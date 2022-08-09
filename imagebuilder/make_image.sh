#!/bin/bash
set -e
export LC_ALL=C

source ./common.sh
setup_cleanup_hook

device=quartz64-b
target=./output/alarm-${device}-latest.img.gz

[ $EUID -eq 0 ] || die "Root privileges required"

#if [[ "$(uname -m)" != aarch64 ]]; then
#	die TODO # host -> vm (where the script runs) -> chroot (target)
#fi

check_tools sfdisk losetup mkfs.vfat mkfs.ext4 bsdtar pv

source=./output/alarm-aarch64-latest.tar.gz
[ -s "$source" ] || die "Missing the rootfs at $source"

loopdev=
mntdir=
tmpfile=
cleanup_mount () {
	if [ -n "$mntdir" ]; then
		umount -R "$mntdir"
		rmdir "$mntdir"
		mntdir=
	fi
}
_cleanup_other () {
	[ -n "$loopdev" ] && { losetup -d "$loopdev"; loopdev=; }
	[ -n "$tmpfile" ] && { rm "$tmpfile"; tmpfile=; }
}
add_cleanup_hook cleanup_mount _cleanup_other

truncate -s 2G "./blk$$.bin"
tmpfile=./blk$$.bin

msg "Partitioning"
sfdisk "$tmpfile" <<"PARTS"
label: gpt
unit: sectors
first-lba: 34
sector-size: 512

start=64, size=   1M, type=L, name="idblock"
start= +, size=   8M, type=L, name="uboot"
start= +, size= 512M, type=U, name="efi"
start= +, size=    +, type=L, name="root"
PARTS

loopdev=$(losetup -fP --show "$tmpfile")
echo "Loop device: $loopdev"

mkfs.vfat -F32 -n efi "${loopdev}p3"
mkfs.ext4 -L rootfs "${loopdev}p4"

# TODO: a bootloader package should handle this
cat <bins/idblock.bin >"${loopdev}p1"
cat <bins/uboot.img >"${loopdev}p2"

mkdir "./mnt$$"
mntdir=./mnt$$

mount "${loopdev}p4" "$mntdir" -o noatime
install -d -m 755 "$mntdir/boot"
mount "${loopdev}p3" "$mntdir/boot" -o noatime

msg "Extracting"
bsdtar -xpf "$source" -C "$mntdir"

mkdir -p "$mntdir/boot/extlinux"
install -T -m 644 /dev/stdin "$mntdir/boot/extlinux/extlinux.conf" <<"BOOTMENU"
default l0
menu title Quartz64 Boot Menu
prompt 0
timeout 50

label l0
menu label Arch Linux
linux /Image
fdt /dtbs/rockchip/rk3566-quartz64-b.dtb
append initrd=/initramfs-linux.img earlycon=uart8250,mmio32,0xfe660000 console=ttyS2,1500000n8 root=LABEL=rootfs rw rootwait
BOOTMENU

# TODO: should install the right kernel instead of this
cp bins/rk3566-quartz64-b.dtb "$mntdir/boot/dtbs/rockchip/"

sync "$mntdir/"
cleanup_mount

msg "Compressing"
pv "$loopdev" | gzip >"$target"

msg "Done"
ls -l "$target"
exit 0
