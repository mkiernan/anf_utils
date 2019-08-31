#!/bin/bash -e

###############################################################################
# anf_resize.sh: 
# Resize Azure NetApp Files Volume & Pool using Azure CLI
# Author Mike Kiernan, Microsoft
# PREREQ: Azure CLI installed, logged in, with correct subscription set
###############################################################################

usage()
{
    echo -e "\nUsage: $(basename $0) [--account-name,-a <ANF account name>]\n\
                     [--resource-group,-r <resource group>]\n\
                     [--pool-name,-p <capacity pool name>]\n\
                     [--volume-name,-v <volume name>]\n\
                     [--pool-size <pool size in TiB>] \n\
                     [--vol-size <volume size in TiB>]\n"
    echo -e "eg: $(basename $0) -r mygrp -a myanf -p mypool001 -v myvol001 --pool-size 16 --vol-size 16\n"
    exit 1
}

if [ $# -ne 12 ]; then
        usage
fi
while [[ $# -gt 0 ]]
do
   key="$1"
   case $key in 
     --vol-size)
     targetvolsizeTB="$2"
     shift; shift
     ;;
     --pool-size)
     targetpoolsizeTB="$2"
     shift; shift
     ;;
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
   esac
done

if [ $targetvolsizeTB -gt $targetpoolsizeTB ]; then
   echo -e "\nERROR: Volume size must be less than or equal to the pool size specified\n"
   usage
fi

#-- convert target size to bytes
tb="$((1024*1024*1024*1024))"
targetpoolsize="$(($targetpoolsizeTB*$tb))"
targetvolsize="$(($targetvolsizeTB*$tb))"

#-- determine current size of pool & volume in bytes
poolsize=`az netappfiles pool show --resource-group $rg --account-name $account --pool-name $pool --query "size"`
volsize=`az netappfiles volume show --volume-name $volume --resource-group $rg --account-name $account --pool-name $pool --query "usageThreshold"`
poolsizeTB="$(($poolsize/$tb))"
volsizeTB="$(($volsize/$tb))"

#echo "volsize: $volsize"
#echo "poolsize: $poolsize"

echo -e "ANF Account: \t\t$account"
echo -e "Resource Group:\t\t$rg"
echo -e "ANF Pool:\t\t$pool"
echo -e "ANF Volume:\t\t$volume"
echo -e "Current pool size:\t$poolsizeTB TiB"
echo -e "Current volume size:\t$volsizeTB TiB"
echo -e "Target pool size:\t$targetpoolsizeTB TiB [$targetpoolsize bytes]"
echo -e "Target volume size:\t$targetvolsizeTB TiB [$targetvolsize bytes]"

#-- az cli command setup
volcmd="az netappfiles volume update --volume-name $volume --resource-group $rg --account-name $account --pool-name $pool --set usageThreshold=$targetvolsize --query \"usageThreshold\""
poolcmd="az netappfiles pool update --size $targetpoolsizeTB --resource-group $rg --account-name $account --pool-name $pool --query \"size\""

#-- Perform the pool & volume resize in correct order based on current sizes
if [ $volsizeTB -gt $targetvolsizeTB ]; then
   #-- downsizing: resize volume down first, then pool
   echo "Reducing volume \"$volume\" size from $volsizeTB TiB to $targetvolsizeTB TiB"
   if [ $poolsizeTB -eq $targetpoolsizeTB ]; then
      echo "Pool \"$pool\" is already set to $targetpoolsizeTB TiB. Nothing to do."
      cmd1=$volcmd; cmd2=""
   elif [ $poolsizeTB -gt $targetpoolsizeTB ]; then
      echo "Reducing pool \"$pool\" size from $poolsizeTB TiB to $targetpoolsizeTB TiB"
      cmd1=$volcmd; cmd2=$poolcmd
   elif [ $poolsizeTB -lt $targetpoolsizeTB ]; then
      echo "Increasing pool \"$pool\" size from $poolsizeTB TiB to $targetpoolsizeTB TiB"
      cmd1=$volcmd; cmd2=$poolcmd
   fi 
elif [ $volsizeTB -lt $targetvolsizeTB ]; then
   #-- upsizing: resize pool first, then volume
   if [ $poolsizeTB -eq $targetpoolsizeTB ]; then
      echo "Pool \"$pool\" is already set to $targetpoolsizeTB TiB. Nothing to do."
      cmd1=$volcmd; cmd2=""
   elif [ $poolsizeTB -gt $targetpoolsizeTB ]; then
      echo "Reducing pool \"$pool\" size from $poolsizeTB TiB to $targetpoolsizeTB TiB"
      cmd1=$poolcmd; cmd2=$volcmd
   elif [ $poolsizeTB -lt $targetpoolsizeTB ]; then
      echo "Increasing pool \"$pool\" size from $poolsizeTB TiB to $targetpoolsizeTB TiB"
      cmd1=$poolcmd; cmd2=$volcmd
   fi 
   echo "Increasing volume \"$volume\" size from $volsizeTB TiB to $targetvolsizeTB TiB"
elif [ $volsizeTB -eq $targetvolsizeTB ]; then
   #-- only need to resize pool here
   echo "Volume \"$volume\" size is already set to $targetvolsizeTB TiB. Nothing to do."
   if [ $poolsizeTB -eq $targetpoolsizeTB ]; then
      echo "Pool \"$pool\" is already set to $targetpoolsizeTB TiB. Nothing to do."
      cmd1=""; cmd2=""
   elif [ $poolsizeTB -gt $targetpoolsizeTB ]; then
      echo "Reducing pool \"$pool\" size from $poolsizeTB TiB to $targetpoolsizeTB TiB"
      cmd1=$poolcmd; cmd2=""
   elif [ $poolsizeTB -lt $targetpoolsizeTB ]; then
      echo "Increasing pool \"$pool\" size from $poolsizeTB TiB to $targetpoolsizeTB TiB"
      cmd1=$poolcmd; cmd2=""
   fi 
fi

#-- execute the pool/volume resize commands in order
if [[ ! -z $cmd1 ]]; then 
  echo "Running: $cmd1"
  rc=`$cmd1`
  outsize="$(($rc/$tb))"
  if [ "$cmd1" = "$volcmd" ]; then
      echo "Volume size changed to $outsize TiB"
  else 
      echo "Pool size changed to $outsize TiB"
  fi
     
  if [[ ! -z $cmd2 ]]; then
     rc=`$cmd2`
     outsize="$(($rc/$tb))"
     echo "Running: $cmd2"
     if [ "$cmd2" = "$volcmd" ]; then
         echo "Volume size changed to $outsize TiB"
     else 
         echo "Pool size changed to $outsize TiB"
     fi
  fi
fi

#-- Check: new sizes
poolsize=`az netappfiles pool show --resource-group $rg --account-name $account --pool-name $pool --query "size"`
volsize=`az netappfiles volume show --volume-name $volume --resource-group $rg --account-name $account --pool-name $pool --query "usageThreshold"`
poolsizeTB="$(($poolsize/$tb))"
volsizeTB="$(($volsize/$tb))"
echo -e "New pool size:\t$targetpoolsizeTB TiB [$targetpoolsize bytes]"
echo -e "New volume size:\t$targetvolsizeTB TiB [$targetvolsize bytes]"

# -- Finally, give estimate on performance capability
tier=`az netappfiles pool show --resource-group $rg --account-name $account --pool-name $pool --query "serviceLevel"`
echo "Tier for pool \"$pool\" volume \"$volume\" is $tier"
if [ "$tier" = "\"Standard\"" ]; then
   perf="$((16*$targetvolsizeTB))"
elif [ "$tier" = "\"Premium\"" ]; then
   perf="$((64*$targetvolsizeTB))"
elif [ "$tier" = "\"Ultra\"" ]; then
   perf="$((128*$targetvolsizeTB))"
fi
   
# Max MiB/s: 
# https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-performance-benchmarks
cap=4500 
if [[ $perf -gt $cap ]]; then perf=$cap; fi
echo "Max throughput for volume \"$volume\" is now: $perf MiB/s"
