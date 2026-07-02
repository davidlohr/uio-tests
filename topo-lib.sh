#!/bin/bash
# topo-lib.sh - QEMU launch library for PCIe UIO testing
# Modeled on ~/cxl.sh / ~/cxl-switches.sh
#
# Usage: source this file, then call launch_qemu with topology device args.
#        Guest reachable via: guest_ssh <cmd>

QEMU=${QEMU:-$HOME/code/qemu-upstream/build/qemu-system-x86_64}
KERNEL=${KERNEL:-$HOME/code/linux-torvalds/arch/x86/boot/bzImage}
IMG=${IMG:-$HOME/img/cxl-test.qcow2}
SSHPORT=${SSHPORT:-27110}
RUNDIR=${RUNDIR:-/tmp/uio-tests}
QMPSOCK=$RUNDIR/qmp-sock
CONSOLE_LOG=$RUNDIR/console.log
PIDFILE=$RUNDIR/qemu.pid

mkdir -p "$RUNDIR"

# NB: no net.ifnames=0 - the guest image's netplan matches enp0s2, so the
# e1000 must stay at 00:02.0 (first -device) with predictable naming.
BOOTARGS="root=/dev/sda1 console=ttyS0 serial selinux=0 audit=0 \
ignore_loglevel rw memhp_default_state=online \
cxl_acpi.dyndbg=+fplm cxl_pci.dyndbg=+fplm cxl_core.dyndbg=+fplm \
cxl_mem.dyndbg=+fplm cxl_port.dyndbg=+fplm cxl_region.dyndbg=+fplm \
dyndbg=\"file drivers/pci/uio.c +p; file drivers/pci/p2pdma.c +p\""

# launch_qemu <device args...>
# Boots in background; console to $CONSOLE_LOG, qmp on $QMPSOCK.
launch_qemu() {
	stop_qemu
	rm -f "$CONSOLE_LOG"
	"$QEMU" -smp 4 -m 4G -cpu host \
		-drive file="$IMG" \
		-kernel "$KERNEL" \
		-append "$BOOTARGS" \
		-machine q35,accel=kvm,cxl=on \
		-device e1000,netdev=net0 \
		-netdev user,id=net0,hostfwd=tcp:127.0.0.1:$SSHPORT-:22 \
		"$@" \
		-qmp unix:$QMPSOCK,server,wait=off \
		-display none \
		-enable-kvm \
		-serial file:"$CONSOLE_LOG" \
		-pidfile "$PIDFILE" \
		-daemonize
}

stop_qemu() {
	local pid i
	if [ -f "$PIDFILE" ]; then
		pid=$(cat "$PIDFILE")
		kill "$pid" 2>/dev/null
		for i in $(seq 1 20); do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.5
		done
		kill -9 "$pid" 2>/dev/null
		rm -f "$PIDFILE"
	fi
	pkill -f "qemu-system-x86_64.*hostfwd=tcp:127.0.0.1:$SSHPORT" 2>/dev/null
	for i in $(seq 1 10); do
		ss -tln 2>/dev/null | grep -q ":$SSHPORT " || break
		sleep 0.5
	done
	true
}

guest_ssh() {
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    -o ConnectTimeout=5 -o LogLevel=ERROR -p "$SSHPORT" \
	    root@localhost "$@"
}

guest_scp() {
	scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    -o LogLevel=ERROR -P "$SSHPORT" "$@"
}

# wait_for_guest [timeout_sec]
# Guards against talking to a stale guest from a previous topology:
# the boot_id must differ from the one recorded by the last launch.
wait_for_guest() {
	local timeout=${1:-120} i=0 bid last=""
	[ -f "$RUNDIR/boot_id" ] && last=$(cat "$RUNDIR/boot_id")
	while [ $i -lt "$timeout" ]; do
		bid=$(guest_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null)
		if [ -n "$bid" ] && [ "$bid" != "$last" ]; then
			echo "$bid" > "$RUNDIR/boot_id"
			return 0
		fi
		sleep 2
		i=$((i + 2))
	done
	echo "guest failed to come up (or stale boot); console tail:" >&2
	tail -20 "$CONSOLE_LOG" >&2
	return 1
}

# qmp_cmd '<json>'  (simple one-shot qmp; requires python3)
qmp_cmd() {
	python3 - "$QMPSOCK" "$1" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
f = s.makefile("rw")
f.readline()                       # greeting
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
f.readline()
f.write(sys.argv[2] + "\n"); f.flush()
print(f.readline().strip())
EOF
}
