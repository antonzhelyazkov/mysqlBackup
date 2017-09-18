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
# ver 0.2.1 - 18.09.2017

verbose=1
scriptLog="/var/log/mysqlBackup.log"
nagiosLog="/var/log/mysqlBackup.nagios"

localCopyDefault=0

########################################################

# Usage
function usage() {
	echo "--local-copy	>>>>	Keep local copy" 

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

echo `date` $logMessage >> $scriptLog

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

for i in "$@"
do
	case $i in
		--local-copy=*)
		localCopy="${i#*=}"
		shift # past argument=value
		;;
		*)
		# unknown option
		;;
	esac
done


if [ -z $localCopy ]; then
	$localCopy = $localCopyDefault
fi

echo $localCopy
if [ $localCopy -ne 1 ] && [ $localCopy -ne 0 ]; then
	logPrint "--local-copy accepts 0 or 1" 0 1
fi
