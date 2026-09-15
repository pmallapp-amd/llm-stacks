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

One blocker from today is now **RESOLVED**; one remains and is now the top
blocker:

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

Also new this session (2026-09-15), not yet folded into a numbered blocker
above because each is an open decision rather than something broken: the
lab's actual working deployment is containerised, not built from source
(§10.1); a KV backend can only ever be an LMCache tier, never
`NixlConnector`'s transport (§1, §10.3); and the compute nodes' kernel
cannot yield a `/dev/ngXnY` device for a KV namespace at all (§10.4). See
TODO §6 for the plan this drives.

2. **The P→D fabric (leg A) has no route yet — now the top blocker.**
   `smc1`'s data-plane addresses are `30.1.N.1/24`; `smc2`'s are
   `30.2.N.1/24` — different `/24`s, differing in the second octet — and
   `smc1` has no route to `smc2` at all (falls back to the management
   default route). This also falsifies the `/31` point-to-point premise in
   `config/cluster.env` (§6); the `UCX_IB_ROCE_SUBNET_PREFIX_LEN=16`
   workaround would not bridge `30.1.x` to `30.2.x` either, since they differ
   inside the first 16 bits (TODO 3.6). Leg B (storage) is unaffected for
   bring-up — see the measurement caveat added to §8.

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
- **RDMA device presence** — 8 `ionic` RDMA devices on each compute node;
  target exposes `rocep100s0` + `rocep132s0`. Confirmed by `00-preflight.sh`.
- **`00-preflight.sh` on the target (SMC3)** — clean run, all 5 checks
  pass: 320 CPUs, 62 GiB RAM, no ROCm (expected), the two RDMA devices above,
  176.8 GiB free on `/opt`, kernel `6.8.0-38-generic`.
- **The KV target now genuinely runs and is verified**, 2026-09-15 — via the
  prebuilt `/root/kv_spdk`, not this repo's build (§5's correction):
  namespace `KvMalloc0`, subsystem `nqn.2024-01.io.nixl:kv0`, listener on
  the management IP port 4420, `max_io_qpairs_per_ctrlr: 512` confirmed (§7
  invariant 7 holds). Also measured: `max_io_size: 131072` (128 KiB), **not**
  the 16 MiB invariant 8 assumes — flagged, unresolved, see TODO 6.4.
- **Kernel `nvme connect` against the KV namespace, 2026-09-15**: controller
  attach succeeds (`/dev/nvme2`, correct `subsysnqn`, live state, "creating
  128 I/O queues", `nvme list-ns` reports `[0]:0x1`, admin passthru works),
  but **no namespace device node is created at all** — no
  `/dev/nvme2n1` block device and no `/dev/ng2n1` char device — because the
  kernel logs `unknown csi 1 for nsid 1` and has no fallback for a
  Key-Value-command-set namespace. Same result for the local Pensando DSC KV
  device (`nvme1`) — a kernel limitation, not a fabric one. Full detail and
  its consequence for the plugin's own assumption at §10.4.

### Assumed — reconcile on first contact with hardware

- **`plugins/xnvme-kv/xnvme_kv_backend.h:244-251`'s claim that a KV
  namespace always appears as `/dev/ngXnY` with no matching
  `/dev/nvmeXnY`, "Verified both ways on the Austin prefill node
  2026-09-10" — DISPROVEN on these hosts, 2026-09-15.** Measured: the
  kernel logs `unknown csi 1 for nsid 1` and creates **neither** device node
  for a KV namespace on `5.15.0-191-generic` (both compute nodes) — not the
  block device, and not the char device either. The plugin's own
  `discover_kv_device()` heuristic therefore finds nothing on these hosts.
  The 2026-09-10 verification must have run on a different kernel — the
  **target** node here runs `6.8.0-38-generic` while both **compute** nodes
  run `5.15.0-191-generic`. See §10.4. Remedy is the paused kernel-upgrade
  sub-plan at TODO 6.5–6.8, itself unverified to actually fix this.
- **LMCache YAML key names and the allowlist patch sites.** Derived against
  v0.5.4, validated only against a mock. `apply-patches.sh` fails loudly if it
  finds zero allowlist sites, because that means the assumption is stale.
- **The `kv_transfer_params` field name** the proxy threads from prefill to
  decode. Could not be confirmed against an installed vLLM; made configurable
  via `PD_HANDOFF_FIELD` rather than guessed silently.
- **The NIXL Python API surface** used by the verify scripts — partially
  grounded, partially inferred. Failures surface as `AttributeError`, not as
  silent passes.
- **All benchmark numbers** in `BENCHMARKING.md` are order-of-magnitude
  estimates, labelled as such.

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
   `modprobe amdgpu`, redone automatically by host-prep every run); the
   single biggest open blocker is now the P→D fabric having no route (TODO
   3.6).
4. Follow [BRINGUP.md](BRINGUP.md).
5. Before touching the storage tier specifically, read §10 below and
   [TODO.md §6](TODO.md#6-storage-tier-integration-plan-xnvme_kv--spdk_nvme_kv-as-an-lmcache-tier)
   in full, and make the 6.1/6.2/6.3 decisions (deployment model, SPDK build
   route, KV backend) before doing anything else in that section — none of
   §6's later items mean much until those are settled.

The first things likely to bite, in order: the P→D fabric having no route
(3.6); the LMCache allowlist patch against whatever version actually
installs; and the `kv_transfer_params` field name. (The amdgpu blacklist,
formerly first on this list, is resolved — TODO 0.4 — but remember it must be
redone after every reboot of either compute node, and this session confirmed
that recurrence in practice, not just in theory.)

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
from-source path, or supports both is an **open decision with tradeoffs, not
made here** — see TODO 6.1.

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
integration**, not reproduction of a proven setup. Planned as such at
TODO §6, with the unknowns named there.

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
