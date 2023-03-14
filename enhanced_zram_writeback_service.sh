#!/bin/bash

# This script attempts to squeeze a bit more performance out of a potato pc.

# It works by continuosly monitoring the amount of zram-occupied RAM,
# and dumping old pages to an hdd-based backing storage, preventing usual zram problem of LRU inversion.
# In order for zram to tell new and old pages apart,
# a debug feature CONFIG_ZRAM_MEMORY_TRACKING is exploited, so ensure you have it enabled.

# The script will be useful (for me) for as long as zswap doesn't have ALL of the below entries fully implemented:
# - zsmalloc writeback [ IMPLEMENTED ]
# - NOT writing zero- and same-filled pages to regular swap during writeback (seriously, that's ~10% of swap i\o, wtf)
# - multiple compression algorithms that zram introduced in 6.2
# - ability to drop zpool's contents to regular swap at any time i like, instead of having it just sit in RAM forever.
# - ability to have incompressible pages in RAM at least for a short while. As counterintuitive as that sounds,
# a lot of those pages are short-lived, so it's more expensive to immediately write them to regular swap, instead of
# allowing them to waste RAM for a little while, until there's a real need to drop them. Even if you have an SSD, 
# it might still be a useful feature, that'll help to reduce the number of writes to it.

# If you have:
# -more than 4GB RAM and/or
# -an SSD and/or
# -will to live,
# then you probably don't need this script. Just enable about 30% zswap and call it a day, 
# you'll be fine for the most part, especially with lazy desktop usage, especially since zsmalloc pool 
# writeback implementation is finished.

# The script has a drawback -- in exchange for a bit more performance for long intervals of time,
# every once in a while, for short periods of time, your whole computer might become sluggish
# or even completely freeze for a bit, while the writeback of old pages to the backing device is happening. 
# It's expected, it's going to be back to normal once the writeback is complete. Start worrying though, 
# if it's still completely frozen after ~5 minutes -- your system is likely dying in agony


if ! zcat /proc/config.gz | grep CONFIG_ZRAM_MEMORY_TRACKING | grep y
 then echo "no zram tracking enabled, bye" 
      exit 1
fi

# amount of seconds beyond which everything is written without consideration of data age.
max_age=$(( 3600 * 3 ))

# not recommended to put values higher than 50, unless you're using this on a 8+ gb ram pc for some reason
ram_percent=25 

total_ram=`cat /proc/meminfo  | grep MemTotal | awk '{print $2}'`
compressed_ram_limit=$((  ($total_ram /100 * $ram_percent) * 1024  ))

# writeback will continue until this percentage of $compressed_ram_limit remains in RAM
# basically this controls how often the writeback would trigger in high memory pressure conditions:
# 10 means almost all of your zram-swap will be written to disk, so subsequent writeback will happen rarely,
# at the cost of worse multitasking and interactivity with already running programs,
# 100 means only very old and unneeded pages will be written to disk, keeping multitasking and
# interactivity at maximum, at the cost of more frequent writes. Test different values, ymmw

allow_left_compressed_ram_limit=90

# ensure zswap and specifically "same_filled_pages_enabled" are enabled,
# as the goal is to reduce unnecessary i\o, we need to catch all the zero- and same-filled pages possible,
# and prevent them from taking up valuable disk space and cpu time, regardless of what type of swapping is enabled.
echo zsmalloc >/sys/module/zswap/parameters/zpool
echo 5 >/sys/module/zswap/parameters/max_pool_percent
echo 1 >/sys/module/zswap/parameters/enabled
echo 1 >/sys/module/zswap/parameters/same_filled_pages_enabled
echo 0 >/sys/module/zswap/parameters/non_same_filled_pages_enabled
echo 99 >/sys/module/zswap/parameters/accept_threshold_percent

optimize_for_zram(){
if [ -z $1 ]
 then v0=200 # maximum swapping
 else v0=60 # prefer to drop caches under memory pressure
fi

sysctl -w vm.swappiness=$v0
sysctl -w vm.page-cluster=0 # even though backing store is hdd, most reads will be done from ram
sysctl -w vm.vfs_cache_pressure=100 # ensuring default, playing around does nothing good, the system knows better
}

total_zram(){
awk '{ sum += $3 }; END { print sum }' /sys/block/zram*/mm_stat
}

do_write(){
zram_age=$1
file=$2
# this madness ensures the writeback happens on all devices simultaneously.
# IMPORTANT: the write needs to happen with maximum i\o priority,
# otherwise the system WILL freeze
echo $(for zram in /sys/block/zram* ; do echo echo_${zram_age}_${zram}/${file}; done) \
| sed -e 's/ / \| /g' -e 's/_/ /g' -e 's/\/sys/\>\/sys/g' | chrt -r 3 ionice -c 1 -n 0 bash -x
}

do_recompress(){
sec=$1
if ! [ $sec == all ]
 then
  do_write \"type=huge_algo=zstd\" recompress
  do_write $sec idle
  do_write \"type=idle_algo=zstd\" recompress
 else
  do_write \"type=all_algo=zstd\" recompress
fi
do_write incompressible writeback
}

do_writeback(){
sec=$1
sync &
do_write huge writeback
do_write $sec idle
do_write idle writeback
}

get_zram_age(){
# oldest _not_already_written_ zram page
age=`cat /sys/kernel/debug/zram/zram*/block_state | grep -v w | awk '{print $2}' | sort -n | head -n 1 | awk '{printf "%.0f", $1 }'`
}

do_slow_writeback(){
# while zram is over allowable limit, but hasn't approached a hard limit yet, begin to slowly write stuff
# every $wait_period seconds.
wait_period=$(( 60 * 10 ))
slow_writeback_time=/tmp/slow_writeback_last
touch $slow_writeback_time
if [ $EPOCHSECONDS -gt $(( `cat $slow_writeback_time` + $wait_period )) ]
      then do_writeback $max_age ; echo 1 | tee /sys/block/zram*/compact >/dev/null 
           echo $EPOCHSECONDS >$slow_writeback_time
fi
}

#######
#######
#######
# This section contains code related to enabling regular swap temporarily, while zram writeback is happening.
# Enabling temporary swap on an hdd is not recommended, as it proved to actually cause more hangups instead of 
# preventing them. Might be a different story with an ssd, but I have none, so didn't test.
# You can safely remove this section if you want to.
# Leaving the code in just in case, maybe it'll be useful one day

# change this to any non-zero value to enable temporary swap
temp_swap_on=0

temp_swap=/home/temp_swapfile

create_temp_swap(){
# create swap three times the size of already occupied swap.

# the number is completely arbitrary, it just makes me feel safer,
# in case any rogue program decides to swap a few gb while the writeback is still happening
size=`free -m | grep Swap | awk '{print int ($3 * 3 )}'`

# can't just truncate a sparse file, as allocating blocks requires paging, so might run into a deadlock.
# can't dd a file, too slow, the system will freeze long before the write is complete.
# so fallocate is a compromise, even though it's not recommended for swap files.
chrt -r 3 ionice -c 1 -n 0 fallocate -l ${size}M $temp_swap 
chmod 0600 $temp_swap
mkswap $temp_swap
}

# giving temp_swap swapoff rt priority, so that the system would become responsive sooner
do_temp_swapoff(){
zswap 0
chrt -r 3 ionice -c 1 -n 1 swapoff $temp_swap
chrt -r 3 ionice -c 1 -n 0 rm $temp_swap

# since the system is slow due to swapoff anyway, it's better to dump huge pages to disk immediately after,
# and force maximum compression to use zram more efficiently, it'll only take an extra few seconds
do_write huge writeback
do_recompress all
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
# Otherwise ram limit can easily be exceeded while swapoff still happens, and then we're fucked
  do_temp_swapoff &
fi
}

temp_swap_on(){
# these will only be used for temp_swap to soften up the performance hit of switching from zram to disk swap.
# remember that max_pool_percent will initially be added to already occupied $ram_percent,
# until the zram writeback dumps enough data to backing_dev to free up RAM,
# so it's possible that the system might get locked if you set these values too high.
echo 5 >/sys/module/zswap/parameters/max_pool_percent
echo zstd >/sys/module/zswap/parameters/compressor  # maximum compression
echo zsmalloc >/sys/module/zswap/parameters/zpool

# at values lower than 100, once filled, zswap will flat out stop accepting any new pages at all,
# even zero- and same-filled, which forces the system to write to disk-based swap directly,
# resulting in LRU inversion. With a value of 100, system continues to shove pages down zswap's throat,
# further softening up the performance hit of having to swap short-lived pages directly to disk,
# and also LRU inversion doesn't happen.
echo 100 >/sys/module/zswap/parameters/accept_threshold_percent 

# we need temp_swap ready before writeback begins, so stopping a temp_swap swapoff if it's still happening.
swapoff_pid=`ps -aux | grep swapoff | grep $temp_swap | grep -v grep | awk '{print $2}'`
   while pidof swapoff | grep $swapoff_pid
    do kill -9 $swapoff_pid
     sleep 0.1
   done 
   temp_swap 1 # switching to disk-based swap
   zswap 1 # enabling full zswap functionality to soften up the performance hit
}


# End of temp_swap section
#######
#######
#######



optimize_for_zram

# magic starts here

while true
do
 if [ `total_zram` -gt $compressed_ram_limit ]
     then get_zram_age ; optimize_for_zram 0
     [ -z $temp_swap_on ] || [ $temp_swap_on != 0 ] && temp_swap_on

# jump forward in time every $time_chunk since last writeback, progressively dumping less and less
# old pages, registered by zram tracking at those periods of time, until the amount of compressed data in
# RAM is less than $allow_left_compressed_ram_limit
#
   echo 1 | tee /sys/block/zram*/compact >/dev/null
   until [ `total_zram` -lt $(( $compressed_ram_limit /100 * $allow_left_compressed_ram_limit )) ]
     do before=`total_zram`
	      do_recompress $age
	      after=`total_zram`
        [ $after -ge $before ] && do_writeback $age
# amount of seconds to jump
     if [ $age -ge $(( 3600 * 6 )) ]
        then time_chunk=3600
     elif [ $age -le 3600 ]
        then time_chunk=120
        else time_chunk=600
     fi
     age=$(( $age - $time_chunk )) 
   done
   echo 1 | tee /sys/block/zram*/compact >/dev/null 
   [ -z $temp_swap_on ] || [ $temp_swap_on != 0 ] && temp_swap 0 
   optimize_for_zram
 fi
#do_slow_writeback
# check every 5 seconds if $compressed_ram_limit was exceeded 
 sleep 5 
done
