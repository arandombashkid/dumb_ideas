#!/bin/bash

# make sure zram module is loaded
lsmod | grep zram >/dev/null || modprobe zram

# zram by itself occupies ~1/1000th of it's own size ( an empty 100GB disksize consumes 100mb ram )
# backing_dev size
bd_size=23G

# no idea why, but writing to several backing_dev simultaneously is faster, 
# even if they're all on a same hdd. Idk, maybe it has something to do with multithreading
for bd in /home/sparseswap0 /home/sparseswap1 /home/sparseswap2   # 3 devices, 69gb swap total
do
 truncate -s 1 $bd # reduce to dust previously inflated files to save space
 truncate -s $bd_size $bd # set apparent size
 chmod 0600 $bd # prevent swapon from swearing
 loopdev=`losetup --nooverlap --find`
 losetup --direct-io=on $loopdev $bd
 mkswap $loopdev
 zd=`zramctl -f | sed "s\/\\ \g" | awk '{print $2}'` # get zram dev name
 cd /sys/block/$zd
# the entire thing is useless if backing_dev can't be used, so bailing out
 if echo $loopdev >backing_dev 
  then echo zstd >comp_algorithm # maximum effort
   echo $bd_size >disksize
   mkswap /dev/$zd
   swapon -d -p 1 /dev/$zd # need to have all zram dev being written to simultaneously, 
                        # so later writing to disk would also be done simultaneously
  else echo "$swap is probably busy, can't be used, skipping"
 fi
done

