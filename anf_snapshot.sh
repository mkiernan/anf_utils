#!/bin/bash

###############################################################################
# anf_snapshot.sh:
# Client-side Snapshot initialization & cycle management for ANF
# Author Mike Kiernan, Microsoft
# PREREQ: Azure CLI installed, logged in, with correct subscription set
###############################################################################
# Example cron entry:
#0 * * * * /filer/anf_utils/anf_snapshot.sh -a umanf -r umgrp -p pool001 -v data -l westeurope --purge yes > /filer/anf_utils/snapshot.log 2>&1
###############################################################################
# Default snapshot retention schedule 
retain_hourly=24
retain_nightly=7
retain_weekly=4
retain_monthly=12
retain_yearly=2
###############################################################################

usage()
{
    echo -e "\nUsage: $(basename $0) [--account-name,-a <ANF account name>]\n\
                     [--resource-group,-r <resource group>]\n\
                     [--pool-name,-p <capacity pool name>]\n\
                     [--volume-name,-v <volume name>]\n\
                     [--location,-l <azure location>]\n\
                     [--purge <yes or no> (purge old snapshots, or not)]\n"
    echo -e "eg: $(basename $0) -r mygrp -a myanf -p mypool001 -v myvol001 -l westeurope --purge yes\n"
    exit 1
} #-- end of usage() --#

delete_snapshot()
{
    snaptopurge=$1
    echo "Purging snapshot $snaptopurge"
    #-- purging via id as using the "name" doesn't seem to work via API currently. 
    #cmd="az netappfiles snapshot delete --account-name $account --resource-group $rg --pool-name $pool --volume-name $volume --ids $snaptopurge"
    cmd=(az netappfiles snapshot delete --ids "$snaptopurge")
    #-- has this line out if doing a dry run
    if [ $purge == "yes" ]; then 
       echo "Executing purge command: ${cmd[@]}"
       ${cmd[@]}
    else 
       echo "Dry run only - purge command:"
       echo "cmd: ${cmd[@]}"
    fi 

} #-- end of delete_snapshot() --#

if [ $# -ne 12 ]; then
        usage
fi
while [[ $# -gt 0 ]]
do
   key="$1"
   case $key in
     -r|--resource-group)
     rg="$2"
     shift; shift
     ;;
     -a|--account-name)
     account="$2"
     shift; shift
     ;;
     -p|--pool-name)
     pool="$2"
     shift; shift
     ;;
     -v|--volume-name)
     volume="$2"
     shift; shift
     ;;
     -l|--location)
     location="$2"
     shift; shift
     ;;
     -d|--purge)
     purge="$2"
     shift; shift
     ;;
   esac
done


#-- Prepare for purging/cycling
#-- List current snapshots (use jmespath+tsv to avoid installing jq) and store in hash table
readarray -t snaplines < <(az netappfiles snapshot list --account-name $account --resource-group $rg --pool-name $pool --volume-name $volume --query [*].[name,id] --output tsv)
declare -A snapshots
#echo "A: ${snaplines[@]}"
count=0
for line in "${snaplines[@]}"; do
      name=`echo $line | awk '{print $1}'`
      id=`echo $line | awk '{print $2}'`
      snapshots["$name"]="$id"
      ((count++))
done
echo "Total number of snapshots: $count (includes unmanaged snapshots)"
#--NB this loop fails silently on counter increment with -e flag turned on 
IFS= #--preserve newlines in sort output

#-- Start the clock
timenow=$(date +%s)
#-- The snapshot "CreationDate" shows up as null via API right now, so use timestamps in the names
#-- Also not possible to rename snapshots via API yet, so all names are "snapshot_" for now. 
ts=`date +%F-%H%M%S`
echo "Time Now: $timenow $ts"

#-- Take a new backup before initiating the purge
echo "Creating new snapshot backup:"
az netappfiles snapshot create --resource-group $rg --name snapshot_$ts --account-name $account --pool-name $pool --volume-name $volume --location $location

#-- parse managed snapshot names, interpret timestamp into absolute value and sort by time
hourlys=$(
for snapshot in "${!snapshots[@]}"; do
   #echo "snapshot: $snapshot, id: ${snapshots[$snapshot]}"
   sshort=`echo $snapshot | awk -F "/" '{print $4}'`
   #-- match format snapshot_2019-09-01-103023
   if [[ $sshort =~ "snapshot_" ]]; then
       sshort=${sshort/snapshot_/}
       dshort=`echo $sshort | sed -E 's,([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2}),\1-\2-\3 \4:\5:\6,g'`
       #echo "short: $sshort, $dshort"
       human=$(date -d "$dshort")
       abs=$(date -d "${dshort}" "+%s")
       #echo "hourly snapshot: snapshot_$sshort, human: $human, absolute: $abs"
       echo "$abs ${snapshots[$snapshot]} $sshort"
   fi
done | sort -rnu)
IFS=$'\n' #-- restore newline

#-- set expiration deadlines based on schedule 
hoursec=3600
daysec=86400
weeksec=604800
monthsec=2628000 #-- 730 hrs avg
yearsec=31536000

#
# PURGE Snapshots According to Schedule
#
#-- parse sorted lines into arrays
i=0
for line in $hourlys; do
#     echo "line: $line"
     creationtime[$i]=$(echo $line | awk '{print $1}')
     snapid[$i]=$(echo $line | awk '{print $2}')
     timestamp[$i]=$(echo $line | awk '{print $3}')
     retain[$i]="no"
     ((i++))
done

#-- Determine in one pass which of the 5 snapshot schedule retention buckets each snapshot
#-- belongs in hourly/daily/weekly/monthly/yearly.
snapshots=$i
echo "Total number of managed snapshots: $snapshots"
i=0; next=0; last=0
hour=0; day=0; week=0; month=0; year=0
while [ $i -lt $snapshots ]; do
    next=$((i+1))
    age[$i]="$(($timenow-${creationtime[$i]}))"
    #echo "creationtime[$i]: ${creationtime[$i]}, age: ${age[$i]} snapshot: ${snapid[$i]}"
    if [ $next -eq $snapshots ]; then
        last=1
    else 
        nextage[$i]="$(($timenow-${creationtime[$next]}))"
    fi

    #-- if still within range of hourly buckets
    reset=$hour
    while [ $hour -le $retain_hourly ]; do
        hourmin=$((hoursec*hour)); hourmax=$((hourmin+hoursec))
        #echo "hour bucket: $hour, age[$i]: ${age[$i]}, hourly window: $hourmin:$hourmax"
        ((hour++))
        if [ ${age[$i]} -ge $hourmin ] && [ ${age[$i]} -lt $hourmax ]; then
          if [ $last -eq 1 ]; then 
             retain[$i]="hourly"; ((i++)); continue 2
          fi
          if [ ${nextage[$i]} -ge $hourmax ]; then
             retain[$i]="hourly"; ((i++)); continue 2 
          else
             hour=$reset; break
          fi
        fi
    done

    #-- if still within range of nightly buckets
    reset=$day
    while [ $day -le $retain_nightly ]; do
        nightmin=$((daysec*day)); nightmax=$((nightmin+daysec))
        #echo "night bucket: $day, age: ${age[$i]} nextage: ${nextage[$i]}, nightly window: $nightmin:$nightmax"
        ((day++))
        if [ ${age[$i]} -ge $nightmin ] && [ ${age[$i]} -lt $nightmax ]; then
          if [ $last -eq 1 ]; then 
              retain[$i]="nightly"; ((i++)); continue 2
          fi
          if [ ${nextage[$i]} -ge $nightmax ]; then
              retain[$i]="nightly"; ((i++)); continue 2
          else 
              day=$reset; break
          fi
        fi
    done

    #-- if still within range of weekly buckets
    reset=$week
    while [ $week -le $retain_weekly ]; do
        weekmin=$((weeksec*week)); weekmax=$((weekmin+weeksec))
        #echo "week bucket: $week, age: ${age[$i]} nextage: ${nextage[$i]}, weekly window: $weekmin:$weekmax"
        ((week++))
        if [ ${age[$i]} -ge $weekmin ] && [ ${age[$i]} -lt $weekmax ]; then
          if [ $last -eq 1 ]; then 
              retain[$i]="weekly"; ((i++)); continue 2
          fi
          if [ ${nextage[$i]} -ge $weekmax ]; then
              retain[$i]="weekly"; ((i++)); continue 2
          else 
              week=$reset; break
          fi
        fi
    done

    #-- if still within range of monthly buckets
    reset=$month
    while [ $month -le $retain_monthly ]; do
        monthmin=$((monthsec*month)); monthmax=$((monthmin+monthsec))
        #echo "month bucket: $month, age: ${age[$i]} nextage: ${nextage[$i]}, monthly window: $monthmin:$monthmax"
        ((month++))
        if [ ${age[$i]} -ge $monthmin ] && [ ${age[$i]} -lt $monthmax ]; then
          if [ $last -eq 1 ]; then 
              retain[$i]="monthly"; ((i++)); continue 2
          fi
          if [ ${nextage[$i]} -ge $monthmax ]; then
              retain[$i]="monthly"; ((i++)); continue 2
          else 
              month=$reset; break
          fi
        fi
    done

    #-- if still within range of yearly buckets
    reset=$year
    while [ $year -le $retain_yearly ]; do
        yearmin=$((yearsec*year)); yearmax=$((yearmin+yearsec))
        #echo "year bucket: $year, age: ${age[$i]} nextage: ${nextage[$i]}, yearly window: $yearmin:$yearmax"
        ((year++))
        if [ ${age[$i]} -ge $yearmin ] && [ ${age[$i]} -lt $yearmax ]; then
          if [ $last -eq 1 ]; then 
              retain[$i]="yearly"; ((i++)); continue 2
          fi
          if [ ${nextage[$i]} -ge $yearmax ]; then
              retain[$i]="yearly"; ((i++)); continue 2
          else 
              year=$reset; break
          fi
        fi
    done

    ((i++)) #-- main loop counter
done

#-- Print summary table 
i=0
while [ $i -lt $snapshots ]; do
      echo "creationtime[$i]: ${creationtime[$i]} timestamp[$i]: ${timestamp[$i]} age[$i]: ${age[$i]} retain[$i]: ${retain[$i]}"
      #echo "snapshot: ${snapid[$i]}"
      ((i++))
done

#-- Now we have a purge list, go ahead and execute the deletions
i=0
while [ $i -lt $snapshots ]; do
      if [ "${retain[$i]}" == "no" ]; then
         delete_snapshot ${snapid[$i]}
      fi
      ((i++))
done

#-- snapshots remaining
#echo "Snapshots remaining after purge:"
#az netappfiles snapshot list --account-name $account --resource-group $rg --pool-name $pool --volume-name $volume --query [*].[name,id] --output tsv

exit
