# PCIe Unordered IO (UIO) test suite

QEMU-driven validation of the Linux PCIe Unordered IO (UIO) transport
stack: capability discovery, CXL UIO Direct-P2P region provisioning,
route validation/commit (including live SVC virtual-channel programming
and its config-space side effects), DMA attribute derivation, policy
fallback, and revocation.

The harness boots a kernel built from the UIO patch series under an
emulated CXL fabric, drives an in-guest test driver over ssh, and emits
TAP. Eight topologies exercise the happy path (direct-attach and
switched) plus the fail-closed gates (missing capability, no SVC,
non-flit link, cross-root-port, no-ATS requester, wide interleave).

> **Scope.** QEMU emulates UIO **enumeration only** — there is no UIO
> data path. The suite validates discovery, provisioning gates, routing
> logic and lifetime/revocation. Wire behaviour (completion accounting,
> 64B update granularity, actual peer traffic) is out of reach here and
> is called out under "Emulation limits" below.

---

## What you need

This targets **out-of-tree work-in-progress branches** — it is not
expected to run against a stock kernel or stock QEMU. Three moving
parts, which you build once and then point the harness at:

| part | what it is |
|---|---|
| **kernel** | a `bzImage` built from the PCIe UIO series (PCI/UIO core, `DMA_ATTR_UIO`, P2PDMA typed providers, CXL UIO provisioning), which sits on top of the CXL Back-Invalidate series. |
| **QEMU** | a `qemu-system-x86_64` with the UIO enumeration series applied (SVC ext cap 0x35, flit-mode props, Device-3 capability, `cxl-type3` `x-uio`/`x-uio-req`/`x-ats`, per-window `back-invalidate` CFMWS, FLR on `cxl-type3`). |
| **guest image** | any small Debian/Ubuntu qcow2 used purely as a **userland** — see below. |

> Fill in your published branch URLs here when you clone this:
> kernel `<KERNEL-SERIES-URL>`, QEMU `<QEMU-SERIES-URL>`. The QEMU side
> builds on the Samsung UIO enumeration RFC
> (`20260609105836.3702787-1-shrihari.s@samsung.com` on linux-cxl).

### The key simplification

The harness boots your kernel **directly** with QEMU `-kernel`, so the
guest image is only a root filesystem + userland. **All UIO/CXL
functionality is built into the `bzImage` (`=y`, not modules)**, so the
guest needs no matching `/lib/modules` and no out-of-tree drivers
installed. Any generic Debian/Ubuntu cloud image works once it can ssh
in. Do **not** build the UIO/CXL options as modules — the harness does
not install modules into the guest.

---

## Host requirements

- **KVM**: `/dev/kvm` accessible (be in the `kvm` group; enable
  virtualization in BIOS, or nested virt if the host is itself a VM).
  The launcher uses `-cpu host -enable-kvm`; running under pure TCG is
  possible but requires editing `launch_qemu` in `topo-lib.sh` (drop
  `accel=kvm`/`-enable-kvm`, change `-cpu host`) and is much slower.
- **Packages** (Debian/Ubuntu names): `openssh-client`, `python3`,
  `iproute2` (for `ss`), and either a distro `qemu-system-x86` or your
  own build. To create the guest image: `libguestfs-tools`
  (`virt-customize`). To build QEMU/kernel from source: their usual
  build-deps.
- An ssh keypair (`ssh-keygen` if you have none) — the guest trusts
  your public key.

---

## Setup

### 1. Build QEMU

Build the `uio-work-rfc` QEMU and note the binary path. Sanity-check
that it has the UIO device knobs the topologies use:

    $QEMU -device cxl-type3,help      2>&1 | grep -E 'x-uio|x-ats'
    $QEMU -device pcie-root-port,help 2>&1 | grep -E 'x-uio-svc|x-256b-flit'

Both should print matching properties. If they don't, your QEMU lacks
the enumeration series.

### 2. Build the kernel

On top of a CXL-enabled config, add the UIO options **built-in**:

    CONFIG_CXL_BUS=y CONFIG_CXL_MEM=y CONFIG_CXL_REGION=y
    CONFIG_PCI_P2PDMA=y
    CONFIG_PCI_UIO=y
    CONFIG_CXL_UIO_TEST=y        # the in-kernel debugfs test consumer
    CONFIG_HOTPLUG_PCI_PCIE=y    # REQUIRED for the hot-remove phase;
                                 # without pciehp, QEMU device_del is
                                 # silently ignored by the guest
    CONFIG_DMA_API_DEBUG=y       # optional: enables the dma-debug
                                 # misuse checks (t2 test 9b)

Build `arch/x86/boot/bzImage`. After the first boot you can confirm the
kernel is right from inside the guest:

    ls -d /sys/kernel/debug/pci_uio /sys/kernel/debug/cxl_uio_test

Both directories must exist (PCI_UIO + CXL_UIO_TEST are present).

### 3. Create the guest image

Any Debian/Ubuntu qcow2 works; it needs, at boot time, only: a root
filesystem, a serial console login, `sshd` accepting your key as root,
DHCP on the first NIC (`enp0s2`), and `pciutils`. Starting from a
Debian cloud image:

    wget https://cloud.debian.org/images/cloud/bookworm/latest/\
debian-12-genericcloud-amd64.qcow2 -O cxl-test.qcow2

    export LIBGUESTFS_BACKEND=direct
    NETPLAN='network:\n  version: 2\n  ethernets:\n    enp0s2:\n      dhcp4: true\n'
    virt-customize -a cxl-test.qcow2 \
      --root-password password:root \
      --install openssh-server,pciutils \
      --ssh-inject root:file:$HOME/.ssh/id_rsa.pub \
      --run-command 'systemctl enable ssh' \
      --run-command "printf '$NETPLAN' > /etc/netplan/50-enp0s2.yaml" \
      --run-command 'chmod 600 /etc/netplan/50-enp0s2.yaml'

Two things to verify for your image:

- **Root device.** The launcher passes `root=/dev/sda1`. Debian
  genericcloud lands root on `/dev/sda1` with the q35 SATA default; if
  yours differs, set `ROOTDEV` (see Configuration). The guest
  bootloader is bypassed (`-kernel`), so *this* cmdline is what counts,
  not the image's grub.
- **Networking.** The first `-device` is the NIC, so it enumerates as
  `enp0s2`; it must DHCP (slirp serves `10.0.2.x`) so the host's
  forwarded ssh port reaches it. The recipe above forces that; some
  cloud images already DHCP all `en*` via cloud-init. Never add
  `net.ifnames=0` — predictable naming is what keeps the NIC at
  `enp0s2`.

serial-getty on `ttyS0` starts automatically because the cmdline sets
`console=ttyS0`. Root ssh with a key works under Debian's default
`PermitRootLogin prohibit-password`.

### 4. Point the harness at your builds

Everything is overridable by environment variable (see Configuration).
The defaults assume the author's layout, so export your paths:

    export QEMU=/path/to/qemu/build/qemu-system-x86_64
    export KERNEL=/path/to/linux/arch/x86/boot/bzImage
    export IMG=/path/to/cxl-test.qcow2

---

## Run

    ./run-all.sh

Boots the eight topologies sequentially (one QEMU at a time, ssh
forwarded on `127.0.0.1:$SSHPORT`), pushes the guest driver, runs each
suite, and collects TAP + dmesg under `$RUNDIR/results/`. Exit status
is 0 iff every suite passes. A fully green run ends with:

    === t1 (t1-direct.sh) ===       # pass 7 fail 0
    === t2 (t2-switch.sh) ===       # pass 43 fail 0
    --- t2 phase 2: completer hot-remove revocation ---
    ok - route armed for hot-remove
    ok - route revoked by completer hot-remove
    ok - quiesce+revoke ops fired exactly once
    ok - requester enable dropped on revocation
    === t5 ... t4 ... t3 ... t6 ... t7 ... t8 ===  all pass
    suites failed: 0

Wall-clock is dominated by eight guest boots (~1 min each).

### Running one suite (or a subset)

`run-all.sh` takes suite names — handy while iterating, since each suite
is one guest boot:

    ./run-all.sh t1          # just t1
    ./run-all.sh t4 t8       # a subset, in the given order

Valid names: `t1 t2 t3 t4 t5 t6 t7 t8`. With no arguments it runs them
all.
This routes through the same machinery as a full run, so per-suite TAP +
dmesg still land in `$OUT`, and t2 still gets its hot-remove phase. For
poking at a live guest instead of a scripted pass, see "Running one
suite by hand" below; to reproduce a single *check*, drive the debugfs
consumer directly ("Driving the test consumer manually").

---

## Configuration

All knobs are environment variables read by `topo-lib.sh` /
`run-all.sh`; export them before launching. Defaults in parentheses.

**Paths and environment**

    QEMU          qemu-system-x86_64 binary
                  (~/code/qemu-upstream/build/qemu-system-x86_64)
    KERNEL        bzImage to boot with -kernel
                  (~/code/linux-torvalds/arch/x86/boot/bzImage)
    IMG           guest rootfs qcow2            (~/img/cxl-test.qcow2)
    ROOTDEV       guest root partition          (/dev/sda1)
    SSH_KEY       ssh identity file; empty uses your default/agent  ()
    EXTRA_APPEND  extra kernel cmdline appended to BOOTARGS          ()
    SSHPORT       host-forwarded guest ssh port (27110)
    RUNDIR        scratch: console.log, qmp-sock, pidfile, boot_id
                  (/tmp/uio-tests)
    OUT           results dir: per-suite TAP + dmesg  (RUNDIR/results)

Example — different image whose root is `/dev/vda1`, a dedicated key,
and extra debug on the cmdline:

    ROOTDEV=/dev/vda1 SSH_KEY=~/.ssh/cxl_test \
      EXTRA_APPEND="dyndbg=+p loglevel=8" ./run-all.sh

**Topology knob groups** (per-topology, consumed by `topos/*.sh`)

    PORT_SVC   port SVC capability   (x-uio-svc3=on,x-uio-svc4=on)
    PORT_FLIT  port flit mode        (x-256b-flit=on)
    T3_EXTRA   extra cxl-type3 props (x-uio-req=on,x-ats=on)

e.g. a one-off ATS-gate negative test on the happy-path topology:

    T3_EXTRA=x-uio-req=on ./topos/t2-switch.sh

then a REQUIRED acquire fails `-95` (HDM decoders match translated
addresses only, so requesters must be ATS-capable).

---

## The suites

The `tN` labels are stable identifiers; the run order is by role, not by
number — the happy paths first (t1 direct-attach, then t2 switched),
since the fail-closed negatives only mean anything once the same
topology is shown to succeed, then t5, t4, t3, t6, t7, t8.

All topologies share the base: q35 + `cxl=on`, one `pxb-cxl` host
bridge, a 4G CFMWS window with `back-invalidate=on`, and `cxl-type3`
devices with `hdm-db=on`. Port knobs: `x-uio-svc3`/`x-uio-svc4` (SVC
capability), `x-256b-flit`. Device knobs: `x-uio` (completer),
`x-uio-req` (requester), `x-ats`.

### t1 — direct attach, no switch (7 checks)

    rp0 -- mem0     one root port, one type3 directly under it

The minimal topology and the only *successful* commit where the root
port is the sole upstream hop (t2/t6 target under a switch; t8's direct
commit fails on a non-UIO host bridge). Proves: discovery (RP +
endpoint both SVC-capable), the window is UIO-eligible (`cap_uio`), a
1-way `uio=1` region commits and programs the endpoint decoder UIO bit
with the RP as the sole segment-check hop, and that a route over the
no-switch path classifies **THRU_RP** (`route_flags 0x2`, `map_type 4`,
one hop) — the correct contrast to t2's in-fabric BUS_ADDR. (Minimal
topology: the one device is both requester and target; the assertion is
about path classification, not a distinct peer.)

### t2 — switch happy path (43 checks + 4 hot-remove)

    rp0 -- us0 -- dsp0 -- mem0 (region target)
                \- dsp1 -- mem1 (requester)     all knobs on

What it proves, in order:

1. Discovery: `/sys/kernel/debug/pci_uio/capabilities` shows exactly
   7 SVC-capable functions — 5 ports (incl. a plain pcie-root-port
   with SVC, the regression check for the SVC-vs-AER placement fix)
   plus the 2 endpoints, which carry SVC themselves (VC enablement is
   per-link, both partners; TC3 mapping lives in the port containing
   the requester/completer function) — and 2 `requester completer`
   endpoints (Device 3 capability emulation).
2. `uio=1` region commit succeeds; endpoint decoder `uio` attr reads 1.
3. REQUIRED route via the `cxl_uio_test` consumer: `rc: 0`,
   `map_type: 3` (in-fabric BUS_ADDR), `xport_uio: 1`,
   `attrs: 0x4000` (DMA_ATTR_UIO without DMA_ATTR_MMIO — HDM is not a
   BAR), `route_tc/vc: 3/3`, `boundary: 256`, `update_granule: 64`,
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
9. Subrange decode (1 vs 2 interleave granules → 1 vs 2 bound
   targets), PREFERRED-on-eligible takes the UIO plan, post-commit
   `uio`/`uio_policy` EBUSY guards, and the dma-debug misuse triad
   (RAM / no-route / attr-mismatch warnings via the module's `misuse`
   hook, needs CONFIG_DMA_API_DEBUG).
10. Requester FLR: the reset-preparation revocation entry point
    (self-contained on a requester-only device), route revoked and
    DevCtl3 enable cleared.
11. Phase 2 (host-driven): `device_del mem0` → orderly pciehp removal
    → route revoked, ops fired once (delta-counted against a
    baseline), requester DevCtl3 enable cleared.

### t5 — device without UIO capability (2 checks)

Same topology, but the device under dsp0 lacks `x-uio` (keeps
`hdm-db`). `uio=1` region commit must fail `EOPNOTSUPP` at the commit
gate ("not a UIO Direct P2P target" with cxl dyndbg). The non-capable
device is selected **by BDF** (`0000:0f:00.0`), see gotchas.

### t4 — port without SVC (1 check)

Switch USP lacks `x-uio-svc3`. Commit must fail via the endpoint-uplink
segment check (`cxl_uio_segment_check()` names the hop with dyndbg).

### t3 — non-flit uplink (1 check)

`x-256b-flit=off` on the **switch USP** (see gotchas for why not the
DSP). No uio region may reach committed state; in practice the BI
prerequisite (also flit-gated) rejects the region at target attach
before the UIO segment check runs — both gates lead to the same
fail-closed outcome and the test accepts either shape.

### t6 — 4-way interleave (6 checks)

Four endpoints under one switch, 4-way `uio=1` region. Exercises
per-endpoint ISP programming, `pos_map` for more than two interleave
positions, a 5-hop route (4 DSPs + USP), and subrange decode
(1-granule → 1 target, 3-granule → 3 targets).

### t7 — requester without ATS (3 checks)

Requesters realized without `x-ats`. CXL HDM decoders match translated
addresses only, so REQUIRED route acquisition is refused (`-95`) and
PREFERRED falls back to the ordered host-mediated plan.

### t8 — cross root port (4 checks)

Two type3 devices directly under two cxl-rp's, no switch. A 2-way
`uio=1` region commit must fail `ENXIO`: the pxb host bridge advertises
no UIO decode capability, so the HB decoder trips the UIO Capable
Decoder Count gate. A plain (uio=0) 2-way region commits; REQUIRED
routes fail `-95` (cross-RP is host-mediated policy, not claimed);
PREFERRED yields the ordered plan — `map_type` 4 or 2 depending on host
P2P whitelisting/CPU, both accepted.

---

## Running one suite by hand

For a scripted single-suite pass use `./run-all.sh <suite>` (above).
The manual sequence below is for *interactive* work — it leaves the
guest running so you can poke at it (it skips result collection and t2's
phase-2 hot-remove):

    ./topos/t2-switch.sh                   # boots in background
    source topo-lib.sh
    wait_for_guest 150
    guest_scp guest/run-tests.sh root@localhost:/tmp/
    guest_ssh "bash /tmp/run-tests.sh t2"  # t2|t3|t4|t5|t6|t7|t8
    # ... poke at the live guest here ...
    stop_qemu

After `wait_for_guest`, just `guest_ssh` around. QMP one-shots:
`qmp_cmd '{"execute":"query-status"}'`.

## Driving the test consumer manually

The kernel's `cxl_uio_test` module exposes the whole route/mapping
contract under debugfs, so you can reproduce any check by hand:

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

## Debugging failures

- `$RUNDIR/results/<suite>.tap` and `<suite>.dmesg` per run;
  `t2-hotremove.tap`/`.dmesg` for phase 2.
- `$RUNDIR/console.log` — full serial console of the last boot.
- dyndbg is on by default for all cxl modules **and**
  `drivers/pci/uio.c` + `drivers/pci/p2pdma.c` (see `BOOTARGS`), so
  every rejected hop/gate names itself in dmesg.
- Guest not reachable: check `console.log`; `wait_for_guest` refuses a
  guest whose `boot_id` matches the previous launch (stale-guest
  guard) — if you manually reuse a running guest, delete
  `$RUNDIR/boot_id` first.
- errno cheat sheet in TAP output: `-95` EOPNOTSUPP (capability / flit
  / VC / policy gate), `-6` ENXIO (decoder count / config state),
  `-19` ENODEV (bad requester BDF or region name in the consumer).

## Portability notes

The harness pins a few environment facts; if you diverge from them,
here is what to change:

- **Root device** — set `ROOTDEV` to match your image
  (`/dev/sda1` default; `/dev/vda1` for a virtio-blk image, etc.).
- **First NIC = `enp0s2`, DHCP** — required so forwarded ssh reaches
  the guest. Keep the e1000 as the first `-device` and never set
  `net.ifnames=0`.
- **KVM** — assumed. Non-KVM needs a `launch_qemu` edit (see Host
  requirements).
- **BDFs are topology-derived, not configurable.** The guest sees
  stable BDFs (`0000:0f:00.0` = mem0, `0000:10:00.0` = mem1, …) purely
  because the topology scripts fix device order and `pxb-cxl bus_nr`.
  Guest `memN` *names* do **not** track QEMU device ids, so the tests
  pin by BDF (`mem_for_bdf`). If you edit a topology's device layout,
  re-derive any hardcoded BDFs (e.g. the `0000:0f:00.0` poll in
  `run-all.sh`'s hot-remove phase).
- **ssh identity** — `guest_ssh` uses your default key/agent unless you
  set `SSH_KEY`.

## Gotchas the harness already encodes (don't relearn these)

- **Guest memN naming does not track QEMU device ids.** Probe order can
  swap them between boots. Anything asymmetric must pin devices by BDF
  (`mem_for_bdf`), never by name. Endpoint decoders are found via the
  endpoint port's `uport` symlink, not the devpath.
- **QEMU mirrors the child's LNKSTA2 flit bit into the downstream
  port** (link negotiation). A DSP with `x-256b-flit=off` under an
  endpoint with flit on still reads flit-enabled — and an `hdm-db=on`
  endpoint *requires* flit to realize. Hence non-flit links can only be
  modeled at the switch-USP uplink (t3).
- **`device_del` on cxl-type3 is attention-button orderly removal**:
  needs pciehp in the guest and ~10s; the runner polls for the BDF to
  vanish rather than sleeping.
- `stop_qemu` kill-waits the pidfile owner and waits for the ssh port
  to free; launches are serialized by design (one SSHPORT).

## Emulation limits (can't be tested here)

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
2. Add a `case` arm in `guest/run-tests.sh` using the `ok/fail/check/
   expect_eq` helpers and the provisioning library
   (`create_region <uio> <ways> <memdevs...>`, `commit_region`,
   `destroy_region`, `mem_for_bdf`, `ep_decoder_for_mem`).
3. Register it in `run-all.sh` with `run_suite <topo> <suite>`.

## Repository layout

    topo-lib.sh          QEMU launcher library: config knobs, boot args,
                         ssh/scp/qmp helpers, boot-id staleness guard,
                         kill-wait
    topos/t*.sh          one topology per suite (see The suites)
    guest/run-tests.sh   in-guest TAP driver; takes the suite name
    guest/hotremove-*.sh guest halves of the t2 hot-remove phase (host
                         side is in run-all.sh: QMP device_del + poll)
    run-all.sh           orchestrator over all eight suites
