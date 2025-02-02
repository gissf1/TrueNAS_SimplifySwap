#!/bin/bash

# generally exit codes are:
#  0 - success
#  1 - fatal error
#  2 - internal error or possible TODO

fatal() {
	local RET=$1
	shift
	echo "FATAL: $*" >&2
	cleanup_tmpfiles
	exit $RET
}

pretty_size() {
	# $1 size in blocks
	local SIZE=$1
	local SIZEKB=$(( SIZE / 2 ))
	if [ $SIZEKB -ge 10485760 ]; then
		SIZE=$(( SIZEKB / 1048576 ))
		echo -n "$SIZE GB"
	elif [ $SIZEKB -ge 10240 ]; then
		SIZE=$(( SIZEKB / 1024 ))
		echo -n "$SIZE MB"
	elif [ $SIZEKB -ge 1 ]; then
		echo -n "$SIZEKB KB"
	elif [ $SIZEKB == 0 ]; then
		echo -n "Empty"
	else
		echo -n "$SIZE 512-byte blocks"
	fi
}

ACTIVE_SWAPS=$( awk -e 'NR == 1 && /Filename/ { next } ; { print $1 }' /proc/swaps )

fdisk -l -x -o device,sectors,type-uuid 2>/dev/null \
| grep '0657FD6D-A4AB-43C4-84E5-0933C84B4F4F' \
| awk -e '{ print $1 "\t" $2 }' \
| while IFS="	" read -r DEVICE SIZE ; do
	PRETTY_SIZE=$( pretty_size "$SIZE" )
	echo "Analyzing $PRETTY_SIZE swap device: $DEVICE"

	IS_ACTIVE=""
	for ACTIVE_SWAP in $ACTIVE_SWAPS ; do
		echo "   comparing against active swap: $ACTIVE_SWAP"
		if [ "$ACTIVE_SWAP" == "$DEVICE" ]; then
			echo "      matched active swap"
			IS_ACTIVE=1
		fi
	done
	if [ -n "$IS_ACTIVE" ]; then
		echo "   matched active swap; skipping..."
		continue
	fi
	
	PRIORITY=${PRIORITY:-0}
	echo "Attempting to add $PRETTY_SIZE swap device with priority $PRIORITY: $DEVICE"
	swapon -p $PRIORITY "$DEVICE"

done
