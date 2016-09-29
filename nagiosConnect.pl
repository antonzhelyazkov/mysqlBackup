#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Proc::ProcessTable;

my $pidFile;
my $pidNumber;
my $process;
my $ref = new Proc::ProcessTable;
my $found = 0;

GetOptions (    "pid-file=s"    => \$pidFile,
                "process=s"     => \$process) or exit(2);

if (!defined($process) || !defined($pidFile)) {
        print "CRITICAL Usage --pid-file=/path/to/file.pid --process\'<CMD>\'\n";
        exit(2);
        }

if (open(PID, '<:encoding(UTF-8)', $pidFile)) {
        while (my $row = <PID>) {
                chomp $row;
                $pidNumber = $row;
        }
} else {
        if ( !-f $pidFile ) {
                print "OK file $pidFile does not exist | status=0";
                exit(0);
        } else {
                print "CRITICAL Could not open file '$pidFile' $!";
                exit(2);
        }
}

close PID;

if ( -e $pidFile ) {
        foreach my $proc (@{$ref->table}) {
                if ( $pidNumber == $proc->{pid} && $process eq $proc->{cmndline} ){
                        $found = 1;
                        print "OK file $pidFile exists and process $proc->{cmndline} with ID $proc->{pid} is running | status=1";
                        exit(0);
                }
        }
} else {
        print "OK file $pidFile does not exists | status=0";
        exit(0);
}

if ( !$found ) {
        print "WARNING file $pidFile exists but no process $process with ID $pidNumber is running | status=2";
        exit(1);
}
