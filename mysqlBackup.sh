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

OPTS=$(getopt -o vhl --long verbose,help,local-copy,local-copy-path:,local-copy-days: -n 'parse-options' -- "$@")
getOptsExitCode=$?
if [ $getOptsExitCode != 0 ]; then
	echo "Failed parsing options." >&2 ;
	exit 1 ;
fi

eval set -- "$OPTS"

localCopy=0
localCopyPath="/var/tmp"
localCopyDays=1
verbose=0
HELP=false

while true; do
	case "$1" in
		--local-copy-path ) localCopyPath="$2"; shift; shift ;;
		--local-copy-days ) localCopyDays="$2"; shift; shift ;;
		-v | --verbose ) verbose=1; shift ;;
		-h | --help ) HELP=true; shift ;;
		-l | --local-copy ) localCopy=1; shift ;; 
		-- ) shift; break ;;
		* ) break ;;
	esac
done

scriptLog="/var/log/mysqlBackup.log"
nagiosLog="/var/log/mysqlBackup.nagios"


########################################################

displayHelp() {
	echo "Usage: $0 [option...]" >&2
	echo
	echo "	-v,	--verbose		Run script in verbose mode"
	echo "	-l,	--local-copy		Leave local copy"
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

logPrint "$localCopy $localCopyPath $localCopyDays" 0 0

if [ $HELP = true ]; then
	displayHelp
fi
