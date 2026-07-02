# PCIe Unordered IO (UIO) test suite

QEMU-driven validation of the Linux PCIe UIO transport stack: the
`pcie-uio-rfc` kernel series (PCI/UIO core, `DMA_ATTR_UIO`, P2PDMA typed
providers, CXL UIO provisioning) against the `uio-work-rfc` QEMU branch
(SVC/flit/Device-3 enumeration + CXL HDM decoder UIO emulation).

Scope: QEMU emulates UIO **enumeration only** — there is no UIO data
path. The suite exercises capability discovery, region provisioning
gates, route validation/commit (including live SVC VC programming and
its config-space side effects), DMA attribute derivation, policy
fallback, and revocation. Wire behavior (completion accounting, 64B
update granularity) is not testable here.

## Prerequisites

Three trees, all local:

| tree | branch | notes |
|---|---|---|
| `~/code/linux-torvalds` | `pcie-uio-rfc` | build `bzImage` with the config below |
| `~/code/qemu-upstream` | `uio-work-rfc` | `cd build && ninja qemu-system-x86_64` |
| `~/img/cxl-test.qcow2` | — | Debian 12 guest, see image notes |

Kernel config on top of a CXL-enabled base (`~/code/cxl-fresh/.config`
is a proven-bootable starting point):

    CONFIG_CXL_BUS=y CONFIG_CXL_MEM=y CONFIG_CXL_REGION=y
    CONFIG_PCI_P2PDMA=y
    CONFIG_PCI_UIO=y
    CONFIG_CXL_UIO_TEST=y        # the in-kernel test consumer
    CONFIG_DMA_API_DEBUG=y       # optional: coverage/mismatch checks
    CONFIG_HOTPLUG_PCI_PCIE=y    # REQUIRED for the hot-remove phase;
                                 # without pciehp, device_del is
                                 # silently ignored by the guest

Guest image requirements (already true of `~/img/cxl-test.qcow2`):

- `openssh-server` installed, root login by key, host pubkey in
  `/root/.ssh/authorized_keys` (was injected with
  `virt-customize --install openssh-server --ssh-inject root:file:...`).
- Networking via netplan matching **enp0s2**. Consequences the harness
  already encodes: the e1000 NIC must be the first `-device` (lands at
  00:02.0), never pass `net.ifnames=0`, never use `restrict=on` on the
  netdev (it blocks slirp DHCP).
- `setpci`/`lspci` present (pciutils).

## Quick start

    ./run-all.sh

Boots five topologies sequentially (one QEMU at a time, ssh forwarded
on 127.0.0.1:27110), pushes the guest driver, runs each suite, and
collects TAP + dmesg into `/tmp/uio-tests/results/`. Exit 0 iff every
suite passes. A fully green run ends with:

    === t2 (t2-switch.sh) ===       # pass 29 fail 0
    --- t2 phase 2: completer hot-remove revocation ---
    ok - route armed for hot-remove
    ok - route revoked by completer hot-remove
    ok - quiesce+revoke ops fired exactly once
    ok - requester enable dropped on revocation
    === t5 ... t4 ... t3 ... t8 ===  all pass
    suites failed: 0

Wall clock is dominated by five guest boots (~1 min each).

## Layout

    topo-lib.sh          QEMU launcher library: boot args, ssh/scp/qmp
                         helpers, boot-id staleness guard, kill-wait
    topos/t*.sh          one topology per suite (see table)
    guest/run-tests.sh   in-guest TAP driver; takes the suite name
    guest/hotremove-prep.sh / hotremove-check.sh
                         guest halves of the t2 hot-remove phase
                         (the host side lives in run-all.sh: QMP
                         device_del + removal polling)
    run-all.sh           orchestrator

## The suites

All topologies share the base: q35 + `cxl=on`, one pxb-cxl host bridge,
a 4G CFMWS window with `back-invalidate=on`, two cxl-type3 devices with
`hdm-db=on`. Port knobs: `x-uio-svc3/x-uio-svc4` (SVC capability),
`x-256b-flit`. Device knobs: `x-uio` (completer), `x-uio-req`
(requester), `x-ats`.

### t2 — switch happy path (29 checks + 4 hot-remove)

    rp0 -- us0 -- dsp0 -- mem0 (region target)
                \- dsp1 -- mem1 (requester)     all knobs on

What it proves, in order:

1. Discovery: `/sys/kernel/debug/pci_uio/capabilities` shows exactly
   7 SVC-capable functions — 5 ports (incl. a plain pcie-root-port
   with SVC, the regression check for the SVC-vs-AER placement fix)
   plus the 2 endpoints, which carry SVC themselves (VC enablement
   is per-link, both partners; TC3 mapping lives in the port
   containing the requester/completer function) — and 2
   `requester completer` endpoints (Device 3 capability emulation).
2. `uio=1` region commit succeeds; endpoint decoder `uio` attr reads 1.
3. REQUIRED route via the `cxl_uio_test` consumer: `rc: 0`,
   `map_type: 3` (in-fabric BUS_ADDR), `xport_uio: 1`,
   `attrs: 0x4000` (DMA_ATTR_UIO without DMA_ATTR_MMIO — HDM is not
   a BAR), `route_tc/vc: 3/3`, `boundary: 256`, `update_granule: 64`,
   3 hops, route listed in `/sys/kernel/debug/pci_uio/routes`.
4. Requester-enable lifetime in config space: DevCtl3 bit 7
   (`setpci -s <bdf> ECAP002f+8.L`, mask 0x80) is set only while a
   route exists.
5. No dma-debug "without a covering UIO route" warning for the
   legitimate mapping (CONFIG_DMA_API_DEBUG path).
6. Policy semantics: FORBIDDEN acquires with no route and yields the
   host-mediated ordered plan (`map_type: 4`); REQUIRED on a non-uio
   region fails `-95`; PREFERRED on it falls back ordered.
7. Revocation via region teardown (`echo 0 > commit`): consumer's
   `valid` flips 1→0, quiesce/revoke ops fire exactly once each.
8. 2-way interleaved uio region under the switch: route binds to
   **both** targets (`nr_targets: 2`) — all-or-none structurally.
9. Phase 2 (host-driven): `device_del mem0` → orderly pciehp removal
   → route revoked, ops fired once (delta-counted against a baseline),
   requester DevCtl3 enable cleared.

### t5 — device without UIO capability (2 checks)

Same topology, but the device under dsp0 lacks `x-uio` (keeps
`hdm-db`). `uio=1` region commit must fail `EOPNOTSUPP` at the
commit gate ("not a UIO Direct P2P target" with cxl dyndbg).
The non-capable device is selected **by BDF** (0000:0f:00.0), see
gotchas.

### t4 — port without SVC (1 check)

Switch USP lacks `x-uio-svc3`. Commit must fail via the
endpoint-uplink segment check (`cxl_uio_segment_check()` names the
hop with dyndbg).

### t3 — non-flit uplink (1 check)

`x-256b-flit=off` on the **switch USP** (see gotchas for why not the
DSP). No uio region may reach committed state; in practice the BI
prerequisite (also flit-gated) rejects the region at target attach
before the UIO segment check runs — both gates lead to the same
fail-closed outcome and the test accepts either shape.

### t8 — cross root port (4 checks)

Two type3 devices directly under two cxl-rp's, no switch. A 2-way
`uio=1` region commit must fail `ENXIO`: the pxb host bridge
advertises no UIO decode capability, so the HB decoder trips the UIO
Capable Decoder Count gate. A plain (uio=0) 2-way region commits;
REQUIRED routes fail `-95` (cross-RP is host-mediated policy, not
claimed); PREFERRED yields the ordered plan — `map_type` 4 or 2
depending on host P2P whitelisting/CPU, both accepted.

## Running one suite by hand

    ./topos/t2-switch.sh                   # boots in background
    source topo-lib.sh
    wait_for_guest 150
    guest_scp guest/run-tests.sh root@localhost:/tmp/
    guest_ssh "bash /tmp/run-tests.sh t2"  # t2|t3|t4|t5|t8
    stop_qemu

Interactive poking: after `wait_for_guest`, just `guest_ssh` around.
QMP one-shots: `qmp_cmd '{"execute":"query-status"}'`.

## Driving the test consumer manually

    cd /sys/kernel/debug/cxl_uio_test
    echo -n 0000:10:00.0 > requester      # any UIO-req-capable BDF
    echo -n region0      > region         # a committed region
    echo -n required     > policy         # forbidden|preferred|required
    echo -n 0 > offset; echo -n 0 > len   # len 0 = whole region
    echo 1 > acquire
    cat acquire                           # rc, plan, attrs, route dump
    cat valid                             # tracks revocation live
    cat events                            # cumulative quiesce/revoke
    echo 1 > release                      # unmap + route put

`acquire` re-acquires idempotently (implicit release first). `events`
counters are cumulative per boot — diff them, don't expect absolutes.

## Environment overrides

From `topo-lib.sh` (export before launching):

    QEMU     (~/code/qemu-upstream/build/qemu-system-x86_64)
    KERNEL   (~/code/linux-torvalds/arch/x86/boot/bzImage)
    IMG      (~/img/cxl-test.qcow2)
    SSHPORT  (27110)
    RUNDIR   (/tmp/uio-tests)   console.log, qmp-sock, pidfile, boot_id
    OUT      (RUNDIR/results)   TAP + dmesg per suite

Topology knob groups (per-topos overrides):

    PORT_SVC   (x-uio-svc3=on,x-uio-svc4=on)
    PORT_FLIT  (x-256b-flit=on)
    T3_EXTRA   (x-uio-req=on,x-ats=on)   extra type3 device props

e.g. an ATS-gate negative test: `T3_EXTRA=x-uio-req=on ./topos/t2-switch.sh`
then a REQUIRED acquire fails `-95` (HDM decoders match translated
addresses only, so requesters must be ATS capable).

## Debugging failures

- `/tmp/uio-tests/results/<suite>.tap` and `<suite>.dmesg` per run;
  `t2-hotremove.tap`/`.dmesg` for phase 2.
- `/tmp/uio-tests/console.log` — full serial console of the last boot.
- dyndbg is enabled by default for all cxl modules **and**
  `drivers/pci/uio.c` + `drivers/pci/p2pdma.c` (see `BOOTARGS`), so
  every rejected hop/gate names itself in dmesg.
- Guest not reachable: check `console.log`; remember `wait_for_guest`
  refuses a guest whose `boot_id` matches the previous launch (stale
  guest guard) — if you manually reuse a running guest, delete
  `/tmp/uio-tests/boot_id` first.
- errno cheat sheet in TAP output: `-95` EOPNOTSUPP (capability/flit/
  VC/policy gate), `-6` ENXIO (decoder count / config state),
  `-19` ENODEV (bad requester BDF or region name in the consumer).

## Gotchas the harness already encodes (don't relearn these)

- **Guest memN naming does not track QEMU device ids.** Probe order
  can swap them between boots. Anything asymmetric must pin devices
  by BDF (`mem_for_bdf`), never by name. Endpoint decoders are found
  via the endpoint port's `uport` symlink, not the devpath.
- **QEMU mirrors the child's LNKSTA2 flit bit into the downstream
  port** (link negotiation). A DSP with `x-256b-flit=off` under an
  endpoint with flit on still reads flit-enabled — and an `hdm-db=on`
  endpoint *requires* flit to realize. Hence non-flit links can only
  be modeled at the switch-USP uplink (t3).
- **`device_del` on cxl-type3 is attention-button orderly removal**:
  needs pciehp in the guest and ~10s; the runner polls for the BDF to
  vanish rather than sleeping.
- `stop_qemu` kill-waits the pidfile owner and waits for the ssh port
  to free; launches are serialized by design (one SSHPORT).

## Known QEMU emulation limits (can't be tested here)

- No UIO data path at all: routing, completion coalescing/accounting,
  ordering semantics are out of reach.
- No CXIMS/XOR CFMWS emulation: the kernel's "Standard Modulo only"
  rejection is covered by inspection, not by a topology.
- No DPC emulation; error-path revocation beyond hot-remove would use
  HMP `pcie_aer_inject_error` (not yet scripted).
- SVC negotiation is static (Resource Status never reads pending), so
  the kernel's negotiation poll completes immediately by design.

## Adding a suite

1. Copy a `topos/t*.sh`, tweak device knobs (keep the e1000 first and
   the `-M cxl-fmw...` window last; keep `$PORT_SVC/$PORT_FLIT/
   $T3_EXTRA` parameterization so overrides keep working).
2. Add a `case` arm in `guest/run-tests.sh` using the `ok/fail/
   check/expect_eq` helpers and the provisioning library
   (`create_region <uio> <ways> <memdevs...>`, `commit_region`,
   `destroy_region`, `mem_for_bdf`, `ep_decoder_for_mem`).
3. Register it in `run-all.sh` with `run_suite <topo> <suite>`.
