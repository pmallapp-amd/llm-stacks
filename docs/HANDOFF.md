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

**The new top blocker, this session: the container image on `smc1` cannot
run P/D at all.** vLLM on ROCm imports the `rixl` package, not `nixl`
(`vllm/distributed/nixl_utils.py`); the image used to launch P/D
(`rocm-aic:latest`) has `nixl` but not `rixl`, so both engines died on
startup. The two images that do have `rixl`
(`kv-mppd`/`kv-mppd-assertfix`) exist only on `smc2` — moving one to `smc1`
is now the single next action. Full detail and the launch parameters
already worked out at **TODO 6.11**; composing the now-proven storage tier
underneath that P/D deployment is **TODO 6.10**. These are the only two
live items in TODO §6 — see §9 below.

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
- **The `kv_transfer_params` field name question is settled: there isn't
  one.** Measured 2026-09-15 against vLLM's actual vendored
  `disagg_proxy_demo.py`: the proxy sends the request to prefill with
  `max_tokens=1`, then sends the original request to decode; KV moves
  out-of-band over the NixlConnector side channel. There is no
  `kv_transfer_params` in the body at all. `PD_HANDOFF_FIELD` is therefore
  **unused** on this proxy — not wrong, just moot. Proxy facts for next
  session: runs in the same image, `--network host`, args `--model
  --prefill HOST:PORT --decode HOST:PORT --port`, health endpoint
  `/status` (not `/health`), endpoint discovery is static CLI args. Lives
  at `/root/rixl-bench/bench/pd-disaggregation/disagg_proxy_demo.py`.
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

### The two live items — read this first, nothing else in §6 is more urgent

Everything that used to gate §6 (deployment model, kernel/CSI-1, KV backend
choice) is now decided, resolved, or proven — see §6/§10 above. **Exactly
two actionable items remain:**

- **(A) [TODO 6.11](TODO.md#6-storage-tier-integration-plan-xnvme_kv--spdk_nvme_kv-as-an-lmcache-tier) —
  get P/D + proxy actually serving.** Move a `rixl`-capable image
  (`kv-mppd-assertfix` or `kv-mppd`, currently only on `smc2`) onto `smc1`,
  relaunch prefill+decode with the parameters already worked out this
  session, confirm both answer `/health`, confirm the side channel binds
  the routable IP (`ss -ltn | grep 5600`), then start `disagg_proxy_demo.py`
  and confirm `/status` plus a completion through it.
- **(B) [TODO 6.10](TODO.md#6-storage-tier-integration-plan-xnvme_kv--spdk_nvme_kv-as-an-lmcache-tier) —
  compose the storage tier under P/D.** `MultiConnector[NixlConnector,
  LMCacheMPConnector]` with LMCache's `nixl_backend = XNVME_KV` and
  `dev_uri` from `resolve_xnvme_kv_dev()`. New integration — prove both legs
  independently, with a cross-instance or post-eviction reuse number so
  vLLM's own prefix cache can't fake the result (§8). Blocked by (A).

Everything else in TODO §6 is done or explicitly parked behind these two —
see each item's status there.

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

The first things likely to bite, in order: the container-image `rixl` gap
(6.11, above); the LMCache allowlist patch against whatever version actually
installs (2.7); and, once P/D is up, reconciling XNVME_KV's real 32768-byte
value ceiling against the config (6.4/6.13, folded into 6.10). The amdgpu
blacklist and the P→D RDMA route are both known, both still require the
same manual steps as before — see the per-boot ritual and TODO 3.6
respectively.

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
