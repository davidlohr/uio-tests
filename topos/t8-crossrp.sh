#!/bin/bash
# t8-crossrp.sh - two type3 devices under different root ports.
# In-fabric UIO is impossible (cross-RP is host-mediated); REQUIRED
# routes must fail, PREFERRED must fall back to the ordered plan.
UIO_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$UIO_TESTS_DIR/topo-lib.sh"

T3_EXTRA=${T3_EXTRA:-x-uio-req=on,x-ats=on}
PORT_SVC=${PORT_SVC:-x-uio-svc3=on,x-uio-svc4=on}
PORT_FLIT=${PORT_FLIT:-x-256b-flit=on}

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,$PORT_SVC,$PORT_FLIT \
	-device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=1,slot=3,$PORT_SVC,$PORT_FLIT \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-uio=on${T3_EXTRA:+,$T3_EXTRA} \
	-device cxl-type3,bus=rp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on,x-uio=on${T3_EXTRA:+,$T3_EXTRA} \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
