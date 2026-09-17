# Handoff

State of the P/D-disaggregated KV cache project, for whoever picks this up
next (including future me). Last updated 2026-09-17.

Read this before [BRINGUP.md](BRINGUP.md). It tells you what is real, what is
assumed, and what is still wrong.

> **Resuming? Go straight to [§9](#9-how-to-resume).** It carries the
> cluster state as handed over, the three things to check before touching
> anything, and what to do in what order. §§1–8 are background; §§10–14
> are the evidence record, including several corrections of earlier
> corrections — read them when you need the *why*, not to get started.
>
> **Headline, 2026-09-17 (§19), supersedes the §18 headline below:** after
> both compute nodes were rebooted, cross-node storage-tier store+retrieve
> is **PROVEN, in both directions**, on a clean/empty namespace, with a
> negative control — the topology blocker this project has carried since
> §1 is not merely "confirmed shared" (§18.2) any more, it is confirmed
> **working**. The DSC completions-error wedge (§18.5) is cleared. What
> remains broken is now isolated to exactly one thing: LMCache's
> `nixl_store_l2_adapter.py` L2 tier still never retrieves anything a live
> vLLM engine stored (`retrieve_ops=0`, `store=36864`) — TODO 6.21's
> per-daemon-`uuid4` key naming is no longer one of several candidate
> causes, it is the sole remaining blocker, isolated beyond argument by
> this session's evidence. A DSC boot-time race, new this session, is also
> recorded (§19.1) — see it before assuming a reboot has left the stack in
> a known state.
>
> **Headline, session 4 (2026-09-16), superseded above but not wrong:** leg
> A works — a direct P→D NIXL transfer, proven by decode doing **zero**
> prefill at a 100% external cache hit rate (§11). Two silent defects had
> to be fixed to get there, both of which served correct text while moving
> no KV at all. RDMA (§3) became newly viable when another party fixed
> half the `ionic` stack (§14).

---

## 1. What this project is

Three nodes, splitting vLLM inference so prefill and decode run on different
machines and share KV cache.

| Role | Hardware | Function |
|---|---|---|
| Prefill (`smc1`) | 8× MI300X `[1002:74a1]` "Aqua Vanjaram", 10× DSC Ethernet Controller `[1dd8:1002]` | vLLM, KV producer |
| Decode (`smc2`) | 8× MI300X `[1002:74a1]` "Aqua Vanjaram", 10× DSC Ethernet Controller `[1dd8:1002]` | vLLM, KV consumer |
| Target (SMC3) | no GPU, 2× DSC Ethernet Controller `[1dd8:1002]` | SPDK NVMe-KV over NVMe-oF/TCP |

> **Corrected 2026-09-14, first real contact with hardware.** The IDs above were
> wrong: `1dd8:5303` and `1dd8:5200` do not exist on any of the three nodes (grep
> count 0). The GPUs are vendor `1002` (AMD/ATI), not `1dd8` — `lspci -d 1dd8:`
> finds no GPUs at all, on any node. There are 10 `[1dd8:1002]` DSC Ethernet
> Controllers per compute node, not 2. The target's two `[1dd8:1002]` devices
> carry the same ID as the compute-node NICs, so that ID alone does not
> distinguish a "POLLARA" from a "DSC3" — the marketing names above are
> unconfirmed and are not restated as fact; see the new blocker in §2 for the
> consequence to `00-preflight.sh`.

Addresses and credentials are **not in this repo** — see §3. Stack is
vLLM + LMCache + NIXL + the two NIXL plugins in `plugins/`, on ROCm.
Model is Qwen2.5-72B-Instruct at TP=8.

> **STALE, 2026-09-16/17 — see §18.1.** The creds file now pins
> `MODEL=Qwen/Qwen3-8B`, `TP_SIZE=1` (72B is not present on disk on either
> compute node — a 145 GB download — and Qwen3-8B is what's actually
> being served). `config/cluster.env`'s own *default* is still
> `Qwen2.5-72B-Instruct`/TP=8 and that line is not wrong as a description
> of the tracked default; it is wrong as a description of the running
> cluster. **Every latency/throughput number anywhere in §§2-17 above was
> measured against the 72B/TP=8 stack and is not comparable to anything
> measured from 2026-09-16 onward** — see §18.1 before quoting any figure
> from this document as if the two were interchangeable.

### One stack, two always-on KV paths — not two independent legs

> **Corrected 2026-09-16 — see §17.2 for the full account.** This section
> used to be titled "Two independent legs," language that implied the two
> paths below could be stood up separately. They never could be: this
> repo has composed both, every time, since TODO 0.1 was decided. The
> "leg A"/"leg B" shorthand this doc used throughout §2–§16 is retired;
> both paths are always-on parts of **one** stack, described below by what
> they actually are.

This distinction is the thing to get right; an earlier pass got it wrong and
built an entire phase plan around the mistake of treating them as
independently deployable.

| Path | Route | Transport | NICs |
|---|---|---|---|
| **P→D handoff** | prefill → decode, direct GPU-to-GPU via `NixlConnector`/UCX | TCP now → **RDMA = acceptance** | DSC Ethernet Controller `[1dd8:1002]` (10/node, `ionic` driver) |
| **Storage tier** | both compute nodes → `LMCacheMPConnector` → the MP daemon → its `nixl_store` L2 adapter → the KV target over NVMe-oF (§17.3, §17.4) | **TCP, permanently by design** | Same `[1dd8:1002]` ID on the target (2 present) — no distinguishing name confirmed |

**Why the storage tier can only ever be an LMCache tier, never
`NixlConnector`'s transport itself:** `NixlConnector`'s handshake
(`getLocalMD()`) requires RDMA-style addressable memory. Storage/KV
backends — SPDK_NVMe_KV and XNVME_KV alike — return
`NIXL_ERR_INVALID_PARAM` there (verified from `/root/rixl-bench`'s
`11-deploy-qwen-nixl-xnvme.sh`, quoted in full at §10.3). A KV backend can
therefore never carry the P/D handshake itself; it is only reachable as an
LMCache storage tier underneath NixlConnector, which is exactly what the
composition below does.

Composed as `MultiConnector[NixlConnector, LMCacheMPConnector]`, with
`NixlConnector` fixed as `connectors[0]`: `NixlConnector` carries the P/D
role and moves KV over RDMA (at acceptance) or TCP (today); LMCache stays
`kv_both` on both sides as a reuse tier, not the transport. This
composition is no longer a documented convention to remember — it is the
only shape this repo's generator can emit; see §17.1.

---

## 2. Current state

> **Note, 2026-09-16:** this section is a running record and its numbered
> blockers below are historical — each is annotated with how it resolved.
> For what is true *now*, see [§9.1](#91-cluster-state-as-handed-over).
> The "leg A"/"leg B" shorthand used in the historical entries below is
> retired terminology, kept here unedited because it is what was actually
> written and measured at the time — see §1 and §17.2 for the current
> framing (one stack, two always-on KV paths).

`main` is the default branch and in sync with
`github.com/pmallapp-amd/llm-stacks`. Working tree clean.

**The repository is PUBLIC.** Everything lab-specific has been externalised and
the history purged (§3). Verified: no credential or lab identifier appears in
any blob of any commit.

**First contact with hardware happened 2026-09-14.** `ssh` inventory reached
all three nodes (§6) and confirms node identity and credentials resolve
correctly (TODO 2.1). `00-preflight.sh` now runs clean on **all three** nodes,
5/5 checks each (TODO 2.2). It did not at first: it aborted partway through on
both compute nodes under `set -euo pipefail`, silently truncating the RDMA and
NIC inventory the run existed to collect. That was a bug in the script, not a
node defect, and it is fixed (TODO 2.13).

Read that green preflight narrowly. Its GPU check is `check_soft`, so a node
with **zero usable GPUs still passes** — see blocker 1 below. Preflight means
"inventoried", not "ready to serve". No vLLM, SPDK build, or verify-ladder
script has run anywhere yet. Treat the first invocation as bring-up, not a
benchmark.

Two of the three items below are now **RESOLVED**; the RDMA fabric route
remains open but is no longer the practical top blocker — a new one
(a container-image gap) took that spot this session, described after the
numbered list:

1. ~~The GPUs are unusable~~ **RESOLVED 2026-09-14.** All 16 MI300X (8 per
   compute node) are now up on both nodes: `rocminfo` reports 10 agents each
   (2× EPYC 9554 + 8× gfx942), `rocm-smi` reports 8 GPUs / 206141652992 B
   (192 GiB) VRAM each, all `runtime_status=active`. **An earlier pass on
   this same finding was wrong** — it concluded that removing
   `modprobe.blacklist=amdgpu` (present on both compute nodes' kernel cmdline)
   required editing GRUB and rebooting both machines. It did not:
   `modprobe.blacklist=` suppresses **autoload only** (alias/`-b` resolution,
   what udev uses — `modprobe -n -v -b amdgpu` does nothing) and does **not**
   block an explicit `modprobe amdgpu` by module name (`modprobe -n -v
   amdgpu` resolves the full 8-module chain, exit 0). There is no
   `install amdgpu /bin/false`-style hard block in any of
   `/etc|/lib|/run/modprobe.d` — the cmdline is the only source. Running
   `modprobe amdgpu` for real on both nodes brought the GPUs up immediately,
   with **no reboot**. **Residual fact that matters:** the blacklist itself
   is still on the cmdline and untouched, so this does **not** survive a
   reboot — every boot, the GPUs come up unusable again until something
   explicitly runs `modprobe amdgpu`. `scripts/{prefill,decode}/01-host-prep.sh`
   now do this automatically, every run, via `ensure_amdgpu_loaded()` in
   `lib.sh` (opt-out: `AMDGPU_AUTOLOAD=0`). See TODO 0.4 for the corrected
   record.

   Cosmetic, non-blocking, recorded and not chased further: `rocm-smi`
   prints `get_name, Error when calling libdrm` and an empty Marketing Name,
   because `libdrm-amdgpu1` is Ubuntu's `2.4.113-2~ubuntu0.22.04.1` while
   ROCm is 7.13.0 / hsa-rocr 7.2.0. `rocminfo` still correctly identifies
   `gfx942` and vLLM uses ROCr, not libdrm device names — see TODO 4.6.

2. **The P→D fabric (leg A) has no RDMA route yet — still open, but no
   longer the practical top blocker (see below).**
   `smc1`'s data-plane addresses are `30.1.N.1/24`; `smc2`'s are
   `30.2.N.1/24` — different `/24`s, differing in the second octet — and
   `smc1` has no route to `smc2` at all (falls back to the management
   default route). This also falsifies the `/31` point-to-point premise in
   `config/cluster.env` (§6); the `UCX_IB_ROCE_SUBNET_PREFIX_LEN=16`
   workaround would not bridge `30.1.x` to `30.2.x` either, since they differ
   inside the first 16 bits (TODO 3.6). Leg B (storage) is unaffected for
   bring-up — see the measurement caveat added to §8. This is a Phase 2/3
   (RDMA acceptance) blocker, not a Phase 1 one — leg A works today over the
   two nodes' shared management `/24` on TCP, which is what this session's
   P/D attempt used (see the new blocker below).

3. **RESOLVED, second session, 2026-09-15: the kernel could not yield a KV
   namespace device node at all — this is now false, on the current
   kernel.** The compute nodes were upgraded to **Ubuntu 24.04.5, kernel
   6.8.0-139**. Re-running the exact CSI-1 test that failed on 5.15: where
   5.15 logged `unknown csi 1 for nsid 1` and created **no** namespace
   device node at all, 6.8 logs `nvme nvme1: block device for nsid 1 not
   supported (csi 1)` and **does** create the generic char device (correctly,
   no block device beside it — a KV namespace has no block semantics). This
   is verbatim the string quoted in
   `plugins/xnvme-kv/xnvme_kv_backend.h:244-251`. **That header's claim,
   which the previous pass in this doc marked DISPROVEN, is therefore more
   precisely KERNEL-DEPENDENT: false on 5.15, true on 6.8** — see the
   corrected §6 entry, which is left in place rather than deleted, because
   the correction of a correction is the useful record here.

   With that gap closed, the storage backend decision (TODO 6.3) is now
   **XNVME_KV over kernel `nvme-of`**, and it has been proven end-to-end
   for the first time this session — see the new §6 Verified entry and
   §10 for the full test. **The GPU blacklist requirement (blocker 1
   above) is unaffected by this OS upgrade** — `modprobe.blacklist=amdgpu`
   is still on the 24.04 cmdline, so `modprobe amdgpu` is still required
   every boot on both nodes, confirmed again this session (TODO 0.4).

4. **RESOLVED, fourth session, 2026-09-15: leg A now actually carries KV.**
   The two blockers that stood here in turn — the `rixl` package gap, and
   then session 3's "P/D serves but no KV crosses" finding — are both
   closed. Measured through this repo's own proxy, on a 4033-token prompt:

   | engine | avg prompt throughput | external prefix cache hit rate |
   |---|---|---|
   | prefill | 403.3 tokens/s | 0.0% |
   | decode  | **0.0 tokens/s** | **100.0%** |

   Decode does no prefill work at all. That is precisely the acceptance
   signal TODO 6.11 specified, and which it explicitly refused to accept a
   successful completion in place of. **Two independent defects had to be
   fixed, and both of them presented identically: a pipeline that served
   correct text, at plausible latency, while transferring zero KV.** The
   full account is §11.

   With leg A proven, exactly **one** live item remains: **TODO 6.10**,
   composing the storage tier underneath this now-working P/D pair.

---

## 3. Credentials and lab identity

Per-setup identity lives outside the repo entirely:

```
creds/setup-4.env     real values, mode 0600, untracked
creds/active.env      symlink -> setup-4.env
config/creds.env.template   tracked template, placeholders only
scripts/common/init-creds.sh   scaffolds a creds file and the symlink
```

`.gitignore` carries a bare `/creds/` with **no negation exceptions**. A
`!creds/...` rule is one typo away from tracking a real credentials file in a
public repo, so the template deliberately sits on the tracked side of that line
in `config/`. `init-creds.sh` additionally refuses to write if `creds/` is not
ignored, verifying the assumption rather than trusting it.

`config/cluster.env` sources `${CREDS_FILE:-creds/active.env}` before its own
defaults, so creds always win. Anything unset falls back to a placeholder on the
reserved `.invalid` TLD — a checkout with no creds file fails DNS immediately
rather than resolving to a real machine.

To get a fresh checkout running: `scripts/common/init-creds.sh 4`, edit the
file, then `scripts/common/00-preflight.sh`.

> **Outstanding:** the BMC and root passwords were committed to a public repo
> before this cleanup. The history is purged and the published branch is clean,
> but if anyone cloned or GitHub cached it during that window, rotation is the
> only real remedy. This is tracked as TODO 0.2 and is not closed by the purge.

---

## 4. Repository map

```
config/cluster.env          single source of truth; sources creds/active.env first
config/creds.env.template   tracked template for a per-setup creds file
creds/                      UNTRACKED, gitignored — real addresses and passwords
scripts/common/             lib.sh (shared vocabulary), init-creds, preflight,
                            SPDK/UCX/NIXL build chain, venv, LMCache + kv-transfer
                            config generation, shared vLLM launcher, deploy.sh
                            (repo sync + remote exec onto the three bare nodes)
scripts/target/             SPDK build + nvmf_tgt, verify, namespace reset,
                            chunk-ceiling guard
scripts/prefill/            host prep, vLLM as kv_producer
scripts/decode/             host prep, vLLM as kv_consumer
scripts/proxy/              async disaggregation router
scripts/verify/             10 network → 20 plugin → 30 KV roundtrip →
                            40 end-to-end → 50 direct P/D transfer
scripts/bench/             llama-benchy harness + compare_runs.py
patches/spdk/               4 NVMe-KV patches (2 still required, see §5)
patches/lmcache/             5 LMCache patches baked into the vendor image
                            at build time — not applied by anything in this
                            repo; see patches/lmcache/README.md (§20 correction)
plugins/                    vendored SPDK_NVMe_KV and XNVME_KV NIXL backends
docs/                       ARCHITECTURE, BRINGUP, TROUBLESHOOTING, BENCHMARKING,
                            TODO, HANDOFF
```

---

## 5. SPDK: upstream plus two patches

There is **no private fork**. NVMe-KV support is four upstream-bound patches by
Ben Walker (NVIDIA) on review.spdk.io, vendored in `patches/spdk/`:

| Patch | Gerrit | Status |
|---|---|---|
| `0001` nvme: recognize KV namespaces | 28260 | **MERGED** 2026-08-25 (`8dc8327`) |
| `0002` bdev/kvmalloc | 27889 | **OPEN** — CR+2, Verified+1, mergeable, tagged `26.09` |
| `0003` nvmf: KV namespace support | 28298 | **OPEN** — CR+2 ×2, Verified+1, tagged `26.09`; depends on 0002 |
| `0004` nvme: KV unit tests | 27886 | **MERGED** 2026-08-25 (`b12a372`) |

v26.05 has the KV *initiator* API but predates all four. Master carries 0001 and
0004. **Only 0002 and 0003 must be carried**, and both are review-complete —
re-check `https://review.spdk.io/q/topic:kv+status:open`; when they land, the
vendored copies can be dropped. See [patches/spdk/README.md](../patches/spdk/README.md).

> **Correction 2026-09-15:** `scripts/target/02-build-spdk-kv.sh` was run
> against `SPDK_TARGET_REF=master` and `git am` **failed** to apply
> `0002-spdk-bdev-kvmalloc.patch` — master has moved since these patches were
> vendored. The target for this session's work was brought up instead from
> the **prebuilt** `/root/kv_spdk` (SPDK v26.05-pre, already carrying
> `bdev_kvmalloc`/`kvbdev` and 11 KV command-set symbols), not from this
> repo's build. This makes TODO 2.3/2.4 partly moot as written; the real
> decision — pin a compatible SHA, rebase 0002/0003 onto current master, or
> adopt the prebuilt tree as the reference — is tracked at TODO 6.2, not
> decided here. See §10.4 for what was verified on that prebuilt target.

---

## 6. Verified vs assumed

The scripts fail loudly on the assumed items rather than guessing. Preserve that
when editing.

### Verified

- Plugin env vars, params and failure modes — read from `plugins/nvme-kv/*.{h,cpp}`.
  The `queryMem()`, `make_key()` and `max_value_size` comments are authoritative.
- SPDK patch provenance and Gerrit status (§5), queried directly.
- Target configuration — `nvmf_tgt` binary, single `--json` startup config,
  `bdev_kvmalloc_create` taking `name`/`max_key_size`/`max_value_size`,
  `max_io_qpairs_per_ctrlr`, the iobuf sizing — all transcribed from a working
  deployment, not inferred.
- The chunk-size formula (§7 invariant 8), validated against two independent
  measurements.
- Compute-leg composition and UCX configuration — `MultiConnector` schema,
  `UCX_TLS=ib,rocm,self,sm`, the RoCE `/31` subnet workaround, side-channel
  behaviour — all from the same working deployment. **The `/31` premise does
  not hold on this fabric** — measured 2026-09-14, the P→D links are `/24`s in
  different second octets with no route between them; see §2 and TODO 3.6.
- LMCache's own `enable_pd`/`pd_role` peer channel is **unusable** with this
  plugin: it requires `supportsRemote() == true`, which
  `spdk_nvme_kv_backend.h` explicitly declines. This is why the P/D role goes on
  NixlConnector and never on LMCache.
- **Node identity and creds resolution**, 2026-09-14: `ssh` as root via
  `creds/active.env` reaches all three nodes as SMC1 (prefill),
  SMC2 (decode) and SMC3 (target) (TODO 2.1).
- **`ionic_*` → physical port mapping, both compute nodes**, measured
  2026-09-14 (TODO 2.8): on `smc1` all eight `ionic_N` map 1:1 to
  `benicNp1`-style names and are UP (`30.1.N.1/24`). On `smc2` only
  `ionic_2/3/5/6` line up with the matching `benic3p1/benic4p1/benic6p1/benic7p1`
  and are UP (`30.2.N.1/24`); `ionic_0/1` on `smc2` are different interfaces
  (`enp10s0`/`enp39s0`) and DOWN. `ionic_2` (`benic3p1`) is the first candidate
  common plane. This inverts the doc's prior claim that only the first two
  indices line up — `ionic_0/1` are exactly the pair that does *not*.
- ~~**RDMA device presence** — 8 `ionic` RDMA devices on each compute node;
  target exposes `rocep100s0` + `rocep132s0`. Confirmed by
  `00-preflight.sh`.~~ **EXPIRED — do not rely on this. Measured
  2026-09-15 (session 4): `ibv_devinfo` on `smc1` returns `No IB devices
  found`.** The claim was true when taken on 2026-09-14, on Ubuntu 22.04
  / kernel 5.15, and the 24.04.5 / 6.8 upgrade in session 2 broke the
  RDMA stack underneath it. Nobody re-ran preflight afterwards, and
  preflight would not have caught it anyway — see §13.

  Note also what the original entry ever established: `00-preflight.sh`
  runs `ibv_devinfo -l`, which **lists** device names. It never opens a
  device and never reads port state. "Presence" was the literal and
  correct word; it was read as functional.
- **`00-preflight.sh` on the target (SMC3)** — clean run, all 5 checks
  pass: 320 CPUs, 62 GiB RAM, no ROCm (expected), the two RDMA devices above,
  176.8 GiB free on `/opt`, kernel `6.8.0-38-generic`.
- **The KV target now genuinely runs and is verified**, 2026-09-15 — via the
  prebuilt `/root/kv_spdk`, not this repo's build (§5's correction):
  namespace `KvMalloc0`, subsystem `nqn.2024-01.io.nixl:kv0`, listener on
  the management IP port 4420, `max_io_qpairs_per_ctrlr: 512` confirmed (§7
  invariant 7 holds). Also measured: `max_io_size: 131072` (128 KiB), **not**
  the 16 MiB invariant 8 assumes — reconciled, see the plugin-log detail
  below and TODO 6.4. **Does not survive a reboot** — it had to be
  restarted from scratch on a later reboot within this same session; this
  is now part of the documented per-boot ritual (§9).
- **Kernel `nvme connect` against the KV namespace, on `5.15.0-191-generic`,
  2026-09-14**: controller attach succeeds (`/dev/nvme2`, correct
  `subsysnqn`, live state, "creating 128 I/O queues", `nvme list-ns` reports
  `[0]:0x1`, admin passthru works), but **no namespace device node is
  created at all** — no `/dev/nvme2n1` block device and no `/dev/ng2n1`
  char device — because the kernel logs `unknown csi 1 for nsid 1` and has
  no fallback for a Key-Value-command-set namespace. Same result for the
  local Pensando DSC KV device (`nvme1`) — a kernel limitation, not a
  fabric one. **Superseded on 6.8 — see the corrected entry below and
  §10.4.**
- **The CSI-1 kernel gap is CLOSED on 6.8 — measured 2026-09-15, second
  session, both compute nodes upgraded to Ubuntu 24.04.5 / kernel
  6.8.0-139.** Re-ran the identical test: 6.8 logs `nvme nvme1: block
  device for nsid 1 not supported (csi 1)` and **does** create the generic
  char device (correctly, no block device beside it). This confirms the
  plugin header's original claim
  (`plugins/xnvme-kv/xnvme_kv_backend.h:244-251`) is **kernel-dependent**,
  not simply wrong — see the corrected Assumed entry below, left in place
  rather than deleted. With this closed, the KV-backend decision (TODO
  6.3) is XNVME_KV over kernel `nvme-of`.
- **The XNVME_KV storage path is PROVEN end-to-end over kernel `nvme-of`,
  2026-09-15, second session — the session's headline result.**
  Cross-process test on the prefill node, two separate `docker run`
  invocations so the reader process never saw the writer's memory:
  process 1 stored three 32 KiB parts (98304 bytes, multipart split
  exercised), process 2 independently derived the same keys and retrieved
  identical bytes. `RESULT:OK` both phases, reproducible. Negative control
  verified: a nonce never written returns `RESULT:QUERY_MISS` and exit 1,
  not a false pass. Plugin startup line observed: `device KV format 0:
  value_max=131072 key_max=16 novg=4096 (compiled-in default 32768)` — this
  is the real per-value ceiling (32768 bytes), distinct from the
  transport's `max_io_size` (131072) and from invariant 8's assumed 16 MiB
  — see TODO 6.4.
- **The KV device must be resolved by subsystem NQN, not by path** —
  measured 2026-09-15, second session. The kernel numbers controllers in
  attach order, so the same target is `/dev/ng1n1` on prefill but
  `/dev/ng2n1` on decode — a shared creds file cannot carry one correct
  literal. Worse: decode also has a **local** Pensando DSC KV controller
  (PCIe `0000:36:00.0`, `nqn.2019-08.com.pensando:nvm-subsystem-sn-8001-0-0`)
  presenting a char-only `/dev/ng1n1`; the plugin's own
  `discover_kv_device()` picks the **lowest** such node, so autodiscovery
  on decode silently selects the local DSC — a real, writable KV device,
  and entirely the wrong one, with nothing downstream reporting it.
  `resolve_xnvme_kv_dev()` now matches on `NVMF_SUBNQN` and dies on
  ambiguity instead. Verified live: prefill → `/dev/ng1n1`, decode →
  `/dev/ng2n1`, correctly skipping the Pensando node.
- **The container's XNVME_KV plugin is a stale artifact**, measured
  2026-09-15: `query_memory()` returns `NIXL_ERR_NOT_SUPPORTED`, and `nm -D`
  on `/opt/nixl/.../libplugin_XNVME_KV.so` shows only the weak base-class
  `queryMem` symbol — the prebuilt `.so` predates the `queryMem` override
  that exists in this repo's `plugins/xnvme-kv` source. Not an
  architectural limit — the roundtrip above degrades to retrieve-as-probe
  with a visible INFO line. Recorded as a known limitation (TODO 6.10).
- **The vendored `disagg_proxy_demo.py` sends no handoff field — and that
  is a DEFECT, not a design.** Read from the source 2026-09-15: the proxy
  sends the request to prefill with `max_tokens=1`, then sends the
  original request to decode, and nothing carries `kv_transfer_params`.
  Proxy facts: runs in the same image, `--network host`, args `--model
  --prefill HOST:PORT --decode HOST:PORT --port`, health endpoint
  `/status` (not `/health`), endpoint discovery is static CLI args. Lives
  at `/root/rixl-bench/bench/pd-disaggregation/disagg_proxy_demo.py`.

  > **Correction, same day — do not repeat this inference.** An earlier
  > pass concluded from the above that `PD_HANDOFF_FIELD` was therefore
  > "settled and unused". That was wrong, and wrong in the direction this
  > repo is most careful about: it read an ABSENCE as a design decision
  > instead of as a missing piece. Measured afterwards on a live P/D pair
  > (§10.6): with this proxy in front, **decode re-prefills the entire
  > prompt** — a 4000-token request shows ~400 tokens/s of prompt
  > throughput on BOTH engines, and `External prefix cache hit rate` stays
  > 0.0% on both. No KV crosses. NixlConnector's consumer side needs the
  > producer's handoff metadata to know there is anything to pull, and this
  > proxy never gives it. So `PD_HANDOFF_FIELD` is not moot: it names
  > something the proxy is missing. Fixing that is part of live item A.
- **The NIXL Python API surface, reconciled against the real bindings**,
  2026-09-15 — the verify scripts' inferred version was wrong on several
  points: `register_memory` takes `backends` as a **list**, not `backend`;
  OBJ transfer descriptors must come from `register_memory(...).trim()` — a
  4-tuple to `get_xfer_descs` is rejected ("3-tuple list needed for
  transfer") and returns `None`; `remote_agent` must be the agent's own
  name for a local storage transfer, not `""`; `notif_msg` must stay empty
  because XNVME_KV does not support notifications;
  `nixl_agent_config(backends=[X])` auto-instantiates `X` with **default**
  params, so a later `create_backend(X, params)` fails "already created"
  **and** the params (`dev_uri`) never apply — for XNVME_KV this means
  silent fallback to the wrong-device autodiscovery described above. Two
  checks in the verify scripts were incapable of failing and are now fixed:
  `create_backend()` had no return statement (always `None`, success or
  failure), and `check_xfer_state()`'s `"ERR"` branch was dead because the
  binding raises a typed exception instead.

### Assumed — reconcile on first contact with hardware

- **`plugins/xnvme-kv/xnvme_kv_backend.h:244-251`'s claim that a KV
  namespace always appears as `/dev/ngXnY` with no matching
  `/dev/nvmeXnY`, "Verified both ways on the Austin prefill node
  2026-09-10" — DISPROVEN on these hosts, 2026-09-15 [first session].**
  Measured: the kernel logs `unknown csi 1 for nsid 1` and creates
  **neither** device node for a KV namespace on `5.15.0-191-generic` (both
  compute nodes) — not the block device, and not the char device either.
  The plugin's own `discover_kv_device()` heuristic therefore finds nothing
  on these hosts. The 2026-09-10 verification must have run on a different
  kernel — the **target** node here runs `6.8.0-38-generic` while both
  **compute** nodes run `5.15.0-191-generic`. See §10.4. Remedy was the
  paused kernel-upgrade sub-plan at TODO 6.5–6.8, itself unverified to
  actually fix this.

  > **Correction, second session, same day, 2026-09-15: the finding above
  > was real but incomplete — "DISPROVEN" is not quite the right word.**
  > The compute nodes were upgraded to Ubuntu 24.04.5 / kernel 6.8.0-139,
  > and the identical test was re-run: 6.8 logs `nvme nvme1: block device
  > for nsid 1 not supported (csi 1)` and **does** create the generic char
  > device, with no block device beside it. So the plugin header's claim is
  > **KERNEL-DEPENDENT**: false on 5.15, **true** on 6.8. Neither this
  > entry's original finding nor the header's original claim was wrong in
  > isolation — they were each true of a different kernel. Left in place
  > rather than deleted, because the correction of a correction is the
  > useful record. Now tracked as Verified above and at TODO 6.3/6.8, not
  > as an open assumption.
- **LMCache YAML key names and the allowlist patch sites.** Derived against
  v0.5.4, validated only against a mock.

  > **Partially resolved 2026-09-17, corrected same day.** The
  > from-source-generator half of this assumption is moot: that generator
  > applied only to a from-source LMCache install, which has never
  > completed a build and is deprioritised (`docs/TODO.md` §6.2), and
  > remains withdrawn (git history holds it). **A same-day pass then wrongly
  > concluded the vendor container "already accepts both backends with no
  > patch" and deleted `patches/lmcache/` on that premise — that conclusion
  > was FALSE and is corrected below at §20.** The vendored LMCache 0.5.3
  > carries both backends in its allowlist sites because the image was
  > **built with** `patches/lmcache/0006`/`0007`/`0008` applied, not
  > because stock LMCache does. See `patches/lmcache/README.md` for the
  > per-patch table and the re-verification recipe.
- **All benchmark numbers** in `BENCHMARKING.md` are order-of-magnitude
  estimates, labelled as such.

Two items formerly here are now **settled, moved to Verified above**: the
`kv_transfer_params` field name (this proxy doesn't thread one at all —
`PD_HANDOFF_FIELD` is unused, see above) and the NIXL Python API surface
(reconciled against the real bindings, see above).

---

## 7. Invariants — do not break these

Each guards a **silent** failure: the cluster looks healthy while doing the
wrong thing. This is why several scripts refuse to start.

1. **`nixl_pool_size: 0`** selects LMCache's content-derived-key backend. The
   object-pool backend names objects `obj_{slot}_{uuid4}` — per-process random —
   so prefill and decode derive different keys for identical content and every
   decode lookup misses. Symptom: `LMCache hit tokens: 0`.

2. **The `ldd` self-containment check** on `libplugin_SPDK_NVMe_KV.so`. A
   `DT_NEEDED` on `librte_eal.so` or `libspdk_*.so` makes NIXL's `dlopen()` fail
   *silently* and report only "unsupported backend". This is why SPDK is built
   `--without-shared` and `meson.build` links explicit `.a` paths.

3. **`PYTORCH_HIP_ALLOC_CONF=expandable_segments:False`.** Otherwise vLLM's KV
   tensors cannot be exported over HIP IPC and registration fails.

4. **`NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` stays unset.** Adopting the
   device-reported ceiling changes on-wire object geometry, and nothing records
   the `sub_size` an object was written with — a reader would reassemble a
   half-stale page without error.

5. **Drain the namespace whenever `KV_MAX_VALUE_SIZE` changes** —
   `scripts/target/50-reset-namespace.sh`. Same root cause as (4).

6. **`UCX_TLS` must include `rocm` and must not include `tcp`.** Without `rocm`,
   UCX loads no ROCm memory domain, reports VRAM as host, and NIXL refuses
   registration with an error blaming a missing ROCm build — misleading, because
   the build has ROCm and `UCX_TLS` configured it out. Without excluding `tcp`,
   RDMA acceptance can pass on a silent TCP fallback. `ib,rocm,self,sm`.

7. **`max_io_qpairs_per_ctrlr = 512`, spelled exactly that way.** SPDK silently
   ignores the older `max_qpairs_per_ctrlr` spelling, leaving the default 127.
   One plugin instance opens all 128 qpairs on its controller, so against a
   shared target the first role to connect takes the whole budget and the second
   is refused — surfacing as `CQ transport error -6` and `NIXL_ERR_BACKEND`
   while LMCache logs a successful store and HTTP returns 200, with **zero bytes
   reaching the device**.

8. **The chunk-size ceiling.** One LMCache chunk is one NIXL object; exceeding
   the controller transfer size fails the store with `NIXL_ERR_BACKEND` and
   takes the server down rather than degrading. Per rank:
   `layers × chunk × (kv_heads/TP) × head_dim × 2 × 2`. Current config is 10 MiB
   against a 16 MiB ceiling — 37% headroom, which is thin. Guarded by
   `scripts/target/05-check-chunk-ceiling.sh`. **`chunk_size` is part of the
   cache key, so both roles must use the same value** or the receiver silently
   re-prefills.

9. **Startup preconditions in `start-vllm.sh`** — target reachable, LMCache
   config validated, side channel not loopback, RDMA access confirmed in RDMA
   mode. Without them vLLM serves from local cache only and disaggregation does
   nothing while appearing correct.

---

## 8. Known measurement trap

**vLLM's own prefix cache sits upstream of the connector layer.** If it hits, no
connector is consulted — LMCache included. With a large GPU KV cache,
same-endpoint repeats are served by vLLM and the whole KV tier looks dead
regardless of configuration. This confound invalidated every earlier retrieve
measurement on the reference deployment.

A valid reuse number is therefore **cross-instance** (decode loading what
prefill stored) or same-instance only after genuine eviction. Confirm with a
non-zero `need to load:` and a non-zero `External prefix cache hit rate` in the
logs — never with the presence of a flag.

`scripts/bench/20-bench-prefix-cache.sh` currently sends the same context twice
to the same endpoint and is therefore subject to this. The warning and a
`--confirm-connector-hit` mode are in place; restructuring the benchmark is
TODO 1.13.

**A second trap, found 2026-09-14.** The target's real data-plane NIC
(`enp132s0`, its own /24, MTU 9000, 200000 Mb/s, `ionic` driver) is
unreachable from the compute nodes right now — same routing gap as leg A
(§2). But `NVMF_TRADDR` defaults to `TARGET_HOST`, the management address, which *is* reachable, so NVMe-oF/TCP can come up over
management before the fabric route exists. Any storage-leg number measured
that way is traversing a 1000 Mb/s `tg3` management NIC (`enp101s0`) and is not
representative — the same kind of trap as above, one layer down.

**Sharpened 2026-09-15: this is not only a routing gap, the physical links
are down.** Both 200G data-plane NICs on the target — `enp132s0` (holding
`1.1.0.2`) and `enp100s0` — report `Link detected: no`. The lab reference
script `target_scale_kv_spdk.sh` hardcodes listener `1.1.0.2`, which is
consequently unusable as written, independent of any routing fix. So the
storage leg is bounded to 1 Gb/s not merely "until the fabric route exists"
as the 2026-09-14 note framed it, but until someone brings the physical
200G links up — no known fix, see TODO 6.16. Leg A is unaffected by this:
the two compute nodes share a common /24 management subnet and reach each
other directly today.

---

## 9. How to resume

Rewritten 2026-09-16 (twice — first at the end of session 4, again later
the same day once the connector matrix collapsed to one stack and the
MP daemon existed, §17). Everything above §9 is background and evidence;
this section is the operational one. If you read nothing else, read this.

> **What changed in this rewrite:** §9.3's old "Track A / Track B" split
> is gone. Track A (the storage tier) was never something to compose
> *after* the leg-A baseline — the composition has been one thing since
> TODO 0.1, and the MP daemon + its `nixl_store` L2 adapter (§17.3, §17.4)
> are now part of what "bring up the stack" means. RDMA acceptance (§3)
> remains the one genuinely separate, parallel workstream — it always was
> an independent transport upgrade for the P→D path, not a second leg.

### 9.1 Cluster state as handed over

Measured, not assumed, minutes before writing:

| Node | State |
|---|---|
| `smc1` prefill | **up 4 min** (just rebooted). **0 GPUs, no `/dev/kfd`.** No containers. `ibv_devinfo` → 8 devices (RDMA userspace OK). |
| `smc2` decode | **up 4 min** (just rebooted). **0 GPUs, no `/dev/kfd`.** No containers. `ibv_devinfo` → 8 devices. |
| `smc3` target | up 4 days. Serving **`nqn.2016-06.io.spdk:cnode1`** — *another party's* configuration. Our `nqn.2024-01.io.nixl:kv0` does not exist. |

Nothing of ours is running anywhere. vLLM and the proxy were torn down
deliberately at the end of the session; the containers carry no
`--restart` policy, so they will not come back on their own.

Both compute nodes rebooted simultaneously just now, which nobody on our
side initiated — see §9.5.

### 9.2 Check these things before touching anything

Each has cost a run already, and each presents as a failure in whatever
you were actually testing rather than as itself.

1. **`uptime` on `smc2`.** It rebooted seven times on 2026-09-15, cycling
   every 3–13 minutes — shorter than the 5–6 minutes a 72B TP=8 load
   takes. It later held for hours, then rebooted again. Nothing explains
   either the instability or the recovery. TODO 6.20. **If it has been up
   less than the time your step needs, you will lose the run.**
2. **Who owns `smc3`.** It is shared and was reconfigured mid-session by
   someone else (§12.5). Our subsystem is gone. Do not restart their
   target to reclaim it — agree ownership first. TODO 6.18. (§16.8/§17.9:
   the local-DSC option may make this moot for a first proof — evaluate
   before assuming it still gates everything.)
3. **`modprobe amdgpu` on both compute nodes.** Currently **needed** —
   both report 0 GPUs as handed over. §9.4.
4. **Whether the LMCache MP daemon is already up on this node before you
   run `start-vllm.sh` (or a role script) by hand.** It is idempotent and
   the role scripts start it automatically, but `start-vllm.sh`'s own gate
   will `die` with a pointer back to `start-lmcache-daemon.sh` if it isn't
   reachable — read that message before assuming vLLM itself is broken.
   §9.4, §17.3.

### 9.3 What to do, in order

**Step 0 — bring up the one stack, including its storage tier, and
confirm the leg-A baseline before anything else.** There is no longer a
"restore the compute leg, then separately consider the storage tier"
sequence — the MP daemon and its `nixl_store` L2 adapter are part of what
starting this stack means now (§17.1, §17.3, §17.4), so bring them up
first, on both nodes:

```
scripts/common/start-lmcache-daemon.sh     # on smc1 AND smc2 (idempotent — safe if already up)
scripts/prefill/03-start-prefill.sh        # on smc1 -- also starts the daemon itself first if needed
scripts/decode/03-start-decode.sh          # on smc2 -- same
scripts/proxy/start-proxy.sh               # fronting both (or: python3 scripts/proxy/disagg_proxy.py)
```

`scripts/common/start-vllm-container.sh`, which this step used to point
at, is **deleted** (§17.1) — it built a bare `NixlConnector` with no
LMCache at all, had no caller, and could never have run the composition
this repo actually decided on. Use the role scripts above; `start-vllm.sh`
underneath them now hard-gates on the daemon being reachable in addition
to its pre-existing gate on the KV target.

Send one long (≥4000-token) prompt with a per-run nonce through the proxy
and confirm **decode's `Avg prompt throughput` is 0.0 with
`External prefix cache hit rate` at 100%**, while prefill's throughput is
non-zero. That is the §11 result — the P→D handoff baseline. **It proves
the P→D path, not the storage tier**: a healthy daemon and a working
`--l2-adapter` spec are necessary for vLLM to start at all now (the gate
above), but starting is not the same as the tier actually serving a hit.

**To prove the storage tier itself is live**, look for a real LMCache hit
served from the KV backend — non-zero `need to load:` and non-zero
`External prefix cache hit rate` **cross-instance or post-eviction**
(§8's trap), via `scripts/verify/30-verify-kv-roundtrip.sh` or a repeat
request engineered to miss vLLM's own prefix cache first. **This has not
yet been run against the composed daemon+L2-adapter path on live
hardware** — the code and its JSON round-trip are validated (§17.4,
§17.5), a live hit through it is not. This is TODO 6.10, still the one
live item in §6, and it is blocked on exactly what it always was:

- **6.18** — `smc3` is shared and was reconfigured out from under this
  work once already; agree ownership before touching it again. **Evaluate
  the local-DSC option first** (§16.8, §17.9) — both `smc1` and `smc2`
  have their own local Pensando DSC (`/dev/ng1n1`) that does not need
  `smc3` at all; unproven, nothing deployed against it yet, but it may
  make 6.18 moot for a first proof.
- **6.20** — `smc2`'s reboot instability. A composed run needs the node to
  stay up through model load *and* the daemon startup; check `uptime`
  first (§9.2).

**Done, not blocking either of the above:** the `KV_BACKEND=XNVME_KV`
default flip in `config/cluster.env` (§17.7) is now committed — it decides
which backend `start-lmcache-daemon.sh`'s `--l2-adapter` spec targets.

**Separately, and not blocking any of the above — RDMA acceptance (§3).**
This was never a second leg to compose; it is a transport upgrade for the
P→D path that has always been independent work. Newly viable and not
previously available: another party installed the matched 24.04 DSC
bundle, so `ibv_devinfo` works and **RC queue pairs carry data** (§14).
Remaining, in order:
- **3.9** — `UCX_TLS=ib` pulls in UD transports, and **UD QP creation
  fails on this hardware**. Find the transport spec that works, without
  weakening invariant 6's exclusion of `tcp`. Also: the container launch
  does **not** map `/dev/infiniband` yet, which Phase 2 needs. **This is
  the sole remaining RDMA-stack blocker** — 3.6 (routing) is closed and
  3.10 (firmware skew) is downgraded to tidiness, both per §15.
- **3.6** — CLOSED (§15.4). Left here only as a reminder to re-measure if
  the shared fabric changes again (§9.5) — do not assume a closed item
  stays closed on this cluster.
- **3.10** — downgraded to tidiness (§15.1); `smc1`'s `ionic_0` is still
  the lone card on old firmware, level it when convenient.

**3.8 — DONE, 2026-09-16.** `00-preflight.sh` now asserts `ibv_devinfo`
actually enumerates a device rather than merely existing, and surfaces
libibverbs' `couldn't load driver` warning verbatim when it fires — the
exact signature that hid §13 for two sessions. Still `check_soft` in
Phase 1 by design (TCP needs no verbs); the hard check for
`KV_TRANSPORT=rdma` was already covered separately by `require_rdma_access`
(`lib.sh`, dies if no port reports `PORT_ACTIVE` — TODO 1.9), not by this
change. Nothing further to do here.

### 9.4 The per-boot ritual — none of this survives a reboot

1. **`modprobe amdgpu`** on both compute nodes. `modprobe.blacklist=amdgpu`
   is still on the 24.04 cmdline, so GPUs never autoload.
   `01-host-prep.sh` does this automatically (opt-out
   `AMDGPU_AUTOLOAD=0`). TODO 0.4. **Required right now.**
2. **Confirm `/dev/ng1n1` exists before attempting to start anything on
   that node — new, 2026-09-17, §19.1.** The DSC NVMe controller has a
   boot-time race: the kernel can probe it (`CSTS=0x0`, "Device not
   ready; aborting initialisation") before the DPU-side application is
   ready, the driver detaches, and **nothing re-probes it**. If
   `/dev/ng1n1` is missing after a reboot, first check `lspci` still
   shows `[1dd8:1005]` and that the other DSC functions (`pds_core`,
   `ionic`) bound fine — if so, the card is not dead, the DPU side just
   was not ready in time. Retry with
   `echo -n "0000:36:00.0" > /sys/bus/pci/drivers/nvme/bind` — this only
   succeeds once the DPU side is actually up, takes ~2 minutes, and fails
   with the identical `CSTS=0x0` otherwise. `start-vllm.sh` hard-gates on
   `/dev/ng1n1` by design, but a manual roundtrip run ahead of that gate
   will not, and will instead report a confusing device-open failure.
3. **The KV target.** It does not survive a reboot of `smc3` — but as
   handed over the problem is different and worse: `smc3` is up, and
   someone else's subsystem is on it. Resolve 6.18 before assuming this
   step is yours to perform. (Or evaluate the local-DSC option, §16.8 —
   it sidesteps this step entirely if adopted.)
4. **`nvme connect`** on both compute nodes — no `--persistent`, no
   systemd unit (TODO 6.9). Moot until (3) is resolved.
5. **Start the LMCache MP daemon on both nodes** —
   `scripts/common/start-lmcache-daemon.sh` (§17.3). Idempotent, and the
   role start scripts (`scripts/{prefill,decode}/03-start-*.sh`) call it
   automatically before launching vLLM — but it does not survive a reboot
   any more than (1)–(4) do, and `start-vllm.sh`'s gate will `die`, not
   silently proceed, if it isn't up.

What does **not** need redoing: the DSC/RDMA userspace fix is a package
install and survived this reboot (`ibv_devinfo` → 8 devices on both nodes
post-boot).

### 9.5 The hardware is shared, and it changes under you

This is the single most important thing a new session needs to internalise,
because it has invalidated recorded facts five separate times (§14.4):

- The KV target was reconfigured by another party mid-session (§12.5).
- The DSC driver/firmware bundle was replaced between sessions, fixing
  half of a blocker we had documented as needing vendor action (§14).
- A 200G link came up during an investigation (§13.7), contradicting a
  TODO marked "not actionable without physical access".
- `amdgpu` was loaded on `smc2` by someone else, three hours into a boot.
- Both compute nodes rebooted simultaneously as this handoff was written.

**Re-measure; do not trust a recorded measurement of driver, device, or
library state.** Prefer a check that fails loudly over a note in a
document. Every "Verified" entry in §6 taken before 2026-09-15 should be
treated as suspect if it concerns anything the OS or driver updates could
have touched; entries about hardware identity, plugin source, and Gerrit
status are fine.

### 9.6 Traps that have actually bitten, distilled

Not hypothetical — each cost real time on this project.

| Trap | Where |
|---|---|
| A correct completion proves **nothing**. Two separate defects produced perfect output at plausible latency while transferring zero KV. Read the two engine throughput counters or you have measured nothing. | §11 |
| `UCX_NET_DEVICES` unset makes UCX advertise the first TCP device it enumerates — an unroutable fabric NIC. `<auto>` was not a default, it was the bug. | §11.2 |
| `max_local_cpu_size` is **per TP worker**. At TP=8, `80` means 640 GiB of pinned memory. It took a node down. | §12.3 |
| `LMCacheMPConnector` silently ignores `enable_nixl_storage` / `nixl_backend` / `nixl_backend_params`. Not rejected — ignored. True, and it is the RIGHT config surface (`--l2-adapter`, daemon-side) that was missing from this doc, not a capability gap in the connector — see the next row and §17.4/§17.6. | §12.1 |
| The YAML `gen-lmcache-config.sh` emits (`enable_nixl_storage`, `nixl_backend`, `nixl_backend_params`) is not what configures the live storage tier under MP mode. The backend is set on the **daemon** via a repeatable `--l2-adapter <JSON>` CLI flag; the YAML only matters for the in-process `LMCacheConnectorV1` path this repo does not run. Reading "the YAML has the right keys" as "the tier is configured" is exactly the mistake that produced §12.1. | §17.4, §17.6 |
| vLLM's own prefix cache sits upstream of every connector. A valid reuse number must be cross-instance or post-eviction. | §8 |
| `nixl_rocm._api.create_backend()` has no `return` — it is always `None`. Checking it is a test incapable of failing. | §11.3 |
| `ibv_rc_pingpong`'s Mbit/s figure is latency-bound loopback, not throughput. There is **no** RDMA throughput number on this cluster. | §14.2 |

### 9.7 What this session added to the repo

- `scripts/common/start-vllm-container.sh` — **new**. The container launch
  path as a guarded script rather than shell history.
- `scripts/proxy/disagg_proxy.py` — **fixed**. Implements the full
  three-step XpYd handshake; it now *requests* the handoff, which is what
  made leg A work. This is the router, **not** the vendored
  `disagg_proxy_demo.py` (which cannot drive NixlConnector — TODO 6.14 is
  reversed).
- `config/cluster.env` — `PREFILL_PD_IF` / `DECODE_PD_IF`, the compute-leg
  NIC, deliberately separate from the storage-leg `*_DATA_IF`.
- `scripts/common/lib.sh` — `setup_ucx_env` now dies rather than
  autodetecting.
- `scripts/common/gen-lmcache-config.sh` — emits `nixl_buffer_size` only
  when the buffer device is not `cpu`, and no longer claims the LMCache
  allowlist patch is mandatory (it is not, on the container path).

### 9.8 Standing setup, if starting from a fresh checkout

1. `scripts/common/init-creds.sh 4`, populate it, confirm
   `source config/cluster.env` resolves real addresses. *(Already done —
   TODO 2.1.)*
2. `scripts/common/deploy.sh` to push the repo and creds onto each node.
   No node has a shared filesystem. SSH key auth is **not** configured
   anywhere, so everything depends on the passwords in `creds/active.env`,
   which `deploy.sh` pushes to all three machines by default — TODO 2.12.
3. Then §9.3 above. [BRINGUP.md](BRINGUP.md) remains the long-form guide,
   but note it predates the container-path decision (TODO 6.1) and
   describes the from-source build, which is deprioritized (TODO 6.2).

---

## 10. Reference deployment, container image contents, and the storage-backend transport constraint (2026-09-15)

Everything below was measured directly on the three nodes and by inspecting
`/root/rixl-bench` and the `rocm-aic` Docker images already present there —
none of it is inferred. This is the session that produced TODO §6; read that
section alongside this one.

### 10.1 The deployment model this repo assumes does not match how the lab actually runs

This repo's scripts build everything from source into `/opt/kvstack`
(`scripts/common/{05-build-spdk-initiator,10-build-stack,
20-build-vllm-lmcache}.sh`) and run vLLM from a venv. The lab's actual,
working deployment is **containerised** and already present on both compute
nodes:

- Docker images `rocm-aic:{latest,mp-pd,kv-planefix,pr4467,kv-mppd,kv-mppd-assertfix}`
  (~43.7 GB each), plus `rocm/vllm:latest` and `rocm/pytorch:latest` on `smc2`.
- `rocm-aic:kv-mppd-assertfix` (built 2026-09-11), inspected directly: vLLM
  0.26.0+rocm, LMCache 0.5.3, torch 2.13.0+rocm7.2, nvme-cli 2.8, libxnvme
  with 5 `xnvme_kvs_*` symbols, and NIXL plugins **already built**:
  `libplugin_UCX.so`, `libplugin_POSIX.so`, `libplugin_AIS_MT.so`,
  `libplugin_SPDK_NVMe_KV.so`, **and** `libplugin_XNVME_KV.so`.
  `NIXL_PLUGIN_DIR=/opt/nixl/lib/x86_64-linux-gnu/plugins`. Entrypoint is
  `python3 -m vllm.entrypoints.openai.api_server`.

This makes the entire from-source build chain redundant for bring-up as
measured today. Whether the repo adopts the container path, keeps the
from-source path, or supports both was an open decision with tradeoffs, not
made here.

> **Decided, second session, 2026-09-15: the container path.** Not by
> declaration — by what actually moved this session: the target came up
> from a prebuilt binary, leg B was proven from a container, and the P/D
> launch attempt ran entirely from `rocm-aic` images (§10.4, TODO 6.1/6.11).
> The from-source path is deprioritized, not abandoned — see TODO 6.2.

### 10.2 Reference deployment tooling: `/root/rixl-bench`

Present on all three nodes; this is the provenance for this repo's target
config, heavily commented. Relevant paths:

```
stack/tracks/nixl/vllm/08-deploy-qwen-nixl.sh
stack/tracks/nixl/vllm/11-deploy-qwen-nixl-xnvme.sh
bench/pd-disaggregation/deploy-pd-disaggregated.sh
bench/pd-disaggregation/deploy-pd-asymmetric-p2p.sh
bench/lib/deployment.sh
stack/tracks/nixl/core/10-nixlbench-xnvme-kv.sh
stack/tracks/nixl/core/xnvme-kv-plugin/build.sh
```

Key facts extracted:

- The proven P/D deploy uses `kv_connector: NixlConnector` **only** —
  `kv_role` kv_producer/kv_consumer, `kv_buffer_device` cpu (or cuda),
  `extra_config {hostname, port: 14579}`, `NIXL_BACKEND=UCX`. **No LMCache at
  all** — no `LMCACHE_*` env, no YAML, no `nixl_pool_size`, nothing.
- The router is upstream vLLM's `disagg_proxy_demo.py`, run in the same
  image, `--network host`, args `--model --prefill HOST:PORT --decode
  HOST:PORT --port`, health endpoint `/status` (**not** `/health`). Endpoint
  discovery is static CLI args; there is no registry.
- `VLLM_NIXL_SIDE_CHANNEL_HOST` must be set to the routable IP — vLLM
  defaults it to localhost, and setting only `extra_config.hostname` does
  **not** change the bind. Ports 5600 (prefill) / 5601 (decode); verify with
  `ss -ltn`.
- Qwen caveats: `--dtype bfloat16` (their float16 default overflows to
  inf/NaN on bf16-trained checkpoints); YARN needs key `rope_type`, not
  `type`; TP is **not** derived from `HIP_VISIBLE_DEVICES` and defaults to 1,
  which silently single-GPU-loads.
- `disagg_proxy_demo.py` mislabels vLLM 400s as a 200 SSE stream — surfaces
  client-side as "stream ended without a finish reason". Read the vLLM
  container logs, not the proxy, when this happens.

### 10.3 The core integration gap: a KV backend can never be NixlConnector's transport

Both lab scripts state plainly that `NixlConnector`'s handshake
(`getLocalMD()`) requires RDMA-style addressable memory, and that
storage/KV backends — SPDK_NVMe_KV and XNVME_KV alike — return
`NIXL_ERR_INVALID_PARAM` there. Quote, `11-deploy-qwen-nixl-xnvme.sh`:

> "Storage/KV backends — SPDK_NVMe_KV *and* XNVME_KV alike — return
> NIXL_ERR_INVALID_PARAM there, so they cannot serve as the live transfer
> path for vLLM serving."

So a KV storage backend can **never** be NixlConnector's transport. It can
only be reached as an **LMCache storage tier** (LMCache → NIXL →
XNVME_KV/SPDK_NVMe_KV) — exactly this repo's leg-B design, composed via
`MultiConnector[NixlConnector, LMCacheMPConnector]` (§1).

The consequence: the lab has run (a) NixlConnector P/D over UCX and (b) raw
KV backends via `nixlbench` — but has **never** run (c) a KV backend as an
LMCache tier underneath a live P/D deployment. That combination is **new
integration**, not reproduction of a proven setup.

**Status, second session, 2026-09-15:** (b) is now proven for XNVME_KV
specifically (see the new §6 Verified entry and §10.4/§10.5 below) — but
(c), the composition itself, is still unrun and remains **TODO 6.10**, one
of the two live items in this handoff. (a) also remains unproven on this
hardware — the current blocker is a container-image gap, **TODO 6.11**, the
other live item.

### 10.4 Kernel blocker for the XNVME_KV path — measured, definitive

The SPDK NVMe-KV target was brought up on the target node using the prebuilt
`/root/kv_spdk` (already carrying `bdev_kvmalloc`/`kvbdev` and 11 KV
command-set symbols — this repo's own from-source build of patches
0002/0003 **failed** to apply to SPDK master, see §5's correction). Target
verified: namespace `KvMalloc0`, `nqn.2024-01.io.nixl:kv0`, listener on the
management IP port 4420, `max_io_qpairs_per_ctrlr: 512` confirmed (§7
invariant 7 holds). Also note the transport came up with `max_io_size:
131072` (128 KiB), **not** 16 MiB — see the open question at TODO 6.4; this
may invalidate invariant 8's stated headroom.

A kernel `nvme connect` from the prefill node then:

- **Succeeded** at the controller level: `/dev/nvme2` exists, `subsysnqn`
  correct, state live, "creating 128 I/O queues", and `nvme list-ns` reports
  the namespace `[0]:0x1`. Admin passthru works (`nvme id-ns` returns data).
- But the kernel logs `nvme nvme2: unknown csi 1 for nsid 1` and creates
  **no namespace device node at all** — no `/dev/nvme2n1` block device and
  no `/dev/ng2n1` generic char device.
- CSI 1 is the Key-Value command set. Both compute nodes run
  `5.15.0-191-generic`, which has no KV support and does not fall back to a
  char-only node.
- The **same** message appears for the local Pensando DSC KV device
  (`nvme1`) — this is a kernel limitation, not a fabric one.

**This disproves the assumption in `plugins/xnvme-kv/xnvme_kv_backend.h:244-251`**,
which asserts a KV namespace appears as `/dev/ngXnY` with no `/dev/nvmeXnY`
and states it was "Verified both ways on the Austin prefill node
2026-09-10." That verification must have run on a different kernel: the
**target** node runs `6.8.0-38-generic` while **both compute** nodes run
`5.15.0-191-generic` — the contradiction is explicit, and the plugin's own
`discover_kv_device()` heuristic finds nothing on these hosts as they stand.

Remedy path (paused, not started — TODO 6.5–6.8): the HWE kernel
`linux-image-generic-hwe-22.04` candidate `6.8.0-138.138~22.04.1` is
available in apt. Requires an amdgpu DKMS rebuild for 6.8 (currently built
only for 5.15.x), staged single-node reboots, and re-handling
`modprobe.blacklist=amdgpu` (TODO 0.4). **UNVERIFIED** whether ROCm 7.13 +
amdgpu DKMS 6.16.13/6.18.4 work on 6.8. Nothing was installed this session —
the installer script never transferred to either node.

> **Resolved, second session, same day, 2026-09-15 — but by a different
> route than planned above.** The compute nodes were upgraded wholesale to
> **Ubuntu 24.04.5 / kernel 6.8.0-139** (not the in-place HWE kernel
> package this remedy path describes) — same practical outcome, different
> mechanism, recorded so the discrepancy is visible (see TODO 6.5–6.7 for
> the corrected status of each planned step). amdgpu DKMS is confirmed
> built for 6.8.0-139 on both nodes post-upgrade (TODO 6.6). Re-running the
> exact CSI-1 test above on 6.8: the kernel now logs `nvme nvme1: block
> device for nsid 1 not supported (csi 1)` and **does** create the generic
> char device (no block device beside it, as expected). **This closes the
> CSI-1 gap** — TODO 6.8's re-test, passed. The plugin header's claim at
> `xnvme_kv_backend.h:244-251` is therefore not simply disproven, it is
> **kernel-dependent**: false on 5.15, true on 6.8 — see the corrected §6
> entry. With the path open, XNVME_KV was then proven end-to-end — see
> §10.5 below and TODO 6.12.

### 10.5 Also this session

- **`nvme connect` does not persist across reboot** (no `--persistent` flag,
  no systemd unit) — every remaining storage step depends on the connection
  existing. TODO 6.9.
- **Both compute nodes rebooted unexpectedly this session** (cause unknown —
  provably not the paused kernel-upgrade work, since its installer never
  reached either host). Both came back with 0 GPUs and `/dev/kfd` absent,
  confirming TODO 0.4's predicted recurrence in practice, not just in theory.
- **Model weights**: Qwen2.5-72B-Instruct was already present in
  `/root/.cache/huggingface/hub` on both compute nodes (153 GB hub cache
  total) and is now also staged at `/var/tmp/hf/Qwen2.5-72B-Instruct` (37/37
  shards, 0 missing, verified against `model.safetensors.index.json`; 80
  layers, 64 heads, 8 kv_heads, hidden 8192, bfloat16), intended as the
  container's `/hf` bind-mount. The hub-cache copy is now redundant
  (~136 GB/node); `smc2` is down to ~118 GB free. TODO 6.17.

### 10.6 Second session, same day (2026-09-15): the OS upgrade, the leg-B proof, and the new P/D blocker

Everything in this subsection was measured on live hardware after the
24.04.5/6.8.0-139 upgrade described in §10.4's correction.

- **Everything survived the OS upgrade.** Verified present: model weights at
  `/var/tmp/hf/Qwen2.5-72B-Instruct` (37/37 shards, 136 GB), all `rocm-aic`
  docker images, `/root/kv-cache`, `/root/rixl-bench`, nvme-cli 2.8, 8
  `ionic` RDMA devices per node, ROCm 7.13.0. amdgpu DKMS is now built for
  6.8.0-139 on both nodes (previously 5.15-only).
- **GPUs work on 6.8, but the blacklist requirement is unchanged.**
  `modprobe.blacklist=amdgpu` is still on the 24.04 cmdline, so GPUs still
  do not autoload. One `modprobe amdgpu` per node brought up 8× gfx942, 192
  GiB VRAM each (206141652992 bytes), zero dmesg errors, on both hosts. TODO
  0.4's every-boot requirement is unchanged by the upgrade.
- **The KV target runs from the prebuilt `/root/kv_spdk`.** Restarted
  cleanly after the reboot: `nqn.2024-01.io.nixl:kv0` on the management IP:
  4420, bdev `KvMalloc0`, `max_io_qpairs_per_ctrlr: 512` confirmed,
  `max_io_size: 131072` (still not the 16 MiB invariant 8 assumes — TODO
  6.4). Does **not** survive a reboot; it had to be restarted this session.
- **The XNVME_KV storage path is proven end-to-end over kernel `nvme-of`**
  — see the new §6 Verified entry for the full test; this is leg B working
  for the first time.
- **The KV device must be resolved by subsystem NQN, not by path** — see
  the new §6 Verified entry; `resolve_xnvme_kv_dev()` now does this,
  verified live on both roles.
- **The NIXL Python API used by the verify scripts was inferred and wrong;
  reconciled against the real one** — see the new §6 Verified entry for the
  full list of corrections (backends-as-list, `.trim()`, `remote_agent`,
  `notif_msg`, the `nixl_agent_config` pre-instantiation gotcha, and two
  checks that were incapable of failing).
- **The container's XNVME_KV plugin is a stale artifact** —
  `query_memory()` returns `NIXL_ERR_NOT_SUPPORTED`; the prebuilt `.so`
  predates the `queryMem` override in this repo's plugin source. Known
  limitation, not architectural — see the new §6 Verified entry.
- **The current blocker: vLLM on ROCm imports `rixl`, not `nixl`.**
  P/D was launched with `rocm-aic:latest`, which has `nixl` but not `rixl`,
  so every worker died with `Worker failed with error 'NIXL is not
  available'` and both engines exited 1. Surveyed all six `rocm-aic`
  images (all six carry the same plugin set — AIS_MT, POSIX, SPDK_NVMe_KV,
  UCX, XNVME_KV): `kv-mppd-assertfix` and `kv-mppd` have `rixl`; `mp-pd`,
  `pr4467`, `kv-planefix`, and `latest` do not. The two `rixl`-capable
  images exist **only on `smc2` (decode)** — `smc1` (prefill) has none of
  them. Both roles must run the same image, so it must be moved to `smc1`
  (`docker save | ssh | docker load`, or a registry) before P/D can start.
  This is **TODO 6.11**, the first of the two live items.
- **The proxy does not thread a handoff field.** vLLM's vendored
  `disagg_proxy_demo.py` sends the request to prefill with `max_tokens=1`,
  then sends the original request to decode; KV moves out-of-band over the
  NixlConnector side channel. This settles the `PD_HANDOFF_FIELD`
  assumption — see the new §6 Verified entry.
- **P/D launch parameters already worked out** — the containers started
  and loaded weights before dying on the `rixl` import, so these are
  confirmed as far as they got; full list at TODO 6.11, so next session
  does not re-derive them.
- **Housekeeping done**: 135 GB reclaimed per node by deleting the
  redundant `Qwen2.5-72B-Instruct` hub-cache copy (weights now solely at
  `/var/tmp/hf`, verified 37/37 shards and 145.4 GB matching the index).
  `smc1` now 336 GB free, `smc2` 253 GB. Qwen3-8B and TinyLlama left
  intact. TODO 6.17.

---

## 11. Fourth session, 2026-09-15: leg A proven, and the two defects that hid it

Session 3 left the pipeline in the most dangerous state this repo has a
name for: **every HTTP check green, every completion correct, and zero KV
crossing the wire.** Both engines answered `/health` 200, the side
channels bound routable IPs, the proxy's `/status` listed both nodes, and
a request through it returned coherent text with `finish_reason: stop` in
about three seconds. None of that was evidence of anything. Decode was
re-prefilling the entire prompt every time.

Two independent defects were responsible. Neither produced an error
message until it was looked for directly. They are recorded separately
because they fail in different layers and either one alone is enough to
silently disable disaggregation.

### 11.1 Defect one — the proxy never ASKED for the handoff

**The XpYd handshake is three steps, not two.** This repo, and session
3's notes, had it as two: prime prefill, then thread whatever
`kv_transfer_params` comes back into decode. The missing first step is
that prefill only *produces* that field if the request asks it to.

Reference implementation, read from inside the running image at
`/app/vllm/tests/v1/kv_connector/nixl_integration/toy_proxy_server.py`
(vLLM 0.26.0+rocm):

1. **Request** the handoff. The priming request must carry
   `kv_transfer_params = {"do_remote_decode": true, "do_remote_prefill":
   false, "remote_engine_id": null, "remote_block_ids": null,
   "remote_host": null, "remote_port": null}` alongside `max_tokens=1`
   and `stream=false`.
2. **Extract** `kv_transfer_params` from prefill's JSON response. It
   returns with the booleans inverted and the rest populated.
3. **Thread** that object into decode's request body.

Confirmed live against the prefill engine — step 1 added, and prefill
answers with:

```json
{"do_remote_prefill": true, "do_remote_decode": false,
 "remote_block_ids": [[...]], "remote_engine_id": "3bd4ce1b-...",
 "remote_request_id": "cmpl-...", "remote_host": "10.30.75.198",
 "remote_port": 5600, "tp_size": 8, "remote_num_tokens": 3001}
```

Without step 1 the same request succeeds and simply returns **no**
`kv_transfer_params` at all. Fixed in `scripts/proxy/disagg_proxy.py`.

> **This is the second time this exact inference has been made and been
> wrong, so it is worth naming the pattern rather than just the fact.**
> An earlier pass observed that the vendored `disagg_proxy_demo.py`
> threads no handoff field, and concluded `PD_HANDOFF_FIELD` was
> "settled and unused". Session 3 corrected that to "the proxy is missing
> something". Both readings treated the vendored demo proxy as evidence
> about the protocol. It is not: it implements a *different connector's*
> protocol, and pointing it at NixlConnector produces exactly the silent
> non-disaggregating pipeline described above. **An absence in a
> reference implementation is evidence about that implementation, not
> about the interface.** The authoritative artifact was
> `toy_proxy_server.py`, in the same image, the whole time.

`PD_HANDOFF_FIELD` is now **verified**, not assumed: the name is
`kv_transfer_params`, on both the request and the response side.

### 11.2 Defect two — UCX advertised a NIC the peer cannot route to

With the handoff threaded, decode got far enough to attempt the transfer
and then failed every request with an HTTP 500. The engine log shows the
handshake genuinely working — `NIXL compatibility check passed`,
`Transfer plan: TransferTopology(tp_ratio=1, num_kv_heads=8, local_tp=8,
remote_tp=8, ...)` — and then dying in `add_remote_agent` →
`loadRemoteMD` with `NIXL_ERR_BACKEND`.

Isolated with a standalone two-process probe rather than by restarting
72B engines (~6 minutes a cycle): a producer calls `get_agent_metadata()`,
a consumer calls `add_remote_agent()` on it. That reproduced the failure
in seconds and named it:

```
connect(fd=33, dest_addr=30.1.1.1:55385) failed: Connection timed out
Unexpected UCX error: Destination is unreachable
UCX endpoint create failed: failed to create ep
loadRemoteMD: error loading connection info for backend 'UCX'
```

**Cause:** with `UCX_NET_DEVICES` unset, UCX enumerates every TCP-capable
interface in the host network namespace and advertises the first. On
`smc1` that is `benic1p1` — `30.1.1.1`, a fabric NIC on a `/24` the decode
node has no route to (the long-standing TODO 3.6 gap). Decode spent ~133
seconds in `connect()` per attempt before failing.

The asymmetry is worth stating because it is not obvious from either node
alone: prefill's container enumerates **ten** TCP devices
(`benic1p1`..`benic8p1`, `ens51f0`, `lo`); decode's enumerates **two**
(`ens51f0`, `lo`), because `smc2`'s `benic` interfaces currently carry no
IPv4 at all. Neither container has `/dev/infiniband`, so UCX inside them
is TCP-only regardless — RDMA is not available to these processes today
and `UCX_TLS` excluding `tcp` would leave them with no transport at all.

**Fix:** pin both roles to the shared management interface. New
`PREFILL_PD_IF`/`DECODE_PD_IF` in `config/cluster.env`, deliberately
separate from `*_DATA_IF` (which names the *storage*-leg NIC to the
target — conflating the two is what allowed this). `setup_ucx_env` now
**dies** in TCP mode if neither resolves, rather than falling through to
its previous `unset UCX_NET_DEVICES` / `<auto>` branch. `<auto>` was not a
safe default; it was the bug.

> **Caveat that must not be lost: this path is the 1 GbE management NIC.**
> Leg A is functionally proven and is *not* transport-benchmarked. The
> 13.8 s decode latency observed on a 4035-token prompt is consistent with
> moving roughly 1.3 GiB of KV over 1 Gb/s, which is corroborating
> evidence that the transfer is real — and simultaneously a statement that
> no throughput number taken here means anything. The fabric NICs remain
> unrouted (TODO 3.6) and are Phase 2's problem.

### 11.3 Also found: `create_backend()` cannot fail

`nixl_rocm._api.create_backend()` has **no return statement** — it is
always `None`, on success and on failure alike. Any caller that checks its
return value has written a test incapable of failing. This is the same
defect class HANDOFF §6 already records for this repo's verify scripts,
but this instance is upstream, in the vendored NIXL Python API itself.
Check `agent.backends[<name>]` instead.

### 11.4 What is now codified in the repo

- `scripts/proxy/disagg_proxy.py` — sends the request-side
  `kv_transfer_params`; drops `min_tokens`/`min_completion_tokens`/
  `stream_options` from the priming copy only (vLLM rejects
  `min_tokens > max_tokens`, which would have turned every long-generation
  request into a 400 and disabled disaggregation for exactly the requests
  that benefit most); treats a falsy handoff as absent, since an empty
  dict threaded into decode looks like success to the counters while
  carrying no block ids.
- `config/cluster.env` — `PREFILL_PD_IF`/`DECODE_PD_IF`; `PD_HANDOFF_FIELD`
  re-documented as verified rather than guessed.
- `scripts/common/lib.sh` — `setup_ucx_env` prefers `*_PD_IF` over
  `*_DATA_IF` and dies rather than autodetecting.
- `scripts/common/start-vllm-container.sh` — **new**; the container launch
  path (TODO 6.1's decision) as a real script instead of shell history,
  with the guards that would have caught both defects above.

### 11.5 The router question, reopened and settled the other way

TODO 6.14 settled on the vendored `disagg_proxy_demo.py` as this stack's
router. **That is now reversed, with evidence:** that proxy cannot drive
NixlConnector, because it never performs step 1 of §11.1. This repo's own
`scripts/proxy/disagg_proxy.py` is the router, and it is the one the
result above was measured through — `prefill_no_handoff: 0` across the
run, which is the counter that would have caught the original defect had
the repo's proxy been the one in front all along.

---

## 12. Fourth session: the 6.10 attempt — what was established, and what stopped it

Leg A (§11) was the session's result. The storage-tier composition (TODO
6.10) was then attempted and did **not** land. It is recorded here in
detail because most of what was learned is durable and expensive to
rediscover, and because one finding invalidates a design assumption this
repo has carried since §1.

### 12.1 ~~`LMCacheMPConnector` cannot carry the KV tier at all — correct the architecture~~ — WITHDRAWN, see §16

> **CORRECTION, 2026-09-16: this section's headline conclusion is WRONG
> and is WITHDRAWN. Full account at §16.**
> `LMCacheMPConnector` **can** carry the KV tier, reaching XNVME_KV through
> the distributed L2-adapter path (`v1/distributed/l2_adapters/nixl_store_l2_adapter.py`)
> — a config surface this section never examined. `LMCacheConnectorV1` is
> **not** the required child. The evidence below is left in place, not
> deleted — it correctly shows that `extra_config`'s NIXL keys are ignored
> under MP; the error was concluding from that observation that MP is
> incapable, rather than that those particular keys are the wrong surface
> for MP. This section's ordering finding — NixlConnector must be first on
> the decode side, `multi_connector.py:387-400` — is **unaffected and
> reaffirmed**; nothing in §16 touches it.

**This repo has described its composition as
`MultiConnector[NixlConnector, LMCacheMPConnector]` since the beginning
(§1, TODO 0.1, `gen-kv-transfer-config.sh`). That cannot work.** Read from
the installed LMCache 0.5.3:

- `nixl_storage_backend.py` — the only thing that can drive XNVME_KV — is
  reachable from exactly one place in the entire package:
  `storage_backend/__init__.py:205-213`'s `CreateStorageBackends`, called
  only by the **in-process** `StorageManager` (`storage_manager.py:249`).
- That path is configured by `LMCacheEngineConfig`. The MP connector and
  its adapter never construct one — `grep -n "LMCacheEngineConfig" ` over
  `lmcache/integration/vllm/{lmcache_mp_connector,vllm_multi_process_adapter}.py`
  returns nothing at all. MP mode uses `lmcache/v1/distributed/` with a
  separate `StorageManagerConfig` and an entirely different L2-adapter
  schema.
- So `extra_config{enable_nixl_storage, nixl_backend, nixl_backend_params}`
  — the keys that select XNVME_KV and pass its `dev_uri` — are **silently
  ignored** under `LMCacheMPConnector`. Not rejected. Ignored.
- "MP" is **multi-process**: it requires a separately launched `lmcache
  server` daemon reached over ZMQ (`mq.py:263-275` connects; nothing
  spawns it). No such process runs on either node.

**WITHDRAWN, see §16 — do not read the rest of this section as concluding
`LMCacheConnectorV1` is the required, or even the preferred, child.**
`LMCacheConnectorV1` is *a* way to reach `nixl_storage_backend.py` —
in-process, no daemon — verified end-to-end through
`vllm_v1_adapter.py:498` → `lmcache_get_or_create_config()` →
`VllmServiceFactory` → `LMCacheEngineBuilder` → `StorageManager` →
`CreateStorageBackends`. **It is not the only way, and it is not the one
the vendor ships.** `LMCacheMPConnector` reaches the same backend by a
different route this section did not examine — the distributed
L2-adapter path documented in full at §16. The composition this repo
should use is `MultiConnector[NixlConnector, LMCacheMPConnector]`, per
§16 and per this repo's own scripts, which never changed.

Two consequences worth stating plainly:

- `MultiConnector` does **not** inspect or reconcile child `kv_role`s —
  `grep -n kv_role multi_connector.py` returns nothing — so a
  `NixlConnector` child at `kv_producer` beside an `LMCacheConnectorV1`
  child at `kv_both` is accepted.
- `kv_transfer_params` **survives** the wrapping in both directions: the
  request object is passed to children by reference, and responses are
  merged by `multi_connector.py:486-508`, which raises on a key clash.
  `LMCacheConnectorV1` returns `(False, None)`, so it cannot clash with
  NixlConnector's handoff payload. Leg A's §11 fix is safe under
  composition.

Ordering still matters, and now for a sharper reason than the repo
recorded: `MultiConnector.get_num_new_matched_tokens` assigns the load to
the **first** child reporting a non-zero match
(`multi_connector.py:387-400`). On decode, if LMCache is listed first and
hits, the NIXL remote-prefill pull is skipped entirely. **NixlConnector
must be first on the decode side.** **This finding is unaffected by the
§16 correction and is explicitly reaffirmed there** — it holds regardless
of which LMCache connector is the sibling child.

### 12.2 The LMCache allowlist is patched into the image, not needed as a runtime step

TODO 2.7 and a (now-withdrawn) from-source patch generator existed to
widen an LMCache backend allowlist. **There is no runtime patch step for
the container path** — but that is because the vendored LMCache 0.5.3 in
the `rocm-aic` image was **built with the allowlist already patched in**,
not because stock LMCache carries it natively. `XNVME_KV` and
`SPDK_NVMe_KV` appear in all three hardcoded backend tuples —
`nixl_storage_backend.py:126` (`validate_nixl_backend`), `:670` (mem_type
selection, which correctly routes them to `OBJ` not `FILE`), and `:1119`
(`createPool`) — because `patches/lmcache/0008` put them there at image
build time. (A conventional build-time `.patch` diff does not leave a
marker string in the resulting source the way the old generator's own
edits did — "no marker string" was misread as "no patch" in an earlier,
now-corrected pass; see §20.)

**Correction, 2026-09-17: §20 originally recorded a second, FALSE reason
for the old generator's removal — "the image already accepts these
backends unpatched" — and that framing bled into this section too.** The
generator itself remains correctly withdrawn (it targeted the from-source
build path, `docs/TODO.md` §6.2, which has never completed a build) — that
part stands. But the allowlist widening it would have performed is real,
required, and already done: `patches/lmcache/0006`/`0007`/`0008` are
tracked at `patches/lmcache/` and applied at the image's build time in a
sibling build repo. See `patches/lmcache/README.md` for the per-patch
table and a re-verification recipe against any future image.

### 12.3 `max_local_cpu_size` is PER TP WORKER, and getting it wrong took a node down

`config/cluster.env` carries `LMCACHE_MAX_LOCAL_CPU_SIZE=80` with the
comment "GiB of host DRAM (L1)". **That value is per worker process, not
per node.** At TP=8 it asks for 8 × 80 = 640 GiB of *pinned* host memory
(`hipHostMalloc`), on top of the ~1.38 TiB the engines already had
resident.

What happened, in order: every worker on prefill failed
`RuntimeError: hipHostMalloc failed: 2` out of
`mixed_memory_allocator.py:60`; the decode node stopped answering SSH
mid-configuration, kept answering ICMP for several minutes, and then
**rebooted** — losing its GPUs (`modprobe.blacklist=amdgpu`, TODO 0.4) and
its `nvme connect` (TODO 6.9) with it.

This is not a tuning nit. **An oversized LMCache L1 on this hardware is a
node-availability hazard**, and nothing in the config surface says so. A
value of 5 GiB per worker (40 GiB across TP=8) is ample for a correctness
proof: at a 10 MiB page that is ~512 chunks, ~131k tokens of L1 per
worker. `gen-lmcache-config.sh` should multiply by TP and sanity-check
against `MemAvailable`; it does not yet, and that is the first thing to
add before retrying 6.10.

### 12.4 Also fixed while here: the generator emitted a key LMCache rejects

`gen-lmcache-config.sh` emitted `nixl_buffer_size` unconditionally.
LMCache 0.5.3 **raises** if it is set while `nixl_buffer_device: "cpu"`
(`config.py:805`), because CPU mode shares `LocalCPUBackend`'s pinned pool
and sizes it from `max_local_cpu_size` instead. It is conversely
*required* for any non-cpu device. The generator now emits it
conditionally and dies on the contradictory combination rather than
producing a config that cannot load.

`cpu` is the right buffer device here, not the generator's previous `cuda`
default: XNVME_KV reaches the device through kernel `pread`/`pwrite` on a
char device, so the staging buffer has to be host memory.

### 12.5 The blocker that stopped 6.10: the target is a shared resource, and it moved

Mid-session the KV target stopped matching anything this repo expects.
`nvmf_get_subsystems` on `smc3` now reports:

```
NQN: nqn.2016-06.io.spdk:cnode1
   listener: {'trtype': 'TCP', 'traddr': '1.1.0.2', 'trsvcid': '4420'}
   ns: dev1_ns1 1
```

The subsystem this repo uses — `nqn.2024-01.io.nixl:kv0`, namespace
`KvMalloc0`, listening on the management IP — **no longer exists**, and
`nvme connect` from decode fails `Connection refused`. The `nvmf_tgt`
process was restarted by someone else against the lab reference config
(`target_scale_kv_spdk.sh`, which hardcodes the `1.1.0.2` listener). The
node itself has not rebooted in three days.

**`smc3` is shared, and this session was not the only thing using it.**
No attempt was made to reclaim it — restarting another party's target
mid-experiment is not a move this repo should make unilaterally. 6.10
resumes by re-establishing the `nqn.2024-01.io.nixl:kv0` subsystem, after
checking who else is on the box.

### 12.6 A blocker that has silently LIFTED: the 200G links are up

Recorded here because it contradicts a standing entry and nobody would
think to re-check it. HANDOFF §8 and TODO 6.16 state that both of the
target's 200G data-plane NICs report `Link detected: no`, with "no known
fix", bounding the storage leg to 1 Gb/s.

Measured this session: **`enp132s0` and `enp100s0` both report `Link
detected: yes`**, and `enp132s0` holds `1.1.0.2/24`. Something changed
physically. The compute nodes still have no address on `1.1.0.x`, so
there is still no route — but the premise of 6.16 ("needs someone with
physical hardware access; not actionable from a terminal") no longer
holds. What remains is an addressing/routing question, which *is*
actionable. Re-check before treating 6.16 as blocked.

### 12.7 Where 6.10 now stands

> **CORRECTED 2026-09-16, see §16.** The recipe below was written against
> §12.1's withdrawn conclusion and names the wrong connector.
> `LMCacheConnectorV1` here should be `LMCacheMPConnector`, and the child's
> `kv_connector_extra_config` should carry only the rendezvous keys
> `lmcache.mp.host` / `lmcache.mp.port` (default port **6557**) — under
> MP the backend (`nixl_backend`, `dev_uri`, etc.) is configured on the
> **daemon** side, not in vLLM's connector config, and vLLM must share IPC
> and PID namespace with the daemon container
> (`VLLM_IPC_MODE=service:<lmcache>`, `VLLM_PID_MODE=service:<lmcache>` —
> §16.5). The JSON block and the `LMCACHE_CONFIG_FILE`/`extra_config`
> paragraph below describe the in-process `LMCacheConnectorV1` config
> surface, which the vendor path — and this repo's own
> `gen-kv-transfer-config.sh` — does not use. Left in place because the
> LMCache tuning facts inside it (per-worker `max_local_cpu_size`, §12.3;
> `chunk_size` as part of the cache key, §7 invariant 8) are still
> correct and still apply; only the connector and its top-level config
> surface are wrong. See §16.5 for the vendor's actual recipe.

Everything except the target is worked out. The recipe to resume with,
each element established above rather than guessed:

```
--kv-transfer-config '{"kv_connector":"MultiConnector","kv_role":"<kv_producer|kv_consumer>",
  "kv_connector_extra_config":{"connectors":[
    {"kv_connector":"NixlConnector","kv_role":"<same>","kv_buffer_device":"cpu",
     "kv_connector_extra_config":{"hostname":"<own IP>","port":14579}},
    {"kv_connector":"LMCacheConnectorV1","kv_role":"kv_both"}]}}'
```

with `LMCACHE_CONFIG_FILE` pointing at a YAML carrying `chunk_size: 256`,
`local_cpu: true`, `max_local_cpu_size: 5` (**per worker** — §12.3),
`save_unfull_chunk: false`, `nixl_buffer_device: "cpu"`, **no**
`nixl_buffer_size`, and `extra_config: {enable_nixl_storage: true,
nixl_backend: "XNVME_KV", nixl_pool_size: 0, nixl_backend_params:
{dev_uri: <resolved by NQN>}}`. Note `LMCACHE_*` env vars only exist for
top-level fields; everything under `extra_config` must come from the YAML
or a single `LMCACHE_EXTRA_CONFIG` JSON blob.

Known unknown, not yet tested because the target went away: **a 10 MiB
LMCache page against XNVME_KV's 32 KiB per-value ceiling.** The plugin
splits multipart (proven in 6.12 — 98304 bytes became three 32 KiB
parts), so a 10 MiB page implies ~320 parts against the device's
`novg=4096`. Plausible, unverified. If stores fail, reduce `chunk_size`
before suspecting anything else — and remember `chunk_size` is part of the
cache key, so both roles must change together or the receiver silently
re-prefills (§7 invariant 8).

**Superseded 2026-09-16 (§16):** replace `LMCacheConnectorV1` above with
`LMCacheMPConnector` and `{"lmcache.mp.host":"<daemon URI>","lmcache.mp.port":6557}`;
drop the `LMCACHE_CONFIG_FILE`/`extra_config` block shown above from the
vLLM side entirely — it belongs on the daemon side under MP, which this
repo has not yet stood up. §16.5 is the authoritative recipe until this
repo runs it and can record the daemon-side config directly.

> **ANSWERED, 2026-09-16 — see §17.5.** The "known unknown" two paragraphs
> up is now closed with evidence, not left open: `get_plugin_params()`
> confirms XNVME_KV declares `max_value_size = 32768` (this paragraph's
> guess was right about that much), but the 10-MiB-chunk-vs-32-KiB-ceiling
> tension itself does not apply on the daemon-side path this repo
> actually runs — that reasoning was about the in-process
> `LMCacheEngineConfig.chunk_size`, a layer the MP path never touches. On
> the MP/L2-adapter path the pool tiles at `--l1-align-bytes` (4096 B by
> default), which stays far under either backend's ceiling, so the split
> described here never engages. Do not carry the "~320 parts" arithmetic
> above forward as if it were a live risk on the path this repo runs.

### 12.8 `smc2` (decode) became reboot-unstable during this session — read before planning any long run

Recorded prominently because it invalidates the assumption every
multi-minute step in this repo makes: that a compute node stays up long
enough to finish.

`journalctl --list-boots` on `smc2`, 2026-09-15:

```
-6  03:56:58 -> 05:17:01
-5  05:30:26 -> 07:49:35
-4  07:52:37 -> 12:04:43     <- the 4h window in which leg A was proven
-3  12:13:55 -> 12:22:24     <-  ~8 minutes
-2  12:28:26 -> 12:41:50     <- ~13 minutes
-1  12:44:17 -> 12:46:58     <-  ~3 minutes
```

Seven boots in one day, and after 12:04 it is cycling every three to
thirteen minutes — not long enough to load a 72B model at TP=8, which
takes five or six. Confirmed the hard way: a final attempt to restore the
proven leg-A pair was made at 12:41 and the node went down mid-load,
again.

The 12:04 reboot has a plausible cause: the 640 GiB pinned-memory request
described in §12.3. **The 12:22 one does not.** It happened with the
engine idle, minutes after `Application startup complete`, with the
container exiting 255 because the host went away underneath it. Nothing
in `journalctl -b -1 -p err` names a cause — no panic, no MCE, no OOM
kill, no thermal event. The only errors are ~~benign boot-time noise~~
(`ionic_N: Couldn't open port 1`, a networkd wait-online timeout).

> **Correction, same session: "benign boot-time noise" was wrong.** Those
> `ionic_N: Couldn't create ib_mad QP1` / `Couldn't open port 1` lines are
> a real RDMA-stack failure, they occur on **both** compute nodes, and
> `iwpmd.service` failing beside them is a second signal from the same
> stack. They were dismissed here because they appeared during an
> unrelated investigation and looked like startup chatter. They are
> §13's subject. Whether they bear on these reboots is still unknown —
> the DSC cards are the `ionic` devices, and a firmware-level fault there
> would reset a host without leaving a journal entry, which would fit
> "no recorded cause" — but that is a hypothesis to test, not a finding.
> The point of this correction is narrower and certain: the lines are not
> noise, and reading them as such delayed finding §13 by a session.

So this is not explained, and it should not be assumed to be a
consequence of §12.3 just because that came first. TODO 0.4 already
recorded "both compute nodes rebooted unexpectedly this session (cause
unknown)" in an earlier session, so this is the **second** independent
occurrence of unexplained reboots on this hardware. Treat it as a
standing hazard, tracked at TODO 6.20.

Two practical consequences:

- **Every reboot silently undoes three things** — `modprobe amdgpu`
  (0.4), the KV target session, and `nvme connect` (6.9) — so a node that
  reboots mid-run does not come back broken-looking, it comes back
  *quietly unequipped*, which on this stack is worse.
- **Check uptime before starting anything that takes minutes.** If `smc2`
  has been up less than the time your step needs, you are going to lose
  the run, and the failure will look like something else.

`smc1` (prefill) has shown none of this and was stable throughout.

### 12.9 State the cluster was left in

- `smc1` / prefill: `rocm-aic:latest` container `vllm-pd-prefill` running
  the **proven leg-A configuration** (NixlConnector only, `UCX_NET_DEVICES=ens51f0`),
  `/health` 200, side channel bound `10.30.75.198:5600`. GPUs up.
- `smc2` / decode: **rebooting repeatedly** (§12.8); last seen up at
  12:44 and down again by 12:47. A `vllm-pd-decode` container exists but
  the node has not stayed up long enough to finish loading it, and
  `modprobe amdgpu` will need re-running after whatever the current boot
  is. `nvme connect` NOT re-established — the target no longer offers the
  subsystem anyway (§12.5). Do not interpret decode being down as a
  consequence of any change in this session's commits; it is 6.20.
- `smc3` / target: running, but serving **another party's**
  configuration (§12.5). Not touched.
- No proxy running.

To get back to the proven leg-A state once `smc2` is stable: relaunch both
roles and the proxy, then re-run the §11 measurement. Nothing about the
leg-A fix depends on the storage target.

---

## 13. The `ionic` RDMA stack is broken on both compute nodes (2026-09-15, session 4)

Found by following up an operator's hypothesis that there was a
version/ABI mismatch between `ionic` and the kernel uverbs ABI. There is.
It is worse than one mismatch, and it has been true since the OS upgrade
in session 2 without anything reporting it.

**There is no functioning RDMA userspace on `smc1` today:**

```
$ ibv_devinfo
libibverbs: Warning: couldn't load driver 'libionic-rdmav34.so':
            cannot open shared object file: No such file or directory
No IB devices found
```

Zero devices — while sysfs simultaneously reports all eight ports healthy:

```
ionic_0 .. ionic_7   state=4: ACTIVE   phys_state=5: LinkUp
/dev/infiniband/uverbs0 .. uverbs7 all present, plus rdma_cm
/sys/class/infiniband_verbs/abi_version = 6
```

That combination is the whole trap: every cheap indicator looks right.

### 13.1 Break one — userspace provider ABI mismatch

| | |
|---|---|
| Provider on disk | `libionic-rdmav59.so` → `libionic.so.1.0.61.0` (Jan 21 2025) |
| Owning package | **none** — `dpkg -S` finds no match. It is an orphan. |
| `libionic1`, `rdma-core 61.0-1` | state `rc` — removed, config files only |
| Installed userspace | Ubuntu `ibverbs-providers` / `libibverbs1` `50.0-2ubuntu0.2` |
| Provider ABI that libibverbs 50 loads | `lib*-rdmav**34**.so` |

Every other provider in `/usr/lib/x86_64-linux-gnu/libibverbs/` is
`-rdmav34.so`. The AMD-built ionic provider is ABI **59**, built against
rdma-core 61. `libibverbs` 50 looks for `libionic-rdmav34.so`, does not
find it, and loads **no ionic provider at all**.

This cannot be repaired with `apt` as the machine currently stands:

```
$ apt-cache policy libionic1
  Installed: (none)
  Candidate: (none)
```

and no Pensando/AMD apt source is configured anywhere in
`/etc/apt/sources.list*`.

### 13.2 Break two — kernel driver against DSC firmware

Independent of the above, and equally fatal:

```
ionic 0000:08:00.3 ionic_0: opcode CREATE_QP (2) error BAD_ATTR (5)   [all 8, repeatedly]
infiniband ionic_0: Couldn't create ib_mad QP1
infiniband ionic_0: Couldn't open port 1
```

`ionic_rdma` is DKMS `26.09.4.001~ubu22.04` — the **22.04** source package
rebuilt against the 6.8 kernel. Its `vermagic` matches `6.8.0-139-generic`
so it loads cleanly, but the card rejects the QP attributes it passes.
Failing to create QP1 (the GSI special QP) means no MAD agent, which means
no SA and no CM, which means `rdma_cm` cannot establish a connection no
matter what `state=ACTIVE` claims.

So the kernel modules being present, loaded, and correctly versioned for
the running kernel proves nothing on its own — all three are true here.

### 13.3 Why this went unnoticed for two sessions

The OS upgrade (session 2) replaced the AMD DSC userspace with Ubuntu's
while leaving the DKMS kernel modules rebuilt and in place. That split a
matched vendor stack in half. Then:

- **Preflight cannot detect it.** Its only assertion is
  `check_soft "rdma-core userspace tools present" command -v ibv_devinfo`
  — the *binary exists*. Its inventory step runs `ibv_devinfo -l`, and
  with zero devices that returns empty, whereupon preflight logs
  `none found (expected in Phase 1 / KV_TRANSPORT=tcp)` and **passes
  green**. Fixing this is TODO 3.7.
- **Nobody re-ran preflight after the upgrade** — so §6's RDMA entry
  still described the pre-upgrade machine.
- **Leg A never touched verbs.** It runs UCX over TCP.
- The containers never mapped `/dev/infiniband`, so UCX inside them
  enumerated only `tcp/self/sm/rocm` — which was read as a consequence of
  the missing device mapping. It would have been empty regardless.

### 13.4 The failure pattern, stated plainly

This is the fourth instance in one session of a check that passed while
the thing it checked was broken, and it is the most instructive:

| # | Check | What it actually proved |
|---|---|---|
| 1 | HTTP 200 + coherent completion | that vLLM serves. Not that any KV moved. |
| 2 | `create_backend()` returned without error | nothing — the function has no `return` |
| 3 | `00-preflight.sh` GPU check | `check_soft`, so 0 GPUs still passes |
| 4 | `00-preflight.sh` RDMA "verified" | that 8 names existed in sysfs, on a kernel since replaced |

The first three prove too little. **The fourth is different: it was a
correct verification that silently expired.** The ground moved under a
recorded fact and nothing re-checked it. That is a failure mode this
document's whole Verified/Assumed split is supposed to guard against, and
it did not, because the split has no notion of a fact going stale.

Treat every "Verified" entry taken before 2026-09-15 as suspect if it
concerns anything the OS upgrade could have touched — kernel, drivers,
userspace libraries, device nodes. Entries about hardware identity, plugin
source code, and Gerrit status are unaffected.

### 13.5 What it blocks, and what it does not

- **Blocks all of TODO §3 (Phase 2 RDMA acceptance).** 3.6 frames the
  blocker as a missing route between `30.1.x` and `30.2.x`. That is real
  but secondary: there is currently no verbs layer for a route to carry.
  Fix the stack first, then the routing. Tracked as TODO 3.7, which 3.1
  and 3.6 now sit behind.
- **Does not affect leg A.** The §11 result is TCP/UCX and stands.
- **Invariant 6 behaves correctly here**, and is worth keeping for exactly
  this reason: `UCX_TLS=ib,rocm,self,sm` with no ib devices makes UCX fail
  rather than fall back to TCP and report a good number over the wrong
  transport.

### 13.6 Remediation sketch — not attempted

The DSC driver bundle (`ionic`, `ionic_rdma`, `pds` DKMS + `libionic1` +
a matching `rdma-core`) is a matched set. Options, in order of
correctness:

1. **Install the AMD DSC bundle built for 24.04.** The `~ubu22.04` suffix
   on all three DKMS packages suggests only the 22.04 bundle was ever
   installed. This is the real fix and needs the vendor package.
2. Rebuild the ionic provider against rdma-core 50 to produce a
   `libionic-rdmav34.so`. Addresses break one only — break two is
   kernel/firmware and would survive it.
3. Check DSC firmware level (`ethtool -i <ionic netdev>`) against driver
   `26.09.4.001`. `CREATE_QP ... BAD_ATTR` is the signature of the card
   disagreeing with the driver about QP attributes, which firmware skew
   would also produce.

Do (1) if the package can be obtained; do not bother with (2) alone.

### 13.7 Someone else is on this hardware

Recorded because it affects how to read anything measured here:

```
14:52  ionic_N: opcode CREATE_QP (2) error BAD_ATTR (5)   [storm, all 8 devices]
14:58  ionic 0000:33:00.0 enp51s0: Link up - 200 Gbps
```

A 200G link came up during this investigation. Together with the KV target
being reconfigured mid-session (§12.5) and the target's 200G links coming
up (TODO 6.19), this is active work by another party on the same machines.
Some observations in this section may be racing their changes — re-verify
before acting on anything here, and find out who else is on these boxes
(TODO 6.18).

---

## 14. The DSC software was updated — §13 is half-fixed, and the other half is now precisely characterised (2026-09-16)

Another party installed a matched AMD DSC bundle for 24.04 between
sessions — §13.6's remediation option (1). Re-measured on both compute
nodes. The picture is better and much sharper.

> **Tooling note:** the tool for this is `show_gid` (there is no
> `show_igb` on either node). It prints the per-device GID table with the
> associated netdev, and is the only convenient way to confirm both the
> `UCX_IB_GID_INDEX` value and the `ionic_N` → netdev mapping at once.

### 14.1 Break one — userspace provider ABI — FIXED

| | Before (§13) | Now |
|---|---|---|
| `libionic1` | `rc` (removed), `~ubu22.04` | **`ii` 50.0.26.06.3.001-1** |
| Provider file | only `libionic-rdmav59.so` (orphan) | **`libionic-rdmav34.so`** present |
| `ionic_rdma` | `26.09.4.001~ubu22.04` | **`26.06.9.001`** |
| `ibv_devinfo` | `No IB devices found` | **works** |

Identical on `smc1` and `smc2`. The `~ubu22.04` suffix is gone — this is
a 24.04-matched build, which is what §13.6 asked for. The stale
`libionic-rdmav59.so` orphan is still on disk and is now harmless.

`show_gid` returns **24 GIDs per node**, three per device:

```
ionic_0  1  0  fe80::...                   v2  benic1p1   link-local IPv6
ionic_0  1  1  ::ffff:30.1.1.1   30.1.1.1  v2  benic1p1   IPv4 RoCEv2
ionic_0  1  2  2001:0db8:0001::1           v2  benic1p1   global IPv6
```

**This confirms `UCX_IB_GID_INDEX=1` in `config/cluster.env` is correct** —
index 1 is the IPv4 RoCEv2 GID on every device, on both nodes. That value
was previously a default nobody had verified.

### 14.2 Break two — NOT fixed, but it is narrower than §13 claimed

The `ib_mad QP1` / `CREATE_QP ... BAD_ATTR` failures still occur, and they
are **contemporaneous with the new driver**, not leftovers:

```
06:06:26  boot
06:10:50  ionic_rdma : AMD Pensando RoCE HCA driver     <- NEW module loads
06:10:50  infiniband ionic_0: Couldn't create ib_mad QP1
06:10:51  ionic 0000:a5:00.3 ionic_5: opcode CREATE_QP (2) error BAD_ATTR (5)
```

But §13 characterised the consequence too broadly. Measured directly:

| Path | Result |
|---|---|
| Device enumeration (`ibv_devinfo`, `show_gid`) | **works** |
| **RC QP** create + data (`ibv_rc_pingpong`, GID idx 1) | **WORKS** — 9.6 µs RTT (`smc1`), 11.1 µs (`smc2`). See the warning below before quoting any bandwidth figure from this. |
| **UD QP** create (`ibv_ud_pingpong`) | **FAILS** — `Couldn't create QP` |
| **`rdma_cm`** connect (`rping`) | **FAILS** — `rdma_connect: Invalid argument` |
| GSI/MAD QP1 (a UD QP) | **FAILS** — `CREATE_QP BAD_ATTR` |

> **Do not read a throughput number out of that RC row.**
> `ibv_rc_pingpong` prints a `Mbit/sec` figure (6819.56 on `smc1`, 5900.95
> on `smc2`) and it is close to meaningless here, for three independent
> reasons:
> - It is a **latency** test. It sends one 4 KB message and waits for the
>   reply before sending the next — the byte total is exactly
>   `4096 x 1000 iters x 2 directions = 8,192,000`. The rate is bounded by
>   round-trip stalls, not by the link.
> - It ran **loopback**, `-d ionic_0 ... localhost`. Both ends are the same
>   device on the same host. **The traffic never crossed the fabric.**
> - These are 200 Gb/s NICs, so ~5.9 Gb/s is about 3% of line rate. Quoted
>   without context it reads as a catastrophic fabric result rather than
>   what it is: an irrelevant one.
>
> The `smc1`-vs-`smc2` difference is not real either. On `smc2` the two
> ends of the *same* run disagreed — client 5900.95 Mbit/s / 11.11 us,
> server 4917.17 Mbit/s / 13.33 us — so the error bars swamp the
> cross-node gap. Both figures above are client-side, so at least the
> comparison is like-for-like, but it supports no claim that one node's
> fabric is faster.
>
> For a real transport number: `ib_write_bw` / `ib_send_bw` from
> `perftest`, **cross-node**, once 3.6's routing exists and 3.10's
> firmware skew is levelled. Until then there is no RDMA throughput
> measurement on this cluster, and this section does not provide one.

**The pattern is: this driver/firmware cannot create UD queue pairs. RC
queue pairs work and move data.** QP1 is a UD QP, which is why the MAD
agent fails; `rdma_cm` fails downstream of that because CM MADs ride the
GSI QP.

So §13's "no verbs layer for a route to carry" is **no longer true** — there
is a working RC verbs layer today. §13's narrower claim, that `rdma_cm`
cannot establish a connection regardless of `state=ACTIVE`, is **confirmed
exactly**.

### 14.3 Why this probably does not block us

NIXL/UCX do not need `rdma_cm`. NixlConnector exchanges agent metadata
over its **own** side channel — that is precisely the `getLocalMD()` /
`loadRemoteMD()` path §11 fixed — and then programs QPs directly with
`ibv_modify_qp`. `ibv_rc_pingpong` above works the same way (out-of-band
TCP exchange, no `rdma_cm`) and succeeds.

**Caveat that must be tested, not assumed:** `UCX_TLS=ib,...` (invariant 6)
expands `ib` to include UD-based transports (`ud_verbs`, and `rc_verbs`
uses a UD QP for some connection-establishment modes). On this hardware
those will fail. Phase 2 may need `UCX_TLS` narrowed to RC explicitly
rather than the `ib` alias. Tracked as TODO 3.9 — do not edit invariant 6
until it is measured, because the invariant's *reason* (never let RDMA
acceptance pass on a silent TCP fallback) remains valid and the fix must
preserve it.

### 14.4 The `ionic_N` → netdev mapping changed — TODO 2.8 is stale

Measured on both nodes, now **symmetric and all eight up**:

```
smc1:  ionic_0..7 -> benic1p1..benic8p1   all up   30.1.1.1 .. 30.1.8.1
smc2:  ionic_0..7 -> benic1p1..benic8p1   all up   30.2.1.1 .. 30.2.8.1
```

TODO 2.8 and §6 record that on `smc2` only `ionic_2/3/5/6` lined up, and
that `ionic_0/1` were `enp10s0`/`enp39s0` and **down**. That is no longer
the case. The creds pin `PREFILL_UCX_NET_DEVICES=DECODE_UCX_NET_DEVICES=ionic_2:1`
is still *valid* (ionic_2 is `benic3p1` on both), but it was chosen to work
around an asymmetry that no longer exists, and any index would now do.

**This is the fifth expired fact in two sessions** — see §13.4's table. The
pattern is now established well enough to state as a rule: *on this
cluster, any recorded measurement of driver, device, or library state has
a shelf life, because the hardware is shared and changes under us
(§13.7).* Re-measure rather than trust, and prefer a check that fails
loudly over a note in a document.

### 14.5 Firmware is not identical across the two nodes

```
smc1 (prefill):  fw_ver: 1.130.0-pi-121
smc2 (decode):   fw_ver: 1.130.0-a-120
```

Different build suffix and different build number. Both nodes carry the
same driver (`26.06.9.001`) and the same userspace (`50.0.26.06.3.001-1`),
so this is a firmware-only skew. Not known to cause a problem — RC works
on both — but RDMA is a two-sided protocol and leg A is exactly a
cross-node RC path, so this is worth levelling before trusting any P↔D
RDMA result. Recorded, not chased. TODO 3.10.

### 14.6 What is now the actual blocker for Phase 2

Routing, as TODO 3.6 always said — the IPv4 fabric addresses are still
`30.1.N.1/24` on `smc1` and `30.2.N.1/24` on `smc2`, different `/24`s with
no route. §13 re-scoped 3.6 behind 3.7 on the grounds that there was no
verbs layer; that re-scoping is now **partly withdrawn**: there is an RC
verbs layer, so routing is operative again, with 3.9 (UD/UCX_TLS) beside
it.

One observation worth following up rather than acting on: the **index-2
global IPv6 GIDs share a common `2001:0db8::/32`** — `smc1` holds
`2001:0db8:0001::1`..`0008::1`, `smc2` holds `2001:0db8:0009::1`..`0010::1`
— whereas the IPv4 GIDs differ in the second octet with no route. Distinct
`/64`s still need routing between them, so this is not a free path, but it
is a materially different addressing situation from IPv4 and may be the
easier one to route. RoCEv2 over the IPv6 GID is legitimate. Do not guess
a configuration from this; measure whether a route exists first.

---

## 15. Firmware was updated — the UD/`rdma_cm` break survives it, but the routing gap is closed and cross-node RDMA now works, measured for the first time (2026-09-16)

The operator updated firmware for the RDMA device on `smc1` and `smc2` and
asked for a connectivity re-check. Both nodes rebooted 2026-09-16 06:39
(~19 min uptime at measurement). Both have **0 GPUs and no containers
running** — the amdgpu ritual (§9.4) still applies, not addressed here.
`smc3` was **not examined this session**; nothing below says anything
about the target.

### 15.1 Firmware skew (TODO 3.10) is now all but levelled — and this DISPROVES firmware as the cause of break two

| | §14.5 | Now |
|---|---|---|
| `smc2` | `1.130.0-a-120` | all 8 ports = `1.130.0-a-120` (uniform) |
| `smc1` | `1.130.0-pi-121` | `ionic_1`..`ionic_7` = `1.130.0-a-120`; **`ionic_0` (`benic1p1`) is still `1.130.0-pi-121`** |

Measured per-port across all 8 devices on both nodes. 15 of the 16 cards
across the two nodes are now levelled; `smc1`'s `ionic_0` is the lone
holdout.

**The inference that matters:** `smc1`'s `ionic_0`, still at `-pi-121`,
and every `-a-120` card on both nodes **both emit the identical
`CREATE_QP BAD_ATTR` failure** (§15.3). A card on the old firmware and
cards on the new firmware fail the same way, on the same host, under the
same driver. Therefore **the firmware skew is not the cause of break
two.** §14.5 recorded the skew as "worth levelling before trusting any
cross-node RDMA result" — it has now been levelled (15/16) and nothing
functional changed. **TODO 3.10 is downgraded to a tidiness item, not a
blocker.**

Driver and userspace are unchanged from §14.1: `ionic`/`ionic_rdma` DKMS
`26.06.9.001`, `libionic1` `50.0.26.06.3.001-1`, `libibverbs`
`50.0-2ubuntu0.2`, kernel `6.8.0-139-generic`, provider
`libionic-rdmav34.so` present. The stale `libionic-rdmav59.so` orphan is
still on disk, still harmless. This was a firmware-only change, exactly as
the operator described.

### 15.2 Break one stays fixed

`ibv_devinfo -l` returns **"8 HCAs found"** on both nodes, no
provider-load warning. Nothing to add to §14.1.

### 15.3 Break two SURVIVED the firmware update, unchanged

Re-measured, contemporaneous with this boot — driver loads 06:39:57 on
`smc1` / 06:39:55 on `smc2`, failures immediately after:

- Exactly **8** occurrences of `opcode CREATE_QP (2) error BAD_ATTR (5)`
  and **8** of `Couldn't create ib_mad QP1` per node — one per device,
  both nodes.

| Path | Result |
|---|---|
| RC QP create + data (loopback, `-d ionic_2 -g 1`) | **WORKS** — `smc1` 9.30 us/iter, `smc2` 10.31 us/iter, 200 iters |
| UD QP create (`ibv_ud_pingpong`) | **FAILS** — "Couldn't create QP" |
| `rdma_cm` (`rping`) | **FAILS** — "rdma_connect: Invalid argument" |

Identical on both nodes, and identical to §14.2's matrix — same
transports pass, same transports fail, same error strings. **§14.2's
characterisation — "this driver/firmware cannot create UD queue pairs" —
is confirmed verbatim after a firmware change that levelled 15 of the 16
cards.** The defect is not firmware-version-specific. Attribute it to the
driver, or to something common to both firmware builds — not to the
firmware skew §14.5 flagged. **TODO 3.9 (`UCX_TLS`/UD) remains fully open
and is now the main RDMA-stack risk** — see §15.9.

### 15.4 THE HEADLINE: the routing gap (TODO 3.6) is CLOSED

Someone configured it between sessions. Static routes now exist for all 8
fabric pairs, both directions:

```
smc1:  30.2.N.0/24 via 30.1.N.2 dev benicNp1 proto static
smc2:  30.1.N.0/24 via 30.2.N.2 dev benicNp1 proto static
```

Cross-node ping over `benic3p1` succeeds both directions, **0% loss, rtt
avg ~0.10 ms**.

§14.6 named routing "the actual blocker for Phase 2". That blocker is
gone. **This was not done by us** — it follows the §13.7/§14.4 pattern of
the shared hardware changing underneath this project, this time in our
favour.

### 15.5 First real cross-node RDMA on this cluster

§14.2 said: "there is no RDMA throughput measurement on this cluster, and
this section does not provide one" — conditional on routing existing and
firmware being levelled. **Both conditions are now met, so this section
does provide one.**

Cross-node RC pingpong `smc1`→`smc2` (`ionic_2`, GID idx 1, 1000 iters):
works. Local GID `::ffff:30.1.3.1`, remote `::ffff:30.2.3.1` — distinct
GIDs, so unlike §14.2's loopback run **this genuinely crossed the
fabric**. **14.01 us/iter, client-side.**

`ib_write_bw`, RC, cross-node, `-d ionic_2 -x 1 -F`, 5000 iters, BW
average:

| msg size | MiB/s | approx Gb/s |
|---|---|---|
| 64 KiB | 28,653 | ~240 |
| 1 MiB | 40,287 | ~338 |
| 8 MiB | 41,898 | ~351 |

`ib_send_bw` (two-sided), 1 MiB, 5000 iters: **26,918 MiB/s (~226 Gb/s)**.

### 15.6 CORRECTION: these are 400 Gb/s links, not 200 Gb/s

§14.2 asserted: "These are 200 Gb/s NICs, so ~5.9 Gb/s is about 3% of line
rate." **Measured now: `ethtool` reports `Speed: 400000Mb/s` on all 8
ports on both nodes, and `/sys/class/infiniband/ionic_2/ports/1/rate`
reads `"400 Gb/sec (4X NDR)"`.** So the 8 MiB result above (~351 Gb/s) is
**~88% of line rate** — a healthy fabric number, not the ~3%-of-line-rate
figure §14.2's premise implied.

This is the **sixth** expired/incorrect fact on this cluster, extending
the §13.4 / §14.4 tally. The prior 200G figure likely came from the
§13.7 / §12.6 link-up log lines, which said `200 Gbps` — those describe
different NICs (§13.7's is a compute-node event during the driver
investigation, §12.6's is the target's data-plane NICs), and neither was
the `ionic` fabric link this cluster's RDMA path actually runs over.
§14.2's 200 Gb/s premise was carried forward from one of those without
being measured directly against the device the RC/UD tests actually used.

### 15.7 Methodology note: the throughput number was verified independently of `perftest` — and it first produced a false negative

The verification method matters, because it did not work on the first
attempt, and the way it failed is itself a lesson worth keeping.

- The kernel netdev counter `/sys/class/net/benic3p1/statistics/rx_bytes`
  is **useless for RoCE** — it moved only ~1.9 KB across a 1.95 GiB
  transfer, because RoCE bypasses the kernel netdev path entirely. Do not
  use it to confirm RDMA traffic.
- `ionic` exposes only **error** counters under
  `/sys/class/infiniband/ionic_2/ports/1/hw_counters/` — no byte
  counters there either.
- What works: MAC-level `ethtool -S benic3p1 | grep octets_rx_ok` **on
  the receiving node**.
- These counters **lag by roughly 5 seconds**. A 3-second settle produced
  a delta of 148 bytes and a spurious "did not cross" verdict. With a
  longer settle the delta was **2,147,330,651 bytes against 2,097,152,000
  expected** — a ratio of 1.024, the 2.4% excess being RoCE/Ethernet
  header overhead. That is positive proof the payload crossed the wire.

**The lesson, in this repo's voice:** an instrument that reads zero is not
evidence of absence until you have shown the instrument responds at all.
This nearly became a seventh false conclusion in the same family as
§13.4's table — the 3-second settle's "did not cross" reading was wrong
for the same underlying reason those four checks were wrong: a check that
passed (or in this case, failed) while proving the opposite of what it
looked like it proved.

### 15.8 GID mapping re-confirmed (the §14.4 expired-fact rule)

`ionic_0..7` → `benic1p1..benic8p1` on **both** nodes, all 8
ACTIVE/up, `smc1` `30.1.N.1/24` and `smc2` `30.2.N.1/24` — unchanged from
§14.4. `UCX_IB_GID_INDEX=1` is still correct — index 1 is the IPv4 RoCEv2
GID. The creds pin `ionic_2:1` is now **additionally justified**: `ionic_2`
is `-a-120` on both nodes, i.e. it avoids `smc1`'s lone `-pi-121` card
(§15.1).

### 15.9 Still open / not done this session

- **TODO 3.9 remains the top open RDMA item.** `ucx_info` is **not
  installed on the hosts** (container-only), so which UCX transport spec
  works here still could not be determined and still must be measured
  inside the container with `/dev/infiniband` mapped — which the launch
  scripts still do not do.
- **The IPv6 GID lead from §14.6 is a DEAD END for now.** Global v6 GIDs
  are present (`smc1` `benic3p1` = `2001:db8:3::1/64`, `smc2` `benic3p1` =
  `2001:db8:b::1/64`) but `ping6` across fails "Network is unreachable".
  Since IPv4 is now routed (§15.4), this lead is moot — drop it.
- **GPUs are 0 on both nodes**; the amdgpu modprobe ritual (§9.4) still
  applies.

**What this changes:**

- **3.6 closed** — the routing gap is gone; cross-node IPv4 works both
  directions.
- **3.10 downgraded** to a tidiness item, and disproved as the cause of
  break two — 15/16 cards levelled, both firmware levels fail UD
  identically.
- **3.9 is now the sole RDMA-stack blocker.**
- **Phase 2 RDMA acceptance is unblocked at the fabric level** and gated
  only on the UCX transport question (3.9) and mapping `/dev/infiniband`
  into the containers.

---

## 16. MAJOR CORRECTION: §12.1's headline conclusion is WRONG — `LMCacheMPConnector` DOES carry the KV tier, and a local-DSC path may unblock Track A (2026-09-16)

> **Implemented, 2026-09-16 — see §17.** The L2-adapter path this section
> identifies only in outline (§16.1) is now actual, running code:
> `scripts/common/start-lmcache-daemon.sh` builds and validates the
> `--l2-adapter` JSON described there, and §17.5 answers the
> `max_value_size`/split question §16.1's `mem_split_n` note raised but
> did not settle. Read this section for the *why*; read §17 for the
> *what's actually implemented now*.

**§12.1 is wrong.** It concluded `LMCacheMPConnector` "cannot carry the KV
tier at all" and that the correct child is `LMCacheConnectorV1`. That
conclusion has been steering this project's docs away from the connector
the vendor actually ships, and away from what this repo's own scripts have
emitted since §1. It is withdrawn here, in full, in the open — see §13.4
for why this repo does that rather than quietly edit the earlier text.

All evidence below is read from the installed LMCache 0.5.3 in image
`rocm-aic:mp-pd-ionic2609`, at
`/usr/local/lib/python3.12/dist-packages/lmcache` — a container variant
not previously catalogued in §10.1's image table.

### 16.1 `LMCacheMPConnector` reaches XNVME_KV through a path §12.1 never examined

§12.1 checked exactly one route into the storage backend — the in-process
`StorageManager` / `CreateStorageBackends` path, configured by
`LMCacheEngineConfig` — found MP mode never constructs one, and concluded
MP "cannot carry the KV tier at all." **There is a second route, and MP
uses it:** the distributed L2-adapter path under `lmcache/v1/distributed/`.

- `v1/distributed/config.py:28-29` registers L2 adapter types
  `nixl_store` and `nixl_store_dynamic`.
- `v1/distributed/l2_adapters/nixl_store_l2_adapter.py`:
  - `_VALID_NIXL_BACKENDS` (~line 1056) includes **`XNVME_KV`** and
    `SPDK_NVMe_KV`.
  - `_FILE_BACKENDS` (~line 1068) is `("GDS", "GDS_MT", "POSIX", "HF3FS",
    "AIS_MT")` — **`XNVME_KV` is deliberately excluded**, so no
    `file_path` is required for it.
  - ~line 234: `elif self.backend in ["OBJ", "AZURE_BLOB",
    "SPDK_NVMe_KV", "XNVME_KV"]:` routes to
    `init_storage_handlers_object`.
  - ~lines 437-440 register with `mem_type="OBJ"` — exactly the OBJ (not
    FILE) routing §12.2 identified as required.
  - ~lines 202-208: `mem_split_n` exists to split pages against a KV
    backend's `max_value_size`, and the comment reads "SPDK_NVMe_KV:
    524288 B vs. a multi-MiB **MP-mode** chunk." **This code was written
    specifically for MP mode driving a KV backend.** MP is not
    incidentally supported here; it is the path this code exists for.

### 16.2 Use the static adapter — `nixl_store_dynamic` is a different, file-oriented thing

Do not reach for `nixl_store_dynamic_l2_adapter.py` by name-similarity.
It requires `backend_params["file_path"]` (~line 105), does
`os.makedirs` (~line 106), and registers `mem_type="FILE"` (~lines
168-171) — that is the GDS/HF3FS/POSIX-style file-backend adapter. For
XNVME_KV the static `nixl_store` adapter (§16.1) is the one that routes
to `mem_type="OBJ"` with no `file_path` at all.

### 16.3 Where §12.1 went right, and the actual shape of its error

§12.1's evidence was not fabricated and is not being retracted:

- `extra_config{enable_nixl_storage, nixl_backend, nixl_backend_params}`
  **is** silently ignored under `LMCacheMPConnector` — true.
- `LMCacheEngineConfig` **is** never constructed on the MP path — true.

**The error was the inference, not the observation.** §12.1 went from "the
keys I checked are ignored" to "this connector cannot carry the tier at
all." Those keys are simply the wrong config surface for MP. Under MP the
backend is configured on the **daemon** side; vLLM's connector config
carries only the rendezvous keys `lmcache.mp.host` / `lmcache.mp.port`
(§16.4). §12.1 never looked for those because it never considered that MP
might have a config surface at all beyond the one `LMCacheConnectorV1`
uses.

§12.1 also asserted MP "requires a separately launched `lmcache server`
daemon reached over ZMQ (`mq.py:263-275` connects; nothing spawns it)."
The daemon requirement is real and correctly identified. **"Nothing spawns
it" was true only of this repo's scripts** — the vendor reference spawns
it as a compose service (§16.4). That, too, was an inference about the
component drawn from a gap in this repo's tooling.

### 16.4 The generalised lesson — sibling to §13.4, the same shape inverted

§13.4 catalogued checks that **passed** while the thing they checked was
broken. This is the same failure family, inverted: **a check that
correctly showed a key was ignored, read as if it showed a component was
incapable.** A negative result about a configuration surface is not a
negative result about a component. State it plainly because it will
happen again with some other connector, some other `extra_config` block:
before concluding "X cannot do Y," confirm you have found *every* config
surface X exposes, not just the one you expected it to use.

### 16.5 The vendor reference — authoritative, and it deploys exactly this

`/root/rixl-bench/stack/tracks/rocm-aic/deploy-xnvme.sh`, on `smc1`. Its
own summary line (~245):

```
stack : vLLM -> LMCacheMPConnector -> NixlStorageAgent l2-adapter -> XNVME_KV -> ${AIC_XNVME_DEV}
```

Its vLLM connector config (~line 173):

```
--kv-transfer-config '{"kv_connector":"LMCacheMPConnector","kv_role":"kv_both","kv_connector_extra_config":{"lmcache.mp.host":"tcp://${CONTAINER_LMCACHE}","lmcache.mp.port":${LMCACHE_XNVME_PORT}}}'
```

Default port **6557**. The daemon is a separate compose service — `docker
compose --profile storage-xnvme up -d` brings it up alongside vLLM.

**Namespace sharing is a hard requirement, not optional decoration.**
vLLM is launched with `VLLM_IPC_MODE=service:<lmcache>` and
`VLLM_PID_MODE=service:<lmcache>` — i.e. the vLLM container **shares IPC
and PID namespace** with the lmcache daemon container. Treat this the way
§7 treats its invariants: skip it and the failure will present as
something else entirely, not as a namespace error.

Also recorded in the same script: `AIC_XNVME_KV_POOL` default `2000000`,
and a deployment record with `backend=XNVME_KV`, `category="1 (real
Pensando DSC)"`.

### 16.6 The repo's own scripts were already correct — no code change needed

Reassuring, and important to say plainly so nobody "fixes" working code
toward the withdrawn conclusion: `scripts/common/gen-kv-transfer-config.sh`
still emits `LMCacheMPConnector` with `lmcache.mp.host` /
`lmcache.mp.port` (~lines 92-96), matching the vendor reference exactly.
`config/cluster.env` likewise still describes
`MultiConnector[NixlConnector, LMCacheMPConnector]`. §12.1's "correct the
architecture" was **never applied to code** — only the docs were rewritten
to contradict scripts that were right all along. **Do not touch
`gen-kv-transfer-config.sh` or `cluster.env` to chase
`LMCacheConnectorV1`.** They do not need it.

### 16.7 A dangerous trap in the vendor reference — read before running it here

`deploy-xnvme.sh` defaults `AIC_XNVME_DEV=/dev/ng0n1`. **On `smc1` and
`smc2` that default is wrong, and running it is destructive.** Measured on
both nodes:

| Device | Identity | Size | What it is |
|---|---|---|---|
| `/dev/ng0n1` | Micron_7450_MTFDKBA800TFS | 800 GB | **The OS boot drive** — carries partitions `nvme0n1p1`, `nvme0n1p2` |
| `/dev/ng1n1` | `PDSNVME-00`, model `PDSNVME` | — | The actual Pensando DSC device |

**On our nodes, `AIC_XNVME_DEV` must be set to `/dev/ng1n1`.** Running the
reference with its default would point XNVME_KV at the root disk. This is
a §7-style invariant, stated here because §7 predates this device: **never
run `deploy-xnvme.sh` on `smc1`/`smc2` without overriding
`AIC_XNVME_DEV=/dev/ng1n1` explicitly.**

The DSC namespace itself is real and provisioned, not absent:
`nvme id-ns /dev/ng1n1` gives `nsze = 0x200000` blocks at `lbads 9` (512
B) = **1 GiB**. `nvme list` displays "0.00 B / 0.00 B" only because
`nuse=0` (unused, not unprovisioned) — do not read that as an absent
namespace. 1 GiB is small for a KV tier; flag as a **sizing question to
confirm before relying on it**, not as a blocker.

### 16.8 Strategic consequence — Track A may not need `smc3` at all

> **CORRECTED 2026-09-16/17 — see §18.2. This section's premise, that the
> local DSC is a separate device that "does not need `smc3` at all," is
> WRONG.** `nvme ns-descs` against `/dev/ng1n1` on both nodes returns an
> **identical** `eui64` and `csi`, and the DSCs are themselves NVMe-oF
> initiators peered to `smc3`'s `nvmf_tgt` — the "local DSC" *is* `smc3`'s
> namespace, transparently re-exported over each node's own PCIe function,
> not an independent 1 GiB device. Left in place because the correction is
> the useful record (§13.4's rule); read §18.2 before acting on anything
> below.

Both `smc1` and `smc2` have their **own local DSC** (§16.7). §9.3's Track A
was recorded as "Blocked by 6.18" because it needed this repo's KV
subsystem restored on the shared `smc3` target, currently owned by another
party. **A local-DSC XNVME_KV tier does not need `smc3` at all.** Track A
is therefore potentially unblocked without resolving the `smc3` ownership
question.

State this as what it is — **a newly available option to evaluate, not a
proven result.** Nothing has been deployed or measured against the local
DSC by this repo. It also changes the storage tier's topology from remote
NVMe-oF (the design this repo has assumed since §1) to a local device —
a real architectural difference, and one this repo should decide on
deliberately rather than by default. It aligns with §10.1's standing
observation that the lab does not run the model this repo originally
assumed; this is one more instance of that same pattern.

### 16.9 What this changes

- **§12.1's headline conclusion is withdrawn.** `LMCacheConnectorV1` is
  not the required child; `LMCacheMPConnector` reaches XNVME_KV via the
  L2-adapter path (§16.1). §12.1's ordering finding (NixlConnector must be
  first on the decode side, `multi_connector.py:387-400`) is unaffected
  and stands.
- **§12.7's launch recipe is corrected** to `LMCacheMPConnector` with
  `lmcache.mp.host` / `lmcache.mp.port`, per §16.5.
- **§9.3's Track A entry is corrected** — composition is
  `MultiConnector[NixlConnector, LMCacheMPConnector]`, and Track A may no
  longer be gated on 6.18 if the local-DSC path (§16.8) is adopted.
- **No code change is required.** `gen-kv-transfer-config.sh` and
  `cluster.env` were right the whole time (§16.6).
- **New hard warning:** never point `AIC_XNVME_DEV` at `/dev/ng0n1` on
  `smc1`/`smc2` — that is the OS boot drive. Use `/dev/ng1n1` (§16.7).
- **Track A's blocked-by-6.18 status needs re-evaluation**, not
  automatic closure — the local-DSC option is unproven and 6.18 (the
  `smc3` ownership question) remains true on its own terms if the
  remote-target design is kept instead.

---

## 17. The matrix is collapsed to one stack, the MP daemon exists, and §12.7's `max_value_size` question is answered (2026-09-16)

Commits `c055f7d` and `0b75adb`, plus a follow-up commit carrying the
`config/cluster.env` edit (§17.7), turn §16's outline into running code. Nothing here was
measured on live hardware against `smc3` or the local DSC — that live
composed run is still gated on 6.18/6.20 exactly as §12.9 left it. What
changed is that the code this repo runs no longer has a matrix of
postures to get wrong, the daemon §12.1 said "nothing spawns" now has a
launcher, and one of §12.7's open questions is closed by evidence rather
than by further guessing.

### 17.1 The connector matrix is gone — one composition, and the order is enforced in code, not chosen by a flag

This repo used to expose three switches — `PD_ENABLED` (whether the outer
connector was `MultiConnector` at all, or a lone `LMCacheConnectorV1`),
`PD_CONNECTOR`, and `PD_LMCACHE_FIRST` (child order) — eight combinations,
of which exactly one was ever the intended architecture. All three are
deleted, along with the `LMCacheConnectorV1` single-connector code path
they could select. There is now exactly one shape
`scripts/common/gen-kv-transfer-config.sh` can emit:

```
MultiConnector[NixlConnector, LMCacheMPConnector]
```

with `NixlConnector` hardcoded as `connectors[0]`. This is not a style
preference: `MultiConnector.get_num_new_matched_tokens` walks its children
in list order and assigns the **entire** load to the first child reporting
a non-zero match (`multi_connector.py:387-400`, quoted in full in the
generator's own header comment). If `LMCacheMPConnector` were listed
first, any decode request whose prefix is already in the local L2 tier
would be satisfied by LMCache before `NixlConnector` is even asked, and
the direct P→D remote-prefill pull this whole architecture exists to
measure would be silently skipped whenever the L2 tier has anything
cached — which is most of the time once a storage tier is live. This was
§12.1's one surviving finding, reaffirmed at §16.9, and it is now
expressed as a hardcoded order in `gen-kv-transfer-config.sh`, not a
variable an operator (or a future session) can flip back.

Also deleted as part of the same cleanup: `scripts/common/
start-vllm-container.sh` and its `patch-vllm-nixl-pkg.sh` helper. Both
were orphaned (no caller) and both built a bare `NixlConnector` with no
LMCache at all — a configuration this repo's own composition decision
(§1, TODO 0.1) never sanctioned, and one that §9.3 had been pointing
resume-time operators at as the "baseline" restore step. It no longer is;
see the rewritten §9.

### 17.2 The "leg A / leg B" framing is retired — they were never independently deployable

§1's "Two independent legs" framing (and this doc's running use of "leg
A"/"leg B" throughout §2–§16) implied two things that could, in
principle, be stood up separately. They never could be: the composition
decided at TODO 0.1 and unchanged since is `MultiConnector[NixlConnector,
LMCacheMPConnector]`, both children present, every time. What the old
framing was actually pointing at are two always-on KV paths inside **one**
stack:

- **The P→D handoff** — `NixlConnector` over UCX, prefill pushing decode's
  remote-prefill pull, TCP today / RDMA at acceptance (§3, §9).
- **The storage tier** — `LMCacheMPConnector` → the MP daemon (§17.3) →
  its `nixl_store` L2 adapter (§17.4) → `smc3` (or, per §16.8, a local
  DSC).

§1 is corrected in place to say this (not left as a contradiction to
this section); see the note there pointing back here.

### 17.3 The MP daemon now exists — this closes §12.1's "nothing spawns it"

§12.1 correctly identified that `LMCacheMPConnector` needs a separately
launched daemon reached over ZMQ, and correctly noted nothing in this
repo started one. **That was true of this repo's scripts, not of the
component** (§16.3 already said as much in the abstract; this is the
concrete fix). `scripts/common/start-lmcache-daemon.sh` /
`stop-lmcache-daemon.sh` now exist, are wired into
`scripts/{prefill,decode}/03-start-*.sh` (called first, idempotently,
before `start-vllm.sh`) and into `scripts/{prefill,decode}/99-stop.sh`.
They are deliberately **not** numbered like `scripts/common/`'s
`00-preflight.sh` / `10-build-stack.sh` / `20-build-vllm-lmcache.sh` /
`25-validate-lmcache-config.sh` sequence — those numbers mean ordered
one-time build/setup steps, and this is runtime lifecycle, same category
as `start-vllm.sh`, `deploy.sh`, and `tune-tcp.sh`, none of which carry a
number either. (The scripts briefly existed as `30-start-lmcache-daemon.sh`
/ `31-stop-lmcache-daemon.sh` in `c055f7d`; renamed in `0b75adb` once this
distinction was made explicit — recorded so the rename doesn't look like
churn.)

The entry point was **read**, not guessed, from the installed package
inside `rocm-aic:mp-pd-ionic2609`:

- `lmcache_server` (`lmcache/v1/server/__main__.py`) is a decoy — an
  older, separate raw-socket remote-cache server (`STORE`/`RETRIEVE`/
  `EXIST`/`HEALTH` over a bare TCP socket), not MP mode, not what
  `LMCacheMPConnector` talks to.
- The `lmcache` console script's `server` subcommand
  (`lmcache/cli/commands/server.py`'s `ServerCommand.execute`) calls
  `lmcache.v1.multiprocess.http_server.run_http_server(...)` directly.
  That module is also directly runnable (`if __name__ == "__main__":` at
  `lmcache/v1/multiprocess/http_server.py:279`), and this is exactly what
  the package's **own** reference launcher,
  `lmcache/lmcache_frontend/run_mp_server_with_frontend.sh`, invokes.
  `start-lmcache-daemon.sh` runs the same module the same way, verified
  against both ends of the ZMQ handshake: the server does
  `bind_url=f"tcp://{mp_config.host}:{mp_config.port}"`
  (`lmcache/v1/multiprocess/server.py`), and the client
  (`lmcache_mp_connector.py`) reads `lmcache.mp.host`/`lmcache.mp.port` out
  of `kv_transfer_config`'s `extra_config` — exactly the keys
  `gen-kv-transfer-config.sh` already emitted (§16.6).

`LMCACHE_MP_PORT` moves to **6557** to match that reference (was an
unverified placeholder before). `LMCACHE_MP_HOST` stays loopback
(`tcp://127.0.0.1`) **by design, not by omission** — `config/cluster.env`'s
comment now states why: vLLM and the daemon are two processes on the
**same** host, so they share an IPC namespace, and `MemoryObjMetadata
.address` — a raw pointer — has to survive the ZMQ crossing between them.
That only works within one host's address space; loopback is the only
correct value here, not a default nobody chose deliberately.

`start-vllm.sh` gained a hard gate on the daemon's ZMQ port being
reachable (`wait_for_port`, 30 s, `die`s with a pointer to
`start-lmcache-daemon.sh` on timeout) — alongside its pre-existing gate on
`smc3` (or the resolved KV target) being reachable. Both gates are
required, not alternatives: a healthy daemon on this host says nothing
about whether the far end of the storage tier answers, and vice versa.

### 17.4 The KV tier attaches daemon-side via a repeatable `--l2-adapter` JSON spec

This is the mechanism §16 identified only in outline ("the distributed
L2-adapter path... a config surface this section never examined"). Every
flag and key below was **read from the installed lmcache 0.5.3** in
`rocm-aic:mp-pd-ionic2609`, and the JSON specs were round-tripped through
that same installed parser before being trusted.

- `http_server.parse_args` composes `add_storage_manager_args`, which
  calls `add_l2_adapters_args`
  (`lmcache/v1/distributed/l2_adapters/config.py:402-441`), adding a
  **repeatable** `--l2-adapter <JSON>` flag (`action="append"`).
  `parse_args_to_l2_adapters_config` `json.loads`s each one and dispatches
  on a `"type"` key to a registered config class.
- `NixlStoreL2AdapterConfig` self-registers as `"nixl_store"`
  (`nixl_store_l2_adapter.py:1071`, registration at `:1167`) and requires
  `backend`, `backend_params`, and `pool_size` — `pool_size` has no
  default, so an operator cannot forget it silently.
- Emitted for the two backends this repo knows, matching each plugin's
  actual `backend_params` shape:

  ```
  XNVME_KV      {"type":"nixl_store","backend":"XNVME_KV",
                 "backend_params":{"dev_uri":"..."},"pool_size":2000000}
  SPDK_NVMe_KV  {"type":"nixl_store","backend":"SPDK_NVMe_KV",
                 "backend_params":{"trid":"...","kv_slot_offset":"..."},
                 "pool_size":2000000}
  ```

  Both round-trip through the installed parser, including the exact
  `parse_args_to_config` path `http_server` itself calls — this was
  checked against the installed classes, not asserted from reading the
  source alone. `scripts/common/25-validate-lmcache-config.sh` gained
  `--l2-adapter-json` to run exactly this check in about a second, and
  `start-lmcache-daemon.sh` calls it on every spec it builds before ever
  spawning the daemon subprocess.
- **Static `nixl_store`, not `nixl_store_dynamic`.** The dynamic adapter
  is file-oriented — it requires `backend_params["file_path"]`, calls
  `os.makedirs`, and registers `mem_type="FILE"` — and has nothing to do
  with a KV-keyed backend. The static adapter's `_VALID_NIXL_BACKENDS`
  includes both `SPDK_NVMe_KV` and `XNVME_KV`; its `_FILE_BACKENDS`
  deliberately excludes them, so neither ever needs a `file_path`. Both
  route through `init_storage_handlers_object()` with `mem_type="OBJ"` —
  the same OBJ (not FILE) routing §12.2 already established this LMCache
  build uses for these two backend names on the in-process path.
- `backend_params` is forwarded **verbatim** to
  `nixl_agent.create_backend(backend, backend_params)`
  (`nixl_store_l2_adapter.py:201`) — the same NIXL plugin init path
  `gen-kv-transfer-config.sh`'s `NixlConnector` side and
  `gen-lmcache-config.sh`'s in-process YAML both use. Each plugin's C++
  constructor prefers an **env var** over this dict over its own
  compiled-in default: `NIXL_XNVME_DEV` over `dev_uri`
  (`plugins/xnvme-kv/xnvme_kv_backend.cpp:508-520`), `NIXL_KV_TRID` over
  `trid` (`plugins/nvme-kv/spdk_nvme_kv_backend.cpp:602-611`). `lib.sh`'s
  `setup_nixl_kv_env` exports those env vars with the NQN resolution and
  the boot-drive guard attached (§16.7), so it wins either way —
  `start-lmcache-daemon.sh` puts the same resolved value in
  `backend_params` too, deliberately redundant rather than a second
  source of truth that could drift from the env var.

### 17.5 §12.7's `max_value_size` question — ANSWERED, and the earlier worry was aimed at the wrong layer

§12.7 asked, as an untested known-unknown: does XNVME_KV actually declare
`max_value_size` via `get_plugin_params`, and if a 10 MiB LMCache page
hits a 32 KiB per-value ceiling, does the multipart split absorb it? Both
halves are now answered, and the second half's premise turns out not to
apply on the path this repo actually runs.

- **Yes, both backends declare it, queried live against the installed
  plugins in `rocm-aic:mp-pd-ionic2609` via `nixl_agent.get_plugin_params()`:
  XNVME_KV declares `max_value_size = 32768`, SPDK_NVMe_KV declares
  `524288`.**
- **But the split never engages on the MP/L2-adapter path, and §12.7's
  10-MiB-chunk-vs-32-KiB-ceiling worry was analysing a different layer.**
  The `page_size` handed to `init_storage_handlers_object` is
  `l1_memory_desc.align_bytes` — i.e. `--l1-align-bytes`, which defaults
  to **4096** and is not overridden by `start-lmcache-daemon.sh`. 4096 is
  far below both declared ceilings (32768 and 524288), so
  `_resolve_mem_split()` resolves `mem_split_n = 1` for both backends at
  this daemon's default page size: **the adapter-level split never
  engages.** §12.7's "10 MiB chunk against a 32 KiB ceiling" tension was
  reasoning about the **in-process** `LMCacheEngineConfig.chunk_size` —
  the `LMCacheConnectorV1`/`StorageManager` layer §12.1 originally (and
  wrongly) concluded was the only way in. On the MP path this repo
  actually runs, the adapter never sees a whole LMCache chunk as one
  storage unit at all — only 4096-byte tiles, well under either ceiling.
  XNVME_KV's own internal multipart splitting inside the plugin itself
  (the "32 KiB parts" proven in TODO 6.12) is a separate, lower layer and
  is unaffected by any of this.
- **`pool_size` counts 4 KiB pool slots, one per raw L1 page — never one
  per LMCache chunk.** This is why the vendor's own tested default is
  2,000,000, not something matched to L1 capacity: their own comment
  records that an L1-size-matched value (5,242,880 at a 20 GiB default L1
  / 4096 B) was still spinning at 100% CPU with zero forward progress
  after ten-plus minutes, while 2,000,000 comes up in about 90 s.
  `LMCACHE_L2_POOL_SIZE` defaults to 2,000,000 for the same reason;
  raising it needs its own startup-time re-check, not a capacity
  calculation.
- **The single-region-L1 constraint does not fire here either.**
  `_HYBRID_L1_SINGLE_REGION_L2_ADAPTERS` lists `nixl_store`, but
  `validate_storage_manager_config` only enforces that constraint when a
  hybrid DRAM+Device-DAX L1 is also configured (`--l1-devdax-path` plus a
  matching DAX L2 adapter). `start-lmcache-daemon.sh` passes neither, so
  plain pinned-DRAM L1 is unconditionally the single-region case and the
  constraint is inert. Recorded so nobody adds a DAX/GDS L1 tier here
  without re-reading this first.

### 17.6 The YAML-vs-daemon trap, now documented where it can't be missed again

§12.1's original error was reading "these YAML keys are ignored under MP"
as "MP cannot reach the backend" (§16.3/§16.4's diagnosis). That trap is
now stated plainly in the code that would otherwise re-invite it:
`gen-lmcache-config.sh`'s header states, as of this change, that **none**
of the `extra_config` keys it emits (`enable_nixl_storage`, `nixl_backend`,
`nixl_backend_params`, the `nixl_buffer_*` fields) are consumed by
anything running on this repo's actual path — confirmed by grepping the
installed `lmcache_mp_connector.py` for any reference to
`LMCACHE_CONFIG_FILE` / `LMCacheEngineConfig` / `lmcache_get_or_create_config`
and finding none. The YAML is **not deleted** — it remains correct
documentation of the same `backend_params` shape (`trid` vs `dev_uri`)
the `--l2-adapter` JSON now also emits, it still exercises
`25-validate-lmcache-config.sh`'s introspection checks against the same
installed `nixl_storage_backend.py`, and it is what the in-process
`LMCacheConnectorV1` path would read if this repo ever needed it again.
It is simply, now, explicitly labelled as inert on the path that is
actually live, so the next reader cannot make §12.1's mistake by staring
at this file alone.

### 17.7 KV_BACKEND: XNVME_KV is now the canonical default; SPDK_NVMe_KV is kept, deliberately, not deleted

`config/cluster.env`'s `KV_BACKEND` default flips from `SPDK_NVMe_KV` to
**`XNVME_KV`** — the working tree and `HEAD` both carry this edit now.
The rationale is measured history, not a preference:

- The CSI-1 kernel blocker that made XNVME_KV unusable is **closed**: on
  5.15 `nvme connect` logged `unknown csi 1` and created no device node at
  all; on 6.8 it logs `block device for nsid 1 not supported (csi 1)` and
  **does** create the generic char device (§10.4's re-test, TODO 6.8), and
  the path was then proven end-to-end (§10.5, TODO 6.12).
- It needs no `vfio-pci`, no hugepages, and no DPDK/SPDK version pairing —
  removing a whole class of the failures §10.4 and §12 record for the
  from-source SPDK path.
- The `rocm-aic` image already ships the XNVME_KV plugin in all three of
  LMCache's hardcoded backend tuples (§12.2), so no allowlist patch is
  required for it either.

**SPDK_NVMe_KV is deliberately kept fully wired** — the build step, the
plugin, `lib.sh`'s arm, the `--l2-adapter` spec (§17.4), and the verify
ladder all still branch on it — rather than deleted, so the comparison
between the two remains available and a regression in one can be
attributed against the other. Switching `KV_BACKEND` still requires
draining the namespace exactly as before (§7 invariant 5); that has not
changed.

### 17.8 A wrong turn during this same consolidation, corrected before it landed: smc3 was nearly deleted

Recorded honestly, per this repo's own rule (§13.4/§16.4) that a wrong
turn belongs in the open rather than quietly absent from the history. An
early pass of this exact consolidation misread a design note about "two
separate nodes" — meaning two physically distinct compute nodes, each
needing its own instance of everything — as "two nodes total," and on
that misreading deleted `smc3`, the SPDK target tree, and the storage-tier
scripting wholesale, leaving only the P→D leg. That was wrong and was
reverted **in full** before it ever reached a committed state, so it does
not appear as a revert in `git log` — it is recorded here instead, because
the mistake and its correction are exactly the kind of thing this doc
exists to keep visible.

**`smc3` stays.** It is the physical KV store; both compute nodes reach it
over NVMe-oF; `XNVME_DEV` is empty by default and resolved at runtime by
subsystem NQN (`resolve_xnvme_kv_dev()`, §6's Verified entry), not pinned
to a path. Nothing about §16.8's local-DSC option changes this — that
option is still unproven and evaluated separately, not a replacement
decided by this correction.

### 17.9 1P1D → xPyD: the fleet-shape seam, implemented and tested against fakes, not yet run on more than one real pair

`config/cluster.env` grows `PREFILL_HOSTS`/`PREFILL_PORTS`/`DECODE_HOSTS`/
`DECODE_PORTS` (plural, space-separated) alongside the existing singular
`PREFILL_HOST`/`DECODE_HOST`, defaulting to the singulars so 1P1D is
unchanged in behaviour. `scripts/proxy/disagg_proxy.py` replaces its four
scalar endpoint variables with an `EndpointPool` per role and a
round-robin `select()`; at N=1 this returns the same endpoint every time,
by construction. Going to xPyD means adding entries to the plural
variables and giving each additional instance its own NIXL side-channel
port (base port + instance index) — not restructuring the proxy itself. P
and D are selected independently per request, a request keeps its decode
endpoint for its whole lifecycle, and `/status` reports per-endpoint
request counts so balancing is observable rather than assumed.

The risk in this refactor was §11.1's handoff semantics — the exact thing
two prior sessions burned time proving — and it was tested, not
eyeballed, against fake upstreams: the priming request body, the
`min_tokens`/`stream_options` drop on the priming copy only, the handoff
threading into decode, §11.4's empty-dict-is-absent rule, the
`prefill_no_handoff` counter, and the swallow-prefill/502-on-decode
asymmetry all have passing tests. **What this has not been run against
is real hardware with more than one prefill or decode instance** — every
live measurement in this doc (§11, §12, §15) is still N=1. Treat the
fleet shape as implemented and unit-tested, not as proven at scale.

### 17.10 What this changes

- **§12.1's ordering finding stands, now in code, not just in docs** —
  `NixlConnector` as `connectors[0]` is no longer a convention to
  remember, it is the only shape `gen-kv-transfer-config.sh` can emit
  (§17.1).
- **§12.1's "nothing spawns it" is closed** — `start-lmcache-daemon.sh` /
  `stop-lmcache-daemon.sh` exist and are wired into role start/stop
  (§17.3).
- **§16's L2-adapter outline is now implemented**, with the exact JSON
  shape, file:line evidence, and validation path at §17.4. See the
  forward-pointer added at §16.
- **§12.7's `max_value_size` open question is answered** at §17.5. See
  the forward-pointer added at §12.7.
- **The "leg A / leg B" framing is retired** (§17.2); §1 is corrected in
  place with a pointer here.
- **§9 is rewritten** to drop the Track A/Track B split — there is one
  stack to bring up, with RDMA acceptance (§3) as the one genuinely
  separate remaining workstream.
- **`KV_BACKEND` default is now `XNVME_KV`**, committed (§17.7).
- **Still not done by any of this**: an actual live LMCache hit served
  through the composed daemon+L2-adapter path against real hardware.
  6.18 (`smc3` ownership) and 6.20 (`smc2` reboot instability) gate that
  exactly as they did before this session — nothing here required
  touching either.

---

## 18. The remote target came up, the KV namespace is confirmed SHARED, the device geometry shrank, and the P→D leg is re-verified against a different model (2026-09-16/17)

Everything below was measured directly on `smc1`/`smc2`/`smc3` this
session. It supersedes several standing assumptions rather than merely
adding to them — each subsection says exactly what it supersedes and why,
per this doc's own rule (§13.4) of leaving the wrong turn visible rather
than quietly editing it away.

### 18.1 The model changed — every historical throughput/latency figure in this document is against a different model

The running stack is `Qwen/Qwen3-8B`, `--tensor-parallel-size 1`
(`creds/active.env`), **not** `Qwen2.5-72B-Instruct` at TP=8 — 72B is a
145 GB download that is not present on either compute node's disk today.
Also pinned: `--gpu-memory-utilization 0.85`, `--max-model-len 32768`,
`--block-size 64`.

**Read this as a hard boundary, not a footnote.** Every prompt-throughput,
TTFT, and decode-latency number recorded anywhere in §§2–17 above — the
§11 4033-token-prompt result (prefill 403.3 tok/s, decode 0.0 tok/s /
100% hit), the §17 launch parameters, all of it — was measured against
72B/TP=8. None of it is a valid comparison baseline for anything measured
from this session onward, and none of the new numbers in this section
(§18.7) should be read back against those older ones as if the model had
not changed. `config/cluster.env`'s own tracked *default* is unchanged
(still `Qwen2.5-72B-Instruct`/TP=8, per `docs/ARCHITECTURE.md` §2) — this
is a creds-level override for this specific deployment, not a decision to
change the default.

### 18.2 The KV namespace is confirmed SHARED across P and D — the topology blocker that has shaped this project's storage-tier design since §1 is GONE

`/dev/ng1n1` on **both** `smc1` and `smc2` is a local PCIe function of
that node's own Pensando DSC (`0000:36:00.0`, model `PDSNVME`, subsystem
NQN `nqn.2019-08.com.pensando:nvm-subsystem-sn-8001-0-0`). `nvme id-ctrl`
and `nvme id-ns` succeed on both, as §16.7 already recorded.

**What §16.7/§16.8 did not know, and what changes everything:**
`nvme ns-descs /dev/ng1n1 -n 1` returns `csi: 0x1` (the KV command set)
and `eui64: e46cfefeffcdae01` — **identical** on both nodes. Same
namespace, same identifier, on both sides. Namespace size is `nsze
0x200000` @ `lbads 9` = 1 GiB, also matching §16.7's earlier reading.

The host is **not** the NVMe-oF initiator here — the DSC is. `nvme
list-subsys` on both compute nodes shows only local PCIe subsystems, no
NVMe-oF connection at all. `smc3` (`volcano17`) runs `nvmf_tgt` serving
`nqn.2016-06.io.spdk:cnode1` on `1.1.0.2:4420`, and the two DSCs are its
peers — each one re-exports that same remote namespace transparently as
a local PCIe function, `/dev/ng1n1`, on its own host.

**This supersedes §16.7/§16.8 outright.** Those sections read `/dev/ng1n1`
as a distinct, node-local, unshareable 1 GiB device, and framed a
"local-DSC XNVME_KV tier" as an *alternative* to `smc3` precisely because
it looked independent of it. It is not independent of it — it **is**
`smc3`, one hop closer. The correction block added at §16.8 points here.
Practical consequences:

- **The topology blocker this project has carried since §1** — that a
  KV storage backend can only be a shared, cross-node tier if it's a
  remote NVMe-oF target, and that a node-local device is a dead end for
  that purpose — **is gone.** `/dev/ng1n1` on `smc1` and `/dev/ng1n1` on
  `smc2` already point at the same physical namespace, with no extra
  wiring required, and no decision to make between "local DSC" and
  "`smc3`" — they were never two options.
- **6.18 (`smc3` shared-resource ownership) is NOT sidestepped by using
  the local DSC** — the opposite of what §16.8 speculated. Any other
  party's use of `smc3`'s subsystem is exactly as visible from `/dev/ng1n1`
  as it would be from a direct `nvme connect`, because it is the same
  backing store. Evaluate 6.18 on its own terms; there is no local-DSC
  escape hatch from it.
- **The remaining blocker is unchanged and is NOT a topology problem —
  see §18.4/TODO 6.21.** Physical sharing was never what stood between
  this project and a cross-node hit; the per-daemon random key naming is.

### 18.3 The device KV geometry changed: `value_max` 32768 → 4096

The plugin now logs, at backend init:

```
[XNVME_KV] device KV format 0: value_max=4096 key_max=16 novg=0 (compiled-in default 32768)
WARNING: device value_max=4096 is SMALLER than the compiled-in default 32768
```

`novg=0` here is itself notable — earlier sessions (§10.4/§10.5, TODO 6.4)
measured `novg=4096` against the 131072/32768-ceiling device; this is a
different geometry entirely, not a re-measurement of the same one.

Previously (§10.4, TODO 6.4) this document recorded 32768 as a **measured
DSC firmware ceiling** — a real, empirically-established limit, not a
config knob. **That is no longer true; the device's own ceiling moved
under us, again**, in the same shared-hardware-changes-under-you pattern
§13.7/§14.4/§15 already catalogue. `scripts/verify/20-verify-nixl-plugin.sh`
currently **FAILS**:

```
RESULT:MAX_VALUE_SIZE_MISMATCH:reported='32768' expected=4096
```

**Resolution applied, this session, config/comment side only — read the
still-open half below before assuming this is settled:**

- `creds/active.env` now sets `KV_MAX_VALUE_SIZE_XNVME=4096`
  (`config/cluster.env`'s `KV_MAX_VALUE_SIZE_EFFECTIVE` resolves from
  this for `KV_BACKEND=XNVME_KV`).
- `scripts/common/container.sh` no longer exports
  `NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` — it never took effect anyway,
  because `lib.sh`'s `setup_nixl_kv_env()` (`lib.sh:613-621`) `unset`s it
  unconditionally right after `env.sh` is sourced, per invariant 4. An
  operator control silently annulled downstream is worse than no control;
  see `container.sh`'s own comment (added this session) for the full
  three-reason rationale.
- **This particular transition is NOT destructive**, unlike invariant 4's
  general warning. The MP daemon's `nixl_store` L2 adapter unit is
  `--l1-align-bytes` (4096 B, §17.4/§17.5) — every stored object has
  always been exactly 4096 B, under both the old 32768 ceiling and the
  new 4096 one, so `mem_split_n == 1` either way. No object has ever been
  split, so the half-stale-reassembly hazard invariant 4 exists to
  prevent (§7 invariant 4) cannot fire for *this specific* change. **It
  would fire** if `--l1-align-bytes` itself changes, or if
  `max_value_size` ever drops below 4096 — the invariant's reasoning is
  unaffected, only this one transition happens to be safe.
- **STILL OPEN — the plugin's own compiled-in default is unchanged.**
  `XNVME_KV_DEFAULT_MAX_VALUE_SIZE` (`plugins/xnvme-kv/xnvme_kv_backend.h:71`)
  is still `32768u`. `scripts/common/container.sh plugin-build` has not
  been re-run to align it, so `20-verify-nixl-plugin.sh`'s mismatch above
  persists until that rebuild happens.
- **Recommended durable fix, NOT yet applied — a config knob, not a code
  fix to the ceiling itself.** Give the plugin an explicit
  `NIXL_KV_MAX_VALUE_SIZE=<N>` override that `getParams()` returns
  unconditionally, and promote the device-vs-config mismatch from a
  `WARNING` to a hard init failure. Rationale, read directly off
  `container.sh`'s own reason 3 (added this session): the existing
  `NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` knob is call-order dependent —
  `getParams()` reads `discovered_max_value_size_`, which `start_workers()`
  only populates during `create_backend()`, so any caller that calls
  `get_plugin_params()` **before** `create_backend()` (which
  `20-verify-nixl-plugin.sh` itself does, `:171` then `:214`) still sees
  the stale compiled-in value even with the device-adoption flag set.
  On-wire geometry must never depend on call order. The correct model:
  geometry comes from **config** (`KV_MAX_VALUE_SIZE_EFFECTIVE`), the
  device is a **validator**, and a disagreement is a startup failure, not
  a warning to scroll past.

### 18.4 `retrieve_ops=0` on BOTH nodes — measured, and this confirms TODO 6.21 is still live

XNVME_KV plugin runtime metrics, read from `${NIXL_KV_METRICS_PATH}`
(`/run/kv-cache-bench/*.json`):

| role | store_ops | store_bytes | completions_ok | completions_err | stalls | retrieve_ops | retrieve_bytes |
|---|---|---|---|---|---|---|---|
| prefill | 313,143 | 1,282,633,728 (1.28 GB) | 312,439 | 704 | 11 | **0** | **0** |
| decode | 442,368 (368,640 + 73,728 across two engine pids) | ~1.81 GB | — | — | — | **0** | **0** |

This is exactly the failure signature TODO 6.21 already identified —
`nixl_store_l2_adapter.py`'s per-daemon `uuid4` object naming
(`key = f"obj_{i}_{uuid.uuid4().hex[0:4]}"`) means prefill and decode
never name the same object, so cross-node retrieve is impossible by
construction, independent of anything in §18.3. **Confirmed still true,
not newly discovered.**

**New, and genuinely open: `retrieve_ops=0` on PREFILL by itself is a
question that deserves its own investigation, separate from the
cross-node key mismatch.** `LMCACHE_MAX_LOCAL_CPU_SIZE=4` (GiB) means L1
should be evicting constantly under this store volume, and a
same-daemon L2 read-back on an L1 eviction miss is exactly the kind of
lookup the key-mismatch argument does **not** explain — a daemon reading
back its own previously-evicted object needs no cross-daemon key
agreement at all. That retrieve count is zero anyway is not yet
explained by anything recorded in this document. Do not assume it is the
same cause as the cross-node case without checking.

**State plainly, so it is not re-litigated:** cross-node L2 retrieve
remains **impossible**, and nothing in §18.3's `max_value_size` work
touches this — they are unrelated layers. Cross-node KV movement on this
stack happens over the P→D `NixlConnector` handoff (§11, §18.7), which is
the only mechanism this architecture has for it (§4/§18.9's summary).

### 18.5 The DSC wedge is active and getting worse — top open operational issue for the storage tier

Building on TODO 6.22's first characterisation of the DSC stall
watchdog: **within a single observation window this session,
`completions_err` went 512 → 704 and `stalls` went 8 → 11.** The errors
arrive in exact multiples of the plugin's fixed 64-deep queue
(`704 == 11 × 64`) — this is the **stall-watchdog signature** (per-queue
`fail_queued_work()` firing after the timeout), **not** a size-rejection
signature. Verbatim:

```
queue made no forward progress for 30s: 0 op(s) queued, 1 in flight
```

Contrast this with TODO 6.22's earlier stall log (`37705 op(s) queued, 64
in flight`) — a saturated queue with a large backlog draining slowly. This
one is nearly idle (`0 queued, 1 in flight`) and still cannot make
progress, which is a different, and worse, presentation: the device is
not merely behind, it is not responding to the one outstanding op at all.

**A standalone `scripts/verify/30-verify-kv-roundtrip.sh --write` wedged
on its very first store** and returned `NIXL_ERR_BACKEND`. Per the
plugin header's own `stall_timeout_ns_` documentation
(`plugins/xnvme-kv/xnvme_kv_backend.h`), only an out-of-band DPU-side
restart clears this condition — host-side resets make it **worse**, not
better. Mark this the **top open operational issue for the storage
tier**, ahead of TODO 6.21's key-derivation gap and §18.3's rebuild, both
of which are moot against a device that will not complete a single
operation.

**Practical lesson worth recording plainly:** do **not** run
`30-verify-kv-roundtrip.sh` against a device a live vLLM engine is
already driving. The standalone probe above was not the first cause of
the wedge — it hit an already-wedging device mid-session and its
`NIXL_ERR_BACKEND` result would otherwise misattribute the failure to the
verify script or its inputs, rather than to device state that predates
the probe. Confirm nothing else is live on the device before trusting a
negative result from this script.

### 18.6 `scripts/verify/50-verify-pd-direct.sh` had four defects that together produced a false-negative acceptance rung on a fully healthy system — all four now fixed, 9/9 passing

All four defects made the P→D acceptance rung **fail** even when the
underlying transfer was genuinely working — the exact "check passed/failed
while proving the opposite" failure family §13.4/§16.4 already catalogue,
this time on the verification side rather than the thing being verified:

1. **The priming request never included
   `kv_transfer_params={"do_remote_decode": true, ...}`**, so
   `NixlConnector` never staged blocks and never returned a handoff — this
   is the exact trap `scripts/proxy/disagg_proxy.py`'s own module
   docstring documents at lines 44-51 (§11.1's three-step handshake). The
   proxy itself was fixed 2026-09-15 (§11.1); this verify script was not
   updated to match and kept priming without the handoff field.
2. **The side-channel reachability check probed
   `${PREFILL_HOST}`/`${DECODE_HOST}`**, but `lib.sh`'s `setup_pd_env()`
   binds `${PD_SIDE_CHANNEL_HOST_<ROLE>}` if set, else the first IP from
   `hostname -I | awk '{print $1}'`. `smc2` enumerates fabric NICs before
   its management NIC, so decode had actually bound `30.2.1.1` (a fabric
   address), not the management `10.30.75.204` the check assumed. The
   script now resolves the side-channel host the same way `lib.sh` does,
   rather than re-deriving it independently.
3. **A race against vLLM's periodic stats logger.** The script grepped
   the decode log immediately after issuing the request, but vLLM's
   "External prefix cache hit rate" line comes from a ~10 s periodic
   logger, not a per-request one. Fixed by capturing a baseline reading
   before the request, then polling for a **new** stats line for up to
   45 s — matching §15.7's lesson that an instrument's absence of signal
   is not evidence of absence until the instrument has been shown to
   respond at all.
4. **A dead hard assertion.** The script hard-asserted on the literal
   string `need to load: <nonzero>`, which vLLM 0.26.0+rocm / LMCache
   0.5.3 never emit at default verbosity — verified **absent** even on
   runs independently proven to transfer KV. This assertion could never
   pass and was demoted to corroborating-only. The hard assertion is now
   that the cumulative "External prefix cache hit rate" **increased**
   versus the pre-request baseline — presence of the string alone is
   meaningless for a cumulative rate; only the delta means anything (same
   reasoning as defect 3).

**Also recorded: `bc` is not present in the `rocm-aic:mp-pd-ionic2609`
image.** Float comparisons in verify scripts must use `awk`, which is
present everywhere this stack runs; a `require_cmd ... bc` would `die`
before a single check ran, turning a working acceptance rung into an
unconditional failure on this image.

With all four fixed, `50-verify-pd-direct.sh` **passes 9/9** — see §18.7
for the measured result.

### 18.7 P→D direct transfer re-verified working, against the new (Qwen3-8B/TP=1) stack — measured

A controlled A/B on a fresh-nonce ~1230-token prompt, read from the
decode engine log:

| condition | Avg prompt throughput | External prefix cache hit rate |
|---|---|---|
| WITH handoff threaded in | **0.0 tokens/s** | rose 48.3% → 58.2% |
| WITHOUT handoff (negative control) | 124.7 tokens/s | fell 50.5% → 33.4% |

Same qualitative signature §11 established against 72B/TP=8 — decode does
no prefill work when the handoff fires, and does full prefill when it is
deliberately withheld — reproduced against a different model. **Do not
compare the throughput numbers themselves across the two sessions** (§18.1).

Full rung run: `50-verify-pd-direct.sh` **PASSED 9/9**, hit rate rose
58.2% → 65.0% over the run, decode `Avg prompt throughput` held at 0.0.
`40-verify-disagg.sh` **PASSED 9/9** with TTFT improving **2.14x**.
Proxy `/status` reported `prefill_no_handoff: 0` throughout both runs —
the counter that would have caught §11's original defect, still clean.

**Caveat this repo already makes, and it still applies unchanged:** the
P→D leg runs over the 1 GbE **management** NIC (`UCX_NET_DEVICES=ens51f0`
on both nodes, §11.2) — none of the numbers above are transport
benchmarks. Nothing about the RDMA fabric (§3, §14, §15) was exercised by
this measurement.

### 18.8 Side-channel bind addresses are now pinned in creds

`PD_SIDE_CHANNEL_HOST_PREFILL=10.30.75.198` and
`PD_SIDE_CHANNEL_HOST_DECODE=30.2.1.1` are now set explicitly in
`creds/active.env`, removing the `hostname -I`-first-IP lottery §18.6's
defect 2 depended on to reproduce — with these pinned, `setup_pd_env()`
no longer has to guess, on either node.

**Known, non-correctness asymmetry, left as a follow-up, not fixed here:**
bulk KV still rides UCX over `ens51f0` (management) on both nodes (§11.2),
while decode's metadata **side channel** now sits on a fabric NIC
(`benic1p1`, i.e. `30.2.1.1`) rather than the management NIC prefill uses.
This is asymmetric by IP class, not merely by address, and nothing has
broken because of it yet — `50-verify-pd-direct.sh` passes 9/9 with this
pin in place — but it is worth resolving to one class or the other before
trusting it under a topology change (e.g. the xPyD fleet shape, §17.9).

### 18.9 What this session changes

- **§18.1**: the model is `Qwen/Qwen3-8B` TP=1, not `Qwen2.5-72B-Instruct`
  TP=8 — every prior throughput/latency figure in this document is
  against the other model and is not a valid comparison baseline.
- **§18.2 SUPERSEDES §16.7/§16.8**: the "local DSC" is not a separate,
  node-local, unshareable device — it is `smc3`'s own namespace,
  re-exported per-node over PCIe. The topology blocker this project has
  carried since §1 is gone; 6.18 is not sidestepped by using it.
- **§18.3**: `XNVME_KV`'s device-reported `value_max` moved 32768 → 4096.
  Config-side resolved (`KV_MAX_VALUE_SIZE_XNVME=4096`, the dead
  `NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` export removed); the plugin's
  compiled-in default (`xnvme_kv_backend.h:71`) still needs a
  `plugin-build` to align, and `20-verify-nixl-plugin.sh` fails until it
  does. A durable fix (explicit `NIXL_KV_MAX_VALUE_SIZE` override +
  promoting the mismatch to a hard failure) is recommended, not applied.
- **§18.4 confirms TODO 6.21 is still live**: `retrieve_ops=0` on both
  roles, measured. New open question, not previously asked: why
  `retrieve_ops=0` on **prefill alone**, given L1 should be evicting
  under a 4 GiB cap — not yet explained by the cross-node key-mismatch
  argument, which only accounts for the cross-node case.
- **§18.5**: the DSC wedge is worse than TODO 6.22 characterised it —
  `completions_err`/`stalls` climbing within one session, a new
  near-idle stall signature (`0 queued, 1 in flight`), and a standalone
  verify script wedging on its first store. Top open operational issue
  for the storage tier. Practical lesson: never point
  `30-verify-kv-roundtrip.sh` at a device a live engine is already
  driving.
- **§18.6/§18.7**: `50-verify-pd-direct.sh`'s four defects (missing
  handoff request, wrong side-channel host resolution, a stats-logger
  race, a dead string assertion) are fixed; the rung passes 9/9 and the
  P→D direct-transfer result is reproduced against the new model.
- **§18.8**: side-channel bind addresses are pinned in creds, removing
  the first-IP lottery; a management-vs-fabric NIC asymmetry on the
  side channel is recorded as a non-blocking follow-up.

---

## 19. Both compute nodes rebooted: a DSC boot-time race, cross-node storage-tier store+retrieve PROVEN in both directions, the DSC wedge cleared, and LMCache's L2 tier isolated as the sole remaining blocker (2026-09-17)

Everything below was measured directly on `smc1`/`smc2` after both compute
nodes were rebooted this session. As with §18, each subsection says what it
supersedes rather than quietly editing an earlier claim away.

### 19.1 The DSC NVMe controller has a boot-time race — new this session, not previously recorded

At boot, the kernel probes the DSC NVMe controller (PCIe `0000:36:00.0`,
`[1dd8:1005]`) roughly 3 seconds after PCIe enumeration — before the
DPU-side application is ready to answer it — and the probe fails:

```
nvme nvme1: Device not ready; aborting initialisation, CSTS=0x0
```

The kernel `nvme` driver then detaches, and **nothing re-probes it**.
Symptoms: `/dev/ng1n1` absent, the device shows `enable=0` in sysfs, no
driver bound to the PCI slot — while `lspci` still shows the function
present and enumerated: `36:00.0 ... DSC NVMe Controller [1dd8:1005]`.

**Diagnostic that distinguishes "the card is dead" from "the NVMe
personality specifically isn't ready yet" — check this before assuming a
hardware fault:** the DSC's *other* PCI functions bind and work fine on
the same boot — `pds_core` on `08:00.2` (firmware `1.130.0-a-120`) and
`ionic` on `35:00.0` — config space reads correctly
(`setpci -s 36:00.0 00.L` → `10051dd8`, i.e. the device answers config
cycles), and the PCIe link itself is healthy (`LnkSta` `32GT/s x16`, full
width and speed). A `CSTS=0x0` on a function with a healthy link and
sibling functions bound cleanly means the DPU-side NVMe/KV application is
not yet serving — not that the card, slot, or link is bad.

**Manual recovery — works ONLY if the DPU side has already come up in the
background; fails identically otherwise:**

```
echo -n "0000:36:00.0" > /sys/bus/pci/drivers/nvme/bind
```

This takes roughly 2 minutes to resolve either way. If the DPU-side
application is not yet ready, it fails with the exact same
`CSTS=0x0`/`Device not ready` signature as the original boot-time probe —
the rebind is not a fix by itself, it is a way to re-trigger the probe
once the actual precondition (DPU-side readiness) has been met.

On a reboot where the DPU side was already up by the time the kernel got
to it, the probe succeeds cleanly on the first try:

```
nvme nvme1: 63/0/0 default/read/poll queues
nvme nvme1: block device for nsid 1 not supported (csi 1)
```

**Record explicitly: the second line is EXPECTED, not an error.** `csi 1`
is the KV command set, which has no block-device semantics — that is
exactly why only the char device `/dev/ng1n1` appears and `/dev/nvme1n1`
correctly does **not**. This is the same signature §18.2/TODO 6.25 already
established as healthy; it is restated here only because this section's
subject is the boot race that precedes it, not the csi-1 behaviour itself.

**Added to the per-boot ritual (§9.4) because of this:** after any reboot,
confirm `/dev/ng1n1` exists before attempting to start anything on that
node. `start-vllm.sh` already hard-gates on it by design (§7), so a
missing device fails loudly there too — but a manual roundtrip run or a
verify-script invocation ahead of that gate will not, and will instead
report a confusing device-open failure that looks unrelated to boot order.

### 19.2 Cross-node storage-tier STORE + RETRIEVE is PROVEN, in both directions — this is a first

**This supersedes §18.2's framing.** §18.2 established that `/dev/ng1n1`
on both nodes is the *same namespace* (`csi 0x1`, identical `eui64`) — a
topology fact, established without moving a single byte between nodes.
This session moved actual data across it, both directions, on a
namespace confirmed clean beforehand (`nuse: 0`) with **no vLLM engine
running** — a clean, uncontaminated test on a pristine device, not one
sharing the namespace with a live workload. `nvme ns-descs` reconfirmed
`csi 0x1` / `eui64 e46cfefeffcdae01`, identical on both nodes, matching
§18.2 exactly.

Using `scripts/verify/30-verify-kv-roundtrip.sh` — keys are derived purely
from `(nonce, size)` via sha256; **the two sides never exchange the key
directly**, so a successful cross-node read is proof the namespace is
shared, not proof the test script leaked information between processes:

| direction | size | max_value_size | parts | result |
|---|---|---|---|---|
| WRITE on `smc1` (prefill) → READ on `smc2` (decode) | 24,576 B | 4096 | 6 | **RESULT:OK** — all 6 sub-keys confirmed present by `query_memory` before read, byte-for-byte compare passed |
| negative control: never-written nonce, read on `smc2` | — | — | — | **RESULT:QUERY_MISS**, non-zero exit |
| WRITE on `smc2` (decode) → READ on `smc1` (prefill), reverse direction | 1,048,576 B | 4096 | 256 | **RESULT:OK** |

The negative control is the reason the positive results above are not a
false pass — a nonce that was genuinely never written correctly reports
`QUERY_MISS` rather than a stale hit against leftover namespace data. The
reverse-direction run (`smc2` → `smc1`, 256 parts) exercises the
multipart `#{j}`-suffix path heavily, which the smaller forward-direction
run barely touches.

**This supersedes every earlier statement in this document that the
storage tier cannot move data between nodes.** The topology blocker is
definitively gone, in both directions, at the plugin/device layer. What
remains broken sits one layer up, in LMCache — see §19.4.

### 19.3 The DSC completions-error wedge (§18.5) is CLEARED

§18.5 recorded `completions_err` climbing 512 → 704 and `stalls` 8 → 11
within a single session, with a standalone verify script wedging on its
very first store — and stated that only a DPU-side restart was known to
clear it.

Plugin metrics across every process, checked after all of §19.2's runs:
**`completions_err=0`, `stalls=0`, everywhere.** The reboot — with the DPU
side up, per §19.1 — cleared it, consistent with §18.5's own prediction
that only an out-of-band DPU-side restart (not a host-side reset) would
do so. Not yet known: whether the reboot cleared it incidentally or
whether it recurs under the same sustained-load conditions §18.5/TODO
6.22 first measured it under — this is a clean baseline, not a proof the
wedge cannot recur.

### 19.4 LMCache's L2 tier still does not retrieve — and is now cleanly isolated as the sole remaining blocker

**This is the headline finding of this session, and it sharpens TODO
6.21 from "the diagnosed cause" to "the only remaining candidate cause,
with the alternatives ruled out by direct measurement."** Per-process
plugin metrics after a full stack run, both roles:

| role | pid | store | retrieve | identity |
|---|---|---|---|---|
| prefill | 193 | 6 | 0 | this session's own roundtrip write |
| prefill | 308 | 0 | 256 | this session's own roundtrip read |
| prefill | **759** | **36,864** | **0** | **the LIVE vLLM engine** |
| decode | 253 | 256 | — | this session's own reverse-direction write |
| decode | 28 | — | 6 | this session's own cross-node read |
| decode | **707** | **0** | **0** | **the LIVE vLLM engine** |

Every single non-zero `retrieve_op` measured anywhere on either box came
from the standalone roundtrip runs in §19.2 — never from an
LMCache-driven engine. The two live vLLM engines together stored **36,864**
objects into the shared, now-proven-working namespace, and retrieved
**zero** of them.

**Why this matters more than a repeat of TODO 6.21's original diagnosis:**
before this session, "the plugin/device/topology don't support cross-node
retrieve" was one of the candidate explanations for `retrieve_ops=0` on
both roles (§18.4 explicitly left this open, and flagged prefill's
own-process `retrieve_ops=0` as a separate, unexplained question). §19.2
closes that candidate directly — the plugin, the device, the shared
namespace, and cross-node retrieve all demonstrably work, on this exact
namespace, this session. What does **not** work is LMCache's
`nixl_store_l2_adapter.py`, which names every stored object
`obj_{i}_{uuid.uuid4().hex[0:4]}` with a fresh `uuid4` drawn independently
by each daemon at startup (TODO 6.21's original finding, unchanged) — so
prefill and decode never agree on a key for identical content, regardless
of what the underlying device is capable of.

TODO 6.21 is therefore no longer one of several candidate explanations
for `retrieve_ops=0` — after this session's evidence, it is **the**
remaining blocker, and it is an LMCache patch (the key-derivation scheme
in `nixl_store_l2_adapter.py`), not a plugin defect and not a topology
problem. §18.4's separate open question — why prefill's own-process
`retrieve_ops=0` even on a same-daemon L1-eviction miss — remains
unexplained and is not resolved by this session; it is a different
mechanism than the cross-node key-mismatch and should still be
investigated on its own.

### 19.5 P→D leg re-verified on the fully rebuilt stack

Re-running the acceptance ladder §18.6/§18.7 already established, this
time against the freshly rebooted, freshly reconnected stack (not a
repeat of the same live processes — a genuinely new engine instance):

- `scripts/verify/50-verify-pd-direct.sh`: **9/9 PASSED.** External prefix
  cache hit rate rose **0.0% → 100.0%** — a fresh engine, so the 0.0%
  starting point is a genuine baseline, not a stale reading — while decode
  logged `Avg prompt throughput: 0.0 tokens/s`, the same signature §18.7
  established.
- `scripts/verify/40-verify-disagg.sh`: **9/9 PASSED.**
- Proxy `/status`: `prefill_no_handoff: 0` — the counter that would catch
  §11's original silent-defect class, still clean.
- Decode's NIXL side channel is bound to `30.2.1.1:5601`, matching the
  pinned `PD_SIDE_CHANNEL_HOST_DECODE` (§18.8) — confirming that pin is
  now deterministic across a reboot, rather than the `hostname -I`
  first-IP accident §18.6's defect 2 depended on to reproduce.

This does not supersede §18.6/§18.7 — it reproduces the same result on a
rebuilt stack, which is worth recording because nothing about the P→D
leg is assumed to survive a reboot untouched (§9.5's standing warning).

### 19.6 Still open — do not read anything above as closing these

- `20-verify-nixl-plugin.sh` still **FAILS**:
  `RESULT:MAX_VALUE_SIZE_MISMATCH:reported='32768' expected=4096`. The
  plugin's compiled-in `XNVME_KV_DEFAULT_MAX_VALUE_SIZE`
  (`plugins/xnvme-kv/xnvme_kv_backend.h:71`) is still `32768u`, unchanged
  since §18.3/TODO 6.24 — `container.sh plugin-build` has not been re-run.
  This did **not** prevent any of §19.2's roundtrips, because the harness
  does its own splitting at `KV_MAX_VALUE_SIZE_EFFECTIVE=4096`; the two
  facts are independent, not a contradiction.
- The explicit `NIXL_KV_MAX_VALUE_SIZE=<N>` override plus promoting the
  device/config mismatch from a warning to a hard init failure (§18.3's
  recommended durable fix) is still unimplemented.
- §18.4's separate open question — `retrieve_ops=0` on prefill by itself,
  independent of the cross-node key mismatch — is untouched by this
  session and still unexplained.

### 19.7 What this session changes

- **§19.1**: new finding, not previously recorded — a DSC NVMe
  boot-time race (`CSTS=0x0` if the kernel probes before the DPU side is
  ready), with a diagnostic that separates it from a dead card and a
  manual-recovery command that only works once the DPU side is actually
  up. Added to the per-boot ritual, §9.4.
- **§19.2 strengthens §18.2 from "confirmed shared" to "confirmed
  working"**: cross-node store+retrieve through the shared namespace is
  proven in both directions, on a clean namespace, with a negative
  control. This supersedes every earlier statement that the storage tier
  cannot move data between nodes.
- **§19.3**: the DSC completions-error wedge §18.5 flagged as the top
  open operational issue is cleared — `completions_err=0`/`stalls=0`
  across every process, after the reboot.
- **§19.4 isolates TODO 6.21 as the sole remaining blocker**: with the
  plugin, device, topology and cross-node retrieve all directly proven
  working (§19.2), the live vLLM engines' `store=36,864`/`retrieve=0`
  can no longer be attributed to anything but LMCache's
  `nixl_store_l2_adapter.py` per-daemon `uuid4` key naming. This is now a
  targeted LMCache patch, not an open-ended investigation.
- **§19.5**: the P→D leg (§18.6/§18.7) is reproduced, 9/9 on both rungs,
  against the rebuilt stack — not a new result, a re-confirmation that
  survives a reboot when the per-boot ritual (§9.4, now including §19.1)
  is followed.
- **§19.6**: TODO 6.24's plugin-rebuild gap and its recommended durable
  fix remain open and unchanged; do not read §19.2-§19.5 as having
  touched either.

---

## 20. The LMCache from-source patch generator withdrawn — and a same-day factual error in this section, corrected (2026-09-17)

This repo's patch directory used to carry an LMCache subtree (a shell
entry point plus a Python scan-and-patch engine module) that generated an
in-place edit to an **installed-from-source** LMCache, adding
`SPDK_NVMe_KV`/`XNVME_KV` to two hardcoded NIXL-backend allowlists in
`lmcache/v1/storage_backend/nixl_storage_backend.py`. That generator was
removed from the tree — `git rm -r`'d, not left behind untracked — and
**remains withdrawn**; the reasoning below explains why, and also
corrects a second claim this section originally made that was false.

1. **It targeted a build path that has never completed. This reasoning
   stands.** The generator only applied to LMCache installed via
   `scripts/common/20-build-vllm-lmcache.sh` into `/opt/kvstack/venv` — the
   from-source chain `docs/TODO.md` §6.2 tracks as parked/deprioritised.
   This lab runs the vendor container image `rocm-aic:mp-pd-ionic2609`
   instead, which never touches that venv at all. Git history holds the
   generator if the from-source path is ever revived.

2. **"The LMCache actually installed in that image (0.5.3) already accepts
   both backends, unpatched" — this reasoning was FALSE and is retracted,
   corrected 2026-09-17, same day it was written.** On the strength of
   this claim, `patches/lmcache/` (the whole directory, including five
   `.patch` files unrelated to the withdrawn generator) was `git rm`'d —
   staged, caught and reverted before commit. **The image accepts
   `SPDK_NVMe_KV`/`XNVME_KV` because it was BUILT with LMCache patches
   applied, not because stock LMCache 0.5.3 does.** The patch set —
   `0006`-`0009`, `0011` — lives in a sibling build repo and is now also
   tracked here at `patches/lmcache/`, as conventional `.patch` diffs
   consumed at image-build time (a different mechanism from the withdrawn
   generator's deploy-time source-scanning, but the same underlying
   intent). `nixl_store_l2_adapter.py` (the file the MP daemon's
   `--l2-adapter` actually uses) carries `0006`'s allowlist widening and
   `0007`'s `mem_split_n`/`#{j}` multipart-split machinery — the latter is
   not upstream LMCache at all, it originates in `0007`. The MP daemon
   store of ~1.16 GB (§19.4's `store` column) this section originally cited
   as evidence of "no patch" is real and still stands as evidence the
   backend works — it was the *inference* from that evidence ("therefore
   unpatched") that was wrong. See `patches/lmcache/README.md` for the
   full per-patch table and a copy-pasteable re-verification recipe
   against any future image.

So: the generator's withdrawal (point 1) is correct and unaffected by this
correction. What was wrong was concluding, additionally, that the
*patches* were unnecessary — they are necessary, they are just not applied
by anything in this repo at runtime, because the image ships prebuilt with
them already in place. Every doc that cited this section's original point
2 (`README.md`, `BRINGUP.md` §6.2, `TROUBLESHOOTING.md`, `ARCHITECTURE.md`
§2, `TODO.md` 2.7 / 6.10 §12.2) carries its own dated correction pointing
back here and to `patches/lmcache/README.md`.

**Git history holds the withdrawn generator** — a straightforward `git
log`/`git show` lookup on the commit that removed it — if the from-source
build path in `docs/TODO.md` §6.2 is ever revived and actually reaches an
installed LMCache tree, that is the one condition under which reviving the
generator (or just applying `0006`-`0009`/`0011` to that from-source tree
directly) would matter again. Short of that, if
`scripts/common/25-validate-lmcache-config.sh` ever reports a backend
**REJECTED** against some future vendor image, that is the signal to
re-run `patches/lmcache/README.md`'s verification recipe against that
image — the patches may be missing from that build, not that this repo
needs a runtime patch step. `patches/spdk/` is unaffected — it is
unrelated, still live, target-side SPDK support.
