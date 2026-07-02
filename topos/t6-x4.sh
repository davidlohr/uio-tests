#!/bin/bash
# t6-x4.sh - four endpoints under one switch, 4-way interleave
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, svc3+svc4, flit)
#       cxl-upstream (us0, svc3+svc4, flit, uio)
#         cxl-downstream (dsp0, svc3+svc4, flit)
#           cxl-type3 (mem0: uio completer, hdm-db, flit)
#         cxl-downstream (dsp1, svc3+svc4, flit)
#           cxl-type3 (mem1: uio completer + requester + ats, hdm-db, flit)
#   plain pcie-root-port (prp0, svc3) with nothing under it:
#       regression check for SVC-vs-AER capability placement.
#
# mem1 doubles as the UIO requester for route tests targeting mem0's
# region (and vice versa).
UIO_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$UIO_TESTS_DIR/topo-lib.sh"

T3_EXTRA=${T3_EXTRA:-x-uio-req=on,x-ats=on}   # requester + ATS roles
PORT_SVC=${PORT_SVC:-x-uio-svc3=on,x-uio-svc4=on}
PORT_FLIT=${PORT_FLIT:-x-256b-flit=on}

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-object memory-backend-ram,id=m2,size=1G \
	-object memory-backend-ram,id=m3,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device pcie-root-port,id=prp0,bus=pcie.0,chassis=9,slot=9,x-uio-svc3=on \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,$PORT_SVC,$PORT_FLIT \
	-device cxl-upstream,bus=rp0,id=us0,$PORT_SVC,$PORT_FLIT \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,$PORT_SVC,$PORT_FLIT \
	-device cxl-downstream,port=1,bus=us0,id=dsp1,chassis=0,slot=5,$PORT_SVC,$PORT_FLIT \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-uio=on${T3_EXTRA:+,$T3_EXTRA} \
	-device cxl-downstream,port=2,bus=us0,id=dsp2,chassis=0,slot=6,$PORT_SVC,$PORT_FLIT \
	-device cxl-downstream,port=3,bus=us0,id=dsp3,chassis=0,slot=7,$PORT_SVC,$PORT_FLIT \
	-device cxl-type3,bus=dsp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on,x-uio=on${T3_EXTRA:+,$T3_EXTRA} \
	-device cxl-type3,bus=dsp2,volatile-memdev=m2,id=mem2,x-256b-flit=on,hdm-db=on,x-uio=on${T3_EXTRA:+,$T3_EXTRA} \
	-device cxl-type3,bus=dsp3,volatile-memdev=m3,id=mem3,x-256b-flit=on,hdm-db=on,x-uio=on${T3_EXTRA:+,$T3_EXTRA} \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
