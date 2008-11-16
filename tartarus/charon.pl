#!/usr/bin/perl
#
# charon.pl by Stefan Tomanek <stefan.tomanek@wertarbyte.de>
#              http://wertarbyte.de/tartarus.shtml
#
# This script will remove tartarus backup files from an FTP server
# that have reached a certain age.
#
# WARNING: This script will delete your backup data when called
# improperly
#
# Version 0.6.3
#
# Last change: $Date$

use strict;
use warnings;
use Net::FTP;
use Time::Local;
use Getopt::Long;


# your backup FTP server
my $host = undef;
# username and password
my ($user, $pass) = (undef, "");
my $read_password = 0;
my $dir = "/";

my $days_to_expire = 14;
my $uprofile = undef;
my $all = 0;

my $dry_run = 0;
my $verbose = 0;
my $help = 0;

sub usage {
    my ($error) = @_;
    print <<EOF;
charon.pl by Stefan Tomanek <stefan.tomanek\@wertarbyte.de>

    --host          FTP server to connect to
    --user          username to authenticate with
    --password      password to authenticate with
    --readpassword  read password from stdin
    --dir           server directory of the backup files
    --maxage        maximum age of backup files (in days)
    --profile       backup profile to process
    --all           process all files found in the directory
    --dry-run       do a test run, don't actually delete files
    --help          show this help text
EOF
    if (defined $error) {
        print "\n$error\n";
    }
    exit 1;
}

GetOptions(
    "host|h|server=s"   => \$host,
    "username|user|u=s" => \$user,
    "password|p=s"      => \$pass,
    "readpassword|r"    => \$read_password,
    "maxage|m=i"        => \$days_to_expire,
    "profile|p=s"       => \$uprofile,
    "all|a"             => \$all,
    "directory|dir|d=s" => \$dir,
    "test|dry-run|n"    => \$dry_run,
    "verbose|v"         => \$verbose,
    "help|h"            => \$help
) || usage();

usage "No servername specified" unless defined $host;
usage "No username specified" unless defined $user;
usage "Neither --all nor a single backup profile specified" unless ($all || defined $uprofile);

if ($read_password) {
    print STDERR "Reading password:" if $verbose;
    while (<STDIN>) {
        $pass .= $_;
    }
    print STDERR " Thank you.\n" if $verbose;
}

sub string2time {
    my ($time) = @_;

    if ($time =~ /^([0-9]{4})([01][0-9])([0-3][0-9])-([012][0-9])([0-9]{2})$/) {
        my $t = timelocal(0, $5, $4, $3, $2-1, $1);
        return $t;
    }
}

my $ftp = Net::FTP->new($host, Debug => 0, Passive => 1) || die "Unable to connect to server";
$ftp->login($user, $pass) || die "Unable to authenticate, ", $ftp->message();
$ftp->cwd($dir) || die "Error changing to backup directory, ", $ftp->message();
my @listing = $ftp->ls();

my %delete;
for my $filename (sort @listing) {
    if ($filename =~ /^tartarus-(.+?)-([0-9]{4}[01][0-9][0-3][0-9]-[012][0-9][0-9]{2})(?:\.|-inc-([0-9]{4}[01][0-9][0-3][0-9]-[012][0-9][0-9]{2}))?\.(chunk-[0-9]+\.)?(tar|afio)/) {
        my $profile = $1;
        next unless ($all || $uprofile eq $profile);
        my $date = $2;
        my $based_on = $3;
        my $inc = defined $based_on;
        my $age = int( ( time - string2time($date) ) / (60*60*24) );
        
        if ($age > $days_to_expire) {
            print STDERR "$filename is $age days old, scheduling for deletion\n";
            #$delete{$profile}{$date} = $filename;
            # add the file name to the candidate list for deletion
            push @{$delete{$profile}{$date}}, $filename;
        } elsif ($inc && exists $delete{$profile}{$based_on}) {
            # If it is an incremental backup, we have to preserve the full backup it is based on
            print STDERR "Preserving ".$delete{$profile}{$based_on}." for $filename\n";
            delete $delete{$profile}{$based_on};
        }
    }
}

for my $profile (values %delete) {
    for my $archive (values %$profile) {
        for my $file (@$archive) {
            print STDERR "Removing file $file...\n";
            unless ($dry_run) {
                $ftp->delete("$file") || print STDERR "Error removing $file!\n";
            }
        }
    }
}

$ftp->quit();
