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

my $stopSlave;
my $verbose;
my $dbName;
my $table;
my $tmpDir;
my $excludeTable;
my $excludeDatabase;
my $ignoreSlaveRunning;
my $pigz;
my $pigzPath;
my $pigzCommand;
my $mysqldumpCommand;
my $keepLocalCopy;
my $localCopyPath;
my $localCopyDays;
my $keepRemoteCopy;
my $remoteCopyDays;
my $ftpHost;
my $ftpPort;
my $ftpUser;
my $ftpPass;
my $logFile;
my $nagiosInf;
my $nagiosAlarm;
my $mysqlDumpBinary;

my $mysqlRootPass;
my $mysqlHost;
my $mysqlUser = "root";
my $mysqlPort;

my $mysqlHostDefault = "127.0.0.1";
my $mysqlPortDefault = 3306;

my $tmpDirDefault = "/var/tmp";
my $mysqlDumpBinaryDefault = "/bin/mysqldump";
my $logFileDefault = "/var/log/mysqlBackup.log";
my $pigzPathDefault = "/bin/pigz";
my $ftpPortDefault = 21;
my $localDirectoryName = "mysql";
my $nagiosInfDefault = "/usr/local/share/nagios.inf";

my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
my $dateStamp = sprintf "%4u-%02u-%02u", $year+1900, $mon+1, $mday;
my $hourStamp = sprintf "%02u-%02u", $hour, $min;

GetOptions (    "local-copy"		=> \$keepLocalCopy,
		"local-copy-path=s"	=> \$localCopyPath,
		"local-copy-days=i"	=> \$localCopyDays,
                "stop-slave"            => \$stopSlave,         # string
                "database=s"            => \$dbName,
                "password=s"            => \$mysqlRootPass,
		"host=s"		=> \$mysqlHost,
		"port=i"		=> \$mysqlPort,
                "verbose"               => \$verbose,           # flag
                "ignore-slave-running"  => \$ignoreSlaveRunning,
                "exclude-table=s"       => \$excludeTable,
                "exclude-database=s"    => \$excludeDatabase,
		"pigz"			=> \$pigz,
		"pigz-path=s"		=> \$pigzPath,
		"remote-copy"		=> \$keepRemoteCopy,
		"remote-copy-days=i"	=> \$remoteCopyDays,
		"ftp-host=s"		=> \$ftpHost,
		"ftp-port=i"		=> \$ftpPort,
		"ftp-user=s"		=> \$ftpUser,
		"ftp-pass=s"		=> \$ftpPass,
		"log-file=s"		=> \$logFile,
		"nagios-alarm"		=> \$nagiosAlarm,
		"nagios-inf-file=s"	=> \$nagiosInf,
		"mysqldump-binary=s"	=> \$mysqlDumpBinary,
                "tmpdir=s"              => \$tmpDir)
                or die("Error in command line arguments\n");

##### functions #####

sub LogPrint {

my $message = shift;
my $nagiosAlert = shift;

if ( $verbose == 1 ) {
        print "$message\n";
}

open (LOG, ">>$logFile") or die "Could not open file '$logFile' $!";;
print LOG localtime()." $message\n";
close LOG;

if (defined($nagiosAlarm) && defined($nagiosAlert)){
	if (open (INF, ">>$nagiosInf")) {
		print INF "$message\n";
		close INF;
	} else {
		open (LOG, ">>$logFile");
		print LOG localtime()."Could not open $nagiosInf";
		close LOG;
	}
}
}

sub showDatabases {

my $row;
my @databases;
my @databases_to_backup;
my $dbh = DBI->connect( "DBI:mysql:mysql;host=$mysqlHost;port=$mysqlPort", $mysqlUser, $mysqlRootPass, { RaiseError => 1 } ) or die( "Couldn't connect to database: " . DBI->errstr );
my $databases_to_backup = $dbh->prepare('show databases');
$databases_to_backup->execute();

while ( my $row = $databases_to_backup->fetchrow_arrayref ) {
        push @databases, @$row;
}

$databases_to_backup->finish();
$dbh->disconnect;

for (@databases) {
        next if $_ =~ /^\#/;
        next if $_ =~ /mysql/;
        next if $_ =~ /performance_schema/;
        next if $_ =~ /test/;
        next if $_ =~ /information_schema/;
        push( @databases_to_backup, $_ );
}

return @databases_to_backup;

}

sub showTables {

my $database = shift;
my $row;
my @tables;
my @tables_to_backup;
my $dbh = DBI->connect( "DBI:mysql:database=$database;host=$mysqlHost;port=$mysqlPort", $mysqlUser, $mysqlRootPass, { RaiseError => 1 } ) or die( "Couldn't connect to database: " . DBI->errstr );
my $tables_to_backup = $dbh->prepare('show tables');
$tables_to_backup->execute();

while ( my $row = $tables_to_backup->fetchrow_arrayref ) {
        push @tables, @$row;
}

$tables_to_backup->finish();
$dbh->disconnect;

#print "showTables in $database\n";
return @tables;

}

sub parseExcludeTable {
my @tables = split(/,/, $excludeTable);
return @tables;
}

sub parseExcludeDatabase {
my @databases = split(/,/, $excludeDatabase);
return @databases;
}

sub showSlaveStatus {

my $dbh = DBI->connect( "DBI:mysql:mysql;host=$mysqlHost;port=$mysqlPort", $mysqlUser, $mysqlRootPass, { RaiseError => 1 } ) or die( "Couldn't connect to database: " . DBI->errstr );

my $slaveStatus = $dbh->prepare('show slave status');
$slaveStatus->execute();
my $results = $slaveStatus->fetchrow_hashref();
$slaveStatus->finish();
$dbh->disconnect;

if (!$results || $results->{"Slave_SQL_Running"} ne 'Yes') {
        LogPrint("Slave SQL thread is NOT RUNNIG or NOT configured");
        return 1;
}

if ($results->{"Slave_SQL_Running"} eq 'Yes') {
        LogPrint("OK Slave SQL thread is RUNNIG", 1);
        return 0;
}

}

sub stopSlave {

LogPrint("Stopping Slave");
my $dbh = DBI->connect( "DBI:mysql:mysql;host=$mysqlHost;port=$mysqlPort", $mysqlUser, $mysqlRootPass, { RaiseError => 1 } ) or die( "Couldn't connect to database: " . DBI->errstr );
my $slaveStop = $dbh->do('stop slave');
$dbh->disconnect;

}

sub startSlave {

LogPrint("Starting Slave");
my $dbh = DBI->connect( "DBI:mysql:mysql;host=$mysqlHost;port=$mysqlPort", $mysqlUser, $mysqlRootPass, { RaiseError => 1 } ) or die( "Couldn't connect to database: " . DBI->errstr );
my $slaveStop = $dbh->do('start slave');
$dbh->disconnect;

}

sub createLocalDirectory {

my $database = shift;

if ( !-d "$localCopyPath\/$localDirectoryName" ) {
	mkdir("$localCopyPath\/$localDirectoryName" );
}

if ( !-d "$localCopyPath\/$localDirectoryName\/$dateStamp" ) {
        mkdir("$localCopyPath/$localDirectoryName/$dateStamp");
}

if ( !-d "$localCopyPath\/$localDirectoryName\/$dateStamp\/$hourStamp" ) {
	mkdir("$localCopyPath\/$localDirectoryName\/$dateStamp\/$hourStamp");
}

if ( !-d "$localCopyPath\/$localDirectoryName\/$dateStamp\/$hourStamp\/$database" ) {
        mkdir("$localCopyPath\/$localDirectoryName\/$dateStamp\/$hourStamp\/$database");
}

return "$localCopyPath\/$localDirectoryName\/$dateStamp\/$hourStamp\/$database/";

}

sub removeLocalDirectory {

my $deleteTime = time() - ($localCopyDays * 86400);

if ( -d "$localCopyPath\/$localDirectoryName" ) {
	opendir (DIR, "$localCopyPath\/$localDirectoryName");
	my @folder = readdir(DIR);
	foreach my $f (@folder) {
		next if ($f =~ /\./);
		next if (scalar((stat("$localCopyPath\/$localDirectoryName\/$f"))[9]) > $deleteTime);
		rmtree("$localCopyPath\/$localDirectoryName\/$f");
		if (-d "$localCopyPath\/$localDirectoryName\/$f") {
			LogPrint("Error Could not remove directory $localCopyPath\/$localDirectoryName\/$f", 1);
		} else {
			LogPrint("OK Directory $localCopyPath\/$localDirectoryName\/$f deleted", 1);
		}
	}
}
}

sub removeRemoteDirectory {

my $hostname =  hostname;
my @hostname = split('\.', $hostname);
my $ftpDir1 = $hostname[0];
my $timeCode;
my $deleteTime = time() - ($remoteCopyDays * 86400);

my $ftp = Net::FTP->new( "$ftpHost", Port => "$ftpPort", Debug => 0, Timeout => 2 );
$ftp->login( $ftpUser, $ftpPass ) or return "Cannot login ", $ftp->message;
my @dirs = $ftp->ls("$ftpDir1\/$localDirectoryName");

for my $dir (@dirs) {
	next if ($dir =~ /\./);
	$timeCode = $dir;
	$timeCode =~ s/$ftpDir1\/$localDirectoryName\///;
	if (dateToEpoch($timeCode) < $deleteTime) {
		LogPrint("Removing Directory $dir");
		$ftp->rmdir($dir, 1);
		if ($ftp->cwd($dir)) {
			LogPrint("Error Remove directory failed $dir", 1);
		} else {
			LogPrint("OK Directory $dir successfully removed", 1);
		}
	}
}

$ftp->close();
}

sub ftpTransfer {

my $tmpFile = shift;
my $hostname =  hostname;
my @hostname = split('\.', $hostname);
my $ftpDir1 = $hostname[0];
my $database = shift;

$tmpFile =~ s/$tmpDir//;

my $ftpDir2 = "$ftpDir1\/$localDirectoryName";
my $ftpDir3 = "$ftpDir1\/$localDirectoryName\/$dateStamp";
my $ftpDir4 = "$ftpDir1\/$localDirectoryName\/$dateStamp\/$hourStamp";
my $ftpDir5 = "$ftpDir1\/$localDirectoryName\/$dateStamp\/$hourStamp\/$database";

my $ftp = Net::FTP->new( "$ftpHost", Port => "$ftpPort", Debug => 0, Timeout => 2 );

if ( $ftp ) {
	LogPrint("ftp connection to $ftpHost established");
	$ftp->login( $ftpUser, $ftpPass ) or return "Cannot login ", $ftp->message;
	$ftp->binary();
	$ftp->mkdir($ftpDir1);
	$ftp->mkdir($ftpDir2);
	$ftp->mkdir($ftpDir3);
	$ftp->mkdir($ftpDir4);
	$ftp->mkdir($ftpDir5);
	LogPrint("FTP Transfer $tmpFile, $ftpDir5$tmpFile");
	$ftp->put( "$tmpDir$tmpFile", "$ftpDir5$tmpFile" ) or return "Error in transfer $tmpFile", $ftp->message;

	if ( $ftp->size("$ftpDir5$tmpFile") == (-s "$tmpDir$tmpFile") ) {
		LogPrint("OK ftp transfer to $ftpHost is successful", 1);
	} else {
		LogPrint("Error ftp transfer to $ftpHost FAILED", 1);
	}
	$ftp->close();
} else {
	LogPrint("Error ftp connection to $ftpHost NOT established", 1);
}
}

sub dateToEpoch {
my $date = shift;
my @date = split /-/, $date;

$date[0] =~ s/\b0+(?=\d)//g;
$date[1] =~ s/\b0+(?=\d)//g;
$date[2] =~ s/\b0+(?=\d)//g;

return timelocal(0,0,0,$date[2],$date[1]-1,$date[0]);
}

sub help {

my @showHelpMsg =
        (
                "USAGE:",
		"--local-copy",
                "--local-copy-path",
                "--local-copy-days",
                "--stop-slave",
                "--database",
                "--password",
                "--host",
                "--port",
                "--verbose",
                "--ignore-slave-running",
                "--exclude-table",
                "--exclude-database",
                "--pigz",
                "--pigz-path",
                "--remote-copy",
                "--remote-copy-days",
                "--ftp-host",
                "--ftp-port",
                "--ftp-user",
                "--ftp-pass",
                "--tmpdir",
		"--log-file",
		"--nagios-alarm",
		"--nagios-inf-file",
		"--mysqldump-binary",
		"",
		"example: /mysqlBackup.pl --password=<mysql root password> --tmpdir=/tmp/ --exclude-database=vod,c1neterraf1b,bgmedia --stop-slave --local-copy --local-copy-days=1 --local-copy-path=/var/tmp --remote-copy --remote-copy-days=1 --ftp-host=<host/ip> --ftp-port=<port> --ftp-user=<user> --ftp-pass=<password>",
        );

print join("\n", @showHelpMsg);

}

##### Main #####

if ( !defined($keepLocalCopy) && !defined($localCopyPath) && !defined($localCopyDays) && !defined($stopSlave) && !defined($dbName) && !defined($mysqlRootPass) && !defined($mysqlHost) && !defined($mysqlPort) && !defined($verbose) && !defined($ignoreSlaveRunning) && !defined($excludeTable) && !defined($excludeDatabase) && !defined($pigz) && !defined($pigzPath) && !defined($tmpDir) && !defined($keepRemoteCopy) && !defined($remoteCopyDays) && !defined($ftpHost) && !defined($ftpPort) && !defined($ftpUser) && !defined($ftpPass) && !defined($nagiosAlarm) && !defined($nagiosInf) && !defined($mysqlDumpBinary)) {
	help();
	exit(0);
}

if (defined($nagiosInf) && !defined($nagiosAlarm)) {
	LogPrint("You must add --nagios-inf-file");
	exit(0);
}

if (defined($nagiosAlarm) && !defined($nagiosInf)) {
	$nagiosInf = $nagiosInfDefault;
}

if (defined($nagiosAlarm)){
	if ( open(INF, '>', $nagiosInf) ){
		print INF $$."\n";
		print INF time()."\n";
		close INF;
	} else {
		LogPrint("Could not write to $nagiosInf");
		exit(1);
	}
}

if (!defined($logFile)) {
	$logFile = $logFileDefault;
}

if (!defined $dbName) {
        $dbName = "all";
}

if (!defined $mysqlHost) {
        $mysqlHost = $mysqlHostDefault;
}

if (!defined $mysqlPort) {
        $mysqlPort = $mysqlPortDefault;
}

if (defined $pigz) {
	if (!defined $pigzPath){
		if (!-f $pigzPathDefault) {
			LogPrint("PIGZ option is turned ON. PIGZ binary not found in $pigzPathDefault. Turn off PIGZ or point PIGZ binary");
			exit(1);
		} else {
			$pigzPath = $pigzPathDefault;
		}
	} else {
		if (!-f $pigzPath) {
			LogPrint("PIGZ option is turned ON. PIGZ binary not found in $pigzPath. Turn off PIGZ or point correct PIGZ binary");
			exit(1);
		}
	}
}

if (!defined($keepLocalCopy) && !defined($keepRemoteCopy)) {
	LogPrint("You must set destination --local-copy or --remote-copy");
	exit(1);
}

if (defined $keepLocalCopy && (!defined $localCopyPath || !defined $localCopyDays)) {
	LogPrint("If you want to use --local-copy, you must define --local-copy-path and --local-copy-days");
	exit(1);
} else {
	if ( !-d $localCopyPath ) {
		LogPrint("Destination does not exist. Try mkdir -p $localCopyPath");
		exit(1);
	}
}

if ( defined($remoteCopyDays) && $remoteCopyDays < 1 ) {
	LogPrint("Value --local-copy-days must be greater or equal to 1");
	exit(1)
}

if ( defined($localCopyDays) && $localCopyDays < 1 ) {
        LogPrint("Value --local-copy-days must be greater or equal to 1");
        exit(1)
}

if (!defined $pigz && defined $pigzPath) {
	LogPrint("Unused option --pigz-path");
	exit(1);
}

if (defined($keepRemoteCopy) && (!defined($remoteCopyDays) || !defined($ftpHost) || !defined($ftpPort) || !defined($ftpUser) || !defined($ftpPass)) ) {
	LogPrint("If you want to use ftp storage add --remote-copy --remote-copy-days=<days> --ftp-host=<ip\/host> --ftp-port=<default 21> --ftp-user=<user> --ftp-pass=<pass>");
	exit(1);
}

if (!defined($keepRemoteCopy) && (defined($remoteCopyDays) || defined($ftpHost) || defined($ftpPort) || defined($ftpUser) || defined($ftpPass)) ) {
        LogPrint("If you want to use ftp storage add --remote-copy --remote-copy-days=<days> --ftp-host=<ip\/host> --ftp-port=<default 21> --ftp-user=<user> --ftp-pass=<pass>");
        exit(1);
}

if (!defined($ftpPort)) {
	$ftpPort = $ftpPortDefault;
}

if ( $dbName eq "all" && defined $excludeTable ) {
        LogPrint("You can use --exclude-table if database is defined");
        exit(1);
}

if (!defined $mysqlRootPass) {
        LogPrint("must provide MySQL root password");
	exit(1);
}

if (!defined($mysqlDumpBinary)){
	$mysqlDumpBinary = $mysqlDumpBinaryDefault;
}

if (!-f $mysqlDumpBinary) {
        LogPrint("mysqldump not found $mysqlDumpBinary");
	exit(1);
}

if (!defined $tmpDir) {
        $tmpDir = $tmpDirDefault;
}

if ($tmpDir=~/(.*)\/$/) {
        $tmpDir = $1;
}

if ($localCopyPath=~/(.*)\/$/) {
        $localCopyPath = $1;
}

if (!-d $tmpDir) {
        LogPrint("Directory $tmpDir does not exist");
        exit(1);
}

if ( $dbName ne "all" && defined $excludeDatabase ) {
        LogPrint("Remove --exclude-database or --database");
        exit(1);
}

if ( defined $ignoreSlaveRunning && defined $stopSlave ) {
        LogPrint("Unwanted option --ignore-slave-running or --stop-slave");
        exit(1);
}

if ( !showSlaveStatus() && !defined $ignoreSlaveRunning && !defined $stopSlave ) {
        LogPrint("Slave is RUNNING Exit! You must use --ignore-slave-running or --stop-slave");
        exit(1);
}

if ( showSlaveStatus() && (defined $ignoreSlaveRunning || defined $stopSlave) ) {
        LogPrint("Slave is NOT RUNNING unwanted option --ignore-slave-running or --stop-slave EXIT!");
        exit(1);
}

if ( defined $stopSlave ) {
        stopSlave();
	sleep 1;
	if ( !showSlaveStatus() ) {
		LogPrint("Slave is running after \"SLAVE STOP\" command. Problem!!!");
		exit(1);
	} else {
		LogPrint("OK Slave stopped", 1);
	}
}

if ( $dbName eq "all" ) {
        for my $db (showDatabases()){
                if ( grep( /$db/, parseExcludeDatabase() ) ) {
                        LogPrint("Database $db is mark as excluded");
                        next;
                }
                for $table (showTables($db)) {
			if (defined $pigz) {
				$pigzCommand = "$mysqlDumpBinary $db $table | $pigzPath > $tmpDir/$table.sql.gz";
				#print "$pigzCommand\n";
				system($pigzCommand);
				if (defined($keepLocalCopy)) {
					copy("$tmpDir/$table.sql.gz",createLocalDirectory($db)) or LogPrint("Error in $db $table.sql.gz", 1);
				}
				if (defined($keepRemoteCopy)) {
					ftpTransfer("$tmpDir/$table.sql.gz", $db);
				}
				unlink("$tmpDir/$table.sql.gz");
			} else {
				$mysqldumpCommand = "$mysqlDumpBinary $db $table > $tmpDir/$table.sql";
				#print "$mysqldumpCommand\n";
				system($mysqldumpCommand);
				gzip "$tmpDir/$table.sql" => "$tmpDir/$table.sql.gz" or die "gzip failed: $GzipError\n";
				if (defined($keepLocalCopy)) {
					copy("$tmpDir/$table.sql.gz",createLocalDirectory($db)) or LogPrint("Error in $db $table.sql.gz", 1);
				}
				if (defined($keepRemoteCopy)) {
                                        ftpTransfer("$tmpDir/$table.sql.gz", $db);
                                }
				unlink("$tmpDir/$table.sql");
				unlink("$tmpDir/$table.sql.gz");
			}
                }
        }
} else {
        for $table (showTables($dbName)) {
                if ( grep( /$table/, parseExcludeTable() ) ) {
                        LogPrint("Table $table is mark as excluded");
                        next;
                }
		if (defined $pigz) {
                	$pigzCommand = "$mysqlDumpBinary $dbName $table | $pigzPath > $tmpDir/$table.sql.gz";
			#print "$pigzCommand\n";
			system($pigzCommand);
			if (defined($keepLocalCopy)) {
				copy("$tmpDir/$table.sql.gz",createLocalDirectory($dbName)) or LogPrint("Error in $dbName $table.sql.gz", 1);
			}
			if (defined($keepRemoteCopy)) {
                        	ftpTransfer("$tmpDir/$table.sql.gz", $dbName);
                        }
			unlink("$tmpDir/$table.sql.gz");
		} else {
			$mysqldumpCommand = "$mysqlDumpBinary $dbName $table > $tmpDir/$table.sql";
			#print "$mysqldumpCommand\n";
			system($mysqldumpCommand);
			gzip "$tmpDir/$table.sql" => "$tmpDir/$table.sql.gz" or die "gzip failed: $GzipError\n";
			if (defined($keepLocalCopy)) {
				copy("$tmpDir/$table.sql.gz",createLocalDirectory($dbName)) or LogPrint("Error in $dbName $table.sql.gz", 1);
			}
			if (defined($keepRemoteCopy)) {
                                ftpTransfer("$tmpDir/$table.sql.gz", $dbName);
                        }
			unlink("$tmpDir/$table.sql");
			unlink("$tmpDir/$table.sql.gz");
		}
        }
}

if ( defined($keepLocalCopy)) {
	removeLocalDirectory();
}

if ( defined($keepRemoteCopy)) {
	removeRemoteDirectory();
}

if ( defined($stopSlave)) {
        startSlave();
        sleep 1;
        if ( showSlaveStatus() ) {
                LogPrint("Error Slave is NOT running after \"SLAVE START\" command. Problem!!!", 1);
                exit(1);
        }
}

if (defined($nagiosAlarm)){
	open(INF, '>>', $nagiosInf);
	print INF time()."\n";
        close INF;
}
