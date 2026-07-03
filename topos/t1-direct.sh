#!/bin/bash
# t1-direct.sh - the minimal topology: one root port, one cxl-type3
# directly under it, no switch. Establishes that a UIO Direct P2P
# target provisions and programs correctly when the root port is the
# sole upstream hop (every other happy-path suite puts the target under
# a switch; t8's direct commit deliberately fails on a non-UIO host
# bridge). The endpoint's uplink segment check runs against the RP.
UIO_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$UIO_TESTS_DIR/topo-lib.sh"

T3_EXTRA=${T3_EXTRA:-x-uio-req=on,x-ats=on}
PORT_SVC=${PORT_SVC:-x-uio-svc3=on,x-uio-svc4=on}
PORT_FLIT=${PORT_FLIT:-x-256b-flit=on}

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,$PORT_SVC,$PORT_FLIT \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-uio=on${T3_EXTRA:+,$T3_EXTRA} \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
