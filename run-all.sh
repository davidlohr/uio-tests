#!/bin/bash
# Host-side UIO test orchestrator: boots each topology, pushes the
# guest driver, runs the suite, collects TAP + dmesg. Exit 0 iff all
# suites pass.
UIO_TESTS_DIR="$(dirname "$(readlink -f "$0")")"
source "$UIO_TESTS_DIR/topo-lib.sh"
OUT=${OUT:-$RUNDIR/results}
mkdir -p "$OUT"
TOTAL_FAIL=0

run_suite() { # run_suite <topo-script> <suite>
	local topo=$1 suite=$2
	echo "=== $suite ($(basename "$topo")) ==="
	"$topo" || { echo "launch failed"; TOTAL_FAIL=$((TOTAL_FAIL+1)); return; }
	if ! wait_for_guest 180; then
		echo "guest boot failed"; TOTAL_FAIL=$((TOTAL_FAIL+1)); return
	fi
	guest_scp "$UIO_TESTS_DIR/guest/run-tests.sh" root@localhost:/tmp/ \
		>/dev/null
	guest_ssh "dmesg -C; bash /tmp/run-tests.sh $suite" \
		| tee "$OUT/$suite.tap"
	local rc=${PIPESTATUS[0]}
	guest_ssh "dmesg" > "$OUT/$suite.dmesg" 2>/dev/null

	if [ "$suite" = t2 ] && [ "$rc" -eq 0 ]; then
		echo "--- t2 phase 2: completer hot-remove revocation ---"
		guest_scp "$UIO_TESTS_DIR/guest/hotremove-prep.sh" \
			  "$UIO_TESTS_DIR/guest/hotremove-check.sh" \
			  root@localhost:/tmp/ >/dev/null
		guest_ssh "bash /tmp/hotremove-prep.sh" \
			| tee "$OUT/t2-hotremove.tap"
		local rc2=${PIPESTATUS[0]}
		if [ "$rc2" -eq 0 ]; then
			qmp_cmd '{"execute":"device_del","arguments":{"id":"mem0"}}' \
				>/dev/null
			for i in $(seq 1 45); do
				guest_ssh \
				  "[ ! -e /sys/bus/pci/devices/0000:0f:00.0 ]" \
					2>/dev/null && break
				sleep 2
			done
			guest_ssh "bash /tmp/hotremove-check.sh" \
				| tee -a "$OUT/t2-hotremove.tap"
			rc2=${PIPESTATUS[0]}
			guest_ssh dmesg > "$OUT/t2-hotremove.dmesg" 2>/dev/null
		fi
		[ "$rc2" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
	fi

	[ "$rc" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
	stop_qemu
}

# suite -> topology script
declare -A TOPO=(
	[t1]=t1-direct.sh
	[t2]=t2-switch.sh
	[t3]=t3-noflit.sh
	[t4]=t4-nosvc.sh
	[t5]=t5-nouio-dev.sh
	[t6]=t6-x4.sh
	[t7]=t7-noats.sh
	[t8]=t8-crossrp.sh
)
# Default order runs the happy path first, then the fail-closed gates.
ORDER="t1 t2 t5 t4 t3 t6 t7 t8"

# No args: run everything. Otherwise run only the named suites, e.g.
#   ./run-all.sh t2          # one suite (incl. its phase-2 hot-remove)
#   ./run-all.sh t4 t8       # a subset
SUITES="${*:-$ORDER}"
for s in $SUITES; do
	topo=${TOPO[$s]}
	if [ -z "$topo" ]; then
		echo "unknown suite '$s' (choices: $ORDER)" >&2
		exit 2
	fi
	run_suite "$UIO_TESTS_DIR/topos/$topo" "$s"
done

echo "==================================================="
echo "suites failed: $TOTAL_FAIL (results in $OUT)"
exit $((TOTAL_FAIL != 0))
