#!/usr/bin/perl

use strict;
use Getopt::Long;
use DBI;
use IO::Compress::Gzip qw(gzip $GzipError);
use File::Copy;
use Time::Piece;
use Time::Local;
use File::Path;
use Net::FTP;
use Sys::Hostname;

my $remoteCopyDays = 1;
my $hostname =  hostname;
my @hostname = split('\.', $hostname);
my $ftpDir1 = $hostname[0];
my $timeCode;
my $deleteTime = time() - ($remoteCopyDays * 86400);
my $localDirectoryName = "mysql";

#my $ftp = Net::FTP->new( "$ftpHost", Port => "$ftpPort", Debug => 0, Timeout => 2 );
#$ftp->login( $ftpUser, $ftpPass ) or return "Cannot login ", $ftp->message;

my $ftpHost = "212.73.140.112";
my $ftpUser = "backup2";
my $ftpPass = "JTGskszpLUrx7HAJ";


sub dateToEpoch {
my $date = shift;
my @date = split /-/, $date;

$date[0] =~ s/\b0+(?=\d)//g;
$date[1] =~ s/\b0+(?=\d)//g;
$date[2] =~ s/\b0+(?=\d)//g;

return timelocal(0,0,0,$date[2],$date[1]-1,$date[0]);
}

my $curlCommand = "curl -s -l ftp://$ftpHost/$ftpDir1/$localDirectoryName/ --user $ftpUser:$ftpPass";

my @dirs = `$curlCommand`;

foreach my $dir (@dirs) {
	chomp $dir;
	$timeCode = $dir;
	print $deleteTime." ".dateToEpoch($timeCode)."\n";
	if (dateToEpoch($timeCode) < $deleteTime) {
		my $curlCommandSubdir = "curl -s -l ftp://$ftpHost/$ftpDir1/$localDirectoryName/$timeCode/ --user $ftpUser:$ftpPass";
		print $curlCommandSubdir . "\n";
		my @subDirs = `$curlCommandSubdir`;
		foreach my $subDir (@subDirs) {
			chomp $subDir;
			my $curlListDatabasesDirs = "curl -s -l ftp://$ftpHost/$ftpDir1/$localDirectoryName/$timeCode/$subDir/ --user $ftpUser:$ftpPass";
			print $curlListDatabasesDirs . "\n";
			my @listDatabases = `$curlListDatabasesDirs`;
			foreach my $database (@listDatabases) {
				chomp $database;
				my $curlListTables = "curl -s -l ftp://$ftpHost/$ftpDir1/$localDirectoryName/$timeCode/$subDir/$database/ --user $ftpUser:$ftpPass";
				my @listTables = `$curlListTables`;
				foreach my $databaseTable (@listTables) {
					chomp $databaseTable;
					my $curlRemoveTable = "curl -s --user $ftpUser:$ftpPass ftp://$ftpHost -Q \"DELE $ftpDir1/$localDirectoryName/$timeCode/$subDir/$database/$databaseTable\"";
					print $curlRemoveTable . "\n";
					system($curlRemoveTable);
				}
				my $curlRemoveDatabaseDir = "curl -s --user $ftpUser:$ftpPass ftp://$ftpHost -Q \"RMD $ftpDir1/$localDirectoryName/$timeCode/$subDir/$database/\"";
				system($curlRemoveDatabaseDir);
			}
			my $curlRemoveHourDir = "curl -s --user $ftpUser:$ftpPass ftp://$ftpHost -Q \"RMD $ftpDir1/$localDirectoryName/$timeCode/$subDir/\"";
			system($curlRemoveHourDir);
		}
		my $curlRemoveTimecodeDir = "curl -s --user $ftpUser:$ftpPass ftp://$ftpHost -Q \"RMD $ftpDir1/$localDirectoryName/$timeCode/\"";
		system($curlRemoveTimecodeDir);
	}
}

#for my $dir (@dirs) {
#        next if ($dir =~ /\./);
#        $timeCode = $dir;
#        $timeCode =~ s/$ftpDir1\/$localDirectoryName\///;
#        if (dateToEpoch($timeCode) < $deleteTime) {
#                LogPrint("Removing Directory $dir");
#                $ftp->rmdir($dir, 1);
#                if ($ftp->cwd($dir)) {
#                        LogPrint("Error Remove directory failed $dir", 1);
#                } else {
#                        LogPrint("OK Directory $dir successfully removed", 1);
#                }
#        }
#}
