#!/opt/local/bin/perl -w
#SNM 2.30 - System and Network Monitor
#__________________________________________________________________________________________

=head1 NAME

SNM - System and Network Monitor

=head1 SYNOPSIS

Usage: snm.pl -c configfile [options], where options are:
  -v           Activates verbose mode
  -t           Activates test mode, excluding queries to targets
  -h           This help text

=head1 REQUIRES

Perl5.008,
Net::SNMP      (in snm.pl only),
Net::SMTP      (in snm.pl only),
XML::Simple    (in snm.pl and snm.cgi),
RRDs           (in snm.pl and snm.cgi)
HTML::Template (in snm.cgi only),

=head1 DESCRIPTION

SNM is a System and Network Monitor that utilises SNMP and Tobi Oetiker's RRDtool.

=head1 METHODS

=head2 Creation

=over 4

=item Use

This program requires three input files to function:
1. Configuration (recommend config.xml),
2. Targets (recommend targets.xml),
3. Graphs  (recommend graphs.xml)

To develop the configuration, target and graph files, refer
to documentation (readme.html) and the included example files.

=back

=head1 AUTHOR

Thomas Price, mailto:t_h_048d3 via the sourceforge.net website

=head1 SEE ALSO

rrdtool            : http://www.rrdtool.org

=head1 ACKNOWLEDGMENTS

The original concept for this application was based on:
 F<MRTG> and F<RRDtool> written by Tobias Oetiker.

=head1 COPYRIGHT

Copyright (c) 2003-2006 Thomas Price.  All rights reserved.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut

#_______________________________________________________________________________________
#
#    This program initialises the environment, then loops through to:
#    - determine targets,
#    - execute snmp and ping queries
#    - save to .rrd files and
#    - e-mail alerts
#
#_____________________ Begin: INITIAL: Initialise the environment ______________________

use strict;
use warnings;
use sigtrap;

# Get the command line options
use Getopt::Std;

use Cwd;
use FindBin;
use lib "$FindBin::Bin/lib";
use lib qw(/lib/perl/5.8.5/i386-linux-thread-multi /opt/local/lib/snm);

use vars qw($error $session $response $opt_c $opt_v $opt_t $opt_h $opt_sleep);
getopt('c');
getopts('vthd');

# Display TEST MODE when the Option -t is called.
if ( defined($opt_t) ) {
    print_log("\nSNM 2.30 - System and Network Monitor\n");
    print_log("Copyright (C) 2006 Thomas Price\n");
    print_log("           Test Mode Activated\n");
    $opt_v = 1;
}

# O/S detection
my ( $p_os, $sl, $newgid, $newuid );
if ( $^O =~ /^darwin/i ) {
    $opt_sleep = 1;
}
$opt_sleep = 0; # PFZ turn this off for now
if ( $^O =~ /^(ms)?(dos|win(32|nt)?)/i ) {
    $p_os = 'n';    # prefix for the number of pings
    $sl   = '\\';
}
elsif ( $^O =~ /^(linux|darwin)/i ) {
    $p_os = 'c';    # prefix for the number of pings
    $sl   = '/';
}
else {
    print_log("WARNING   |O/S is not Win32 or Linux.\n"
            . "       SNM has only been tested on Win32"
            . " and Linux Operating Systems.\n" );
}
&debug("\nmain      |O/S is Win32 or Linux compatable ($^O)");

# Verify the perl version is not less than 5.008
print('Warning   |Perl version 5.8.0 or greater is recommended')
    if ( $] < 5.008 );
&debug( 'main      |Perl                is installed (' . $] . ')' );
&debug(
    'main      |Cwd         library is installed (' . $Cwd::VERSION . ')' );
&debug(   'main      |FindBin     library is installed ('
        . $FindBin::VERSION
        . ')' );
&debug(   'main      |Getopt::Std library is installed ('
        . $Getopt::Std::VERSION
        . ')' );
use XML::Simple qw(:strict);    # Load the XML::Simple library
&debug(   'main      |XML::Simple library is installed ('
        . $XML::Simple::VERSION
        . ')' );
use Net::SNMP;                  # Load the Net::SNMP library
&debug('main      |Net::SNMP   library is installed');
use Net::Ping;                  # Load the Net::Ping library
&debug(   'main      |Net::Ping   library is installed ('
        . $Net::Ping::VERSION
        . ')' );
use Net::SMTP;                  # Load the Net::SMTP library
&debug(   'main      |Net::SMTP   library is installed ('
        . $Net::SMTP::VERSION
        . ')' );
use RRDs;                       # Load the RRDs library
&debug(
    'main      |RRDs        library is installed (' . $RRDs::VERSION . ')' );

# SIGINT call - Clean up if an interuption occurs.
$SIG{INT}  = \&sigint;
$SIG{TERM} = \&sigint;

# Windows sends a QUIT signal to the perl app when logging out. This manages it.
$SIG{QUIT} = 'IGNORE';

# Exit now if the Option -h is called.
if ( defined($opt_h) ) {
    print(    "\nSNM 2.30 - System and Network Monitor\n\n"
            . "Copyright (C) 2006 Thomas Price\n\n"
            . "Usage: snm.pl -c configfile [options], where options are:\n"
            . " -v   Activates verbose mode\n"
            . " -t   Activates test mode\n"
            . " -h   This help text\n\n" );
    exit(0);
}

# Defining the $configile variable
die(      "ERROR     |Configuration file not defined.\n"
        . "       Use the -c option to point to the full path of one.\n"
        . "       For help use snm.pl -h\n" )
    if ( !defined($opt_c) );
my $configfile = $opt_c;
&debug( 'main      |Config file ' . $configfile . ' defined' );

# Verify $configfile has a full path by searching for : or / or \
if ( not $configfile =~ /:|\\|\// ) {
    &debug(   'main      |Did not find full path in config definition'
            . ' Prefixing "'
            . getcwd
            . '" to file' );
    $configfile = getcwd . $sl . $configfile;
}

# Verify if the config file exists/readable/type
&debug( 'main      |Evaluating Config file "' . $configfile . '"' );
my $cfg
    = eval { XMLin( $configfile, ForceArray => ['target'], KeyAttr => '' ) };
die( "ERROR     |Error when evaluating " . $configfile . "\n$@\n" )
    if ($@);
&debug( 'main      |Config file "' . $configfile . '" loaded successfully' );

#________ Test the config file ________________________________________________
# use Data::Dumper;
# print Dumper($cfg);

# Defining the log file variable
if ( !defined( $cfg->{log}->{file} ) ) {
    &debug('main      |<log file=""> not defined');
}
else {
    &debug( 'main      |<log file="' . $cfg->{log}->{file} . '"> defined.' );
}

#________ If *nix and UIG/GID/PID _____________________________________________
if ( ( $^O =~ /^(linux|darwin)/i ) && ( defined( $cfg->{nix_mgt} ) ) ) {

    # impersonate to another uid/gid and create a PID file if under linux
    use Net::Server::Daemonize qw(set_user create_pid_file daemonize);
    use POSIX qw(geteuid getegid);
    if ( defined( $cfg->{nix_mgt}->{daemon} ) ) 
    {
        $cfg->{nix_mgt}->{user}     = geteuid unless defined( $cfg->{nix_mgt}->{user} );
        $cfg->{nix_mgt}->{group}    = getegid unless defined( $cfg->{nix_mgt}->{group} );
        $cfg->{nix_mgt}->{PID_path} = '/var/run/snm.pid' 
            unless defined( $cfg->{nix_mgt}->{PID_path} );
        print_log(
            'main      |Daemonizing with user="'
                . $cfg->{nix_mgt}->{user}
                . '" and group="'
                . $cfg->{nix_mgt}->{group}
                . '" and PID="' 
                . $cfg->{nix_mgt}->{PID_path} 
                . '"' );
        if ( defined ( $opt_t ) )
        {
            print_log('main      |Test mode - no forking done');
            print_log('main      |Setting permissions for user="'
                    . $cfg->{nix_mgt}->{user}
                    . '" and group="'
                    . $cfg->{nix_mgt}->{group}
                    . '"' );
            set_user(
                $cfg->{nix_mgt}->{user},    # User
                $cfg->{nix_mgt}->{group}    # Group
            );
        }
        else
        {
            daemonize(
                $cfg->{nix_mgt}->{user},    # User
                $cfg->{nix_mgt}->{group},   # Group
                $cfg->{nix_mgt}->{PID_path} # PID file path 
            );
            undef($opt_sleep);
        }
    }
    else
    {
        if (   ( defined( $cfg->{nix_mgt}->{user} ) )
        && ( defined( $cfg->{nix_mgt}->{group} ) ) )
        {
            print_log('main      |Setting permissions for user="'
                    . $cfg->{nix_mgt}->{user}
                    . '" and group="'
                    . $cfg->{nix_mgt}->{group}
                    . '"' );
            set_user(
                $cfg->{nix_mgt}->{user},    # User
                $cfg->{nix_mgt}->{group}    # Group
            );
        }
        if ( defined( $cfg->{nix_mgt}->{PID_path} ) ) {
            print_log(
                'main      |Creating PID="' . $cfg->{nix_mgt}->{PID_path} . '"' );
            create_pid_file(
                $cfg->{nix_mgt}->{PID_path}    # Path to PID file
            );
        }
    }
}

# Check if RRDs can access rrdtool ____________________________________________
my $ERR = q{};                             #empty string
my $test_file;
if ($opt_t) {
    if ( $p_os eq 'n' ) { $test_file = 'test_win32.rrd'; }
    else { $test_file = 'test_linux.rrd'; }
    my ($chk_rrds) = RRDs::last $test_file;
    $ERR = RRDs::error;
    die_log( 'ERROR     |Error while testing RRDs: ' . $ERR ) if $ERR;
    die_log(  'ERROR     |rrdtool access via RRDs failed. '
            . ' Ensure RRDs is correctly implemented, refer to rrdtool documentation.'
            . ' Ensure the file="'
            . $ENV{'PWD'}
            . $sl
            . $test_file
            . '" exists.' )
        if ( !defined($chk_rrds) );
    &debug('main      |RRDs can access rrdtool');
}

#________ Verify the Config file values _________________________________________________
#
# Verifying the attribute variables
if ( defined( $cfg->{attributes}->{in_file} ) ) {
    if ( -r $cfg->{attributes}->{in_file} ) {
        &debug(   'main      |Valid <attributes in_file="'
                . $cfg->{attributes}->{in_file}
                . '">.' );
        if ( !defined $cfg->{attributes}->{out_file} ) {
            $cfg->{attributes}->{out_file} = 'attribute.xml';
            print_log(
                'Warning   |<attributes out_file=""> value not defined. Using default="'
                    . $cfg->{attributes}->{out_file}
                    . '"' );
        }
        if ( !defined $cfg->{attributes}->{frequency} ) {
            $cfg->{attributes}->{frequency} = 24;
            print_log(
                'Warning   |<attributes frequency=""> not defined. Using default="'
                    . $cfg->{attributes}->{frequency}
                    . '" hrs.' );
        }
        elsif ( $cfg->{attributes}->{frequency} !~ /^\d+$/ ) {    # is numeric
            $cfg->{attributes}->{frequency} = 24;
            print_log(
                'Warning   |<attributes frequency=""> is not a natural number. Using default="'
                    . $cfg->{attributes}->{frequency}
                    . '" hrs.' );
        }
        else {
            &debug(   'main      |Valid <attributes frequency="'
                    . $cfg->{attributes}->{frequency}
                    . '"> hrs.' );
        }
    }
    else {
        die_log(  'ERROR     |Could not read the <attributes in_file="'
                . $cfg->{attributes}->{in_file} . '" ('
                . $!
                . ') Please check full path and permissions and that the file exists.'
        );
    }
}

# Verify the alert file is defined
die_log(  'ERROR     |<alert file=""> not defined in the config file "'
        . $configfile
        . '".' )
    if ( !defined( $cfg->{alert}->{file} ) );
&debug( 'main      |Valid <alert file="' . $cfg->{alert}->{file} . '">.' );

# Verify the default frequency is valid
if ( !defined $cfg->{default}->{frequency} ) {    # is defined
    $cfg->{default}->{frequency} = 300;
    print_log(
              'Warning   |<default frequency=""> not defined. Using default="'
            . $cfg->{default}->{frequency}
            . '" seconds' );
}
elsif ( $cfg->{default}->{frequency} !~ /^\d+$/ ) {    # is numeric
    $cfg->{default}->{frequency} = 300;
    print_log(
        'Warning   |<default frequency=""> is not a natural number. Using default="'
            . $cfg->{default}->{frequency}
            . '" seconds' );
}
elsif (( $cfg->{default}->{frequency} >= 30 )
    && ( $cfg->{default}->{frequency} <= 86400 ) )
{                                                      # is within range
    &debug(   'main      |Valid <default frequency="'
            . $cfg->{default}->{frequency}
            . '"> seconds' );
}
else {
    $cfg->{default}->{frequency} = 300;
    print_log('Warning   |Invalid <default frequency="">. Using default="'
            . $cfg->{default}->{frequency}
            . '" seconds' );
}

# Verify the rrd step timeout is valid
if ( !defined $cfg->{rrdstep}->{timeout} ) {    # is defined
    $cfg->{rrdstep}->{timeout} = 2;
}
elsif ( $cfg->{rrdstep}->{timeout} !~ /^\d+\.?\d*$/ ) {    # is numeric
    $cfg->{rrdstep}->{timeout} = 2;
    print_log(
        'Warning   |<rrdstep timeout=""> is not a positive decimal number.'
            . ' Using default(2)="'
            . $cfg->{rrdstep}->{timeout}
            . '".' );
}
elsif (( $cfg->{rrdstep}->{timeout} > 1 )
    && ( $cfg->{rrdstep}->{timeout} <= 2 ) )
{                                                          # is within range
    &debug(   'main      |Valid <rrdstep timeout="'
            . $cfg->{rrdstep}->{timeout}
            . '">.' );
}
else {
    $cfg->{rrdstep}->{timeout} = 2 * $cfg->{default}->{frequency};
    print_log('Warning   |Invalid <rrdstep timeout="">. Using default(2)="'
            . $cfg->{rrdstep}->{timeout}
            . '".' );
}

# Verify the timeout is valid
if ( !defined $cfg->{default}->{timeout} ) {    # is defined
    $cfg->{default}->{timeout} = 4;
}
elsif ( $cfg->{default}->{timeout} !~ /^\d+$/ ) {    # is numeric
    $cfg->{default}->{timeout} = 4;
    print_log(
        'Warning   |<default timeout=""> is not a natural number. Using default="'
            . $cfg->{default}->{timeout}
            . '" seconds' );
}
elsif (( $cfg->{default}->{timeout} >= 1 )
    && ( $cfg->{default}->{timeout} <= 20 ) )
{                                                    # is within range
    &debug(   'main      |Valid <default timeout="'
            . $cfg->{default}->{timeout}
            . '"> seconds' );
}
else {
    $cfg->{default}->{timeout} = 4;
    print_log('Warning   |Invalid <default timeout="">. Using default="'
            . $cfg->{default}->{timeout}
            . '" seconds' );
}

# Verifying the ping file variable
if ( !defined( $cfg->{ping}->{file} ) ) {
    &debug(   'main      |<ping file=""> not defined in configuration file.'
            . ' Using net-ping.' );
    $cfg->{ping}->{file} = q{};
}
else {
    &debug( 'main      |<ping file="' . $cfg->{ping}->{file} . '"> defined' );
    if ( ( -r $cfg->{ping}->{file} ) && ( -x $cfg->{ping}->{file} ) ) {
        &debug(
            'main      |Valid <ping file="' . $cfg->{ping}->{file} . '">.' );
    }
    else {
        print_log('Warning   |Could not read the <ping file="'
                . $cfg->{ping}->{file} . '"> ('
                . $!
                . ') Please check full path and permissions and that the file exists.'
                . ' Using net-ping.' );
        $cfg->{ping}->{file} = q{};
    }
}

# Verify the snmp timeout is valid
if ( !defined $cfg->{snmp}->{retries} ) {    # is defined
    $cfg->{snmp}->{retries} = 2;
}
elsif ( $cfg->{snmp}->{retries} !~ /^\d+$/ ) {    # is numeric
    $cfg->{snmp}->{retries} = 2;
    print_log(
        'Warning   |<snmp retries=""> is not a natural number. Using default="'
            . $cfg->{snmp}->{retries}
            . '".' );
}
elsif (( $cfg->{snmp}->{retries} >= 1 )
    && ( $cfg->{snmp}->{retries} <= 10 ) )
{                                                 # is within range
    &debug(   'main      |Valid <snmp retries="'
            . $cfg->{snmp}->{retries}
            . '">.' );
}
else {
    $cfg->{snmp}->{retries} = 2;
    print_log('Warning   |Invalid <snmp retries="">. Using default="'
            . $cfg->{snmp}->{retries}
            . '".' );
}

# Verify the snmp port is valid
if ( !defined $cfg->{snmp}->{port} ) {    # is defined
    $cfg->{snmp}->{port} = 161;
}
elsif ( $cfg->{snmp}->{port} !~ /^\d+$/ ) {    # is numeric
    $cfg->{snmp}->{port} = 161;
    print_log(
        'Warning   |<snmp port=""> is not a natural number. Using default="'
            . $cfg->{snmp}->{port}
            . '".' );
}

# Ensure the graph folder is defined
if ( !defined $cfg->{graph}->{folder} ) {      # is defined
    $cfg->{graph}->{folder} = 'graphs';
}

# Verify the log purge is valid
if ( !defined $cfg->{log}->{purge} ) {         # is defined
    $cfg->{log}->{purge} = 14;
}
elsif ( $cfg->{log}->{purge} !~ /^\d+$/ ) {    # is numeric
    $cfg->{log}->{purge} = 14;
    print_log(
        'Warning   |<log purge=""> is not a natural number. Using default="'
            . $cfg->{log}->{purge}
            . '" days' );
}
elsif ( ( $cfg->{log}->{purge} >= 1 ) && ( $cfg->{log}->{purge} <= 90 ) )
{                                              # is within range
    &debug(
        'main      |Valid <log purge="' . $cfg->{log}->{purge} . '"> days' );
}
else {
    $cfg->{log}->{purge} = 7;
    &debug(   'Warning   |<log purge=""> out of valid range. Using default="'
            . $cfg->{log}->{purge}
            . '" days' );
}

# Verify the mail server is valid
if ( !defined $cfg->{mail}->{server} ) {       # is not defined
    print_log('Warning   |<mail server=""> is not configured.'
            . ' No e-mail alerts will be sent.' );
}
else {                                         # validate server
    die_log(  'ERROR     |Invalid <mail server="'
            . $cfg->{mail}->{server}
            . '"> in config file' )
        unless ( $cfg->{mail}->{server} =~ m/^[a-zA-Z0-9._-]+$/ );
    &debug(
        'main      |Valid <mail server="' . $cfg->{mail}->{server} . '">.' );

    # test to see if a connection can be made to the mail server
    my $smtp = Net::SMTP->new( $cfg->{mail}->{server} );
    if ( !defined($smtp) ) {
        print_log('main      |Unable to connect to <mail server="'
                . $cfg->{mail}->{server}
                . '"> E-mail alerts may not be able to be sent in the future.'
        );
    }
    else {
        $smtp->quit();
    }
}

# Verify the mail from is valid
# Use "snm@example.com" unless valid
if ( !defined $cfg->{mail}->{from} ) {
    $cfg->{mail}->{from} = 'snm@example.com';
}
else {    # is defined
    die_log(  'ERROR     |Invalid <mail value="'
            . $cfg->{mail}->{from}
            . '">. Must be a valid email address.' )

        # http://www.regexlib.com/REDetails.aspx?regexp_id=333
        # reference for the email regex.
        unless ( $cfg->{mail}->{from}
        =~ /^[\w](([_\.-]?[\w]+)*)@([\w]+)(([\.-]?[\w]+)*)\.([A-Za-z]{2,})$/
        );
    &debug( 'main      |Valid <mail from="' . $cfg->{mail}->{from} . '">.' );
}

# Verify mail server password is defined if username is defined
if ( defined $cfg->{mail}->{username} ) {
    die_log(  'ERROR     | <mail ... password="">. '
            . 'Must be defined if username="" is defined.' )

        # http://www.regexlib.com/REDetails.aspx?regexp_id=333
        # reference for the email regex.
        unless ( defined $cfg->{mail}->{password} );
    &debug(   'main      |Authentication to mail server,'
            . ' username and password are defined.' );
}

# Verify the web directory is defined
die_log(  'ERROR     |<web directory=""> not defined in the config file "'
        . $configfile
        . '"' )
    if ( !defined( $cfg->{web}->{directory} ) );

# If the last character in web}->{directory is not / or \, then append $sl
if ( $cfg->{web}->{directory} !~ /[\/\\]$/ ) {
    $cfg->{web}->{directory} .= $sl;
}
&debug(
    'main      |Web directory="' . $cfg->{web}->{directory} . '" defined' );

#_________load attributes discovery____________________________________________
my $attrib_in;
if ( defined( $cfg->{attributes}->{in_file} ) ) {
    &debug(   'main      |Attributes in-file="'
            . $cfg->{attributes}->{in_file}
            . '" defined' );
    $attrib_in = eval {
        XMLin(
            $cfg->{attributes}->{in_file},
            ForceArray =>
                [ 'suite', 'table', 'value', 'column', 'translate' ],
            KeyAttr => ''
        );
    };
    die_log(  'ERROR     |Error when evaluating <attributes in-file="'
            . $cfg->{attributes}->{in_file} . '">  ('
            . $@
            . ')' )
        if ($@);
    &debug('main      |Attributes in-file loaded sucessfully');
}

# Validate the attribute values _____________________________________________
# use Data::Dumper;
# print Dumper($tgt);
my %suite_idx = ();    # suite index

if ( defined( $cfg->{attributes}->{in_file} ) ) {

    #for each suite
    for ( my $s_n = 0; $s_n <= $#{ $attrib_in->{suite} }; $s_n++ ) {

        # verify the suite id is valid
        if ( !defined $attrib_in->{suite}[$s_n]->{id} ) {
            die_log(  'ERROR     |id= not defined for attribute <suite #'
                    . ( $s_n + 1 )
                    . ' > in file "'
                    . $cfg->{attributes}->{in_file}
                    . '"' );
        }
        else {
            die_log(  'ERROR     |Invalid id for attribute <suite id="'
                    . $attrib_in->{suite}[$s_n]->{id}
                    . '"> in file "'
                    . $cfg->{attributes}->{in_file}
                    . '". Only valid characters are "a-zA-Z0-9_.-"' )
                unless ( $attrib_in->{suite}[$s_n]->{id} =~ m/^[\w\.-]+$/ );
            die_log(  'ERROR     |Invalid id= for attribute <suite id="'
                    . $attrib_in->{suite}[$s_n]->{id}
                    . '"> in file "'
                    . $cfg->{attributes}->{in_file}
                    . '". id= must be between 1-36 characters in length.' )
                if ( $attrib_in->{suite}[$s_n]->{id} =~ m/.{37,}/ );
        }

        # ___Check the suite id is unique
        if ( defined( $suite_idx{ $attrib_in->{suite}[$s_n]->{id} } ) ) {
            die_log(  'ERROR     |<suite id="'
                    . $attrib_in->{suite}[$s_n]->{id}
                    . '"> is not unique in file "'
                    . $cfg->{attributes}->{in_file}
                    . '"' );
        }
        $suite_idx{ $attrib_in->{suite}[$s_n]->{id} } = $s_n;

        # validate all attribute values
        for (
            my $v_n = 0;
            $v_n <= $#{ $attrib_in->{suite}[$s_n]->{value} };
            $v_n++
            )
        {
            if ( !defined $attrib_in->{suite}[$s_n]->{value}[$v_n]
                ->{description} )
            {
                die_log(  'ERROR     |description= not defined for <value #'
                        . ( $v_n + 1 )
                        . ' > in attribute <suite id="'
                        . $attrib_in->{suite}[$s_n]->{id}
                        . '"> in file "'
                        . $cfg->{attributes}->{in_file}
                        . '"' );
            }
            if ( !defined $attrib_in->{suite}[$s_n]->{value}[$v_n]->{oid} ) {
                die_log(
                    'ERROR     |oid= not defined for <value description="'
                        . $attrib_in->{suite}[$s_n]->{value}[$v_n]
                        ->{description}
                        . '"> in attribute <suite id="'
                        . $attrib_in->{suite}[$s_n]->{id}
                        . '"> in file "'
                        . $cfg->{attributes}->{in_file}
                        . '"' );
            }
            if ( defined $attrib_in->{suite}[$s_n]->{value}[$v_n]->{convert} )
            {
                die_log(  'ERROR     |Illegal value for <value convert="'
                        . $attrib_in->{suite}[$s_n]->{value}[$v_n]->{convert}
                        . '"> in attribute <suite id="'
                        . $attrib_in->{suite}[$s_n]->{id}
                        . '"> in file "'
                        . $cfg->{attributes}->{in_file}
                        . '". Valid conversion is "date"' )
                    unless (
                    $attrib_in->{suite}[$s_n]->{value}[$v_n]->{convert}
                    =~ m/^date$/i );
            }
            if (defined $attrib_in->{suite}[$s_n]->{value}[$v_n]
                ->{calculate} )
            {
                die_log( 'ERROR     |Illegal character in <value calculate="'
                        . $attrib_in->{suite}[$s_n]->{value}[$v_n]
                        ->{calculate}
                        . '"> in attribute <suite id="'
                        . $attrib_in->{suite}[$s_n]->{id}
                        . '"> in file "'
                        . $cfg->{attributes}->{in_file}
                        . '". Valid characters are "0-9.,-+*/eE"' )
                    unless (
                    $attrib_in->{suite}[$s_n]->{value}[$v_n]->{calculate}
                    =~ m/^[\d\.\,\-\+\*\/eE]+$/ );
            }

            # validate all attribute translates
            for (
                my $tr_n = 0;
                $tr_n <= $#{ $attrib_in->{suite}[$s_n]->{value}[$v_n]
                        ->{translate} };
                $tr_n++
                )
            {
                if ( !defined $attrib_in->{suite}[$s_n]->{value}[$v_n]
                    ->{translate}[$tr_n]->{value} )
                {
                    die_log(
                        'ERROR     |<translate value=""> not defined for '
                            . '<value description="'
                            . $attrib_in->{suite}[$s_n]->{value}[$v_n]
                            ->{description}
                            . '"> in attribute <suite id="'
                            . $attrib_in->{suite}[$s_n]->{id}
                            . '"> in file "'
                            . $cfg->{attributes}->{in_file}
                            . '"' );
                }
                if ( !defined $attrib_in->{suite}[$s_n]->{value}[$v_n]
                    ->{translate}[$tr_n]->{text} )
                {
                    die_log( 'ERROR     |<translate text=""> not defined for '
                            . '<value description="'
                            . $attrib_in->{suite}[$s_n]->{value}[$v_n]
                            ->{description}
                            . '"> in attribute <suite id="'
                            . $attrib_in->{suite}[$s_n]->{id}
                            . '"> in file "'
                            . $cfg->{attributes}->{in_file}
                            . '"' );
                }
            }    # for ( my $tr_n...
        }    # for ( my $v_n...

        # validate all attribute tables
        for (
            my $t_n = 0;
            $t_n <= $#{ $attrib_in->{suite}[$s_n]->{table} };
            $t_n++
            )
        {
            if ( !defined $attrib_in->{suite}[$s_n]->{table}[$t_n]
                ->{description} )
            {
                die_log(  'ERROR     |description= not defined for <table #'
                        . ( $t_n + 1 )
                        . ' > in attribute <suite id="'
                        . $attrib_in->{suite}[$s_n]->{id}
                        . '"> in file "'
                        . $cfg->{attributes}->{in_file}
                        . '"' );
            }

            # validate all attribute columns
            for (
                my $c_n = 0;
                $c_n
                <= $#{ $attrib_in->{suite}[$s_n]->{table}[$t_n]->{column} };
                $c_n++
                )
            {
                if ( !defined $attrib_in->{suite}[$s_n]->{table}[$t_n]
                    ->{column}[$c_n]->{description} )
                {
                    die_log(  'ERROR     |description= not defined for '
                            . 'a <column> in <table description="'
                            . $attrib_in->{suite}[$s_n]->{table}[$t_n]
                            ->{description}
                            . '"> in attribute <suite id="'
                            . $attrib_in->{suite}[$s_n]->{id}
                            . '"> in file "'
                            . $cfg->{attributes}->{in_file}
                            . '"' );
                }
                if ( !defined $attrib_in->{suite}[$s_n]->{table}[$t_n]
                    ->{column}[$c_n]->{oid} )
                {
                    die_log(  'ERROR     |oid= not defined for '
                            . 'a <column> in <table description="'
                            . $attrib_in->{suite}[$s_n]->{table}[$t_n]
                            ->{description}
                            . '"> in attribute <suite id="'
                            . $attrib_in->{suite}[$s_n]->{id}
                            . '"> in file "'
                            . $cfg->{attributes}->{in_file}
                            . '"' );
                }
                if (defined $attrib_in->{suite}[$s_n]->{table}[$t_n]
                    ->{column}[$c_n]->{convert} )
                {
                    die_log( 'ERROR     |Illegal value for <value convert="'
                            . $attrib_in->{suite}[$s_n]->{table}[$t_n]
                            ->{column}[$c_n]->{convert}
                            . '"> in attribute <suite id="'
                            . $attrib_in->{suite}[$s_n]->{id}
                            . '"> in file "'
                            . $cfg->{attributes}->{in_file}
                            . '". Valid conversion is "date"' )
                        unless ( $attrib_in->{suite}[$s_n]->{table}[$t_n]
                        ->{column}[$c_n]->{convert} =~ m/^date$/i );
                }
                if (defined $attrib_in->{suite}[$s_n]->{table}[$t_n]
                    ->{column}[$c_n]->{calculate} )
                {
                    die_log(
                        'ERROR     |Illegal character in <value calculate="'
                            . $attrib_in->{suite}[$s_n]->{table}[$t_n]
                            ->{column}[$c_n]->{calculate}
                            . '"> in attribute <suite id="'
                            . $attrib_in->{suite}[$s_n]->{id}
                            . '"> in file "'
                            . $cfg->{attributes}->{in_file}
                            . '". Valid characters are: 0-9.,-+*/eE' )
                        unless ( $attrib_in->{suite}[$s_n]->{table}[$t_n]
                        ->{column}[$c_n]->{calculate}
                        =~ m/^[\d\.\,\-\+\*\/eE]+$/ );
                }

                # validate all attribute translates
                for (
                    my $tr_n = 0;
                    $tr_n <= $#{
                        $attrib_in->{suite}[$s_n]->{table}[$t_n]
                            ->{column}[$c_n]->{translate}
                    };
                    $tr_n++
                    )
                {
                    if ( !defined $attrib_in->{suite}[$s_n]->{table}[$t_n]
                        ->{column}[$c_n]->{translate}[$tr_n]->{value} )
                    {
                        die_log(
                            'ERROR     |<translate value=""> not defined for '
                                . 'a <column> in <table description="'
                                . $attrib_in->{suite}[$s_n]->{table}[$t_n]
                                ->{description}
                                . '"> in attribute <suite id="'
                                . $attrib_in->{suite}[$s_n]->{id}
                                . '"> in file "'
                                . $cfg->{attributes}->{in_file}
                                . '"' );
                    }
                    if ( !defined $attrib_in->{suite}[$s_n]->{table}[$t_n]
                        ->{column}[$c_n]->{translate}[$tr_n]->{text} )
                    {
                        die_log(
                            'ERROR     |<translate text=""> not defined for '
                                . 'a <column> in <table description="'
                                . $attrib_in->{suite}[$s_n]->{table}[$t_n]
                                ->{description}
                                . '"> in attribute <suite id="'
                                . $attrib_in->{suite}[$s_n]->{id}
                                . '"> in file "'
                                . $cfg->{attributes}->{in_file}
                                . '"' );
                    }
                }    # for ( my $tr_n...
            }    # for ( my $c_n...
        }    # for ( my $t_n...
    }    # for ( my $s_n...
    &debug('main      |Attributes in-file validated');
}

# Defining the $targetfile variable____________________________________________
die_log(  'ERROR     |<target file=""> not defined in the config file "'
        . $configfile
        . '"' )
    if ( not defined( $cfg->{target}[0]->{file} ) );
my %tgt_idx = ();    # target index
my %tmp_idx = ();    # template index in each target
my %mod_idx = ();    # hash of unique modules
my $n_g     = 0;     # number of targets-1
my $n_e     = 0;     # number of templates-1
my $n_i     = 0;     # number of interfaces-1
my %tt      = ();    # hash of target-templates
my $n       = 0;     # index of target-templates,
my $next_sched;      # the time of the next scheduled query,
my %alert_status     = ();
my $alert_print_flag = 0;
my $metricid;
my ( $met_criteria, $met_val,  $met_alert_num );
my ( $if_al_th,     $if_email, $alert_on_up );
my $target;
my $rrd_lastupdate;    # the last update as collected from the RRD file
my $ATTRIBUTE_FREQUENCY = 3600;    # 1 hr (in seconds)
my $attrib_menu;

for ( my $t = 0; $t <= $#{ $cfg->{target} }; $t++ ) {    #for each target file
    &debug(   'main      |Target file "'
            . $cfg->{target}[$t]->{file}
            . '" defined' );

    # Verify if the target file exists/readable/type
    my $tgt = eval {
        XMLin(
            $cfg->{target}[$t]->{file},
            ForceArray => [ 'target', 'template', 'interface' ],
            KeyAttr    => ''
        );
    };
    die_log( 'ERROR     |Error loading target file:' . $@ )
        if ($@);
    &debug('main      |Target file loaded successfully');

# Validate the Target file values _____________________________________________
# use Data::Dumper;
# print Dumper($tgt);

    # subroutine to validate is a number.
    sub check_int {
        my ( $cinum_desc, $cinum_val ) = @_;
        die_log(  'ERROR     |Invalid '
                . $cinum_desc . ': "'
                . $cinum_val
                . '" for interface="'
                . $tgt->{target}[$n_g]->{template}[$n_e]->{interface}[$n_i]
                ->{int}
                . '" for target="'
                . $tgt->{target}[$n_g]->{id}
                . '" in the target file. '
                . $cinum_desc
                . ' must be a number.' )
            if ( $cinum_val
            !~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ );
        return;
    }

    #for each target
    for ( $n_g = 0; $n_g <= $#{ $tgt->{target} }; $n_g++ ) {

        # verify the target id is valid
        if ( !defined $tgt->{target}[$n_g]->{id} ) {
            die_log(  'ERROR     |id= not defined for <target #'
                    . ( $n_g + 1 )
                    . ' >.' );
        }
        else {
            die_log(  'ERROR     |Invalid id= for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '">. Only valid characters are "a-zA-Z0-9_.-"' )
                unless ( $tgt->{target}[$n_g]->{id} =~ m/^[\w\.-]+$/ );
            die_log(  'ERROR     |Invalid id= for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '">. Must be between 1-36 characters in length.' )
                if ( $tgt->{target}[$n_g]->{id} =~ m/.{37,}/ );
        }

        # verify the IP address is valid
        if ( !defined $tgt->{target}[$n_g]->{ip_address} ) {
            die_log(  'ERROR     |ip_address= not defined for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '">.' );
        }

        # ___Check the target id is unique
        if ( defined( $tgt_idx{ $tgt->{target}[$n_g]->{id} } ) ) {
            die_log(  'ERROR     |<target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '"> is not unique in "'
                    . $cfg->{target}[$t]->{file}
                    . '"' );
        }
        $tgt_idx{ $tgt->{target}[$n_g]->{id} } = $n_g;

        # verify the community is valid
        if ( defined $tgt->{target}[$n_g]->{community} ) {
            die_log(
                'ERROR     |Missing or invalid community= for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '">.' )
                unless ( $tgt->{target}[$n_g]->{community} =~ m/.{1,}/ );
            die_log(  'ERROR     |Invalid community= for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '". Must be between 1-36 characters in length.' )
                if ( $tgt->{target}[$n_g]->{community} =~ m/.{37,}/ );
        }

        # verify the username is valid
        if ( defined $tgt->{target}[$n_g]->{username} ) {
            die_log(
                'ERROR     |Missing or invalid username= for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '">.' )
                unless ( $tgt->{target}[$n_g]->{username} =~ m/.{1,}/ );
            die_log(  'ERROR     |Invalid username= for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '". Must be between 1-36 characters in length.' )
                if ( $tgt->{target}[$n_g]->{username} =~ m/.{37,}/ );
        }

        # verify the attributes=no or =suite id
        if (   defined $cfg->{attributes}->{in_file}
            && defined $tgt->{target}[$n_g]->{attributes} )
        {

            # loop through attributes array, check each is 'no' or a suite
            my @s_att;
            my @orig_att = split( /,/, $tgt->{target}[$n_g]->{attributes} );
            foreach my $attr (@orig_att) {
                $attr =~ s/^\s+//;    # strip leading spaces
                $attr =~ s/\s+$//;    # strip trailing spaces
                if ( $attr =~ m/^(n|no)$/i ) {
                    @s_att = ();
                    last;
                }
                elsif ( !defined( $suite_idx{$attr} ) ) {

                    # $tgt->{target}[$n_g]->{attributes} = 'no';
                    print_log(
                        'Warning   |Invalid attributes="" for <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '">. Must be either "no" or match'
                            . ' attributes in <suite id="">. Skipping "'
                            . $attr
                            . '"' );
                }
                else {
                    push( @s_att, $suite_idx{$attr} );
                }
            }
            $tgt->{target}[$n_g]->{attributes} = [@s_att];
        }
        else {
            $tgt->{target}[$n_g]->{attributes} = [0];
        }

        # verify the version is valid
        if ( defined $tgt->{target}[$n_g]->{version} ) {
            if ( $tgt->{target}[$n_g]->{version} !~ m/^(1|2|3)$/ ) {
                $tgt->{target}[$n_g]->{version} = 1;
                print_log('Warning   |Invalid version= for <target id="'
                        . $tgt->{target}[$n_g]->{id}
                        . '">, using default version="'
                        . $tgt->{target}[$n_g]->{version}
                        . '"' );
            }
        }
        else {
            $tgt->{target}[$n_g]->{version} = 1;
        }

        # Verify the target port is valid
        # Use cfg->{snmp}->{port} unless tgt->{target}[$n_g]->{port} is valid
        if ( !defined $tgt->{target}[$n_g]->{port} ) {
            $tgt->{target}[$n_g]->{port} = $cfg->{snmp}->{port};
        }
        else {    # is defined
            die_log(  'ERROR     |Invalid port= for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '">. Must be a natural number.' )
                unless ( $tgt->{target}[$n_g]->{port} =~ /^\d+$/ )
                ;    # is numeric
        }

        # Verify the alert is valid
        # if alert is defined, validate it; x:y where:
        # x = the criteria = a number, and
        # y = an e-mail address.
        # refer to http://www.quanetic.com/regex.php
        if ( defined( $tgt->{target}[$n_g]->{alert} ) ) {

            # validate the format "x:y"
            my ( $inf_alert_num, $inf_email ) =
                split( /:/, $tgt->{target}[$n_g]->{alert}, 2 );
            if ( ( !defined $inf_alert_num ) || ( !defined $inf_email ) ) {
                die_log(  'ERROR     |alert="'
                        . $tgt->{target}[$n_g]->{alert}
                        . '" for <target id="'
                        . $tgt->{target}[$n_g]->{id}
                        . '"> in the target file.'
                        . ' Format must be: "number_alerts:e-mail_address"' );
            }
            $inf_alert_num =~ s/U$//i;    # strip any trailing U or u
                 # Use cfg->{alert} unless target->{alert} is valid
            die_log(  'ERROR     |Invalid alert= threshold for <target id="'
                    . $tgt->{target}[$n_g]->{id}
                    . '">. Must be a natural number.' )
                unless ( $inf_alert_num =~ /^\d+$/i );    # is numeric
            die_log(  'ERROR     |Invalid alert= threshold for <target id="'
                    . $tgt->{target}[$n_g]->{id} . ""
                    . '">. Must be between 1 and 999.' )
                unless ( ( $inf_alert_num >= 1 )
                && ( $inf_alert_num <= 999 ) );           # is within range

            # Verify the alert_emails are valid
            my @emails = split( /[;,]/, $inf_email );
            foreach my $an_email (@emails) {
                die_log(  'ERROR     |Invalid alert email value "'
                        . $an_email
                        . '" for <target id="'
                        . $tgt->{target}[$n_g]->{id}
                        . '">. Must be a valid email address.' )

             # reference: http://www.regexlib.com/REDetails.aspx?regexp_id=333
             # for the email regex.
                    unless ( $an_email
                    =~ /^[\w](([_\.-]?[\w]+)*)@([\w]+)(([\.-]?[\w]+)*)\.([A-Za-z]{2,})$/
                    );
            }
        }
        else {
            $tgt->{target}[$n_g]->{alert} = '0:-';
        }

        # validate all target templates
        %tmp_idx = ();    # initialise target index
        for (
            $n_e = 0;
            $n_e <= $#{ $tgt->{target}[$n_g]->{template} };
            $n_e++
            )
        {

            # Verify a template->id exists
            if ( defined( $tgt->{target}[$n_g]->{template}[$n_e]->{id} ) ) {

                # Verify template->id is valid
                if ( $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                    =~ m/.{21,}/ )
                {
                    die_log(  'ERROR     |<template id="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                            . '"> in <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '">. Must be between 1-20 characters in length.'
                    );
                }
                elsif ( $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                    !~ m/^[\w-]+$/ )
                {
                    die_log(  'ERROR     |<template id="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                            . '"> in <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '">. Must only contain the characters "a-zA-Z0-9_-".'
                    );
                }
            }
            else {
                die_log(  'ERROR     |A template in <target id="'
                        . $tgt->{target}[$n_g]->{id}
                        . '" requires a mandatory id="".' );
            }

            # ___Check the template id is unique in each target
            if (defined(
                    $tmp_idx{ $tgt->{target}[$n_g]->{template}[$n_e]->{id} }
                )
                )
            {
                die_log(  'ERROR     |<template id="'
                        . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                        . '"> is not unique in <target id="'
                        . $tgt->{target}[$n_g]->{id}
                        . '">.' );
            }
            $tmp_idx{ $tgt->{target}[$n_g]->{template}[$n_e]->{id} } = $n_e;

            # Verify a ping, oid or module exists for each template
            unless ( defined( $tgt->{target}[$n_g]->{template}[$n_e]->{ping} )
                || defined( $tgt->{target}[$n_g]->{template}[$n_e]->{oid} )
                || defined( $tgt->{target}[$n_g]->{template}[$n_e]->{module} )
                )
            {
                die_log( 'ERROR     |A ping=, oid= or module= is not defined '
                        . 'in <template id="'
                        . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                        . '"> for the <target id="'
                        . $tgt->{target}[$n_g]->{id}
                        . '">.' );
            }

            # if oid:
            # verify community defined for v1 & v2
            # or username defined for v3
            if ( defined( $tgt->{target}[$n_g]->{template}[$n_e]->{oid} ) ) {
                if (   ( $tgt->{target}[$n_g]->{version} =~ m/^(1|2)$/ )
                    && ( !defined( $tgt->{target}[$n_g]->{community} ) ) )
                {
                    die_log(  'ERROR     |snmp community= is required but '
                            . 'not defined for the <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '">.' );
                }
                if (   ( $tgt->{target}[$n_g]->{version} == 3 )
                    && ( !defined( $tgt->{target}[$n_g]->{username} ) ) )
                {
                    die_log(  'ERROR     |snmp username= is required but '
                            . 'not defined for the <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '">.' );
                }
            }

            # Validate modules
            if ( defined( $tgt->{target}[$n_g]->{template}[$n_e]->{module} ) )
            {

                # validate :: is in the module
                if ( $tgt->{target}[$n_g]->{template}[$n_e]->{module}
                    =~ m/::/ )
                {
                    my @mod_split =
                        split( /::/,
                        $tgt->{target}[$n_g]->{template}[$n_e]->{module} );

                    # Add this to the hash of modules to be loaded
                    $mod_idx{ $mod_split[0] } = 1;
                }
                else {
                    die_log(  'ERROR     |module="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]->{module}
                            . '" in <template id="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                            . '"> in <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> is incorrectly formatted.'
                            . ' Must contain the characters "::".' );
                }
            }

            # Validate ping
            if ( defined( $tgt->{target}[$n_g]->{template}[$n_e]->{ping} ) ) {
                if ( $tgt->{target}[$n_g]->{template}[$n_e]->{ping}
                    !~ /^\d+$/ )
                {    # is numeric
                    $tgt->{target}[$n_g]->{template}[$n_e]->{ping} = 4;
                    print_log('Warning   |In <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> the ping value is not a natural number. '
                            . 'Using default value="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]->{ping}
                            . '"' );
                }
                elsif (( $tgt->{target}[$n_g]->{template}[$n_e]->{ping} < 1 )
                    || ( $tgt->{target}[$n_g]->{template}[$n_e]->{ping} > 20 )
                    )
                {
                    $tgt->{target}[$n_g]->{template}[$n_e]->{ping} = 4;
                    print_log('Warning   |In <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> the ping value must be between 1 and 20. '
                            . 'Using default value="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]->{ping}
                            . '"' );
                }
            }

            # Validate oid
            if ( defined( $tgt->{target}[$n_g]->{template}[$n_e]->{oid} ) ) {
                if ( $tgt->{target}[$n_g]->{template}[$n_e]->{oid}
                    !~ m/^[\d\.int]+$/ )
                {
                    print_log('Warning   |In <template id="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                            . '"> of <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> the oid= is not a valid format.' );
                }
            }

            #___Verify data_source_type is valid
            if ( !defined $tgt->{target}[$n_g]->{template}[$n_e]
                ->{data_source_type} )
            {
                $tgt->{target}[$n_g]->{template}[$n_e]->{data_source_type}
                    = "COUNTER";
            }
            elsif (
                uc( $tgt->{target}[$n_g]->{template}[$n_e]->{data_source_type}
                ) =~ /^(GAUGE|DERIVE|ABSOLUTE)$/i
                )
            {
                $tgt->{target}[$n_g]->{template}[$n_e]->{data_source_type}
                    = uc( $tgt->{target}[$n_g]->{template}[$n_e]
                        ->{data_source_type} );
            }
            else {
                $tgt->{target}[$n_g]->{template}[$n_e]->{data_source_type}
                    = "COUNTER";
            }

            # if 'frequency' is not defined,
            # then set it to the default $cfg->{default}->{frequency}
            if (!defined $tgt->{target}[$n_g]->{template}[$n_e]->{frequency} )
            {
                $tgt->{target}[$n_g]->{template}[$n_e]->{frequency}
                    = $cfg->{default}->{frequency};
            }
            else {

                # validate frequency is numeric
                die_log(  'ERROR     |Invalid frequency="'
                        . $tgt->{target}[$n_g]->{template}[$n_e]->{frequency}
                        . '" for <template id="'
                        . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                        . '"> defined in <target id="'
                        . $tgt->{target}[$n_g]->{id}
                        . '">. Must be a natural number.' )
                    unless (
                    $tgt->{target}[$n_g]->{template}[$n_e]->{frequency}
                    =~ /^\d+$/ );

                # validate is between 60 and 3600 seconds, inclusive
                die_log(  'ERROR     |<template id="'
                        . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                        . '"> defined in <target id="'
                        . $tgt->{target}[$n_g]->{id}
                        . '"> has an invalid frequency="'
                        . $tgt->{target}[$n_g]->{template}[$n_e]->{frequency}
                        . '". The valid range is 60 to 3600 seconds.' )
                    if (
                    (   $tgt->{target}[$n_g]->{template}[$n_e]->{frequency}
                        > 3600
                    )
                    || ( $tgt->{target}[$n_g]->{template}[$n_e]->{frequency}
                        < 60 )
                    );
            }

    # verify the frequency and DataSourceType in the RRD file using RRDs:info.
    # if the RRD file does not exist, skip it as it will be created later
            my $tune;
            my $rrd_to_validate = $cfg->{web}->{directory}
                . $tgt->{target}[$n_g]->{id}
                . $sl
                . $tgt->{target}[$n_g]->{template}[$n_e]->{id} . '.rrd';
            my $rrd_info = RRDs::info($rrd_to_validate);
            if ( defined $rrd_info ) {
                if ( defined $rrd_info->{step} ) {
                    if ( $tgt->{target}[$n_g]->{template}[$n_e]->{frequency}
                        != $rrd_info->{step} )
                    {
                        die_log( 'ERROR     |The frequency= in the RRD file "'
                                . $cfg->{web}->{directory}
                                . $tgt->{target}[$n_g]->{id}
                                . $sl
                                . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                                . '.rrd" is "'
                                . $rrd_info->{step}
                                . '". This does not match the frequency in <target id="'
                                . $tgt->{target}[$n_g]->{id}
                                . '"> which is "'
                                . $tgt->{target}[$n_g]->{template}[$n_e]
                                ->{frequency}
                                . '". Either correct the <target frequency="">'
                                . ', or delete the RRD file and allow a new RRD to be created.'
                        );
                    }    # if ( $tgt...{frequency} != {step}
                }    # if ( defined ...{step}
            }    # if ( defined $rrd_info

            # if 'interface' is not defined, then set it to the default '0'
            if (!defined $tgt->{target}[$n_g]->{template}[$n_e]->{interface} )
            {
                $tgt->{target}[$n_g]->{template}[$n_e]->{interface}
                    = [ { 'int' => '0' } ];
            }

            # for each interface of each template of this target
            for (
                $n_i = 0;
                $n_i
                <= $#{ $tgt->{target}[$n_g]->{template}[$n_e]->{interface} };
                $n_i++
                )
            {

                # If int not defined, then define as "0"
                if (!defined(
                        $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int}
                    )
                    )
                {
                    $tgt->{target}[$n_g]->{template}[$n_e]->{interface}[$n_i]
                        ->{int} = 0;
                }
                else {
                    die_log( 'ERROR     |Invalid int="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int}
                            . '" for <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> in target file.'
                            . ' Format must be number.number.etc.' )
                        if ( $tgt->{target}[$n_g]->{template}[$n_e]
                        ->{interface}[$n_i]->{int} !~ /^(\d+\.)*\d+$/ );

                    die_log( 'ERROR     |Invalid int="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int}
                            . '" for <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> in target file.'
                            . ' int= must be 16 digits or less.' )
                        if (
                        length $tgt->{target}[$n_g]->{template}[$n_e]
                        ->{interface}[$n_i]->{int} > 16 );
                }

                # define 'int_nodot' for future use
                $tgt->{target}[$n_g]->{template}[$n_e]->{interface}[$n_i]
                    ->{int_nodot} = $tgt->{target}[$n_g]->{template}[$n_e]
                    ->{interface}[$n_i]->{int};
                $tgt->{target}[$n_g]->{template}[$n_e]->{interface}[$n_i]
                    ->{int_nodot} =~ s/\./d/g;

                # Validate data_source_type for each interface in the rrd file
                if (defined $rrd_info->{
                        'ds[ds'
                            . $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int_nodot} . '].type'
                    }
                    )
                {
                    if ($tgt->{target}[$n_g]->{template}[$n_e]
                        ->{data_source_type} ne $rrd_info->{
                            'ds[ds'
                                . $tgt->{target}[$n_g]->{template}[$n_e]
                                ->{interface}[$n_i]->{int_nodot} . '].type'
                        }
                        )
                    {
                        $tune = RRDs::tune(
                            $rrd_to_validate,
                            '--data-source-type',
                            (   'ds'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{int_nodot} . ':'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{data_source_type}
                            )
                        );
                        $ERR = RRDs::error;
                        if ($ERR) {
                            print_log(
                                'Warning   |Error updating data-source-type for rrd file: '
                                    . $rrd_to_validate . ' : '
                                    . $ERR );
                        }
                        else {
                            print_log(
                                'Update    |data-source-type from "'
                                    . $rrd_info->{
                                    'ds[ds'
                                        . $tgt->{target}[$n_g]
                                        ->{template}[$n_e]->{interface}[$n_i]
                                        ->{int_nodot} . '].type'
                                    }
                                    . '" to "'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{data_source_type}
                                    . '" for rrd file: "'
                                    . $rrd_to_validate . '"'
                            );
                        }
                    } # if ( $tgt...{data_source_type} != data_source_type in file
                }    # if ( defined ...{data_source_type}

                # if interface description not defined, define it as: " "
                if (!defined(
                        $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{description}
                    )
                    )
                {
                    $tgt->{target}[$n_g]->{template}[$n_e]->{interface}[$n_i]
                        ->{description} = ' ';
                }

           # if int_alert is defined, validate it; x:y:z where:
           # x = the criteria = 'lt', 'gt', 'le', 'ge', 'eq' or 'ne',
           # y = the metric value = a number, and
           # z = the number of concurrent failures before alerting = a number.
           # http://www.quanetic.com/regex.php
                if (defined(
                        $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int_alert}
                    )
                    )
                {

                    # validate the format "x:y:z"
                    my ( $met_criteria, $met_val, $met_alert_num ) =
                        split(
                        /:/,
                        $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int_alert},
                        3
                        );
                    if (   ( !defined $met_criteria )
                        || ( !defined $met_val )
                        || ( !defined $met_alert_num ) )
                    {
                        die_log( 'ERROR     |int_alert="'
                                . $tgt->{target}[$n_g]->{template}[$n_e]
                                ->{interface}[$n_i]->{int_alert}
                                . '" for <interface int="'
                                . $tgt->{target}[$n_g]->{template}[$n_e]
                                ->{interface}[$n_i]->{int}
                                . '"> for <target id="'
                                . $tgt->{target}[$n_g]->{id}
                                . '"> in the target file.'
                                . ' Format must be: "criteria:value:number_alerts"'
                        );
                    }

                    # validate x (criteria) is one of
                    # 'lt', 'gt', 'le', 'ge', 'eq' or 'ne'
                    die_log(  'ERROR     |Invalid int_alert "criteria": "'
                            . $met_criteria
                            . '" for <interface int="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int}
                            . '"> for <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> in the target file.'
                            . ' int_alert criteria must be: lt gt le ge eq or ne'
                        )
                        if ( $met_criteria !~ /^(lt|le|gt|ge|eq|ne)$/i );

                    # validate y (value) it is a number.
                    &check_int( 'int_alert value', $met_val );

              # Verify z (number_alerts) is numeric and within the range 1-999
                    die_log( 'ERROR     |Invalid int_alert "number_alerts": "'
                            . $met_alert_num
                            . '" for <interface int="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int}
                            . '"> for <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> in the target file.'
                            . ' Must be a natural number.' )
                        unless ( $met_alert_num =~ /^\d+$/ );    # is numeric
                    die_log( 'ERROR     |Invalid int_alert "number_alerts": "'
                            . $met_alert_num
                            . '" for <interface int="'
                            . $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{int}
                            . '"> for <target id="'
                            . $tgt->{target}[$n_g]->{id}
                            . '"> in the target file.'
                            . ' Must be between 1 and 999.' )
                        unless ( ( $met_alert_num >= 1 )
                        && ( $met_alert_num <= 999 ) );
                }    # if int_alert is defined

                # validate target 'input_max' it is a number.
                if (defined(
                        $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{input_max}
                    )
                    )
                {
                    &check_int( 'input_max',
                        $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{input_max} );
                }

                # validate target 'input_min' it is a number.
                if (defined(
                        $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{input_min}
                    )
                    )
                {
                    &check_int( 'input_min',
                        $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{interface}[$n_i]->{input_min} );
                }

                # validate .rrd files against input_max and input_min
                my $tune;
                my $print_update_max = 0;
                my $print_update_min = 0;
                my $rrd_to_validate  = $cfg->{web}->{directory}
                    . $tgt->{target}[$n_g]->{id}
                    . $sl
                    . $tgt->{target}[$n_g]->{template}[$n_e]->{id} . '.rrd';
                my $info = RRDs::info($rrd_to_validate);
                if ( defined $info ) {

                    # if input_max in rrd file is not defined (U) then
                    # validate against the template & update if required
                    if (!defined(
                            $$info{
                                'ds[ds'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{int_nodot} . '].max'
                                }
                        )
                        )
                    {
                        if (defined(
                                $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{input_max}
                            )
                            )
                        {
                            $print_update_max = 1;
                            $tune             = RRDs::tune(
                                $rrd_to_validate,
                                '--maximum',
                                (   'ds'
                                        . $tgt->{target}[$n_g]
                                        ->{template}[$n_e]->{interface}[$n_i]
                                        ->{int_nodot} . ':'
                                        . $tgt->{target}[$n_g]
                                        ->{template}[$n_e]->{interface}[$n_i]
                                        ->{input_max}
                                )
                            );
                            $ERR = RRDs::error;
                            if ($ERR) {
                                print_log(
                                    'Warning   |Error updating input_max for rrd file: '
                                        . $rrd_to_validate . ' : '
                                        . $ERR );
                            }
                        }
                    }

                    # if input_max in rrd file is defined then
                    # validate against the template & update if required
                    else {
                        if (!defined(
                                $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{input_max}
                            )
                            )
                        {
                            $print_update_max = 1;
                            $tune = RRDs::tune( $rrd_to_validate, '--maximum',
                                'ds'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{int_nodot} . ':U' );
                            $ERR = RRDs::error;
                            if ($ERR) {
                                print_log(
                                    'Warning   |Error updating input_max= '
                                        . 'for rrd file '
                                        . $rrd_to_validate . ' : '
                                        . $ERR );
                            }
                        }

             # compare input_max and the value in rrd, if within 0.001% ... OK
                        elsif (
                            abs((   $tgt->{target}[$n_g]->{template}[$n_e]
                                        ->{interface}[$n_i]->{input_max}
                                ) - (
                                    $$info{
                                        'ds[ds'
                                            . $tgt->{target}[$n_g]
                                            ->{template}[$n_e]
                                            ->{interface}[$n_i]->{int_nodot}
                                            . '].max'
                                        }

                                )
                            ) > abs(
                                $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{input_max}
                                    / 100000    #/
                            )
                            )
                        {
                            $print_update_max = 1;
                            $tune             = RRDs::tune(
                                $rrd_to_validate,
                                '--maximum',
                                (   'ds'
                                        . $tgt->{target}[$n_g]
                                        ->{template}[$n_e]->{interface}[$n_i]
                                        ->{int_nodot} . ':'
                                        . $tgt->{target}[$n_g]
                                        ->{template}[$n_e]->{interface}[$n_i]
                                        ->{input_max}
                                )
                            );
                            $ERR = RRDs::error;
                            if ($ERR) {
                                print_log(
                                    'Warning   |Error updating input_max= '
                                        . 'for rrd file '
                                        . $rrd_to_validate . ' : '
                                        . $ERR );
                            }
                        }
                    }    # if/else ( !defined...max"

                    # if input_min in rrd file is not defined (U) then
                    # validate against the template & update if required
                    if (!defined(
                            $$info{
                                'ds[ds'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{int_nodot} . '].min'
                                }
                        )
                        )
                    {
                        if (defined(
                                $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{input_min}
                            )
                            )
                        {
                            $print_update_min = 1;
                            $tune             = RRDs::tune(
                                $rrd_to_validate,
                                '--minimum',
                                'ds'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{int_nodot} . ':'
                                    . (
                                    $tgt->{target}[$n_g]->{template}[$n_e]
                                        ->{interface}[$n_i]->{input_min}
                                    )
                            );
                            $ERR = RRDs::error;
                            if ($ERR) {
                                print_log(
                                    'Warning   |Error updating input_min= for rrd file: '
                                        . $rrd_to_validate . ' : '
                                        . $ERR );
                            }
                        }
                    }

                    # if input_min in rrd file is defined then
                    # validate against the template & update if required
                    else {
                        if (!defined(
                                $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{input_min}
                            )
                            )
                        {
                            $print_update_min = 1;
                            $tune = RRDs::tune( $rrd_to_validate, '--minimum',
                                'ds'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{int_nodot} . ':U' );
                            $ERR = RRDs::error;
                            if ($ERR) {
                                print_log(
                                    'Warning   |Error updating input_min= for rrd file '
                                        . $rrd_to_validate . ' : '
                                        . $ERR );
                            }
                        }

                        # compare input_min and the value in rrd,
                        # if within 0.001% ... OK
                        elsif (
                            abs((   $tgt->{target}[$n_g]->{template}[$n_e]
                                        ->{interface}[$n_i]->{input_min}
                                ) - (
                                    $$info{
                                        'ds[ds'
                                            . $tgt->{target}[$n_g]
                                            ->{template}[$n_e]
                                            ->{interface}[$n_i]->{int_nodot}
                                            . '].min'
                                        }
                                )
                            ) > abs(
                                $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{input_min}
                                    / 100000    #/
                            )
                            )
                        {
                            $print_update_min = 1;
                            $tune             = RRDs::tune(
                                $rrd_to_validate,
                                '--minimum',
                                'ds'
                                    . $tgt->{target}[$n_g]->{template}[$n_e]
                                    ->{interface}[$n_i]->{int_nodot} . ':'
                                    . (
                                    $tgt->{target}[$n_g]->{template}[$n_e]
                                        ->{interface}[$n_i]->{input_min}
                                    )
                            );
                            $ERR = RRDs::error;
                            if ($ERR) {
                                print_log(
                                    'Warning   |Error updating input_min= for rrd file '
                                        . $rrd_to_validate . ' : '
                                        . $ERR );
                            }
                        }
                    }    # if/else ( !defined...min"
                }
                if ( $print_update_max == 1 ) {
                    print_log( 'Update    |input_max= for rrd file: '
                            . $rrd_to_validate );
                }
                if ( $print_update_min == 1 ) {
                    print_log( 'Update    |input_min= for rrd file: '
                            . $rrd_to_validate );
                }
            }    #for ( $n_i
        }    #for ( $n_e
    }    #for ( $n_g

    &debug('main      |Target file validated');

# load templates into memory___________________________________________________
# $template->{frequency}:                           frequency of quering,
# $target->{ip_address}:                            ip address of target,
# $target->{id}:                             name of target,
# $target->{community}:                             snmp community of target,
# $target->{username}:                              snmp v3 username of target,
# $target->{port}:                                  snmp port number of target,
# $template:                                        query template of target,
# (split(/:/, $target->{alert}, 2))[0]:   alert threshold
# (split(/:/, $target->{alert}, 2))[1]:   alert e-mails
# Create %tt, a hash of arrays containing the target and metrics templates to query

    for ( $n_g = 0; $n_g <= $#{ $tgt->{target} }; $n_g++ ) {  #for each target

        # for each template of this target
        for (
            $n_e = 0;
            $n_e <= $#{ $tgt->{target}[$n_g]->{template} };
            $n_e++
            )
        {

            # get the next_update using RRDs:last.
            # if the RRD file does not exist, skip it and use time now
            # note the modulo (x % y) magic ... thanks tobi
            $rrd_lastupdate = RRDs::last( $cfg->{web}->{directory}
                    . $tgt->{target}[$n_g]->{id}
                    . $sl
                    . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                    . '.rrd' );
            if ( defined $rrd_lastupdate ) {
                $next_sched = $rrd_lastupdate - (
                    $rrd_lastupdate % $tgt->{target}[$n_g]->{template}[$n_e]
                        ->{frequency} )
                    + $tgt->{target}[$n_g]->{template}[$n_e]->{frequency};
            }
            else {
                $next_sched = time;
            }

            # separate the alert threshold and the e-mail address
            # then create an array of arrays which will be
            # used to schedule the queries
            ( $if_al_th, $if_email )
                = ( split( /:/, $tgt->{target}[$n_g]->{alert}, 2 ) );
            if ( $if_al_th =~ /U$/i ) {    # contains a trailing U or u
                $alert_on_up = 1;
            }
            else { $alert_on_up = 0; }
            $if_al_th =~ s/U$//i;          # strip any trailing U or u

            # increment $next_sched by 1/1000 sec until it is unique
            while ( exists( $tt{$next_sched} ) ) {
                $next_sched += 0.001;
            }
            my $this_tt_type;
            if ( defined( $tgt->{target}[$n_g]->{template}[$n_e]->{ping} ) ) {
                $this_tt_type = 'ping';
            }
            elsif (
                defined( $tgt->{target}[$n_g]->{template}[$n_e]->{module} ) )
            {
                $this_tt_type = 'module';
            }
            elsif ( defined( $tgt->{target}[$n_g]->{template}[$n_e]->{oid} ) )
            {
                $this_tt_type = 'snmp';
            }

         # if community and username not defined only allow non-snmp templates
            if (   !defined( $tgt->{target}[$n_g]->{community} )
                && !defined( $tgt->{target}[$n_g]->{username} ) )
            {
                if ( !defined( $tgt->{target}[$n_g]->{template}[$n_e]->{oid} )
                    )
                {
                    $tt{$next_sched} = {
                        'tt_index'  => $n,
                        'tt_type'   => $this_tt_type,
                        'frequency' => $tgt->{target}[$n_g]->{template}[$n_e]
                            ->{frequency},
                        'ip_address' => $tgt->{target}[$n_g]->{ip_address},
                        'id'         => $tgt->{target}[$n_g]->{id},
                        'community'  => q{},
                        'username'   => q{},
                        'port'       => $tgt->{target}[$n_g]->{port},
                        'version'    => $tgt->{target}[$n_g]->{version},
                        'template' => $tgt->{target}[$n_g]->{template}[$n_e],
                        'if_alert_thresh' => $if_al_th,
                        'alert_on_up'     => $alert_on_up,
                        'if_alert_email'  => $if_email

                    };
                }
                else {
                    print_log(
                        'main      |snmp community or username not defined for target "'
                            . $tgt->{target}[$n_g]->{id}
                            . '" hence template "'
                            . $tgt->{target}[$n_g]->{template}[$n_e]->{id}
                            . '" is not active.' );
                }
            }
            else {
                $tt{$next_sched} = {
                    'tt_index'  => $n,
                    'tt_type'   => $this_tt_type,
                    'frequency' =>
                        $tgt->{target}[$n_g]->{template}[$n_e]->{frequency},
                    'ip_address' => $tgt->{target}[$n_g]->{ip_address},
                    'id'         => $tgt->{target}[$n_g]->{id},
                    'community'  => $tgt->{target}[$n_g]->{community},
                    'username'   => $tgt->{target}[$n_g]->{username},
                    'port'       => $tgt->{target}[$n_g]->{port},
                    'version'    => $tgt->{target}[$n_g]->{version},
                    'template'   => $tgt->{target}[$n_g]->{template}[$n_e],
                    'if_alert_thresh' => $if_al_th,
                    'alert_on_up'     => $alert_on_up,
                    'if_alert_email'  => $if_email

                };
            }    # if/else ( !defined(...{community}

            $n++;    # increment index by 1
        }    # for ( $n_e = 0...{template}

        if (( defined( $cfg->{attributes}->{in_file} ) )
            && (   defined( $tgt->{target}[$n_g]->{community} )
                || defined( $tgt->{target}[$n_g]->{username} ) )
            && ( defined( $tgt->{target}[$n_g]->{attributes} ) )
            && ( @{ $tgt->{target}[$n_g]->{attributes} } )
            )
        {
            my $path_out_file = $cfg->{web}->{directory}
                . $tgt->{target}[$n_g]->{id}
                . $sl
                . $cfg->{attributes}->{out_file};
            if ( -r $path_out_file ) {
                my $discovered = eval {
                    XMLin(
                        $path_out_file,
                        ForceArray => [ 'table', 'value', 'column' ],
                        KeyAttr    => ''
                    );
                };
                print_log('main      |Error when evaluating '
                        . $path_out_file . ': "'
                        . $@
                        . '"' )
                    if ($@);
                if ( defined $discovered->{last_update} ) {
                    $next_sched = $discovered->{last_update} - (
                        $discovered->{last_update} % (
                            $cfg->{attributes}->{frequency}
                                * $ATTRIBUTE_FREQUENCY
                        )
                        )
                        + ( $cfg->{attributes}->{frequency}
                            * $ATTRIBUTE_FREQUENCY );
                }
                else {
                    $next_sched = time;
                }
            }
            else {
                $next_sched = time;
            }

            # set the attributes template
            while ( exists( $tt{$next_sched} ) ) {
                $next_sched += 0.001;
            }
            $tt{$next_sched} = {
                'tt_index'  => $n,
                'tt_type'   => 'attribute',
                'frequency' => $cfg->{attributes}->{frequency}
                    * $ATTRIBUTE_FREQUENCY,
                'ip_address' =>
                    $tgt->{target}[$n_g]->{ip_address},    # ip address
                'id'         => $tgt->{target}[$n_g]->{id},
                'community'  => $tgt->{target}[$n_g]->{community}, # community
                'username'   => $tgt->{target}[$n_g]->{username},  # username
                'port'       => $tgt->{target}[$n_g]->{port},      # port
                'attributes' =>
                    $tgt->{target}[$n_g]->{attributes},            # attribute
                'version' => $tgt->{target}[$n_g]->{version},      # version
            };
            push(
                @{ $attrib_menu->{menu} },
                { 'content' => $tgt->{target}[$n_g]->{id} }
            );
            $n++;    # increment query counter ($n)
        }    # if ( defined( $cfg->{attributes}->{in_file}...
    }    # for ( $n_g = 0...{target}
}

# create web_dir/graphfolder/attributes_menu.xml file _________________________
if ( defined( $cfg->{attributes}->{in_file} ) ) {

    # Directory creation/check for attributes_menu.xml file
    &dirCheck( $cfg->{graph}->{folder} )
        || (
        print_log(
                  'main      |Directory creation/check for "'
                . $cfg->{graph}->{folder}
                . '" unsuccessful.'
        )
        );

    # add to web_dir/graphfolder/attributes_menu.xml file
    my $path_attrib_menu = $cfg->{web}->{directory}
        . $cfg->{graph}->{folder}
        . $sl
        . 'attributes_menu.xml';
    open( FOUNDFILE, ">" . $path_attrib_menu )
        or die_log( 'ERROR     |Failure to open/create attribute menu file "'
            . $path_attrib_menu
            . '". Please check directory and permissions. '
            . $! );
    print( FOUNDFILE XMLout(
            $attrib_menu,
            KeyAttr       => '',
            NumericEscape => 2
        )
    );
    close(FOUNDFILE)
        or die_log( 'ERROR     |Failure to close attribute menu file "'
            . $path_attrib_menu
            . '". Please check directory and permissions. '
            . $!
            . $?
            . $@ );

    &debug(   'main      |Creation of attribute menu file "'
            . $path_attrib_menu
            . '" completed' );

    $attrib_menu = undef;    # flush attrib_menu as it is no longer needed
}
%tmp_idx    = ();            # flush template index as it is no longer needed
$next_sched = time;

# Add a 'log' target if log file is defined ___________________________________
my $SNM_LOG_FREQUENCY = 86400;        # 24 hrs (in seconds)
my $SNM_LOG_DIR       = 'snm_log';    # and 'device'
my $SNM_LOG_FILE      = 'snmlog';     # and id
my $SNM_LOG_TEMPLATE;

if ( defined( $cfg->{log}->{file} ) ) {

    # set the next scheduled time ($next_sched) to query the log file
    $rrd_lastupdate = RRDs::last( $cfg->{web}->{directory}
            . $SNM_LOG_DIR
            . $sl
            . $SNM_LOG_FILE
            . '.rrd' );
    if ( defined $rrd_lastupdate ) {
        $next_sched
            = $rrd_lastupdate - ( $rrd_lastupdate % $SNM_LOG_FREQUENCY )
            + $SNM_LOG_FREQUENCY;
    }
    else {
        $next_sched = time;
    }

    # set the log template
    $SNM_LOG_TEMPLATE->{frequency}        = $SNM_LOG_FREQUENCY;
    $SNM_LOG_TEMPLATE->{id}               = $SNM_LOG_FILE;
    $SNM_LOG_TEMPLATE->{data_source_type} = 'GAUGE';
    $SNM_LOG_TEMPLATE->{interface}        = [
        {   'description' => ' ',
            'int'         => '0',
            'int_nodot'   => '0',
        }
    ];

    # increment $next_sched by 1/1000 sec until it is unique
    $next_sched = time;
    while ( exists( $tt{$next_sched} ) ) {
        $next_sched += 0.001;
    }
    $tt{$next_sched} = {
        'tt_index'        => $n,
        'tt_type'         => 'snm_log',
        'frequency'       => $SNM_LOG_FREQUENCY,
        'ip_address'      => q{},                  # ip address
        'id'              => $SNM_LOG_DIR,
        'community'       => q{},                  # community
        'username'        => q{},                  # username
        'port'            => q{},                  # port
        'version'         => q{},                  # version
        'template'        => $SNM_LOG_TEMPLATE,
        'if_alert_thresh' => '0',
        'alert_on_up'     => 0,
        'if_alert_email'  => '-',
    };
    $n++;
}

# Initialize the alert file and insert an empty list of alerts_________________
my $alert_list;
open( ALERTFILE, '>' . $cfg->{alert}->{file} )
    or die_log( 'main      |Failure to open/create <alert file="">.'
        . ' Please check directory and permissions. "'
        . $!
        . '"' );
print( ALERTFILE XMLout( $alert_list, KeyAttr => '' ) );
close(ALERTFILE)
    or print_log( 'main      |Failure to close <alert file="' . $! . '">' );

#_________load custom modules__________________________________________________

&debug('__________|Installing Custom Modules______________________');

# use Data::Dumper;
# print Dumper(%mod_idx);
my $ver;
foreach my $mod_used ( keys %mod_idx ) {
    eval( 'use ' . $mod_used );
    if ($@) {
        die_log(  'ERROR     |Error loading custom module:'
                . $mod_used
                . '  Ensure dependent modules are loaded.' );
    }
    eval( '$ver = $' . $mod_used . '::VERSION' );
    if ( !defined $ver ) {
        &debug( 'main      |' . $mod_used . ' module is installed' );
    }
    else {
        &debug(   'main      |'
                . $mod_used
                . ' module is installed ('
                . $ver
                . ')' );
    }
}

&debug('__________|Custom Modules installed_______________________');

# Exit SNM now if in test mode
if ($opt_t) {
    exit(0);
}

        if ( $opt_sleep ) {
            print_log(
                'main      |OS X - Sleeping for 75 seconds' );
            my $rest = sleep(75);  # so that launchd will think we're for real
            print_log(
                'main      |OS X - Slept for ' . $rest . ' seconds' );
        }


# Initialize the loop _________________________________________________________
my $next_tgt;
my @tt_sorted;
my $next_time;
my $wait_time;
print_log( '__________|Loop start ' . localtime(time) . '____________' );
do {    # Commence loop
        #sort the list placing the next query at the top.
    @tt_sorted = ();
    @tt_sorted = sort { $a <=> $b } keys %tt;

    # sleep until next query is scheduled
    my $timegap = $tt_sorted[0] - time;
    if ( ($timegap) <= 0.5 ) {
        $wait_time = 0;
    }
    else {
        $wait_time = $timegap;
        print_log('main      |'
                . localtime(time)
                . ' Wait '
                . $timegap
                . ' seconds for next scheduled query' );
    }
    while ( $wait_time > 0 ) {
        sleep(1);
        $wait_time--;
    }

    # Directory creation/check for $target->{id} or jump to next device
    &dirCheck( $tt{ $tt_sorted[0] }->{id} )
        || (
        print_log(
                  'main      |Directory creation/check for '
                . $tt{ $tt_sorted[0] }->{id}
                . ' unsucessfull'
        )
        || return (0)
        );
    if ( $tt{ $tt_sorted[0] }->{tt_type} =~ m/^(snmp|ping|module|snm_log)$/ )
    {

        # File creation/check for $target->{id} or jump to next device
        &fileCheck( $tt{ $tt_sorted[0] }->{id},
            $tt{ $tt_sorted[0] }->{template} )
            || (
            print_log(
                      'main      |File creation/check for '
                    . $tt{ $tt_sorted[0] }->{id}
                    . ' unsucessfull, jumping to next device'
            )
            || return (0)
            );

        if ( $tt{ $tt_sorted[0] }->{tt_type} eq 'snmp' ) {

            # Query the device for the specified template
            &debug(   'main      |Starting snmp query for '
                    . $tt{ $tt_sorted[0] }->{id} . ' at '
                    . $tt{ $tt_sorted[0] }->{ip_address} . ':'
                    . $tt{ $tt_sorted[0] }->{port} );
            &snmpQuery( $tt{ $tt_sorted[0] } )
                || print_log(
                'main      |snmpQuery was not succesfully completed for '
                    . $tt{ $tt_sorted[0] }->{id} );
        }
        elsif ( $tt{ $tt_sorted[0] }->{tt_type} eq 'ping' ) {

            # Query the device for the specified template
            &debug(   'main      |Starting ping query for '
                    . $tt{ $tt_sorted[0] }->{id} . ' at '
                    . $tt{ $tt_sorted[0] }->{ip_address} . ':'
                    . $tt{ $tt_sorted[0] }->{port} );
            &pingQuery( $tt{ $tt_sorted[0] } )
                || print_log(
                'main      |pingQuery was not succesfully completed for '
                    . $tt{ $tt_sorted[0] }->{id} );
        }
        elsif ( $tt{ $tt_sorted[0] }->{tt_type} eq 'module' ) {

            # Query the device for the specified template
            &debug(   'main      |Starting module query for '
                    . $tt{ $tt_sorted[0] }->{id} . ' at '
                    . $tt{ $tt_sorted[0] }->{ip_address} . ':'
                    . $tt{ $tt_sorted[0] }->{port} );
            &modQuery( $tt{ $tt_sorted[0] } )
                || print_log(
                'main      |modQuery was not succesfully completed for '
                    . $tt{ $tt_sorted[0] }->{id} );
        }
        elsif ( $tt{ $tt_sorted[0] }->{tt_type} eq 'snm_log' ) {

            # Query the device for the specified template
            &debug('main      |Starting LogPurge');
            &LogPurgeRRD( $tt{ $tt_sorted[0] } )
                || print_log(
                'main      |LogPurge was not succesfully completed for '
                    . $tt{ $tt_sorted[0] }->{id} );
        }
    }    # elsif ( ...->{tt_type} =~ 'snmp|snm_log'
    elsif ( $tt{ $tt_sorted[0] }->{tt_type} eq 'attribute' ) {
        &debug(   'main      |Starting attribute discovery for <target id="'
                . $tt{ $tt_sorted[0] }->{id}
                . '">' );
        &getAttributes( $tt{ $tt_sorted[0] } )
            || print_log(
            'main      |GetAttributes was not succesfully completed for '
                . $tt{ $tt_sorted[0] }->{id} );
    }

    # Schedule the next query
    $next_sched = time - ( time % $tt{ $tt_sorted[0] }->{frequency} )
        + $tt{ $tt_sorted[0] }->{frequency};

    # increment $next_sched by 1/1000 sec until it is unique
    while ( exists( $tt{$next_sched} ) ) {
        $next_sched += 0.001;
    }

    # delete the row that relates to the query just processed ($tt[0])
    # and add a revised row (with new time)
    $next_tgt = $tt{ $tt_sorted[0] };
    delete( $tt{ $tt_sorted[0] } );
    $tt{$next_sched} = $next_tgt;

} while (1);    # end do (and run forever)

&debug('main      |Exiting SNM');

#___________________________end core process___________________________________

#___ dirCheck(): ______________________________________________________________
# Checks if the apropriate directories are there, if not, they are created
#
sub dirCheck {
    my $id = $_[0];

    # For this target, checking if the directory exists
    if ( !-r $cfg->{web}->{directory} . $id )
    {    # if the target directory does not exist
        &debug(   'dirCheck  |directory '
                . $cfg->{web}->{directory}
                . $id
                . ' does not exist' );
        mkdir( $cfg->{web}->{directory} . $sl . $id, 0755 )
            || (
            print_log(
                      'dirCheck  |Could not create directory '
                    . $cfg->{web}->{directory}
                    . $id . ': '
                    . $!
            )
            && return (0)
            );
    }

    # For this target, check if the directory was created
    if (   ( -r $cfg->{web}->{directory} . $id )
        && ( -d $cfg->{web}->{directory} . $id ) )
    {
        &debug(   'dirCheck  |directory '
                . $cfg->{web}->{directory}
                . $id
                . ' is OK' );
    }
    return (1);
}

#___ fileCheck(): _____________________________________________________________
# Checks if the apropriates rrd files are there, if not, they are created
#
sub fileCheck {
    my ( $id, $tgt_template ) = @_;

    # For this target, check if the .rrd file exists, create if not exist
    # file format is: "id".rrd
    if (  !-r $cfg->{web}->{directory} . $id . $sl
        . $tgt_template->{id}
        . '.rrd' )
    {    # if the rrd file does not exists
        &debug(   'fileCheck |file '
                . $cfg->{web}->{directory}
                . $id
                . $sl
                . $tgt_template->{id}
                . '.rrd does not exist' );
        &createRRD( $id, $tgt_template )
            || ( print_log('fileCheck |RRD file creation was not succesfull')
            && return (0) );
    }
    return (1);
}

#________ createRRD(): creates an RRD db _______________________________________________
#
sub createRRD {
    my ( $id, $template ) = @_;
    my $create_rrd_file
        = $cfg->{web}->{directory} . $id . $sl . $template->{id} . '.rrd';
    &debug( 'createRRD |Creating ' . $create_rrd_file . ' file for ' . $id );
    my @DSs = ();    # define Data Sources (DS) for each OID on each interface
    if ( $template->{id} eq 'ping' ) {
        push( @DSs,
                  'DS:dsmin:GAUGE:'
                . ( $cfg->{rrdstep}->{timeout} * $template->{frequency} )
                . ":U:U" );
        push( @DSs,
                  'DS:dsmax:GAUGE:'
                . ( $cfg->{rrdstep}->{timeout} * $template->{frequency} )
                . ':U:U' );
        push( @DSs,
                  'DS:dsavg:GAUGE:'
                . ( $cfg->{rrdstep}->{timeout} * $template->{frequency} )
                . ':U:U' );
    }
    else {

       # get all the metrics from the template that match the target->template
        foreach my $interface ( @{ $template->{interface} } )
        {    #for each interface for the target->description
            my ( $i_max, $i_min );

            # set input_max and input_min to 'U' unless defined.
            if ( defined( $interface->{input_max} ) ) {
                $i_max = $interface->{input_max};
            }
            else {
                $i_max = 'U';
            }
            if ( defined( $interface->{input_min} ) ) {
                $i_min = $interface->{input_min};
            }
            else {
                $i_min = 'U';
            }
            push( @DSs,
                      'DS:ds'
                    . $interface->{int_nodot} . ':'
                    . $template->{data_source_type} . ':'
                    . ( $cfg->{rrdstep}->{timeout} * $template->{frequency} )
                    . ':'
                    . $i_min . ':'
                    . $i_max );
        }    # foreach my $interface
    }

    # define daily, weekly, monthly and annual Average and Max for RRAs
    my @RRAs = ();

    if ( $template->{id} eq $SNM_LOG_FILE ) {

        #monthly Average, each 1 step for 1550 hours (rows)
        push( @RRAs,
            'RRA:AVERAGE:0.5:1:'
                . ( ( 3600 * 1550 ) / $template->{frequency} ) );

        #monthly Max, each 1 steps for 1550 hours (rows)
        push( @RRAs,
            'RRA:MAX:0.5:1:' . ( ( 3600 * 1550 ) / $template->{frequency} ) );
    }
    else {

        #daily Average, each 1 step for 50 hours (rows)
        push( @RRAs,
            'RRA:AVERAGE:0.5:1:'
                . ( ( 3600 * 50 ) / $template->{frequency} ) );

        #weekly Average, each 6 steps for 350 hours (rows)
        push( @RRAs,
            'RRA:AVERAGE:0.5:6:'
                . ( ( 3600 * 350 ) / ( $template->{frequency} * 6 ) ) );

        #monthly Average, each 24 steps for 1550 hours (rows)
        push( @RRAs,
            'RRA:AVERAGE:0.5:24:'
                . ( ( 3600 * 1550 ) / ( $template->{frequency} * 24 ) ) );

        #annual Average, each 288 steps for 19128 hours (rows)
        push( @RRAs,
            'RRA:AVERAGE:0.5:288:'
                . ( ( 3600 * 19128 ) / ( $template->{frequency} * 288 ) ) );

        #daily Max, each 1 step for 50 hours (rows)
        push( @RRAs,
            'RRA:MAX:0.5:1:' . ( ( 3600 * 50 ) / $template->{frequency} ) );

        #weekly Max, each 6 steps for 350 hours (rows)
        push( @RRAs,
            'RRA:MAX:0.5:6:'
                . ( ( 3600 * 350 ) / ( $template->{frequency} * 6 ) ) );

        #monthly Max, each 24 steps for 1550 hours (rows)
        push( @RRAs,
            'RRA:MAX:0.5:24:'
                . ( ( 3600 * 1550 ) / ( $template->{frequency} * 24 ) ) );

        #annual Max, each 288 steps for 19128 hours (rows)
        push( @RRAs,
            'RRA:MAX:0.5:288:'
                . ( ( 3600 * 19128 ) / ( $template->{frequency} * 288 ) ) );
    }

    # Create RRD for target device as defined by @DSs and @RRAs
    RRDs::create( $create_rrd_file, '--step=' . $template->{frequency},
        @DSs, @RRAs );
    $ERR = RRDs::error;

    if ( defined($ERR) ) {
        print_log('createRRD |Error while creating '
                . $create_rrd_file . ": "
                . $ERR );
        return (0);
    }
    else {
        return (1);
    }
}

#___ PingQuery(): Gets the responses from ping_________________________________
#___ and sends it to insertData function ______________________________________
#
sub pingQuery {
    my ($this_tt) = @_;

    # ping the target
    my %ping_data = &netPing( $this_tt->{ip_address},
        $this_tt->{id}, $this_tt->{template}->{ping} );

    # write to rrd
    my $rrd_file_path_s = $cfg->{web}->{directory}
        . $this_tt->{id}
        . $sl
        . $this_tt->{template}->{id} . '.rrd';
    &insertData( $rrd_file_path_s, \%ping_data )
        || print_log( 'pingQuery |rrd file "'
            . $rrd_file_path_s
            . '" was not succesfully updated' );

    # print_log and add fail to alert file if ping is unsuccessful
    if (   ( $ping_data{dsmin} eq 'U' )
        && ( $ping_data{dsavg} eq 'U' )
        && ( $ping_data{dsmax} eq 'U' ) )
    {
        print_log('pingQuery |'
                . localtime(time)
                . ' Ping unsuccessful for '
                . $this_tt->{id} );

        # alert if ping not successful
        alert(
            $this_tt->{tt_index},
            'error_ping',
            'query failure: ' . $this_tt->{template}->{id},
            $this_tt->{ip_address},
            $this_tt->{id},
            'ping',
            ' ',
            $this_tt->{if_alert_thresh},
            $this_tt->{alert_on_up}
        );
        return ( { '1.3.6.1.2.1.1.3.0' => 'UNKNOWN' } );
    }
    else {

        # add pass to alert file if ping status '1' = success
        alert(
            $this_tt->{tt_index},
            1,
            'query failure: ' . $this_tt->{template}->{id},
            $this_tt->{ip_address},
            $this_tt->{id},
            'ping',
            ' ',
            $this_tt->{if_alert_thresh},
            $this_tt->{alert_on_up}
        );
    }
    return (1);
}

#___ snmpQuery(): Gets the responses from the ping, script or snmp agents_________________
#___ and sends it to insertData function ________________________________________________
#
sub snmpQuery {
    my ($this_tt) = @_;

    # responses for all interfaces of this template of this target
    my %tplate_data     = ();
    my $if_snmp         = 1;
    my $rrd_file_path_s = $cfg->{web}->{directory}
        . $this_tt->{id}
        . $sl
        . $this_tt->{template}->{id} . '.rrd';

    # Creating Net::SNMP session
    if ( $this_tt->{version} == 3 ) {
        ( $session, $error ) = Net::SNMP->session(
            -hostname  => $this_tt->{ip_address},
            -username  => $this_tt->{username},
            -port      => $this_tt->{port},
            -version   => $this_tt->{version},
            -translate => [ -timeticks => 0x0 ]
            ,    # Turn off so sysUpTime is numeric
            -timeout => $cfg->{default}->{timeout},
            -retries => $cfg->{snmp}->{retries}
        );
    }
    else {
        ( $session, $error ) = Net::SNMP->session(
            -hostname  => $this_tt->{ip_address},
            -community => $this_tt->{community},
            -port      => $this_tt->{port},
            -version   => $this_tt->{version},
            -translate => [ -timeticks => 0x0 ]
            ,    # Turn off so sysUpTime is numeric
            -timeout => $cfg->{default}->{timeout},
            -retries => $cfg->{snmp}->{retries}
        );
    }
    if ( !defined($session) ) {

        # if session not defined, print Warning and return from subroutine
        print_log('snmpQuery |Net::SNMP error "' . $error
                . '" for <target id="'
                . $this_tt->{id}
                . '">, <template id="'
                . $this_tt->{template}->{id}
                . '">' );

        # alert file if snmp "S" threshold does not meet the critera
        alert(
            $this_tt->{tt_index}, 'error_snmp_session',
            'snmp session error', $this_tt->{ip_address},
            $this_tt->{id},       $this_tt->{template}->{id},
            ' ',                  $this_tt->{if_alert_thresh},
            $this_tt->{alert_on_up}
        );

        #for each interface for this template
        foreach my $interface ( @{ $this_tt->{template}->{interface} } ) {
            $tplate_data{ 'ds' . $interface->{int_nodot} } = 'U';

            # clear existing alert file for snmp query
            alert(
                $this_tt->{tt_index},
                1,
                'query failure: ' . $this_tt->{template}->{id},
                $this_tt->{ip_address},
                $this_tt->{id},
                $interface->{int},
                $interface->{description},
                $this_tt->{if_alert_thresh},
                $this_tt->{alert_on_up}
            );
        }

        # Update the rrd file with the query responses
        &insertData( $rrd_file_path_s, \%tplate_data )
            || print_log( 'snmpQuery |rrd file "'
                . $rrd_file_path_s
                . '" was not succesfully updated' );

        # need to add 'if threshold then un-alarm it'
        return (1);
    }
    else {

        # alert file if snmp session was successful
        alert(
            $this_tt->{tt_index}, 1,
            'snmp session error', $this_tt->{ip_address},
            $this_tt->{id},       $this_tt->{template}->{id},
            ' ',                  $this_tt->{if_alert_thresh},
            $this_tt->{alert_on_up}
        );
    }

    # if it is defined, get snmp requests
    &debug( 'snmpQuery |Net::SNMP Session created with ' . $this_tt->{id} );

    #for each interface for this template
    foreach my $interface ( @{ $this_tt->{template}->{interface} } ) {

        # define snmp OID queries for each interface
        # of each template of this target
        my %oid_properties = ();

        #for each oid for this template
        $_ = $this_tt->{template}->{oid};
        s/^\.//g;                     # strip any leading periods (.)
        s/int/$interface->{int}/g;    # replace the 'int' with interface value

        # replace the "." with "d" in the RRD data set
        # create a RRD data set using metric & interface as the ID
        $oid_properties{ $this_tt->{template}->{id} }{'oid'} = $_;
        $oid_properties{ $this_tt->{template}->{id} }{'rrd_template'}
            = 'ds' . $interface->{int_nodot};

        # if %oid_properties hash not empty,
        # then use the snmp session to query the target
        if ( ( keys %oid_properties ) != 0 ) {

            my $query_resp;
            my @oid_list = ();

            # get snmp requests for the array of oids for each template
            for my $key ( keys %oid_properties ) {
                push( @oid_list, $oid_properties{$key}->{'oid'} );
            }
            if ( defined( $response = $session->get_request(@oid_list) ) ) {

                # if there is an query response
                $query_resp = 0;
                &debug(   'snmpQuery |Updating "'
                        . $this_tt->{template}->{id}
                        . '.rrd" for '
                        . $this_tt->{id}
                        . ' with query responses' );

                #create a hash containing rrd's DS-name and it's update value
                #if the value is an integer or decimal number, else "U"
                my $non_num_snmp_query = 0;
                foreach $query_resp ( keys %oid_properties ) {
                    if ( $response->{ $oid_properties{$query_resp}->{'oid'} }
                        =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/ )
                    {
                        $oid_properties{$query_resp}{'current_value'}
                            = $response->{ $oid_properties{$query_resp}
                                ->{'oid'} };
                    }
                    else {
                        $non_num_snmp_query = 1;    # query is non-numeric
                        $oid_properties{$query_resp}{'current_value'} = 'U';

                        # print_log if snmp is unsuccessful
                        print_log('snmpQuery |'
                                . localtime(time)
                                . ' Non numeric response from <target id="'
                                . $this_tt->{id}
                                . '"> for oid="'
                                . $oid_properties{$query_resp}->{'oid'}
                                . '" in template="'
                                . $this_tt->{template}->{id}
                                . '". Updating with "Unknown"' );
                    }
                    $tplate_data{ $oid_properties{$query_resp}
                            ->{'rrd_template'} }
                        = $oid_properties{$query_resp}->{'current_value'};
                }

                # add pass to alert file if snmp is "1" successful
                if ( $non_num_snmp_query == 1 ) {

                    # alert file if snmp query NOT successful
                    alert(
                        $this_tt->{tt_index},
                        'non-numeric_snmp_query_response',
                        'query failure: ' . $this_tt->{template}->{id},
                        $this_tt->{ip_address},
                        $this_tt->{id},
                        $interface->{int},
                        $interface->{description},
                        $this_tt->{if_alert_thresh},
                        $this_tt->{alert_on_up}
                    );
                }
                else {

                    # alert file if snmp query was successful
                    alert(
                        $this_tt->{tt_index},
                        1,
                        'query failure: ' . $this_tt->{template}->{id},
                        $this_tt->{ip_address},
                        $this_tt->{id},
                        $interface->{int},
                        $interface->{description},
                        $this_tt->{if_alert_thresh},
                        $this_tt->{alert_on_up}
                    );
                }

            }
            else {

                # the snmp query response is not successful
                $query_resp = 0;

                # print_log and add fail to alert file if snmp is unsuccessful
                print_log('snmpQuery |'
                        . localtime(time) . ' on '
                        . $this_tt->{id}
                        . ', interface:'
                        . $interface->{int} . ' for '
                        . $this_tt->{template}->{id}
                        . '. Updating with "Unknown" Error: '
                        . $session->error );

                # alert file if snmp query NOT successful
                alert(
                    $this_tt->{tt_index},
                    'error_snmp_query',
                    'query failure: ' . $this_tt->{template}->{id},
                    $this_tt->{ip_address},
                    $this_tt->{id},
                    $interface->{int},
                    $interface->{description},
                    $this_tt->{if_alert_thresh},
                    $this_tt->{alert_on_up}
                );

             #create a hash containing rrd's DS-name and an update value = 'U'
                foreach $query_resp ( keys %oid_properties ) {
                    $tplate_data{ $oid_properties{$query_resp}
                            ->{'rrd_template'} } = 'U';
                    $oid_properties{$query_resp}{'current_value'} = 'U';
                }
            }    # if/else defined $response=$session->get_request
        }
    }    # foreach interface

    # Update the rrd file with the query responses
    &insertData( $rrd_file_path_s, \%tplate_data )
        || print_log( 'snmpQuery |rrd file "'
            . $rrd_file_path_s
            . '" was not succesfully updated' );

    # Test the vaule if there is an alert threshold
    if ( defined( $this_tt->{if_alert_thresh} ) ) {
        &testThreshold( $this_tt, $rrd_file_path_s );
    }
    if ($if_snmp) {
        $session->close();
    }
    return (1);
}

#___ modQuery(): Gets the responses from modules_______________________________
#___ and sends it to insertData function ______________________________________
#
sub modQuery {
    my ($this_tt) = @_;

    # responses for all interfaces of this template of this target
    my %tplate_data = ();
    my $if_snmp     = 1;

    # for each template of this target
    my $rrd_file_path_s = $cfg->{web}->{directory}
        . $this_tt->{id}
        . $sl
        . $this_tt->{template}->{id} . '.rrd';

    #for each interface for this template
    foreach my $interface ( @{ $this_tt->{template}->{interface} } ) {

        # define module queries for each interface
        # of each template of this target
        my %mod_properties = ();
        if ( defined $this_tt->{template}->{module} ) {

            # for each module of this template
            # replace the %ip_address%, %interface% and %community%
            $_ = $this_tt->{template}->{module};
            s/%ip_address%/$this_tt->{ip_address}/ig;
            s/%interface%/$interface->{int}/ig;
            s/%community%/$this_tt->{community}/ig;

            # replace the "." with "d" in the RRD data set
            # create a RRD data set using metric & interface as the ID
            $mod_properties{ $this_tt->{template}->{id} }{'mod'} = $_;
            $mod_properties{ $this_tt->{template}->{id} }{'rrd_template'}
                = 'ds' . $interface->{int_nodot};
        }

        if ( ( keys %mod_properties ) != 0 ) {
            my $output;
            my $script_alert = 0;

            # get requests for the array of module
            # queries (mods) for each template
            foreach my $mod_query ( keys %mod_properties ) {
                eval( '$output = ' . $mod_properties{$mod_query}->{'mod'} );
                if ($@) {
                    print_log('modQuery  |Module "'
                            . $mod_query
                            . '" in template "'
                            . $this_tt->{template}->{id}
                            . '" for target "'
                            . $this_tt->{id}
                            . '" has incorrect syntax:'
                            . $@ );
                }

                # clean returned data (remove non printable characters
                # and remove any leading and trailing spaces)
                $output =~ s/[\t\n\r\f]//g;
                $output =~ s/^\s+//;
                $output =~ s/\s+$//;

                # verify there is a numeric output in $output
                if ( $output !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/ ) {
                    print_log('modQuery  |Response to module "'
                            . $mod_query
                            . '" in template "'
                            . $this_tt->{template}->{id}
                            . '" for target "'
                            . $this_tt->{id}
                            . '" is non numeric: '
                            . $output );
                    $mod_properties{$mod_query}->{'current_value'} = 'U';
                    $tplate_data{ $mod_properties{$mod_query}
                            ->{'rrd_template'} } = 'U';

                    # alert file if query NOT successful
                    $script_alert = 1;
                }
                else {
                    &debug(   'modQuery  |Updating "'
                            . $this_tt->{template}->{id}
                            . '.rrd" for '
                            . $this_tt->{id}
                            . ' with query responses' );
                    $mod_properties{$mod_query}{'current_value'} = $output;
                    $tplate_data{ $mod_properties{$mod_query}
                            ->{'rrd_template'} }
                        = $mod_properties{$mod_query}->{'current_value'};
                }
            }    # foreach my $mod_query

            # update alerts either successful or unsuccessful
            if ( $script_alert != 0 ) {

                # alert file if query NOT successful
                alert(
                    $this_tt->{tt_index},
                    'error_script_query',
                    'query failure: ' . $this_tt->{template}->{id},
                    $this_tt->{ip_address},
                    $this_tt->{id},
                    $interface->{int},
                    $interface->{description},
                    $this_tt->{if_alert_thresh},
                    $this_tt->{alert_on_up}
                );
            }
            else {

                # add pass to alert file if query is "S" successful
                alert(
                    $this_tt->{tt_index},
                    1,
                    'query failure: ' . $this_tt->{template}->{id},
                    $this_tt->{ip_address},
                    $this_tt->{id},
                    $interface->{int},
                    $interface->{description},
                    $this_tt->{if_alert_thresh},
                    $this_tt->{alert_on_up}
                );
            }
        }    # elsif keys %mods
    }    # foreach interface

    # Update the rrd file with the query responses
    &insertData( $rrd_file_path_s, \%tplate_data )
        || print_log( 'modQuery  |rrd file "'
            . $rrd_file_path_s
            . '" was not succesfully updated' );

    # Test the vaule if there is an alert threshold
    if ( defined( $this_tt->{if_alert_thresh} ) ) {
        &testThreshold( $this_tt, $rrd_file_path_s );
    }
    return (1);
}

#___ LogPurgeRRD(): records the snm_log file volume in rrd file________________
#___ then purges oldest x days_________________________________________________
#
sub LogPurgeRRD {
    my ($this_tt) = @_;

    # get the log record size for the last period (get_record_size)
    my $log_rec_size = get_record_size( ( time() - $SNM_LOG_FREQUENCY ),
        $cfg->{log}->{file} );
    my %log_entries;
    if ( $log_rec_size =~ /^\d+$/ ) {
        %log_entries = ( 'ds0' => $log_rec_size );
    }
    else {
        %log_entries = ( 'ds0' => 'U' );
    }

    # purge old log records (purge_old_records)
    my $purgelog = purge_old_records(
        ( time() - ( $cfg->{log}->{purge} * $SNM_LOG_FREQUENCY ) ),
        $cfg->{log}->{file} );
    if ( $purgelog == 1 ) {
        print_log('Purgelog  |'
                . localtime(time)
                . ' Successful purge of old log records' );
    }
    else {
        print_log('Purgelog  |Unsuccessful purge of old log records');
    }

    # write record_size to rrd
    my $rrd_file_path_s = $cfg->{web}->{directory}
        . $this_tt->{id}
        . $sl
        . $this_tt->{template}->{id} . '.rrd';
    &insertData( $rrd_file_path_s, \%log_entries )
        || print_log( 'Purgelog  |rrd file "'
            . $rrd_file_path_s
            . '" was not succesfully updated' );

    # print_log and add fail to alert file if ping is unsuccessful
    if ( $log_entries{ds0} eq 'U' ) {
        print_log(
            'Purgelog  |Unsuccessful query of log file: ' . $log_rec_size );

        # alert if ping not successful
        alert(
            $this_tt->{tt_index},
            'error_log_file_query',
            'query failure: ' . $this_tt->{template}->{id},
            $this_tt->{ip_address},
            $this_tt->{id},
            'log_file',
            ' ',
            $this_tt->{if_alert_thresh},
            $this_tt->{alert_on_up}
        );
        return ( { '1.3.6.1.2.1.1.3.0' => 'UNKNOWN' } );
    }
    else {

        # add pass to alert file if query is successful
        alert(
            $this_tt->{tt_index},
            1,
            'query failure: ' . $this_tt->{template}->{id},
            $this_tt->{ip_address},
            $this_tt->{id},
            'log_file',
            ' ',
            $this_tt->{if_alert_thresh},
            $this_tt->{alert_on_up}
        );
        return ( { '1.3.6.1.2.1.1.3.0' => 'UNKNOWN' } );
    }
    return (1);
}

#__ testThreshold(): ____________________________________________
sub testThreshold {
    my ( $this_tt, $rrd_file_path_s ) = @_;
    my $int_x;
    my @int_alert_checks = ();
    for (
        $int_x = 0;
        $int_x <= $#{ $this_tt->{template}->{interface} };
        $int_x++
        )
    {

        # if there is a int_alert,
        # add the interface index to @int_alert_checks
        if (defined( $this_tt->{template}->{interface}[$int_x]->{int_alert} )
            )
        {
            &debug(   'testThresh|Testing <target id="'
                    . $this_tt->{id}
                    . '"> <template id="'
                    . $this_tt->{template}->{id}
                    . '"> <interface int="'
                    . $this_tt->{template}->{interface}[$int_x]->{int}
                    . '"> for threshold="'
                    . $this_tt->{template}->{interface}[$int_x]->{int_alert}
                    . '"' );
            push( @int_alert_checks, $int_x );
        }
    }    # for ( $int_x = 0;

    # if there is a int_alert, use RRDs::fetch to get current values
    if ( $#int_alert_checks >= 0 ) {
        my $now = time();
        my $ma_time = $now - ( $now % $this_tt->{template}->{frequency} );
        my ( $ma_start, $ma_step, $ma_ds_names, $ma_data ) = RRDs::fetch(
            $rrd_file_path_s, 'AVERAGE',
            '-r',             $this_tt->{template}->{frequency},
            '-s',             $ma_time - $this_tt->{template}->{frequency},
            '-e',             $ma_time
        );
        $ERR = RRDs::error;
        print_log('modQuery  |ERROR while fetching '
                . $rrd_file_path_s
                . ' to evaluate alert threshold: '
                . $ERR )
            if $ERR;

        # loop thru interfaces, checkandalert if int_alert defined
        foreach $int_x (@int_alert_checks) {
            ( $met_criteria, $met_val, $met_alert_num ) =
                split( /:/,
                $this_tt->{template}->{interface}[$int_x]->{int_alert}, 3 );

            # initialise $temp_if_met to no/false
            my $temp_if_met = q{};
            if ( defined $ma_data->[0]->[$int_x] ) {
                if ( $ma_data->[0]->[$int_x]
                    =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ )
                {
                    if ( $met_criteria eq "lt" ) {
                        $temp_if_met = ( $ma_data->[0]->[$int_x] < $met_val );
                    }
                    elsif ( $met_criteria eq "gt" ) {
                        $temp_if_met = ( $ma_data->[0]->[$int_x] > $met_val );
                    }
                    elsif ( $met_criteria eq "le" ) {
                        $temp_if_met
                            = ( $ma_data->[0]->[$int_x] <= $met_val );
                    }
                    elsif ( $met_criteria eq "ge" ) {
                        $temp_if_met
                            = ( $ma_data->[0]->[$int_x] >= $met_val );
                    }
                    elsif ( $met_criteria eq "eq" ) {
                        $temp_if_met
                            = ( $ma_data->[0]->[$int_x] == $met_val );
                    }
                    elsif ( $met_criteria eq "ne" ) {
                        $temp_if_met
                            = ( $ma_data->[0]->[$int_x] != $met_val );
                    }
                }    # if ( $ma_data->[0]->[$int_x]..
            }
            else {
                $temp_if_met = 0;
                $ma_data->[0]->[$int_x] = '-';
            }
            if ($temp_if_met) {

                # alert file if threshold does NOT meet the critera
                alert(
                    'T' . $this_tt->{tt_index},
                    'int_alert',
                    'actual:'
                        . $ma_data->[0]->[$int_x] . ' '
                        . $this_tt->{template}->{interface}[$int_x]
                        ->{int_alert} . ' threshold:' . $met_val,
                    $this_tt->{ip_address},
                    $this_tt->{id},
                    $this_tt->{template}->{interface}[$int_x]->{int},
                    $this_tt->{template}->{interface}[$int_x]->{description},
                    $met_alert_num,
                    $this_tt->{alert_on_up}
                );
            }
            else {

                # alert file if threshold does meet the critera
                alert(
                    'T' . $this_tt->{tt_index},
                    1,
                    'actual:'
                        . $ma_data->[0]->[$int_x] . ' '
                        . $this_tt->{template}->{interface}[$int_x]
                        ->{int_alert} . ' threshold:' . $met_val,
                    $this_tt->{ip_address},
                    $this_tt->{id},
                    $this_tt->{template}->{interface}[$int_x]->{int},
                    $this_tt->{template}->{interface}[$int_x]->{description},
                    $met_alert_num,
                    $this_tt->{alert_on_up}
                );
            }    # if/else ( $temp_if_met
        }    # foreach $int_x
    }    # if ( $#int_alert_checks
}

#____________________________________ NetPing _____________________________________________
#
# This Ping subrouting has some code based on mrtg-ping-probe by Peter W. Osel <pwo@pwo.de>
#
sub netPing {
    my ( $ptgt_ip, $ptgt_id, $ping_count ) = @_;
    my $ping_output;
    my %pt = ();
    my ( $p, $ret, $duration, $ip, $sum_dur );
    my @durations;

    # initialize return values as "Unknown"
    $pt{dsmin} = $pt{dsmax} = $pt{dsavg} = 'U';

    if ( $cfg->{ping}->{file} eq q{} ) {

        # call the net-ping module and read its output:
        $p = Net::Ping->new('icmp');
        $p->hires();
        for ( my $i = 1; $i <= $ping_count; $i++ ) {
            ( $ret, $duration, $ip )
                = $p->ping( $ptgt_ip, $cfg->{default}->{timeout} );
            if ($ret) {
                push( @durations, $duration );
            }
        }
        $p->close();
        if ( $#durations != -1 ) {
            @durations = sort { $a <=> $b } @durations;
            $pt{dsmin} = sprintf( "%.2f", 1000 * $durations[0] );
            $pt{dsmax} = sprintf( "%.2f", 1000 * $durations[$#durations] );
            foreach (@durations) { $sum_dur += $_ }
            $pt{dsavg} = sprintf( "%.2f",
                ( 1000 * $sum_dur ) / ( $#durations + 1 ) );
        }
    }
    else {

        # call the external ping program and read its output:
        unless (
            my $pid = open( PING,
                      $cfg->{ping}->{file} . ' -' . $p_os . ' '
                    . $ping_count . ' '
                    . $ptgt_ip . ' |'
            )
            )
        {
            print_log( 'netPing   |Unable to open ping: ' . $! );
            return (
                'dsmin' => $pt{dsmin},
                'dsmax' => $pt{dsmax},
                'dsavg' => $pt{dsavg}
            );
        }
        while (<PING>) {
            $ping_output .= $_;
        }
        close(PING);

        # find round trip times
        if ( $ping_output
            =~ m*(?:round-trip|rtt)(?:\s+\(ms\))?\s+min/avg/max(?:/(?:m|std)-?dev)?\s+=\s+(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)*m
            )
        {
            $pt{dsmin} = $1;
            $pt{dsmax} = $3;
            $pt{dsavg} = $2;
        }
        elsif ( $ping_output
            =~ m*^\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms,\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms,\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms\s+$*m
            )
        {

            # this should catch most windows locales
            $pt{dsmin} = $1;
            $pt{dsmax} = $2;
            $pt{dsavg} = $3;
        }
        else {
            print_log('netPing   |Time: '
                    . localtime(time) . ' on '
                    . $ptgt_id
                    . '. Updating with "Unknown"' );
        }
    }
    return (
        'dsmin' => $pt{dsmin},
        'dsmax' => $pt{dsmax},
        'dsavg' => $pt{dsavg}
    );
}

#____________________________________________________________________________________________
#
sub insertData {
    my ( $rrd_file_path, $data ) = @_;
    my $rrd_tpl   = q{};    #empty string
    my $rrd_value = q{};    #empty string

    foreach my $temp_data ( keys %$data ) {
        $rrd_tpl = $rrd_tpl . ':' . $temp_data;

        # replace "" or not defined in $data->{$temp_data} with "U"
        if ( $data->{$temp_data} !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/ )
        {                   # is not a decimal number
            $rrd_value = $rrd_value . ':U';
        }
        else {
            $rrd_value = $rrd_value . ':' . $data->{$temp_data};
        }
    }
    $rrd_tpl =~ s/^://;     # remove the leading : from the rrd string
    my $testrrds = RRDs::update( $rrd_file_path, '--template', $rrd_tpl,
        'N' . $rrd_value );
    $ERR = RRDs::error;

    if ( defined($ERR) ) {
        print_log('insertData|Error on updating file: '
                . $rrd_file_path . ': '
                . $ERR );
        return (0);
    }
    else {
        &debug(
            'insertData|File "' . $rrd_file_path . '" successfully updated' );
        return (1);
    }
}

#________ GetAttributes():_______________________________________________________________
#
sub getAttributes {
    my ($att_target) = @_;
    my $s;    # suite
    my $t;    # table
    my $c;    # column
    my $v;    # value
    my $e;    # translate
    my $discovered;
    push( @{ $discovered->{last_update} }, time );

    if ( $att_target->{version} == 3 ) {
        ( $session, $error ) = Net::SNMP->session(
            -hostname   => $att_target->{ip_address},
            -version    => $att_target->{version},
            -username   => $att_target->{username},
            -maxmsgsize => 6400,
            -port       => $att_target->{port},
            -timeout    => $cfg->{default}->{timeout},
        );
    }
    else {
        ( $session, $error ) = Net::SNMP->session(
            -hostname   => $att_target->{ip_address},
            -version    => $att_target->{version},
            -community  => $att_target->{community},
            -maxmsgsize => 6400,
            -port       => $att_target->{port},
            -timeout    => $cfg->{default}->{timeout},
        );
    }

    if ( !defined($session) ) {
        print_log( 'getAttrib |Error creating SNMP session: ' . $error );
    }
    else {

        # loop through selected attribute suites, query each value and table
        my $s_id = 0;
        foreach my $s ( @{ $att_target->{attributes} } ) {
            $discovered->{suite}[$s_id]->{id} = $s;

            #loop through values
            my $row_value;
            for (
                $v = 0;
                $v <= $#{ $attrib_in->{suite}[$s]->{value} };
                $v++
                )
            {
                if (defined(
                        $response = $session->get_request(
                            -varbindlist => [
                                $attrib_in->{suite}[$s]->{value}[$v]->{oid}
                            ]
                        )
                    )
                    )
                {

                    # strip non-printable, leading and trailing whitespace
                    ( $row_value
                            = $response->{ $attrib_in->{suite}[$s]
                                ->{value}[$v]->{oid} } ) =~ s/[^[:print:]]//g;
                    $row_value =~ s/^\s+//;
                    $row_value =~ s/\s+$//;

                    # if convert is defined then convert to date
                    if (defined $attrib_in->{suite}[$s]->{value}[$v]
                        ->{convert} )
                    {
                        $row_value = convert(
                            $attrib_in->{suite}[$s]->{value}[$v]->{convert},
                            $row_value );
                    }

                 # if calculate is defined and $row_value is numeric, then rpn
                    if ((   defined $attrib_in->{suite}[$s]->{value}[$v]
                            ->{calculate}
                        )
                        && ( $row_value
                            =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/
                        )
                        )
                    {
                        $row_value = rpn( $row_value . ','
                                . $attrib_in->{suite}[$s]->{value}[$v]
                                ->{calculate} );
                    }

                    # if defined then translate
                    for (
                        $e = 0;
                        $e <= $#{ $attrib_in->{suite}[$s]->{value}[$v]
                                ->{translate} };
                        $e++
                        )
                    {
                        if ($row_value eq $attrib_in->{suite}[$s]->{value}[$v]
                            ->{translate}[$e]->{value} )
                        {
                            $row_value = $attrib_in->{suite}[$s]->{value}[$v]
                                ->{translate}[$e]->{text};
                        }
                    }
                }
                else { $row_value = ''; }
                push(
                    @{ $discovered->{value} },
                    {   'description' => $attrib_in->{suite}[$s]->{value}[$v]
                            ->{description},
                        'content' => $row_value
                    }
                );
            }

            #loop through tables
            for (
                $t = 0;
                $t <= $#{ $attrib_in->{suite}[$s]->{table} };
                $t++
                )
            {
                push(
                    @{ $discovered->{suite}[$s_id]->{table} },
                    {   'description' => $attrib_in->{suite}[$s]->{table}[$t]
                            ->{description}
                    }
                );
                for (
                    $c = 0;
                    $c
                    <= $#{ $attrib_in->{suite}[$s]->{table}[$t]->{column} };
                    $c++
                    )
                {
                    push(
                        @{  $discovered->{suite}[$s_id]->{table}[$t]->{tr}[0]
                                ->{td}
                            },
                        {   'oid'     => 'na',
                            'content' => $attrib_in->{suite}[$s]->{table}[$t]
                                ->{column}[$c]->{description}
                        }
                    );
                    if (defined(
                            $response = $session->get_table(
                                -baseoid =>
                                    $attrib_in->{suite}[$s]->{table}[$t]
                                    ->{column}[$c]->{oid}
                            )
                        )
                        )
                    {
                        my $row_value;
                        my $n = 1;
                        foreach my $key ( sort keys %$response ) {

                        # strip non-printable, leading and trailing whitespace
                            ( $row_value = $response->{$key} )
                                =~ s/[^[:print:]]//g;
                            $row_value =~ s/^\s+//;
                            $row_value =~ s/\s+$//;

                            # if convert is defined then convert to date
                            if (defined $attrib_in->{suite}[$s]->{table}[$t]
                                ->{column}[$c]->{convert} )
                            {
                                $row_value = convert(
                                    $attrib_in->{suite}[$s]->{table}[$t]
                                        ->{column}[$c]->{convert},
                                    $row_value
                                );
                            }

                            # if calculate is defined and
                            #$row_value is numeric, then rpn
                            if ((   defined $attrib_in->{suite}[$s]
                                    ->{table}[$t]->{column}[$c]->{calculate}
                                )
                                && ( $row_value
                                    =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/
                                )
                                )
                            {
                                $row_value = rpn( $row_value . ','
                                        . $attrib_in->{suite}[$s]->{table}[$t]
                                        ->{column}[$c]->{calculate} );
                            }

                            # if defined then translate
                            for (
                                $e = 0;
                                $e <= $#{
                                    $attrib_in->{suite}[$s]->{table}[$t]
                                        ->{column}[$c]->{translate}
                                };
                                $e++
                                )
                            {
                                if ( $row_value eq
                                    $attrib_in->{suite}[$s]->{table}[$t]
                                    ->{column}[$c]->{translate}[$e]->{value} )
                                {
                                    $row_value
                                        = $attrib_in->{suite}[$s]->{table}[$t]
                                        ->{column}[$c]->{translate}[$e]
                                        ->{text};
                                }
                            }
                            push(
                                @{  $discovered->{suite}[$s_id]->{table}[$t]
                                        ->{tr}[$n]->{td}
                                    },
                                { 'oid' => $key, 'content' => $row_value }
                            );
                            $n++;
                        }    # foreach my $key ...
                    }    # if (defined( ...
                }    # for ( $c = 0; $c ... {column}
            }    # for ( $t = 0 ... {table}
            $s_id++;
        }
        $session->close;
    }    # else ... if ( !defined($session)

    # Open the discovered file (default: id\discovered.xml)
    # and insert discovered attributes
    my $path_out_file = $cfg->{web}->{directory}
        . $att_target->{id}
        . $sl
        . $cfg->{attributes}->{out_file};
    open( FOUNDFILE, ">" . $path_out_file )
        or print_log( 'getAttrib |Failure to open/create out_file "'
            . $path_out_file
            . '". Please check directory and permissions. '
            . $! );
    print( FOUNDFILE XMLout(
            $discovered,
            KeyAttr       => '',
            NumericEscape => 2
        )
    );
    close(FOUNDFILE)
        or print_log( 'getAttrib |Failure to close out_file "'
            . $path_out_file . '": '
            . $! );
    print_log('getAttrib |'
            . localtime(time)
            . ' Attribute query complete for target: '
            . $att_target->{id} );
    return (1);
}

#________ convert(): calculate an rpn expression __________________________________
# convert an snmp DateAndTime value (rfc 2579)
sub convert {
    my ( $convert_type, $value ) = @_;
    if (   ( $convert_type =~ m/^date$/i )
        && ( $value =~ m/^0x[\da-fA-F]{16}$/ ) )
    {
        my ( $year, $month, $day, $hour, $minute, $second )
            = unpack( "x2 A4 A2 A2 A2 A2 A2", $value );
        $value = sprintf(
            "%.2u-%.2u-%.2u %.2u:%.2u:%.2u",
            hex($year), hex($month),  hex($day),
            hex($hour), hex($minute), hex($second)
        );
    }
    return $value;
}

#________ rpn(): calculate an rpn expression __________________________________
# http://qs321.pair.com/~monkads/index.pl?node_id=520826
sub rpn {
    my ($expr) = @_;
    $expr =~ s/\s//g;    # strip all whitespace
    my @stack;
    for my $tok ( split ',', $expr ) {
        if ( $tok =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ ) {
            push @stack, $tok;
            next;
        }
        my $x = pop @stack;
        if ( !defined $x ) {
            print_log(
                'calculate |Warning: Illegal rpn syntax. Stack underflow');
            return 'calculate error';
        }
        my $y = pop @stack;
        if ( !defined $y ) {
            print_log(
                'calculate |Warning: Illegal rpn syntax. Stack underflow');
            return 'calculate error';
        }
        if ( $tok eq '+' ) {
            push @stack, $y + $x;
        }
        elsif ( $tok eq '-' ) {
            push @stack, $y - $x;
        }
        elsif ( $tok eq '*' ) {
            push @stack, $y * $x;
        }
        elsif ( $tok eq '/' ) {
            push @stack, $y / $x;
        }
        else {
            print_log(
                'calculate |Warning: Invalid operator "' . $tok . '"' );
            return 'calculate error';
        }
    }
    if ( @stack != 1 ) {
        print_log('calculate |Warning: Incorrect rpn syntax.'
                . '  Too many numbers in rpn stack.' );
        return 'calculate error';
    }
    return $stack[0];
}

#________ print_log(): write debug data to a logfile and print to the console ___________
#
sub print_log {
    my ($arg) = @_;
    my $print_arg = $arg;
    while ( length($print_arg) >= 78 ) {
        print( substr( $print_arg, 0, 78 ) . "\n" );
        $print_arg = "          |" . substr( $print_arg, 78 );
    }
    print( $print_arg . "\n" );
    if ( defined( $cfg->{log}->{file} ) ) {
        if ( !( -r $cfg->{log}->{file} ) || !( -w $cfg->{log}->{file} ) ) {
            print(    'printlog |Log file '
                    . $cfg->{log}->{file}
                    . ' Does not exist or has bad permissions.'
                    . ' Attempting to create it.'
                    . "\n" );
        }
        open( LOGFILE, ">>" . $cfg->{log}->{file} )
            or die( 'printlog |Failure to open/create log file '
                . $cfg->{log}->{file}
                . ' Please check directory and permissions. '
                . $!
                . "\n" );
        print( LOGFILE time() . '|' . $arg . "\n" );
        close(LOGFILE);
    }
    return;
}

#________ die_log(): write debug data to a logfile and die ______________________________
#
sub die_log {
    my ($arg) = @_;
    if ( defined( $cfg->{log}->{file} ) ) {
        if ( !( -r $cfg->{log}->{file} ) || !( -w $cfg->{log}->{file} ) ) {
            print(    'dielog   |Log file '
                    . $cfg->{log}->{file}
                    . ' Does not exist or has bad permissions.'
                    . ' Attempting to create it.'
                    . "\n" );
        }
        open( LOGFILE, ">>" . $cfg->{log}->{file} )
            or die( 'dielog   |Failure to open/create log file '
                . $cfg->{log}->{file}
                . ' Please check directory and permissions. '
                . $!
                . "\n" );
        print( LOGFILE time() . '|' . $arg . "\n" );
        close(LOGFILE);
    }
    while ( length($arg) >= 78 ) {
        print( substr( $arg, 0, 78 ) . "\n" );
        $arg = '          |' . substr( $arg, 78 );
    }
    die( $arg . "\n" );
}

#________ get_record_size(): add to the alert list ________________________________
#
sub get_record_size {
    if ( ( $#_ + 1 ) == 2 ) {
        my ( $last_period, $log_file ) = @_;
        open( LOGFILE, "< $log_file" )
            or return ( 'Logmgr    |Unable to open log file ('
                . $log_file
                . ') to get record size. '
                . 'Please check log file exists.'
                . ' Please check log file permissions.' );
        my @log_content = <LOGFILE>;
        close(LOGFILE);

        # From latest entry, in reverse,
        # count all log entries between 'now' and $last_period
        my $count = 0;
        while ( my $line = pop @log_content ) {
            my $time_stamp = ( split /\|/, $line )[0];

            # ensure $time_stamp is numeric else skip
            if ( $time_stamp =~ /^\d+$/ ) {
                if ( $time_stamp > $last_period )
                {    # if time_stamp of $line greater than $last_period
                    $count++;
                }
            }
        }
        return ($count);
    }
    return ('Logmgr    |Illegal call to Logmgr "get_record_size".');
}

#________ purge_old_records(): add to the alert list ______________________________
#
sub purge_old_records {
    if ( ( $#_ + 1 ) == 2 ) {
        my ( $purge_date, $log_file ) = @_;
        my $newlog_file    = $log_file . '.new';
        my $print_the_rest = 0;

        # Perl Cookbook p241
        open( OLDLOG, "< $log_file" )
            or return ( 'Logmgr    |Unable to open log file ('
                . $log_file
                . ') to purge old records. '
                . 'Please check log file exists.'
                . ' Please check log file permissions. '
                . $! );
        open( NEWLOG, "> $newlog_file" )
            or return ( 'Logmgr    |Unable to open new log file "'
                . $newlog_file
                . '". Please check permissions. '
                . $! );
        while (<OLDLOG>) {

            # copy if $time_stamp is valid and earlier than the purge_date
            my $line = $_;
            if ( $print_the_rest == 0 ) {
                my $time_stamp = ( split /\|/, $line )[0];
                if ( $time_stamp =~ /^\d+$/ ) {
                    if ( $time_stamp > $purge_date ) {
                        $print_the_rest = 1;
                        print NEWLOG $line;
                    }
                }
            }
            else {
                print NEWLOG $line;
            }
        }
        close(OLDLOG);
        close(NEWLOG);
        rename( $log_file,    $log_file . '.old' );
        rename( $newlog_file, $log_file );
        return (1);
    }
    return ('Logmgr    |Illegal call to Logmgr "get_record_size".');
}

#________ alert(): add to the alert list __________________________________________
#
sub alert {

#   There are 2 alert types, Query and Threshold.
#   If a query fails to return a valid result a 'Query Alert' is raised
#   If the query is valid, but a threshold fails a criteria, a 'Threshold Alert' is raised
#
#   Both successful (S) and unsuccessful queries/thresholds are sent to this alert function.
#   The unsuccessful are to raise alerts, the successful are to clear existing alerts.
#   $tgt_n:               [''|T]index of target and templates,
#                               Note: if 'Query Alert' then prefix is empty/null
#                               Note: T = Threshold Alert
#   $status:              query status (1 = OK, 1 != alert message) eg:"error_snmp_query"
#   $alert_content:       $template->{id}
#   $alert_description:   $target_desc
#   $alert_device:        $id
#   $alert_if_id:         $interface->{int}
#   $alert_if_desc:       $interface->{description}
#   $alert_threshold:     $
    my ($tgt_n,            $status,          $alert_content,
        $alert_ip_address, $alert_device,    $alert_if_id,
        $alert_if_desc,    $alert_threshold, $alert_on_up
        )
        = @_;
    my $alert_n_int = $tgt_n . '.' . $alert_if_id;
    my $alert_time  = localtime;
    my $smtp_message;

    # if alert_attributes are not defined, then define them as '-'
    defined($alert_content)    or $alert_content    = '-';
    defined($alert_ip_address) or $alert_ip_address = '-';
    defined($alert_device)     or $alert_device     = '-';
    defined($alert_if_id)      or $alert_if_id      = '-';
    defined($alert_if_desc)    or $alert_if_desc    = ' ';

    # If an alert_status for the target.interface does not exist (ie new),
    # initiate it with: alert_count = 0 and alert_sent = No
    defined( $alert_status{$alert_n_int}->{'alert_count'} )
        or $alert_status{$alert_n_int} = {
        'metric_id'       => $tgt_n,
        'status'          => $status,
        'content'         => $alert_content,
        'ip_address'      => $alert_ip_address,
        'device'          => $alert_device,
        'interface'       => $alert_if_id,
        'if_desc'         => $alert_if_desc,
        'alert_on_up'     => $alert_on_up,
        'alert_threshold' => $alert_threshold,
        'alert_count'     => 0,
        'alert_sent'      => 'No',
        'last_time'       => $alert_time
        };

    # display for alerts
    my $temp_int_id;
    if ( $alert_status{$alert_n_int}->{'if_desc'} eq ' ' ) {
        $temp_int_id = $alert_status{$alert_n_int}->{'interface'};
    }
    else {
        $temp_int_id = $alert_status{$alert_n_int}->{'interface'} . '('
            . $alert_status{$alert_n_int}->{'if_desc'} . ')';
    }

    # If an alert file does not exist, then create it ($alert_print_flag = 1)
    if ( !( -r $cfg->{alert}->{file} ) || !( -w $cfg->{alert}->{file} ) ) {
        $alert_print_flag = 1;
    }

# if there is an alert_status for the target.interface (ie status != 1) then:
# a) set the alert.xml file to be updated ($alert_print_flag = 1),
# b) increment the alert_count by 1, and
# c) if e-mail address exists and alert_count = alert_threshold then e-mail an alert.
    if ( $status ne '1' ) {

        #  The query failed
        $alert_print_flag = 1;
        $alert_status{$alert_n_int}->{'alert_count'}++;
        $alert_status{$alert_n_int}->{'status'} = $status;
        if ( $alert_status{$alert_n_int}->{'alert_count'} == 1 ) {
            $alert_status{$alert_n_int}->{'last_time'} = $alert_time;
        }

        # if e-mail address exists (!= "-")
        # and alert_count = alert_threshold then send an e-mail
        if (( $tt{ $tt_sorted[0] }->{if_alert_email} ne '-' )
            && ( $alert_status{$alert_n_int}->{'alert_count'}
                == $alert_status{$alert_n_int}->{'alert_threshold'} )
            )
        {

            my $content = 'Subject: SNM status = DOWN for device: '
                . $alert_status{$alert_n_int}->{'device'} . ' ['
                . $alert_status{$alert_n_int}->{'content'} . ']' . "\n"
                . 'SNM status  = DOWN for:' . "\n"
                . 'Device (IP) : '
                . $alert_status{$alert_n_int}->{'device'} . ' ('
                . $tt{ $tt_sorted[0] }->{ip_address} . ")\n"
                . 'Interface   : '
                . $temp_int_id . "\n"
                . 'Content     : '
                . $alert_status{$alert_n_int}->{'content'} . "\n"
                . 'Count       : '
                . $alert_status{$alert_n_int}->{'alert_count'} . "\n"
                . 'Threshold   : '
                . $alert_status{$alert_n_int}->{'alert_threshold'} . "\n"
                . 'Date & Time : '
                . $alert_status{$alert_n_int}->{'last_time'} . "\n";
            if (sendemail(
                    $tt{ $tt_sorted[0] }, $alert_status{$alert_n_int},
                    $content
                )
                )
            {
                $alert_status{$alert_n_int}->{'alert_sent'} = 'Yes';
            }

        }    # if ($alert_status...
    }
    else {

    # The query was successful (ie status = 1) hence
    # print if there was an old alert else do not print
    # If alert_count != 0 (previously was alerting), then set alert_print_flag
        if ( $alert_status{$alert_n_int}->{'alert_count'} != 0 ) {
            $alert_print_flag = 1;
        }

        # Reset the count, sent and last_time
        $alert_status{$alert_n_int}->{'alert_count'} = 0;
        $alert_status{$alert_n_int}->{'status'}      = $status;

        #        $alert_status{$alert_n_int}->{'alert_sent'}  = 'No';
        $alert_status{$alert_n_int}->{'last_time'} = $alert_time;

        # Sent email if alert_on_up is set to 1 (yes)
        # and alert_count has been reset to 0
        if (   $alert_status{$alert_n_int}->{'alert_on_up'}
            && $alert_print_flag
            && ( $alert_status{$alert_n_int}->{'alert_sent'} eq 'Yes' ) )
        {
            my $content = 'Subject: SNM status = UP for device: '
                . $alert_status{$alert_n_int}->{'device'} . ' ['
                . $alert_status{$alert_n_int}->{'content'} . ']' . "\n"
                . 'SNM status  = UP for:' . "\n"
                . 'Device (IP) : '
                . $alert_status{$alert_n_int}->{'device'} . ' ('
                . $tt{ $tt_sorted[0] }->{ip_address} . ")\n"
                . 'Interface   : '
                . $temp_int_id . "\n"
                . 'Content     : '
                . $alert_status{$alert_n_int}->{'content'} . "\n"
                . 'Date & Time : '
                . $alert_status{$alert_n_int}->{'last_time'} . "\n";
            if (sendemail(
                    $tt{ $tt_sorted[0] }, $alert_status{$alert_n_int},
                    $content
                )
                )
            {
                $alert_status{$alert_n_int}->{'alert_sent'} = 'No';
            }
        }
    }    #if-else ( $alert_status

    # If $alert_print_flag != 0 update the
    #list of alerts ($alert_list) and write it to the alert file
    if ( $alert_print_flag != 0 ) {
        foreach $metricid ( sort keys %alert_status ) {
            if ( $alert_status{$metricid}->{'status'} ne '1' ) {
                push(
                    @{ $alert_list->{alerts}->{alert} },
                    $alert_status{$metricid}
                );
            }
        }

        # Open the alert file (default: alert.xml) and
        # insert the list of alerts ($alert_list)
        open( ALERTFILE, ">" . $cfg->{alert}->{file} )
            or die_log( 'AlertMail |Failure to open/create alert file '
                . '        Please check directory and permissions. '
                . $! );
        print( ALERTFILE XMLout( $alert_list, KeyAttr => '' ) );
        close(ALERTFILE)
            or print_log( 'AlertMail |Failure to close alert file: ' . $! );
        $alert_list       = ();
        $alert_print_flag = 0;
    }
    return;
}

#________ sendemail(): send an email ___________________________________________________
#
sub sendemail {

    # $sm_tt0             = $tt{ $tt_sorted[0] }
    # $sm_alert_status    = $alert_status{$alert_n_int}
    # $sm_mail_message    = The content of the message to send
    my ( $sm_tt0, $sm_alert_status, $sm_mail_message ) = @_;
    my $smtp_message;

    # Connect to mail server if it is defined
    if ( defined( $cfg->{mail}->{server} ) ) {
        my $smtp = Net::SMTP->new( $cfg->{mail}->{server} );
        if ( !defined($smtp) ) {
            print_log('AlertMail |Unable to connect to mail server: '
                    . $cfg->{mail}->{server}
                    . ' Error sending mailto:'
                    . $sm_tt0->{if_alert_email}
                    . '  for device:'
                    . $sm_alert_status->{'device'} );
        }
        else {

            # display for alerts
            my $temp_int_id;
            if ( $sm_alert_status->{'if_desc'} eq ' ' ) {
                $temp_int_id = $sm_alert_status->{'interface'};
            }
            else {
                $temp_int_id = $sm_alert_status->{'interface'} . '('
                    . $sm_alert_status->{'if_desc'} . ')';
            }

            # turn email string into an array
            my @emails = split( /[;,]/, $sm_tt0->{if_alert_email} );

            # if authentication to mail server configured
            if ( defined $cfg->{mail}->{username} ) {
                $smtp->auth( $cfg->{mail}->{username},
                    $cfg->{mail}->{password} );
                if ( not $smtp->ok() ) {

                    # strip non-printable, leading and trailing whitespace
                    ( $smtp_message = $smtp->message ) =~ s/[^[:print:]]//g;
                    print_log('AlertMail |Authentication failure'
                            . ' to e-mail server ('
                            . $cfg->{mail}->{server} . ') :'
                            . $smtp_message );
                }
            }

            # send the alert mail
            $smtp->mail( $cfg->{mail}->{from} );
            $smtp->to(@emails);
            $smtp->data();
            $smtp->datasend($sm_mail_message);
            $smtp->dataend();

            # test if e-mail sent OK
            if ( $smtp->ok() ) {
                print_log('AlertMail |mailto:'
                        . $sm_tt0->{if_alert_email}
                        . '  for device:'
                        . $sm_alert_status->{'device'} );
            }
            else {

                # strip non-printable, leading and trailing whitespace
                ( $smtp_message = $smtp->message ) =~ s/[^[:print:]]//g;
                print_log('AlertMail |Failure sending e-mail to ('
                        . $sm_tt0->{if_alert_email}
                        . ') Error: '
                        . $smtp_message );
            }

            # Disconnect from the mail server
            $smtp->quit();
            return (1);

            #            $sm_alert_status->{'alert_sent'} = 'Yes';
        }    # if-else ( !defined ($smtp)...
    }    # if (defined($cfg->{mail}->{server}...
    return (0);
}

#________ debug(): print debug data to stdout __________________________________________
#
sub debug {
    if ($opt_v) {
        print_log(@_);
    }
    return;
}

#________ sigint(): close the snmp session if open _____________________________________
#
sub sigint {
    print_log( 'Signal: ' . @_ . ', detected, cleaning up' );
    sleep 10;
    if ( defined($session) ) {
        &debug('sigint    |SNMP session open, closing it');
        $session->close();
    }
    exit(0);
}

