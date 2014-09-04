#!/usr/bin/perl

use strict;
use warnings;

use POE;
use POE::Component::IRC;
use Switch;

my $NICK = 'zabbixbot';
my $USER = 'zabbixbot';
my $REAL = 'Zabbix IRC Bot';
my $SERVER = 'irc.freenode.net';
my $PORT = 6667;
my $CHANNEL = '#zabbix';

my ($irc) = POE::Component::IRC->spawn();

### helper functions

sub reply
{
    $irc->yield(privmsg => $CHANNEL, $_[0]);
}

### public interface

my %COMMANDS =
(
    help  => { function => \&cmd_help,  usage => 'help <command> - print usage information' },
    issue => { function => \&cmd_issue, usage => 'issue <n|jira> - fetch issue description' },
);

sub get_command
{
    my @commands = ();

    foreach my $command (keys %COMMANDS)
    {
        push @commands, $command if $command =~ m/^$_[0]/;
    }

    return join ', ', sort @commands;
}

sub cmd_help
{
    if (@_)
    {
        my $command = get_command $_[0];

        switch ($command)
        {
            case ''   { reply "ERROR: Command \"$_[0]\" does not exist.";                          }
            case /, / { reply "ERROR: Command \"$_[0]\" is ambiguous (candidates are: $command)."; }
            else      { reply $COMMANDS{$command}->{usage};                                        }
        }
    }
    else
    {
        reply 'Available commands: ' . (join ', ', sort keys %COMMANDS) . '.';
        reply 'Type "!help <command>" to print usage information for a particular command.';
    }
}

my @issues = ();
my %issues = ();

sub get_issue
{
    return $issues{$_[0]} if exists $issues{$_[0]};

    my $html = `curl --silent https://support.zabbix.com/browse/$_[0]` or return "ERROR: Could not fetch issue description.";

    if (my ($descr) = $html =~ m!<title>\[$_[0]\] ([^<]+) - ZABBIX SUPPORT</title>!s)
    {
        return +($issues{$_[0]} = "[$_[0]] $descr (URL: https://support.zabbix.com/browse/$_[0]).");
    }
    else
    {
        my ($error) = $html =~ m!<title>([^<]+) - ZABBIX SUPPORT</title>!s;
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
        reply +($issue - 1 <= $#issues ? get_issue($issues[-$issue]) : "ERROR: Issue \"$issue\" does not exist in chat history.");
    }
    elsif ($issue =~ m/^\w{3,7}-\d{1,4}$/)
    {
        reply get_issue($issue);
    }
    else
    {
        reply "ERROR: Argument \"$_[0]\" is not a number or an issue identifier.";
    }
}

### event handlers

sub on_start
{
    $irc->yield(register => 'all');
    $irc->yield
    (
        connect =>
        {
            Nick     => $NICK,
            Username => $USER,
            Ircname  => $REAL,
            Server   => $SERVER,
            Port     => $PORT
        }
    );
}

sub on_connected
{
    $irc->yield(join => $CHANNEL);

    $_[HEAP]->{seen_traffic} = 1;
    $_[KERNEL]->delay(my_autoping => 300);
}

sub on_disconnected
{
    $_[KERNEL]->delay(my_autoping => undef);
    $_[KERNEL]->delay(my_reconnect => 60);
}

sub on_autoping
{
    $_[KERNEL]->post(userhost => $NICK) unless $_[HEAP]->{seen_traffic};

    $_[HEAP]->{seen_traffic} = 0;
    $_[KERNEL]->delay(my_autoping => 300);
}

sub on_public
{
    my ($who, $where, $message) = @_[ARG0, ARG1, ARG2];

    my $nick = (split /!/, $who)[0];
    my $channel = $where->[0];
    my $timestamp = localtime;

    print "[$timestamp] $channel <$nick> $message\n";

    if (my ($prefix, $argument) = $message =~ m/^!(\w+)\b(.*)/g)
    {
        my $command = get_command $prefix;
        $argument =~ s/^\s+|\s+$//g if $argument;

        switch ($command)
        {
            case ''   { reply "ERROR: Command \"$prefix\" does not exist.";                                         }
            case /, / { reply "ERROR: Command \"$prefix\" is ambiguous (candidates are: $command).";                }
            else      { $argument ? $COMMANDS{$command}->{function}($argument) : $COMMANDS{$command}->{function}(); }
        }
    }
    else
    {
        push @issues, map {uc} ($message =~ m/\b(\w{3,7}-\d{1,4})\b/g);
        @issues = @issues[-15 .. -1] if $#issues >= 15;
    }

    $_[HEAP]->{seen_traffic} = 1;
}

sub on_default
{
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ();

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

    $_[HEAP]->{seen_traffic} = 1;

    return 0;
}

### connect to IRC

POE::Session->create
(
    inline_states =>
    {
        _default         => \&on_default,
        _start           => \&on_start,
        irc_001          => \&on_connected,
        irc_disconnected => \&on_disconnected,
        irc_error        => \&on_disconnected,
        irc_socketerr    => \&on_disconnected,
        irc_public       => \&on_public,
        my_autoping      => \&on_autoping,
        my_reconnect     => \&on_start,

        map { ; "irc_$_" => sub { $_[HEAP]->{seen_traffic} = 1; } }
            qw(connected isupport join mode notice part ping registered quit
               002 003 004 005 251 254 255 265 266 332 333 353 366 422 451)
    }
);

$poe_kernel->run();

exit 0;
