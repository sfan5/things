#!/bin/bash
set -e

msg() { printf '\e[35;1m~~~\e[0m %s\n' "$1"; }
die() { msg "ERROR: $1"; exit 1; }

target=./output/alarm-aarch64-latest.tar.gz

[ $EUID -eq 0 ] || die "Root privileges required"

if [[ "$(uname -m)" != aarch64 ]]; then
	die TODO # host -> vm (where the script runs) -> chroot (target)
fi

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

install -d -m 755 "./tmp$$"
tmpdir=./tmp$$

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
pacman -Scc --noconfirm
rm -r /root/.gnupg
rm /var/log/pacman.log /etc/machine-id
'

cleanup_mounts

rm -f "$target"
msg "Creating archive"
bsdtar -cz --numeric-owner -f "$target" -C "$tmpdir" .

msg "Done"
ls -l "$target"
exit 0
