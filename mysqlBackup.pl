#!/usr/bin/perl

use strict;
use Getopt::Long;
use DBI;
use IO::Compress::Gzip qw(gzip $GzipError);
use File::Copy;

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

my $mysqlRootPass;
my $mysqlHost;
my $mysqlUser = "root";
my $mysqlPort;

my $mysqlHostDefault = "127.0.0.1";
my $mysqlPortDefault = 3306;

my $tmpDirDefault = "/var/tmp";
my $mysqlDumpBinary = "/bin/mysqldump";
my $logFile = "/var/log/mysqlBackup.log";
my $pigzPathDefault = "/bin/pigz";
my $ftpPortDefault = 21;

my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
#my $formatted = sprintf "%4u-%02u-%02u %02u:%02u:%02u", $year+1900, $mon+1, $mday, $hour, $min, $sec;
my $dateStamp = sprintf "%02u-%02u", $mon+1, $mday;
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
                "tmpdir=s"              => \$tmpDir)
                or die("Error in command line arguments\n");

##### functions #####

sub LogPrint {
my $message = shift;

if ( $verbose == 1 ) {
        print "$message\n";
}

open (LOG, ">>$logFile") or die "Could not open file '$logFile' $!";;
print LOG localtime()." $message\n";
close LOG;

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

print "showTables in $database\n";
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
        LogPrint("Slave SQL thread is RUNNIG");
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

if ( !-d "$localCopyPath\/mysql" ) {
	mkdir("$localCopyPath\/mysql" );
}

if ( !-d "$localCopyPath\/mysql\/$dateStamp" ) {
        mkdir("$localCopyPath/mysql/$dateStamp");
}

if ( !-d "$localCopyPath\/mysql\/$dateStamp\/$hourStamp" ) {
	mkdir("$localCopyPath\/mysql\/$dateStamp\/$hourStamp");
}

if ( !-d "$localCopyPath\/mysql\/$dateStamp\/$hourStamp\/$database" ) {
        mkdir("$localCopyPath\/mysql\/$dateStamp\/$hourStamp\/$database");
}

return "$localCopyPath\/mysql\/$dateStamp\/$hourStamp\/$database/";

}

sub help {
print "HELP\n";
}

##### Main #####

if ( !defined($keepLocalCopy) && !defined($localCopyPath) && !defined($localCopyDays) && !defined($stopSlave) && !defined($dbName) && !defined($mysqlRootPass) && !defined($mysqlHost) && !defined($mysqlPort) && !defined($verbose) && !defined($ignoreSlaveRunning) && !defined($excludeTable) && !defined($excludeDatabase) && !defined($pigz) && !defined($pigzPath) && !defined($tmpDir) && !defined($keepRemoteCopy) && !defined($remoteCopyDays) && !defined($ftpHost) && !defined($ftpPort) && !defined($ftpUser) && !defined($ftpPass) ) {
	help();
	exit(0);
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
			exit(0);
		} else {
			$pigzPath = $pigzPathDefault;
		}
	} else {
		if (!-f $pigzPath) {
			LogPrint("PIGZ option is turned ON. PIGZ binary not found in $pigzPath. Turn off PIGZ or point correct PIGZ binary");
			exit(0);
		}
	}
}

if (!defined($keepLocalCopy) && !defined($keepRemoteCopy)) {
	LogPrint("You must set destination --local-copy or --remote-copy");
	exit(0);
}

if (defined $keepLocalCopy && (!defined $localCopyPath || !defined $localCopyDays)) {
	LogPrint("If you want to use --local-copy, you must define --local-copy-path and --local-copy-days");
	exit(0);
} else {
	if ( !-d $localCopyPath ) {
		LogPrint("Destination does not exist. Try mkdir -p $localCopyPath");
		exit(0);
	}
}

if (!defined $pigz && defined $pigzPath) {
	LogPrint("Unused option --pigz-path");
	exit(0);
}

if (defined($keepRemoteCopy) && (!defined($remoteCopyDays) || !defined($ftpHost) || !defined($ftpPort) || !defined($ftpUser) || !defined($ftpPass)) ) {
	LogPrint("If you want to use ftp storage add --remote-copy --remote-copy-days=<days> --ftp-host=<ip\/host> --ftp-port=<default 21> --ftp-user=<user> --ftp-pass=<pass>");
	exit(0);
}

if (!defined($keepRemoteCopy) && (defined($remoteCopyDays) || defined($ftpHost) || defined($ftpPort) || defined($ftpUser) || defined($ftpPass)) ) {
        LogPrint("If you want to use ftp storage add --remote-copy --remote-copy-days=<days> --ftp-host=<ip\/host> --ftp-port=<default 21> --ftp-user=<user> --ftp-pass=<pass>");
        exit(0);
}

if (!defined($ftpPort)) {
	$ftpPort = $ftpPortDefault;
}

if ( $dbName eq "all" && defined $excludeTable ) {
        LogPrint("You can use --exclude-table if database is defined");
        exit(0);
}

if (!defined $mysqlRootPass) {
        LogPrint("must provide MySQL root password");
}

if (!-f $mysqlDumpBinary) {
        LogPrint("mysqldump not found $mysqlDumpBinary");
}

if (!defined $tmpDir) {
        $tmpDir = $tmpDirDefault;
}

if ($tmpDir=~/(.*)\/$/) {
        $tmpDir = $1;
}

if (!-d $tmpDir) {
        LogPrint("Directory $tmpDir does not exist");
        exit(0);
}

if ( $dbName ne "all" && defined $excludeDatabase ) {
        LogPrint("Remove --exclude-database or --database");
        exit(0);
}

if ( defined $ignoreSlaveRunning && defined $stopSlave ) {
        LogPrint("Unwanted option --ignore-slave-running or --stop-slave");
        exit(0);
}

if ( !showSlaveStatus() && !defined $ignoreSlaveRunning && !defined $stopSlave ) {
        LogPrint("Slave is RUNNING Exit! You must use --ignore-slave-running or --stop-slave");
        exit(0);
}

if ( showSlaveStatus() && (defined $ignoreSlaveRunning || defined $stopSlave) ) {
        LogPrint("Slave is NOT RUNNING unwanted option --ignore-slave-running or --stop-slave EXIT!");
        exit(0);
}

if ( defined $stopSlave ) {
        stopSlave();
	sleep 1;
	if ( !showSlaveStatus() ) {
		LogPrint("Slave is running after \"SLAVE STOP\" command. Problem!!!");
		exit(0);
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
				print "$pigzCommand\n";
				system($pigzCommand);
				if (defined($keepLocalCopy)) {
					copy("$tmpDir/$table.sql.gz",createLocalDirectory($db)) or LogPrint("Error in $db $table.sql.gz");
				}
				unlink("$tmpDir/$table.sql.gz");
			} else {
				$mysqldumpCommand = "$mysqlDumpBinary $db $table > $tmpDir/$table.sql";
				print "$mysqldumpCommand\n";
				system($mysqldumpCommand);
				gzip "$tmpDir/$table.sql" => "$tmpDir/$table.sql.gz" or die "gzip failed: $GzipError\n";
				if (defined($keepLocalCopy)) {
					copy("$tmpDir/$table.sql.gz",createLocalDirectory($db)) or LogPrint("Error in $db $table.sql.gz");
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
			print "$pigzCommand\n";
			system($pigzCommand);
			if (defined($keepLocalCopy)) {
				copy("$tmpDir/$table.sql.gz",createLocalDirectory($dbName)) or LogPrint("Error in $dbName $table.sql.gz");
			}
			unlink("$tmpDir/$table.sql.gz");
		} else {
			$mysqldumpCommand = "$mysqlDumpBinary $dbName $table > $tmpDir/$table.sql";
			print "$mysqldumpCommand\n";
			system($mysqldumpCommand);
			gzip "$tmpDir/$table.sql" => "$tmpDir/$table.sql.gz" or die "gzip failed: $GzipError\n";
			if (defined($keepLocalCopy)) {
				copy("$tmpDir/$table.sql.gz",createLocalDirectory($dbName)) or LogPrint("Error in $dbName $table.sql.gz");
			}
			unlink("$tmpDir/$table.sql");
			unlink("$tmpDir/$table.sql.gz");
		}
        }
}

if ( defined $stopSlave ) {
        startSlave();
        sleep 1;
        if ( showSlaveStatus() ) {
                LogPrint("Slave is NOT running after \"SLAVE START\" command. Problem!!!");
                exit(0);
        }
}
