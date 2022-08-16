
msg() { printf '\e[35;1m~~~\e[0m %s\n' "$1"; }
die() { msg "ERROR: $1"; return 1; }

check_tools() {
	for exe in "$@"; do
		command -v "$exe" >/dev/null || die "Missing $exe"
	done
}

cleanup_hooks=()
add_cleanup_hook() {
	cleanup_hooks+=("$@")
}
_run_cleanup_hooks() {
	set +e
	for fun in "${cleanup_hooks[@]}"; do
		eval "$fun"
	done
	cleanup_hooks=()
}
setup_cleanup_hook() {
	 [ -n "$(trap -p EXIT)" ] && die "BUG: hook already exists"
	 trap '_run_cleanup_hooks' EXIT
}

# exit 0 -> done
# exit 1 -> error occurred
# exit 2 -> execution can continue on host
# exit 3 -> executing inside vm
_vm_expect_arch=aarch64
_vm_cleanup() {
	if [ -n "$vmntdir" ]; then
		umount "$vmntdir"
		rmdir "$vmntdir"
		vmntdir=
	fi
	[ -n "$1" ] && return
	[ -n "$vtmpfile" ] && { rm "$vtmpfile"; vtmpfile=; }
}
relaunch_in_vm() {
	if [ -n "$INVM" ]; then
		# inside vm part
		systemd-detect-virt -v || die "not meant to be"
		[[ "$(uname -m)" == ${_vm_expect_arch} ]] || die "not meant to be"

		# apply some options to improve performance (placebo?)
		echo 0 >/proc/sys/kernel/randomize_va_space 
		mount '' / -o remount,commit=3600
		dd if=/dev/hwrng of=/dev/random count=16

		return 3
	fi

	# host part
	if [[ "$(uname -m)" == ${_vm_expect_arch} ]]; then
		return 2
	fi
	local rootfs="$1"
	[ -s "$1" ] || die "Need a previous rootfs build to bootstrap"
	check_tools mkfs.ext4 bsdtar qemu-system-aarch64

	msg "Preparing VM"

	vmntdir=
	vtmpfile=
	add_cleanup_hook _vm_cleanup

	truncate -s 6G "./vm$$.bin"
	vtmpfile=./vm$$.bin

	mkfs.ext4 -q "$vtmpfile"

	mkdir "./mnt$$"
	vmntdir=./mnt$$

	mount "$vtmpfile" "$vmntdir" -o loop,noatime

	bsdtar -xpf "$rootfs" -C "$vmntdir"
	# get rid of interference
	rm "$vmntdir/usr/lib/systemd/system/multi-user.target.wants/getty.target" \
		"$vmntdir/usr/lib/systemd/system/sysinit.target.wants/systemd-firstboot.service"
	# configure the 9p mount
	printf '%s\t' >>"$vmntdir/etc/fstab" \
		shared /mnt 9p trans=virtio,version=9p2000.L,msize=104857600
	printf '\n' >>"$vmntdir/etc/fstab"
	# add a service that runs us on startup
	local script="$(basename "$0")"
	printf '%s\n' >"$vmntdir/etc/systemd/system/script.service" \
		[Unit] RequiresMountsFor=/mnt {Failure,Success}Action=poweroff-force \
		[Service] Type=oneshot Environment=INVM=1 Standard{Output,Error}=tty \
		WorkingDirectory=/mnt ExecStart=/mnt/"$script"
	ln -s "etc/systemd/system/script.service" "$vmntdir/etc/systemd/system/multi-user.target.wants/"

	_vm_cleanup mount-only

	msg "Re-launching in VM"
	args=(
		-M virt -cpu cortex-a53 -m 2048 -smp 2
		-kernel bins/Image.gz
		-nic user,model=virtio
		-drive file="$vtmpfile",if=virtio,format=raw,cache=unsafe
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
	return 0
}

run_in_target() {
	local tdir="$1"
	shift
	PATH=/usr/bin unshare --fork --pid -R "$tdir" -- "$@" </dev/null
}
