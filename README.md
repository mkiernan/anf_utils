# anf_utils
Azure NetApp Files Utilities

anf_resize.sh: standalone utility to resize a volume and it's containing capacity pool up or down in order to increase throughput while a heavy job is running, and then resize back down to optimize costs when the job has ended. 

./anf_resize.sh

Usage: anf_resize.sh [--account-name,-a <ANF account name>]
                     [--resource-group,-r <resource group>]
                     [--pool-name,-p <capacity pool name>]
                     [--volume-name,-v <volume name>]
                     [--pool-size <pool size in TiB>]
                     [--vol-size <volume size in TiB>]

eg: anf_resize.sh -r mygrp -a myanf -p mypool001 -v myvol001 --pool-size 16 --vol-size 16
