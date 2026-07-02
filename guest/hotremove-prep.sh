#!/bin/bash
# Provision a uio region on mem0 and acquire a route from mem1, in
# preparation for host-driven device_del of mem0.
CXL=/sys/bus/cxl/devices
CUT=/sys/kernel/debug/cxl_uio_test

ep_decoder_for_mem() {
	local mem=$1 ep
	for ep in $CXL/endpoint*; do
		[ "$(basename "$(readlink -f $ep/uport)")" = "$mem" ] &&
			basename "$(ls -d $ep/decoder*.0 | head -1)" && return
	done
}
bdf_for_mem() {
	readlink -f $CXL/$1 | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' | tail -1
}

mem_for_bdf() {
	local m
	for m in $CXL/mem*; do
		[ "$(bdf_for_mem "$(basename $m)")" = "$1" ] &&
			{ basename "$m"; return; }
	done
}

modprobe cxl_uio_test 2>/dev/null
TGT_MEM=$(mem_for_bdf 0000:0f:00.0)	# device under dsp0 (QEMU id mem0)
REQ_MEM=$(mem_for_bdf 0000:10:00.0)	# device under dsp1 (QEMU id mem1)
cat /sys/kernel/debug/cxl_uio_test/events > /tmp/uio-ev-base
rd=$(basename "$(ls -d $CXL/decoder0.* | head -1)")
region=$(cat $CXL/$rd/create_ram_region)
echo "$region" > $CXL/$rd/create_ram_region
R=$CXL/$region
dec=$(ep_decoder_for_mem "$TGT_MEM")
echo 256 > $R/interleave_granularity
echo 1 > $R/interleave_ways
echo $((256 << 20)) > $R/size
echo ram > $CXL/$dec/mode 2>/dev/null
echo $((256 << 20)) > $CXL/$dec/dpa_size
echo "$dec" > $R/target0
echo 1 > $R/uio
echo 1 > $R/commit || { echo "not ok - commit failed"; exit 1; }

echo -n "$(bdf_for_mem "$REQ_MEM")" > $CUT/requester
echo -n "$region" > $CUT/region
echo -n required > $CUT/policy
echo 1 > $CUT/acquire
rc=$(awk '$1=="rc:" {print $2}' $CUT/acquire)
[ "$rc" = 0 ] || { echo "not ok - acquire rc=$rc"; exit 1; }
[ "$(cat $CUT/valid)" = 1 ] || { echo "not ok - route not valid"; exit 1; }
echo "ok - route armed for hot-remove"
