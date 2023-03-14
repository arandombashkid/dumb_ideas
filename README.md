# dumb_ideas
bash scripts with varying degree of sanity

Normal zram script sets up regular swap partitions/files as backing_dev for writeback; sparse zram script uses loop devices with sparse files attached to them.

Zram service does zram writeback in increments, exploiting zram tracking debug feature. I wrote this script before kernel 6.2 introduced zswap zsmalloc writeback, to imitate same behavior. Interestingly enough, even after it was implemented, my computer still works much faster with this script, rather than with pure zswap. Made for slow devices only, and huge compromises were made in the process, so i doubt fast ones will benefit much, if at all. Read the script for more info.
