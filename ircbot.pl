#!/usr/bin/perl

use strict;
use warnings;

use POE;
use POE::Component::IRC;
use POE::Component::IRC::Plugin::Connector;
use String::IRC;
use POE::Component::Server::HTTP;
use HTTP::Status;
use Switch;
use JSON::XS;
use List::MoreUtils qw(any);

my $config_file = "ircbot.conf";
my $datadir="data";
my $item_key_file="$datadir/item_keys.json";
my $topic_file="$datadir/topics.json";

### default configuration parameters
my $config = {};
$config->{channel} = "#zabbix";
$config->{curl_flags} = "";
$config->{jira_host} = "https://support.zabbix.com";
$config->{nick} = "zabbixbot";
$config->{port} = "6667";
$config->{real} = "Zabbix IRC Bot";
$config->{server} = "irc.freenode.net";
$config->{user} = "zabbix";
$config->{reload_users} = ();
$config->{jira_receiver_port} = "8000";
$config->{jira_receiver_url} = "/jira-webhook";
$config->{jira_receiver_server_header} = "Jira receiver";

### read configuration
if (open (my $fh, '<:raw', $config_file)) {
    my $configcontents; { local $/; $configcontents = <$fh>; }
    # if present in the JSON structure, will override parameters that were defined above
    close $fh;
    my $config_read = decode_json($configcontents);
    @$config{keys %$config_read} = values %$config_read;
}

my $fh;

### read item keys
open ($fh, '<:raw', $item_key_file) or die "Can't open $item_key_file";
my $itemkeycontents; { local $/; $itemkeycontents = <$fh>; }
close $fh;
my $itemkeys_read = decode_json($itemkeycontents);

### read helper topics

my $topics_read;
my $alltopics;
my $nick;
my $auth;
my $reload_users = $config->{reload_users};

sub read_topics
{
    open ($fh, '<:raw', $topic_file) or die "Can't open $topic_file";
    my $topiccontents; { local $/; $topiccontents = <$fh>; }
    close $fh;
    $topics_read = decode_json($topiccontents);
    $alltopics = join(", ", sort {lc $a cmp lc $b} (keys $topics_read));
}

read_topics

my ($irc) = POE::Component::IRC->spawn();

my ($httpd) = POE::Component::Server::HTTP->new(
    Port => $config->{jira_receiver_port},
    ContentHandler => { '$config->{jira_receiver_url}' => \&http_handler },
    Headers => { Server => $config->{jira_receiver_server_header} },
);

### helper functions

sub reply
{
    $irc->yield(privmsg => $_[0], $_[1]);
}

### public interface

my %COMMANDS =
(
    help  => { function => \&cmd_help,  usage => 'help <command> - print usage information'                 },
    issue => { function => \&cmd_issue, usage => 'issue <n|jira> - fetch issue description'                 },
    key   => { function => \&cmd_key,   usage => 'key <item key> - show item key description'               },
    topic => { function => \&cmd_topic, usage => 'topic <topic>  - show short help message about the topic' },
    reload=> { function => \&cmd_reload, usage => 'reload - reload topics'                                  },
);

my @ignored_commands = qw (getquote note quote time seen botsnack);

sub get_command
{
    my @commands = ();

    foreach my $command (keys %COMMANDS)
    {
        push @commands, $command if $command =~ m/^$_[0]/;
    }

    return join ', ', sort @commands;
}

sub get_itemkey
{
    my @itemkeys = ();
    foreach my $itemkey (keys $itemkeys_read)
    {
        push @itemkeys, $itemkey if $itemkey =~ m/^\Q$_[0]\E/;
    }

    return join ', ', sort @itemkeys;
}

sub get_topic
{
    my @topics = ();
    my @return_topics;
    my $aliased_topic;
    foreach my $topic (keys $topics_read)
    {
        push @topics, $topic if $topic =~ m/^\Q$_[0]\E/i;
    }
    foreach my $topic (@topics) {
        ($aliased_topic) = $topics_read->{$topic} =~ m/^alias:(.+)/;
        if ($aliased_topic)
        {
            if (!any { $aliased_topic eq $_ } @topics ) { push @return_topics, $aliased_topic };
        } else {
            push @return_topics, $topic;
        }
    }

    return join ', ', sort @return_topics;
}

sub cmd_help
{
    if (@_)
    {
        my $command = get_command $_[0];

        switch ($command)
        {
            case ''   { return "ERROR: Command \"$_[0]\" does not exist.";                          }
            case /, / { return "ERROR: Command \"$_[0]\" is ambiguous (candidates are: $command)."; }
            else      { return $COMMANDS{$command}->{usage};                                        }
        }
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
        my $itemkey = get_itemkey $_[0];

        switch ($itemkey)
        {
            case ''   { return "ERROR: Item key \"$_[0]\" not known.";                           }
            case /, / { return "Multiple item keys match \"$_[0]\" (candidates are: $itemkey)."; }
            else      { return "$itemkey: $itemkeys_read->{$itemkey}";                           }
        }
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
        my $topic = get_topic $_[0];

        switch ($topic)
        {
            case ''   { return "ERROR: Topic \"$_[0]\" not known.";                         }
            case /, / { return "Multiple topics match \"$_[0]\" (candidates are: $topic)."; }
            else      { return "$topic: $topics_read->{$topic}";                            }
        }
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
        return "Topics reloaded";
    }
    else
    {
        return "ERROR: Not identified with NickServ";
    }
}

my @issues = ();
my %issues = ();

sub get_issue
{
    return $issues{$_[0]} if exists $issues{$_[0]};

    my $json = `curl --silent $config->{curl_flags} $config->{jira_host}/rest/api/2/issue/$_[0]?fields=summary` or return "ERROR: Could not fetch issue description.";

    if (my ($descr) = $json =~ m!summary":"(.+)"}!)
    {
        $descr =~ s/\\([\\"])/$1/g;
        return +($issues{$_[0]} = "[$_[0]] $descr (URL: https://support.zabbix.com/browse/$_[0])");
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
    @_ = ('1') if not @_;
    my $issue = uc $_[0];

    if ($issue =~ m/^\d+$/)
    {
        return +($issue - 1 <= $#issues ? get_issue($issues[-$issue]) : "ERROR: Issue \"$issue\" does not exist in chat history.");
    }
    elsif ($issue =~ m/^\w{3,7}-\d{1,4}$/)
    {
        return get_issue($issue);
    }
    else
    {
        return "ERROR: Argument \"$_[0]\" is not a number or an issue identifier.";
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
    my $channel = $where->[0];
    my $timestamp = localtime;
    my ($replymsg, $recipient);

    print "[$timestamp] $channel <$nick> $message\n";

    if (my ($prefix, $argument) = $message =~ m/^!(\w+)\b(.*)/g)
    {
        if (grep { /^$prefix$/ } @ignored_commands) { return };
        my $command = get_command $prefix;
        $argument =~ s/^\s+|\s+$//g if $argument;

        switch ($command)
        {
            case ''   { $replymsg = "ERROR: Command \"$prefix\" does not exist.";                                               }
            case /, / { $replymsg = "ERROR: Command \"$prefix\" is ambiguous (candidates are: $command).";                      }
            else      { $replymsg = $argument ? $COMMANDS{$command}->{function}($argument) : $COMMANDS{$command}->{function}(); }
            if ($channel =~ m/^#/)
            {
                # message in a channel
                $recipient = $channel;
            }
            else
            {
                $recipient = $nick;
            }
            reply ($recipient, $replymsg);
        }
    }
    else
    {
        push @issues, map {uc} ($message =~ m/\b(\w{3,7}-\d{1,4})\b/g);
        @issues = @issues[-15 .. -1] if $#issues >= 15;
    }
}

sub on_default
{
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ();

    return if $event eq '_child';

    foreach (@$args)
    {
        if (ref $_ eq 'ARRAY')
        {
            push @output, '[', join(', ', @$_), ']';
            last;
        }
        if (ref $_ eq 'HASH')
        {
            push @output, '{', join(', ', %$_), '}';
            last;
        }
        push @output, "\"$_\"";
    }

    printf "[%s] unhandled event '%s' with arguments <%s>\n", scalar localtime, $event, join ' ', @output;
}

sub on_ignored
{
    # ignore event
}

sub http_handler {
    my ($request, $response) = @_;
    $response->code(RC_OK);
    $response->content("You requested " . $request->uri);
    my $req_content = $request->content;
    print "Incoming jira webhook request: $req_content\n";
    my $incoming_json = decode_json($req_content);
    my $issuekey = $incoming_json->{issue}->{key};
    my $issuesummary = $incoming_json->{issue}->{fields}->{summary};
    my $user = $incoming_json->{user}->{displayName};
    my $username = $incoming_json->{user}->{name};
    print "Extracted [issue_key], summary, user (username): [$issuekey] $issuesummary  $user ($username)\n";
    my $colouredissuekey = String::IRC->new($issuekey)->red;
    # we only expect notifications about new issues created at this time
    my $colouredbystring = String::IRC->new("created by $user/$username")->grey;
    my $colouredissuesummary = String::IRC->new($issuesummary)->green;
    my $colouredurl = String::IRC->new("https://support.zabbix.com/browse/$issuekey")->light_blue;
    my $replymsg = "[$colouredissuekey] $colouredissuesummary $colouredbystring ($colouredurl)";
    reply ($config->{channel}, $replymsg);
    return RC_OK;
}

### connect to IRC

POE::Session->create
(
    inline_states =>
    {
        _default         => \&on_default,
        _start           => \&on_start,
        irc_001          => \&on_connected,
        irc_public       => \&on_public,
        irc_ctcp_action  => \&on_public,
        irc_msg          => \&on_public,

        map { ; "irc_$_" => \&on_ignored }
            qw(connected isupport join mode notice part ping registered quit
               002 003 004 005 251 254 255 265 266 332 333 353 366 422 451)
    }
);

$poe_kernel->run();

exit 0;
