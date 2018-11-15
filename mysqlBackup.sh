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
# ver 0.2.3 - 27.09.2017

OPTS=$(getopt -o vhl --long verbose,help,local-copy,local-copy-path:,local-copy-days:,mysql-root-password: -n 'parse-options' -- "$@")
getOptsExitCode=$?
if [ $getOptsExitCode != 0 ]; then
	echo "Failed parsing options." >&2 ;
	exit 1 ;
fi

eval set -- "$OPTS"

localCopy=0
localCopyPath="/var/tmp"
localCopyDays=1
verbose=1
mysqlHost="localhost"
HELP=false
mysqlBin="/usr/bin/mysql"

while true; do
	case "$1" in
		--mysql-root-password ) mysqlRootPassword="$2"; shift; shift ;;
		--local-copy-path ) localCopyPath="$2"; shift; shift ;;
		--local-copy-days ) localCopyDays="$2"; shift; shift ;;
		-v | --verbose ) verbose=1; shift ;;
		-h | --help ) HELP=true; shift ;;
		-l | --local-copy ) localCopy=1; shift ;; 
		-- ) shift; break ;;
		* ) break ;;
	esac
done

dateTs=$(date +%s)
ownScriptName=$(basename "$0" | sed -e 's/.sh$//g')
hostname=$(hostname)
mysqlUser="root"
mysqlConnString="$mysqlBin -h $mysqlHost -u $mysqlUser -p$mysqlRootPassword -Bse"
scriptLog="/var/log/$ownScriptName.log"
nagiosLog="/var/log/$ownScriptName.nagios"
lastRun="/var/log/$ownScriptName.last"


########################################################

displayHelp() {
	echo "Usage: $0 [option...]" >&2
	echo
	echo "	-v,	--verbose		Run script in verbose mode"
	echo "	-l,	--local-copy		Leave local copy"
	echo "		--local-copy-path	Directory where local copy is stored"
	echo "		--local-copy-days	Backup keep days"
	echo "		--mysql-root-password	MySQL/MariaDB root password"
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

########################################################

logPrint START 0 0

if [ -f $nagiosLog ]; then
        logPrint "file $nagiosLog exists EXIT!" 1 1
else
        echo $$ > $nagiosLog
fi


logPrint "localCopy $localCopy" 0 0
logPrint "localCopyPath $localCopyPath" 0 0
logPrint "localCopyDays $localCopyDays" 0 0
logPrint "MySQL root pass $mysqlRootPassword" 0 0


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
	logPrint "ERROR MySQL root password is missing add --mysql-root-password" 1 1
fi

logPrint "checking local mysql connection" 0 0
mysql -h $mysqlHost -u root -p$mysqlRootPassword -e "quit"
checkMysqlConnection=$?
if [ $checkMysqlConnection -ne 0 ]; then
	logPrint "ERROR MySQL connection failed. Check if root password is correct" 1 1
fi

secondsBhindMaster=$($mysqlConnString "SHOW SLAVE STATUS\G"| grep "Seconds_Behind_Master" | awk '{ print $2 }')
IORunning=$($mysqlConnString "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running" | awk '{ print $2 }')
SQLRunning=$($mysqlConnString "SHOW SLAVE STATUS\G" | grep "Slave_SQL_Running" | awk '{ print $2 }')

echo $secondsBhindMaster

if [ "$secondsBhindMaster" == "NULL" ]
then
	ERRORS=("${ERRORS[@]}" "The Slave is reporting 'NULL' (Seconds_Behind_Master)")
	logPrint "The Slave is reporting NULL (Seconds_Behind_Master)" 0 0
elif [[ $secondsBhindMaster > 60 ]]
then
	ERRORS=("${ERRORS[@]}" "The Slave is at least 60 seconds behind the master (Seconds_Behind_Master)")
	logPrint "The Slave is at least 60 seconds behind the master (Seconds_Behind_Master) we have $secondsBhindMaster Seconds_Behind_Master" 0 0
else
	logPrint "The Slave is reporting $secondsBhindMaster (Seconds_Behind_Master)" 0 0
	logPrint "Stopping slave" 0 0
	$mysqlConnString "stop slave"
	sleep 100
	checkStopSlave=$($mysqlConnString "SHOW SLAVE STATUS\G"| grep "Seconds_Behind_Master" | awk '{ print $2 }')
	if [ "$checkStopSlave" == "NULL" ]
	then
		logPrint "SLAVE STOPPED" 0 0
	else
		logPrint "Error in slave stopping" 1 1
	fi
	$mysqlConnString "start slave"
	sleep 3
	checkStartSlave=$($mysqlConnString "SHOW SLAVE STATUS\G"| grep "Seconds_Behind_Master" | awk '{ print $2 }')
	logPrint "start $checkStartSlave" 0 0
fi

echo ${#ERRORS[@]}

########################################################

if grep -Fq "ERROR" $nagiosLog ; then
        logPrint "ERRORS are found. Must not remove $nagiosLog" 0 0
else
        rm -f $nagiosLog
        logPrint "FINISH" 0 0
fi
echo $dateTs > $lastRun
