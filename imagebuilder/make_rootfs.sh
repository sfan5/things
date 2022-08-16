#!/bin/bash
set -e
export LC_ALL=C

source ./common.sh
setup_cleanup_hook

target=./output/alarm-aarch64-latest.tar.gz

[ $EUID -eq 0 ] || die "Root privileges required"

relaunch_in_vm "$target" && :
r=$?

if [ $r -eq 3 ]; then
	pacman-key --init && pacman-key --populate
	pacman -S --noconfirm --needed arch-install-scripts

	# put temporary files on rootfs, that'll be faster
	WORKDIR=/root
elif [ $r -eq 1 ]; then
	die "Error occurred ($?)"
elif [ $r -eq 0 ]; then
	exit 0
fi

if ! command -v pacstrap; then
	die TODO # should this be supported?
fi

check_tools unshare bsdtar

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
	nano vi
	archlinuxarm-keyring # hotfix until ALARM has fixed their `base`
)

msg "Running pacstrap"
pacstrap -c -GM "$tmpdir" "${pkgs[@]}"

msg "Applying customizations"
target_chroot () {
	run_in_target "$tmpdir" "$@"
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
