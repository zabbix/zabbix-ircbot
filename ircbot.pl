#!/usr/bin/perl

use strict;
use warnings;

use POE;
use POE::Component::IRC;
use POE::Component::IRC::Plugin::Connector;
use String::IRC;
use POE::Component::Server::HTTP;
use HTTP::Status;
use JSON::XS;
# has to run with List::Util 1.25, which does not have 'any' yet
use List::MoreUtils qw(any);

my $config_file   = "ircbot.conf";
my $datadir       = "data";
my $item_key_file = "$datadir/item_keys.json";
my $topic_file    = "$datadir/topics.json";
my $keyword_file  = "$datadir/keywords.json";

### default configuration parameters
my $config = {};
$config->{channel}                     = "#zabbix";
$config->{curl_flags}                  = "";
$config->{jira_host}                   = "https://support.zabbix.com";
$config->{nick}                        = "zabbixbot";
$config->{port}                        = "6667";
$config->{real}                        = "Zabbix IRC Bot";
$config->{server}                      = "irc.freenode.net";
$config->{user}                        = "zabbix";
$config->{reload_users}                = ();
$config->{jira_receiver_port}          = "8000";
$config->{jira_receiver_url}           = "/jira-webhook";
$config->{jira_receiver_server_header} = "Jira receiver";

### read configuration
if (open(my $fh, '<:raw', $config_file))
{
    my $config_read = do { local $/; decode_json(<$fh>); };
    # if present in the JSON structure, will override parameters that were defined above
    close $fh;
    @$config{keys %$config_read} = values %$config_read;
}

# bot can't change the nickname, so we store the length once
my $nicklength = length($config->{nick});
my $fh;

### read helper topics

my $topics_read;
my $alltopics;
my $nick;
my $auth;
my $reload_users = $config->{reload_users};

sub read_topics
{
    open($fh, '<:raw', $topic_file) or die "Can't open $topic_file";
    $topics_read = do { local $/; decode_json(<$fh>); };
    close $fh;
    $alltopics = join(", ", sort {lc $a cmp lc $b} (keys %$topics_read));
}

read_topics

### read keywords

my $keywords_read;

sub read_keywords
{
    open($fh, '<:raw', $keyword_file) or die "Can't open $keyword_file";
    $keywords_read = do { local $/; decode_json(<$fh>); };
    close $fh;
}

read_keywords

### read item keys

my $itemkeys_read;

sub read_itemkeys
{
    open($fh, '<:raw', $item_key_file) or die "Can't open $item_key_file";
    $itemkeys_read = do { local $/; decode_json(<$fh>); };
    close $fh;
}

read_itemkeys

my ($irc) = POE::Component::IRC->spawn();

my ($httpd) = POE::Component::Server::HTTP->new(
    Port           => $config->{jira_receiver_port},
    PreHandler     => {
        '/'        => sub {$_[0]->header(Connection => 'close')}
    },
    ContentHandler => {$config->{jira_receiver_url} => \&http_handler},
    Headers        => {Server => $config->{jira_receiver_server_header}},
);

### helper functions

sub reply
{
    # IRC messages consist of "PRIVMSG <recipient> <message>". They can be of 512 characters max, but have trailing CRLF.
    # The message also is colon-prefixed. Accounting for the command, spaces, CRLF and the colon makes the max
    #  recipient+message length of 500.
    # ...but there's also prefix, and servers will add it when sending messages to each other. Especially with Freenode
    #  cloaking, there is no way to know the final max length of the message. POE::Component::IRC by default trims lines
    #  at 450-<nickname length>, thus we will split at the same length to be safe.
    # "10" is the total length of the command (PRIVMSG), spaces, colon
    my ($recipient, $replymsg) = @_;
    my $contentlimit = 450 - 10 - $nicklength - length($recipient);
    my @messages = unpack("(A$contentlimit)*", $replymsg);
    foreach (@messages) {
        my $message = $_;
        $irc->yield(privmsg => $recipient, $message);
    }
}

### public interface

my %COMMANDS =
(
    help  => { function => \&cmd_help,   usage => 'help <command> - print usage information'                },
    issue => { function => \&cmd_issue,  usage => 'issue <n|jira> - fetch issue description'                },
    key   => { function => \&cmd_key,    usage => 'key <item key> - show item key description'              },
    topic => { function => \&cmd_topic,  usage => 'topic <topic> - show short help message about the topic' },
    reload=> { function => \&cmd_reload, usage => 'reload - reload topics, keywords and item keys'          },
);

my @ignored_commands = qw(getquote note quote time seen botsnack addquote karma lart);

sub get_command
{
    my @commands;

    foreach my $command (keys %COMMANDS)
    {
        push @commands, $command if $command =~ m/^$_[0]/;
    }

    return join ', ', sort @commands;
}

sub get_itemkey
{
    my @itemkeys;
    foreach my $itemkey (keys %$itemkeys_read)
    {
        push @itemkeys, $itemkey if $itemkey =~ m/^\Q$_[0]\E/;
    }

    return join ', ', sort @itemkeys;
}

sub get_topic
{
    my @topics;
    my @return_topics;
    my $aliased_topic;
    foreach my $topic (keys %$topics_read)
    {
        push @topics, $topic if $topic =~ m/^\Q$_[0]\E/i;
    }
    foreach my $topic (@topics)
    {
        ($aliased_topic) = $topics_read->{$topic} =~ m/^alias:(.+)/;
        if ($aliased_topic)
        {
            if (!any { $aliased_topic eq $_ } @topics ) { push @return_topics, $aliased_topic };
        }
        else
        {
            push @return_topics, $topic;
        }
    }

    return join ', ', sort @return_topics;
}

sub cmd_help
{
    if (@_)
    {
        my $user_input = $_[0];
        my $command = get_command $user_input;
        return "ERROR: Command \"$user_input\" does not exist." if $command eq '';
        return "ERROR: Command \"user_input\" is ambiguous (candidates are: $command)." if $command =~ m/, /;
        return $COMMANDS{$command}->{usage};
    }
    else
    {
        return 'Available commands: ' . (join ', ', sort keys %COMMANDS) . '.';
        return 'Type "!help <command>" to print usage information for a particular command.';
    }
}

sub cmd_key
{
    if (@_)
    {
        my $user_input = $_[0];
        my $itemkey = get_itemkey $user_input;
        return "ERROR: Item key \"$user_input\" not known." if $itemkey eq '';
        return "Multiple item keys match \"$user_input\" (candidates are: $itemkey)." if $itemkey =~ m/, /;
        return "$itemkey: $itemkeys_read->{$itemkey}";
    }
    else
    {
        return 'Type "!key <item key>" to see item key description.';
    }
}

sub cmd_topic
{
    if (@_)
    {
        my $user_input = $_[0];
        my $topic = get_topic $user_input;
        return "ERROR: Topic \"$user_input\" not known." if $topic eq '';
        return "Multiple topics match \"$user_input\" (candidates are: $topic)." if $topic =~ m/, /;
        return "$topic: $topics_read->{$topic}";
    }
    else
    {
        return "Available topics: $alltopics";
    }
}

sub cmd_reload
{
    if ($auth)
    {
        if (!any { $nick eq $_ } @$reload_users ) { return "ERROR: Not authorised to reload" };
        read_topics;
        read_keywords;
        read_itemkeys;
        return "Topics, keywords and item keys reloaded";
    }
    else
    {
        return "ERROR: Not identified with NickServ";
    }
}

my @issues;
my %issues;

sub get_issue
{
    my $issue_key = $_[0];
    return $issues{$issue_key} if exists $issues{$issue_key};

    my $json = `curl --silent $config->{curl_flags} $config->{jira_host}/rest/api/2/issue/$issue_key?fields=summary` or return "ERROR: Could not fetch issue description.";

    if (my ($descr) = $json =~ m!summary":"(.+)"}!)
    {
        $descr =~ s/\\([\\"])/$1/g;
        return +($issues{$issue_key} = "[$issue_key] $descr (URL: https://support.zabbix.com/browse/$issue_key)");
    }
    else
    {
        my ($error) = $json =~ m!errorMessages":\["(.+)"\]!;
        $error = 'unknown' unless $error;
        $error = lc $error;

        return "ERROR: Could not fetch issue description. Reason: $error.";
    }
}

sub cmd_issue
{
    my $issue = '1';
    if (@_)
    {
        $issue = uc $_[0];
    }

    if ($issue =~ m/^\d+$/)
    {
        return +($issue - 1 <= $#issues ? get_issue($issues[-$issue]) : "ERROR: Issue \"$issue\" does not exist in chat history.");
    }
    elsif ($issue =~ m/^\w{3,7}-\d{1,5}$/)
    {
        return get_issue($issue);
    }
    else
    {
        return "ERROR: Argument \"$issue\" is not a number or an issue identifier.";
    }
}

### event handlers

sub on_start
{
    $irc->yield(register => 'all');

    $_[HEAP]->{connector} = POE::Component::IRC::Plugin::Connector->new();
    $irc->plugin_add('Connector' => $_[HEAP]->{connector});

    $irc->yield
    (
        connect =>
        {
            Nick     => $config->{nick},
            Username => $config->{user},
            Ircname  => $config->{real},
            Server   => $config->{server},
            Port     => $config->{port},
        }
    );
}

sub on_connected
{
    $irc->yield(join => $config->{channel});
}

sub on_public
{
    my ($who, $where, $message) = @_[ARG0, ARG1, ARG2];

    $nick = (split /!/, $who)[0];
    $auth = $_[ARG3];
    my $channel   = $where->[0];
    my $timestamp = localtime;
    my ($replymsg, $recipient);
    if ($channel =~ m/^#/)
    {
        # message in a channel
        $recipient = $channel;
    }
    else
    {
        $recipient = $nick;
    }

    print "[$timestamp] $channel <$nick> $message\n";

    if (my ($prefix, $argument) = $message =~ m/^!(\w+)\b(.*)/g)
    {
        if (grep { /^$prefix$/ } @ignored_commands) { return };
        my $command = get_command $prefix;
        $argument =~ s/^\s+|\s+$//g if $argument;

        if ($command eq '')
        {
            $replymsg = "ERROR: Command \"$prefix\" does not exist.";
        }
        elsif ($command =~ /, /)
        {
            $replymsg = "ERROR: Command \"$prefix\" is ambiguous (candidates are: $command).";
        }
        else
        {
            $replymsg = $argument ? $COMMANDS{$command}->{function}($argument) : $COMMANDS{$command}->{function}();
        }
        reply($recipient, $replymsg);
    }
    else
    {
        push @issues, map {uc} ($message =~ m/\b(\w{3,7}-\d{1,5})\b/g);
        @issues = @issues[-15 .. -1] if $#issues >= 15;

        foreach my $keyword (keys %$keywords_read)
        {
            if ($message =~ m/$keyword/i)
            {
                reply($recipient, "$nick, " . $keywords_read->{$keyword});
            }
        }
    }
}

sub on_default
{
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output;

    return if $event eq '_child';

    foreach my $arg (@$args)
    {
        if (ref $arg eq 'ARRAY')
        {
            push @output, '[', join(', ', @$arg), ']';
            last;
        }
        if (ref $arg eq 'HASH')
        {
            push @output, '{', join(', ', %$arg), '}';
            last;
        }
        push @output, "\"$arg\"";
    }

    printf "[%s] unhandled event '%s' with arguments <%s>\n", scalar localtime, $event, join ' ', @output;
}

sub on_ignored
{
    # ignore event
}

sub http_handler
{
    my ($request, $response) = @_;
    my $timestamp = localtime;
    $response->code(RC_OK);
    $response->content("You requested " . $request->uri);
    my $req_content = $request->content;
    print "[$timestamp] Incoming jira webhook request: $req_content\n";
    my $incoming_json = decode_json($req_content);
    my $webhookevent = $incoming_json->{webhookEvent};
    if ($webhookevent eq "jira:issue_created")
    {
        # explicitly filter out only new issue notifications
        # other possible events :
        # - jira:issue_deleted
        # - jira:issue_updated
        # - jira:worklog_updated
        my $issuekey = $incoming_json->{issue}->{key};
        if ($issuekey =~ m/^(ZBX-|ZBXNEXT-)/)
        {
            # react to issues from ZBX and ZBXNEXT projects only
            my $issuesummary = $incoming_json->{issue}->{fields}->{summary};
            my $user = $incoming_json->{user}->{displayName};
            my $username = $incoming_json->{user}->{name};
            print "[$timestamp] Extracted [issue_key], summary, user (username): [$issuekey] $issuesummary  $user ($username)\n";
            my $colouredissuekey = String::IRC->new($issuekey)->red;
            # we only expect notifications about new issues created at this time
            my $colouredbystring = String::IRC->new("created by $user")->grey;
            if ($user ne $username)
            {
                $colouredbystring .= String::IRC->new("/$username")->grey;
            }
            my $colouredissuesummary = String::IRC->new($issuesummary)->green;
            my $colouredurl = String::IRC->new("https://support.zabbix.com/browse/$issuekey")->light_blue;
            my $replymsg = "[$colouredissuekey] $colouredissuesummary $colouredbystring ($colouredurl)";
            reply($config->{channel}, $replymsg);
        }
    }
    return RC_OK;
}

### connect to IRC

POE::Session->create
(
    inline_states =>
    {
        _default        => \&on_default,
        _start          => \&on_start,
        irc_001         => \&on_connected,
        irc_public      => \&on_public,
        irc_ctcp_action => \&on_public,
        irc_msg         => \&on_public,

        map {; "irc_$_" => \&on_ignored}
            qw(connected isupport join mode notice part ping registered quit
               002 003 004 005 251 254 255 265 266 332 333 353 366 422 451)
    }
);

$poe_kernel->run();

exit 0;
