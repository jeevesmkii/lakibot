#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent; 
use HTTP::Cookies;
use HTTP::Request;
use URI::Encode qw(uri_encode);
use IO::Async::Loop;
use Net::Async::WebSocket::Client;
use IO::Async::Timer::Periodic;
use Net::Async::IRC;
use Protocol::IRC::Message;
use JSON;

use Data::Dumper;

use constant
	{
	TWITCH_CLIENT_ID => "p0jsj9zcr60se8wzot50szgymgcwwm",
	TWITCH_OAUTH_URI => "https://id.twitch.tv/oauth2/authorize",
	TWITCH_OAUTH_TOKEN_URI => " https://id.twitch.tv/oauth2/token",
	TWITCH_OAUTH_SCOPES => "chat:edit chat:read whispers:read whispers:edit",
	TWITCH_OAUTH_CALLBACK => "http://localhost",
	TWITCH_IRC_URI => "irc.chat.twitch.tv",
	
	IRC_BOT_NAME => "woosterb0t",
	IRC_BOT_OWNER_LIST => ["jeevesmkii"]
	};
	
use constant
	{
	HS_STATE_ROUND_OVER => 0,
	HS_STATE_ROUND_PREPARING => 1,
	HS_STATE_ROUND_IN_PROGRESS => 2
	};

my $sjow_shannel_id = "22588033";
my $sjow_shannel = "https://www.twitch.tv/sjow";
my $twitch_gql = "https://gql.twitch.tv/gql";
my $twitch_pubsub = "wss://pubsub-edge.twitch.tv/v1";
my $deck_tracker_topic = "channel-ext-v1.22588033-apwln3g3ia45kk690tzabfp525h9e1-broadcast";

my $http_ua = LWP::UserAgent->new;
my $cookies = HTTP::Cookies->new(file => "saved.cookies", autosave => 1);
$http_ua->cookie_jar($cookies);
my $json = JSON->new->allow_nonref;

my $ws_client = undef;
my $ping_timer = undef;
my $irc_client = undef;

my $hs_state = HS_STATE_ROUND_OVER;
my @hs_daily_results = ();
my $hs_daily_stats =
	{
	expected_luck => 0.5,
	actual_luck => 0.5
	};

$ws_client = Net::Async::WebSocket::Client->new(

	on_text_frame => sub 
		{
		my ( $self, $frame ) = @_;
		
		# ignore frames that can't be decoded
		my $resp = $json->decode($frame) || return;
		exists($resp->{type}) || return;
		
		# the "RESPONSE" type messages just tells us if we've errored out
		if ($resp->{type} eq "RESPONSE")
			{
			my $err = "Unknown error.";
			$err = $resp->{error}
				if exists($resp->{error});
				
			die "Attempting to connect to twitch websocket returned error: $err"
				unless $err eq "";
				
			# start the ping timer
			$ping_timer->start;
			}
		# but mostly we get messages of type "MESSAGE", original eh?
		elsif ($resp->{type} eq "MESSAGE")
			{
			# we're only subscribed to one topic, so we know what the messages are about
			# ->data->message->content is an array of messages, double fucking quoted
			return
				unless (exists($resp->{data}) && exists($resp->{data}->{message}));
			
			my $msg = $json->decode($resp->{data}->{message}) || return;
			return
				unless exists($msg->{content});
			
			foreach (@{$msg->{content}})
				{
				my $content = $json->decode($_) || next;
				handle_hearthstone_tracker_msg($content);
				}
			}
		},
);

# I believe twitch sends it's stupid "ping" messages every 90 seconds
$ping_timer = IO::Async::Timer::Periodic->new(
	interval => 90,
	
	on_tick => sub
		{
		my %ping = ("type" => "PING");
		my $ping_msg = $json->encode(\%ping);
		
		print "sending ping!\n";
		$ws_client->send_text_frame($ping_msg);
		}
	);
	
$irc_client = Net::Async::IRC->new(
	on_message => sub 
		{
		my ( $self, $type, $message ) = @_;
		
		print "Message type is $type\n";
		print "message is $message\n";
		if ($type eq "PRIVMSG")
			{
			handle_irc_privmsg($message);
			}
		elsif ($type eq "WHISPER")
			{
			handle_irc_whisper($message);
			}
		}
	);

sub hs_has_probabilities($)
	{
	my ($probabilities) = @_;
	
	return ($probabilities->{win_rate} != 0 || $probabilities->{loss_rate} != 0 || $probabilities->{tie_rate} != 0);
	}
	
sub hs_recalculate_probabilities()
	{
	if (scalar @hs_daily_results > 0)
		{
		my $cumulative_win_rate = 0;
		my $cumulative_probability = 0;
		
		foreach (@hs_daily_results)
			{
			$cumulative_win_rate += $_->{favourable};
			$cumulative_probability += $_->{probability};
			}
			
		$hs_daily_stats->{actual_luck} = $cumulative_win_rate / scalar @hs_daily_results;
		$hs_daily_stats->{expected_luck} = $cumulative_probability / scalar @hs_daily_results;
		}
	}

sub hs_log_round_outcome($$)
	{
	my ($outcome, $probabilities) = @_;
	
	# we log two things: 
	# 1) whether the round has a favourable outcome, defined as a win or a tie.
	# 2) The probability of a favourable outcome this round (win + tie probability)
	
	my $favourable = $outcome >= 0 ? 1 : 0;
	my $probability = $probabilities->{win_rate} + $probabilities->{tie_rate};
	push @hs_daily_results, { "favourable" => $favourable, "probability" => $probability };
	hs_recalculate_probabilities();
	}

sub handle_hearthstone_tracker_msg($)
	{
	my ($msg) = @_;
	
	# Sanity check, we want type, and the statistics.
	return
		unless (exists($msg->{type}) && exists($msg->{data}));
	
	# (round ending message gets to here, if we ever need that)
	# we need player and opponent boards
	return
		unless (exists($msg->{data}->{player}) && exists($msg->{data}->{opponent})
			&& exists($msg->{data}->{player}->{board}) && exists($msg->{data}->{opponent}->{board}));
	
	# if bob's buddy state exists, print it
	my $bb = $msg->{data}->{bobs_buddy_state};
	return
		unless (exists($msg->{data}->{bobs_buddy_state}) && exists($bb->{loss_rate}) && exists($bb->{win_rate})
			&& exists($bb->{tie_rate}) && exists($bb->{player_lethal_rate})
			&& exists($bb->{opponent_lethal_rate}));
	
	my $probabilities = 
		{
		"opp_lethal" => $bb->{player_lethal_rate} + 0,
		"win_rate" => $bb->{win_rate} + 0,
		"tie_rate" => $bb->{tie_rate} + 0,
		"loss_rate" => $bb->{loss_rate} + 0,
		"sjow_lethal" => $bb->{opponent_lethal_rate} + 0
		};
	
	# It couldn't be fuckng simple, could it?
	# watch the board state to determine round winners
	if ($hs_state == HS_STATE_ROUND_OVER)
		{
		# in the round over state, all we're looking for is the probabilties to revert to zero to indicate a new round
		
		$hs_state = HS_STATE_ROUND_PREPARING
			if (!hs_has_probabilities($probabilities));
		}
	elsif ($hs_state == HS_STATE_ROUND_PREPARING)
		{
		# when the probabilties revert to zero, we're preparing a round. Then they become non-zero in game.
		$hs_state = HS_STATE_ROUND_IN_PROGRESS
			if (hs_has_probabilities($probabilities));
		}
	elsif ($hs_state == HS_STATE_ROUND_IN_PROGRESS)
		{
		# now we need to watch the boards to figure out who won, when a board empties the round is over
		my $sjow_board_size = scalar @{$msg->{data}->{player}->{board}};
		my $opp_board_size = scalar @{$msg->{data}->{opponent}->{board}};
		
		# TODO: need to confirm this works even when a deathrattle triggers last
		# I believe I've witnessed at least one game where this happened, but need more data to be sure.
		if ($sjow_board_size == 0 || $opp_board_size == 0)
			{
			# the round is over, find result
			my $result = $sjow_board_size - $opp_board_size;
			
			print "Round is a tie!\n"
				if ($result == 0);
			print "Round is a win!\n"
				if ($result > 0);
			print "Round is a loss\n"
				if ($result < 0);
			
			hs_log_round_outcome($result, $probabilities);
			
			print "Expected luck: $hs_daily_stats->{expected_luck}\n";
			print "Actual luck: $hs_daily_stats->{actual_luck}\n";
			
			$hs_state = HS_STATE_ROUND_OVER;
			}
		}
	}

sub is_owner_message($)
	{
	my ($nick) = @_;
	$nick = lc($nick);
	
	foreach (IRC_BOT_OWNER_LIST)
		{
		return 1
			if ($nick eq $_);
		}
		
	return 0;
	}

sub handle_irc_privmsg($)
	{
	my ($msg) = @_;
	
	my ($nick, $ident, $host) = $msg->prefix_split;
	my $text = $msg->arg(1);
	
	# comments directly addressed to the bot
	my $name_match = "@" . IRC_BOT_NAME;
	if ($text =~ /$name_match/ig)
		{
		
		}
	
	print "privmsg from $nick : $text\n";
	}
	
sub handle_irc_whisper($)
	{
	my ($msg) = @_;
	
	my ($nick, $ident, $host) = $msg->prefix_split;
	my $text = $msg->arg(1);
	
	print "whisper from $nick : $text\n";
	}

sub request_shannel_extension_auth_token()
	{
	# I really have no idea what the hash is a hash of, but the request doesn't work without it so lets call is a ritual object.
	my %vars = ("channelID" => $sjow_shannel_id);
	my %persisted_query = ("version" => 1, "sha256Hash" => "37a5969f117f2f76bc8776a0b216799180c0ce722acb92505c794a9a4f9737e7");
	my %extensions = ("persistedQuery" => \%persisted_query);
	my %request_payload = ( 
		"operationName" => "ExtensionsForChannel",
		"variables" => \%vars,
		"extensions" => \%extensions
		);
	
	my $json_payload = $json->encode(\%request_payload);
	
	# get a client ID by scraping the twitch HTML
	my $req = HTTP::Request->new("GET", $sjow_shannel);
	my $resp = $http_ua->request($req);
	
	$resp->is_success
		|| die "Failed to get Sjow's shannel HTML!";
	$resp->decoded_content =~ /clientId=\"([^"]+)/
		|| die "Could not find Twitch TV client ID in HTML!";
		
	my $client_id = $1;
	
	# fetch extension info for sjow's shannel
	$req = HTTP::Request->new("POST", $twitch_gql);
	$req->header("Content-Type" => "application/json");
	$req->header("Client-Id" => $client_id);
	$req->content($json_payload);
	
	$resp = $http_ua->request($req);
	$resp->is_success
		|| die "Failed to interogate GQL API to get shannel extensions!";
	my $ext_struct = $json->decode($resp->decoded_content)
		|| die "Twitch GQL returned unparsable JSON!";
	
	exists($ext_struct->{data}) && exists($ext_struct->{data}->{user}) && exists($ext_struct->{data}->{user}->{channel})
		&& exists($ext_struct->{data}->{user}->{channel}->{selfInstalledExtensions}) 
		|| die "Twitch GQL installed extension data incomplete!";
		
	my $installed_exts = $ext_struct->{data}->{user}->{channel}->{selfInstalledExtensions};
	
	# find the deck tracker struct
	my $deck_tracker = undef;
	foreach (@{$installed_exts})
		{
		$deck_tracker = $_;
		last
			if (exists($deck_tracker->{installation}) && exists($deck_tracker->{installation}->{extension}) &&
				exists($deck_tracker->{installation}->{extension}->{name}) && $deck_tracker->{installation}->{extension}->{name} eq "Hearthstone Deck Tracker");
		$deck_tracker = undef;
		}
	
	$deck_tracker || die "Hearthstone deck tracker extension does not appear to be installed!";
	
	# it's the "token" we need, I don't believe the extension ID changes but maybe we ought to be sure
	exists($deck_tracker->{token}) && exists($deck_tracker->{token}->{jwt})
		|| die "Hearthstone deck tracker struct does not contain auth token!";
	
	return $deck_tracker->{token}->{jwt};
	}

sub generate_twitch_ws_nonce()
	{
	# this is an approximation of what their nonces look like, 30 chars from an alphabet of A-Z, a-z, 0-9
	my @alphabet = ("a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
		"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
		"0", "1", "2", "3", "4", "5", "6", "7", "8", "9");
	
	my $nonce = "";
	$nonce .= $alphabet[rand 62] for 1..30;
	return $nonce;
	}

sub store_twitch_credentials($$$)
	{
	my ($client_secret, $user_token, $refresh_token) = @_;
	
	# store all this crap in the cookie jar, because lazy.
	$cookies->set_cookie(1, "ClientSecret", $client_secret, "/", "example.com", 80, 0, 1, 
			60 * 60 * 24 * 365, 0);
	$cookies->set_cookie(1, "UserToken", $user_token, "/", "example.com", 80, 0, 1, 
			60 * 60 * 24 * 365, 0);
	$cookies->set_cookie(1, "RefreshToken", $refresh_token, "/", "example.com", 80, 0, 1, 
			60 * 60 * 24 * 365, 0);
	}

sub get_twitch_credentials()
	{
	my $credentials = undef;
	if (exists $cookies->{COOKIES}->{'example.com'})
		{
		my $dummy_cookies = $cookies->{COOKIES}->{'example.com'};
		if (exists $dummy_cookies->{'/'} && exists $dummy_cookies->{'/'}->{ClientSecret}
			&& exists $dummy_cookies->{'/'}->{UserToken} && exists $dummy_cookies->{'/'}->{RefreshToken})
			{
			$credentials = {
				"ClientSecret" => $dummy_cookies->{'/'}->{ClientSecret}[1],
				"UserToken" => $dummy_cookies->{'/'}->{UserToken}[1],
				"RefreshToken" => $dummy_cookies->{'/'}->{RefreshToken}[1]
				};
			}
		}
	
	return $credentials;
	}

sub refresh_twitch_credentials()
	{
	my $credentials = get_twitch_credentials()
		|| "No authentication credentials available, use --auth.";
	
	# use the refresh token to get new credentials
	my $token_post_body = "client_id=" . TWITCH_CLIENT_ID
		. "&client_secret=" . $credentials->{ClientSecret}
		. "&refresh_token=" . $credentials->{RefreshToken}
		. "&grant_type=refresh_token&redirect_uri=" . TWITCH_OAUTH_CALLBACK;
	
	my $req = HTTP::Request->new("POST", TWITCH_OAUTH_TOKEN_URI);
	$req->header("Content-Type" => "application/x-www-form-urlencoded");
	$req->content($token_post_body);
	
	my $resp = $http_ua->request($req);
	my $result = undef;
	if ($resp->is_success)
		{
		my $auth_struct = $json->decode($resp->decoded_content);
		if (exists($auth_struct->{access_token}) && exists($auth_struct->{refresh_token}))
			{
			store_twitch_credentials($credentials->{ClientSecret}, $auth_struct->{access_token}, $auth_struct->{refresh_token});
			$result = {
				"ClientSecret" => $credentials->{ClientSecret},
				"UserToken" => $auth_struct->{access_token},
				"RefreshToken" => $auth_struct->{refresh_token}
				};
			}
		}
		
	return $result;
	}


my $auth = 0;
my $temp_refresh = 0;

while ($#ARGV >= 0)
	{
	$_ = shift @ARGV;
	if (m/^--auth/) { $auth = 1; }
	
	# temporary credential refresh until it's hooked up to auth failure
	elsif (m/^--refresh/) { $temp_refresh = 1; }
	}

if ($auth)
	{
	# do the interactive auth flow
	print "Paste the client secret: ";
	chomp(my $client_secret = <STDIN>);
	
	my $auth_url = TWITCH_OAUTH_URI ."?client_id=" . TWITCH_CLIENT_ID 
		. "&redirect_uri=" . TWITCH_OAUTH_CALLBACK
		. "&response_type=code&scope=" . uri_encode(TWITCH_OAUTH_SCOPES, { encode_reserved => 1 });
	
	print "Use this URL to authorise the bot:\n";
	print "$auth_url\n";
	
	print "Paste the OAUTH master token: ";
	chomp(my $oauth_master = <STDIN>);
	
	# use the master token and client secret to get an intial user token and reset code
	my $token_post_body = "client_id=" . TWITCH_CLIENT_ID
		. "&client_secret=" . $client_secret
		. "&code=" . $oauth_master
		. "&grant_type=authorization_code&redirect_uri=" . TWITCH_OAUTH_CALLBACK;
	
	my $req = HTTP::Request->new("POST", TWITCH_OAUTH_TOKEN_URI);
	$req->header("Content-Type" => "application/x-www-form-urlencoded");
	$req->content($token_post_body);
	
	my $resp = $http_ua->request($req);
	$resp->is_success || die "Failed to get access token, reason $!";
	
	my $auth_struct = $json->decode($resp->decoded_content);
	die "No access token in (successful?) authentication response!"
		unless (exists($auth_struct->{access_token}) && exists($auth_struct->{refresh_token}));
	
	
	store_twitch_credentials($client_secret, $auth_struct->{access_token}, $auth_struct->{refresh_token});
	
	print "Authorised successfully!\n";	
	print "Client Secret: $client_secret\n";
	print "User Token: $auth_struct->{access_token}\n";
	print "Refresh Token: $auth_struct->{refresh_token}\n";
	}
elsif ($temp_refresh)
	{
	# this block will be deleted soon
	my $credentials = refresh_twitch_credentials()
		|| die "it didn't work pepega.";
	
	print Dumper( $credentials) . "\n";
	}
else
	{
	# run the bot
	my $loop = IO::Async::Loop->new;
	$loop->add($ws_client);
	$loop->add($ping_timer);
	$loop->add($irc_client);

	# Tedious shit where we have to get a client ID from twitch HTML and then send it to GQL to get an auth token for HS DT
	my $auth_token = request_shannel_extension_auth_token();
	my $ws_nonce = generate_twitch_ws_nonce();

	# HEY! LISTEN!
	my @ws_topics = ($deck_tracker_topic);
	my %ws_listen_data = ("topics" => \@ws_topics, "auth_token" => $auth_token);
	my %ws_listen_struct = ("type" => "LISTEN", "nonce" => $ws_nonce, "data" => \%ws_listen_data);

	my $listen_request = $json->encode(\%ws_listen_struct);

	$ws_client->connect(
		url => $twitch_pubsub
	)->then( sub {
		$ws_client->send_text_frame($listen_request);
	})->get;
	
	my $credentials = get_twitch_credentials()
		|| die "No authentication credentials available, use --auth.";
	
	$irc_client->connect(
		host => TWITCH_IRC_URI,
		nick => IRC_BOT_NAME
	)->then( sub {
		$irc_client->send_message(Protocol::IRC::Message->new_from_line("CAP REQ :twitch.tv/membership twitch.tv/tags twitch.tv/commands"));
		$irc_client->send_message(Protocol::IRC::Message->new_from_line("PASS oauth:" .  $credentials->{UserToken}));
		$irc_client->send_message(Protocol::IRC::Message->new_from_line("NICK " . IRC_BOT_NAME));
		$irc_client->send_message(Protocol::IRC::Message->new_from_line("JOIN #jeevesmkii"));
	})->get;
	
	$loop->run;
	}

