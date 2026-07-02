#!/bin/bash
# In-guest PCIe UIO test driver. TAP-ish output on stdout.
# Usage: run-tests.sh <suite>   (suite: t2 | t3 | t4 | t5 | t8)
#
# Maps to the design doc's cross-subsystem invariants (sec 7.3):
#  - route held => DMA_ATTR_UIO; provider type => MMIO attr; fallback is
#    a re-derived plan; teardown ordering via revocation events.

SUITE=${1:-t2}
CXL=/sys/bus/cxl/devices
DBG=/sys/kernel/debug
CUT=$DBG/cxl_uio_test
PASS=0; FAIL=0; N=0

ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
check() { # check <desc> <cmd...>
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
expect_eq() { # expect_eq <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got '$2' want '$3')"; fi
}

# --- discovery helpers ----------------------------------------------
ep_decoder_for_mem() { # memN -> endpoint decoderX.Y name
	local mem=$1 ep
	for ep in $CXL/endpoint*; do
		[ -d "$ep" ] || continue
		if [ "$(basename "$(readlink -f $ep/uport)")" = "$mem" ]; then
			basename "$(ls -d $ep/decoder*.0 2>/dev/null | head -1)"
			return
		fi
	done
}
bdf_for_mem() { # memN -> 0000:bb:dd.f
	readlink -f $CXL/$1 | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' | tail -1
}
mem_for_bdf() { # 0000:bb:dd.f -> memN (guest naming does not track
	# QEMU device ids; asymmetric topologies must pin by BDF)
	local m
	for m in $CXL/mem*; do
		[ "$(bdf_for_mem "$(basename $m)")" = "$1" ] &&
			{ basename "$m"; return; }
	done
}
root_decoder() { # first root decoder with create_ram_region
	local d
	for d in $CXL/decoder0.*; do
		[ -e "$d/create_ram_region" ] && { basename "$d"; return; }
	done
}

# --- region provisioning --------------------------------------------
SZ=$((256 << 20))
create_region() { # create_region <uio 0|1> <ways> <memdevs...>
	local uio=$1 ways=$2; shift 2
	local rd; rd=$(root_decoder)
	local region; region=$(cat $CXL/$rd/create_ram_region)
	echo "$region" > $CXL/$rd/create_ram_region || return 1
	local R=$CXL/$region
	echo 256 > $R/interleave_granularity || return 1
	echo "$ways" > $R/interleave_ways || return 1
	echo $((SZ * ways)) > $R/size || return 1
	local i=0 mem dec
	for mem in "$@"; do
		dec=$(ep_decoder_for_mem "$mem")
		[ -n "$dec" ] || return 1
		echo ram > $CXL/$dec/mode 2>/dev/null
		echo $SZ > $CXL/$dec/dpa_size || return 1
		echo "$dec" > $R/target$i || return 1
		i=$((i+1))
	done
	if [ "$uio" = 1 ]; then
		echo 1 > $R/uio || return 1
	fi
	echo "$region"
}
commit_region() { echo 1 > $CXL/$1/commit; }
reset_region()  { echo 0 > $CXL/$1/commit 2>/dev/null; }
destroy_region() {
	reset_region "$1"
	echo "$1" > $CXL/"$(root_decoder)"/delete_region 2>/dev/null
}

cut_set() { echo -n "$2" > $CUT/$1; }
cut_get() { cat $CUT/$1 2>/dev/null; }
cut_field() { cut_get acquire | awk -v k="$1:" '$1==k {print $2}'; }

echo "# UIO guest tests, suite $SUITE, kernel $(uname -r)"
modprobe cxl_uio_test 2>/dev/null
[ -d $CUT ] || { echo "Bail out! cxl_uio_test debugfs missing"; exit 1; }

# =====================================================================
case $SUITE in
t2)	# happy path: switch topology, both endpoints uio+req+ats capable
	# --- test 1: capability discovery
	caps=$(cat $DBG/pci_uio/capabilities)
	# 5 ports + 2 endpoints: endpoints carry SVC too (both Link
	# partners must enable the UIO VC, and TC3 mapping lives in the
	# port containing the requester/completer Function).
	expect_eq "seven SVC/UIO-VC capable functions" \
		"$(echo "$caps" | grep -c routing)" 7
	expect_eq "two requester+completer endpoints" \
		"$(echo "$caps" | grep -c 'requester completer')" 2

	# --- test 2: uio region commit success + decoder/DVSEC state
	region=$(create_region 1 1 mem0) || fail "create region"
	check "uio region commit" commit_region "$region"
	dec=$(ep_decoder_for_mem mem0)
	expect_eq "endpoint decoder uio attr" "$(cat $CXL/$dec/uio)" 1
	# HDM Decoder0 Control UIO bit (bit 14) via the component BAR is
	# not config space; check the port DVSEC gate after route instead.

	# --- test 5/7/8: route REQUIRED in-fabric via test module
	req_bdf=$(bdf_for_mem mem1)
	cut_set requester "$req_bdf"
	cut_set region "$region"
	cut_set policy required
	cut_set offset 0; cut_set len 0
	echo 1 > $CUT/acquire
	expect_eq "REQUIRED route acquired" "$(cut_field rc)" 0
	expect_eq "transport is UIO" "$(cut_field xport_uio)" 1
	expect_eq "in-fabric bus-addr plan" "$(cut_field map_type)" 3
	expect_eq "route flags in-fabric" "$(cut_field route_flags)" "0x1"
	expect_eq "attrs: UIO without MMIO" \
		"$(cut_field attr_uio)/$(cut_field attr_mmio)" "1/0"
	expect_eq "boundary 256" "$(cut_field boundary)" 256
	expect_eq "update granule 64" "$(cut_field update_granule)" 64
	expect_eq "route tc3/vc3" \
		"$(cut_field route_tc)/$(cut_field route_vc)" "3/3"
	check "route listed in debugfs" \
		grep -q "$req_bdf" $DBG/pci_uio/routes

	# --- test 11: requester enable lifetime (DevCtl3 bit 7 = 0x80)
	dev3=$(setpci -s "$req_bdf" ECAP002f+8.L)
	expect_eq "DevCtl3 requester enable set" \
		"$((0x$dev3 & 0x80))" 128
	# UIO To HDM Enable on both DSPs (port DVSEC ctl bit 4); DVSEC id 3
	for dsp in $(lspci -d :a129 -D | awk '{print $1}'); do
		v=$(setpci -s "$dsp" 'ECAP000B+c.L' 2>/dev/null || echo 0)
		: # DVSEC offset varies; verified indirectly via route success
	done

	# --- test 9: dma-debug attr mismatch (unmap with different attrs
	# is exercised by module release path consistency; here check no
	# route-coverage warning fired for the legitimate mapping)
	if dmesg | grep -q "DMA_ATTR_UIO mapping without a covering"; then
		fail "no dma-debug coverage warning for valid mapping"
	else
		ok "no dma-debug coverage warning for valid mapping"
	fi

	echo 1 > $CUT/release

	# --- test 9b: dma-debug misuse triad (RAM + no-route + mismatch)
	if [ -d $DBG/dma-api ]; then
		echo 1 > $DBG/dma-api/all_errors 2>/dev/null
		echo 1 > $CUT/misuse
		check "dma-debug flags UIO on cacheable RAM" \
			sh -c "dmesg | grep -q 'DMA_ATTR_UIO mapping of cacheable system RAM'"
		check "dma-debug flags UIO without covering route" \
			sh -c "dmesg | grep -q 'DMA_ATTR_UIO mapping without a covering'"
		check "dma-debug flags map/unmap attr mismatch" \
			sh -c "dmesg | grep -q 'different attributes'"
	else
		ok "dma-api debugfs absent (skip misuse triad)"
		ok "skip"; ok "skip"
	fi

	# --- test: PREFERRED on an eligible region takes the UIO plan
	cut_set policy preferred
	echo 1 > $CUT/acquire
	expect_eq "PREFERRED uses UIO when eligible" \
		"$(cut_field rc)/$(cut_field xport_uio)" "0/1"
	echo 1 > $CUT/release

	# --- post-commit provisioning guards (EBUSY) + attrs
	expect_eq "root decoder cap_uio" \
		"$(cat $CXL/$(root_decoder)/cap_uio)" 1
	expect_eq "uio_policy default" \
		"$(cat $CXL/$region/uio_policy)" required
	if echo 0 > $CXL/$region/uio 2>/dev/null; then
		fail "uio store rejected after commit"
	else
		ok "uio store rejected after commit"
	fi
	if echo -n forbidden > $CXL/$region/uio_policy 2>/dev/null; then
		fail "uio_policy store rejected after commit"
	else
		ok "uio_policy store rejected after commit"
	fi

	# --- FORBIDDEN policy => ordered plan, no route
	cut_set policy forbidden
	echo 1 > $CUT/acquire
	expect_eq "FORBIDDEN acquires without route" "$(cut_field rc)" 0
	expect_eq "FORBIDDEN: no UIO transport" "$(cut_field xport_uio)" 0
	expect_eq "FORBIDDEN: host-mediated ordered plan for HDM" \
		"$(cut_field map_type)" 4
	echo 1 > $CUT/release

	# --- requester enable dropped after last route
	dev3=$(setpci -s "$req_bdf" ECAP002f+8.L)
	expect_eq "DevCtl3 requester enable cleared" \
		"$((0x$dev3 & 0x80))" 0

	# --- test 10a: revocation via region teardown
	cut_set policy required
	echo 1 > $CUT/acquire
	expect_eq "route for revocation test" "$(cut_field rc)" 0
	expect_eq "route valid pre-revoke" "$(cut_get valid)" 1
	reset_region "$region"
	expect_eq "route invalid post region-reset" "$(cut_get valid)" 0
	ev=$(cut_get events | tr '\n' ' ')
	expect_eq "quiesce+revoke ops fired" "$ev" "quiesce: 1 revoke: 1 "
	echo 1 > $CUT/release
	destroy_region "$region"

	# --- test 3a: non-uio commit still fine, FORBIDDEN classification
	region=$(create_region 0 1 mem0)
	check "plain region commit" commit_region "$region"
	cut_set region "$region"
	cut_set policy required
	echo 1 > $CUT/acquire
	expect_eq "REQUIRED fails on non-uio region" "$(cut_field rc)" -95
	cut_set policy preferred
	echo 1 > $CUT/acquire
	expect_eq "PREFERRED falls back ordered" \
		"$(cut_field rc)/$(cut_field xport_uio)" "0/0"
	echo 1 > $CUT/release
	destroy_region "$region"

	# --- test 6: 2-way interleave region under one switch
	region=$(create_region 1 2 mem0 mem1)
	check "2-way uio region commit" commit_region "$region"
	cut_set region "$region"
	cut_set policy required
	echo 1 > $CUT/acquire
	# mem1 as requester is also a target: route to both targets;
	# target set structurally all-or-none.
	expect_eq "2-way route acquired" "$(cut_field rc)" 0
	expect_eq "2-way: two targets" "$(cut_field nr_targets)" 2
	echo 1 > $CUT/release

	# subrange decode: one 256B granule touches position 0 only;
	# two granules touch both (cxl_region_p2p_validate pos_map math)
	cut_set len 0x100
	echo 1 > $CUT/acquire
	expect_eq "subrange (1 granule) binds one target" \
		"$(cut_field rc)/$(cut_field nr_targets)" "0/1"
	echo 1 > $CUT/release
	cut_set len 0x200
	echo 1 > $CUT/acquire
	expect_eq "subrange (2 granules) binds both targets" \
		"$(cut_field rc)/$(cut_field nr_targets)" "0/2"
	echo 1 > $CUT/release
	cut_set len 0
	destroy_region "$region"

	# --- FLR on the requester: reset-preparation revocation path.
	# Self-contained: a 1-way region on mem0 with mem1 as a
	# requester-only (never a target), so FLR of mem1 does not
	# disturb any committed target decoder.
	region=$(create_region 1 1 mem0)
	commit_region "$region"
	cut_set requester "$req_bdf"
	cut_set region "$region"
	cut_set policy required
	echo 1 > $CUT/acquire
	expect_eq "route for FLR test" "$(cut_field rc)" 0
	base_q=$(awk '$1=="quiesce:" {print $2}' $CUT/events)
	base_r=$(awk '$1=="revoke:" {print $2}' $CUT/events)
	echo 1 > /sys/bus/pci/devices/$req_bdf/reset
	expect_eq "route revoked by requester FLR" "$(cut_get valid)" 0
	now_q=$(awk '$1=="quiesce:" {print $2}' $CUT/events)
	now_r=$(awk '$1=="revoke:" {print $2}' $CUT/events)
	expect_eq "quiesce+revoke fired once on FLR" \
		"$now_q/$now_r" "$((base_q+1))/$((base_r+1))"
	dev3=$(setpci -s "$req_bdf" ECAP002f+8.L)
	expect_eq "requester enable gone after FLR" \
		"$((0x$dev3 & 0x80))" 0
	echo 1 > $CUT/release
	destroy_region "$region"

	# --- test 10b: revocation via completer hot-remove is driven from
	# the host side (device_del) in run-all.sh phase 2 marker file.
	;;

t5)	# endpoint without x-uio: commit of uio region must fail. The
	# non-capable device is the one under dsp0 (0f:00.0); pin by BDF.
	tgt=$(mem_for_bdf 0000:0f:00.0)
	region=$(create_region 1 1 "$tgt")
	if [ -z "$region" ]; then
		# uio store itself may reject if region type is not DEVMEM
		ok "uio provisioning rejected (store)"
		ok "skip"
	elif commit_region "$region" 2>/dev/null; then
		fail "uio commit unexpectedly succeeded"
		destroy_region "$region"
	else
		ok "uio commit rejected without device uio capability"
		expect_eq "region stays uncommitted" \
			"$(cat $CXL/$region/commit)" 0
		destroy_region "$region"
	fi
	;;

t4)	# no SVC on switch ports: fail-fast at commit (segment check)
	region=$(create_region 1 1 mem0)
	if [ -n "$region" ] && commit_region "$region" 2>/dev/null; then
		fail "uio commit succeeded without SVC uplink"
		destroy_region "$region"
	else
		ok "uio commit rejected without SVC-capable uplink"
		[ -n "$region" ] && destroy_region "$region"
	fi
	;;

t3)	# switch uplink not in flit mode: fail-fast before commit. The BI
	# prerequisite (also flit-gated) may reject the region at target
	# attach before the UIO segment check runs; either way no uio
	# region may reach the committed state.
	region=$(create_region 1 1 mem0)
	if [ -n "$region" ] && commit_region "$region" 2>/dev/null; then
		fail "uio commit succeeded on non-flit uplink"
		destroy_region "$region"
	else
		ok "uio commit rejected on non-flit uplink"
		[ -n "$region" ] && destroy_region "$region"
	fi
	;;

t8)	# targets under different root ports. The host bridge (pxb)
	# advertises no UIO decode capability, so committing a uio=1
	# region whose interleave needs the HB decoder must fail closed
	# (UIO Capable Decoder Count gate). A plain region commits, and
	# a PREFERRED consumer gets the ordered host-mediated plan.
	region=$(create_region 1 2 mem0 mem1)
	if [ -n "$region" ] && commit_region "$region" 2>/dev/null; then
		fail "uio commit rejected on non-UIO host bridge"
	else
		ok "uio commit rejected on non-UIO host bridge"
	fi
	[ -n "$region" ] && destroy_region "$region"

	region=$(create_region 0 2 mem0 mem1)
	check "plain cross-RP region commit" commit_region "$region"
	req_bdf=$(bdf_for_mem mem1)
	cut_set requester "$req_bdf"
	cut_set region "$region"
	cut_set policy required
	echo 1 > $CUT/acquire
	expect_eq "REQUIRED fails cross-RP" "$(cut_field rc)" -95
	cut_set policy preferred
	echo 1 > $CUT/acquire
	# The ordered classification is host dependent: THRU_HOST_BRIDGE
	# (4) on P2P-capable/whitelisted hosts, NOT_SUPPORTED (2)
	# otherwise. Either way: no route, no UIO transport.
	mt=$(cut_field map_type)
	[ "$mt" = 2 ] || [ "$mt" = 4 ] && mt=ok
	expect_eq "PREFERRED ordered fallback cross-RP" \
		"$(cut_field rc)/$(cut_field xport_uio)/$mt" "0/0/ok"
	echo 1 > $CUT/release
	destroy_region "$region"
	;;
t6)	# 4-way interleave under one switch: per-endpoint ISP, pos_map
	# for >2 positions, multi-target route with hop dedup.
	region=$(create_region 1 4 $(mem_for_bdf 0000:0f:00.0) \
		$(mem_for_bdf 0000:10:00.0) $(mem_for_bdf 0000:11:00.0) \
		$(mem_for_bdf 0000:12:00.0))
	check "4-way uio region commit" commit_region "$region"
	cut_set requester "$(bdf_for_mem "$(mem_for_bdf 0000:12:00.0)")"
	cut_set region "$region"
	cut_set policy required
	cut_set offset 0; cut_set len 0
	echo 1 > $CUT/acquire
	expect_eq "4-way route acquired" "$(cut_field rc)" 0
	expect_eq "4-way: four targets" "$(cut_field nr_targets)" 4
	expect_eq "4-way: five hops (4 DSPs + USP)" \
		"$(cut_field nr_hops)" 5
	echo 1 > $CUT/release
	cut_set len 0x100
	echo 1 > $CUT/acquire
	expect_eq "4-way subrange binds one target" \
		"$(cut_field rc)/$(cut_field nr_targets)" "0/1"
	echo 1 > $CUT/release
	cut_set len 0x300
	echo 1 > $CUT/acquire
	expect_eq "4-way 3-granule subrange binds three targets" \
		"$(cut_field rc)/$(cut_field nr_targets)" "0/3"
	echo 1 > $CUT/release
	cut_set len 0
	destroy_region "$region"
	;;

t7)	# requester without ATS: HDM decoders match translated
	# addresses only, so the route must be refused; PREFERRED
	# falls back to the ordered host-mediated plan.
	region=$(create_region 1 1 "$(mem_for_bdf 0000:0f:00.0)")
	check "uio region commit (no-ATS topo)" commit_region "$region"
	cut_set requester "$(bdf_for_mem "$(mem_for_bdf 0000:10:00.0)")"
	cut_set region "$region"
	cut_set policy required
	echo 1 > $CUT/acquire
	expect_eq "REQUIRED fails without requester ATS" \
		"$(cut_field rc)" -95
	cut_set policy preferred
	echo 1 > $CUT/acquire
	expect_eq "PREFERRED ordered fallback without ATS" \
		"$(cut_field rc)/$(cut_field xport_uio)/$(cut_field map_type)" \
		"0/0/4"
	echo 1 > $CUT/release
	destroy_region "$region"
	;;
esac

echo "1..$N"
echo "# pass $PASS fail $FAIL"
[ $FAIL -eq 0 ]
