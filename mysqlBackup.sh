#!/bin/bash
#################################
#	Mysql Backup Script	#
#	nagios check		#
#				#
# Anton Antonov			#
# antonisimo@gmail.com		#
# ver 0.2			#
#################################

# changelog
# ver 0.2.10 - 16.11.2018

OPTS=$(getopt -o vhtly --long verbose,help,tables,local-copy,year-copy,local-copy-path:,local-copy-days:,mysql-root-password:,ftp-host:,ftp-user:,ftp-pass:,mysql-user:,mysql-host: -n 'parse-options' -- "$@")
getOptsExitCode=$?
if [ $getOptsExitCode != 0 ]; then
	echo "Failed parsing options." >&2 ;
	exit 1 ;
fi

eval set -- "$OPTS"

localCopy=1
localCopyPath="/var/tmp"
localCopyDays=1
localBackupDays=$(date +%Y%m%d%H%M -d "$localCopyDays day ago")
verbose=0
mysqlHost="localhost"
HELP=false
mysqlBin="/usr/bin/mysql"
mysqlUser="root"
tables=0

while true; do
	case "$1" in
		--mysql-host ) mysqlHost="$2"; shift; shift ;;
		--mysql-user ) mysqlUser="$2"; shift; shift ;;
		--mysql-root-password ) mysqlRootPassword="$2"; shift; shift ;;
		--local-copy-path ) localCopyPath="$2"; shift; shift ;;
		--local-copy-days ) localCopyDays="$2"; shift; shift ;;
		--ftp-host ) ftpHost="$2"; shift; shift ;;
		--ftp-user ) ftpUser="$2"; shift; shift ;;
		--ftp-pass ) ftpPass="$2"; shift; shift ;;
		-t | --tables ) tables=1; shift ;;
		-v | --verbose ) verbose=1; shift ;;
		-h | --help ) HELP=true; shift ;;
		-l | --local-copy ) localCopy=1; shift ;; 
		-y | --year-copy ) yearCopy=1; shift ;;
		-- ) shift; break ;;
		* ) break ;;
	esac
done

dateTs=$(date +%s)
ownScriptName=$(basename "$0" | sed -e 's/.sh$//g')
hostname=$(hostname)
serverName=$(hostname -s)
mysqlConnString="$mysqlBin -h $mysqlHost -u $mysqlUser -p$mysqlRootPassword -Bse"
mysqlSlaveString="$mysqlBin -h $mysqlHost -u $mysqlUser -p$mysqlRootPassword -se"
scriptLog="/var/log/$ownScriptName.log"
nagiosLog="/var/log/$ownScriptName.nagios"
lastRun="/var/log/$ownScriptName.last"

ftpRemotePath="/$serverName-mysql-backup/"
rateLimit="2048K"
# Speed is in bytes per second. 0 - means unlimited
ftpUploadSpeed=0
ftpDownloadSpeed=0
keepRemoteBackupDays=5
remoteBackupDays=$(date +%Y%m%d%H%M -d "$keepRemoteBackupDays day ago")

mysqlDir="$localCopyPath/mysql"
currentBackupDir="$mysqlDir/$(date +%Y%m%d%H%M)"

########################################################

displayHelp() {
	echo "Usage: $0 [option...]" >&2
	echo
	echo "	-v,	--verbose		Run script in verbose mode"
	echo "	-l,	--local-copy		Leave local copy"
	echo "	-t,	--tables		Split archive by tables"
	echo "	-y,	--year-copy		Keeps backup each 1-st date one year ago"
	echo "		--local-copy-path	Directory where local copy is stored"
	echo "		--local-copy-days	Backup keep days"
	echo "		--mysql-root-password	MySQL/MariaDB root password"
	echo "		--ftp-host		ftp host"
	echo "		--ftp-user		ftp user"
	echo "		--ftp-pass		ftp password"
	echo
# echo some stuff here for the -a or --add-options 
	exit 1
}

function logPrint() {

logMessage=$1

if [ -z $2 ]; then
        nagios=0
else
        if [[  $2 =~ ^[0-1]{1}$ ]]; then
                nagios=$2
        else
                nagios=0
        fi
fi

if [ -z $3 ]; then
        exitCommand=0
else
        if [[  $3 =~ ^[0-1]{1}$ ]]; then
                exitCommand=$3
        else
                exitCommand=0
        fi
fi

echo $(date) $logMessage >> $scriptLog

if [ $verbose -eq 1 ]; then
        echo $logMessage
fi

if [ $nagios -eq 1 ]; then
        echo $logMessage >> $nagiosLog
fi

if [ $exitCommand -eq 1 ]; then
        exit
fi

}

function dumpByTables() {

databaseName=$1

currentDBDir=$currentBackupDir/$databaseName
mkdir $currentDBDir
checkMDDBDir=$?
if [ $checkMDDBDir -ne 0 ]
then
	logPrint "ERROR could not create directory $currentDBDir" 1 1
fi

logPrint "current directory $currentDBDir" 0 0

mysqlTablesString="$mysqlBin -h $mysqlHost -u $mysqlUser -p$mysqlRootPassword $databaseName -Bse"
mapfile localTables < <( $mysqlTablesString "show tables" )
for table in "${localTables[@]}"
do
	table=$(echo -e "${table}" | tr -d '[:space:]')
	logPrint "dumping $databaseName $table" 0 0
	mysqldump --host=$mysqlHost --user=$mysqlUser --password=$mysqlRootPassword $databaseName $table | pigz > $currentDBDir/$table.sql.gz
	checkTableDumpStatus=$?
	if [ $checkTableDumpStatus -ne 0 ]
	then
		logPrint "ERROR in dump $databaseName $table" 1 0
	fi
done

}

function remoteTransfer() {

hash lftp 2>/dev/null
lftpCheck=$?
if [ $lftpCheck -ne 0 ]
then
        rm -f $nagiosLog
        logPrint "ERROR lftp not found!" 1 1
fi

logPrint "start ftp transfer" 0 0
lftp -u $ftpUser:$ftpPass $ftpHost -e "set net:connection-limit 1; set net:limit-rate $ftpDownloadSpeed:$ftpUploadSpeed; mirror -R $currentBackupDir $hostname/; bye"
checkUploadExit=$?
if [ $checkUploadExit -ne 0 ]; then
	logPrint "ERROR in upload" 1 1
else
	logPrint "ftp transfer finished successfully" 0 0
fi

for currentRemoteDirectory in $(curl -s -u $ftpUser:$ftpPass ftp://$ftpHost/$hostname/ -X MLSD | grep 'type=dir' | cut -d';' -f8)
do
	if [[ $currentRemoteDirectory =~ ^[0-9]{12}$ ]]; then
		if [ $currentRemoteDirectory -lt $remoteBackupDays ]; then
			if [ ! -z $currentRemoteDirectory ]; then
				logPrint "remove $hostname/$currentRemoteDirectory" 0 0
				lftp -u $ftpUser:$ftpPass $ftpHost -e "rm -r $hostname/$currentRemoteDirectory; bye"
				checkRemoteRemove=$?
				if [ $checkRemoteRemove -ne 0 ]; then
					logPrint "ERROR could not remove remote directory $hostname/$currentRemoteDirectory" 1 0
				fi
			fi
		fi
	fi
done

}

########################################################

logPrint START 0 0

if [ -f $nagiosLog ]; then
        logPrint "ERROR file $nagiosLog exists EXIT!" 1 1
else
        echo $$ > $nagiosLog
fi


logPrint "localCopy $localCopy" 0 0
logPrint "localCopyPath $localCopyPath" 0 0
logPrint "localCopyDays $localCopyDays" 0 0
logPrint "MySQL $mysqlUser pass $mysqlRootPassword" 0 0


if [ $HELP = true ]; then
	displayHelp
fi

if [ $localCopy == 0 ] && [ $localCopyPath != "/var/tmp" ]; then
	logPrint "WARNING unused option --local-copy-path. If you want to use it, you must add -l or --local-copy" 0 0
fi

if [ $localCopy == 0 ] && [ $localCopyDays != 1 ]; then
        logPrint "WARNING unused option --local-copy-days. If you want to use it, you must add -l or --local-copy" 0 0
fi

if [ -z $mysqlRootPassword ]; then
	logPrint "ERROR MySQL $mysqlUser password is missing add --mysql-root-password" 1 1
fi

echo $localCopyPath 

if [ ! -d $localCopyPath ]; then
	logPrint "Directory $localCopyPath does not exist" 0 0
	mkdir -p $localCopyPath
	checkMKdirLocal=$?
	if [ $checkMKdirLocal -ne 0 ]
	then
		logPrint "ERROR could not create directory $localCopyPath" 1 1
	fi
fi

if [ ! -d $currentBackupDir ]; then
        logPrint "Directory $currentBackupDir does not exist" 0 0
        mkdir -p $currentBackupDir
        checkMKdirCurrent=$?
        if [ $checkMKdirCurrent -ne 0 ]
        then
                logPrint "ERROR could not create directory $currentBackupDir" 1 1
        fi
fi

hash pigz 2>/dev/null
pigzCheck=$?
if [ $pigzCheck -ne 0 ]
then
	rm -f $nagiosLog
	logPrint "ERROR pigz not found!" 1 1
fi

logPrint "checking local mysql connection" 0 0
mysql -h $mysqlHost -u $mysqlUser -p$mysqlRootPassword -e "quit"
checkMysqlConnection=$?
if [ $checkMysqlConnection -ne 0 ]; then
	logPrint "ERROR MySQL connection failed. Check if $mysqlUser password is correct" 1 1
fi

secondsBhindMaster=$($mysqlConnString "SHOW SLAVE STATUS\G"| grep "Seconds_Behind_Master" | awk '{ print $2 }')
IORunning=$($mysqlConnString "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running" | awk '{ print $2 }')
SQLRunning=$($mysqlConnString "SHOW SLAVE STATUS\G" | grep "Slave_SQL_Running" | awk '{ print $2 }')

if [ "$secondsBhindMaster" == "NULL" ]
then
#	ERRORS=("${ERRORS[@]}" "The Slave is reporting 'NULL' (Seconds_Behind_Master)")
	logPrint "The Slave is reporting NULL (Seconds_Behind_Master)" 0 0
elif [[ $secondsBhindMaster > 60 ]]
then
	ERRORS=("${ERRORS[@]}" "The Slave is at least 60 seconds behind the master (Seconds_Behind_Master)")
	logPrint "The Slave is at least 60 seconds behind the master (Seconds_Behind_Master) we have $secondsBhindMaster Seconds_Behind_Master" 0 0
elif [[ -z $secondsBhindMaster ]]
then
	echo "seconds Master is EMPTY"
	mapfile localDatabases  < <( $mysqlConnString "show databases" )
                for DB in "${localDatabases[@]}"
                do
                        DB=$(echo -e "${DB}" | tr -d '[:space:]')
                        if ! [[ "$DB" =~ ^(information_schema|performance_schema)$ ]]
                        then
				if [ $tables -eq 0 ]
                                then
                                	logPrint "dumping $DB" 0 0
	                                mysqldump --host=$mysqlHost --user=$mysqlUser --password=$mysqlRootPassword -B $DB | pigz > $currentBackupDir/$DB.sql.gz
				else
					dumpByTables "$DB"
				fi
                        fi
                done
else
	logPrint "The Slave is reporting $secondsBhindMaster (Seconds_Behind_Master)" 0 0
	logPrint "Stopping slave" 0 0
	$mysqlConnString "stop slave"
	sleep 1
	checkStopSlave=$($mysqlConnString "SHOW SLAVE STATUS\G"| grep "Seconds_Behind_Master" | awk '{ print $2 }')
	if [ "$checkStopSlave" == "NULL" ]
	then
		logPrint "SLAVE STOPPED" 0 0
		mapfile localDatabases  < <( $mysqlConnString "show databases" )
		for DB in "${localDatabases[@]}"
		do
			DB=$(echo -e "${DB}" | tr -d '[:space:]')
			if ! [[ "$DB" =~ ^(information_schema|performance_schema)$ ]]
			then
				if [ $tables -eq 0 ]
				then
					logPrint "dumping $DB" 0 0
					masterLogFile=$($mysqlSlaveString "show slave status\G" | grep -w "Master_Log_File")
					masterLogPosition=$($mysqlSlaveString "show slave status\G" | grep -w "Read_Master_Log_Pos")
					masterHost=$($mysqlSlaveString "show slave status\G" | grep -w "Master_Host")
					masterUser=$($mysqlSlaveString "show slave status\G" | grep -w "Master_User")
					echo $masterLogFile > $currentBackupDir/status.inf
					echo $masterLogPosition >> $currentBackupDir/status.inf
					echo $masterHost >> $currentBackupDir/status.inf
					echo $masterUser >> $currentBackupDir/status.inf
					mysqldump --host=$mysqlHost --user=$mysqlUser --password=$mysqlRootPassword -B $DB | pigz > $currentBackupDir/$DB.sql.gz
					checkDumpStatus=$?
					if [ $checkDumpStatus -ne 0 ]
					then
						logPrint "ERROR in dump $databaseName" 1 0
					fi
				else
					dumpByTables "$DB"
				fi
			fi
		done
	else
		logPrint "ERROR in slave stopping" 1 1
	fi
	$mysqlConnString "start slave"
	sleep 1
	checkStartSlave=$($mysqlConnString "SHOW SLAVE STATUS\G"| grep "Seconds_Behind_Master" | awk '{ print $2 }')
	logPrint "start $checkStartSlave" 0 0
fi

echo ${#ERRORS[@]}

if [ ! -z $ftpHost ] && [ ! -z $ftpUser ] && [ ! -z $ftpPass ]
then
	logPrint "Start FTP Upload $ftpHost" 0 0
	remoteTransfer
else
	logPrint "FTP transfer not configured or missing parameter" 0 0
fi

if [ $localCopy -eq 1 ]; then
localBackupDirs=$(ls $mysqlDir)
for directory in $localBackupDirs ; do
	if [[ $directory =~ ^[0-9]{12}$ ]]; then
		if [ $directory -lt $localBackupDays ]; then
			removeDir=$mysqlDir/$directory
			logPrint "check if directory exists $removeDir" 0 0
			if [ -d $removeDir ] && [ ! -z $directory ] ; then
				logPrint "remove $removeDir" 0 0
				rm -rf $removeDir
				removeDirStatus=$?
				logPrint "remove status $removeDirStatus" 0 0
				if [ $removeDirStatus -ne 0 ]; then
					logPrint "ERROR could not remove directory $removeDir" 1 1
				fi
			else
				logPrint "ERROR directory $removeDir does not exist. Someting went wrong" 1 1
			fi
		fi
	fi
done
else
        rm -rf $mysqlDir/*
fi

########################################################

if grep -Fq "ERROR" $nagiosLog ; then
        logPrint "ERRORS are found. Must not remove $nagiosLog" 0 0
else
        rm -f $nagiosLog
        logPrint "FINISH" 0 0
fi
echo $dateTs > $lastRun
