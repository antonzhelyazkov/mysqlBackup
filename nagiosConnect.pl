#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Proc::ProcessTable;

my $pidNumber;
my $process;
my $ref = new Proc::ProcessTable;
my $infFileDefault = "/usr/local/share/nagios.inf";
my $found = 0;
my $infFile;
my $processDefault = "mysqlBackup.pl";
my @infLines;
my $lastLinesElementNumber;

GetOptions (    "inf-file=s"    => \$infFile,
                "process=s"     => \$process) or exit(2);

if (!defined($infFile)) {
	$infFile = $infFileDefault;
}

if (!-f $infFile) {
	print "CRITICAL INF File $infFile not found\n";
	exit(2);
}

if (!defined($process)) {
        $process = $processDefault;
}

if (open(INF, '<:encoding(UTF-8)', $infFile)) {
	@infLines = <INF>;
	close INF;
} else {
	print "CRITICAL Could not open file '$infFile' $!";
	exit(2);
}

$infLines[0] =~ s/PID\s//;
$pidNumber = $infLines[0];
$lastLinesElementNumber = scalar(@infLines);

foreach my $proc (@{$ref->table}) {
	if ( $pidNumber == $proc->{pid} && $proc->{cmndline} =~ m/$process/){
		print $proc->{pid};
		print $proc->{cmndline} ."\n";
		$found = 1;
		print "OK file $infFile exists and process $proc->{cmndline} with ID $proc->{pid} is running | status=1";
		exit(0);
	}
}

if ($infLines[$lastLinesElementNumber - 1] !~ m/endTime\s\d+/ && $found == 0 ) {
	print "WARNING no end timestamp in $infFile and running process $process. Possible backup problem!| status=2\n";
	exit(1);
}

for ( my $i = 2; $i < scalar(@infLines) - 2; $i++ ) {
	print $infLines[$i];
}

#} else {
#        print "OK file $pidFile does not exists | status=0";
#        exit(0);
#}
#
#if ( !$found ) {
#        print "WARNING file $pidFile exists but no process $process with ID $pidNumber is running | status=2";
#        exit(1);
#}
