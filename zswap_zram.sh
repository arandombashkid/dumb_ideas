#!/bin/bash

chmod 0666 /sys/class/backlight/psb-bl/brightness

# make sure zram module is loaded
lsmod | grep zram >/dev/null || modprobe zram


# no idea why, but writing to several backing_dev simultaneously is faster,
# even if they're all on a same hdd. Idk, maybe it has something to do with multithreading
for bd in /dev/sda8 /dev/sda9 /dev/sda10
do
 if [ -e $bd ]
  then
   bd_size=`fdisk -l $bd | head -n 1 | awk '{print $5}'` # match size of zram dev to the size of backing_dev
   zd=`zramctl -f | sed "s\/\\ \g" | awk '{print $2}'` # get zram dev name
   cd /sys/block/$zd
# the entire thing is useless if backing_dev can't be used, so bailing out
   if echo $bd >backing_dev
    then echo zstd >comp_algorithm
     echo $bd_size >disksize
     mkswap /dev/$zd
     swapon -p 1 /dev/$zd # need to have all zram dev being written to simultaneously,
                          # so later writing to disk would also be done simultaneously
    else echo "$swap is probably busy, can't be used, skipping"
   fi
 fi
done

