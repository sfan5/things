#!/bin/bash
set -e

msg() { printf '\e[35;1m~~~\e[0m %s\n' "$1"; }
die() { msg "ERROR: $1"; exit 1; }

target=./output/alarm-aarch64-latest.tar.gz

[ $EUID -eq 0 ] || die "Root privileges required"

if [ -n "$INVM" ]; then ########################################################

# host -> vm (where the script runs)
#         ^^^^^^^^^^^^^^^^^^^^^^^^^^

systemd-detect-virt -v || die "not meant to be"
[[ "$(uname -m)" == aarch64 ]] || die "not meant to be"

msg "Installing requirements"
# apply some options to improve performance (placebo?)
echo 0 >/proc/sys/kernel/randomize_va_space 
mount '' / -o remount,commit=3600
dd if=/dev/hwrng of=/dev/random count=16
#
pacman-key --init && pacman-key --populate
pacman -S --noconfirm --needed arch-install-scripts

# put temporary files on rootfs, that'll be faster
WORKDIR=/root

fi
if [[ "$(uname -m)" != aarch64 ]]; then ########################################

# host -> vm (where the script runs)
# ^^^^

[ -s "$target" ] || die "Need a previous rootfs build to bootstrap"
for exe in mkfs.ext4 bsdtar qemu-system-aarch64; do
	command -v "$exe" >/dev/null || die "Missing $exe"
done

msg "Preparing VM"

mntdir=
tmpfile=
cleanup_mount () {
	if [ -n "$mntdir" ]; then
		umount "$mntdir"
		rmdir "$mntdir"
		mntdir=
	fi
}
_cleanup () {
	set +e
	cleanup_mount
	[ -n "$tmpfile" ] && { rm "$tmpfile"; tmpfile=; }
}
trap _cleanup EXIT

truncate -s 5G "./vm$$.bin"
tmpfile=./vm$$.bin

mkfs.ext4 -q "$tmpfile"

mkdir "./mnt$$"
mntdir=./mnt$$

mount "$tmpfile" "$mntdir" -o loop,noatime

bsdtar -xpf "$target" -C "$mntdir"
# get rid of interference
rm "$mntdir/usr/lib/systemd/system/multi-user.target.wants/getty.target" \
	"$mntdir/usr/lib/systemd/system/sysinit.target.wants/systemd-firstboot.service"
# configure the 9p mount
printf '%s\t' >>"$mntdir/etc/fstab" \
	shared /mnt 9p trans=virtio,version=9p2000.L,msize=104857600
printf '\n' >>"$mntdir/etc/fstab"
# add a service that runs us on startup
printf '%s\n' >"$mntdir/etc/systemd/system/script.service" \
	[Unit] RequiresMountsFor=/mnt {Failure,Success}Action=poweroff-force \
	[Service] Type=oneshot Environment=INVM=1 Standard{Output,Error}=tty \
	WorkingDirectory=/mnt ExecStart=/mnt/make_rootfs.sh
ln -s "etc/systemd/system/script.service" "$mntdir/etc/systemd/system/multi-user.target.wants/"

cleanup_mount

msg "Re-launching in VM"
args=(
	-M virt -cpu cortex-a53 -m 2048 -smp 2
	-kernel bins/Image.gz
	-nic user,model=virtio
	-drive file="$tmpfile",if=virtio,format=raw,cache=unsafe
	# current folder shared via 9p
	-fsdev local,id=shared,path="$PWD",security_model=none
	-device virtio-9p-pci,fsdev=shared,mount_tag=shared
	# hopefully speeds up cryptograhic ops in guest
	-device virtio-rng-pci
	# remove 'quiet' to see systemd and kernel output
	-append "root=/dev/vda rw quiet" -nographic
)
qemu-system-aarch64 "${args[@]}"

# FIXME: somehow extract the exit code from inside the vm
exit 0

fi #############################################################################

if ! command -v pacstrap; then
	die TODO # should this be supported?
fi

for exe in unshare bsdtar; do
	command -v "$exe" >/dev/null || die "Missing $exe"
done

# host -> chroot (target)

tmpdir=
active_mounts=()
cleanup_mounts () {
	if [ ${#active_mounts[@]} -gt 0 ]; then
		umount "${active_mounts[@]}"
	fi
	active_mounts=()
}
_cleanup () {
	set +e
	cleanup_mounts
	[ -n "$tmpdir" ] && { rm -rf "$tmpdir"; tmpdir=; }
}
trap _cleanup EXIT

[[ -n "$WORKDIR" && -d "$WORKDIR" ]] || WORKDIR=.
install -d -m 755 "$WORKDIR/tmp$$"
tmpdir=$WORKDIR/tmp$$

pkgs=(
	base
	linux-aarch64 linux-firmware
	openssh net-tools
	netctl # for wifi-menu
	nano vi
	archlinuxarm-keyring # hotfix until ALARM has fixed their `base`
)

msg "Running pacstrap"
pacstrap -c -GM "$tmpdir" "${pkgs[@]}"

msg "Applying customizations"
target_chroot () {
	PATH=/usr/bin unshare -R "$tmpdir" -- "$@" </dev/null
}
add_mount () {
	local from="$1"
	local to="$2"
	shift; shift
	mount "$from" "$tmpdir$to" "$@"
	active_mounts+=("$tmpdir$to")
}

add_mount proc /proc -t proc

# FIXME: should set up minimal amount of devices instead
add_mount dev /dev -t devtmpfs
install -d 1777 "$tmpdir/dev/shm"

add_mount tmpfs /tmp -t tmpfs -o nosuid,nodev,mode=1777
add_mount tmpfs /run -t tmpfs -o nosuid,nodev

# regenerate initramfs
target_chroot mkinitcpio -P

# services
target_chroot systemctl enable sshd.service systemd-{resolved,networkd,timesyncd}.service

# system config
target_chroot bash -c '
echo alarm | install -T -m 644 /dev/stdin /etc/hostname
echo LANG=C | install -T -m 644 /dev/stdin /etc/locale.conf
'

# network
target_chroot bash -c '
for prefix in en eth; do
	install -T -m 644 /dev/stdin /etc/systemd/network/${prefix}.network <<STOP
[Match]
Name=${prefix}*

[Network]
DHCP=yes
DNSSEC=no
STOP
done
rm /etc/resolv.conf
ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
'

# user accounts
target_chroot bash -c '
useradd -m alarm
printf "%s\n" root:root alarm:alarm | chpasswd
'

# cleanup
target_chroot bash -c '
yes | pacman -Scc
rm -r /root/.gnupg
rm /var/log/pacman.log /etc/machine-id
'

cleanup_mounts

msg "Creating archive"
rm -f "$target"
bsdtar -cz --numeric-owner -f "$target" -C "$tmpdir" .

msg "Done"
ls -l "$target"
exit 0
