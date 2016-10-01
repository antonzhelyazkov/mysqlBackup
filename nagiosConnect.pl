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
my $startTime;
my $cronInterval;
my $cronTimeBuffer = 7200;
my $errorCounter = 0;

GetOptions (    "inf-file=s"   		=> \$infFile,
		"cron-interval=i"	=> \$cronInterval,
                "process=s"		=> \$process) or exit(2);

if (!defined($infFile)) {
	$infFile = $infFileDefault;
}

if (!-f $infFile) {
	print "WARNING INF File $infFile not found | status=0";
	exit(1);
}

if (!defined($process)) {
        $process = $processDefault;
}

if (open(INF, '<:encoding(UTF-8)', $infFile)) {
	@infLines = <INF>;
	close INF;
} else {
	print "CRITICAL Could not open file '$infFile' $! | status=0";
	exit(1);
}

$infLines[0] =~ s/PID\s//;
$pidNumber = $infLines[0];
$startTime = $infLines[1];
$startTime =~ s/startTime\s//g;
$lastLinesElementNumber = scalar(@infLines);

foreach my $proc (@{$ref->table}) {
	if ( $pidNumber == $proc->{pid} && $proc->{cmndline} =~ m/$process/){
#		print $proc->{pid};
#		print $proc->{cmndline} ."\n";
		$found = 1;
		print "OK file $infFile exists and process $proc->{cmndline} with ID $proc->{pid} is running | status=1";
		exit(0);
	}
}

if (defined($cronInterval)){
	my $cronIntervalSeconds = $cronInterval * 3600;
	if (time() > ($cronIntervalSeconds + $startTime + $cronTimeBuffer)) {
		print "WARNING backup has not started more than ".($cronInterval + $cronTimeBuffer / 3600)." hours Possible backup problem! | status=0";
		exit(1);
	}
}

if ($infLines[$lastLinesElementNumber - 1] !~ m/endTime\s\d+/ && $found == 0 ) {
	print "WARNING no end timestamp in $infFile and NO running process $process. Possible backup problem! | status=0";
	exit(1);
}

for ( my $i = 2; $i < scalar(@infLines) - 2; $i++ ) {
	if ( $infLines[$i] =~ m/^Error/) {
		$errorCounter++;
	}
}

if ( $errorCounter > 0 ) {
	print "WARNING finished with $errorCounter errors. Possible backup problem! | status=0";
        exit(1);
} else {
	my $endTime = $infLines[$lastLinesElementNumber - 1];
	$endTime =~ s/endTime\s//;
	my $endTimeRead = scalar localtime $endTime;
	print "OK backup finished successfuly at $endTimeRead | status=0";
}
