#!/bin/bash

# generally exit codes are:
#  0 - success
#  1 - fatal error
#  2 - internal error or possible TODO

cleanup_tmpfiles() {
	if [ -n "$DM_INFO_FILE" ]; then
		DIRNAME=$(dirname "$DM_INFO_FILE")
		if [ -z "$DIRNAME" ] ; then
			echo "FATAL: Unable to determine location of temporary files" >&2
			exit 1
		elif ! [[ $DIRNAME =~ ^/[!-.0-9:=@-Z^_a-z~]+(/|$) ]] ; then
			echo "FATAL: invalid location of temporary files: $DIRNAME" >&2
			exit 1
		elif [ ! -d "$DIRNAME" ] ; then
			echo "FATAL: invalid temporary file directory: $DIRNAME" >&2
			exit 1
		elif ! [[ $DM_INFO_FILE =~ ^/[!-.0-9:=@-Z^_a-z~]+/tmp\.[!-.0-9:=@-Z^_a-z~]+$ ]] ; then
			echo "FATAL: invalid temporary file location: $DM_INFO_FILE" >&2
			exit 1
		elif [ ! -f "$DM_INFO_FILE" ] ; then
			echo "FATAL: invalid temporary file: $DM_INFO_FILE" >&2
			exit 1
		fi
		find "$DIRNAME" -path "$DM_INFO_FILE*" -delete || exit $?
	fi
}

fatal() {
	local RET=$1
	shift
	echo "FATAL: $*" >&2
	cleanup_tmpfiles
	exit $RET
}

if ! grep -Eq '^/dev/dm-0 ' /proc/swaps ; then
	# try to activate existing inactive swap
	echo "Unable to find active devicemapper swap; checking for inactive dm swap..."
	if [ -d '/dev/md' ]; then
		find /dev/md/ -type l \( -name 'swap[0-9]' -or -name '*:swap[0-9]' \) \
		| while read -r MD_NAME ; do
			echo -n "Found md swap device: $MD_NAME... "
			if ! realpath -e "$MD_NAME" | grep -Eq '^/dev/md127$' ; then
				echo "md swap device $MD_NAME is not md127"
				continue
			elif ! realpath -e "/dev/mapper/md127" | grep -Eq '^/dev/dm-0$' ; then
				echo "devicemapper device md127 is not dm-0"
				continue
			elif ! file -s '/dev/dm-0' | grep -Eq '^/dev/dm-0: Linux swap file, ' ; then
				echo "devicemapper device /dev/dm-0 is not formatted as swap"
				continue
			fi
			echo -n "Attempting to activate... "
			swapon /dev/dm-0
			RET=$?
			if [ $RET = 0 ]; then
				echo "Success!"
			else
				echo "Failed with code $RET."
			fi
		done
	fi
	# if we don't have any swap, abort now
	if ! grep -Eq '^/dev/dm-0 ' /proc/swaps ; then
		echo "Unable to detect inactive devicemapper swap either"
		fatal 1 "Unable to find any devicemapper swap"
	fi
fi

echo "Found devicemapper device /dev/dm-0 active as swap"

# build a full path to a temporary file
DM_INFO_FILE=$(mktemp)

# find dm_crypt devicemapper devices
dmsetup status --target crypt --noflush | grep -E '^(md[0-9]+): ([0-9]+) ([0-9]+) crypt ?(.*)$' | sed -r 's#^([^ :]+): ([0-9]+) ([0-9]+) crypt ?(.*)$#\1	\2	\3	\4#g' > "$DM_INFO_FILE" || fatal 1 "unable to find devicemapper device status"

# iterate each line of the temporary file
DM_IDX=0
while IFS="	" read DM_NAME DM_ZERO DM_BLOCKS DM_OPTIONS ; do
	DM_SIZEKB=$(( DM_BLOCKS / 2 ))
	if [ "$DM_ZERO" != "0" ]; then
		fatal 2 "unknown devicemapper device DM_ZERO: $DM_ZERO"
	fi
	if [ $DM_SIZEKB -le 0 ]; then
		fatal 1 "invalid devicemapper device size: $DM_BLOCKS blocks => $DM_SIZEKB KB"
	fi
	if [ -n "$DM_OPTIONS" ]; then
		fatal 2 "unknown devicemapper device options: $DM_OPTIONS"
	fi
	echo "devicemapper device $DM_NAME is $DM_SIZEKB KB"

	# ensure the devicemapper device is dm-0
	realpath -e "/dev/mapper/$DM_NAME" | grep -Eq '^/dev/dm-0$' || fatal 1 "devicemapper device $DM_NAME is not dm-0"

	# determine the constituent devices that make up the devicemapper device
	DMDEPS_INFO_FILE="$DM_INFO_FILE.$DM_IDX"
	DM_IDX=$(( DM_IDX + 1 ))
	dmsetup deps "$DM_NAME" | grep -E '^1 dependencies	: \(9, ([0-9]+)\)$' | sed -r 's#^1 dependencies	: \(9, ([0-9]+)\)$#\1#g' > "$DMDEPS_INFO_FILE" || fatal 1 "unable to find devicemapper device md dependencies"
	DM_MD_MINOR=$(cat "$DMDEPS_INFO_FILE" | sort -n | head -n 1)
	if [ -z "$DM_MD_MINOR" ]; then
		fatal 1 "unable to find devicemapper device md minor"
	fi
	MD_DEVICE="/dev/md$DM_MD_MINOR"
	echo "devicemapper device $DM_NAME uses md$DM_MD_MINOR"
	if [ ! -e "$MD_DEVICE" ]; then
		fatal 1 "md device $MD_DEVICE does not exist"
	fi

	# find out the array properties of the md device
	MD_INFO_FILE="$DM_INFO_FILE.$DM_IDX.mdinfo"
	mdadm --detail "$MD_DEVICE" | sed -r 's#^(/dev/md[0-9]+:)?$|^ +Number +Major +Minor +RaidDevice +State$##g ; T next ; d ; :next ; s#^ *([^ :][^:]*) : (.*)$#MD_\1="\2"#g ; :removespaces ; s#^([^ =]+) ([^=]*)=#\1_\2=#g ; t removespaces ; s#="([0-9]+)"$#=\1#g ; s#="(.*[^ ]) +"$#="\1"#g ; s#^ +([0-9]+) +([0-9]+) +([0-9]+) +([0-9]+) +([^ ].+[^ ]) +(/.+)$#MD_SLAVE_\1="\2\t\3\t\4\t\5\t\6"#g ; s#^ +(-) +([0-9]+) +([0-9]+) +([0-9]+) +(removed)$#MD_SLAVE_REMOVED="\2\t\3\t\4\t\5\t"#g' > "$MD_INFO_FILE" || fatal 2 "unable to process mdadm details"
	. "$MD_INFO_FILE"
	grep 'MD_SLAVE_' "$MD_INFO_FILE"

	# update a few properties
	MD_FULLNAME=$( sed -r 's#^([^ ]+)  \(local to host (\w+)\)$#\1#g ; t ; d' <<< "$MD_Name" )
	if [ -n "$MD_FULLNAME" ]; then
		MD_LOCALHOST=$( sed -r 's#^(\w+):(\w+)  \(local to host (\w+)\)$#\3#g ; t ; d' <<< "$MD_Name" )
		MD_NAME_HOST=$( sed -r 's#^(\w+):(\w+)$#\1#g ; t ; d' <<< "$MD_FULLNAME" )
	else
		MD_FULLNAME=$( sed -r 's#^([^ :]+)$#\1#g ; t ; d' <<< "$MD_Name" )
		if [ -n "$MD_FULLNAME" ]; then
			MD_NAME_HOST=$( hostname )
			MD_LOCALHOST="$MD_NAME_HOST"
			MD_FULLNAME="$MD_NAME_HOST:$MD_FULLNAME"
		elif [[ "$MD_Name" =~ ^([^ :]+):([^ :]+)$ ]]; then
			MD_FULLNAME="$MD_Name"
			IFS="	" read MD_NAME_HOST <<< "$( sed -r 's#^([^ :]+):([^ :]+)$#\1#g ; t ; d' <<< "$MD_Name" )"
			if [ -n "$MD_NAME_HOST" ]; then
				MD_LOCALHOST=$( hostname )
				KVER_HOST=$( sed -r 's#^Linux version [.0-9]+-[^ ]+ \(root@([^ :)]+)\) \(gcc .*$#\1#g ; t ; d' /proc/version )
			fi
		fi
	fi
	if [ -z "$MD_FULLNAME" ]; then
		fatal 2 "unable to determine md device full name from: $MD_Name"
	elif [ -z "$MD_LOCALHOST" ]; then
		fatal 2 "unable to determine md device local host from: $MD_Name"
	elif [ -z "$MD_NAME_HOST" ]; then
		fatal 2 "unable to determine md device name host from: $MD_Name"
	fi

	if [ "$MD_NAME_HOST" == "$KVER_HOST" ]; then
		echo "md device name host ($MD_NAME_HOST) is the default kernel build hostname" >&2
	elif [ "$MD_NAME_HOST" != "$MD_LOCALHOST" ]; then
		fatal 1 "md device name host ($MD_NAME_HOST) does not match its home host ($MD_LOCALHOST) in line: $MD_Name"
	fi

	MD_Name=$( sed -r 's#^([^ :]+):(\w+)$#\2#g ; t ; d' <<< "$MD_FULLNAME" )
	if [ -z "$MD_Name" ]; then
		fatal 1 "unable to determine md device name from: $MD_FULLNAME"
	fi

	OLD="$MD_Array_Size"
	MD_Array_Size=$( sed -r 's#^([0-9]+) \(.*\)$#\1#g ; t ; d' <<< "$MD_Array_Size" )
	if [ -z "$MD_Array_Size" ]; then
		fatal 1 "unable to determine md array size from: $OLD"
	fi

	OLD="$MD_Used_Dev_Size"
	MD_Used_Dev_Size=$( sed -r 's#^([0-9]+) \(.*\)$#\1#g ; t ; d' <<< "$MD_Used_Dev_Size" )
	if [ -z "$MD_Used_Dev_Size" ]; then
		fatal 1 "unable to determine md array used device size from: $OLD"
	fi

	if [ "$MD_Raid_Devices" != "2" ]; then
		fatal 1 "md array raid devices is not 2: $MD_Raid_Devices"
	fi
	if [ -z "$MD_Total_Devices" ]; then
		fatal 1 "unable to determine md array total devices"
	elif [ "$MD_Total_Devices" = "0" ]; then
		fatal 1 "md array total devices is zero"
	elif [ $(( MD_Total_Devices +0 )) -lt 1 ]; then
		fatal 1 "md array total devices is less than 1"
	elif [ "$MD_Total_Devices" == "1" ]; then
		SWAP_COUNT=$( wc -l < /proc/swaps )
		SWAP_COUNT=$(( SWAP_COUNT - 1 ))
		if [ $SWAP_COUNT != 2 ]; then
			fatal 2 "this script can only cleanup the md swap device with 2 swaps mounted.  If you're trying to recover a failed attempt, maybe first do: swapon /dev/dm-0"
		fi
		if [ -z "$MD_SLAVE_REMOVED" ]; then
			fatal 2 "this script can't handle complex swap configurations yet.  To process an MD device with only a single active slave device, the MD device must also have at least 1 removed slaved device."
		fi
		# TODO: we have to remove swap all at once or use a temp swap file
		#fatal 2 "this script can't handle just 1 swap device yet"
	fi

	if [ "$MD_Raid_Level" != "raid1" ]; then
		fatal 2 "unexpected md array raid level: $MD_Raid_Level"
	fi
	if [ "$MD_State" = "clean, resyncing" -o "$MD_State" = "clean, degraded, recovering" -o "$MD_State" = "active, resyncing" ]; then
		echo "md array state: $MD_State"
		echo "Waiting for resync/recovery..."
		DELAY=1
		START=$SECONDS
		LASTPERC=-1
		while [ "$MD_State" = "clean, resyncing" -o "$MD_State" = "clean, degraded, recovering" -o "$MD_State" = "active, resyncing" ]; do
			sleep $DELAY
			MD_State=$( mdadm --detail "$MD_DEVICE" | grep -E '^ *State : ' | sed -r 's#^ *State : +([^ ].*[^ ]) *$#\1#g ; t ; d' )
			MD_Resync_Status=$( mdadm --detail "$MD_DEVICE" | grep -E '^ *Re(sync|build) Status : ' | sed -r 's#^ *Re(sync|build) Status : +([^ ].*[^ ]) *$#\2#g ; t ; d' )
			if [ -n "$MD_Resync_Status" ]; then
				echo -en "\rStatus: $MD_State, $MD_Resync_Status, "
				PERC=$( echo "$MD_Resync_Status" | sed -r 's#^([0-9]+)%.*$#\1#g' )
				ELAPSED=$(( SECONDS - START ))
				#echo -n " ELAPSED=$ELAPSED;"
				ESTIMATED=$(( ELAPSED * 100 / PERC ))
				#echo -n " EST=$ESTIMATED;"
				REMAINING=$(( ESTIMATED - ELAPSED ))
				#echo -n " REMAIN=$REMAINING;"
				if [ $REMAINING -gt 86400 ]; then
					if [ $REMAINING -gt 2592000 ]; then
						COMPLETION=$( date -d "+$REMAINING sec" '+%a %Y-%m-%d' )
					elif [ $REMAINING -gt 604000 ]; then
						COMPLETION=$( date -d "+$REMAINING sec" '+%b %e @ %H:%M %Z' )
					else
						COMPLETION=$( date -d "+$REMAINING sec" '+%a @ %H:%M %Z' )
					fi
					PRETTY_REMAIN="$(( REMAINING / 86400 )) day(s) = $COMPLETION"
					DELAY=$(( DELAY * 6 / 5 ))
					if [ $DELAY -gt 14400 ]; then
						DELAY=14400
					elif [ $DELAY -lt 5 ]; then
						DELAY=5
					fi
				elif [ $REMAINING -gt 3600 ]; then
					COMPLETION=$( date -d "+$REMAINING sec" '+%k:%M %Z' )
					PRETTY_REMAIN="$(( REMAINING / 3600 ))h = $COMPLETION"
					if [ "$PERC" = "$LASTPERC" ]; then
						DELAY=$(( DELAY * 11 / 10 ))
					elif [ $PERC -gt $(( LASTPERC + 1 )) ]; then
						DELAY=$(( DELAY * 9 / 10 ))
					fi
					if [ $DELAY -gt 900 ]; then
						DELAY=900
					elif [ $DELAY -lt 10 ]; then
						DELAY=10
					fi
				elif [ $REMAINING -gt 60 ]; then
					COMPLETION=$( date -d "+$REMAINING sec" '+%k:%M:%S %Z' )
					PRETTY_REMAIN="$(( REMAINING / 60 ))m = $COMPLETION"
					DELAY=$(( ( REMAINING / 240 ) + 1 ))
				else
					PRETTY_REMAIN="${REMAINING}s"
					DELAY=1
				fi
				#echo -en "DELAY=$DELAY; "
				echo -en "Estimated Completion: $PRETTY_REMAIN   \b\b\b"
				LASTPERC=$PERC
			fi
		done
		echo -e "\r\033[2K\rStatus: $MD_State"
		echo "Restarting process..."
		$0
		exit $?
	fi
	if [ "$MD_State" != "clean" ] && [ "$MD_State" != "active" ] && [ "$MD_State" != "clean, degraded" ]; then
		fatal 2 "unexpected md array state: $MD_State"
	fi
# 	echo "DEBUG: all was ok, forcing resync on /dev/sdb1 ..."
# 	mdadm /dev/md127 --fail /dev/sdb1
# 	sleep 1
# 	mdadm /dev/md127 --remove /dev/sdb1 || fatal 3 "DEBUG on line $LINENO"
# 	mdadm /dev/md127 --add /dev/sdb1 || fatal 3 "DEBUG on line $LINENO; don't forget to re-add /dev/sdb1"
# 	fatal 3 "DEBUG on line $LINENO"

	# parse MD_SLAVE_* properties
	MD_SLAVE_IDX=0
	MD_SLAVE_LAST_IDX=$(( MD_Raid_Devices - 1 ))
	MD_SLAVE_IS_FIRST=1
	while [ $MD_SLAVE_IDX -lt $MD_Raid_Devices ]; do
		MD_SLAVE_VAR="MD_SLAVE_$MD_SLAVE_IDX"
		MD_SLAVE_DATA="${!MD_SLAVE_VAR}"
		if [ -z "$MD_SLAVE_DATA" ]; then
			if [ -z "$MD_SLAVE_REMOVED" ]; then
				fatal 1 "unable to determine md array slave $MD_SLAVE_IDX data"
			fi
			IFS="	" read MD_SLAVE_MAJOR MD_SLAVE_MINOR MD_SLAVE_RAIDDEVICE_ID MD_SLAVE_STATE MD_SLAVE_DEVICE <<< "$MD_SLAVE_REMOVED"
			if [ "$MD_SLAVE_RAIDDEVICE_ID" != "$MD_SLAVE_IDX" ]; then
				fatal 1 "unable to determine md array slave $MD_SLAVE_IDX data: unexpected removed device id: $MD_SLAVE_RAIDDEVICE_ID != $MD_SLAVE_IDX"
			elif [ "$MD_SLAVE_STATE" != "removed" ]; then
				fatal 1 "unable to determine md array slave $MD_SLAVE_IDX data: unexpected removed device state: $MD_SLAVE_STATE"
			elif [ -n "$MD_SLAVE_DEVICE" ]; then
				fatal 1 "unable to determine md array slave $MD_SLAVE_IDX data: unexpected removed device file: $MD_SLAVE_DEVICE"
			elif [ "$MD_SLAVE_MAJOR" != "0" ]; then
				fatal 1 "unable to determine md array slave $MD_SLAVE_IDX data: unexpected removed device major: $MD_SLAVE_MAJOR"
			elif [ "$MD_SLAVE_MINOR" != "0" ]; then
				fatal 1 "unable to determine md array slave $MD_SLAVE_IDX data: unexpected removed device minor: $MD_SLAVE_MINOR"
			fi
			# increment MD_SLAVE_IDX for next iteration
			MD_SLAVE_IDX=$(( MD_SLAVE_IDX + 1 ))
			continue
		fi
		if [ $MD_SLAVE_IDX == 1 ]; then
			MD_SLAVE_IS_FIRST=0
		fi
		if [ $MD_SLAVE_IDX == $MD_SLAVE_LAST_IDX ]; then
			MD_SLAVE_IS_LAST=1
		fi
		# parse: Major Minor RaidDeviceId State device
		IFS="	" read MD_SLAVE_MAJOR MD_SLAVE_MINOR MD_SLAVE_RAIDDEVICE_ID MD_SLAVE_STATE MD_SLAVE_DEVICE <<< "$MD_SLAVE_DATA" || fatal 2 "unable to parse md array slave $MD_SLAVE_IDX data: $MD_SLAVE_DATA"
		if [ -z "$MD_SLAVE_DEVICE" ]; then
			fatal 1 "unable to determine md array slave $MD_SLAVE_IDX device"
		fi
		if [ "$MD_SLAVE_STATE" != "active sync" ]; then
			fatal 2 "unexpected md array slave $MD_SLAVE_IDX state: $MD_SLAVE_STATE"
		fi

		# ensure the device name is valid
		if ! [[ $MD_SLAVE_DEVICE =~ ^/dev/[0-9A-Za-z]+$ ]]; then
			fatal 1 "invalid md array slave $MD_SLAVE_IDX device: $MD_SLAVE_DEVICE"
		elif [ ! -e "$MD_SLAVE_DEVICE" ]; then
			fatal 1 "md array slave $MD_SLAVE_IDX device $MD_SLAVE_DEVICE does not exist"
		fi

		# for last device, we have to shut down the DM swap, destroy the devicemapper device, destroy the MD device, and then setup that final MD slave swap device
		if [ "$MD_SLAVE_IS_LAST" == "1" ]; then
			# remove devicemapper swap device from kernel swaps
			echo "Removing devicemapper swap device /dev/dm-0 from kernel swaps..."
			swapoff /dev/dm-0 || fatal 1 "unable to remove devicemapper swap device /dev/dm-0 from kernel swap"
			echo "Removed from kernel swap: /dev/dm-0"

			# destroy devicemapper device
			echo -n "Destroying devicemapper device /dev/mapper/$DM_NAME..."
			dmsetup remove --retry "$DM_NAME" || fatal 1 "unable to destroy devicemapper device /dev/mapper/$DM_NAME"
			echo " Destroyed."

			# stop the MD array
			echo -n "Stopping md array $MD_DEVICE... "
			mdadm --stop "$MD_DEVICE" || fatal 1 "unable to stop md array"
			echo -en "\r"
		else
			# remove slave device from MD array
			echo "Removing slave device $MD_SLAVE_DEVICE from md array $MD_DEVICE..."
			mdadm "$MD_DEVICE" --fail "$MD_SLAVE_DEVICE" --remove "$MD_SLAVE_DEVICE" || fatal 1 "unable to remove md array slave $MD_SLAVE_IDX device $MD_SLAVE_DEVICE from $MD_DEVICE"
		fi

		# setup removed device as swap directly
		mkswap --lock -U random "$MD_SLAVE_DEVICE" || fatal 1 "unable to setup md array slave $MD_SLAVE_IDX device $MD_SLAVE_DEVICE as direct swap device"
		swapon -p0 "$MD_SLAVE_DEVICE" || fatal 1 "unable to reactivate md array slave $MD_SLAVE_IDX device $MD_SLAVE_DEVICE as kernel swap device"

		# increment MD_SLAVE_IDX for next iteration
		MD_SLAVE_IDX=$(( MD_SLAVE_IDX + 1 ))
	done

	# DEBUG output
	#set | grep -E '^MD_'
	cat /proc/swaps

done < "$DM_INFO_FILE"
cleanup_tmpfiles
