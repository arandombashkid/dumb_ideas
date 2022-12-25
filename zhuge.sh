#!/bin/bash

# This script attempts to squeeze a bit more performance out of a potato pc.
# It works by continuosly monitoring the amount of zram-occupied RAM,
# and dumping old pages to an hdd-based backing storage, preventing usual zram problem of LRU inversion.
# In order for zram to tell new and old pages apart,
# a debug feature CONFIG_ZRAM_MEMORY_TRACKING is exploited, so ensure you have it enabled.
# If you have:
# -more than 4GB RAM and/or
# -an SSD and/or
# -will to live,
# then you probably don't need this script. Just enable about 30% zswap and call it a day, 
# you'll be fine for the most part, especially with lazy desktop usage.
# The script has a drawback -- in exchange for a bit more performance long-term,
# every once in a while your whole computer might become incredibly sluggish or even completely freeze for a bit, 
# while the writeback of old pages to the backing device is happening. It's normal, 
# it's going to be back no normal once the writeback is complete. Start worry, though, 
# if it's still completely frozen after ~10 minutes -- it probably indicates a system deadlock.
# If for whatever reason you decide to use this script with SSD, you might want to use sparse files
# for zram's backing_dev, to avoid unnecessary i\o and wear-out.


if ! zcat /proc/config.gz | grep CONFIG_ZRAM_MEMORY_TRACKING | grep y
then echo "no zram tracking enabled, bye" 
exit 1
fi


temp_swap=/temp_swapfile
zram_time=/tmp/zram_last_written_idle
initial_stamp=1800 # fake "last written" value in seconds , used once on script startup
time_chunk=60 # amount of seconds to jump
ram_percent=50 # not recommended to put values higher than 50, unless you're using this on a 8+ gb ram pc for some reason

total_ram=`cat /proc/meminfo  | grep MemTotal | awk '{print $2}'`
compressed_ram_limit=$((  ($total_ram /100 * $ram_percent) * 1024  ))

# writeback will continue until this percentage of $compressed_ram_limit remains in RAM
# basically this controls how often the writeback would trigger in high memory pressure conditions:
# 10 means almost all of your zram-swap will be written to disk, so subsequent writeback will happen rarely,
# at the cost of worse multitasking and interactivity with already running programs,
# 100 means only very old and unneeded pages will be written to disk, keeping multitasking and
# interactivity at maximum, at the cost of more frequent writes. Test different values, ymmw
limit_watermark_percent=90

# produce initial timestamp to work with
echo $(( $EPOCHSECONDS - $initial_stamp )) > $zram_time

# ensure zswap and specifically "same_filled_pages_enabled" are enabled,
# as the goal is to reduce unnecessary i\o, we need to catch all the zero- and same-filled pages possible,
# and prevent them from taking up valuable disk space and cpu time, regardless of what type of swapping is enabled.
echo 1 >/sys/module/zswap/parameters/enabled
echo 1 >/sys/module/zswap/parameters/same_filled_pages_enabled
# these will only be used for temp_swap to soften up the performance hit of switching from zram to disk swap
# remember that max_pool_percent is in addition to $ram_percent initially, so it's possible that the system might
# get locked if you set these values too high
echo 10 >/sys/module/zswap/parameters/max_pool_percent
echo zstd >/sys/module/zswap/parameters/compressor  # maximum compression
echo z3fold >/sys/module/zswap/parameters/zpool
# at values lower than 100, once filled, zswap will flat out stop accepting any new pages at all,
# even zero- and same-filled, which forces the system to write to disk-based swap directly,
# resulting in LRU inversion. With a value of 100, system continues to shove pages down zswap's throat,
# further softening up the performance hit of having to swap short-lived pages directly to disk,
# and also LRU inversion doesn't happen
echo 100 >/sys/module/zswap/parameters/accept_threshold_percent 

create_temp_swap(){
# three times the occupied swap.
# the number is completely arbitrary, it just makes me feel safer,
# in case any rogue program decides to swap a few gb while the writeback is still happening
size=`free -m | grep Swap | awk '{print int ($3 * 3 )}'`
# can't just truncate a sparse file, as allocating blocks requires paging, so might run into a deadlock
# can't dd a file, too slow, the system will freeze long before the write is complete
# so fallocate is a compromise, even though it's not recommended for swap files
ionice -c 1 -n 1 fallocate -l ${size}M $temp_swap 
chmod 0600 $temp_swap
mkswap $temp_swap
}

optimize_for_zram(){
if [ -z $1 ]
 then v0=173; v1=0 ; v2=30 # maximum swapping, maximum file cache
 else v0=100; v1=3 ; v2=200 # minimum file cache, still a lot of early swapping,
                           # helps to keep the system at least somewhat responsive during writeback
fi

sysctl -w vm.swappiness=$v0
sysctl -w vm.page-cluster=$v1
sysctl -w vm.vfs_cache_pressure=$v2
}

optimize_for_zram

total_zram(){
awk '{ sum += $3 }; END { print sum }' /sys/block/zram*/mm_stat
}

do_write(){
zram_age=$1
file=$2
# this ensures the writeback happens on all devices simultaneously.
# IMPORTANT: the write needs to happen with maximum i\o priority,
# otherwise the system WILL freeze, as it essentially results in swap death of the system.
echo $(for zram in /sys/block/zram* ; do echo echo_${zram_age}_${zram}/${file}; done) \
| sed -e 's/ / \| /g' -e 's/_/ /g' -e 's/\/sys/\>\/sys/g' | ionice -c 1 -n 1 bash -x
}


# we need full zswap functionality for temp_swap, and only need same_filled_pages the rest of the time
zswap(){
echo $1 >/sys/module/zswap/parameters/non_same_filled_pages_enabled
}

zswap 0

# not giving temp_swap swapoff rt priority, so that the system would become responsive sooner,
# while swapoff is still happeninig
do_temp_swapoff(){
ionice -c 2 -n 2 nice -n 0 swapoff $temp_swap
ionice -c 1 -n 1 rm $tmp_swap
# there's inevitably going to be some incompressible pages in zram after temp_swap swapoff,
# and usually it's okay to have a few, but since we're occupying i\o with swapoff anyway,
# it's better to dump them to disk immediately after, to use zram more efficiently.
do_write huge writeback
}

temp_swap(){
if  [ $1 != 0 ]
 then
  if ! [ -f $temp_swap ]
   then create_temp_swap
  fi
  
  swapon -p 100 $temp_swap # priority needs to be higher than zram's, so that zram won't be touched during writeback
 else
# forking swapoff, so that the script could continue.
# Otherwise ram limit can easily be exceeded while swapoff still happens, and we're fucked
  do_temp_swapoff &
fi
}

while true
do
 if [ `total_zram` -gt $compressed_ram_limit ]
# reading time of last writeback
  then age=$(( $EPOCHSECONDS - `cat $zram_time` ))
# disabling zram optimizations to prepare for disk-based swap 
   optimize_for_zram 0
# most likely the only swapoff running will be the swapoff of temp_swap,
# and we need that swap ready, before writeback begins.
# if you were swapoff-ing something else -- tough luck, should've read this script, try later
   while pidof swapoff
    do killall -9 swapoff
     sleep 0.1
   done

   temp_swap 1 # switching to disk-based swap
   zswap 1 # enabling full zswap functionality to soften up the performance hit

# jump forward in time every $time_chunk since last writeback, proggressively dumping less and less
# old pages, registered by zram tracking at those periods of time, until the amount of compressed data in
# RAM is less than $limit watermark_percent
   until [ `total_zram` -lt $(( $compressed_ram_limit /100 * $limit_watermark_percent )) ]
    do
     do_write huge writeback # dump huge\incompressible pages first, they're least welcome in zram
     do_write $age idle
     do_write idle writeback
     age=$(( $age - $time_chunk )) 
   done 

   echo $EPOCHSECONDS >$zram_time # mark time of successful writeback
   zswap 0 # return to lightweight zero- same-filled pages only zswap
   sleep 0.2 # just in case, wait for zswap settings to take effect
   temp_swap 0 # disabling hdd-based swap
   optimize_for_zram # optimize swapping for zram. Duh.

 fi

 sleep 5 # check every 5 seconds if $compressed_ram_limit was exceeded 
done
