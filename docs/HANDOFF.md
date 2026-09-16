# Handoff

State of the P/D-disaggregated KV cache project, for whoever picks this up
next (including future me). Last updated 2026-09-15.

Read this before [BRINGUP.md](BRINGUP.md). It tells you what is real, what is
assumed, and what is still wrong.

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

### Two independent legs

This distinction is the thing to get right; an earlier pass got it wrong and
built an entire phase plan around the mistake.

| Leg | Path | Transport | NICs |
|---|---|---|---|
| **A — P→D transfer** | prefill → decode, direct GPU-to-GPU via NIXL/UCX | TCP now → **RDMA = acceptance** | DSC Ethernet Controller `[1dd8:1002]` (10/node, `ionic` driver) |
| **B — Shared KV storage** | both compute nodes → target over NVMe-oF | **TCP, permanently by design** | Same `[1dd8:1002]` ID on the target (2 present) — no distinguishing name confirmed |

**Why leg B can only ever be an LMCache tier, never `NixlConnector`'s
transport itself:** `NixlConnector`'s handshake (`getLocalMD()`) requires
RDMA-style addressable memory. Storage/KV backends — SPDK_NVMe_KV and
XNVME_KV alike — return `NIXL_ERR_INVALID_PARAM` there (verified from
`/root/rixl-bench`'s `11-deploy-qwen-nixl-xnvme.sh`, quoted in full at
§10.3). A KV backend can therefore never carry the P/D handshake itself; it
is only reachable as an LMCache storage tier underneath NixlConnector, which
is exactly what the composition below does.

Composed as `MultiConnector[NixlConnector, LMCacheMPConnector]`: NixlConnector
carries the P/D role and moves KV over RDMA; LMCache stays `kv_both` on both
sides as a reuse tier, not the transport.

---

## 2. Current state

18 commits on `main`, which is the default branch and in sync with
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
scripts/bench/              llama-benchy harness + compare_runs.py
patches/spdk/               4 NVMe-KV patches (2 still required, see §5)
patches/lmcache/            NIXL backend allowlist patch, generated at apply time
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
  v0.5.4, validated only against a mock. `apply-patches.sh` fails loudly if it
  finds zero allowlist sites, because that means the assumption is stale.
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

> **Before anything below: check `uptime` on `smc2`.** It rebooted five
> times on 2026-09-15 and spent the end of that session cycling every
> eight to ten minutes — shorter than the five or six minutes a 72B TP=8
> load needs. §12.8 and TODO 6.20. Also check who owns the KV target on
> `smc3` before relying on it (§12.5, TODO 6.18). Both of these will
> otherwise present as a failure in whatever you were actually testing.

### The one live item — read this first, nothing else in §6 is more urgent

Everything that used to gate §6 (deployment model, kernel/CSI-1, KV backend
choice, and as of the fourth session leg A itself) is now decided, resolved,
or proven — see §6/§10/§11 above. **Exactly one actionable item remains:**

- **[TODO 6.10](TODO.md#6-storage-tier-integration-plan-xnvme_kv--spdk_nvme_kv-as-an-lmcache-tier) —
  compose the storage tier under P/D.** `MultiConnector[NixlConnector,
  LMCacheMPConnector]` with LMCache's `nixl_backend = XNVME_KV` and
  `dev_uri` from `resolve_xnvme_kv_dev()`. New integration — prove both legs
  independently, with a cross-instance or post-eviction reuse number so
  vLLM's own prefix cache can't fake the result (§8).

  The leg-A half of that proof is now available as a known-good baseline
  rather than a hope: bring the pair up with
  `scripts/common/start-vllm-container.sh {prefill,decode}`, front it with
  `scripts/proxy/disagg_proxy.py`, and confirm decode's `Avg prompt
  throughput` sits at 0.0 with `External prefix cache hit rate` at 100%
  BEFORE adding LMCache. If composing the tier breaks that, you know
  which change did it.

Everything else in TODO §6 is done or explicitly parked behind it —
see each item's status there.

**One standing warning, earned twice now (§11):** on this stack a correct
completion is not evidence of anything. Both defects that hid leg A
produced perfect output at plausible latency. Read the two engine
throughput counters, or you have measured nothing.

### The per-boot ritual — none of this survives a reboot

Confirmed again this session (both after the amdgpu recurrence and after
the OS upgrade): **none** of the following persist across a reboot of
either compute node or the target, and all three are prerequisites before
resuming either live item above:

1. `modprobe amdgpu` on both compute nodes (`modprobe.blacklist=amdgpu` is
   still on the 24.04 cmdline; `01-host-prep.sh` does this automatically,
   opt-out `AMDGPU_AUTOLOAD=0` — TODO 0.4).
2. Restart the KV target from `/root/kv_spdk` (it does not survive a
   reboot either — this session had to redo it).
3. Re-run `nvme connect` on both compute nodes (no `--persistent` flag, no
   systemd unit — TODO 6.9).

### Standing resume steps (unchanged in substance since first hardware contact)

1. `scripts/common/deploy.sh` to push the repo (and creds) onto each node —
   none of the three has a shared filesystem, NFS, or the repo already on it;
   this has to run before anything else can. SSH key auth is **not**
   configured on any node, so this and everything else currently depends on
   the passwords in `creds/active.env`; `deploy.sh` pushes those passwords to
   all three machines by default (TODO 2.12).
2. `scripts/common/init-creds.sh 4`, populate it, confirm
   `source config/cluster.env` resolves real addresses. *(Done as of
   2026-09-14 — TODO 2.1.)*
3. Work [TODO.md §2](TODO.md) — hardware bring-up. The architecture correction
   (§1) is complete; the GPU blocker is resolved (TODO 0.4, both nodes up via
   `modprobe amdgpu`, redone automatically by host-prep every run); the P→D
   **RDMA** fabric still has no route (TODO 3.6) but this is a Phase 2/3
   acceptance concern, not what's blocking the two live items above, which
   run on TCP over the shared management `/24`.
4. Follow [BRINGUP.md](BRINGUP.md).
5. For the storage tier specifically, §6.1–6.3's decisions are now made
   (container path, XNVME_KV, kernel `nvme-of`) — go straight to 6.11 then
   6.10, per the section above.

The first things likely to bite, in order: the LMCache allowlist patch
against whatever version actually installs (2.7, folded into 6.10); and
reconciling XNVME_KV's real 32768-byte value ceiling against the config
(6.4/6.13, also folded into 6.10). The amdgpu blacklist and the P→D RDMA
route are both known, both still require the same manual steps as before —
see the per-boot ritual and TODO 3.6 respectively. The container-image
`rixl` gap and the KV-transfer gap that sat here in previous sessions are
both closed — §11.

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

### 12.1 `LMCacheMPConnector` cannot carry the KV tier at all — correct the architecture

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

**The correct child is `LMCacheConnectorV1`** — in-process, no daemon, and
the only connector that reaches `nixl_storage_backend.py`. Verified
end-to-end through `vllm_v1_adapter.py:498` → `lmcache_get_or_create_config()`
→ `VllmServiceFactory` → `LMCacheEngineBuilder` → `StorageManager` →
`CreateStorageBackends`.

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
must be first on the decode side.**

### 12.2 The LMCache allowlist patch is not needed on the container path

TODO 2.7 and `patches/lmcache/` exist to widen an LMCache backend
allowlist. **The vendored LMCache 0.5.3 in the `rocm-aic` image does not
need it.** `XNVME_KV` and `SPDK_NVMe_KV` appear in all three hardcoded
backend tuples — `nixl_storage_backend.py:126` (`validate_nixl_backend`),
`:670` (mem_type selection, which correctly routes them to `OBJ` not
`FILE`), and `:1119` (`createPool`). The repo's patch marker string
appears nowhere in the installed tree. This is an AMD/ROCm vendor build
that ships the support natively. The patch remains correct for the
from-source path and has not been removed; its comment in
`gen-lmcache-config.sh` has been corrected to stop claiming it is
mandatory.

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
| **RC QP** create + data (`ibv_rc_pingpong`, GID idx 1) | **WORKS** — 6.8 Gbit/s, 9.6 µs/iter (`smc1`); 5.9 Gbit/s, 11.1 µs (`smc2`) |
| **UD QP** create (`ibv_ud_pingpong`) | **FAILS** — `Couldn't create QP` |
| **`rdma_cm`** connect (`rping`) | **FAILS** — `rdma_connect: Invalid argument` |
| GSI/MAD QP1 (a UD QP) | **FAILS** — `CREATE_QP BAD_ATTR` |

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
