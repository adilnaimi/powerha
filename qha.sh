#!/bin/ksh
# Version: 9.06
# VARS
export PATH=$PATH:/usr/es/sbin/cluster/utilities
VERSION=`lslpp -L |grep -i cluster.es.server.rte |awk '{print $2}'| sed 's/\.//g'`
CLUSTER=`odmget HACMPcluster | grep -v node |grep name | awk '{print $3}' |sed "s:\"::g"`
UTILDIR=/usr/es/sbin/cluster/utilities
# clrsh dir in v7 must be /usr/sbin in previous version's it's /usr/es/sbin/cluster/utilities.
# Don't forget also that the rhost file for >v7 is /etc/cluster/rhosts
if [[ `lslpp -L |grep -i cluster.es.server.rte |awk '{print $2}' | cut -d'.' -f1` -ge 7 ]]; then
    CDIR=/usr/sbin
else
    CDIR=$UTILDIR
fi
OUTFILE=/tmp/.qha.$$
LOGGING=/tmp/qha.out.$$
ADFILE=/tmp/.ad.$$
HACMPOUT=`/usr/bin/odmget -q name="hacmp.out" HACMPlogs | fgrep value | sed 's/.*=\ "\(.*\)"$/\1\/hacmp.out/'`
COMMcmd="$CDIR/clrsh"
REFRESH=0
usage() {
echo "qha version 9.06"
echo "Usage: qha [-n] [-N] [-v] [-l] [-e] [-m] [-1] [-c]"
echo "\t\t-n displays network interfaces\n\t\t-N displays network \
interfaces + nonIP heartbeat disk\n\t\t-v shows online VGs\n\t\t-l logs entries to \
/tmp/qha.out\n\t\t-e shows running event\n\t\t-m shows appmon status\n\t\t-1 \
single interation\n\t\t-c shows CAA SAN/Disk Status (AIX7.1 TL3 min.)"
}

function adapters {
i=1
j=1
cat $ADFILE | while read line
do
    en[i]=`echo $line | awk '{print $1}'`
    name[i]=`echo $line | awk '{print $2}'`
    if [ i -eq 1 ]; then
      printf " ${en[1]} ";
    fi
    if [[ ${en[i]} = ${en[j]} ]]; then
        printf "${name[i]} "
    else
        printf "\n${en[i]} ${name[i]} "
    fi
let i=i+1
let j=i-1
done
rm $ADFILE
if [ $HBOD = "TRUE" ]; then # Code for v6 and below only. To be deleted soon.
    # Process Heartbeat on Disk networks (Bill Millers code)
    VER=`echo $VERSION | cut -c 1`
    if [[ $VER = "7" ]]; then
        print "[HBOD option not supported]" >> $OUTFILE
    fi
    HBODs=$($COMMcmd $HANODE "$UTILDIR/cllsif" | grep diskhb | grep -w $HANODE | awk '{print $8}')
    for i in $(print $HBODs)
    do
        APVID=$($COMMcmd $HANODE "lspv" | grep -w $i | awk '{print $2}' | cut -c 13-)
        AHBOD=$($COMMcmd $HANODE lssrc -ls topsvcs | grep -w r$i | awk '{print $4}')
        if [ $AHBOD ]
            then
            printf "\n\t%-13s %-10s" $i"("$APVID")" [activeHBOD]
        else
            printf "\n\t%-13s %-10s" $i [inactiveHBOD]
        fi
    done
fi
}
function work {
HANODE=$1; CNT=$2 NET=$3 VGP=$4
#clrsh $HANODE date > /dev/null 2>&1 || ping -w 1 -c1 $HANODE > /dev/null 2>&1
$COMMcmd $HANODE date > /dev/null 2>&1
if [ $? -eq 0 ]; then
    EVENT="";
    CLSTRMGR=`$COMMcmd $HANODE lssrc -ls clstrmgrES | grep -i state | sed 's/Current state: //g'`
    if [[ $CLSTRMGR != ST_STABLE && $CLSTRMGR != ST_INIT && $SHOWEVENT = TRUE ]]; then
        EVENT=$($COMMcmd $HANODE cat $HACMPOUT | grep "EVENT START" |tail -1 | awk '{print $6}')
                  printf "\n%-8s %-7s %-15s\n" $HANODE iState: "$CLSTRMGR [$EVENT]"
    else
        printf "\n%-8s %-7s %-15s\n" $HANODE iState: "$CLSTRMGR"
    fi
    $UTILDIR/clfindres -s 2>/dev/null |grep -v OFFLINE | while read A
    do
        if [[ "`echo $A | awk -F: '{print $3}'`" == "$HANODE" ]]; then
            echo $A | awk -F: '{printf " %-18.16s %-10.12s %-1.20s", $1, $2, $9}'
            if [ $APPMONSTAT = "TRUE" ]; then
                RG=`echo $A | awk -F':' '{print $1}'`
                APPMON=`$UTILDIR/clRGinfo -m | grep -p $RG | grep "ONLINE" | awk 'NR>1 {print $1" "$2}'`
                print "($APPMON)"
            else
                print ""
            fi
        fi
    done
    if [ $CAA = "TRUE" ]; then
        IP_Comm_method=`odmget HACMPcluster | grep heartbeattype | awk -F'"' '{print $2}'`
        case $IP_Comm_method in
            C) # we're multicasting
                printf " CAA Multicasting:"
                $COMMcmd $HANODE lscluster -m | grep en[0-9] | awk '{printf " ("$1" "$2")"}'
                echo ""
                ;;
            U) # we're unicasting
                printf " CAA Unicasting:"
                $COMMcmd $HANODE lscluster -m | grep tcpsock | awk '{printf " ("$2" "$3" "$5")"}'
                echo ""
                ;;
        esac
        SAN_COMMS_STATUS=$(/usr/lib/cluster/clras sancomm_status | egrep -v "(--|UUID)" | awk -F'|' '{print $4}' | sed 's/ //g')
        DP_COMM_STATUS=$(/usr/lib/cluster/clras dpcomm_status | grep $HANODE | awk -F'|' '{print $4}' | sed 's/ //g')
        print " CAA SAN Comms: $SAN_COMMS_STATUS | DISK Comms: $DP_COMM_STATUS"
    fi
    if [ $NET = "TRUE" ]; then
        $COMMcmd $HANODE netstat -i | egrep -v "(Name|link|lo)" | awk '{print $1" "$4" "}' > $ADFILE
        adapters; printf "\n- "
    fi
    if [ $VGP = "TRUE" ]; then
        VGO=`$COMMcmd $HANODE "lsvg -o |fgrep -v caavg_private |fgrep -v rootvg |lsvg -pi 2> /dev/null" |awk '{printf $1")"}' |sed 's:)PV_NAME)hdisk::g' | sed 's/:/(/g' |sed 's:):) :g' |sed 's: hdisk:(:g' 2> /dev/null`
        if [ $NET = "TRUE" ]; then
              echo "$VGO-"
        else
            echo "- $VGO-"
        fi
    fi
    else
        ping -w 1 -c1 $HANODE > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "\nPing to $HANODE good, but can't get the status. Check clcomdES."
        else
            echo "\n$HANODE not responding, check network availability."
        fi
fi
}

# Main
NETWORK="FALSE"; VG="FALSE"; HBOD="FALSE"; LOG=false; APPMONSTAT="FALSE"; STOP=0;
CAA=FALSE; REMOTE="FALSE";
# Get Vars
while getopts :nNvlem1c ARGs
do
   case $ARGs in
        n) # -n show interface info
            NETWORK="TRUE";;
        N) # -N show interface info and activeHBOD
            NETWORK="TRUE"; HBOD="TRUE";;
        v) # -v show ONLINE VG info
            VG="TRUE";;
        l) # -l log to /tmp/qha.out
            LOG="TRUE";;
        e) # -e show running events if cluster is unstable
            SHOWEVENT="TRUE";;
        m) # -m show status of monitor app servers if present
            APPMONSTAT="TRUE";;
        1) # -1 exit after first iteration
            STOP=1;;
        c) # CAA SAN / DISK Comms
            CAA=TRUE;;
        \?) printf "\nNot a valid option\n\n" ; usage ; exit ;;
    esac
done
OO=""
trap "rm $OUTFILE; exit 0" 1 2 12 9 15
while true
do
    COUNT=0
    print "\\033[H\\033[2J\t\tCluster: $CLUSTER ($VERSION)" > $OUTFILE
    echo "\t\t$(date +%T" "%d%b%y)" >> $OUTFILE
    if [[ $REMOTE = "TRUE" ]]; then
        Fstr=`cat $CLHOSTS |grep -v "^#"`
    else
        Fstr=`odmget HACMPnode |grep name |sort -u | awk '{print $3}' |sed "s:\"::g"`
    fi
    for MAC in `echo $Fstr`
    do
        let COUNT=COUNT+1
        work $MAC $COUNT $NETWORK $VG $HBOD
    done >> $OUTFILE
    cat $OUTFILE
    if [ $LOG = "TRUE" ]; then
        wLINE=$(cat $OUTFILE |sed s'/^.*Cluster://g' | awk '{print " "$0}' |tr -s
        '[:space:]' '[ *]' | awk '{print $0}')
        wLINE_three=$(echo $wLINE | awk '{for(i=4;i<=NF;++i) printf("%s ", $i) }')
        if [[ ! "$OO" = "$wLINE_three" ]]; then
            # Note, there's been a state change, so write to the log
            # Alternatively, do something addtional, for example: send an snmp trap
            alert, using the snmptrap command. For example:
            # snmptrap -c <community> -h <anmp agent> -m "appropriate message"
            echo "$wLINE" >> $LOGGING
        fi
        OO="$wLINE_three"
    fi
    if [[ $STOP -eq 1 ]]; then
        exit
    fi
sleep $REFRESH
done
