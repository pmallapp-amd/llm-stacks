# TODO

Working task list. Last updated 2026-09-30.

## ✅ SETUP 3 (2026-09-30): the same stack, over the Linux kernel NVMe-oF driver — UP and PROVEN

**This is a DIFFERENT LAB from everything below.** Branch `setup-3-nvmeof`,
config `creds/setup-3.env` (driven via `CREDS_FILE=`, deliberately not wired
to the shared `creds/active.env`). Full record: **[HANDOFF §0](HANDOFF.md#0-setup-3--the-kernel-nvme-of-lab-2026-09-30)**.
Everything from §0 of this file onward is setup 4 and its Pensando DSC.

Setup 3 has **no DSC NVMe function at all**; the KV namespace is remote and
the stock kernel `nvme_tcp` driver reaches an SPDK `bdev_kvmalloc` target at
`10.235.200.144:4420`. P/D disaggregated, LMCache in MP mode, TCP transport.

**Verify ladder:** 20 **6/6** both nodes · 30 **PASS cross-node** with
negative control · 35 **8/8** · 40 **9/9** (hit-token metric `NA`, so it
proves the pipeline not caching) · 50 **9/9** (hit rate 0.0%→100.0%, decode
prompt throughput 0.0) · 60 **9/11**, the documented `--no-drain` target, with
step 5 green: `l2_device_hits=4`, `l2_index_hits=0`, **token identity matched**.

**The root cause worth carrying to any lab:** the KV tier stored perfectly and
missed 100% of lookups because the container lacked **`CAP_SYS_ADMIN`**. The
kernel gates NVMe passthrough by opcode, and the KV set overlaps NVM opcodes —
`KV_STORE`(0x01)/`KV_RETRIEVE`(0x02) alias write/read and are allowed, while
`KV_EXIST`(0x14)/`KV_DELETE`(0x10) are denied with `-EACCES`. Since
`queryMem()` degrades errors to "absent", there is no error to find. Fixed in
`container.sh`. HANDOFF §0.3.

**Shared-host port traps** (the neighbouring `aic-*` stack owns them):
`LMCACHE_MP_HTTP_PORT` 8080→**8081** — a failed HTTP bind kills the whole
daemon *after* `start-vllm.sh`'s gate passes — and NIXL side channels
5600/5601→**5610/5611**. Rung 60 hardcoded `:8080` and would have scraped the
other stack's counters; it now reads the variable. **Check ports with an
anchored `awk` match** — `grep -w ":8080"` returned false "free" for all of
them. HANDOFF §0.4.

**Open on setup 3:** RDMA (not attempted; fabric looks healthy, pins recorded),
rung 60 step 7's drain control (VOID by construction), and
`l2_commit_writes=0` at step 2 despite step 5's confirmed device hits.

---

## How to use this list

IDs are **stable** — reference an item by number ("do 2.4", "what blocks 3.1").
New work appends; existing IDs are never renumbered. Check the `blocked by`
note before starting anything.

Status: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked on someone else

## Status summary

| § | Area | Items | Done | Blocked |
|---|---|---|---|---|
| 0 | Blocking decisions and follow-ups | 4 | 2 | 2 |
| 1 | Architecture correction (compute leg) | 14 | 12 | 0 |
| 2 | Hardware bring-up (Phase 1, TCP) | 13 | 6 | 2 |
| 3 | Acceptance (Phase 2, RDMA compute leg) | 10 | 4 | 0 |
| 4 | Open items and known limitations | 6 | 2 | 0 |
| 5 | Done | 14 | 14 | — |
| 6 | Storage-tier integration (XNVME_KV / SPDK_NVMe_KV as an LMCache tier) | 47 | 34 | 6 |

Counts are per **ID**, so §6's include its `###` subsections (6.23–6.47), not
just its checkbox bullets — a subsection counts as Done when its heading says
so (`✅`, CLOSED, ANSWERED, PROVEN). §6's row had drifted, reading 28/18: that
was correct through 6.28 and was never updated as 6.29–6.33 were appended.
**Recounted 2026-09-18: 6.34 flips to `✅`, one more than the row it
replaces. Recounted again 2026-09-21: 6.41 flips to `✅`, one more
again. Recounted a third time, same day, 2026-09-21: 6.42 flips to
`✅`, one more again. Recounted a fourth time, same day, 2026-09-21,
a second session after a full teardown/rebuild: 6.43 flips to `✅`,
one more again. Recounted a fifth time, 2026-09-22, after the
principal's driver/software update: 6.44 flips to `✅`, one more
again. Recounted a sixth time, same day, 2026-09-22, after the
principal's 400G config: 6.45 is appended and Items goes 44 → 45 —
but 6.45 records an OPEN problem (no `🔴`/`✅` resolution, the
auxiliary-bus RDMA gap), so it does NOT flip to `✅` and Done stays
at 33. Recounted a seventh time, 2026-09-25, after a reboot cleared
the auxiliary-bus RDMA gap and a new decode-side blocker surfaced:
6.46 flips to `✅` (Done 33 → 34, the RDMA/fabric chain resolved for
this boot) and 6.47 is appended as a new OPEN problem (the
`ipc_wrapper.py:85` LMCache IPC OOM, no `✅` resolution), so Items
goes 45 → 47 while Done stays at 34.** Recount from the IDs when you
add one. On
2026-09-21 a status audit also closed two items outside §6: **3.2**
(§3: 3->4 done, all three RDMA-device conditions verified) and
**4.3** (§4: 1->2 done, superseded by 6.29/6.41 rather than answered
as originally framed).

**Read [HANDOFF §3](HANDOFF.md#3-how-to-resume) first** — it carries the
cluster state as handed over and the ordered resume plan. This file is the
task index.

## Current state (2026-09-25): the auxiliary-bus RDMA gap below is CLEARED post-reboot — all 8 `ionic_N` devices register — but the blocker moves to a decode-side LMCache IPC KV-cache registration OOM, root cause NOT established

**Supersedes the 2026-09-22 block immediately below for the RDMA/fabric
chain — read that block for how the fabric got here, this one for
where it stands now.** Decode host rebooted 2026-09-25 05:50:43 UTC
(`/proc/cmdline` still carries `modprobe.blacklist=amdgpu`; hand-loaded
06:09:32 — TODO 0.4, unchanged, required every boot).

- **RDMA device registration: CLEARED (MEASURED).** All 8 `ionic_N` IB
  devices register and port 1 is ACTIVE (state 4) on both nodes;
  `/sys/bus/auxiliary/devices/` now carries `ionic.rdma.0`–`.7` where
  6.45 found only `pds_core.fwctl.0`–`.7`. Full record: 6.46.
- **RoCE pin re-confirmed but the netdev mapping DRIFTED again:** both
  roles pinned `ionic_7:1` (`config/cluster.env`); the `ionic_N` →
  `benicNp1` mapping recorded at 2.8/6.44/6.45 is **not** what this boot
  shows — this boot maps `ionic_N` → `benic(N+1)p1` on both hosts. The
  same-plane property the pin depends on still holds; the index
  mapping does not, and must be re-verified every boot (2.8).
- **SRQ (3.9) is still PENDING RE-CONFIRMATION** — not re-queried this
  session; do not assume 6.44's `max_srq=512` result survived two
  further config changes and a power cycle.
- **RoCEv2 remains NOT demonstrated.** No RDMA bytes carried, no
  throughput figure — prefill reports `p2p_state="unregistered"`,
  `p2p_peer_count=0`, because decode never reached a healthy serving
  state.
- **The blocker is now decode-side, not fabric-side.** The LMCache MP
  daemon OOMs registering the KV cache at
  `lmcache/v1/platform/cuda/ipc_wrapper.py:85` — a genuine ROCm/HIP
  allocation failure (verified via the raw runtime trace, not a
  mistranslated HIP error), followed by a downstream vLLM `EngineCore`
  segfault during HSA teardown. **Root cause is NOT established** — six
  candidate causes are eliminated (kernel OOM, HBM capacity, GPU VA
  exhaustion, `HSA_ENABLE_IPC_MODE_LEGACY`, a ROCm `dma_buf` IPC leak,
  container/host ROCm skew) plus a seventh (cross-process IPC transport
  as a sufficient cause). Full elimination record, the naming caveat
  (this is ROCm/HIP throughout, not NVIDIA CUDA, despite the
  identifiers), and the named next experiment: `docs/TROUBLESHOOTING.md`'s
  `ipc_wrapper.py:85` entry, and TODO 6.47.

---

## ✅ Current state (2026-09-22): the 400G config brings the fabric UP and makes addressing persistent — but zero RDMA devices register, and a power cycle was in progress when the session ended

**Later the same day, the principal applied a new 400G config and
rebooted** (`smc1` up 11:54:12, `smc2` up 11:54:07). This supersedes
the SRQ/PCI-move/links-down update below. Full record at 6.45:

1. **All 8 fabric links are UP on both nodes.** `carrier` reads
   `11111111`/node and `benic1p1 speed` now reads **400000** — it
   read `800000` before this config change, which was the suspected
   and now effectively confirmed cause of the earlier link failure.
2. **Fabric addressing now PERSISTS across a reboot** — 8 `benicNp1`
   addresses and 16 `30.x` routes present on both nodes with no hand
   re-application, unlike earlier the same day (below). Remove the
   "must re-apply by hand every boot" instruction where it appears.
3. **`/dev/ng1n1` survived the reboot on both nodes** with no manual
   PCI rebind — **observed once, NOT yet established as reliable**;
   6.26's boot-race has a long history and one clean boot does not
   retire it. Its discovery-by-PCI-class recipe stays the correct
   procedure when the device IS absent.
4. **Zero RDMA devices exist — a DIFFERENT failure from the links.**
   `/sys/class/infiniband/` is **empty**; `ibv_devinfo` returns `No IB
   devices found` (0/8 `PORT_ACTIVE`, `max_srq` unreadable). `pds_core`
   has all 8 PCI devices bound and `ionic_rdma` is loaded (refcount 5,
   logged `AMD Pensando RoCE HCA driver`), but
   `/sys/bus/auxiliary/devices/` holds only `pds_core.fwctl.0`–`.7` —
   **no `pds_core.rdma.N`** for `ionic_rdma.rdma` to bind to. **The
   blocker MOVED from the links to this auxiliary-bus gap.** Most
   plausibly a DSC/DPU-side consequence of the new config, but that
   attribution is **UNPROVEN**.
5. **The SRQ result (`max_srq` 0 → 512) is PENDING RE-CONFIRMATION.**
   It was measured on the PREVIOUS boot, before this config change,
   and could not be re-checked here — no device exists to query. Do
   not assume it survived; re-verify the moment RDMA devices return.
6. **A power cycle was in progress when this session ended.** The
   post-power-cycle state is UNKNOWN and everything above must be
   re-measured.

**This is now the sole thing between this cluster and RoCEv2**: not
the fabric links (fixed) and not the old SRQ capability (unconfirmed
either way) — the missing `pds_core.rdma.N` auxiliary device.

**Earlier the same day, before the 400G config — SRQ unblocked, KV
device at a NEW PCI address, fabric links DOWN:**

**Both nodes rebooted again today** (`smc1` 09:39, `smc2` 09:36) after
the principal updated driver/software. Kernel unchanged
(`6.8.0-139-generic`), `ionic`/`ionic_rdma` unchanged (`26.09.4.001`);
the change is userspace (`rdma-core` now `61.0-1`). Three findings,
full record at 6.44:

1. **3.9's SRQ blocker is LIFTED.** `max_srq` is now **512** on all 8
   devices on both nodes (was **0**, 16/16, yesterday), and UCX's own
   trace confirms it: the rejection reason moved from `does not
   support SRQ` to `is not active (state: 1)`. RoCEv2 for P→D is now
   gated **only** on the fabric links coming up. **Not yet
   demonstrated** — no RDMA traffic has been carried, no throughput
   number exists.
2. **The KV device's PCI function MOVED**, `0000:36:00.0` →
   **`0000:37:00.0`**, on both nodes (`36:00.0` is now the Management
   Controller). Rebind at the new address restored `/dev/ng1n1`
   **instantly** (0.09 s) with identical identity. The fix going
   forward is to discover the address by PCI class, not hardcode it
   (6.26).
3. **The RoCE fabric links are DOWN.** All 8 `benicNp1`/node read
   `NO-CARRIER`; addresses/routes did not survive the reboot and were
   re-applied by hand; the links still show no carrier. `ethtool` now
   reports `800000Mb/s` where it reported `400000` yesterday — an
   **unproven** speed-mismatch hypothesis the host cannot fix.

**This update's own "sole thing" claim above is now superseded** — the
400G config (item 1–6 above it) fixed the links and moved the
blocker again.

**Yesterday's (2026-09-21) recovery, for continuity.** Both compute
nodes had rebooted overnight — `smc1` at 06:36 (4 reboots that day:
03:32, 05:03, 06:24, 06:36), `smc2` at 06:39 (3 that day) — the
hardware owner evidently worked on them; the 2026-09-18 session's boot
had run until 06:22. `smc1` hit the 6.26 boot-time race exactly as
documented (`CSTS=0x0` at 06:36:14), and the documented rebind (at the
address then correct, `0000:36:00.0`) succeeded in **0.08 s** — see
6.26's update, this is not a fixed-cost operation. `smc2` came up with
its KV device already present, no intervention needed. `/dev/ng1n1` was
back on both nodes, `modprobe amdgpu` restored all 8 GPUs/node (0.4's
per-boot ritual, 16 `gfx942` agents/node), and DSC firmware had drifted
again to `1.130.0-pi-131` on both (3.10's update). `smc3` was unchanged
— still shared, still not ours.

**Once the tier was back, the open question that session answered: did
anything written before the 09-18 wedge/reboot cycle survive? No.** Every
historical object probed — from both the pre-fix and post-fix generations
recorded in 6.34 — came back `RESULT:MISS`, on both nodes, against a
control confirming the namespace fingerprint is unchanged. **The Pensando
DSC/DPU KV store is VOLATILE.** Full record, the attribution limit, and
what it changes: 6.41.

**Next:** rung `60`'s drain step (steps 0/7) points at `smc3`'s
`nvmf_tgt`, which 6.36 already showed never held our data — re-target it
(6.41c) before relying on it again. Otherwise 6.15/1.13 (the benchmark
rework) remain the natural next item, now that the tier is proven working
again within this fresh uptime window (6.41e). See HANDOFF §3 for the
current resume plan.

**Before starting anything:** `uptime` on both compute nodes (6.20),
confirm who owns `smc3` (6.18), `modprobe amdgpu` (0.4 — needed every
boot), confirm `/dev/ng1n1` exists on both, and note the LMCache MP daemon
must be up before `start-vllm.sh` will proceed (HANDOFF §1.1, §3.4).
[BRINGUP.md](BRINGUP.md) §1 is this checklist in command-and-expected-
output form.

**Three results from the 2026-09-18 late session, and two are negative:**

- **RDMA RoCEv2 for P→D is not achievable** (3.9). The container had no
  `/dev/infiniband` at all (fixed), and with it mapped UCX still offers
  **zero `rc_verbs`** pairs on ionic — only `ud_verbs`, which fails QP
  creation on all 8 devices. 3.9's proposed "name RC explicitly" fix has no
  target. Driver/provider matter for AMD.
- **KV data does not reach smc3** (6.36, 6.40). `/dev/ng1n1` is a local
  Pensando PCIe function; smc3 has served zero I/O, advertises
  `num_blocks=UINT64_MAX`, and is bounded only by its 62 GiB RAM. The
  re-export model is retracted. **Open: what actually backs the shared
  medium.**
- **The 1 GiB namespace limit was never real** (6.39). It was `nsze × 512`
  arithmetic on a `csi 0x1` namespace with no LBAs; ~1.16 GiB was written
  with zero errors. The DSC's real ceiling is unmeasured.

**Proven and working while the hardware is up:** the full L1 → L2 → device
eviction chain with every level's counters reconciling exactly, a live
cross-node L2 hit, and MP-over-ZMQ confirmed (6.37). Benchmarking is
answerable at the KV-block layer via `lmcache bench l2` (6.35) and at the
engine layer via llama-benchy, both of which needed defects fixed before
they would run at all (6.35, 6.38).

**Earlier in the same session — the storage tier serves a cross-node hit
— read 6.34.** 6.34's root
cause (the page and commit OBJ registrations were indistinguishable by
`(addr, len, devId)` and aliased, so every commit write landed on a *page*
key) is **fixed and verified**: `devId` is now allocated from a
daemon-global monotonic counter instead of restarting at the list position
on every call, and the page dlist is now deregistered immediately after
the page write is durable, before the commit registration is created.
Rung `60`'s acceptance run **step 5 PASSES for the first time**: a
genuinely cold decode node served content only prefill had ever computed
(`l2_device_hits=4`, token identity confirmed against the recompute
baseline). Both consequences of the old bug — the missing commit object
and the page-0 corruption — are independently confirmed fixed by direct
device inspection. 6.28 is closed end to end, pointing at 6.34. **What
remains:** step 7's negative control was never validated under a drain —
6.41 has since found the drain premise mis-targeted (the namespace is
already empty, and `50-reset-namespace.sh` was never the operation that
would drain OUR medium) — and 6.15 / 1.13 are the natural next items now
that the tier works. The adapter's design is
written down in
[docs/design/nixl-kv-l2-adapter.md](design/nixl-kv-l2-adapter.md) — do not
re-derive it.

**The composition is fixed, not configurable:** `MultiConnector[NixlConnector,
LMCacheMPConnector]`, `NixlConnector` hardcoded as `connectors[0]` — see
HANDOFF §1. This closed out 4.5's old connector-order question.

**Model running today:** `Qwen/Qwen3-8B`, `TP_SIZE=1` — **not**
`config/cluster.env`'s tracked default (`Qwen2.5-72B-Instruct`, TP=8). Every
throughput/latency figure in this file dated before 2026-09-16 predates that
switch and is not comparable to anything measured after it (HANDOFF §1).

**Storage tier, current state (2026-09-18): it serves a cross-node hit.**
This repo's replacement L2 adapter **`nixl_kv`** is written, unit-tested
(44/44, offline regression + mutation tested), deployed and registered on
both nodes, **proven cross-node byte-exact at the naming layer** (6.29,
rung `35`, 8/8 with three negative controls), and — new this session —
**proven at the engine level**: rung `60` step 5 PASSES, 9 of 11 checks
(the other 2 are step 7's negative control, VOID BY CONSTRUCTION under
`--no-drain`, not a fix failure). A genuinely cold decode node (container
recreated, writer's vLLM and daemon killed and removed) served content
only prefill had ever computed: `l2_device_hits=4`, `l2_index_hits=0`,
`l2_probe_errors=0`, `l2_load_aborts=0`, and TOKEN IDENTITY matched the
recompute baseline; negative control A (unseen nonce) also passed. **The
fault that blocked this (6.34) is fixed**: the page and commit OBJ
registrations no longer alias — `devId` is a daemon-global monotonic
counter, and the page dlist is deregistered before the commit registration
is created. Verified by direct device inspection on a fresh, post-fix key:
the commit object now exists (`<key>!c` HITs), and page `~0` now reads
back as real bf16 KV bytes, not commit-record JSON. 6.21's root cause (it
was always TWO blockers) is resolved end to end — HANDOFF §2.0. **What
remains:** step 7's control was never validated under a drain, and 6.41
has since found that drain premise (6.34's operational note) mis-targeted
smc3 rather than the medium that actually holds our data; 6.15 and 1.13
are the natural next items now that the tier works.

**RDMA acceptance (§3 below)** is a separate, independent transport upgrade
for the P→D path — routing is closed and RC queue pairs move real cross-node
traffic; UD queue-pair creation still fails on this driver/firmware, which is
the sole remaining blocker (3.9, HANDOFF §7.5).

**Second session, same day (2026-09-21), after a full teardown and
rebuild:** P↔D is now measured — by counting bytes on the wire, not
inferred from config — riding the 1 GbE management NIC (`ens51f0`)
while all eight 400 GbE fabric NICs sit idle (6.43). 3.9 was
re-measured on the new `-pi-131` firmware (3.10) and the RDMA
conclusion still holds. Consequently, every performance number in
this file is bounded by a 1 GbE link, not by the fabric.

---

## 0. Blocking decisions and follow-ups

- [x] **0.1** Scope of the storage tier in the P→D path. **Decided:** both legs,
      direct wins — `MultiConnector[NixlConnector, LMCacheMPConnector]`, with
      NixlConnector carrying the P/D role and LMCache as a reuse tier. Settled by
      a working reference deployment, not inference.
- [!] **0.2** **Rotate the BMC and root passwords.** They were committed to a
      public repo before the cleanup. History is purged and the published branch
      is verified clean, but anyone who cloned or any GitHub cache during that
      window still has them. The purge does not close this.
- [!] **0.3** Rename remote branch `rocm-aic` → `old`. Requires a PAT with
      `Administration: write`; the current token is read-only for that endpoint.
      Cosmetic — `main` is already default and correct.
- [x] **0.4** **Unblock the GPUs.** `modprobe.blacklist=amdgpu` is on both
      compute nodes' kernel cmdline and suppresses **autoload only** —
      `modprobe amdgpu` (no reboot, no GRUB edit) restores all 8 GPUs per node
      immediately (`rocm-smi`: 192 GiB VRAM × 8, `runtime_status=active`).
      Does not survive a reboot — `01-host-prep.sh` / `ensure_amdgpu_loaded()`
      in `lib.sh` runs it automatically every run (opt-out `AMDGPU_AUTOLOAD=0`).
      **Recurrence observed 2026-09-15:** both nodes rebooted unexpectedly and
      came back with 0 GPUs again, exactly as predicted — confirms the pattern
      empirically, not fixed, only automated. The kernel `nvme connect` from §6
      also did not survive that reboot (no `--persistent`, no systemd unit —
      see 6.9).

---

## 1. Architecture correction (compute leg)

*Done when the direct prefill→decode leg exists, is composed with the storage
tier, and can be verified independently of it.* Complete except the benchmark
rework.

- [x] **1.1** Establish the two-leg model and correct the conflated transport switch.
- [x] **1.2** Research `NixlConnector` / `MultiConnector` / LMCache p2p. Resolved
      from a working deployment. LMCache's own peer channel is unusable here
      (`supportsRemote() == false`).
- [x] **1.3** Remove storage-leg RDMA scaffolding built on the wrong premise.
- [x] **1.4** Implement the direct P→D leg — `scripts/common/gen-kv-transfer-config.sh`.
- [x] **1.5** Compose both legs in `scripts/common/start-vllm.sh`.
- [x] **1.6** Thread `kv_transfer_params` through `scripts/proxy/disagg_proxy.py`.
- [x] **1.7** Added `scripts/verify/50-verify-pd-direct.sh`, distinguishing a
      direct NIXL transfer from an LMCache hit from vLLM's own prefix cache.
      Four independent bugs, each producing a FALSE NEGATIVE on a fully
      healthy system, found and fixed 2026-09-16: the priming request never
      threaded the handoff field, the side-channel check probed the wrong
      host, a race against vLLM's periodic stats logger, and a dead string
      assertion. Passes **9/9** against the current (Qwen3-8B/TP=1) stack;
      re-verified 9/9 again 2026-09-17 after both compute nodes were rebooted.
      Full account: HANDOFF §7.12.
- [x] **1.8** Fix `setup_ucx_env` — `ib,rocm,self,sm`, RoCE `/31` subnet handling,
      per-role device pinning.
- [x] **1.9** Add `setup_pd_env` (refuses a loopback side-channel address) and
      `require_rdma_access` (opens a uverbs node rather than stat-ing it).
      Bind addresses are now pinned in creds
      (`PD_SIDE_CHANNEL_HOST_PREFILL`/`_DECODE`) rather than relying on
      `hostname -I`'s first-IP guess. Known, non-correctness asymmetry: bulk
      KV rides the management NIC on both nodes, but decode's side channel
      now sits on a fabric NIC, not management — harmless today, resolve
      before trusting it under a topology change (HANDOFF §2).
- [x] **1.10** Open side-channel ports in both host-prep scripts.
- [x] **1.11** Record the SPDK patch provenance and upstream status.
- [x] **1.12** Externalise credentials, purge history, add template + bootstrap.
- [ ] **1.13** Rework `scripts/bench/20-bench-prefix-cache.sh` for cross-instance
      or post-eviction measurement. As written it repeats the same context to the
      same endpoint, which vLLM's own prefix cache may serve without consulting
      any connector — see [HANDOFF §5](HANDOFF.md#5-traps-that-have-actually-bitten-distilled).
      The warning and `--confirm-connector-hit` are in place; the restructure is not.
      **Scope narrowed 2026-09-18 (6.35):** this item is now only about the
      *engine-level* question. KV-BLOCK accounting (blocks stored/requested,
      hit rate, block size, store/read MB/s) is answered directly and with
      device-level cross-checks by `lmcache bench l2` via
      `scripts/bench/l2-block-bench.py` — that path never touches vLLM, so
      the prefix-cache confound this item exists to fix cannot apply to it.
      Do not rebuild block-level measurement on top of llama-benchy.
      **2026-09-21:** the defect this item exists to fix is now
      demonstrated concretely, with numbers (6.42) —
      `--prefix-benefit`'s pairing of depth=0 against depth>0 makes a
      healthy tier score 0.823x. The rework now has a specific, measured
      target: pair context-load against inference at the SAME depth.
      Still open — the measurement exists, the harness fix does not.
- [~] **1.14** Implement and prove the 1P1D→xPyD fleet-shape seam: plural
      `PREFILL_HOSTS`/`_PORTS`/`DECODE_HOSTS`/`_PORTS` (defaulting to the
      existing singulars), an `EndpointPool` round-robin `select()` in
      `scripts/proxy/disagg_proxy.py` replacing the four scalar endpoint
      variables, and a per-instance NIXL side-channel port. **Done:** the
      code exists and is unit-tested against fake upstreams for the
      handoff-semantics risks this refactor could introduce (priming body,
      the `min_tokens`/`stream_options` drop, handoff threading,
      `prefill_no_handoff`, the swallow-prefill/502-on-decode asymmetry —
      HANDOFF §7.10 has the underlying handoff-protocol history this guards
      against). **Not done:** never run against more than one real prefill
      or decode instance on live hardware — every measurement in this file
      is still N=1. Prove it on real xPyD hardware before trusting the
      fleet shape beyond N=1. 2026-09-16.

---

## 2. Hardware bring-up (Phase 1, TCP)

*Done when the verify ladder is green end to end with the compute leg on TCP.*

- [x] **2.1** `scripts/common/init-creds.sh 4`, populate `creds/setup-4.env`;
      `source config/cluster.env` resolves real addresses. Verified
      2026-09-14 — ssh as root reaches all three nodes.
- [x] **2.2** `00-preflight.sh` on all three nodes — 5/5 checks each,
      2026-09-14 (after fixing 2.13). Inventory: `smc3` 320 CPUs / 62 GiB
      RAM, no ROCm, RDMA `rocep100s0`+`rocep132s0`, kernel 6.8.0-38;
      `smc1`/`smc2` 128 CPUs / 1511 GiB RAM, ROCm 7.13.0, 8 `ionic` RDMA
      devices/node, kernel 5.15.0-191 (later upgraded to 24.04.5/6.8.0-139,
      see 6.5–6.8). Caveat: its GPU check is advisory (`check_soft`) — green
      here means "inventoried", not "can serve" (0.4).
- [ ] **2.3** Pin an SPDK master SHA in `SPDK_TARGET_REF`; confirm patches 0002
      and 0003 apply cleanly to it. **Attempted 2026-09-15, FAILED:** `git am`
      could not apply `patches/spdk/0002` against current `master`. Not
      closed — the actual decision (pin a SHA / rebase / adopt the prebuilt
      tree) now lives at 6.2, since this session got a working target via a
      different route (2.4).
- [~] **2.4** Build SPDK and start the target; `scripts/target/04-verify-target.sh`.
      *blocked by 2.3.* **Partial workaround, 2026-09-15:** brought up
      instead from the prebuilt `/root/kv_spdk` (SPDK v26.05-pre) —
      namespace `KvMalloc0`, subsystem `nqn.2024-01.io.nixl:kv0`,
      `max_io_qpairs_per_ctrlr: 512` confirmed (HANDOFF §4 invariant 7).
      Transport reports `max_io_size: 131072` (128 KiB), not the 16 MiB
      invariant 8 assumed — see 6.4 (now resolved: 32768 is the real
      per-value ceiling that matters, not this number). Not fully done:
      `04-verify-target.sh` itself was never run against this substitute
      target, and 2.3's build failure is still open.
- [x] **2.5** `nvme discover` from both compute nodes — done 2026-09-15;
      both `nvme connect` to `nqn.2024-01.io.nixl:kv0` with 128 I/O queues.
      KV namespace materializes as a char-only device (`/dev/ng1n1` on
      `smc1`, `/dev/ng2n1` on `smc2`). Neither the connection nor the target
      survives a reboot (HANDOFF §3.4).
- [!] **2.6** Build the stack on both compute nodes; pass the `ldd`
      self-containment check on `libplugin_SPDK_NVMe_KV.so`. **Parked
      2026-09-15 — superseded by 6.1**, which decided the container path.
      Left open rather than deleted because the `ldd` invariant (HANDOFF §4
      invariant 2) still governs any future source build.
- [x] **2.7** Reconcile the LMCache backend allowlist against what's
      actually installed. **Answered:** the vendored LMCache 0.5.3 accepts
      `XNVME_KV`/`SPDK_NVMe_KV` because the vendor image was built with
      `patches/lmcache/0006`–`0008` applied at image-build time — not by
      anything in this repo (HANDOFF §7.8, `patches/lmcache/README.md`).
      As of 2026-09-17 those diffs are no longer carried as `.patch` files
      in this repo (verified present in the image, then deleted per the
      new policy — see `patches/lmcache/README.md`); `0011` is the one
      LMCache diff still carried here, because it's verified **absent**
      from the image. The from-source patch generator this item originally
      targeted is correctly withdrawn (that build path has never
      completed) and survives only in git history.
- [~] **2.8** Map `ionic_*` devices to physical ports per host; pin
      `PREFILL_UCX_NET_DEVICES`/`DECODE_UCX_NET_DEVICES`. **STALE as of
      2026-09-25 — superseded, do not use the `ionic_2:1` pin or the "all
      8 ACTIVE" state below; both were correct for their own moment and
      the hardware moved again.** Current pin, per `config/cluster.env`:
      both roles pinned to **`ionic_7:1`** (the same-plane index on both
      hosts). `UCX_IB_ROCE_SUBNET_PREFIX_LEN` is `8` —
      a `/16` reading recorded earlier was a **UCX policy filter**, not a
      fabric fault. `UCX_IB_GID_INDEX=1`.
      **MEASURED 2026-09-25, post-reboot (decode host rebooted 05:50:43
      UTC):** all 8 `ionic_N` IB devices registered and port 1 **ACTIVE**
      (state 4) on **both** nodes — `/sys/bus/auxiliary/devices/` now
      carries `ionic.rdma.0`–`.7`. This **clears** the blocker recorded at
      6.45 (zero RDMA devices, only `pds_core.fwctl.*`) — full record at
      6.46. **Drift warning, carry this forward every boot:** the
      `ionic_N` → `benicNp1` netdev mapping has **changed across
      reboots**. On the 2026-09-25 boot it is `ionic_N` →
      `benic(N+1)p1` on **both** hosts (e.g. `ionic_7` → `benic8p1`,
      `30.1.8.1/24` and `30.2.8.1/24`) — **not** the `ionic_N` →
      `benicNp1` mapping recorded above and at 6.44/6.45. The
      **same-plane property** of the `ionic_7:1` pin still holds on this
      boot (both hosts land on the same index), but the netdev mapping
      must be **re-verified every boot** and pinned **by property** (same
      plane on both hosts), never by a hardcoded index or a hardcoded
      `ionic_N`↔`benicNp1` assumption.
      **RoCEv2 itself is still NOT demonstrated:** no RDMA bytes carried,
      no throughput figure — decode never reached a healthy state before
      the LMCache IPC failure (TROUBLESHOOTING.md's `ipc_wrapper.py:85`
      entry, TODO 6.47). Prefill reports `p2p_state` `"unregistered"`,
      `p2p_peer_count` 0.
      Superseded pre-2026-09-25 state, for continuity: **re-confirmed
      2026-09-16 after a firmware update:** `ionic_0..7` →
      `benic1p1..benic8p1` on both nodes, all 8 ACTIVE, `smc1` on
      `30.1.N.1/24`, `smc2` on `30.2.N.1/24`. Pinned to `ionic_2:1` on both
      nodes — `ionic_2` is `-a-120` firmware on both, additionally dodging
      `smc1`'s lone `ionic_0` holdout on `-pi-121` (3.10). Two earlier
      mappings recorded here (2026-09-14, 2026-09-15) were each correct for
      their own moment and then invalidated by the hardware changing
      underneath (HANDOFF §7.1).
- [x] **2.9** Pre-staged Qwen2.5-72B-Instruct weights to `/var/tmp/hf/` on
      both nodes (bind-mounted `/hf`), verified 37/37 shards, 145.4 GB,
      index-matched. Redundant hub-cache copy reclaimed later (6.17).
- [!] **2.10** Start prefill/decode/proxy; run the verify ladder.
      **Superseded by 6.11** (bring-up) and **6.10** (compose the storage
      tier) — those items now carry this work against the container path.
      The `kv_transfer_params` handoff field is load-bearing, not "unused"
      as the vendored proxy's silence once suggested — HANDOFF §7.10.
- [ ] **2.11** Fix `00-preflight.sh`'s PCIe inventory section — it greps
      `lspci -d 1dd8:` and claims that covers "GPUs + data-plane NICs".
      Measured 2026-09-14: it covers **zero** GPUs, because the MI300X ID
      is `[1002:74a1]` (vendor `1002`/AMD, not `1dd8`) — see HANDOFF §1's
      hardware table. Small script fix, but `scripts/` is being edited
      concurrently this session — coordinate before touching it.
- [ ] **2.12** Distribute an ssh key to all three nodes. Confirmed
      2026-09-14: key auth is not configured anywhere; every connection so
      far used `sshpass` against `creds/active.env`. `deploy.sh` can install
      a key (opt-in flag) but pushes those same passwords to all three
      machines by default — decide whether that default is acceptable.
- [x] **2.13** Fixed `00-preflight.sh` aborting mid-run under
      `set -euo pipefail` when `rocminfo` exits non-zero (GPUs blacklisted,
      0.4) — a `grep`+`pipefail` interaction silently truncated every
      section after ROCm/GPU. Swept six more sites in `lib.sh` and the
      three `01-host-prep.sh` scripts; host-prep sites now `die` with a
      diagnostic instead of warning, since those are hard gates. 2026-09-14.

---

## 3. Acceptance (Phase 2, RDMA on the compute leg)

*Done when P→D KV transfer runs over RDMA with no TCP fallback, proven by
counters rather than inferred from throughput.*

- [ ] **3.1** Configure the RoCE fabric between the compute nodes — PFC/ECN/DSCP,
      MTU 9000. ~~*blocked by 2.10*~~ — **re-pointed 2026-09-21:** 2.10
      is itself `[!]` superseded (by 6.11/6.10), a dead blocker. *Now
      blocked by 3.9* — no purpose in tuning PFC/ECN/DSCP/MTU for a
      fabric UCX will not select. Also measured 2026-09-21:
      `active_mtu` currently reads **4096**, not the 9000 this item
      targets.
- [x] **3.2** Confirm `/dev/infiniband/uverbs*` are openable, `memlock` is
      unlimited, and `ibv_devinfo` shows `PORT_ACTIVE`. **Partly answered,
      2026-09-15 — badly:** the devices exist and all 8 ports read
      `ACTIVE`/`LinkUp`, yet `ibv_devinfo` returned `No IB devices found`
      because no ionic provider loaded — see 3.7. A device present but
      unopenable presents as a ~90s hang, not an error. `memlock` still
      unchecked.

      **CLOSED 2026-09-21 — all three conditions verified.**
      **Openable, in the strong form:** `/dev/infiniband/` inside the
      role container holds `rdma_cm` + `uverbs0..uverbs7`, and
      `uverbs0` was **actually opened** (`os.open(..., O_RDWR)`
      returned fd 3) — not stat-ed. This is the same distinction
      1.9's `require_rdma_access` makes, and it matters because a
      present-but-unopenable device presents as a ~90 s hang rather
      than an error. **`memlock` is unlimited** inside the container
      (`ulimit -l` = `unlimited`), supplied by `container.sh`'s
      `--ulimit memlock=-1`. **`ibv_devinfo` reports 8/8
      `PORT_ACTIVE`** on the host, with `link_layer: Ethernet`,
      `active_mtu: 4096`. Strongest evidence, beyond what this item
      asked for: `ib_write_bw` moved real cross-node traffic at
      769.34 Gb/s over these devices (3.9), so they are not merely
      openable but fully functional. Operational note worth carrying:
      `ibv_devinfo` is **not installed inside the role container** —
      only on the host. A container-side check must not use it (and
      a `2>/dev/null` around it will silently turn "command not
      found" into a confusing empty result, which is exactly how
      this was nearly mis-read today). 3.8's preflight assertion is
      unaffected because `00-preflight.sh` runs on the host.
- [ ] **3.3** Set the compute leg to RDMA and restart. `UCX_TLS` excludes `tcp`
      by design so a half-configured fabric fails loudly.
- [ ] **3.4** Prove RDMA is carrying the KV traffic — counters, not throughput
      inference. **Measured 2026-09-21:** the measurement technique
      this item asks for now exists and has been exercised —
      per-interface `rx_bytes`/`tx_bytes` deltas snapshotted around
      real traffic (6.43). It returned a decisive **negative**
      answer: across a full benchmark sweep the 1 GbE management NIC
      `ens51f0` carried 3,314,691,031 bytes while all four sampled
      fabric NICs carried 4,308 bytes combined, a ratio of
      ~769,427:1. So the *how* is solved and the *what* is currently
      "TCP, not RDMA". Stays OPEN, now **blocked by 3.9** (UCX
      `rc_verbs` filtered out because the ionic provider reports
      `max_srq = 0`), not by a lack of instrumentation.
- [ ] **3.5** Re-run the verify ladder and
      `scripts/bench/40-bench-transport-compare.sh` for the TCP-vs-RDMA number.
      *blocked by 1.13 if the figure is to mean anything*. **Sharpened
      2026-09-21:** 1.13's defect is no longer hypothetical — it has
      been demonstrated with numbers (6.42/6.43: `--prefix-benefit`
      scores a healthy tier at 0.822x because it pairs depth=0
      against depth=4096). And the RDMA half of the comparison cannot
      be produced at all while 3.9 stands, so this item is blocked on
      **both** 1.13 and 3.9.
- [x] **3.6** P→D fabric had no route: `smc1`'s data-plane addresses are
      `30.1.N.1/24`, `smc2`'s are `30.2.N.1/24` — different `/24`s, no
      fabric route, falsifying `config/cluster.env`'s `/31`
      point-to-point premise. **CLOSED 2026-09-16 — not done by us:**
      static routes now exist for all 8 fabric pairs, both directions;
      cross-node ping is 0% loss at ~0.10 ms. First real cross-node RDMA
      throughput once routing closed: `ib_write_bw` ~41,898 MiB/s (~88% of
      the **400** Gb/s line rate — these are 400 Gb/s NDR NICs, not 200 as
      earlier assumed). See HANDOFF §7.1 (the shared-hardware pattern) and
      §7.6 (the throughput measurement itself).
- [~] **3.7** The `ionic` RDMA stack had two independent breaks, introduced
      by the 24.04.5/6.8 upgrade, on both compute nodes. **Break 1
      (userspace provider ABI mismatch): FIXED** — another party installed
      a matched 24.04 DSC bundle; `ibv_devinfo` now works on both nodes,
      `show_gid` returns 24 GIDs/node (HANDOFF §7.4). **Break 2: RC QPs
      work and move data** (`ibv_rc_pingpong` — loopback only, do not quote
      its `Mbit/s` as throughput); **UD QP creation fails**
      (`CREATE_QP BAD_ATTR`) and `rdma_cm` fails with it, since QP1 is a UD
      QP. NIXL/UCX don't need `rdma_cm` (they program QPs directly after
      exchanging metadata over their own side channel), so this likely
      doesn't block leg A over RDMA — but `UCX_TLS=ib` pulls in UD
      transports that will fail (HANDOFF §7.5). Cross-node RC at full
      rate is now confirmed — 769.34 Gb/s bidirectional via
      `ib_write_bw -q 16`, 2026-09-21 (3.9) — so the loopback caveat
      above no longer limits what is known about the RC datapath.
      `UCX_IB_GID_INDEX=1` confirmed correct (the IPv4 RoCEv2 GID on
      every device). Left `[~]`:
      the UD/QP1 defect is real, unexplained, and should be raised with
      AMD. See 3.9 for what's still open.
- [x] **3.8** `00-preflight.sh` now asserts `ibv_devinfo` enumerates ≥1 RDMA
      device (previously only checked the binary existed) and surfaces
      libibverbs' `couldn't load driver` warning explicitly — that warning
      names the exact missing provider from 3.7's break 1 (HANDOFF §7.4)
      and would have made it self-diagnosing. `require_rdma_access` (1.9)
      already hard-gates in RDMA mode, satisfying that half independently.
      2026-09-16.
- [ ] **3.9** 🔴 **The sole remaining RDMA-stack blocker — now a
      single named missing capability, not an absent transport.
      SHARPENED 2026-09-18 — the premise was wrong twice over.
      ROOT-CAUSED 2026-09-21 — RC works, at line rate; the entire
      gate is UCX's SRQ requirement (see the block at the end of this
      item). UNBLOCKED (capability) 2026-09-22 — the ionic provider
      now reports SRQ; the gate moved to the fabric links, which are
      down (see the update at the end of this item).**

      **(a) The container never had RDMA access at all.** `container.sh`
      mapped only `/dev/kfd`, `/dev/dri` and the KV char device. The host
      showed 8 uverbs devices and a full RoCEv2 GID table (`VER v2`,
      IPv4 GID at index 1, `PORT_ACTIVE`, MTU 4096) while `ucx_info -d`
      **inside the container** enumerated only
      `cma/posix/rocm_copy/rocm_ipc/self/sysv/tcp` — no IB transport of
      any kind. UCX is built with verbs (`libuct_ib.so` present, the
      `HAVE_DECL_IBV_*` block is set); it simply had no device. **Every
      earlier in-container RDMA conclusion was therefore answering a
      different question than the serving path asks.** Fixed: `container.sh`
      now maps `/dev/infiniband` with `--ulimit memlock=-1` and
      `--cap-add IPC_LOCK`, and warns loudly when the host has no
      `/dev/infiniband` rather than silently producing a TCP-only container.

      **(b) There is no RC transport to narrow to.** This item previously
      proposed "naming RC explicitly instead of the `ib` alias". Measured
      after fix (a): `ucx_info -d -t rc_verbs` returns **0 transport/device
      pairs**, and `UCX_TLS=rc_verbs ucx_info -u t -d` falls through to
      `tcp` on the `benicN` interfaces. UCX never attempts RC on ionic at
      all. The only IB transport it offers is `ud_verbs`, on all 8 devices,
      and opening it fails on every one:

      ```
      ib_iface.c:1269 UCX ERROR ionic_N: iface failed to create UD QP
        TX wr:256 sge:6 inl:64 resp:0 RX wr:4096 sge:1 resp:0
        failed: Invalid argument
      ```

      Constraining the parameters named in that message
      (`UCX_IB_TX_MAX_SGE=1`, `UCX_UD_VERBS_TX_INLINE=0`) does **not** change
      the outcome. Note `ibv_rc_pingpong` works on the host (3.7), so the
      hardware does support RC queue pairs — UCX's `rc_verbs` iface needs
      more from the provider than pingpong does, and the ionic userspace
      provider does not satisfy it.

      **Consequence, stated plainly: P→D over RDMA RoCEv2 is NOT achievable
      on this stack today.** Not for want of configuration — UCX has no
      usable RDMA transport here. This is now a driver/provider issue to
      raise with AMD (the `ud_verbs` QP rejection and the absent `rc_verbs`
      support), not a UCX_TLS tuning exercise. Do not spend more time on
      transport-spec permutations until the provider exposes a working
      transport.

      *Original framing, retained for context:* `UCX_TLS=ib`
      pulls in UD transports; UD QP creation fails outright on this
      driver/firmware (`Couldn't create QP`), and `rdma_cm` fails with it
      (HANDOFF §7.5). A firmware update that levelled 15/16 cards did NOT
      fix this — identical failure on old and new firmware alike, which
      disproves firmware skew as the cause (downgrades 3.10). Need to
      determine empirically which UCX transport spec works — likely naming
      RC explicitly instead of the `ib` alias — via `ucx_info -d` inside
      the container with `/dev/infiniband` mapped in (not yet done;
      `ucx_info` isn't installed on the bare host). **Do not simply edit
      invariant 6 to make this pass** — its exclusion of `tcp` must stay,
      so a half-working fabric fails loudly rather than reporting a good
      number over the wrong transport (HANDOFF §4 invariant 6). *3.6 is
      closed; this is the only thing gating 3.1.*

      **Re-measured 2026-09-21, after the DSC recovery and firmware
      drift recorded at the top of this file and in 3.10.** The point
      of re-measuring is that driver/firmware state drifts (HANDOFF
      §3.5) — it drifted again, to a THIRD firmware revision on
      record (`1.130.0-pi-121`/`-a-120`, then `1.130.0.a.129`, now
      `1.130.0-pi-131` — 3.10) — and the conclusion did NOT change.

      DSC firmware `1.130.0-pi-131`, UCX 1.19.1, 8 uverbs devices
      correctly mapped into the container (`rdma_cm uverbs0..uverbs7`).
      `ucx_info -d -t rc_verbs` transport/device pair count: **0**,
      unchanged. `ud_verbs` is still offered on all 8 devices and
      opening it still fails on every one, identical signature to
      before:

      ```
      ib_iface.c:1269 UCX ERROR ionic_0: iface failed to create UD QP
        TX wr:256 sge:6 inl:64 resp:0 RX wr:4096 sge:1 resp:0
        failed: Invalid argument
      ```

      **`UCX_TLS=ib` falls through to `self` + `tcp`** — asking for
      InfiniBand yields TCP. This is the sharpest statement of the
      blocker yet: it is not that RDMA is misconfigured, it is that
      UCX has no usable RDMA transport to select here. Full transport
      inventory inside the container: `tcp` (10), `ud_verbs` (8),
      `sysv`, `self`, `rocm_ipc`, `rocm_copy`, `posix`, `cma`.

      A third firmware revision producing an identical result further
      strengthens 3.10's downgrade of firmware skew as a cause. **3.9
      stays OPEN and `[ ]`** — still a driver/provider matter for AMD.

      **ROOT-CAUSED 2026-09-21 — the missing capability is SRQ, and
      nothing else on the RC path.** Prompted by the principal running
      `ib_write_bw` cross-node successfully, which on the surface
      looked like it contradicted this item's "RoCEv2 not achievable"
      conclusion. It does not — it isolates it, because the two
      results live at different layers.

      **Layer 1 — verbs: RC works, at essentially line rate.**
      Reproduced 2026-09-21, prefill as server / decode as client:
      `ib_write_bw -d ionic_0 -q 16 -a -b -n 10000 --report_gbits`
      (peer `30.1.8.1`). Result: **769.34 Gb/s peak bidirectional**
      (769.16–769.34 across message sizes 128 KiB–8 MiB), 160,000
      iterations per size, all sizes 2 B to 8 MiB, total run 63.473 s
      — ~96% of 400 Gb/s per direction. `ib_write_bw` uses **RC queue
      pairs**. So hardware, firmware (`1.130.0-pi-131`), fabric,
      routing and the RC datapath are ALL fine — consistent with 3.6
      and 3.7's `ibv_rc_pingpong` result, now confirmed cross-node at
      full rate.

      **Layer 2 — UCX: `rc_verbs` is filtered out before any
      configuration is consulted**, because the ionic provider reports
      `max_srq = 0`. Measured on **all 8 devices on both nodes** (16/16
      report 0).

      **The mechanism, read from the UCX 1.19.1 source shipped inside
      the container** (`/tmp/ucx-rocm/ucx-src`), not inferred:
      `src/uct/ib/rc/verbs/rc_verbs_iface.c:582`,
      `uct_rc_verbs_query_tl_devices()` ends with:

      ```c
      return uct_ib_device_query_ports(&ib_md->dev, UCT_IB_DEVICE_FLAG_SRQ,
                                       tl_devices_p, num_tl_devices_p);
      ```

      `src/uct/ib/base/ib_device.c:748`:

      ```c
      if (flags & UCT_IB_DEVICE_FLAG_SRQ) {
          if (IBV_DEV_ATTR(dev, max_srq) == 0) {
              ucs_trace("%s:%d does not support SRQ", ...);
              return UCS_ERR_UNSUPPORTED;
          }
      }
      ```

      And UCX says so in its own words under `UCX_LOG_LEVEL=trace`:
      `ib_device.c:750 UCX TRACE ionic_0:1 does not support SRQ` —
      repeated for every device.

      **Things this rules out, each tested rather than argued:**
      `UCX_IB_ETH_PAUSE_ON` is already `y` by default and is NOT the
      gate (tested explicitly: `UCX_IB_ETH_PAUSE_ON=y` still yields 0
      `rc_verbs` pairs). No `UCX_TLS` or transport-spec permutation
      can help: the filter runs at **device-query** time, before
      transport selection happens at all — this retires the original
      "name RC explicitly" idea above (and HANDOFF §7.17)
      definitively. `ud_verbs` remains a SEPARATE, independent defect
      (QP creation fails, `Invalid argument`) — unchanged, not
      explained by SRQ.

      **Consequence — the ask to AMD is now one line:** implement SRQ
      support (non-zero `max_srq`, working `ibv_create_srq`) in the
      ionic RoCE userspace provider. That single capability is the
      whole distance between this cluster and P→D over RoCEv2. The
      only alternative is an upstream UCX RC path that does not
      require SRQ, which is a much larger change and exists in no
      release.

      **The prize, quantified:** 769 Gb/s measured available on the
      fabric versus the 1 Gb/s management link the KV path actually
      uses today (6.43) — roughly **769x** on the wire.

      **UNBLOCKED (capability) 2026-09-22 — the named blocker above is
      GONE.** After the principal updated driver/software on both
      nodes (userspace only — `rdma-core` is now `61.0-1`,
      `ibverbs-providers 50.0-2ubuntu0.2`, with both
      `libionic-rdmav34.so` and `libionic-rdmav59.so` sonames present;
      kernel unchanged `6.8.0-139-generic`, `ionic`/`ionic_rdma`
      unchanged `26.09.4.001`, `pds_core` firmware reads
      `1.130.0.a.129` — not newer than 3.10's `-pi-131`, so this is a
      driver/library update, not a firmware one):

      **`max_srq` is now 512 on all 8 devices on both nodes** — measured
      **16/16**, versus **0/16** yesterday. And UCX's own rejection
      reason MOVED, which is the rigorous confirmation, not an
      inference from the number alone:

      | date | `ib_device.c` trace |
      |---|---|
      | 2026-09-21 | `:750 UCX TRACE ionic_0:1 does not support SRQ` |
      | 2026-09-22 | `:743 UCX TRACE ionic_0:1 is not active (state: 1)` |

      UCX now PASSES the SRQ gate this item spent all of 2026-09-21
      isolating, and fails only on port state (`state: 1` =
      `IBV_PORT_DOWN`). `rc_verbs` pair count is still 0, but for a
      different and far more mundane reason — the ports are down, not
      that the capability is absent.

      **Stated precisely, because this is a capability fix, not a
      demonstration:** the root cause this item root-caused on
      2026-09-21 — the ionic provider's missing SRQ support — is
      resolved. RoCEv2 for P→D is now gated **only** on the fabric
      links coming up (3.9's blocker moves to 3.1/3.3, and to the
      concrete link-down finding recorded at 6.44). **RoCEv2 has NOT
      been demonstrated** — no RDMA traffic has been carried and no
      throughput number exists yet, so this item stays `[ ]` OPEN.
      What changed is *what* it is blocked by: a single missing
      capability that needed a vendor fix, not a fabric or
      configuration problem this repo could reach. See 6.44 for the
      full driver/software update record, including the two other
      findings (KV device PCI address move, fabric links down) from
      the same update.

      **Link-state gate CLEARED 2026-09-22, later the same day —
      blocker MOVED again, to the auxiliary bus.** The 400G config
      brought all 8 fabric links up (400000 Mb/s), so 3.1/3.3's
      link-down blocker above is gone. But zero RDMA devices
      registered: `/sys/class/infiniband/` is empty, and
      `/sys/bus/auxiliary/devices/` shows only `pds_core.fwctl.*`, no
      `pds_core.rdma.N` for `ionic_rdma` to bind to. **This item stays
      `[ ]` OPEN**, now blocked by that auxiliary-bus gap rather than
      the links. The SRQ result above (`max_srq` 512) is **pending
      re-confirmation** — it was measured on the previous boot and
      could not be re-checked here. Full record: 6.45.
- [x] **3.10** DSC firmware differed between nodes (`smc1` `1.130.0-pi-121`
      vs `smc2` `1.130.0-a-120`) — not known to cause a problem by itself.
      **Firmware updated 2026-09-16, levelled to 15/16 cards** (`smc1`'s
      `ionic_0` held back) — and this DISPROVES firmware skew as 3.7 break
      2's cause: the one remaining old-firmware card fails with the
      identical `CREATE_QP BAD_ATTR` as every levelled card (HANDOFF §7.5).
      Downgraded from blocker to tidiness — level `smc1`'s `ionic_0` when
      convenient; nothing in Phase 2 waits on it. See 3.9.

      **Drifted again, 2026-09-18** (§7.1/§3.5 pattern, recorded rather than
      chased): `pds_core` firmware now reads `1.130.0.a.129`, ionic driver
      `26.09.4.001` on both nodes — different from every value previously
      on record (`1.130.0-pi-121` / `1.130.0-a-120`). Not known to change
      anything in 3.9's UD-QP finding; recorded as the new current value.

      **Drifted again, 2026-09-21** (same §7.1/§3.5 shared-hardware
      pattern, recorded rather than chased): `pds_core` firmware now reads
      `1.130.0-pi-131` on both nodes — different again from every value
      previously on record (`1.130.0.a.129` on 2026-09-18;
      `1.130.0-pi-121`/`1.130.0-a-120` earlier). Not known to change
      anything in 3.9's UD-QP finding; recorded as the new current value.

---

## 4. Open items and known limitations

- [ ] **4.1** The target's Pollara serial console refused connection when last
      tried. Low priority — that leg is TCP-only.
- [ ] **4.2** No geometry manifest for stored KV objects: changing
      `KV_MAX_VALUE_SIZE` (or `--l1-align-bytes`) without draining yields
      silent half-stale reads. Mitigated by
      `scripts/target/50-reset-namespace.sh`, not solved.
- [x] **4.3** ~~uuid4-keyed objects have no restart survival or
      cross-process sharing. Only a content-derived key could cross
      processes, and no such path exists under `nixl_store` (see
      6.21).~~ — **superseded, 2026-09-21, by two separate
      findings:**
      **Cross-process sharing: SOLVED.** A content-derived key path
      now exists — this repo's own `nixl_kv` adapter (6.29), proven
      cross-node byte-exact at the naming layer (rung 35, 8/8) and at
      the engine level on a cold reader (6.34, 6.42, 6.43). This
      item's premise that "no such path exists" was true only of
      `nixl_store`, which is now retained solely as the A/B control
      (6.21).
      **Restart survival: ANSWERED, and it is not a property of key
      derivation at all.** 6.41 measured the DSC/DPU KV store to be
      **volatile** — objects recorded as present on 2026-09-18 all
      probed MISS on 2026-09-21, from both nodes, with positive and
      negative controls. Nothing in this tier survives a DSC/DPU
      restart regardless of how keys are derived, so "uuid4-keyed
      objects have no restart survival" is subsumed by "the medium
      has no restart survival".
- [ ] **4.4** Watch Gerrit 27889 / 28298. Both are review-complete and tagged
      `26.09`; when they merge, drop the vendored `patches/spdk/0002` and `0003`
      and move `SPDK_TARGET_REF` to the release tag.
- [x] **4.5** ~~Connector-order experiment (`PD_LMCACHE_FIRST`)~~ —
      **obsolete, 2026-09-16.** There is no posture left to experiment with:
      `NixlConnector` is hardcoded as `connectors[0]` in
      `gen-kv-transfer-config.sh`, because letting LMCache go first would
      silently skip the P→D remote-prefill pull whenever the L2 tier has
      anything cached (HANDOFF §1).
- [ ] **4.6** `rocm-smi` prints `get_name, Error when calling libdrm` and an
      empty Marketing Name on both nodes — `libdrm-amdgpu1` (Ubuntu-packaged)
      vs ROCm 7.13.0/hsa-rocr 7.2.0 version mismatch. Believed harmless:
      `rocminfo` still correctly identifies `gfx942` via HSA/ROCr, which is
      what vLLM's device enumeration uses. Cosmetic; revisit only if
      something downstream reads `rocm-smi`'s Marketing Name field.

---

## 5. Done

- [x] **5.1** Analysed both NIXL plugins; researched rocm-aic, SPDK v26.05 and llama-benchy.
- [x] **5.2** `config/cluster.env` + `scripts/common/lib.sh` cluster contract.
- [x] **5.3** SMC3 target scripts.
- [x] **5.4** Compute-node build chain (SPDK initiator, UCX, NIXL, plugins, venv).
- [x] **5.5** LMCache allowlist patch and config generation/validation.
- [x] **5.6** Serving scripts and the disaggregation proxy.
- [x] **5.7** Verify ladder (5 rungs).
- [x] **5.8** llama-benchy benchmark harness.
- [x] **5.9** Full documentation set.
- [x] **5.10** Model set to Qwen2.5-72B-Instruct; SPDK migrated to v26.05+.
- [x] **5.11** Target rebuilt from a proven configuration, replacing inference.
- [x] **5.12** Chunk-ceiling guard, validated against two independent measurements.
- [x] **5.13** Direct P→D compute leg implemented and composed.
- [x] **5.14** Credentials externalised, history purged, repo published to
      `main` at `github.com/pmallapp-amd/llm-stacks`.

---

## 6. Storage-tier integration (XNVME_KV / SPDK_NVMe_KV as an LMCache tier)

*Done when a KV storage backend serves as a live LMCache tier underneath a
real P/D deployment, proven independently of the P→D leg.* See HANDOFF §1 for
why a KV backend can only ever be an LMCache storage tier, never
`NixlConnector`'s own transport, and HANDOFF §6.3 for the
container-vs-source-build decision.

- [x] **6.1** Decided the deployment model: the vendor container image
      (`rocm-aic:...`), not this repo's from-source build chain — the image
      already ships vLLM 0.26.0+rocm, LMCache 0.5.3, and prebuilt
      `libplugin_SPDK_NVMe_KV.so`/`libplugin_XNVME_KV.so`. The from-source
      path is deprioritized, not deleted; its patch provenance remains
      untested against what's baked into the image (HANDOFF §6.3).
      2026-09-15.
- [!] **6.2** This repo's own SPDK-vs-`master` build fails: `git am` cannot
      apply `patches/spdk/0002` against current master (2026-09-15). Parked,
      not resolved — superseded by 6.1's container-path decision, which
      doesn't depend on this build. Three options undecided: pin a
      compatible SHA, rebase the patches, or adopt the prebuilt tree as
      reference. Revisit only if the from-source path is revived.
- [x] **6.3** Decided the KV backend: kernel `nvme-of` + **XNVME_KV** (not
      SPDK_NVMe_KV) — unblocked once the compute nodes moved to kernel 6.8
      (closing the CSI-1 gap, 6.8). Proven end-to-end via 6.12. `KV_BACKEND`
      switch and backend-aware `KV_MAX_VALUE_SIZE_EFFECTIVE` already existed
      in `config/cluster.env`; SPDK_NVMe_KV stays available for comparison.
      Also fixed: device autodiscovery (`discover_kv_device()`) could
      silently pick a local Pensando DSC controller instead of the fabric
      target on a host with more than one KV-capable NVMe device —
      `resolve_xnvme_kv_dev()` now matches by `NVMF_SUBNQN` and dies on
      ambiguity. Default flip to XNVME_KV landed later, see 6.22.
- [x] **6.4** Target transport reports `max_io_size: 131072` (128 KiB), not
      the 16 MiB invariant 8's formula assumed — but the number that
      actually governs `KV_MAX_VALUE_SIZE` for XNVME_KV is the plugin's own
      per-value ceiling (32768 B, see 6.24). **Narrowed 2026-09-16:**
      irrelevant to the path this repo runs — the daemon's `--l2-adapter`
      tiles storage at `--l1-align-bytes` (4096 B default), not at the
      whole LMCache chunk, so `_resolve_mem_split()` always returns
      `mem_split_n=1` and splitting is currently DEAD CODE on the live
      path. Whether `--l1-align-bytes` should ever change, and what that
      would do to the split logic if it ever engages, is still an open,
      deferred question. HANDOFF §4 invariant 8.
- [x] **6.5** Kernel-upgrade sub-plan step 1 (install HWE kernel package) —
      superseded: the nodes were upgraded wholesale to Ubuntu
      24.04.5/kernel 6.8.0-139 instead, same practical outcome.
- [x] **6.6** amdgpu DKMS rebuild for 6.8 — confirmed built on both nodes as
      part of the OS upgrade, not a separate step.
- [x] **6.7** Stage reboots one node at a time — happened as part of the OS
      upgrade; both nodes came back on 24.04/6.8 with the amdgpu
      blacklist/ritual unchanged (0.4).
- [x] **6.8** Re-test that a KV namespace yields `/dev/ngXnY` (not
      `/dev/nvmeXnY`) on the new kernel. **PASSED 2026-09-15:** 5.15 logged
      `unknown csi 1 for nsid 1` and created no device node; 6.8.0-139
      creates the char device correctly. Closes the CSI-1 gap — the
      plugin header's claim was kernel-dependent, not simply wrong
      (HANDOFF §7.9).
- [x] **6.9** Kernel `nvme connect` is not persistent (no `--persistent`, no
      systemd unit) — confirmed does not survive a reboot. Reclassified as
      a known limitation with a documented per-boot workaround (HANDOFF
      §3.4) rather than open build work; automating it is optional future
      work.
- [~] **6.10** Compose the storage tier under P/D:
      `MultiConnector[NixlConnector, LMCacheMPConnector]` with the
      daemon-side `--l2-adapter` (XNVME_KV, `dev_uri` via
      `resolve_xnvme_kv_dev()`). **Implemented** (commits `c055f7d`,
      `0b75adb`): `start-lmcache-daemon.sh`/`stop-lmcache-daemon.sh`, wired
      into the role start scripts and gated by `start-vllm.sh`; validated
      against the installed LMCache parser and a live
      `get_plugin_params()` query. **DONE 2026-09-18:** the composed path
      served a live cross-node LMCache hit — rung `60` step 5,
      `l2_device_hits=4` on a cold reader with the writer killed (6.34).
      The old blocker cited here (6.21's `nixl_store` key derivation) was
      superseded by the `nixl_kv` adapter, and the fault that actually
      remained was 6.34's OBJ descriptor aliasing, now fixed.
      HANDOFF §1.1.
- [x] **6.11** ✅ P→D direct NIXL transfer proven via this repo's own proxy
      — decode 0.0 tokens/s prompt throughput, 100% external prefix cache
      hit rate (4033-token prompt, per-run nonce). Two defects fixed: the
      proxy wasn't requesting the handoff (the XpYd handshake is three
      steps, not two — HANDOFF §7.10) and UCX was advertising an
      unroutable NIC (fixed via `PREFILL_PD_IF`/`DECODE_PD_IF`). Also
      found: `nixl_rocm._api.create_backend()` has no return statement and
      is always `None` — check `agent.backends[name]` instead. 2026-09-15.
- [x] **6.12** Proved the XNVME_KV backend itself (not through LMCache)
      does cross-process store/retrieve: two independent `docker run`
      processes, correct bytes back, correct `QUERY_MISS` on an unwritten
      key. Established the backend works; composing it under LMCache was
      left to 6.10. 2026-09-15.
- [!] **6.13** Generate/validate the LMCache YAML for the chosen backend —
      folded into 6.10 once the backend (XNVME_KV) and its real ceiling
      (32768 B, not 131072 or 16 MiB) were known. No standalone work
      remains.
- [x] **6.14** Proxy/router decision: this repo's own
      `scripts/proxy/disagg_proxy.py`, not the vendored
      `disagg_proxy_demo.py` — the vendored proxy cannot drive
      `NixlConnector` at all (never threads `kv_transfer_params`), see
      HANDOFF §7.10. `PD_HANDOFF_FIELD` = `kv_transfer_params`,
      load-bearing on both request and response sides.
- [~] **6.15** Cross-instance reuse measurement, not confounded by vLLM's
      own prefix cache or same-endpoint repeats — the number that actually
      demonstrates the KV backend is doing anything under live LMCache.
      **Unblocked 2026-09-18:** the composed hit now exists (6.34, rung
      `60` step 5), so the old "the hit itself doesn't exist yet" blocker
      is gone. Still gated on 1.13 (benchmark rework) for the figure to
      mean anything. This is now the natural next item.
      **2026-09-21: a cross-instance reuse number now EXISTS**, and it is
      not confounded by vLLM's own prefix cache — `--confirm-connector-hit`
      passed, and the adapter counters independently corroborate it
      (decode `l2_device_hits=8` with `l1 objects=0` on the live path;
      rung 60 step 5 `l2_device_hits=4` on a cold reader with the writer
      killed). The measured reuse benefit is **7.53x** on `est_ppt` at
      depth 4096 (6.42). What is still missing, stated honestly: the
      figure is N=1 on a single shape (pp=512/tg=128/depth=4096/
      concurrency=1), it was taken with L1 forced to 1 GiB, and the
      harness's own headline metric still needs 1.13's fix before the
      number can be read straight off `compare_runs.py`. Flipped to `[~]`
      as the most defensible marking — not `[x]`.
- [!] **6.16** ~~Both 200G data-plane NICs on the target reported `Link
      detected: no`~~ — **superseded by 6.19:** the links are up now; the
      remaining gap is addressing/routing to `1.1.0.x`, not physical
      access.
- [x] **6.17** Reclaimed the redundant Qwen2.5-72B-Instruct copy in the hub
      cache (~135 GB/node) once `/var/tmp/hf/Qwen2.5-72B-Instruct` was
      confirmed as the sole bind-mount source (37/37 shards, 145.4 GB,
      index-matched). `smc1` now 336 GB free, `smc2` 253 GB. 2026-09-15.
- [!] **6.18** `smc3`'s KV target is SHARED and has been reconfigured by
      another party mid-session more than once — most recently our
      subsystem `nqn.2024-01.io.nixl:kv0`/`KvMalloc0` was replaced by
      `nqn.2016-06.io.spdk:cnode1` (2026-09-15), and `nvme connect` fails
      `Connection refused` until ownership is re-established. Do not
      restart another party's target unilaterally — agree ownership first.
      The local DSC (`/dev/ng1n1`) is **not** an escape hatch: it's the
      same namespace, re-exported (HANDOFF §7.3, confirmed by 6.25) —
      whoever else is on `smc3` is exactly as visible through it. *Blocks
      6.10/storage-tier work whenever ownership is unclear; check before
      every session (HANDOFF §3.2).*

      **Re-confirmed 2026-09-18: still shared, still not ours.** `smc3`'s
      `nvmf_tgt` (running since Wed Sep 16 22:33) serves only
      `nqn.2016-06.io.spdk:cnode1`, namespace `dev1_ns1` (a "KVMalloc disk")
      on listener TCP `1.1.0.2:4420` — our subsystem
      `nqn.2024-01.io.nixl:kv0` is absent, same as before. Despite that,
      `/dev/ng1n1` came up on both compute nodes this session with `csi
      0x1`, `nsze 0x200000` (1 GiB), and `eui64 e46cfefeffcdae01` —
      identical on both and matching the recorded value — and rungs 30/35
      both passed cross-node against it. **Open question, not yet
      answered:** where does our KV data physically live, given our NQN is
      absent from `smc3`'s target? The medium is shared and demonstrably
      working; we do not know which physical namespace it actually maps to.
- [ ] **6.19** Target's 200G links are UP (`enp132s0`/`enp100s0`, `Link
      detected: yes`, `enp132s0` holds `1.1.0.2/24`), reversing 6.16.
      Neither compute node has an address on `1.1.0.x` yet, so there's
      still no route to that listener — that's the remaining gap, and it's
      now actionable from a terminal (addressing/routing), not blocked on
      physical access.
- [!] **6.20** `smc2` (decode) is reboot-unstable — 7 boots in one day,
      cycling every 3–13 minutes at one point (2026-09-15), and both nodes
      have rebooted unexplained, repeatedly, since; `journalctl -b -1 -p
      err` shows no panic/MCE/OOM/thermal event for most of them. One
      instance is explained (an oversized per-worker
      `LMCACHE_MAX_LOCAL_CPU_SIZE`, HANDOFF §4 invariant 9); most are not.
      **Check `uptime` before starting anything that takes minutes.** Not
      diagnosable from a terminal alone if power/thermal/firmware — the
      BMC event log is next. See HANDOFF §7.13. *Blocks any long-running
      work on decode.*
- [ ] **6.21** 🔴 **The LMCache L2 retrieve blocker — the live blocker for
      6.10/6.15.** Never launch the vendor's `deploy-xnvme.sh` without
      overriding `AIC_XNVME_DEV` — its default `/dev/ng0n1` is the OS boot
      drive on both `smc1`/`smc2`, not a KV device; the real local
      Pensando DSC is `/dev/ng1n1` (HANDOFF §4 invariant 10). Always set
      `AIC_XNVME_DEV=/dev/ng1n1` explicitly.

      **The retrieve blocker itself, measured 2026-09-16/17 — live vLLM
      engines: store=36,864, retrieve=0, on both roles.**
      `nixl_store_l2_adapter.py` names every stored object
      `obj_{i}_{uuid4().hex[0:4]}`, a fresh `uuid4` drawn per daemon at
      startup. **This is not a uuid4 typo and not fixable by swapping in a
      content hash:** these names are PRE-REGISTERED POOL SLOTS, built
      once by `init_storage_handlers_object(page_size, num_pages)` at
      daemon startup, which never sees a content key at all — the
      content→slot map lives in an in-process dict that dies with the
      daemon. `pool_size` is required `>0`; there is no `pool_size=0`
      content-addressed escape hatch under `nixl_store`. Cross-node
      LMCache retrieve is therefore impossible by construction, regardless
      of device or topology — confirmed by 6.25's roundtrip proving the
      identical plugin/device/namespace supports cross-node store+retrieve
      directly, while the live engines' counters stayed unchanged
      alongside it. This is an LMCache patch to make, not an open-ended
      investigation. See HANDOFF §4 invariant 1, §2.

      **RESTATED 2026-09-18 — this was always TWO blockers, and the one
      named above is the second.** Blocker 1: `nixl_store`'s lookup
      consults ONLY its in-process `_memory_objects` dict, so a daemon
      never asks the device about a key it did not store — every
      cross-daemon lookup misses *before naming is consulted*. Discovery
      is a MISSING OPERATION, not a wrong value; that is why restoring the
      plugin's `queryMem()` override correctly changed nothing. Blocker 2
      is the naming. Neither fix alone helps. HANDOFF §2.0, §7.14.

      **The "separate, still-open question" is ANSWERED and is NOT a bug.**
      `retrieve_ops=0` on prefill alone is caused by L1 never evicting, so
      L2 is never read back — measured:
      `Prefetch request completed (L1+L2): 4/4 retained keys (4 L1, 0 L2)`.
      **Consequence:** a correct implementation shows the same thing on a
      warm same-daemon path. Only a COLD READER proves anything.

      **Superseded by 6.28** — `nixl_store` is not being fixed; it is kept
      byte-identical as the A/B control (`LMCACHE_L2_ADAPTER_TYPE=nixl_store`)
      and `nixl_kv` replaces it.
- [x] **6.22** `KV_BACKEND` default flipped `SPDK_NVMe_KV`→`XNVME_KV`
      (2026-09-16), matching 6.3's decision; `SPDK_NVMe_KV` stays wired for
      comparison (HANDOFF §1). Separately: the DSC wedges under sustained
      load — signature is `completions_err`/`stalls` in exact multiples of
      the 64-deep queue (e.g. `704 == 11×64`), worsening within a session
      up to a full first-store hang; only a DPU-side restart clears it,
      host-side resets make it worse. Cleared to `completions_err=0`/
      `stalls=0` after both nodes were rebooted 2026-09-17 — not proven
      immune to recurrence under the same load.
- [x] **6.26** The DSC NVMe controller has a boot-time race: the kernel
      probes it (`0000:36:00.0`) ~3 s after PCIe enumeration, before the
      DPU-side app is ready, gets `CSTS=0x0`/"Device not ready", detaches,
      and nothing re-probes it — `/dev/ng1n1` then stays absent. Not a dead
      card: the DSC's other PCI functions (`pds_core`, `ionic`) bind fine,
      config-space reads succeed, and the link is healthy. Recovery,
      validated repeatedly on both nodes, no reboot needed, once the DPU
      side is confirmed up:
      `echo -n "0000:36:00.0" > /sys/bus/pci/drivers/nvme/bind` (~2 min;
      fails identically if the DPU side isn't ready yet — just retry).
      Success looks like `nvme nvme1: 63/0/0 default/read/poll queues`
      then `block device for nsid 1 not supported (csi 1)` — the second
      line is EXPECTED. **Per the hardware owner, this is expected
      behavior, not a defect** — a documented per-boot procedure (HANDOFF
      §3.4), not an open bug.

      **Sharpened 2026-09-18: the retry is not deterministic on the first
      attempt.** Both nodes hit the identical `Device not ready; aborting
      initialisation, CSTS=0x0` signature at t=6.1s after a fresh reboot;
      the documented rebind failed twice with the same signature before
      succeeding on the third attempt, ~20 minutes after boot. Expect to
      retry over a span of minutes, not once — "just retry once it is
      [ready]" above understates it.

      **Sharpened again 2026-09-21: it can also be near-instant.** `smc1`
      hit the identical race after its 06:36 reboot (`CSTS=0x0` at
      06:36:14), and the documented rebind succeeded in **0.08 s** — not
      the ~2 min this item documents, and nowhere near the 128 s failure
      that ended the 2026-09-18 session. Success signature matched exactly
      (`nvme nvme1: 63/0/0 default/read/poll queues` then `block device for
      nsid 1 not supported (csi 1)`). **Reading revised:** rebind latency
      tracks DPU-side readiness, not a fixed host-side cost — neither
      "~2 minutes" nor "retry over a span of minutes" is the whole story;
      it can be sub-second or it can take 20+ minutes, and the difference
      is on the DPU side, not observable from the host.

      **BROKEN AGAIN, differently, 2026-09-22 — the hardcoded address
      in this item is now WRONG.** After the driver/software update
      (6.44), `0000:36:00.0` is no longer the NVMe function at all —
      it is now `Ethernet controller [0200]: AMD Pensando Systems DSC
      Management Controller [1dd8:1004]`, bound to `ionic`. The KV
      device (`Non-Volatile memory controller [0108]:
      ... DSC NVMe Controller [1dd8:1005]`) is now at **`0000:37:00.0`**
      on **both** nodes. `setpci -s 36:00.0 00.L` now reads
      `10041dd8`, not this item's documented `10051dd8` — that value
      belongs to the NVMe function, which moved. Rebinding at the NEW
      address worked **instantly** (0.09 s) on both nodes and restored
      `/dev/ng1n1` with IDENTICAL identity (`mn=PDSNVME`, `csi 0x1`,
      `eui64 e46cfefeffcdae01`) — so this is a pure address relocation,
      not a change in what the device is.

      **The lesson, and the fix: DISCOVER the address, never hardcode
      it.** The `0000:36:00.0` literal above (and the identical one in
      HANDOFF §3.4/§2, BRINGUP §1.3, `scripts/common/lib.sh`,
      `scripts/target/51-reset-smc3-storage.sh`, and
      `creds/setup-4.env`) is now known-fragile — it moved once already
      and nothing says it cannot move again on the next update. Resolve
      the PCI function by CLASS, not by address — the same lesson as
      Invariant 10 (resolve the KV device by NQN, not by path), applied
      one PCIe layer down:
      ```bash
      # [SMC1]/[SMC2] — find the Pensando NVMe-CLASS function, whatever
      # address it is at
      PCI=$(lspci -nn -d 1dd8: | awk '/\[0108\]/{print $1}')   # 0108 = NVMe class
      echo -n "0000:${PCI}" > /sys/bus/pci/drivers/nvme/bind
      ```
      See 6.44 for the full record of this update, including the other
      two findings from the same day (SRQ now supported, fabric links
      down).

### 6.23 The in-process `LMCacheConnectorV1` config surface is removed

Removed the dead in-process `LMCacheConnectorV1` config surface:
`gen-lmcache-config.sh`, `LMCACHE_CONFIG_FILE`, `LMCACHE_LOCAL_CPU`, and
`start-vllm.sh --skip-validate`. Verified dead — `LMCacheMPConnector` never
reads any of it; the live surface remains `start-lmcache-daemon.sh`'s
`--l2-adapter` flag, unmodified.

### 6.24 `XNVME_KV`'s device `value_max` moved 32768 → 4096 — CLOSED: the ceiling is 32768, not 4096

`XNVME_KV`'s device-reported `value_max` moved 32768→4096 underneath us
(shared-hardware drift). **Retracted the same day:** the advertised 4096 is
not the real ceiling — probed by storing single values at each size with
`NIXL_XNVME_KV_DEBUG=1`: 32768 → `ok=1 sct=0 sc=0` (PASS, reads back
cross-node); 33792/34816/36864/40960/49152/65536/131072 → `ok=0 sct=7 sc=234`
(FAIL, all of them). **32768 is the EXACT ceiling.** `KV_MAX_VALUE_SIZE_XNVME`
is reverted to 32768, the plugin was rebuilt on both nodes to match, and
`20-verify-nixl-plugin.sh` now passes 6/6 on both. The resulting startup
WARNING (configured value exceeds the advertised one) is expected and
correct — do not silence it by lowering the config, and do not set
`NIXL_KV_STRICT_DEVICE_CEILING=1`. See HANDOFF §2, §7.11, §4 invariant 4.

### 6.25 Cross-node store+retrieve PROVEN, both directions — the topology blocker is gone

`/dev/ng1n1` on both `smc1` and `smc2` is the SAME namespace: `nvme ns-descs`
returns identical `csi: 0x1` and `eui64 e46cfefeffcdae01` on both — each
node's own Pensando DSC is itself an NVMe-oF initiator peered to `smc3`, not
an independent local device. On a namespace confirmed clean beforehand
(`nuse: 0`), with keys derived from `(nonce, size)` via sha256 (neither side
sees the other's key directly):

| direction | size | parts | result |
|---|---|---|---|
| `smc1` write → `smc2` read | 24,576 B | 6 | `RESULT:OK` |
| `smc2` write → `smc1` read | 1,048,576 B | 256 | `RESULT:OK` |
| `smc1` write → `smc2` read, production geometry (32768 ceiling) | 196,608 B | 6 × 32768 | `RESULT:OK` |
| negative control: never-written nonce | — | — | `RESULT:QUERY_MISS`, non-zero exit |

This closes the topology question this project carried since day one — a KV
storage backend can be a shared, cross-node tier, proven directly rather than
inferred from matching `eui64`s. The remaining blocker was never topology: it
is 6.21, LMCache's own per-daemon key naming. HANDOFF §1, §2.

### 6.27 The DSC DOES report retrieve length in `cdw0` — ANSWERED

When the retrieve-length validation was added to `completion_trampoline()`
(`plugins/xnvme-kv/xnvme_kv_backend.cpp`), whether this DSC populates `cdw0`
with the retrieved value's length on Retrieve at all was an open
MUST-MEASURE. **Answered: yes.** Measured across a 6-part 196,608 B
cross-node read, every part reporting `len=32768 → cdw0=32768`. The
short-read guard is therefore live on this hardware, not a no-op; the
`cdw0==0` fallback stays in the code for devices that don't report a length.
HANDOFF §2.

### 6.28 ✅ RESOLVED — the fault was 6.34's OBJ descriptor aliasing, not the LMCache→adapter seam; 6.34's fix closes it end to end

*Start here for how this was diagnosed, then 6.34 for the mechanism, the
fix, and its verification — rung `60` step 5 now PASSES on that fix,
which is the closing evidence for this item.* The design is written
([docs/design/nixl-kv-l2-adapter.md](design/nixl-kv-l2-adapter.md), including
§11's record of decisions taken where the spec was silent) — **do not
re-derive it**. **Diagnosed 2026-09-18:** rung `60` ran twice this session
(first without the attempt counters, then with them) and the combination
falsified the leading hypothesis below and isolated the real fault to the
adapter's commit-object write. 6.34 has since gone further and established
the exact mechanism (OBJ descriptor aliasing between the live page
registration and the commit registration) with direct debug-key evidence —
this item's diagnosis work is done; the counter values below are the
record of how it was reached.

**What was run (2026-09-18).** `scripts/verify/60-verify-l2-crossnode.sh`'s
sequence, executed step by step. All three maskers excluded structurally, not
by argument:

| Masker | Exclusion | Verified |
|---|---|---|
| vLLM's own prefix cache | decode container **recreated** | `L1 objects=0`, all counters 0 |
| P→D `NixlConnector` leg | prefill vLLM **and** daemon killed | prefill confirmed unreachable |
| L1 / in-process index | fresh daemon in fresh container | `stored_object_count=0` |

The test nonce was computed **only by prefill** (`l2_commit_writes` 4→8).

**Result:** `l2_device_hits=0`, `l2_index_hits=0`, `l2_probe_errors=0`,
`Avg prompt throughput: 108.3 tokens/s`,
`External prefix cache hit rate: 0.0%` — decode recomputed everything.
LMCache *was* consulted (connector live, reported 0.0%) and L1 was empty, so
the request should have reached the adapter's lookup and probed the device.

**Blocking sub-task — instrumentation. DONE, and RUN this session (see
below).** Landed in `overlays/lmcache/nixl_kv_l2_adapter.py`:
five attempt counters — `l2_lookup_calls`, `l2_lookup_keys`,
`l2_lookup_executions`, `l2_keys_probed`, `l2_probe_misses` — all exposed
via `report_status()` on the daemon's `:8080/status` alongside the existing
five outcome counters.

`l2_lookup_calls` is counted on the SYNCHRONOUS entry
(`submit_lookup_and_lock_task`), deliberately NOT inside the coroutine:
counting it in the coroutine would leave "LMCache never called lookup" and
"our event loop never ran the coroutine" indistinguishable, because
`asyncio.run_coroutine_threadsafe` swallows the latter. `l2_lookup_executions`
is the coroutine-side counterpart; a gap between the two IS the wedged-loop
signal.

Two one-shot INFO logs were also added: `FIRST DEVICE PROBE` (reader) and
`FIRST COMMIT WRITE` (writer), each naming the first commit key that daemon
probes/writes. Together they make the writer-vs-reader name comparison a
two-line grep across the two daemons' logs — see below for the run that
used it, and 6.34 for the comparison it produced.

How to read the combination (this is the reading the run below actually
produced):

- `calls==0` → the LMCache→adapter seam never called us; fault is ABOVE the
  adapter.
- `calls>0` & `executions==0` → wedged event loop.
- `keys_probed==0` & `calls>0` → everything short-circuited on the
  in-process index, device never asked.
- `probe_misses>0` → we probed and the device said absent — a
  naming/key-derivation divergence, NOT plumbing.

Offline coverage: `overlays/lmcache/test_nixl_kv_naming.py` is now **38/38**
(was 31); the 7 new tests are structural (`ast`-based), because the adapter
class sits behind the nixl/lmcache import guard and cannot be instantiated
on a control host. Mutation-tested: moving the `l2_lookup_calls` increment
into the coroutine, deleting a `report_status` key, and removing the
probe-name log call site were each caught by the tests meant to catch them.

**Both runs above happened this session.** The first (no counters) left
`l2_device_hits=0` undiagnosable; the second (counters live) resolved the
ambiguity on its first run: `l2_lookup_calls=1`, `l2_lookup_executions=1`,
`l2_keys_probed=4`, `l2_probe_misses=4` — lookup ran and the device said
ABSENT for every key. **This diagnosis is now closed** — the tier still
serves zero hits, but that fact is fully explained by 6.34, and the live
piece of work is 6.34's fix, not another run of this rung.

**That comparison has now been made — the hypothesis is FALSIFIED.** The
writer's and reader's one-shot logs name the identical commit key, byte for
byte (6.34 has the exact strings). `model_name`, `chunk_hash`,
`cache_salt`, `kv_rank`, and `object_group_id` all agree; naming divergence
between the two roles is not the cause and must not be re-investigated. The
`prefetch lookup_phase_count = 0` reading that once looked suggestive of a
naming split is superseded by this direct comparison.

**That check has now been done, and it clears the seam above the adapter.**
Rung `35` proves the naming scheme works cross-node byte-exact (6.29); the
attempt counters now additionally prove the LMCache→adapter lookup path
itself runs correctly end to end. The fault was inside the adapter, on the
STORE side — 6.34.

**Closing evidence, 2026-09-18.** 6.34's fix (monotonic `devId`, page dlist
deregistered before the commit registration is created) is landed and
verified. Rung `60` step 5 — the same acceptance sequence this item's
diagnosis was built on — **PASSES for the first time**: a cold decode node
served content only prefill had computed, `l2_device_hits=4`, token
identity confirmed. This item is resolved end to end, not just diagnosed;
6.34 carries the fix and the full verification chain (A/B/C).

### 6.29 ✅ `nixl_kv` — built, registered, and proven at the naming layer

- `overlays/lmcache/nixl_kv_l2_adapter.py` — content-addressed L2 adapter.
  Names: `{ns}@{object_key_string}~{ordinal}` per page plus a
  `{ns}@{object_key_string}!c` commit object written **only after every page
  is durable** (this medium has no `os.rename`; the commit record is the
  whole atomicity story). Lookup probes **only the commit key** — 1 Exist per
  ObjectKey instead of 9,216, i.e. 57 µs instead of 0.53 s per chunk.
- **Registration costs ZERO vendor-file edits**: `l2_adapters/__init__.py`
  auto-discovers any `*_l2_adapter.py` in the package dir via `pkgutil`, so
  the adapter is simply bind-mounted in (`container.sh adapter-overlay` /
  `adapter-check`). It also leaves `nixl_store` byte-identical as an A/B
  control.
- `ns` is a geometry fingerprint over
  `v1|MODEL|TP|CHUNK|KV_CACHE_DTYPE|align_bytes|max_value_size`, derived
  independently on both nodes (`d9dbd20693b2`). `ObjectKey` carries **no
  dtype and no KV-plane layout**, and patch `0009` exists because a plane
  mismatch corrupts silently at identical byte count — the prefix turns that
  class of divergence into an ordinary MISS.
- 31 offline unit tests, no NIXL/LMCache/hardware needed. **Mutation-tested**:
  reverting the probe check to truthiness, dropping the tile ordinal, and
  changing the key format were each caught by the specific tests meant to
  catch them.
- Rung `35` (`35-verify-nixl-kv-smoke.sh`): **8/8**, both directions, three
  negative controls. **Coverage gap, found 2026-09-18, closed 2026-09-18:**
  rung 35 writes its commit object through the raw NIXL agent path, one
  name registered at a time, and never held two overlapping OBJ
  registrations — so it could not have caught 6.34's aliasing bug, and
  structurally still can't: it is a naming-scheme proof, not a regression
  guard for that class of bug. The gap is closed by six new offline tests
  in `test_nixl_kv_naming.py` (44/44) that construct exactly two
  simultaneous, overlapping OBJ registrations and assert the second one's
  writes land under its own name — those tests, not rung 35, are what
  would catch a recurrence.
- **Known gap, deliberate:** namespace capacity is not enforced. 1 GiB /
  4096 = 262,144 pages ≈ **28 chunks ≈ 7,000 tokens** for this model, with no
  device delete primitive, so space is never reclaimed. This tier is
  *demonstrable*, not *usable*, at current sizing — raise with the hardware
  owner (relates to 6.18).

### 6.30 Patch `0011` was never in the image; its check could not fail

`0011` (the `num_external_tokens` guard on `LMCacheMPConnector`'s load path)
was **absent** from `rocm-aic:mp-pd-ionic2609`, and so was its sibling `0010`.
`patches/lmcache/README.md` claimed otherwise because its check grepped
`num_external_tokens`, which matches the *unpatched* signature and docstring.

This matters: we run `MultiConnector[NixlConnector, LMCacheMPConnector]`,
exactly the composition `0011` guards — without it a non-chosen sub-connector
creates a retrieve that must not happen and **leaks lookup locks**.

Now applied by `container.sh lmcache-patch`, derived from the image's own copy
with five self-invalidation guards (already-patched / line absent /
duplicated / wrong enclosing function / output not valid Python), all five
exercised. Resolved via `importlib.util.find_spec()` rather than a filesystem
`find`, because the module exists at three paths in the image and mounting
over a build-tree copy is a **silent no-op**. HANDOFF §2.2, §7.15.

### 6.31 `0006`–`0009` diffs deleted; the image is vanilla + three overlays

Verified in a **fresh container with no mounts**: `0006`/`0007`/`0008`/`0009`
are present in the image, which is itself vanilla (every layer
`docker build`/buildkit, no `docker commit`). Their `.patch` files were
deleted under a new policy — *if the vendor image ships it, this repo does not
carry the diff* — with sha256s recorded for identity-checking a copy recovered
from git history, and a rewritten, **discriminating** re-verification recipe.

Also recorded: what actually runs is the image **plus three bind-mount
overlays**, and one is load-bearing — **the image's own
`libplugin_XNVME_KV.so` has no `nixlXnvmeKvEngine::queryMem` override**, so
existence probing (and therefore all L2 discovery) exists only because the
repo-built plugin is mounted over it. HANDOFF §2.1, §7.16.

### 6.32 ✅ `60-verify-l2-crossnode.sh` — six defects found by running it; the rung now runs to completion

Written 2026-09-18 and exercised twice this session. The first exercise
(the manual run that produced 6.28's original result) had to work around
the first three defects below; the second (scripted, end to end) surfaced
three more before completing and producing 6.34's diagnosis. Each is the
"a check can fail while proving nothing" family (HANDOFF §7.12). All six
fixes have landed in the script, which now runs end to end (10/11 checks,
the one failure being 6.34):

1. **`role_down` did not actually stop the daemon** — measured:
   `pkill -f lmcache.v1.multiprocess.http_server` left it running (same pid
   before and after), so L1 and the in-process index stayed warm and the
   "cold reader" was not cold. `pkill -f api_server` kills vLLM fine — that
   asymmetry was the trap. **Fixed:** `role_down` now tears the container
   down via `container.sh down <role>` and then PROVES the daemon is gone by
   curling `:8080` over plain ssh, `die`ing if it still answers; `role_up`
   correspondingly `container.sh up`s first. Consequence worth recording:
   step 3's writer-unreachable check had to stop using `container.sh exec`,
   because with the container removed an exec-based curl would be
   vacuously "unreachable" regardless of actual state — a check that passes
   while proving nothing, the exact family this repo keeps hitting.
2. **`role_up` sent start output to `/dev/null`**, so a vLLM that starts and
   dies presents as a silent 600 s timeout — it cost a full diagnostic
   cycle. **Fixed:** `role_up` now captures the backgrounded start to
   `/tmp/60-acc-<role>-<nonce>.log` and prints the last 40 lines before
   `die`ing on timeout.
3. **Step 0's drain silently failed** (`50-reset-namespace.sh` non-zero from
   the control host) and the script only warned — a stale namespace can turn
   a real MISS into a spurious HIT. **Fixed:** step 0's drain failure is now
   FATAL. Step 7's stays a warning (a stale namespace there cannot manufacture
   a false PASS the way step 0's can) but now says the control is VOID.
4. **New:** step 5 now reads the five attempt counters and, when
   `l2_device_hits==0`, prints a self-diagnosing interpretation block, so a
   failing run does not cost another full cycle.
5. **`engine_gen()` declared a third parameter (`prompt`) it never read**,
   while all five call sites passed two — under `set -u` this killed the
   run on `"$3: unbound variable"` **after both models had already loaded**
   (~5 min in). **Fixed:** the stale parameter is removed; the prompt is
   read from a file on the node, not passed as an argument.
6. **The prompt was staged on the HOST's `/tmp` via `_ssh`, but
   `engine_gen` reads it INSIDE the container via `_in`.** The container
   does not share the host's `/tmp`, so staging wrote a file nothing ever
   read (`FileNotFoundError`, again ~5 min in). **Fixed:** `stage_prompt()`
   stages the prompt INSIDE the container.
7. **Compounding 6: `role_down` REMOVES the container**, destroying its
   `/tmp`, so anything staged before the cold-start sequence is gone by the
   time it is needed. **Fixed:** `stage_prompt()` is called after EVERY
   bring-up (initial, step 4, step 6, step 7), not once up front.

Defects 5–7 generalise as the same family already named above: a check
that fails while proving nothing, and a setup step whose vantage point
doesn't match its reader's.

**New capability: `--no-drain`.** `50-reset-namespace.sh` RESTARTS
`nvmf_tgt` on the shared target, which would destroy the other party's
RAM-backed namespace — forbidden by §3.2.2/6.18. `--no-drain` skips it with
a loud warning. **The soundness argument, stated honestly:** the drain is
defence-in-depth, NOT the soundness argument — soundness comes from the
per-run nonce (content, and therefore chunk hashes and ObjectKeys, unique
to each run) plus step 6's "unseen nonce must MISS" negative control, which
passed. **This session's run used `--no-drain`**, so step 7's negative
control was VOID and is reported as such.

**New: the rung harvests names before they're destroyed.** The writer's
`FIRST COMMIT WRITE` is captured in step 2, BEFORE step 3 destroys that
container, and the reader's `FIRST DEVICE PROBE` in step 5; the script
prints them side by side and branches on agree/differ. Harvesting late
would have been the same as not instrumenting at all.

Negative finding, recorded rather than fixed: the "nuse grows" assertion
this section previously described was searched for and **does not exist
anywhere in the repo** — only an accurate comment saying nuse is unusable
survives, in the script itself. That comment's warning stands: `nuse` does
not track KV writes on this device — measured `0x0` after 256+ pages stored
and read back. Use `l2_commit_writes`, or the plugin's `m_completions_ok`.

### 6.33 Move the value-size split into the plugin's `postXfer` (Option A)

`0007`'s `mem_split_n`/`#{j}` scheme splits oversized values **in LMCache**,
inside an image we cannot rebuild. The plugin is C++ we own and rebuild in
~2 minutes, it is the layer that knows the device ceiling, and GDS already
does exactly this internally — so the split arguably belongs in `postXfer()`,
which would delete `0007` and its hand-mirrored copy in `_kv_roundtrip.py`.

Not urgent: on the live path `page_size=4096 ≤ max_value_size=32768`, so
`_resolve_mem_split()` returns 1 and the split path is **dead code today**.

Four things it must own, or it just relocates the hazard:
1. **`queryMem` symmetry — a live bug if missed.** LMCache would register the
   *unsuffixed* name, so `make_key(metaInfo)` would name nothing on the
   device and every split object would report MISS.
2. **Retrieve-side part count** must be recorded, not inferred from the
   descriptor length.
3. **Partial-write atomicity gets worse**, not better — n sub-values with no
   commit record, each full-length, so the `cdw0` guard passes.
4. **Geometry drift** becomes invisible to Python.

Note the device allows a 16-byte key and `make_key()` emits 12 — the 4 spare
bytes can carry a part ordinal structurally instead of hashing it in.

### 6.34 ✅ FIXED and verified — OBJ descriptor aliasing between the live PAGE registration and the COMMIT registration is gone; the tier now serves a genuine cross-node hit

**Resolved 2026-09-18.** The mechanism below (established the same day with
direct debug-key evidence) is fixed by two changes in
`overlays/lmcache/nixl_kv_l2_adapter.py`, and both the missing-commit-object
and the page-corruption consequences are independently verified gone by
direct device inspection (Verification C, below). The diagnostic chain that
follows is kept in full — it is the record of how the fault was found and
is why the fix takes the shape it does.

Established 2026-09-18 with **direct evidence**, superseding the previous
"mechanism not yet isolated" framing. Method: daemon restarted with
`NIXL_XNVME_KV_DEBUG=1`, one generation driven through decode's own engine,
the plugin's per-op debug lines (`op=store key=<hex> len=<n> t=submit`)
analysed against independently predicted keys.

**Mechanism.** `NixlKvStorageAgent.register_obj_names()`
(`overlays/lmcache/nixl_kv_l2_adapter.py`) builds every OBJ descriptor as
`(addr=0, len=slot_size, devId=i, metaInfo=name)` — **every entry sits at
address 0**, distinguished only by `devId` = its position in that call's
name list. In `_execute_store_in_the_loop`, the PAGE registration (this
session: 36,864 entries, `devId` 0..36863, `addr=0`) is deregistered only
in the trailing `finally` — it is still **live** when the COMMIT
registration (4 entries, `devId` 0..3, `addr=0`) is created a few lines
later. The two OBJ registrations are therefore indistinguishable by
`(addr, len, devId)` for `devId` 0..3.

The plugin (`xnvme_kv_backend.cpp:1212`, `postXfer`) resolves object
identity from `file_desc.metadataP` (`nixlXnvmeKvMD::meta_info`) and calls
`make_key(devId, addr, meta_info, ...)`. The comment at that call site says
this exists so callers "don't collide on devId/addr alone" — but the guard
only works if `metadataP` resolves to the intended registration, and with
two live registrations sharing `(addr=0, devId=0..3)`, NIXL binds the
commit descriptors' `metadataP` to the still-live **PAGE** registration.
`make_key()` then hashes the **page's** name, not the commit's.

**Evidence:**

1. `make_key()` replicated in Python (FNV-1a 64 over `meta_info`, seeds
   `14695981039346656037` / `0x9E3779B97F4A7C15`, 8 bytes of `h1` LE + low
   4 bytes of `h2` LE = the 12-byte key) and **validated**: it predicts the
   exact keys appearing in the plugin's own debug output for page
   ordinals.
2. The predicted key for the commit name
   (`5571a49e2ab93c0865eaf3c6`, for commit name
   `d9dbd20693b2@Qwen/Qwen3-8B@01000100@0@ccf4461a92c0b745e0814642299dfcec0d5aa546010ba58bec152e10f158789f!c`)
   appears **zero** times in the debug log — the commit write is never
   submitted under its own key.
3. **36,868 store submits, all `len=4096`, but only 36,864 distinct
   keys.** Zero adapter store-task failures, zero exceptions, zero NIXL
   errors anywhere in the daemon log — nothing was raised.
4. The four doubly-submitted keys are exactly the predicted keys for page
   ordinals **0, 1, 2, 3** — matching `commit_indices = [0,1,2,3]` for the
   four commit objects in the batch. This is the aliasing, observed
   directly.
5. **Silent data corruption, confirmed by reading the page back.** Page
   `~0` of the object now contains the commit record, not KV bytes:
   `{"ns":"d9dbd20693b2","page_size":4096,"pages":9216,"phy_size":37748736,"v":1}`
   followed by NUL padding. Page `~5000` of the same object still holds
   intact bf16 KV data — the commit payload physically overwrote page 0.

**Severity — two consequences, and the second is worse than the one being
chased.**

1. The commit object never exists. Lookup probes ONLY the commit key
   (design §6 / 6.29), so every cross-node lookup misses even though
   ~100% of the pages are present and correctly named. This is the entire
   6.28 symptom.
2. Pages 0..N-1 of every stored object are silently overwritten with
   commit-record JSON. The data is WRONG, not merely unreachable.

Consequence 2 is currently **masked** by consequence 1 — because lookup
never hits, Load never runs, so the corrupted pages are never read back,
and the acceptance run's token-identity check passed regardless. **Anyone
who fixes the commit-key aliasing without also fixing the page overwrite
will turn a tier that serves nothing into a tier that serves CORRUPTED
KV.**

**Why rung `35` stayed green — sharpened.** `scripts/verify/_nixl_kv_smoke.py`'s
`_xfer()` registers ONE object name, transfers, and deregisters it in a
`finally` — exactly one OBJ registration is ever live. It structurally
cannot produce two overlapping registrations and therefore cannot
reproduce this bug, no matter how thoroughly the naming scheme is
exercised. A regression test for this must hold **two simultaneous,
overlapping OBJ registrations** whose descriptors share `(addr, len,
devId)`, then assert the second registration's writes land under its OWN
names, not the first's. Testing the naming scheme alone will never catch
it.

**Fix taken.** Of the three directions once listed here, the one landed is
the ordering change (deregister the page dlist before the commit dlist is
registered) *plus* the deeper/defensive option (stop deriving OBJ identity
from `(addr=0, devId=index)` at all) — together, not either alone, because
the deeper fix is what makes the guarantee hold across `submit_store_task`'s
concurrent, awaiting coroutines, not just within one call:

1. **`register_obj_names()` now draws `devId` from a daemon-global
   monotonic counter** (`self._next_devid`, under `self._devid_lock`), used
   in both the `reg_list` and `xfer_desc` comprehensions, instead of
   restarting at the call's list position `i` every time. Any two
   simultaneously-live OBJ registrations are therefore disjoint by
   construction — covering both the within-store page/commit overlap this
   item found and the cross-task overlap possible because
   `submit_store_task` schedules concurrent coroutines that await.
2. **The page dlist is now deregistered immediately after the page write is
   confirmed durable, before the commit registration is created** —
   `page_reg_descs`/`page_xfer_handler` are cleared to `None` so the
   trailing `finally` does not double-deregister. Defence in depth: exactly
   one OBJ registration is live across that boundary. `post_non_blocking`
   raises on `ERR`, so durability is already confirmed at that point — the
   design's commit-after-durable ordering (design §6 Store) is preserved,
   not weakened.

`devId` does not affect the device key when `metaInfo` is non-empty
(`make_key()` hashes the name), and `query_exists()` passes `metaInfo`
directly without registering — neither path is affected by the widened
`devId` range.

**Verification (2026-09-18, post-fix).**

**A — Offline, `overlays/lmcache/test_nixl_kv_naming.py`: 44/44** (was 38).
Six new tests target this bug specifically: structural checks on the
monotonic-counter shape plus a behavioural test that constructs two
simultaneous, overlapping OBJ registrations and asserts the second one's
writes land under its own name — exactly what §6.34's "why rung 35 stayed
green" note above said a regression test would need to hold. Mutation-tested:
reverting `register_obj_names` to positional `devId`, moving the early
deregistration to after the commit registration, and deleting the
`page_xfer_handler = None` clear were each caught by exactly the test meant
to catch it, no collateral failures.

**B — Rung `60`, the acceptance run: step 5 PASSES for the first time.** A
genuinely cold decode node (container recreated, counters confirmed at
zero) with the writer's vLLM **and** daemon killed and its container
removed (port confirmed unreachable) served content only prefill had ever
computed: `l2_device_hits=4`, `l2_index_hits=0`, `l2_probe_errors=0`,
`l2_load_aborts=0`, and TOKEN IDENTITY matched the recompute baseline.
Negative control A passed: an unseen nonce produced no new device hits (4
→ 4). Overall **9 of 11** checks passed; the 2 failures are both step 7's
negative control, which is **VOID BY CONSTRUCTION** — this run used
`--no-drain`, so step 2's commit object is legitimately still on the
device, and "a drained namespace yields no device hit" cannot hold under
that condition. The script itself flags the control as void; this is not a
partial failure of the fix. Soundness note: the run used a per-run nonce
(`acc-<epoch>-<pid>`), so its chunk hashes and ObjectKeys are unique to
this run and no object left by a previous run could have satisfied it —
negative control A independently confirms unseen content misses.

**C — Both consequences verified fixed by direct device inspection**, on a
fresh key from a post-fix generation
(`...@28f6a7846aca5715f44b4c4a8606ff3e8ee00121c0fd649fa61f5fedd4a19ffb`):
the commit object now EXISTS (probing `<key>!c` returns HIT — it was MISS
before the fix), and page `~0` now reads back as real bf16 KV bytes
(`\xa3\xc00@\x10@\x1d@...`), not the commit-record JSON it held before the
fix. The silent corruption is gone.

**Operational note — the namespace still holds pre-fix corruption, and
draining it is blocked.** Objects written by PRE-FIX runs still have
commit-record JSON in place of KV bytes at pages 0..N-1. They are keyed by
old per-run nonces, so nothing will ever read them, but they are dead
weight in a 1 GiB namespace with no delete primitive (6.29's capacity
gap), and they will persist until a drain happens.
`scripts/target/50-reset-namespace.sh` **refused to run this session**: it
reports
"kv-target is not running — nothing to reset", because the live `nvmf_tgt`
on the target was not started by this repo's scripts — it is the
long-running process serving `nqn.2016-06.io.spdk:cnode1` (6.18), which
appears to be what actually backs the working `/dev/ng1n1` on both compute
nodes. Draining therefore requires either killing and replacing that
target with this repo's own (`03-start-kv-target.sh`) or an RPC-level bdev
recreate against the one already running — both risk dropping the DSC/DPU
peering that currently makes `/dev/ng1n1` work, and DSC recovery is known
to be non-deterministic and slow (6.26). **This is the open decision
blocking step 7's validation** — record it as such, do not attempt a drain
without deciding it first.

**Superseded 2026-09-21 — see 6.41.** The premise above, that draining
requires touching smc3's `nvmf_tgt`, no longer holds: 6.36 had already
shown our data never reaches smc3, so restarting its target was never the
operation that would drain OUR medium — the "open decision" above was
about the wrong store. Separately, an unrelated hardware-recovery cycle
(reboots plus a DSC firmware change, not a deliberate drain) emptied the
namespace outright: every pre-fix **and** post-fix historical object 6.41
probed for came back MISS. **This is not the decision above having been
made — the situation it was about no longer exists.** The historical
reasoning above stays as the record of why `50-reset-namespace.sh`
correctly refused to run; the open decision it names is closed by 6.41,
not resolved as originally framed. Rung `60`'s step 0/7 still need their
drain step re-targeted at the DSC/DPU (or replaced with a probe-based
emptiness check) before they can be re-run meaningfully.

### 6.35 ✅ KV-block-level measurement exists and is PROVEN — via `lmcache bench l2`, unblocked by an upstream L1-indexing defect

**Measured 2026-09-18 on `smc2` (decode), against `nixl_kv`/`XNVME_KV`
on `/dev/ng1n1`.** This answers the "how many KV blocks, what hit rate,
what block size, what store/read bandwidth" question directly, at the L2
adapter — **no vLLM, no proxy, no TTFT anywhere in the number.**

**The tool.** LMCache 0.5.3 ships `lmcache bench l2`
(`lmcache/cli/commands/bench/l2_adapter_bench/`). It drives an L2 adapter
through its real `submit_store_task`/`submit_lookup_and_lock_task`/
`submit_load_task` interface using the same `--l2-adapter '<JSON>'` spec
`start-lmcache-daemon.sh` already builds, and reports per operation:
total keys, total success, **actual hit rate**, MB/s avg/min/max, ops/s,
per-key latency, p50/p99. Upstream also ships `benchmarks/storage_backend_io`
and `benchmarks/microbenchmark`.

**Blocker found, and it is UPSTREAM, not ours.** `lmcache bench l2`
cannot drive *any* NIXL-backed L2 adapter as shipped:

```
makeXferReq: local index out of range at index 0 with value 340075
nixl_rocm._bindings.nixlInvalidParamError: NIXL_ERR_INVALID_PARAM
```

`NixlStorageAgent.init_mem_handlers()` builds the L1 transfer dlist
**base-relative** (entry `i` is `buffer_ptr + i*page_size`), but
`NixlStorageAgent.get_memory_indices()` returns an **absolute** page
number, `raw_addr // l1_align_bytes`, with no base subtracted. The two
agree only when `buffer_ptr == 0`. Measured with the benchmark's own
buffer: `ptr=665980928`, 32 dlist entries, absolute index `162593`
(out of range) vs correct relative index `0`.

**Confirmed upstream, not a `nixl_kv` regression:** the untouched vendor
`nixl_store` fails on the identical line with the identical error and
`Total success: 0`. `nixl_kv` inherits `get_memory_indices` unchanged.

**Fix used, deliberately process-local:** `scripts/bench/l2-block-bench.py`
patches the vendor base class **in the benchmark process only** to be
base-relative, and range-checks the result so an out-of-bounds index
raises instead of silently landing on the wrong page. The adapter file on
disk and the running daemon are untouched. Round-trip verification
(`--no-skip-verify`) passes byte-exact at every block size, which is
independent evidence that base-relative is the correct reading.

**🔴 OPEN QUESTION — is production silently mis-indexed?** The live MP
daemon uses the same absolute arithmetic (`L1MemoryDesc.ptr =
buffer.data_ptr()`, a real pointer — `l1_memory_manager.py:213`). It does
not crash only because the production L1 buffer is 4 GiB (1,048,576 dlist
entries), so `addr // 4096` lands *in range* — but shifted by
`ptr // 4096`. In-range-but-wrong is exactly the silent class this repo
keeps hitting (HANDOFF §5, 6.34). Rung `60`'s token-identity pass argues
against actual corruption, so this is **not** an assertion of a
production bug — it is an untested hypothesis that needs its own decisive
test (store a known pattern, read it back by direct device inspection at
a known offset) **before** anyone changes `get_memory_indices` on the
serving path.

**Results — adapter level** (32 keys/round, 3 measured rounds + 1 warmup,
`--l1-align-bytes 4096`, one namespace per point, all ops 96/96 success,
round-trip verified):

| block | pages/key | device ops | store MB/s | load MB/s | store ms | load ms |
|---|---|---|---|---|---|---|
| 16 KB | 4 | 160 | 12.2 | 10.0 | 41.1 | 53.4 |
| 64 KB | 16 | 544 | 40.0 | 36.5 | 55.3 | 57.9 |
| 256 KB | 64 | 2080 | 119.5 | 136.1 | 67.3 | 59.0 |

Per-key latency is nearly flat (1.29 → 2.10 ms) while bandwidth scales
~10x, so this regime is dominated by **per-key/per-batch fixed overhead,
not device bandwidth**.

**Concurrency is the lever, not queue count** (256 KB/key):

| queues | in-flight | store MB/s | load MB/s | peak_in_flight | submit_retry |
|---|---|---|---|---|---|
| 1 | 1 | 119.5 | 136.1 | 64 | 2,159,089 |
| 8 | 1 | 115.4 | 109.8 | 512 | 7,151,168 |
| 8 | 4 | **279.0** | **340.5** | 512 | 37,812,606 |

Raising `NIXL_XNVME_NUM_QUEUES` alone does nothing (the producer is
serialized); raising in-flight submits gives 2.3–2.5x. Note
`submit_retry` is ~568 retries per completed op — the reactor busy-spins
on `-EBUSY` backpressure. **That, not the device, is where the time goes**
and it is the obvious next optimization target.

**Hit rate, measured on a genuine cold reader** (fresh process, empty
in-process index, so every probe reaches the device). Positive and
negative control both clean:

| requested | keys | hits | hit rate | us/key |
|---|---|---|---|---|
| `--lookup-max-hit-rate 1.0` | 96 | 96 | **1.00** | 69–90 |
| `--lookup-max-hit-rate 0.0` | 96 | 0 | **0.00** | 70–88 |

Device probe (KV Exist) costs ~70–90 µs/key and **hit and miss cost the
same** — there is no short-circuit on either. The warm in-process index
serves the same lookup at ~3 µs/key, i.e. the commit-key index is worth
~25x on a repeat.

**Device-level cross-check** — the plugin's own counters
(`NIXL_KV_METRICS_PATH`) reconcile exactly with the adapter-level
predictions, which is what makes the numbers above trustworthy rather
than merely plausible:

| block | predicted ops `(pages+1)*32*4` | `store_ops` | `retrieve_ops` | `store_bytes` | err | stalls |
|---|---|---|---|---|---|---|
| 16 KB | 640 | 640 | 640 | 2,621,440 | 0 | 0 |
| 64 KB | 2176 | 2176 | 2176 | 8,912,896 | 0 | 0 |
| 256 KB | 8320 | 8320 | 8320 | 34,078,720 | 0 | 0 |

`store_bytes == store_ops * 4096` exactly; `retrieve_ops == store_ops`
(load reads back every page plus the commit object). `completions_err=0`,
`submit_fail=0`, `stalls=0` throughout — no DSC wedge (6.22) at this load.
`retrieve_len_checked == retrieve_ops` with `unreported=0`, independently
re-confirming 6.27 (this DSC does populate `cdw0` on every Retrieve).

**Why this supersedes the llama-benchy path for this question.** 1.13's
confound (vLLM's own prefix cache sitting upstream of every connector)
does not exist here at all — this never goes through vLLM. 1.13 and 6.15
remain the right tools for the *engine-level* question; they are not the
right tool for KV-block accounting.

### 6.36 🔴 The KV data does NOT reach smc3 — `/dev/ng1n1` is a LOCAL Pensando PCIe function, and 6.18's open question is answered

**Measured 2026-09-18, end to end, with the full stack live.** This
answers 6.18's standing question ("where does our KV data physically
live, given our NQN is absent from smc3's target?") and **contradicts**
the re-export model HANDOFF §2 has been carrying.

**Evidence, four independent strands:**

1. **smc3's target has never served a single I/O.** `bdev_get_iostat` on
   `dev1_ns1`: `read=0 bytes_read=0 write=0 bytes_written=0`, across an
   `nvmf_tgt` uptime of 1d05h — while we wrote 972 MiB through
   `/dev/ng1n1` minutes earlier.
2. **Its listener is unreachable from compute.** `1.1.0.2:4420` routes via
   the management gateway and the TCP connect fails. 6.19 predicted this
   ("neither compute node has an address on `1.1.0.x`"); it is still true.
3. **The controller is local PCIe, not fabric.**
   `/sys/class/nvme/nvme1/transport` = `pcie`, address `0000:36:00.0`,
   `nvme list-subsys` reports NQN
   `nqn.2019-08.com.pensando:nvm-subsystem-sn-8001-0-0`, and `nvme id-ctrl`
   reports `mn=PDSNVME sn=PDSNVME-00`. That is the DSC presenting its own
   NVMe function — there is no NVMe-oF connection from the host at all.
4. **smc3 serves only the other party's subsystem**,
   `nqn.2016-06.io.spdk:cnode1` / `dev1_ns1`.

**Conclusion: writes terminate in the Pensando DSC/DPU's own KV store.**
The claim that each DSC is an NVMe-oF initiator peered to smc3 and
transparently re-exports smc3's namespace is **not supported by any
measurement**, and is contradicted by (1) and (2).

**What remains genuinely true, and is NOT explained by this:** the medium
really is shared across `smc1` and `smc2` — rungs 30/35 store on one node
and read back byte-exact on the other, with negative controls. So the two
DSCs reach a common store by some path that is **not** smc3's `nvmf_tgt`.
The matching `eui64 e46cfefeffcdae01` on both nodes is weaker evidence
than it looked: it is equally consistent with a fixed identifier in
Pensando firmware. **Open: what actually backs the shared namespace.** Ask
the hardware owner; do not infer it again from `eui64`.

**Operational consequence — the namespace is nearly full.** One driving
run (13 requests, ~7,000 prompt tokens each) wrote **972.1 MiB of a 1 GiB
namespace** with no delete primitive (6.29). Anything further risks
ENOSPC-class failures on a medium shared with another party. Draining is
still blocked (6.34's operational note). **Treat remaining capacity as
exhausted until this is resolved.**

### 6.37 ✅ The full eviction chain L1 → L2 → device is PROVEN under live traffic

Measured 2026-09-18 with `LMCACHE_MP_L1_SIZE_GB=1` (the tracked default of
4 GiB never evicts under any load this cluster can generate, which is why
`retrieve_ops=0` was historically read as a bug — it is not; 6.21).

| Level | Surface | Observed |
|---|---|---|
| Proxy | `:8000/status` | 13 requests, 0 prefill failures, 0 `prefill_no_handoff` |
| vLLM prefill | `:8100/metrics` | `prompt_tokens_total=112,230` |
| LMCache L1 (prefill) | `:8080/status` | 22 objects, 792 MiB / 1024 MiB = **77.3%**, LRU @ 0.8 watermark |
| LMCache L2 (prefill) | `:8080/status` | `l2_commit_writes=103`, `stored_object_count=103` |
| NIXL XNVME_KV plugin | metrics JSON | `store_ops=248,859`, `store_bytes=972.1 MiB`, `err=0`, `stalls=0` |
| Device | `/dev/ng1n1` | 8 queues, `peak_in_flight=512` |

**The arithmetic cross-checks exactly:** 27 commit groups × 9,217 device
ops (9,216 pages of 4096 B + 1 commit object) = **248,859** = `store_ops`,
and `248,859 × 4096 = 972.1 MiB` = `store_bytes`. This independently
confirms the 36 MiB-per-ObjectKey geometry the design doc predicts.

**A genuine cross-node L2 hit was observed under live traffic:** during
the llama-benchy sweep, decode's adapter reported `l2_device_hits=2` with
`l2_index_hits=0` — decode found on the device content only prefill had
written. Small because the workload was deliberately unique-per-request
(no reuse); the point is that it is non-zero on a path with the writer
still running, which 6.34's fix is what made possible.

**MP + ZMQ confirmed, not assumed:** the daemon listens on
`tcp://127.0.0.1:6557` (ZMQ) and `0.0.0.0:8080` (HTTP status), and vLLM's
`--kv-transfer-config` carries
`MultiConnector[NixlConnector(kv_consumer), LMCacheMPConnector(kv_both)]`
with `lmcache.mp.host=tcp://127.0.0.1`, `lmcache.mp.port=6557` — the MP
rendezvous, not the removed in-process surface.

**Device behaviour worth carrying forward:** `submit_retry=175,890,426`
against 248,859 completed ops — ~707 retries per op — and mean device
latency 3,521 µs with 330 ops beyond 64 ms. Zero errors, zero stalls, but
the reactor is busy-spinning hard on `-EBUSY`. Same signature as 6.35's
microbenchmark, now confirmed on the live serving path.

### 6.38 `benchmarks/storage_backend_io` does not cover this stack's KV path

LMCache's `benchmarks/storage_backend_io` (dev branch) benchmarks the v1
**storage_backend** layer: `local_disk`, `rust_raw_block`, `hf3fs_backend`,
`fs_backend`, `bigtable`. It contains **zero** references to nixl, xnvme,
or L2 adapters, so it cannot measure `nixl_kv`/`XNVME_KV`. Use 6.35's
`lmcache bench l2` path for that.

Run for reference only (`local_disk`, 512 ops, concurrency 32):
**206.96 ops/s**, 2.474 s, at 28 MiB/op — but O_DIRECT was off, so that is
page-cache bandwidth (~5.8 GB/s), not disk.

**Do not point `--backend rust_raw_block --raw-device /dev/ng1n1` at this
cluster.** That device is a KV namespace (`csi=0x1`) shared with another
party; raw block writes to it are semantically wrong and a corruption
risk.

**Operational note:** `pip install` inside a role container does **not**
survive `container.sh down/up` — `/usr/local` is not bind-mounted, only
`REPO_ROOT`, `STACK_ROOT` and `HF_HOME` are. Re-run
`01-install-benchy.sh` after any container recreation.

### 6.39 ✅ RETRACTION — the "1 GiB namespace" limit is NOT a byte limit, and does not come from smc3

**The 1 GiB figure repeated in 6.18, 6.29 and 6.36 is wrong as a capacity
bound.** It was derived by reading NVM-command-set LBA fields on a
namespace that has no LBAs, and it is retracted here rather than quietly
edited, because it drove a real (bad) operational recommendation: 6.36
told the next operator to treat capacity as exhausted.

**Where the number came from.** `nvme id-ns /dev/ng1n1` reports
`nsze = ncap = 0x200000` (2,097,152) with `lbaf 0: lbads:9` (512 B), and
2,097,152 x 512 = exactly 1 GiB. That arithmetic is an **NVM command set**
reading. This namespace is `csi 0x1` — the KV command set — and has no
block device and no LBAs; `/dev/nvme1n1` does not exist beside
`/dev/ng1n1` precisely because of that.

**What the KV command set actually reports.** Identify Namespace with
`CNS=0x00, CSI=0x01` (the structure the plugin already queries at
`xnvme_kv_backend.cpp:933`) returns the *same* `NSZE = NCAP = 2,097,152`,
and `NUSE = 0`. For a KV namespace that value is a count of **KV pairs**,
not bytes — which is why it is identical in both structures and why it is
suspiciously round.

**Disproven empirically, not argued.** In one session, through this single
namespace:

| write | ops | bytes | completions_err | submit_fail | stalls |
|---|---|---|---|---|---|
| live serving eviction | 248,859 | 972.1 MiB | 0 | 0 | 0 |
| capacity probe (6.39) | 49,344 | 192.8 MiB | 0 | 0 | 0 |
| **total** | **298,203** | **~1.16 GiB** | **0** | **0** | **0** |

**~1.16 GiB sailed past the supposed 1 GiB ceiling with zero errors.** If
`nsze` bounded bytes, the probe could not have completed a single round.

**The corrected picture.** Reading `nsze` as KV pairs gives 2,097,152 keys.
At the 4096 B page this stack actually uses that is ~8 GiB; at the measured
32768 B value ceiling it is ~64 GiB. We have consumed roughly 298k of
~2.1M key slots — about **14%**, not 95%.

**Three things this does NOT change:**

1. **There is still no delete primitive and no usage telemetry.** `NUSE`
   reads 0 in both Identify structures, and `nuse` does not track KV writes
   (HANDOFF §5). Space is still never reclaimed, and we still cannot
   measure consumption — we can only count our own `store_ops`. Sizing runs
   (BRINGUP §3.6) remains correct practice; the *reason* is key-slot
   exhaustion and unreclaimable space, not a 1 GiB byte budget.
2. **It has nothing to do with smc3.** `bdev_kvmalloc` is an in-memory
   red-black tree with no total-size RPC parameter at all — `cluster.env`
   has said so since `KV_BDEV_SIZE_GB` was deleted. Combined with 6.36
   (smc3 has served zero I/O, its listener is unreachable), the target's
   capacity is irrelevant to this stack in both directions: it is neither
   the source of the limit nor a place freeing space would help.
3. **The real ceiling is still unmeasured.** 1.16 GiB is a lower bound
   established by the largest write we have done, not a limit. Whether the
   DPU enforces `nsze` as a key count, or is bounded by DPU memory, or
   enforces nothing at all, is **untested**. Do not replace one
   unmeasured-number-stated-as-fact with another.

**Lesson worth keeping:** the failure mode here was applying block-device
arithmetic to a device that deliberately has no block semantics — on a
namespace whose whole point is that `csi 0x1` has no LBAs. The same
instinct that made `block device for nsid 1 not supported (csi 1)` an
*expected* log line should have made `nsze x 512` an obviously invalid
computation.

### 6.40 smc3 IS effectively infinite — it advertises 16 EiB, and its real bound is RAM. Neither is our limit, because nothing of ours reaches it

**Investigated 2026-09-18 at the principal's prompting: "the target is
supposed to be infinite storage, but should at least exhaust RAM".** Both
halves of that are correct, and measuring them closes the capacity
question.

**smc3's bdev declares an unbounded namespace.** `bdev_get_bdevs`:

```
name=dev1_ns1  product="KVMalloc disk"  block_size=1
num_blocks=18446744073709551615        # UINT64_MAX -> 16 EiB
```

`block_size=1` with `num_blocks=UINT64_MAX` is `bdev_kvmalloc` saying "I
have no byte budget" — consistent with `cluster.env`'s standing note that
it is an in-memory red-black tree sized only by per-key/per-value
ceilings, and that `KV_BDEV_SIZE_GB` was deleted because it mapped to
nothing. **Theoretically infinite, confirmed from the device's own
report.**

**Its real bound is smc3's RAM, exactly as predicted.** The tree is
RAM-backed, so capacity is whatever the host can hold: `free -g` shows
**62 GiB total, ~32 GiB available**. A KV workload actually landing here
would grow `nvmf_tgt`'s RSS roughly 1:1 and then exhaust memory somewhere
north of 30 GiB — not at any number the namespace advertises. That is the
honest ceiling, and it is ~30x larger than the 1 GiB this repo wrongly
recorded and retracted in 6.39.

**But none of our data goes there — now confirmed three independent ways.**
After ~1.16 GiB of KV written through `/dev/ng1n1` in one session:

| Evidence | Reading | Expected if smc3 were storing ours |
|---|---|---|
| `bdev_get_iostat` on `dev1_ns1` | `reads=0 writes=0 bytes_written=0` | ~298k writes, ~1.16 GiB |
| `nvmf_tgt` hugepages | 7,986 of 8,192 **free** (~412 MiB in use) | hundreds more 2 MiB pages consumed |
| `nvmf_tgt` RSS | 6.56 GiB, flat, over 1d16h uptime | +1.16 GiB against baseline |

Three different mechanisms, one answer. Combined with 6.36 (listener
TCP-unreachable from compute; `/dev/ng1n1` is `transport=pcie` on a
Pensando subsystem), the conclusion is not reasonably in doubt.

**A fourth, sharper discriminator fell out of this.** The two stores
disagree about their own size by twelve orders of magnitude:

| Store | Advertised capacity |
|---|---|
| smc3 `dev1_ns1` (KVMalloc) | `num_blocks = 2^64-1` — unbounded |
| DSC `/dev/ng1n1` (KV Identify) | `NSZE = NCAP = 2,097,152` |

If `/dev/ng1n1` were a re-export of smc3's namespace these would match.
They do not, which settles the re-export question without reference to any
I/O counter.

**So where is the real limit?** The Pensando DSC/DPU's own store, and it
remains **unmeasured**. We know a lower bound of ~1.16 GiB (written, zero
errors) and that KV Identify reports 2,097,152 — most plausibly KV pairs,
which at the 4096 B page is ~8 GiB (6.39). Nothing has established the
enforced ceiling, and this session's attempt to push further contributed
to taking both DSCs down.

**Operational status at time of writing: both DSCs are DOWN.** `/dev/ng1n1`
is absent on smc1 *and* smc2; the hosts are up (7h uptime, no reboot) and
config space reads `10051dd8`, so the cards are alive. Host-side rebind was
attempted on both and failed identically at ~128 s with
`Device not ready; aborting initialisation, CSTS=0x0` — the DPU-side
application is not serving. Per 6.22 only a DPU-side restart clears this
and **host-side resets make it worse**, so repeated rebinding was stopped
rather than continued. This needs the hardware owner.

**Practical upshot for sizing a run:** stop treating the namespace as a
1 GiB budget. The constraints that actually bite are (a) no delete
primitive, so consumption is monotonic, (b) no usage telemetry — `NUSE`
reads 0 in both Identify structures and `nuse` does not track KV writes,
so you can only count your own `store_ops`, and (c) sustained write load
destabilises the DSC, which is now the second session to end that way.

### 6.41 ✅ The Pensando DSC/DPU KV store is VOLATILE — historical objects did not survive; 6.34's drain blocker dissolves

**Measured 2026-09-21, after the recovery recorded at the top of this
file (6.26, 3.10 updates).** With `/dev/ng1n1` back on both nodes, this
session answered the question the previous one left open: did anything
written before the 09-18 wedge/reboot cycle survive?

**Control first.** The geometry fingerprint was re-derived from today's
`config/cluster.env`
(`v1|Qwen/Qwen3-8B|1|256|auto|4096|32768`): `d9dbd20693b2` —
IDENTICAL to the namespace recorded in 6.34. This is what makes a MISS
meaningful rather than a namespace mismatch.

**New capability used.** `scripts/verify/_nixl_kv_smoke.py` now takes
`--literal-name NAME` (probe mode only, mutually exclusive with
`--nonce`, which stays mandatory for write/read). It probes a name
RECORDED FROM A PAST RUN instead of one derived this run — the
nonce-derived grammar structurally cannot ask "did this specific
historical object survive?".

**Run on `smc1` (prefill), in this order:**

| # | probe | result |
|---|---|---|
| 1 | negative control: unwritten nonce | `RESULT:MISS` |
| 2 | positive control: fresh 2-page write | `RESULT:OK` |
| 3 | positive control: probe what was just written | `RESULT:HIT` |
| 4 | historical page `~5000` of the pre-fix object (6.34 evidence 5 recorded it holding intact bf16 KV) | `RESULT:MISS` |
| 5 | historical page `~0` of the same object | `RESULT:MISS` |
| 6 | historical post-fix commit `...28f6a78...!c` (6.34 verification C recorded it HIT on 2026-09-18) | `RESULT:MISS` |

Re-probed from `smc2` (decode): historical page `~5000` and the post-fix
commit both `RESULT:MISS` — the wipe is global to the shared medium, not
per-node.

Full object names used, so a future session can re-probe directly: prefix
`d9dbd20693b2@Qwen/Qwen3-8B@01000100@0@`, then
`ccf4461a92c0b745e0814642299dfcec0d5aa546010ba58bec152e10f158789f~5000`
/ `~0`, and
`28f6a7846aca5715f44b4c4a8606ff3e8ee00121c0fd649fa61f5fedd4a19ffb!c`.

Rung `35` (`35-verify-nixl-kv-smoke.sh`), re-run after recovery: **8/8**,
both directions, all three negative controls — the tier is fully
functional again.

**Conclusion: the Pensando DSC/DPU KV store is VOLATILE.** Its contents
did not survive.

**Attribution limit — be scrupulous here.** At least four things happened
between the two measurements: sustained write load and the DSC wedge
(2026-09-18), several host reboots, a DPU-side restart, and a DSC
firmware change to `-pi-131`. We CANNOT attribute the wipe to any single
one of them. What IS established: the contents of this namespace do not
survive that combination, so nothing in this tier may be assumed to
persist across a node restart or a DSC recovery. **Do not overclaim "a
reboot wipes it"** — that specific causal claim is untested.

**Consequences — all four matter:**

a. The storage tier is a reuse cache WITHIN AN UPTIME WINDOW, not
   persistent storage. This sharpens 4.3, which framed restart survival
   as a consequence of uuid4 key derivation — it is now a property of the
   MEDIUM, independent of how keys are derived.
b. The namespace is EMPTY right now. The drain that 6.34's operational
   note recorded as blocked has effectively already happened, and the
   pre-fix corrupt objects it worried about are gone.
c. **The drain blocker dissolves rather than being solved.**
   `scripts/target/50-reset-namespace.sh` restarts smc3's `nvmf_tgt`, and
   6.36 established our data never reaches smc3. So rung 60's steps 0/7
   were pointed at a store that was never ours, and the "do we dare
   restart another party's target" dilemma (6.18, HANDOFF §3.2.2) was
   never the real question for draining OUR medium. Draining ours means
   cycling the DSC/DPU. The fix is to re-target rung 60's drain step — or
   better, to assert emptiness by PROBING rather than by restarting
   anything.
d. Capacity anxiety (6.29, 6.36, 6.39, 6.40) is defused further:
   consumption is monotonic only within an uptime window, and this
   cluster reboots often (6.20).
e. Any measurement claiming a "cold reader" or a reuse rate must record
   node uptime — the result is only meaningful relative to the window.

### 6.42 ✅ All three KV data paths proven end to end on the live stack, and the first engine-level numbers

**Measured 2026-09-21**, Qwen3-8B/TP=1/XNVME_KV on `/dev/ng1n1`, LMCache
L1 forced to 1 GiB, full stack live (MP daemon + vLLM prefill + decode +
proxy).

**Path 1 — P→D direct.** `scripts/verify/50-verify-pd-direct.sh`, run ON
`smc2` in the container: **9/9**. `external prefix cache hit rate: 98.1%
→ 99.0%`, decode `Avg prompt throughput = 0.0 tokens/s`, verdict "served
by NixlConnector DIRECT transfer".

**State that 0.0 as a PAIR, always.** `Avg prompt throughput` and `Avg
generation throughput` are two different vLLM gauges, and quoting only the
first reads as "nothing was generated" — it was raised as exactly that
misreading. The prompt gauge at 0.0 is the result being claimed (decode
computed no prefill); the generation gauge must be NON-zero, and a 0.0
there would be a failure, not a pass. Confirmed independently from the
`/metrics` scrapes captured in each benchmark run directory: decode's
`vllm:generation_tokens_total` rose **+617** (baseline) and **+1,641**
(prefix-cache) while the prompt gauge read 0.0, and rung 60's TOKEN
IDENTITY check confirms those are the *same* tokens a recompute produces.
The zero is a real zero, not a dead gauge: rung 50's negative control
withholds the handoff and the prompt gauge jumps to **124.7 tokens/s**
(HANDOFF §2) — the positive control that makes a zero admissible (§7.6).
**Do not argue this from `vllm:prompt_tokens_total`:** measured
2026-09-21 it rises by an IDENTICAL amount on both nodes (+2,160,
+36,978), because it counts a request's prompt at both ends and cannot
distinguish KV that was computed from KV that was transferred.

Operational trap found: run from the CONTROL HOST, the same rung reports
`1 of 8 checks failed — decode side channel reachable (30.2.1.1:5601)` —
a FALSE FAIL, because decode's side channel is bound to a fabric address
the control host cannot route to, and the authoritative verdict needs
`/var/log/kvstack/vllm-decode.log`, which is not bind-mounted. This is
1.9's recorded asymmetry finally biting something. Now documented in
BRINGUP §2.4 / §7 item 16.

**Path 2 — write path, engine → L1 → L2 → device.** 14 requests of
~8,849 prompt tokens through the proxy, unique per request (14/14 OK in
166.4 s):

| Level | Surface | Reading |
|---|---|---|
| vLLM prefill | `:8100/metrics` | `prompt_tokens_total = 126,240` |
| LMCache L1 | `:8080/status` | 20 objects, 720 MiB / 1024 MiB = 70.3%, LRU @ 0.8 |
| LMCache L2 | `:8080/status` | `l2_commit_writes = 36`, `stored_object_count = 36` |
| NIXL XNVME_KV plugin | metrics JSON | `store_ops = 331,812`, `store_bytes = 1,359,101,952`, `completions_err = 0`, `submit_fail = 0`, `stalls = 0` |

The arithmetic reconciles exactly, and that is the proof:
`36 × 9,217 = 331,812 = store_ops` and `331,812 × 4096 = 1,359,101,952 =
store_bytes = 1.266 GiB`. Same structure as 6.37's reconciliation, on
fresh numbers.

Note: mean device latency 2,540 µs; `submit_retry = 156,832,920` = ~473
retries per completed op — the `-EBUSY` busy-spin of 6.35/6.37,
re-confirmed on the live serving path.

Note also: 1.266 GiB written with zero errors onto the freshly-wiped
namespace (6.41) is a new, clean lower bound for capacity and
re-confirms 6.39's retraction.

**Path 3 — read path, device → cold reader.** Two independent pieces of
evidence:

(a) Live serving path, during the benchmark sweep, decode's adapter:
`l2_device_hits = 8`, `l2_index_hits = 0`, `l2_probe_errors = 0`,
`l2_load_aborts = 0`, with decode's L1 holding **0 objects** — the hits
can only have come from the device, for content only prefill wrote.

(b) `scripts/verify/60-verify-l2-crossnode.sh --no-drain`: **9/11**, step
5 green — `l2_device_hits=4`, `l2_index_hits=0`, `l2_probe_errors=0`,
`l2_load_aborts=0`, TOKEN IDENTITY matched, negative control A passed
(device_hits 4 → 4). The 2 failures are step 7's control, VOID BY
CONSTRUCTION under `--no-drain` — identical to the 2026-09-18 result
(6.34), not a regression.

**Engine-level numbers, first on record for this configuration.** These
were taken with **L1 forced to 1 GiB, so every chunk is being written
through to the KV device during the measurement** — they are NOT
comparable to the 2026-09-18 figures in BRINGUP, which were taken
without that.

Baseline (`--target=proxy`, `--no-cache`, pp=512 tg=128 depth=0 conc=1,
3 runs): `e2e_ttft` 698.812 ± 0.586 ms, `est_ppt` 581.512 ± 0.586 ms,
`pp_throughput` 880.5 tok/s, `tg_throughput` 201.5 tok/s,
generation-latency probe 117.30 ms.

Prefix-cache sweep (`BENCHY_DEPTH="0 4096"`, 3 runs,
`--confirm-connector-hit` PASSED):

| phase | depth | est_ppt | e2e_ttft | tg tok/s |
|---|---|---|---|---|
| inference | 0 | 581.36 ± 0.36 ms | 698.67 ± 0.36 ms | 201.3 |
| context load | 4096 | 5,313.85 ± 37.33 ms | 5,431.17 ± 37.33 ms | 182.2 |
| inference | 4096 | 706.15 ± 0.17 ms | 823.47 ± 0.17 ms | 179.6 |

**The headline, and it is a measurement-methodology finding:**
`compare_runs.py --prefix-benefit` reports **0.823x**, which reads as
"the cache made it slower". That is an ARTIFACT — the metric pairs
inference@depth=0 against inference@depth=4096, i.e. a request with no
context against one carrying 4,096 tokens of context. Different
workloads; the ratio cannot express cache benefit and a healthy tier
scores below 1.0. The honest same-depth comparison is context-load vs
inference at depth 4096: **5,313.85 / 706.15 = 7.53x**. Do not quote
0.823x as a result.

### 6.43 ✅ P↔D is measured riding the 1 GbE MANAGEMENT NIC, not the 400 GbE RoCE fabric — first direct traffic proof, plus per-level benchmark metrics

**Measured 2026-09-21**, second session, stack torn down and
rebuilt after 6.42. Qwen3-8B/TP=1/XNVME_KV on `/dev/ng1n1`, LMCache
L1 forced to 1 GiB, full stack live.

**Part A — the transport, proven by traffic rather than inferred
from config.** Every previous statement that the P→D leg runs on
TCP over `ens51f0` came from reading configuration. This is the
first time it was confirmed by counting bytes on the wire. Method:
snapshot `/sys/class/net/*/statistics/{rx,tx}_bytes` on decode,
drive traffic, snapshot again. Run config in force: `UCX_TLS=tcp,
rocm,self,sm`, `UCX_NET_DEVICES=ens51f0`, `KV_TRANSPORT=tcp`.

One P→D transfer, single 7,729-token prompt:

| interface | role | rx bytes | tx bytes |
|---|---|---|---|
| `ens51f0` | 1 GbE management | 1,197,025,283 (1.115 GiB) | 4,376,427 |
| `benic8p1` | 400 GbE fabric | 423 | 0 |

Across a full prefix-cache benchmark sweep:

| interface | rx bytes | tx bytes |
|---|---|---|
| `ens51f0` | 3,314,691,031 (3.087 GiB) | 12,225,811 |
| `benic1p1`+`benic2p1`+`benic3p1`+`benic8p1` combined | 4,308 | 0 |

That is a ratio of about **769,427 : 1** in favour of the
management NIC. The fabric bytes are background noise, not data.
Link speeds confirmed from `/sys/class/net/<if>/speed`: `ens51f0` =
**1,000 Mb/s**; `benicN` = **400,000 Mb/s**.

**The cost, stated plainly:** moving that 1.115 GiB takes **9.58 s**
at 1 Gb/s versus **0.02 s** at 400 Gb/s — a ~400x penalty, while
eight 400 GbE fabric NICs sit idle. This is very likely the
dominant term in the ~11.9 s per request recorded in 6.42's
8,849-token drive, and it means **no latency or throughput figure
in this repo is a transport benchmark** — they are all measurements
of a stack whose KV path is pinned to a 1 GbE link by 3.9.

**Why the fabric sits idle — root-caused 2026-09-21, see 3.9.** The
gap this section measures traces to one missing device capability:
the ionic RoCE provider reports `max_srq = 0`, and UCX's `rc_verbs`
transport is filtered out at device-query time whenever that's
zero. The fabric's own measured capability is **769.34 Gb/s**
bidirectional RC, cross-node (3.9) — so the ~769x gap between that
number and this section's 1 Gb/s link is recoverable the moment the
provider gains SRQ; it was never a fabric, firmware, or routing
limit.

**Part B — per-level metrics across one prefix-cache sweep.**
Deltas, captured before and after the sweep at every level:

| Level | Metric | PREFILL Δ | DECODE Δ |
|---|---|---|---|
| vLLM | `prompt_tokens_total` | +36,989 | +36,989 |
| vLLM | `generation_tokens_total` | +19 | **+1,642** |
| vLLM | `prefix_cache_queries` | +209,058 | +2,267,265 |
| vLLM | `prefix_cache_hits` | +32,256 (15.4%) | +1,935,360 (**85.4%**) |
| LMCache L1 | objects / used / usage | 21 / 756 MiB / 74% | 1 / 36 MiB / 4% |
| LMCache L2 | `l2_commit_writes` | +33 | +1 |
| LMCache L2 | `l2_device_hits` | 0 | **+15** |
| LMCache L2 | `l2_probe_misses` | +129 | +129 |
| device | `store_ops` / `store_bytes` | 304,161 / 1,245,843,456 | 9,217 / 37,752,832 |
| device | `retrieve_ops` / `retrieve_bytes` | 0 / 0 | **138,255 / 566,292,480** |
| device | mean latency / `submit_retry` per op | 3,544 µs / 701 | 2,311 µs / 431 |

**All three reconciliations are exact:**

```
prefill store:    33 groups x 9,217 = 304,161 = store_ops    ; x4096 = 1,245,843,456 = store_bytes
decode  store:     1 group  x 9,217 =   9,217 = store_ops    ; x4096 =     37,752,832 = store_bytes
decode  retrieve: 15 hits   x 9,217 = 138,255 = retrieve_ops ; x4096 =    566,292,480 = retrieve_bytes
```

Call out that the **retrieve side has now been reconciled this way
for the first time** — 6.37 and 6.42 reconciled only the store
side. `l2_device_hits=15` on decode against `retrieve_ops=138,255`
is direct arithmetic proof that a device hit costs exactly one full
object read (9,216 pages + 1 commit), and that decode is reading
content prefill wrote.

**Part C — the benchmark result, and it reproduces 6.42.**

| phase | depth | est_ppt | e2e_ttft | tg tok/s |
|---|---|---|---|---|
| inference | 0 | 599.59 +/- 24.53 ms | 715.22 +/- 24.53 ms | 201.8 |
| context load | 4096 | 5,355.34 +/- 22.01 ms | 5,470.97 +/- 22.01 ms | 182.3 |
| inference | 4096 | 729.00 +/- 20.63 ms | 844.63 +/- 20.63 ms | 179.8 |

`--confirm-connector-hit` PASSED. Honest same-depth reuse speedup:
**5,355.34 / 729.00 = 7.35x**, against 7.53x in 6.42 — the
measurement is reproducible across a full teardown and rebuild.
`compare_runs.py --prefix-benefit` again reports **0.822x**, the
pairing artifact documented in 6.42 and 1.13; do not quote it.

### 6.44 ✅ The 2026-09-22 driver/software update lifts the SRQ blocker, moves the KV device's PCI address, and leaves the fabric links down

**Measured 2026-09-22**, both nodes rebooted (`smc1` 09:39, `smc2`
09:36) after the principal updated driver/software. Kernel unchanged
(`6.8.0-139-generic`); `ionic`/`ionic_rdma` driver strings unchanged
(`26.09.4.001`); `pds_core` firmware reads `1.130.0.a.129` — NOT newer
than 3.10's `-pi-131`, so the meaningful change is in USERSPACE:
**`rdma-core` is now `61.0-1`** (`ibverbs-providers
50.0-2ubuntu0.2`), with both `libionic-rdmav34.so ->
libionic.so.1.1.50` and `libionic-rdmav59.so -> libionic.so.1.0.61.0`
present.

**Finding 1 (headline) — the SRQ blocker from 3.9 is LIFTED.**
`max_srq` is now **512** on all 8 devices on **both** nodes (16/16),
versus **0** yesterday (16/16 then too). UCX's `rc_verbs` rejection
reason MOVED — the rigorous confirmation, not an inference from the
number alone:

| date | `ib_device.c` trace |
|---|---|
| 2026-09-21 | `:750 UCX TRACE ionic_0:1 does not support SRQ` |
| 2026-09-22 | `:743 UCX TRACE ionic_0:1 is not active (state: 1)` |

UCX now PASSES the SRQ gate and fails only on port state (`state: 1` =
`IBV_PORT_DOWN`). `rc_verbs` pair count is still 0, but for a
different and far more mundane reason than yesterday — the ports are
down (Finding 3), not that the capability is absent. **3.9's named
root cause is resolved by this update.** RoCEv2 for P→D is now gated
**only** on the fabric links coming up. Stated with the same
discipline this repo has used throughout: **RoCEv2 has NOT been
demonstrated** — no RDMA traffic has been carried, and no throughput
number exists. See 3.9 for the full update to that item.

**Finding 2 — the DSC NVMe function MOVED PCI address.**
`0000:36:00.0` is now `Ethernet controller [0200]: AMD Pensando
Systems DSC Management Controller [1dd8:1004]`, bound to `ionic`. The
KV device is now at **`0000:37:00.0`** — `Non-Volatile memory
controller [0108]: AMD Pensando Systems DSC NVMe Controller
[1dd8:1005]` — on **both** nodes. `setpci -s 36:00.0 00.L` now returns
`10041dd8`, not the `10051dd8` documented everywhere for the NVMe
function — that value now belongs to `37:00.0`. Rebinding at the NEW
address worked **instantly** (0.09 s) on both nodes and restored
`/dev/ng1n1` with IDENTICAL identity: `mn=PDSNVME`, `csi 0x1`, `eui64
e46cfefeffcdae01`.

**This invalidates a hardcoded address in ~10 places across the
repo:** BRINGUP §1.3, HANDOFF §3.4 and §2, TODO 6.26,
`scripts/common/lib.sh`'s comment,
`scripts/target/51-reset-smc3-storage.sh`'s comment, and
`creds/setup-4.env`'s comment. **The fix is to DISCOVER the address,
never hardcode it** — the recipe used here:
```bash
# [SMC1]/[SMC2] — find the Pensando NVMe-CLASS function, whatever
# address it is at
PCI=$(lspci -nn -d 1dd8: | awk '/\[0108\]/{print $1}')   # 0108 = NVMe class
echo -n "0000:${PCI}" > /sys/bus/pci/drivers/nvme/bind
```
This is the same lesson as Invariant 10 (resolve the KV device by
NQN, not by path) applied one PCIe layer down: resolve the function
by CLASS, not by address. See 6.26 for the update to that item's
long-lived per-boot procedure.

**Finding 3 (current blocker) — the RoCE fabric links are DOWN.** All
8 `benicNp1` on both nodes: `carrier=0`, `NO-CARRIER`, `Link detected:
no`; all 8 `ionic_N` ports read `state: 1: DOWN`; `ibv_devinfo`
reports **0/8 `PORT_ACTIVE`**. Device→netdev mapping re-confirmed
unchanged: `ionic_0..7` → `benic1p1..benic8p1` (PCI
`09/26/46/69/89/a6/c6/e9:00.0`).

**The fabric addressing and routing did NOT survive the reboot** —
the interfaces came back admin-down with no addresses and no `30.x`
routes at all. The documented scheme (smc1 `30.1.N.1/24`, smc2
`30.2.N.1/24` on `benicNp1`) was re-applied by hand; addresses are set
again, but the links still have no carrier. **Record this
non-persistence as a known limitation in the same family as 6.9
(`nvme connect` not persistent) and 0.4 (amdgpu)** — nothing about
this fabric's addressing survives a reboot either.

`ethtool` now reports `Speed: 800000Mb/s`, `Auto-negotiation: off`,
`Port: Direct Attach Copper` — yesterday these same links were up and
reported **400000**. A plausible **(UNPROVEN) hypothesis**: the
update defaulted the port to 800G against a peer that negotiates
400G. Attempts to force it from the host FAILED: `ethtool -s
benic1p1 speed 400000 autoneg off` did not change the reported speed,
and `autoneg on` returned `netlink error: link settings update failed
/ Input/output error`. **This is a hypothesis, not a diagnosis, and
the host cannot influence it** — it needs the switch/DPU side or the
hardware owner.

Three NEW `ionic` netdevs appeared — `enp52s0`/`enp53s0`/`enp54s0` at
PCI `34/35/36:00.0`, all admin-DOWN, and **none has an `ionic_N` RDMA
device attached**, so they are not a path to RoCE. `enp52s0` was
logged `Link up - 200 Gbps` at 09:55:05 and `enp54s0` (`36:00.0`, the
management controller from Finding 2) `Link up - 1 Gbps`.

Per-boot ritual still required and performed: `modprobe amdgpu` on
both (0.4) — 8 GPUs/node afterwards, unchanged.

**Net effect on 3.9/3.1:** the named capability blocker that
consumed all of 2026-09-21 (`max_srq = 0`) is gone. What stands
between this cluster and RoCEv2 today is narrower and more mundane
than a driver defect — it is Finding 3, the links being down, with an
unproven 800G/400G mismatch hypothesis as the leading candidate cause.

**Append, 2026-09-25 — status carried forward twice more since this
entry:** the links-down state here (Finding 3) was fixed by the 400G
config the same day (6.45), which then found a *different* blocker
(zero RDMA devices). That blocker is now itself cleared — post-reboot
2026-09-25, all 8 `ionic_N` IB devices register and port 1 is ACTIVE on
both nodes (6.46). **RDMA device registration is no longer the
blocker.** The blocker is now the decode-side LMCache IPC KV-cache
registration failure — see `docs/TROUBLESHOOTING.md`'s
`ipc_wrapper.py:85` entry and TODO 6.46/6.47. RoCEv2 itself remains
**not demonstrated**: no RDMA traffic has been carried and no
throughput figure exists, because decode has not yet reached a healthy
state under this blocker.

### 6.45 🔴 The 400G config brings all 8 fabric links up and makes addressing persistent — but no RDMA device registers: `pds_core` exposes only `fwctl`, not `rdma`, on the auxiliary bus

**Measured 2026-09-22**, later the same day as 6.44, after the
principal applied a new 400G config and rebooted both nodes (`smc1`
up 11:54:12, `smc2` up 11:54:07). **This supersedes 6.44's Finding 3
(links down) — the links are now up — but opens a new, different
gap.** A power cycle was in progress when this session ended; every
number below is **pre-power-cycle** and must be re-measured.

**Three genuine improvements, in order of what 6.44 left open:**

1. **All 8 fabric links are UP on both nodes.** `carrier` reads
   `11111111` per node (was `00000000`), and `benic1p1 speed` now
   reads **400000** — it read `800000` before this config change,
   which 6.44 flagged as the UNPROVEN suspected cause of the link
   failure. That hypothesis is now **effectively confirmed** by this
   outcome.
2. **Fabric addressing and routing now PERSIST across a reboot** — 8
   `benicNp1` addresses and 16 `30.x` routes present on both nodes
   with no hand re-application. 6.44 recorded the opposite (came back
   with nothing, re-applied by hand) as a known limitation "in the
   same family as 6.9 and 0.4" — **that family membership is now
   revoked for this specific limitation.** Remove the "must re-apply
   by hand every boot" instruction everywhere it appears (HANDOFF
   §3.4).
3. **`/dev/ng1n1` survived the reboot on both nodes with no manual PCI
   rebind.** **Observed once — NOT yet established as reliable.**
   6.26's boot-time race has a long history on this hardware; one
   clean boot does not retire it. Its discovery-by-PCI-class recipe
   (resolve by class, never hardcode the address) stays the correct
   procedure for the boot where the device IS absent.

**What is now broken, and it is a DIFFERENT failure from 6.44's
Finding 3 — zero RDMA devices exist.**

`/sys/class/infiniband/` is **empty**; `ibv_devinfo` returns `No IB
devices found`. Consequently `ibv_devinfo | grep -c PORT_ACTIVE` = 0/8
and `max_srq` could not be read at all — there is no device to query
it on. **This is NOT the old "port DOWN" failure** — the links are up
(Finding 1 above); the devices are simply not being created.

The `ionic_rdma` driver IS loaded (`lsmod` refcount 5) and logged
`ionic_rdma : AMD Pensando RoCE HCA driver` at 11:54:29. Its
auxiliary-bus driver directory exists:
`/sys/bus/auxiliary/drivers/ionic_rdma.rdma/` (with `bind`/`unbind`/
`module`/`uevent`). `pds_core` has all **8** PCI devices bound.

**The gap, and this is the diagnosis:** `/sys/bus/auxiliary/devices/`
contains **only** `pds_core.fwctl.0` … `pds_core.fwctl.7`. There is
**no `pds_core.rdma.N`** auxiliary device for `ionic_rdma.rdma` to
bind to. `ionic_rdma` attaches over the auxiliary bus, so with no
matching aux device it binds nothing and registers no IB device.
**Framed precisely: `pds_core` is exposing only the `fwctl`
personality, not the `rdma` one** — most plausibly a DSC/DPU-side
configuration consequence of the new 400G config, but **that
attribution is UNPROVEN.**

`modprobe amdgpu` was still required (amdgpu not autoloaded) —
unchanged, TODO 0.4.

**Caveat that must be carried forward: the SRQ result is PENDING
RE-CONFIRMATION.** The `max_srq` 0 → 512 result that unblocked TODO
3.9 (6.44, Finding 1) was measured on the PREVIOUS boot, before this
config change. It could **NOT** be re-confirmed here — no devices
exist to query. **Do not assume it survived the config change.** It
must be re-verified the moment RDMA devices come back, before 3.9 is
treated as settled.

**Session ended with the principal power-cycling the nodes.** The
post-power-cycle state is **UNKNOWN** and must be re-measured from
scratch — do not resume from any number in this entry without
re-checking it first (HANDOFF §3.1, §3.5).

**Net effect on 3.9/3.1/6.44:** the fabric-link blocker 6.44 left
open is fixed. The blocker moved again — not back to a capability
(SRQ's status is unknown, not disproven) and not to the links (up),
but to the auxiliary bus: no `pds_core.rdma.N` device for
`ionic_rdma` to bind. **RoCEv2 remains undemonstrated**; no RDMA
traffic has been carried and no throughput number exists.

**Update, 2026-09-25 (post-reboot, post-power-cycle): CLEARED — see
6.46.** All 8 `ionic_N` IB devices now register with port 1 ACTIVE on
both nodes; `pds_core.rdma.0`–`.7` are present on the auxiliary bus.
This entry's gap is resolved. The blocker that replaces it is
decode-side, not fabric-side: TODO 6.47 /
`docs/TROUBLESHOOTING.md`'s `ipc_wrapper.py:85` entry. RoCEv2 is
**still not demonstrated** — decode has not reached a healthy state
under the new blocker.

### 6.46 ✅ RDMA device registration clears post-reboot 2026-09-25 — all 8 `ionic_N` devices ACTIVE on both nodes; the blocker moves to decode-side LMCache IPC KV-cache registration

**Measured 2026-09-25.** Decode host rebooted 05:50:43 UTC;
`/proc/cmdline` still carries `modprobe.blacklist=amdgpu` and `amdgpu`
was hand-loaded at 06:09:32 — TODO 0.4's per-boot condition is
unchanged, still required every boot.

**The 6.45 auxiliary-bus gap is CLEARED.** All 8 `ionic_N` IB devices
are registered and port 1 reads **ACTIVE** (state 4) on **both**
nodes. `/sys/bus/auxiliary/devices/` now carries `ionic.rdma.0`
through `.7` — previously (6.45) it held only `pds_core.fwctl.0`–`.7`,
with no `pds_core.rdma.N` for `ionic_rdma.rdma` to bind. It now binds.
This closes 6.45's specific gap; whether it survives the NEXT reboot
is not established — treat as observed once, same caution as 6.26/6.45
already apply to `/dev/ng1n1` and fabric addressing.

**SRQ (3.9/6.44) is still PENDING RE-CONFIRMATION** — 6.45 flagged this
as unconfirmed after its own config change, and nothing in this
session re-queried `max_srq` on the now-present devices. Do not treat
3.9 as settled from this entry.

**RoCEv2 remains undemonstrated on this boot too** — no RDMA bytes
carried, no throughput figure — because decode did not reach a healthy
serving state before the LMCache IPC failure below (6.47) killed the
attempt. Prefill's own health was unaffected: prefill has been up and
serving `/v1/models` (200) throughout, container up 4h at the time of
this measurement. Prefill reports its NIXL P2P state as
`p2p_state="unregistered"`, `p2p_peer_count=0` — expected, since it
never got a healthy decode peer to register against; not itself a new
defect.

**Two adjacent, more encouraging observations from the same boot,
recorded here because they bear on whether the storage/L2 tier is a
factor in what follows:** `/dev/ng1n1` is present and readable on
**both** nodes post-reboot (no manual PCI rebind needed — same
caution as above, observed once). Decode's `nixl_kv` L2 adapter
registered healthy at startup, namespace `d9dbd20693b2`, before the
crash described in 6.47. The `smc1` DSC wedge previously seen on
`nixl_kv`'s self-probe (`NIXL_ERR_BACKEND`) did **not** recur this
boot — prefill's own L2 self-probe passed. Recorded as a measured
observation on this boot only; it previously was believed to
potentially block L2 and did not this time.

**Net effect:** the RDMA/fabric chain that occupied 3.9, 6.44, and
6.45 is, for this boot, resolved end to end (links up, addressing
persistent, RDMA devices registered). **This item is marked ✅ for
that specific chain.** It does **not** mean RoCEv2 is proven, and it
does **not** mean the cluster is healthy — see 6.47, now the live
blocker.

### 6.47 🔴 LMCache MP daemon OOMs registering the KV cache at `ipc_wrapper.py:85` — a genuine ROCm/HIP allocation failure, root cause NOT established

**Measured 2026-09-24/25**, across multiple sessions, on the decode
node, with RDMA/fabric healthy per 6.46. The LMCache MP daemon fails
`REGISTER_KV_CACHE` with a genuine ROCm/HIP-allocator out-of-memory at
`lmcache/v1/platform/cuda/ipc_wrapper.py:85`, on IPC import 1 of 36,
with 28.37 GiB reported free. vLLM's decode `EngineCore` then times
out after 300s waiting for the registration and its worker segfaults
during HSA teardown in PyTorch's vendored `libhsa-runtime64.so`. Full
symptom, the naming caveat (this is ROCm/HIP throughout — the "CUDA"
identifiers are HIPify artifacts, not evidence of an NVIDIA stack),
the raw ROCm allocator trace, the segfault analysis, and a
seven-candidate **elimination record** (kernel OOM, HBM capacity, GPU
VA exhaustion, `HSA_ENABLE_IPC_MODE_LEGACY`, a ROCm `dma_buf` IPC
leak, container/host ROCm skew, and cross-process IPC transport as a
sufficient cause — all seven ELIMINATED) are recorded in full at
`docs/TROUBLESHOOTING.md`'s `ipc_wrapper.py:85` entry. Do not
duplicate that record here; this item exists so the open defect has a
tracker ID.

**Root cause is NOT established.** The discriminator between two
passing synthetic reproducers and the failing production vLLM+LMCache
pair is unidentified.

**Named next experiment (not yet run):** stand up a full LMCache MP
daemon skeleton — real NIXL agent, real `XNVME_KV` backend threads,
real OTel/Prometheus threads, **no vLLM** — and perform the identical
file-based IPC import into that process. Failure there would implicate
the daemon's own long-lived runtime state (candidate: SVM path
exhaustion/fragmentation — the raw trace's "failed to create a svm
hidden buffer" line is the strongest unexplored lead); passing would
leave LMCache's literal ZMQ REQ/REP framing (`mq.py`) as the remaining
untested variable.

**Do not merge with the `hipErrorInvalidDevicePointer`/`:81` symptom**
this repo's TROUBLESHOOTING.md previously recorded under this general
heading — the principal's original report of that exact error has not
reproduced since, and `:81` vs. `:85` are recorded as distinct symptoms
on current evidence.

**Blocked by:** nothing upstream — RDMA/fabric (6.46) is healthy, the
storage tier's own L2 startup is healthy (6.46). This is now the sole
thing between this cluster and a served decode request.
