#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$1" = "--auto" ]; then
  dev1=$(readlink -e /dev/disk/by-partlabel/idblock)
  dev2=$(readlink -e /dev/disk/by-partlabel/uboot)

  if [[ "$dev1" != *[0-9] || "$dev2" != *[0-9] ]]; then
    echo "Error: couldn't detect partitions to flash U-Boot to (wrong layout?)" >&2
    exit 1
  fi

  echo "A new U-Boot version needs to be flashed onto $dev1 and $dev2."
  echo "Do you want to do this now? [y|N]"
  read -r shouldwe
  if [[ $shouldwe =~ ^([yY][eE][sS]|[yY])$ ]]; then
    set "$dev1" "$dev2"
  else
    echo "You can do this later by running:"
    echo "# /boot/flash_uboot.sh $dev1 $dev2"
    exit 0
  fi
fi

if [ -z "$2" ]; then
  echo "usage: $0 <idblock device> <uboot device>" >&2
  exit 1
fi

[ -z "$IDBLOCK" ] && IDBLOCK="$DIR/idblock.bin"
[ -z "$UBOOT" ] && UBOOT="$DIR/uboot.img"
if [ ! -f "$UBOOT" ]; then
  echo "error: $UBOOT does not exist" >&2
  exit 1
fi

if [ ! -b "$1" ]; then
  echo "Error: can't flash to $1, not a block device" >&2
  exit 1
fi
if [ ! -b "$2" ]; then
  echo "Error: can't flash to $1, not a block device" >&2
  exit 1
fi

dd if="$IDBLOCK" of="$1" conv=fsync bs=1M
dd if="$UBOOT" of="$2" conv=fsync bs=1M

echo "Successfully flashed U-Boot"
