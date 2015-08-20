#!/bin/sh

# size of swapfile in mb
swapsize=512

# do we have a swap file?
grep -q "swapfile" /etc/fstab

if [ $? -ne 0 ]; then
	echo 'No swap file available. Creating...'
	fallocate -l ${swapsize}M /swapfile
	chmod 600 /swapfile
	mkswap /swapfile
	swapon /swapfile
	echo '/swapfile none swap defaults 0 0' >> /etc/fstab
else
	echo 'swapfile found. No changes made.'
fi

# show resulting swap file info
cat /proc/swaps
cat /proc/meminfo | grep Swap
