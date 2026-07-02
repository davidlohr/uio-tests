#!/bin/bash
# After host-side device_del mem0: the route must be revoked with the
# holder's quiesce+revoke ops invoked, and the requester emission
# permission (DevCtl3 bit 7) dropped.
CUT=/sys/kernel/debug/cxl_uio_test
fail=0

valid=$(cat $CUT/valid)
if [ "$valid" = 0 ]; then
	echo "ok - route revoked by completer hot-remove"
else
	echo "not ok - route still valid after hot-remove"; fail=1
fi

base_q=$(awk '$1=="quiesce:" {print $2}' /tmp/uio-ev-base 2>/dev/null)
base_r=$(awk '$1=="revoke:" {print $2}' /tmp/uio-ev-base 2>/dev/null)
now_q=$(awk '$1=="quiesce:" {print $2}' $CUT/events)
now_r=$(awk '$1=="revoke:" {print $2}' $CUT/events)
if [ "$now_q" = "$((base_q + 1))" ] && [ "$now_r" = "$((base_r + 1))" ]; then
	echo "ok - quiesce+revoke ops fired exactly once"
else
	echo "not ok - events base $base_q/$base_r now $now_q/$now_r"; fail=1
fi

req=$(tr -d '\0' < $CUT/requester)
dev3=$(setpci -s "$req" ECAP002f+8.L 2>/dev/null || echo 0)
if [ $((0x$dev3 & 0x80)) = 0 ]; then
	echo "ok - requester enable dropped on revocation"
else
	echo "not ok - DevCtl3 requester enable still set"; fail=1
fi

echo 1 > $CUT/release
exit $fail
