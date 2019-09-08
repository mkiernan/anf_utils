#!/bin/bash
###############################################################################
# anf_snap.sh:
# Simple client-side snapshot initialization - run manual or cron
# Author Mike Kiernan, Microsoft
# PREREQ: Azure CLI installed, logged in, with correct subscription set
###############################################################################
# Example cron:
#0 * * * * /filer/anf_utils/anf_snap.sh

#-- The snapshot "CreationDate" shows up as null via API right now, so use timestamps in the name
ts=`date +%F-%H%M%S`
az netappfiles snapshot create --resource-group umgrp --name snapshot_$ts --account-name umanf --pool-name pool001 --volume-name data --location westeurope
