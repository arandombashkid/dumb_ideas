# dumb_ideas
bash scripts with varying degree of sanity

Normal zram script sets up regular swap partitions/files as backing_dev for writeback; sparse zram script uses loop devices with sparse files attached to them.

Zram service does zram writeback in increments, exploiting zram tracking debug feature. It basically does what zswap can't -- allowes maximum compression using zsmalloc allocator, while being able to push old pages to disk. Essentially zsmalloc LRU eviction. Zswap can only do that with zbud and z3fold allocators, but not zsmalloc, so compression is limited to 3:1 at best, usually 2:1, while zstd algorithm is capable of doing 4:1 compression effortlessly. Hence the idea to write this. Made for slow devices only, and huge compromises were made in the process, so i doubt fast ones will benefit much, if at all. Read the script for more info.
