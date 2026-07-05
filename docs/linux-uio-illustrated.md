# PCIe Unordered IO (UIO), Illustrated

How UIO works on the wire, what CXL builds on top of it, and how both
were integrated into the Linux PCI, DMA and CXL stacks. Every diagram
reflects the implementation as built and tested on `pcie-uio-rfc`
(values shown - attrs, map types, route flags, register bits - are the
ones the QEMU suite actually observes).

Companion documents:

    linux-uio-cover-letter.txt              the series posting text
    ~/Documents/linux-uio-api-design-final.md   the design document
    ~/code/uio-tests/README.md              the test harness

Spec authorities: PCIe Base 6.4 (sec 6.34, 7.7.9, 7.9.29, 2.2.6.2,
2.4.4.2, 6.6.2) and CXL r4.0 (sec 9.16, Tables 8-116, 8-123, 8-32,
9-18). See Appendix C for the full cross-reference.

--------------------------------------------------------------------
Contents

  PART I - THE HARDWARE
    1. The problem: fabric-enforced ordering
    2. The UIO contract: ordering moves into the requester
    3. Completions, Transaction IDs, tags
    4. Request shaping: boundaries and the 64B granule
    5. The config-space surface (Device 3, SVC)
    6. TC/VC: a dedicated unordered lane
    7. Failure mode: the misrouted UIO TLP

  PART II - CXL UIO DIRECT P2P TO HDM
    8. What Direct P2P buys
    9. The interleave decode problem
    10. Reverse decode: UIG / UIW / ISP
    11. Containment: the UIO-to-HDM gate, not ACS
    12. The address-match algorithm

  PART III - LINUX INTEGRATION
    13. Design center: the route object
    14. Patch map and subsystem layering
    15. The object model
    16. Boot-time discovery
    17. Route acquisition, end to end
    18. Role programming order (commit / unwind / teardown)
    19. SVC programming and VC ownership
    20. DMA layer: DMA_ATTR_UIO
    21. P2PDMA: typed providers, transfer plans, policy
    22. CXL provisioning and decoder programming
    23. The region as a provider: subrange decode
    24. Lifecycle: probe to teardown
    25. Revocation
    26. Worked example A: the t2 fabric, register by register
    27. Worked example B: one UIO write, end to end
    28. Worked example C: interleave math in bits
    29. Observability and the test suite
    30. Consumer models: DMABUF, iommufd, RDMA

  APPENDIX
    A. errno map
    B. Deliberate deferrals
    C. Spec cross-reference
    D. File map

====================================================================
PART I - THE HARDWARE
====================================================================

1. The problem: fabric-enforced ordering
----------------------------------------

Conventional PCIe guarantees producer/consumer semantics *in the
fabric*: a write (or read) must not pass a prior posted write, at
every queue on the path. Software leans on it constantly - write the
data, then write the flag; anyone who sees the flag sees the data.

The costs are structural:

     every queue on the path preserves order

   requester                                        completer
   +--------+    +----------+    +----------+     +---------+
   | D1     |    |          |    |          |     |         |
   | D2     |--->| D1 D2 F  |--->| D1 D2 F  |---> |  memory |
   | FLAG F |    |  (fifo)  |    |  (fifo)  |     |         |
   +--------+    +----------+    +----------+     +---------+

   - one legal path per (src,dst): multipath fabrics cannot spread
     load without breaking the guarantee
   - head-of-line blocking: if D1 stalls, D2 and F stall behind it
     even when they target something else entirely
   - posted writes have no completions: the requester never learns
     when (or whether) D1 landed

2. The UIO contract: ordering moves into the requester
------------------------------------------------------

UIO (PCIe 6.4 sec 6.34, from the 2023 UIO ECN) keeps the observable
producer/consumer behavior and moves the enforcement point. Every UIO
request - *including writes* - has a completion. The fabric may
deliver requests and completions in any order, over any path, split
or coalesced. The requester holds dependent operations until the
completions it cares about are all accounted:

   requester                    fabric                completer
   +----------------+    (reorders freely,       +--------------+
   | issue D1 -------->   any path)          --> | D2 lands     |
   | issue D2 -------->                      --> | D1 lands     |
   | hold FLAG      |                            |              |
   |    .           | <-- UIOWrCpl(D2) <-------- | cpl D2       |
   |    .           | <-- UIOWrCpl(D1) <-------- | cpl D1       |
   | all data cpls  |                            |              |
   | accounted?  -----+                          |              |
   | yes: issue FLAG -+--> (any path)        --> | FLAG lands   |
   +----------------+                            +--------------+

Key properties:

   - the requester selects UIO vs ordered *per operation*
   - UIO exists only in Flit Mode, and only when the entire path
     (every link, every routing element) supports and enables it
   - non-tree/multipath topologies are permitted for UIO traffic;
     a tree subset must exist for configuration and ordered traffic
   - UIO writes use Posted flow-control credits; other UIO requests
     use Non-Posted credits

3. Completions, Transaction IDs, tags
-------------------------------------

Three completion namespaces exist; UIO writes get the interesting one
(PCIe 6.4 sec 2.2.6.2):

   Group I    Cpl/CplD for non-UIO requests
              ID = ReqID[15:0] + Tag[13:0]; unique per outstanding
   Group II   UIOWrCpl, for UIO Memory Writes
              ID = TC[2:0] + ReqID[15:0] + Tag[13:0]
              tags MAY BE SHARED across outstanding writes
   Group III  UIORdCpl(D), for UIO Memory Reads
              ID = TC + ReqID + Tag; unique per outstanding

Group II sharing is what makes cheap ordering enforcement possible:
write completions carry no data, so the requester does not match them
one-to-one - it counts data. Completers may split or coalesce write
completions per Transaction ID:

   issued (all Tag=7):            returned (any order/shape):
     UIOMWr 256B  ( 64 DW)          UIOWrCpl Tag=7  192 DW
     UIOMWr 256B  ( 64 DW)          UIOWrCpl Tag=7   32 DW
     UIOMWr 512B  (128 DW)          UIOWrCpl Tag=7   32 DW
     ------------ 256 DW            ------------    256 DW
                                    counter balanced -> the ID is
                                    quiesced; dependent flag may go

   (Completers may split on 64B Write Completion Boundaries and
   coalesce per ID; switches are not permitted to coalesce.)

One tag size is architected for UIO: 14-bit. A Flit Mode function
must support 14-bit tag completion (DevCap3 bit 1, "MUST@FLIT") -
the kernel checks it on every UIO target as a conformance screen.

4. Request shaping: boundaries and the 64B granule
--------------------------------------------------

   256B rule (default): a UIO request must not cross a naturally
   aligned 256B boundary. DevCtl3 bit 8 lifts it (4KB still always
   applies); Linux never sets it.

        0       256B      512B      768B
        |---------|---------|---------|
          [ ok ]
               [ NOT ok ]        <- crosses a 256B line

   Why: UIO is designed to route straight to memory controllers, and
   interleaved memory changes owner every granule. A request that
   straddles two owners cannot be completed by either (Part II shows
   what actually happens to one: forwarded to the owner of the start
   address, then Completer Aborted).

   64B update granule (writes), PCIe 6.4 sec 2.4.4.2: for every
   naturally aligned 64B block touched by a UIO write, the update is
   all-or-nothing and observed in one consistent order by ALL
   readers. Once the completer has sent the UIOWrCpl covering a
   block, every later UIO request must observe that block written.

     128B UIO write:
     [ block0 64B ][ block1 64B ]
        atomic        atomic       ...but block0/block1 may become
                                   visible in either order:
                                   per-BLOCK, not per-request

These two rules surface verbatim in the kernel as route limits:
boundary (256, clamped to the interleave granularity) and
update_granule (64).

5. The config-space surface (Device 3, SVC)
-------------------------------------------

Two extended capabilities carry all of UIO's config state. Role
capabilities are HwInit (never change at runtime); the one runtime
control - requester emission - is owned by the Linux route object.

  Device 3 Extended Capability (ID 002Fh)        PCIe 6.4 sec 7.7.9
  +------+----------------------------------------------------------+
  | +00h | header (cap id 002Fh, version 1)                         |
  | +04h | DevCap3 (HwInit; unaffected by FLR)                      |
  |      |   bit 1   14-Bit Tag Completer Supported  (MUST@FLIT;    |
  |      |           kernel checks on every UIO target)             |
  |      |   bit 2   14-Bit Tag Requester Supported                 |
  |      |   bit 10  UIO Mem RdWr Completer Supported  <- cpl role  |
  |      |   bit 11  UIO Mem RdWr Requester Supported  <- req role  |
  | +08h | DevCtl3                                                  |
  |      |   bit 7   UIO Mem RdWr Requester Enable                  |
  |      |           ROUTE-OWNED. Emission requires this AND Bus    |
  |      |           Master Enable. NOT FLR-exempt (dies with the   |
  |      |           function). Cleared at boot if found set        |
  |      |           (firmware handoff / kexec leftovers).          |
  |      |   bit 8   UIO Request 256B Boundary Disable (never set)  |
  | +0Ch | DevSta3   bit 3  Segment Captured (end-to-end flit)      |
  +------+----------------------------------------------------------+

  Streamlined Virtual Channel Ext. Cap. (ID 0035h)   PCIe 6.4 7.9.29
  +------+----------------------------------------------------------+
  | +00h | header                                                   |
  | +04h | Port Cap 1    [2:0] SVC Extended VC Count (beyond VC0)   |
  | +08h | Port Cap 2    RsvdP                                      |
  | +0Ch | Port Control  [0] VC Enablement Completed                |
  | +10h | Port Status   [0] Use VC/MFVC - RW1C, ONE-WAY per boot   |
  |      |     set:   legacy VC/MFVC caps own the link's VCs        |
  |      |     clear: SVC owns them (all VC/MFVC enables die,       |
  |      |            SVC VC0 comes up); stays clear until the      |
  |      |            next Conventional Reset                       |
  | per-VC resource n, at +14h/+18h/+1Ch + n*0Ch:                   |
  |  RES_CAP    [11:8] protocols   [14:12] VC ID                    |
  |             0000b = same as VC0          (VC0 must use this)    |
  |             0010b = UIO only             (VC3 must, if UIO)     |
  |             0011b = UIO or restricted    (VC4 may)              |
  |  RES_CTRL   [7:0] TC/VC map (bit n = TCn)  [11:8] proto select  |
  |             [29:27]+[30] shared-FC limit   [31] VC Enable       |
  |  RES_STA    [1] VC Negotiation Pending (poll for clear)         |
  +------+----------------------------------------------------------+

  Placement rules the kernel honors: an Upstream Port implements SVC
  only in function 0 (applies port-wide); SR-IOV VFs must NOT
  implement SVC (discovery skips them). All SVC registers are on the
  FLR exemption list - fabric VC config survives function resets.

6. TC/VC: a dedicated unordered lane
------------------------------------

Traffic Classes label packets; Virtual Channels give each label its
own queues and flow-control credits. UIO rides a dedicated lane so
its reordering freedom never mixes with ordered traffic:

              one physical link, independent lanes

    TX side                                    RX side
   +----------------------------+           +------------------+
   | TC0 --> VC0 [ ordered   ]==================> VC0 ordered  |
   | TC3 --> VC3 [ UIO       ]==================> VC3 UIO      |
   +----------------------------+           +------------------+

   mandatory defaults (PCIe 6.4 Table 2-46):
     TC0/VC0   default, ordered
     TC3/VC3   UIO      (required if UIO is supported)
     TC4/VC4   UIO      (optional second UIO VC)

VC enablement is a property of BOTH link partners: each side of every
link must enable the VC, and TC/VC mapping lives in the Port that
contains the requester/completer Function. This is why the kernel
programs SVC on the endpoints too, not only on switches (sec 19).

7. Failure mode: the misrouted UIO TLP
--------------------------------------

   requester --> ... --> egress port with no UIO-configured VC
                                |
                                X   blocked at egress
                                |   ("TLP Translation Egress
                                |     Blocked"); for UIO posted-
                                |     credit TLPs: NO ERROR REPORTED
                                v
                   requester observes... nothing, ever
                   (a completion timeout, much later)

This silent-drop failure mode drives the central Linux design rule:
there is no "enable UIO" knob that could ever be flipped without a
validated end-to-end path (sec 13).

====================================================================
PART II - CXL UIO DIRECT P2P TO HDM
====================================================================

8. What Direct P2P buys
-----------------------

CXL r4.0 sec 9.16 keys in-fabric peer access to HDM (host-managed
device memory) to UIO specifically: switch forwarding of peer traffic
into HDM ranges is a UIO decoder mechanism, not generic memory
routing. In-fabric *ordered* P2P into HDM is not defined transport.

                         host
                          |
                  +-------+--------+   host bridge
                  |                |
                 rp0              rp1
                  |                |
               switch           mem3 mem4     <- interleave set B
              /   |   \
        requester mem1 mem2                   <- interleave set A

   requester -> set A:  decoder-matched at the switch, forwarded
                        directly between downstream ports; the host
                        is never involved
   requester -> set B:  not below this switch; forwarded toward the
                        host, subject to host-specific policy

The kernel further scopes coherent Direct P2P to HDM-DB regions:
without Back-Invalidate there is no mechanism to resolve a coherence
conflict on a device-to-device access. (Policy scoping, not API
structure - HDM-H/HDM-D relaxations need no interface change.)

9. The interleave decode problem
--------------------------------

A committed region spreads consecutive granules across its targets:

   region HPA space (2-way, 256B granularity):

   +--------+--------+--------+--------+--------+---
   |   g0   |   g1   |   g2   |   g3   |   g4   |...
   +--------+--------+--------+--------+--------+---
     mem0     mem1     mem0     mem1     mem0

A peer's UIO request lands somewhere in that HPA space, entering the
fabric at a *downstream* port - the opposite direction from normal
host-side decode. Two questions must be answered in hardware:

   at the switch:  which of my ports owns this address - or does it
                   belong to a peer component above/beside me?
   at the device:  is this granule really mine, and does the request
                   stay inside it?

10. Reverse decode: UIG / UIW / ISP
-----------------------------------

An HPA inside a region decomposes as (G = encoded granularity,
W = log2(total ways)):

      63                    G+8+W-1    G+8   G+7             0
     +-----------------------+----------+--------------------+
     |  upper (range match)  | position | offset in granule  |
     +-----------------------+----------+--------------------+

Decode stages consume position bits from the LOW end first: the root
(CFMWS) selects the host bridge, each switch level selects a
downstream port, and whatever remains identifies the device's slot.

A switch or host bridge decoder handling *upstream-ingress* UIO must
therefore know how much interleave was applied ABOVE it. That is
exactly what the three UIO fields in the HDM Decoder n Control
register describe (CXL r4.0 Table 8-123):

   UIG   granularity of the aggregate upstream interleave
   UIW   ways        of the aggregate upstream interleave
   ISP   this component's position within that upstream set

   "the address is below me" test:
        UIW == 0                                (nothing above), or
        addr[UIW+UIG+7 : UIG+8] == ISP

The *device's* decoder uses ISP differently, and the field is not
UIO's at all: Table 8-123 defines device ISP as BI-capable-device
state (reserved otherwise), because BISnp addresses are HPAs -
downstream ports validate them against the USP's decoders (Table
9-13) - so an interleaved device needs its position to resolve
DPA->HPA for the snoops it originates. Linux programs it with the
BI bit; UIO's address match then reuses it: ISP = the device's
region position, checked against the FULL position field, plus the
boundary rule (UIG/UIW stay reserved for devices):

        addr[IW+IG+7 : IG+8] == ISP        this granule is mine
        offset + len fits in the granule   no straddle
        otherwise: Completer Abort, no data committed

Getting these semantics right matters: programming UIG/UIW as a
mirror of the decoder's own IG/IW (a tempting first reading) makes
every interleaved access a partial match and every transfer a
Completer Abort. Section 28 does the math with real bit numbers.

11. Containment: the UIO-to-HDM gate, not ACS
---------------------------------------------

Two containment regimes exist, one per kind of peer memory:

   BAR-to-BAR P2P            contained by ACS, as always. Any ACS
                             redirect on the path means the traffic
                             goes through the host - a different
                             transfer plan. The kernel requires an
                             ACS-redirect-free path for BAR routes.

   UIO into CXL HDM          ACS DOES NOT APPLY. Table 9-18: a DSP
                             that decoder-matches a UIO address
                             forwards it to the owning peer port
                             "regardless of ACS configuration
                             including egress control vector".

   The architected control for the HDM case is a dedicated gate:

     CXL Extensions DVSEC for Ports (id 3), Port Control (+0Ch)
       bit 4  UIO To HDM Enable
              RW in Switch Downstream Ports ONLY; RsvdP elsewhere
              0 (default): Completer Abort decoder-matched UIO
              1:           forward per Table 9-18

   The kernel programs this gate per-DSP at ROUTE commit, not region
   commit: a provisioned region stays inert until some requester
   actually holds a route through those DSPs.

   One more requester-side gate: HDM decoders match TRANSLATED
   addresses only (the TLP's AT field), so a requester without ATS
   can never produce a matching UIO request. Route validation
   requires pci_ats_supported() on the requester for HDM targets.

12. The address-match algorithm
-------------------------------

Compressed from CXL r4.0 sec 9.16.1 and Table 9-18:

  DSP ingress (evaluates the USP's decoders):
    AT=translated && addr+len inside a decoder range?
      no  --> not HDM: normal PCIe handling
      yes --> position match (UIW==0, or position bits == ISP)?
          yes: COMPLETE match
               gate=1 -> forward to the owning peer DSP (ACS
                         bypassed by architecture)
               gate=0 -> Completer Abort
          no : PARTIAL match
               gate=1 -> forward toward the host
               gate=0 -> Completer Abort

  Device:
    complete match (incl. the in-granule length rule) -> execute
    partial match  -> Completer Abort (writes commit no data)
    mismatch       -> normal PCIe handling

  Root Port ingress (host bridge decoders):
    complete match w/ UIO=1 -> forward to the peer RP, subject to
                               host-specific access controls
    anything else           -> host-specific handling

  Note the DSP does not consider length: a request that straddles an
  interleave boundary is forwarded to the owner of its START address,
  which then Completer-Aborts it (the device does check). This is
  why the kernel clamps every route's request boundary to the
  target's interleave granularity.

====================================================================
PART III - LINUX INTEGRATION
====================================================================

13. Design center: the route object
-----------------------------------

UIO legality is a property of a tuple:

        (requester, path, target set, address range)

never of a single device. The design therefore has exactly one grant
object - the route - and every hardware enable in the fabric is owned
by route lifetime:

     no route  <=>  no requester enable, no UIO VC commitments,
                    no HDM gates (that no other route still needs)

There is no sysfs/module-param "enable UIO" anywhere. Acquire a
route, or nothing is enabled. Fail-closed by construction, matching
the hardware's silent-drop failure mode (sec 7). Corollaries:

   - the kernel never orders, fences or waits for UIO traffic; on
     unmap, "stop DMA first" is the driver's job as always - UIO
     merely makes "stopped" precise (all completions accounted)
   - revocation is mandatory plumbing, not an afterthought: fabric
     events must be able to kill transport under a live consumer

14. Patch map and subsystem layering
------------------------------------

Nine patches, three groups; 1-6 are pure PCIe/DMA (no CXL):

    [1] PCI/UIO: capability discovery
     |     pci_regs.h defs, pci_uio_init(), predicates, debugfs
     |
    [2] dma-mapping:            [3] PCI/P2PDMA: typed providers
     |    DMA_ATTR_UIO,              provider {type, base, size,
     |    dma-debug checks           flags, range_validate};
     |                               range-aware classification
     +------------+------------------+
                  v
    [4] PCI/UIO: route objects            <- the core
     |    get/put, path walk, VC programming, limits
    [5] PCI/UIO: revocation
     |    revoke_dev/subtree + removal/reset/AER hooks
    [6] PCI/P2PDMA: policy wiring
     |    map_info(policy) -> route; p2pdma_map_attrs()
     v
    [7] cxl: target capability + provisioning gates
    [8] cxl/region: the region as a typed provider
    [9] cxl: test consumer (cxl_uio_test)

Runtime layering (who calls whom):

  consumer (driver; here: cxl_uio_test)
     |   cxl_region_p2pdma_provider()      get typed peer memory
     |   pci_p2pdma_map_info(range,policy) transfer plan (+ route)
     |   p2pdma_map_attrs()                MMIO/UIO derivation
     |   dma_map_phys()/dma_unmap_phys()   annotated mapping
     |   pci_uio_route_put()               release transport
     v
  +---------------------------------------------------------------+
  | DMA mapping   DMA_ATTR_UIO: stateless annotation; dma-debug    |
  |               checks coverage, misuse, unmap-attr match        |
  +---------------------------------------------------------------+
  | P2PDMA        typed providers (PCI_BAR_MMIO | CXL_HDM);        |
  |               subrange classification, policy, attrs           |
  +---------------------------------------------------------------+
  | PCI core      Device3/SVC discovery; route get/put/valid;      |
  |               VC programming; revocation entry points          |
  +---------------------------------------------------------------+
  | CXL           cxlds->uio latch; region uio provisioning gates; |
  |               decoder UIO/UIG/UIW/ISP; region-as-provider      |
  +---------------------------------------------------------------+

15. The object model
--------------------

                consumer
                   |            \
      (a) get provider        (b) pci_p2pdma_map_info(off, len,
                   |               req{policy, ops}, &info)
                   v                        |
  +----------------------------+            v
  | struct p2pdma_provider     |  +---------------------------+
  |  owner = &region->dev      |  | struct pci_p2pdma_map_info|
  |  type  = CXL_HDM           |  |  type        (addr form)  |
  |  base  = region HPA        |  |  xport_flags (XPORT_UIO)  |
  |  size  = region size       |  |  uio_route --------------------+
  |  bus_offset = 0            |  +---------------------------+    |
  |  flags |= UIO_COMPLETER    |                                   |
  |  range_validate() ---------+---------+                         |
  +----------------------------+  decode |                         |
             ^ embedded in     subrange  v                         v
  +----------+---------+   +----------------------+  +--------------------+
  | struct cxl_region  |   | struct p2p_target_set|  | struct pci_uio_route|
  |  params.uio = 1    |   |  nr_targets          |  |  requester (pinned) |
  |  params.uio_policy |   |  interleave_gran     |  |  provider ---------->
  |  committed decoders|   |  targets[] (pci_dev) |  |  offset, len        |
  +--------------------+   +----------------------+  |  tc=3, vc=3         |
                                                     |  limits {wr,rd,     |
   BAR flavor of the same provider:                  |    boundary=256,    |
     owner = &pdev->dev, type = PCI_BAR_MMIO,        |    granule=64}      |
     base/size = the BAR, bus_offset = CPU->bus      |  flags: IN_FABRIC   |
     delta, flags |= UIO_COMPLETER iff DevCap3.CPL,  |    0x1 | THRU_RP 0x2|
     range_validate = NULL (whole range, one target) |  generation,revoked |
                                                     |  hops[], targets[]  |
                                                     |  ops{quiesce,revoke}|
                                                     +---------------------+

16. Boot-time discovery
-----------------------

Discovery latches capability, never enables anything:

  pci_init_capabilities(dev)              [every PCI device]
    pci_dev3_init():   dev->dev3_cap, flit status
    pci_uio_init():
      DevCap3  -> uio_cpl_capable / uio_req_capable
      DevCtl3.REQ_EN found set?  (firmware handoff, kexec)
               -> CLEAR it: an enabled requester with no route
                  invites TLPs the fabric silently drops
      locate SVC capability     (skip VFs: must not implement)

  cxl_pci probe -> cxl_mem probe          [CXL memdevs]
    cxl_bi_setup()                        (BI series)
    cxl_hdm_uio_setup():
      DevCap3.CPL && HDM Decoder Capability UIO  -> cxlds->uio
      device advertises a UIO decoder-count limit?
        -> nonconformant (the field is reserved for devices, which
           must accept UIO on ALL decoders) -> refuse, uio stays off

  Predicates built on this state (grant nothing by themselves):
    pci_uio_requester_capable() / _completer_capable()   DevCap3
    pci_uio_routing_capable()      SVC present with a UIO-protocol
                                   VC resource (VC3/VC4)

17. Route acquisition, end to end
---------------------------------

  consumer          p2pdma             pci/uio.c              cxl
     |                 |                   |                    |
     | provider = cxl_region_p2pdma_provider(region)            |
     |<------ &region->p2p_provider [CXL_HDM, UIO_COMPLETER] ---|
     |                 |                   |                    |
     | pci_p2pdma_map_info(prov, dev, off, len,                 |
     |                    req{policy=REQUIRED, ops}, &info)     |
     |---------------->|                   |                    |
     |                 | pci_uio_route_get(dev, prov, off, len) |
     |                 |------------------>|                    |
     |                 |                   | [V1] roles/ownership:
     |                 |                   |   requester DevCap3.REQ
     |                 |                   |   provider UIO_COMPLETER
     |                 |                   |   VC ownership != NONE
     |                 |                   | [V2] provider->range_validate
     |                 |                   |------------------->|
     |                 |                   |  target set + granularity
     |                 |                   |<-------------------|
     |                 |                   | [V3] per target, walk to the
     |                 |                   |   lowest common ancestor:
     |                 |                   |   - flit mode on every link
     |                 |                   |   - SVC routing on every hop
     |                 |                   |   - BAR: no ACS redirect
     |                 |                   |     HDM: requester has ATS
     |                 |                   | [V4] endpoint conformance:
     |                 |                   |   requester + every target
     |                 |                   |   own a UIO VC resource;
     |                 |                   |   targets: 14-bit tag cpl
     |                 |                   | [C1] COMMIT leaf->requester
     |                 |                   |   target VCs -> DSP HDM
     |                 |                   |   gates -> hop VCs ->
     |                 |                   |   requester VC ->
     |                 |                   |   DevCtl3.REQ_EN
     |                 |                   |   (failure: full unwind)
     |                 |                   | [C2] limits from path mins
     |                 |                   |   + dma-debug range add
     |                 |<---- route ref ---|                    |
     |<-- info{type, XPORT_UIO, uio_route}                      |
     |                                                          |
     | attrs = p2pdma_map_attrs(&info, prov)   /* HDM: 0x4000 */|
     | dma_map_phys(dev, prov->base + off, len, attrs)          |
     | ... hardware territory: TC3 queues, 256B-bounded         |
     |     requests, completion counting (Part I) ...           |

Every enable is reference-counted per device (vc_users, req_users,
hdm_users), so overlapping routes share hardware state and only the
last release of a role actually clears it.

18. Role programming order (commit / unwind / teardown)
-------------------------------------------------------

  COMMIT (leaf -> requester)        TEARDOWN / REVOKE (requester 1st)
  1. target endpoint VCs            1. DevCtl3.REQ_EN clear
  2. UIO-to-HDM gates (DSPs)        2. requester VC
  3. hop VCs (traversed links)      3. hop VCs          (each step
  4. requester's own VC             4. gates             refcounted;
  5. DevCtl3.REQ_EN                 5. target VCs        only cleared
                                                         when no
  commit failure at any step:                            surviving
  unwind exactly the enables        route needs it)
  taken so far, reverse order

  "hop VCs" covers only ports whose Link the route traverses: VC
  enable is per-Link, both-partners state (7.9.29.7/.8) - enabling
  one side leaves VC Negotiation Pending set forever. A USP that
  merely tops an in-fabric path (peer traffic turns at the switch's
  internal bus; its external Link is unused) is left untouched.

Why this order is load-bearing:

   - a requester left enabled past its routing emits TLPs the fabric
     drops silently (sec 7): so the requester enable is always the
     LAST thing set and the FIRST thing cleared
   - a completer-side gate dropped under live mappings produces
     completions nobody is counting: so completer-side state goes
     up first, down last

19. SVC programming and VC ownership
------------------------------------

Per-port VC bring-up at route commit, under OS ownership:

   Port Status: Use VC/MFVC set?    (port also has legacy VC/MFVC)
        | yes: write 1 to clear  -- ONE-WAY until Conventional
        |      Reset; kills all VC/MFVC enables, brings up SVC VC0.
        |      Done only when a route actually commits - never as
        |      a probing side effect.
        v
   Resource Control [VC3]:
        TC/VC map    = BIT(3)      (TC3 -> this VC)
        protocol     = 0010b       (UIO)
        VC Enable    = 1
        v
   Port Control: VC Enablement Completed = 1
        v
   poll Resource Status: VC Negotiation Pending == 0
        (both link partners bring the VC's flow control up)

Programmed on every routing hop, every target endpoint, and the
requester - VC enablement is a both-link-partners property, and
TC/VC mapping lives in the Port containing the Function (sec 6).

Ownership is per host bridge:

   OS        (default; pci_host_bridge.native_svc = 1; no _OSC bit
              is defined yet)          -> kernel programs SVC
   PLATFORM  (fabric-manager-owned multi-host fabrics; the spec's
              guidance: preserve preconfigured TC/VC assignments)
                                       -> identical walk, VERIFY-ONLY
   NONE      (no host bridge)          -> no route ever validates

FLR asymmetry (PCIe 6.4 sec 6.6.2) that revocation leans on: SVC
registers are FLR-exempt - fabric VC config survives a function
reset - while DevCtl3.REQ_EN is not, so emission permission dies
with the function and is only ever re-granted by a fresh route.

20. DMA layer: DMA_ATTR_UIO
---------------------------

DMA_ATTR_UIO (bit 14) is a pure annotation on the phys-addr mapping
entry points (dma_map_phys / dma_iova_link): it grants nothing,
orders nothing, never blocks. Legality comes from the route the
caller must hold. No lowering changes: cache maintenance decisions
remain keyed to DMA_ATTR_MMIO.

The orthogonality that everyone gets wrong:

    DMA_ATTR_MMIO  = address-form/cacheability axis
                     "this is BAR MMIO: never CPU-cacheable, skip
                      cache maintenance"
    DMA_ATTR_UIO   = transport axis
                     "the device may use unordered semantics here"

                  |  no route          |  route held
    --------------+--------------------+----------------------
    BAR MMIO      |  MMIO      (0x400) |  MMIO|UIO    (0x4400)
    CXL HDM       |  (none)    (0x0)   |  UIO         (0x4000)
    --------------+--------------------+----------------------

CXL HDM may be HOST-CACHEABLE: deriving MMIO from "it's peer-to-
peer" would skip cache maintenance the mapping needs. Hence
p2pdma_map_attrs() centralizes derivation - MMIO from the provider
TYPE only, UIO from a held route only - so no consumer hand-rolls it.

dma-debug (CONFIG_DMA_API_DEBUG) enforces the contract:

   route commit registers the covered (device, range);
   route release/revoke unregisters it. Then:
   - DMA_ATTR_UIO mapping with no covering registration  -> warn
   - DMA_ATTR_UIO against page-backed, non-reserved RAM  -> warn
     (host-memory UIO is deliberately unsupported for now)
   - unmap attrs != map attrs (UIO joined the match set) -> warn

Unmap contract: the DMA core never fences UIO. "Stop DMA before
unmap" is the standard rule; UIO makes "stopped" precise - all
completions accounted by the requester - and it stays the driver's
obligation to check.

21. P2PDMA: typed providers, transfer plans, policy
---------------------------------------------------

The provider says what kind of memory it exposes; addressing stays
base + offset either way (type is data, not behavior):

   PCI_BAR_MMIO (=0, so zero-initialized providers keep their old
                 meaning)   BAR window; bus_offset = CPU->bus delta
   CXL_HDM                  committed region; base = region HPA;
                            bus_offset = 0 - peers emit host
                            physical addresses, switch HDM decoders
                            route by HPA

   flags: UIO_COMPLETER     set iff the range may legally terminate
                            UIO (BAR: DevCap3.CPL; region: uio=1)
   range_validate()         NULL = whole range, one implicit target.
                            Interleaved regions supply it; it
                            returns the exact endpoint set of a
                            subrange (all-or-none becomes
                            STRUCTURAL) + the granularity

pci_p2pdma_map_info(provider, dev, off, len, uio_req, &info):

              uio_req && policy != FORBIDDEN?
                   |                    \ no
                   v                     v
           pci_uio_route_get()      ordered classification
             |            |         (worst-case across the
            ok          fail        subrange's target set;
             |            |         CXL_HDM ordered is always
             |     REQUIRED: return  host-mediated: in-fabric
             |       rc, no plan     ordered P2P into HDM is
             |     PREFERRED: fall   not defined transport)
             |       through to
             |       ordered  ------------^
             v
      info.type  = IN_FABRIC ? BUS_ADDR(3) : THRU_HOST_BRIDGE(4)
      info.xport_flags |= XPORT_UIO
      info.uio_route = ref (caller puts it after the final unmap)

Observed plans (from the test suite):

                              info.type            xport   route_flags
   t2  in-fabric route        BUS_ADDR (3)         UIO     0x1
   t1  thru-RP route          THRU_HOST_BRIDGE (4) UIO     0x2
   HDM, no route (FORBIDDEN)  THRU_HOST_BRIDGE (4) -       -
   unreachable peer           NOT_SUPPORTED (2)    -       -

PREFERRED's fallback is a NEW ordered plan derived from scratch -
possibly a different address form - never an attribute-stripped copy
of the UIO plan.

22. CXL provisioning and decoder programming
--------------------------------------------

Region attributes (pre-commit only; immutable after, including the
RESET_PENDING window - teardown accounting keys off p->uio):

   uio         0/1   provision the region as a UIO Direct P2P target
   uio_policy  forbidden|preferred|required (default required) -
               advisory to consumers picking their route policy

Commit-time gates for uio=1 (all EOPNOTSUPP, failing hop named via
dyndbg):

   region is HDM-DB           DEVMEM type + root decoder BI window
   Standard Modulo window     XOR/CXIMS arithmetic is ineligible
   ways in {1,2,4,8,16}       3/6/12-way arrangements cannot be UIO
                              targets (CXL r4.0 sec 9.16)
   every target bi && uio     all-or-none across the interleave set
   uplink segment routable    flit + SVC-with-UIO-VC on each hop of
                              each target's own uplink - fail-fast
                              for the admin; pci_uio_route_get()
                              remains the authoritative gate

Decoder programming at commit (cxld_set_uio(), values computed at
target setup):

   switch/HB decoder:  UIO=1
                       UIG = region granularity        (encoded)
                       UIW = position bits consumed ABOVE this port
                             = (parent_eig + parent_eiw) - region_eig
                       ISP = endpoint position modulo upstream ways
   endpoint decoder:   UIO=1; ISP = the device's region position,
                       programmed with the BI bit - ISP is
                       BI-capable-device state (BISnp DPA->HPA)
                       that UIO merely reuses. UIG/UIW stay
                       reserved for devices.

   switch/HB "UIO Capable Decoder Count": counted per committed
   UIO decoder; exceeding the cap fails that decoder commit (ENXIO).
   Devices must not limit (refused at setup, sec 16).

23. The region as a provider: subrange decode
---------------------------------------------

The committed region embeds its typed provider (sec 15). Its
range_validate() answers "which endpoints does [hpa, hpa+len)
actually touch":

   len >= ways * granularity   -> every position
   else: for each granule-aligned address in the window:
             pos = cxl_calculate_position(addr - region_base)
             pos_map |= BIT(pos)
   pos_map -> targets[] = pci_devs of exactly those endpoints
            + interleave_granularity (clamps the route boundary)

   examples (2-way, 256B):        (4-way, 256B):
     [0x000,0x100) -> {0}    1      [0x000,0x100) -> {0}       1
     [0x000,0x200) -> {0,1}  2      [0x000,0x300) -> {0,1,2}   3
     [0x080,0x180) -> {0,1}  2

A route binds to every endpoint the range decodes to, or to none -
the all-or-none rule is enforced by construction, not by caller
discipline.

24. Lifecycle: probe to teardown
--------------------------------

  probe        cxl_pci/cxl_mem probe
    |            cxl_bi_setup()          BI enabled on the path
    |            cxl_hdm_uio_setup()     cxlds->uio latched (static
    |                                    capability; nothing enabled,
    |                                    nothing to tear down)
    v
  provision    region created; uio=1 pre-commit; commit:
    |            gates checked, decoders programmed (UIO, UIG/UIW/
    |            ISP), region becomes a typed provider
    v
  acquire      pci_p2pdma_map_info() -> pci_uio_route_get():
    |            path validated; gates + VCs + requester enable
    |            committed leaf-to-requester
    v
  map          dma_map_phys(..., DMA_ATTR_UIO [| MMIO for BAR])
    |            dma-debug: covered by the route registration
    v
  transfer     hardware territory (Part I: counting, boundaries)
    |
    v
  teardown     1. driver stops new submissions
    |          2. requester drains outstanding UIO completions
    |          3. dma_unmap_phys()        (core never fences; step 2
    |                                      made "stopped" precise)
    |          4. pci_uio_route_put()     final put drops requester
    |                                     role first, then leaf-ward
    |          5. region uncommit         provider dies; any route
    |                                     still alive is force-
    v                                     revoked first (sec 25)

25. Revocation
--------------

     device_del      FLR / reset      DPC/AER          region
     (hot-remove)    preparation      recovery         uncommit
         |               |               |                |
         v               v               v                v
    pci_stop_dev   pci_dev_save_   pcie_do_recovery  cxl_region_
         |         and_disable     (whole subtree     decode_reset
         |               |          below the         (per target)
         |               |          recovering            |
         +-------+-------+------------ bridge) -----------+
                 v
      pci_uio_route_revoke_dev() / _revoke_subtree()
                 |
        for every route involving the device:
          1. generation++, revoked = true
             (pci_uio_route_valid() now false - hot-path cheap)
          2. ops->quiesce(route)   stop submissions, drain UIO
                                   completions, suppress dependent
                                   doorbells of failed batches
          3. drop roles, requester FIRST (sec 18), refcounted
             + dma-debug coverage unregistered
          4. ops->revoke(route)    all mappings under it are dead
          5. references drain via pci_uio_route_put()

      final device destruction (pci_destroy_dev) additionally reaps
      the per-device enable-count state; FLR/reset deliberately do
      not - the device survives and its counts stay live.

The quiesce/revoke ops are optional for trusted in-kernel consumers
whose teardown already quiesces their engines, and mandatory when
userspace drives the requester (DMABUF exporters map move_notify
onto them).

26. Worked example A: the t2 fabric, register by register
----------------------------------------------------------

The suite's happy-path topology, with everything the kernel
programmed and when (guest BDFs as observed):

                pxb-cxl host bridge (bus 0c)
                (no UIO decode capability - a 2-HB
                 region would fail here: see t8)
                          |
            +-------------+-----------+
            | cxl-rp rp0        0c:00.0
            | SVC: VC3 proto=UIO (capability; on the
            |      in-fabric path below, rp0 is never
            |      traversed - traffic turns at us0)
            +-------------+-----------+
                          |  link: flit
            +-------------+-----------+
            | cxl-upstream us0  0d:00.0
            | HDM decoder cap: UIO=1, count=4
            | switch decoder0: range=region HPA,
            |   IW=2 IG=256B  (own decode: addr[8])
            |   UIO=1, UIG=0, UIW=0, ISP=0   <- region commit
            | SVC: capability verified, VCs UNTOUCHED - the
            |   in-fabric route never uses us0's upstream Link
            |   (VC enable is both-Link-partners state)
            +---+---------------------+------+
                |                     |
   +------------+--------+  +---------+-----------+
   | cxl-downstream dsp0 |  | cxl-downstream dsp1 |
   | 0e:00.0             |  | 0e:01.0             |
   | PortExt DVSEC ctl   |  | PortExt DVSEC ctl   |
   |   bit4 UIO-to-HDM=1 |  |   bit4 UIO-to-HDM=1 |  <- route commit
   | SVC VC3 ENABLED     |  | SVC VC3 ENABLED     |  <- route commit
   +------------+--------+  +---------+-----------+
                | flit                | flit
   +------------+--------+  +---------+-----------+
   | cxl-type3 mem0      |  | cxl-type3 mem1      |
   | 0f:00.0  (target)   |  | 10:00.0 (requester) |
   | DevCap3: CPL,REQ,   |  | DevCap3: CPL,REQ,   |
   |   14bTagCpl (HwInit)|  |   14bTagCpl (HwInit)|
   | HDM dec cap UIO=1   |  | ATS capable         |
   | decoder0: UIO=1,    |  | SVC VC3 ENABLED     |  <- route commit
   |   ISP=0 (w/ BI bit: |  | DevCtl3.REQ_EN=1    |  <- route commit
   |   BISnp DPA->HPA)   |  |                     |
   |     <- region commit|  |   (first route sets,|
   | SVC VC3 ENABLED     |  |    last put/revoke  |
   |     <- route commit |  |    clears)          |
   +---------------------+  +---------------------+

   who programs what:
     HwInit / static        role caps, decoder capability bits
     region commit          decoder UIO + UIG/UIW/ISP (us0);
                            decoder UIO + ISP-via-BI (mem0)
     route commit           SVC VCs on traversed-Link ports and
                            endpoints, DSP gates, REQ_EN

   route observed by the consumer: rc 0, map_type 3 (BUS_ADDR),
   xport_uio 1, flags 0x1 (IN_FABRIC), 3 hops {dsp1, us0, dsp0},
   1 target, tc3/vc3, boundary 256, granule 64, attrs 0x4000.

27. Worked example B: one UIO write, end to end
-----------------------------------------------

mem1 writes into region0 (HPA H owned by mem0), then a doorbell:

  mem1 engine   UIOMWr, addr=H (AT=translated via ATS), len<=256B,
      |         TC3, Tag from the shared Group II pool
      |         emission gate: DevCtl3.REQ_EN && Bus Master Enable
      v
  dsp1 ingress  rides VC3 (TC3 mapped there by the route)
      |         evaluate vs us0's HDM decoders:
      |           range hit + AT ok + position match -> COMPLETE
      |           UIO-to-HDM gate=1 -> forward to owning peer DSP
      |                                (ACS is architecturally
      |                                 bypassed for this step)
      v
  us0 decode    own IW/IG decode: addr[8] -> dsp0
      v
  dsp0 egress   VC3; gate=1
      v
  mem0 device   decoder0: complete match incl. the in-granule
      |         length rule -> HPA->DPA -> commit to media
      |         (a granule-straddling request would land here as
      |          a partial match: Completer Abort, no data)
      v
  UIOWrCpl(s)   flow back mem0 -> dsp0 -> us0 -> dsp1 -> mem1,
                any order, possibly coalesced per Transaction ID
      v
  mem1 engine   DW counter for the ID balances
                -> NOW the doorbell write is released (and may
                   itself be UIO or ordered - requester's choice)

Failure branches at each stage map to Part II sec 12; the kernel's
job ended when the fabric state above was proven and programmed.

28. Worked example C: interleave math in bits
---------------------------------------------

Case 1 - t2: 2-way, 256B granularity, one switch, one HB.

   encoded: region eig=0 (256B), eiw=1 (2 ways)
   position field: addr[eiw+eig+7 : eig+8] = addr[8]

        HPA:   ...[ upper ][ b8 ][ b7..b0 ]
                            |
                            +-- granule parity: 0=mem0, 1=mem1

   endpoint decoders (IW=2, IG=256B):
      mem0: ISP=0  -> owns even granules
      mem1: ISP=1  -> owns odd granules
      device check: addr[8]==ISP  AND  offset+len within 256B

   switch decoder (us0): own decode IW=2 IG=256B -> route by b8.
   UIO reverse-decode fields: what interleaves ABOVE us0? Nothing
   (single HB, root ways=1):
      UIW = (parent_eig + parent_eiw) - region_eig = (0+0)-0 = 0
      -> trivial match: any in-range address is "below me"

Case 2 - t6: 4-way under one switch.

   eig=0, eiw=2; position field addr[9:8]; endpoint ISPs 0..3;
   switch still UIW=0 (nothing above), own decode IW=4 by
   addr[9:8]. Subranges: 1 granule -> 1 target, 3 granules -> 3.

Case 3 (hypothetical - why UIW/ISP exist): 4-way total across TWO
host bridges, one switch per HB, 2 devices per switch, 256B gran.

   aggregate: eiw=2, position field addr[9:8]
   root (CFMWS): 2 HBs, IG=256B  -> consumes addr[8]
   each switch:  IW=2, IG=512B   -> consumes addr[9]

   switch-under-HB0 decoder UIO fields:
      UIG = region granularity   = 0   (256B)
      UIW = bits consumed above  = 1   (the root's addr[8])
      ISP = 0    (HB0 gets the addr[8]==0 granule columns;
                  its endpoints hold region positions 0 and 2,
                  both == 0 mod 2)
   switch-under-HB1: ISP = 1.

   Now a requester below HB0's switch targets a granule with
   addr[8]==1: range hits, but position != ISP -> PARTIAL match
   -> with gate=1, the DSP forwards TOWARD THE HOST, which routes
   it down HB1. That is exactly the spec's "UIO Target 3/4 via the
   host" split (sec 8): direct in-fabric routing where the decoders
   prove ownership, host-mediated everywhere else - decided by
   three small fields per decoder.

29. Observability and the test suite
------------------------------------

  /sys/kernel/debug/pci_uio/capabilities   per-function roles
  /sys/kernel/debug/pci_uio/routes         live routes + hops
  /sys/kernel/debug/pci_uio/vc_ownership   per host bridge
  /sys/bus/cxl/devices/regionN/uio, uio_policy
  /sys/bus/cxl/devices/decoderX.Y/uio, cap_uio
  /sys/kernel/debug/cxl_uio_test/*         the test consumer
  dmesg with dyndbg on drivers/pci/uio.c + p2pdma.c + cxl:
                                           every rejected gate
                                           names its hop

  Suite (~/code/uio-tests, all green as of this writing):
    t1 direct-attach 7   t2 switch happy path 43+4 hot-remove
    t5 no-UIO device 2   t4 no SVC 1     t3 non-flit uplink 1
    t6 4-way 6           t7 no ATS 3     t8 cross-RP 4

30. Consumer models: DMABUF, iommufd, RDMA
------------------------------------------

The cxl_uio_test module is a stand-in. Every real consumer follows
the same five verbs; what differs is who plays the requester, where
the mappings live, and how revocation lands in that subsystem's own
invalidation machinery:

   provider = <get typed provider>          exporter side
   pci_p2pdma_map_info(prov, dev, off, len,
                       {policy, ops}, &info) importer core
   attrs = p2pdma_map_attrs(&info, prov)
   dma_map_phys(dev, base+off, len, attrs)   + DMA_ATTR_UIO
   ... traffic (hardware counts) ...
   quiesce -> drain -> unmap -> route_put    reverse order, always

DMABUF - the natural exporter/importer fit

   exporter (CXL region driver,          importer (RNIC, GPU,
     or a driver exporting a BAR)          accelerator driver)
        |                                     |
        |<---- dma_buf_attach (dynamic) ------|
        |                                     |
        | map_dma_buf(attach):                |
        |   pci_p2pdma_map_info(prov,         |
        |     importer_dev, off, len,         |
        |     {REQUIRED, ops}, &info)         |
        |   attrs = p2pdma_map_attrs()        |
        |   dma_map_phys(...)                 |
        |----- mapped ranges + limits ------->|
        |                                     | ...DMA...
        | route ops.quiesce/revoke fire       |
        |----- move_notify ------------------>| stop + drain,
        |      (mapping is now dead)          | unmap, later
        |                                     | re-attach/re-map

   The route ops are dmabuf's move_notify contract with the names
   changed: quiesce = "stop DMA and drain before returning", revoke
   = "the mapping is invalid until you re-map" (pci-uio.h says
   exactly this). Consequences:
   - only DYNAMIC importers may hold UIO plans; a pinned importer
     that cannot accept move_notify gets the ordered plan instead
   - re-map after revocation re-acquires a route: a fresh validate
     against whatever the fabric looks like now
   - CXL HDM export needs no struct page/pgmap: the provider is
     (base, size), which matches dmabuf's phys-range direction

iommufd - user-driven requesters

   The requester belongs to userspace (VFIO/vDPA device); iommufd
   owns its IOMMU domain and IOVA space. Peer memory arrives as a
   dmabuf mapped into an IOAS; at map time iommufd is the importer
   acquiring the route for (device, provider range) and installing
   IOVA -> HPA.

   The AT=Translated requirement (sec 12) is what makes this safe:
   the device must resolve IOVA -> HPA through ATS before emitting
   UIO, so the IOMMU stays the translation authority even though
   in-fabric traffic never crosses the root complex. What stands
   between a user-owned device and peer memory is exactly
   ATS + the route's containment gates - REQUIRED policy,
   fail-closed, no route -> no UIO emission permission at all.

   Revocation lands as: quiesce/revoke -> zap the IOAS mapping,
   block device DMA, surface an event to userspace; device or
   target hot-remove kills the route first (sec 25), then the
   mapping teardown finds it already dead.

RDMA - requester-side accounting is native territory

   RNICs already import peer memory via dmabuf MRs
   (ib_umem_dmabuf), so an MR registered over an exported CXL
   region rides the DMABUF flow above unchanged - verbs
   applications never see a difference.

   The deeper fit is ordering: RDMA's completion rules (no CQE, no
   RDMA-layer ack until payload placement) are the flag/doorbell
   pattern of sec 2. A UIO-capable RNIC holds CQE generation until
   the UIO completions for the WQE's payload balance - per-WQE
   completion accounting is what RNIC hardware does all day, which
   is why requester-enforced ordering suits it. Revocation maps to
   the existing dmabuf-MR invalidation: flush affected QPs,
   invalidate the MR, re-register later.

   Use cases this unlocks: NVMe-oF/storage staging straight into
   CXL HDM (NIC writes far-memory tier without a host-RAM bounce),
   RDMA access to pooled CXL memory across the fabric.

   consumer   requester dev    provider           revocation binding
   --------------------------------------------------------------
   dmabuf     importer's dev   exporter (region   move_notify <->
                               or BAR)            quiesce+revoke
   iommufd    user-owned dev   dmabuf in IOAS     zap mapping +
                                                  userspace event
   RDMA       the RNIC         dmabuf MR over     MR invalidate +
                               a CXL region       QP flush
   nvme       the controller   CMB (BAR) or       driver teardown
                               region             (trusted, in-kernel)

Status: none of these integrations ship in this series - the
contract (typed pgmap-free providers, policy + ops in the map_info
call, revocable routes) was shaped so each lands without reshaping
the API, and the route-ops/move_notify equivalence is already
documented in pci-uio.h.

====================================================================
APPENDIX
====================================================================

A. errno map
------------

   -EOPNOTSUPP (-95)  capability / flit / VC / ACS / ATS / policy
                      gate failed; the hop is named via dyndbg
   -ENXIO      (-6)   UIO decoder count exhausted; region config
   -ENODEV     (-19)  actor going away; bad BDF/region (consumer)
   -EBUSY      (-16)  post-commit attribute writes; ordering
   -EINVAL     (-22)  malformed range / tc / vc / policy

B. Deliberate deferrals
-----------------------

   - _OSC ownership negotiation: native_svc defaults to OS-owned;
     the PLATFORM verify-only path is in place for when a bit lands
   - multipath / non-tree fabrics: PCI_UIO_ROUTE_MULTIPATH reserved
   - host-memory UIO: no IOMMU/cache-maintenance story yet;
     dma-debug warns on any attempt
   - large_uio (256B boundary disable): never set
   - XOR/CXIMS windows: rejected at provisioning; QEMU cannot
     emulate them, so the rejection is verified by inspection
   - DPC-driven revocation: entry point wired via pcie_do_recovery,
     exercised in tests via hot-remove/FLR (QEMU lacks DPC)
   - suspend/resume: SVC registers and DevCtl3 are not yet in the
     PCI save/restore set; D3cold loses route hardware state (the
     FLR exemption does not cover cold transitions)
   - vfio guests: bumping PCI_EXT_CAP_ID_MAX makes config-space
     virtualization hide SVC from guests (fail-closed for a
     host-owned VC resource)
   - PBR fabrics: G-FAM/LD-FAM routing uses FAST/LDST segment
     decoders (Fabric Address Segment Table, CXL r4.0 sec 7.7.9)
     configured by the Fabric Manager over CCI, not the HDM
     decoder registers this series programs. Out of scope; the
     provider addressing contract (peers emit HPAs, bus_offset=0,
     "HDM/FAST decoders route by HPA") was chosen so PBR slots in
     without changing the model

C. Spec cross-reference
-----------------------

   kernel construct                        authority
   -------------------------------------------------------------
   PCI_EXT_CAP_ID_SVC 0x35 + layout        PCIe 6.4 sec 7.9.29
   DevCap3/DevCtl3 UIO bits                PCIe 6.4 sec 7.7.9
   14-bit tag rules (UIO-only size)        PCIe 6.4 sec 2.2.6.2
   TC3/VC3 (+TC4/VC4) UIO defaults         PCIe 6.4 Table 2-46
   limits.update_granule = 64              PCIe 6.4 sec 2.4.4.2
   limits.boundary = 256                   PCIe 6.4 sec 7.7.9.3
   FLR: SVC exempt, REQ_EN not             PCIe 6.4 sec 6.6.2
   VFs must not implement SVC              PCIe 6.4 SR-IOV rules
   HDM Decoder Capability UIO/count        CXL r4.0 Table 8-116
   decoder UIO/UIG/UIW/ISP                 CXL r4.0 Table 8-123
   UIO tag rules (no enables apply)        PCIe 6.4 sec 2.2.6.2.2
   WCB 64B / switch no-coalesce            PCIe 6.4 sec 2.3.1.3
   ways {1,2,4,8,16}, Standard Modulo      CXL r4.0 sec 9.16
   BISnp validated by USP decoders         CXL r4.0 Table 9-13
   forwarding rules + ACS bypass           CXL r4.0 Table 9-18
   UIO To HDM Enable (DSP-only RW)         CXL r4.0 Table 8-32
   address match (incl. AT=translated)     CXL r4.0 sec 9.16.1.x

D. File map
-----------

   new
     drivers/pci/uio.c              discovery, routes, revocation
     include/linux/pci-uio.h        public API (route/policy/limits)
     drivers/cxl/uio_test.c         debugfs test consumer
   modified
     include/uapi/linux/pci_regs.h  SVC map; DevCap3/Ctl3 UIO +
                                    14-bit tag bits; CXL port ctl b4
     include/linux/pci.h            capability fields; native_svc
     drivers/pci/probe.c            pci_uio_init(); native_svc dflt
     drivers/pci/remove.c, pci.c,
     drivers/pci/pcie/err.c         revocation hook points
     drivers/pci/p2pdma.c           typed providers, map_info,
     include/linux/pci-p2pdma.h       policy, attrs helper
     include/linux/dma-mapping.h    DMA_ATTR_UIO
     include/linux/dma-map-ops.h    dma_debug_uio_range_{add,del}
     kernel/dma/debug.c             coverage/misuse/mismatch checks
     drivers/cxl/cxl.h, cxlmem.h,
     include/cxl/cxl.h              UIO regs, region params, state
     drivers/cxl/core/pci.c         cxl_hdm_uio_setup, segment check
     drivers/cxl/core/hdm.c         decoder programming, count cap
     drivers/cxl/core/region.c      gates, provider, subrange decode
     drivers/cxl/core/port.c        decoder sysfs
     drivers/cxl/mem.c              probe hook
     Documentation/                 dma-attributes.rst, sysfs-bus-cxl
