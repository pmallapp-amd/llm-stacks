# Handoff

State of the P/D-disaggregated KV cache project, for whoever picks this up
next (including future me). Last updated 2026-09-18.

Read this before [BRINGUP.md](BRINGUP.md). It tells you what is real, what is
assumed, and what is still wrong.

> **Resuming? Go straight to [§3](#3-how-to-resume).** It carries the
> cluster state as handed over, the checks to run before touching anything,
> and what to do in what order. §§1–2 are background; §7 is the corrections
> record — read it when you need the *why*, not to get started.
>
> **Headline, 2026-09-18: the storage tier now serves a genuine cross-node
> L2 hit.** A replacement L2 adapter — **`nixl_kv`**, this repo's own,
> content-addressed — is written, unit-tested (44/44), registered inside
> the live daemon on both nodes, **proven cross-node byte-exact at the
> naming layer** (8/8 including three negative controls, §2), and now
> **proven at the engine level**: rung `60` step 5 — a genuinely cold
> decode node, writer's vLLM and daemon killed and removed, served content
> only prefill had ever computed — **PASSES**: `l2_device_hits=4`,
> `l2_index_hits=0`, `l2_probe_errors=0`, `l2_load_aborts=0`, and TOKEN
> IDENTITY matched the recompute baseline. 9 of 11 checks passed; the other
> 2 are step 7's negative control, which is **VOID BY CONSTRUCTION** (this
> run used `--no-drain`), not a fix failure.
>
> **The root cause (TODO 6.34) is FIXED and independently verified by
> direct device inspection.** It was an OBJ descriptor aliasing bug in the
> adapter's own store path: `register_obj_names()` built every OBJ
> descriptor at `addr=0`, distinguished only by `devId` restarting at the
> call's list position, so the live PAGE registration (`devId` 0..36863)
> and the COMMIT registration (`devId` 0..3) were indistinguishable for
> `devId` 0..3, and commit writes were submitted under the **page's**
> device key instead of their own. **Fix:** `devId` is now allocated from a
> daemon-global monotonic counter (disjoint by construction, across both
> within-call and cross-task overlap), and the page dlist is deregistered
> immediately after the page write is durable, before the commit
> registration is created. Both consequences are confirmed gone by reading
> the device directly: the commit object now exists (`<key>!c` HITs), and
> page `~0` reads back as real bf16 KV bytes, not commit-record JSON.
>
> Two older framings are corrected here. TODO 6.21's root cause was
> **incompletely stated** — per-daemon naming is the second of two
> independent blockers, and the more fundamental one is that discovery is a
> *missing operation*, not a wrong value (§2). And 6.21's "separate,
> still-open question" about prefill-only `retrieve_ops=0` is **answered and
> is not a bug** (§2). **What remains:** step 7's negative control needs a
> namespace drain to validate, and the drain itself is blocked — the target
> running `/dev/ng1n1`'s backing subsystem was not started by this repo's
> scripts, and replacing or reconfiguring it risks the DSC/DPU peering
> (§2, §3.3). TODO 6.15 (cross-instance reuse measurement) and 1.13
> (benchmark rework) are the natural next items now that the tier works.

---

## 1. What this project is

Three nodes, splitting vLLM inference so prefill and decode run on different
machines and share KV cache.

| Role | Hardware | Function |
|---|---|---|
| Prefill (`smc1`) | 8× MI300X `[1002:74a1]`, 10× DSC Ethernet Controller `[1dd8:1002]` | vLLM, KV producer |
| Decode (`smc2`) | 8× MI300X `[1002:74a1]`, 10× DSC Ethernet Controller `[1dd8:1002]` | vLLM, KV consumer |
| Target (`smc3`, hostname `volcano17`) | no GPU, 2× DSC Ethernet Controller `[1dd8:1002]` | SPDK NVMe-KV over NVMe-oF/TCP |

`smc3` is **shared with other parties** — it has been reconfigured under
this project more than once (§7.1). Do not assume its state survives
between sessions; re-check ownership before touching it.

Addresses and credentials are **not in this repo** — see §6. Known
addresses, for orientation: `smc1` (prefill) `10.30.75.198`, `smc2`
(decode) `10.30.75.204`, `smc3` (target, `volcano17`) `10.30.69.159`.

### The stack, as it actually runs today

- **vLLM 0.26.0+rocm**, **LMCache 0.5.3, MP mode only** (the in-process
  `LMCacheConnectorV1` path and its YAML config generator were removed —
  TODO 6.23; MP is the only composition this repo has ever run in
  practice, see §1.1).
- **NIXL `v1.4.1`**, **UCX `v1.19.x`** (`config/cluster.env`).
- Vendor container image **`rocm-aic:mp-pd-ionic2609`** — this is the
  deployment unit; there is no from-source build path in active use
  (§6.3).
- Model: **`Qwen/Qwen3-8B`, `TP_SIZE=1`** is what is actually deployed
  today (`creds/active.env`). **This is not what `config/cluster.env`'s
  own tracked default says** — that default is still
  `Qwen2.5-72B-Instruct` at TP=8 (145 GB of weights, not present on either
  compute node's disk), and it is a correct description of the tracked
  default, not of the running cluster. **Every latency/throughput number
  in this document predates the switch to Qwen3-8B/TP=1 and is not
  comparable to anything measured against it, in either direction.**
  Figures are labelled with which model produced them.
- `KV_BACKEND=XNVME_KV` is the canonical default (`config/cluster.env`).
  `SPDK_NVMe_KV` is kept fully wired, deliberately, as a comparison point —
  not deleted.
- Ports: prefill **8100**, decode **8200**, proxy **8000**, LMCache MP
  daemon **6557**, NIXL side channel **5600** (prefill) / **5601**
  (decode).

### One stack, two always-on KV paths — not two independent legs

An earlier phase plan treated the P→D handoff and the storage tier as
independently deployable "legs." They never were: this repo has composed
both, every time, since the composition was first decided. There is
exactly one shape the config generator can emit:

```
MultiConnector[NixlConnector, LMCacheMPConnector]
```

with **`NixlConnector` hardcoded as `connectors[0]`** — not a convention to
remember, an enforced order in `scripts/common/gen-kv-transfer-config.sh`.
The reason is mechanical, not stylistic:
`MultiConnector.get_num_new_matched_tokens` walks its children in list
order and assigns the **entire** load to the first child reporting a
non-zero match. If `LMCacheMPConnector` were listed first, any decode
request whose prefix is already in the local L2 tier would be satisfied by
LMCache before `NixlConnector` is even asked, silently skipping the direct
P→D remote-prefill pull this whole architecture exists to exercise.

| Path | Route | Transport | NICs |
|---|---|---|---|
| **P→D handoff** | prefill → decode, direct GPU-to-GPU via `NixlConnector`/UCX | TCP today, over the 1 GbE **management** NIC (`ens51f0` on both nodes) → RDMA is the acceptance target, not yet delivered (§7.4–§7.6) | DSC Ethernet Controller `[1dd8:1002]` (10/node, `ionic` driver) for RDMA; management NIC for TCP |
| **Storage tier** | both compute nodes → `LMCacheMPConnector` → the MP daemon → its `nixl_store` L2 adapter → `KV_BACKEND` → `smc3`'s KV namespace | TCP, permanently by design | Same `[1dd8:1002]` ID on the target |

**Why a KV storage backend can never be `NixlConnector`'s own transport:**
`NixlConnector`'s handshake (`getLocalMD()`) requires RDMA-style
addressable memory. Storage/KV backends — `SPDK_NVMe_KV` and `XNVME_KV`
alike — return `NIXL_ERR_INVALID_PARAM` there (verified against the
vendor's own `11-deploy-qwen-nixl-xnvme.sh`). A KV backend can therefore
only ever be reached as an **LMCache storage tier underneath**
`NixlConnector`, never as the P/D transport itself. That is exactly what
the composition above does, and it is the only shape this repo's
generator can produce.

### 1.1 How the storage tier actually attaches — the daemon, not a YAML

`LMCacheMPConnector`'s vLLM-side config carries only two rendezvous keys,
`lmcache.mp.host`/`lmcache.mp.port` (default port 6557, loopback host — the
daemon and vLLM are two processes on the same host, sharing IPC namespace,
because `MemoryObjMetadata.address` is a raw pointer that only survives the
ZMQ crossing within one host's address space). **The backend itself —
which KV_BACKEND, its `dev_uri`/`trid`, its pool size — is configured
entirely on the separately-launched MP daemon**, via a repeatable
`--l2-adapter '<JSON>'` flag:

```
{"type":"nixl_store","backend":"XNVME_KV","backend_params":{"dev_uri":"..."}
,"pool_size":2000000}
```

`scripts/common/start-lmcache-daemon.sh` builds and validates this spec
(`25-validate-lmcache-config.sh --l2-adapter-json`) before ever spawning the
daemon, and is called automatically, idempotently, by
`scripts/{prefill,decode}/03-start-*.sh` before `start-vllm.sh`, which in
turn hard-gates on the daemon's ZMQ port being reachable. There is no YAML
in this path at all — `gen-lmcache-config.sh` and the `LMCACHE_CONFIG_FILE`
env var it produced were deleted once it was confirmed dead code (TODO
6.23); nothing on the live path reads them. See §7.7 for why this took two
corrections to land on.

`pool_size` counts fixed-size pool slots (`--l1-align-bytes`, 4096 B
default) — it is **required, validated as `>0`**, and selects a
pre-allocated-slot backend, not a content-addressed one (§4, invariant 1).
Default **2,000,000**, chosen because the vendor's own testing found an
L1-capacity-matched value spins at 100% CPU with zero progress for over
ten minutes, while 2,000,000 comes up in about 90 s — it is not a capacity
calculation and should not be "fixed" toward one.

---

## 2. Current state

Measured directly on `smc1`/`smc2`/`smc3`, 2026-09-17/18. This section states
what is true **now** — for how we got here, see §7.

### 2.0 TODO 6.21, restated correctly — there were always TWO blockers

This supersedes the previous framing, which named only the second one and
was repeatedly read as a general impossibility claim.

**Blocker 1 — discovery is a MISSING VERB (the fundamental one).**
`NixlStoreL2Adapter._execute_lookup_in_the_loop()` consults **only** the
in-process `_memory_objects` dict. A daemon never asks the shared medium
about a key it did not itself store, so every cross-daemon lookup misses
*before naming is ever consulted*. You cannot patch a name into existence.
This is why restoring the plugin's `queryMem()` override was correct and
**changed nothing**: the verb existed at the plugin layer and the adapter
above it still never called it.

**Blocker 2 — names are pool slots, not content.**
`init_storage_handlers_object()` pre-registers `pool_size` names as
`obj_{i}_{uuid4().hex[:4]}` at startup; the function never sees a content
key.

Neither fix alone changes the outcome. `start-lmcache-daemon.sh`'s claim
that "no amount of index-keeping, existence-probing or plugin work can
bridge that" is true **only of the current naming**, not in general.

**The "separate, still-open question" is answered and is NOT a bug.**
Prefill-only `retrieve_ops=0` has a benign cause: L1 never evicts, so L2 is
never read back. Measured directly in the daemon log —
`Prefetch request completed (L1+L2): 4/4 retained keys (4 L1, 0 L2)`.
**Consequence for anyone measuring:** a *correct* implementation will also
show `retrieve_ops≈0` on a warm same-daemon path. Only a cold reader proves
anything.

### 2.1 What runs is the IMAGE PLUS THREE OVERLAYS — not the image

Verified 2026-09-17: `rocm-aic:mp-pd-ionic2609` is **vanilla** (every layer
is `docker build`/buildkit, no `docker commit`; a **fresh container with no
mounts** shows the same patch state as a running one). But
`scripts/common/container.sh` bind-mounts three files over it at run time,
and two of them are load-bearing:

| Overlay | Why it matters |
|---|---|
| `libplugin_XNVME_KV.so` (repo-built) | **The image's own plugin has NO `nixlXnvmeKvEngine::queryMem` override** — 1 weak base-class symbol vs. our 2. Existence probing, and therefore all L2 discovery, exists *only* because of this mount. |
| `lmcache_mp_connector.py` (patch `0011`) | Verified **absent** from the image. See §2.2. |
| `nixl_utils.py` | Image ships a ROCm-patched `nixl` and no `rixl`; upstream's hardcoded platform test rejects a working install. |
| `nixl_kv_l2_adapter.py` (new) | This repo's L2 adapter, dropped into the package dir; `pkgutil` auto-discovers it — **zero vendor files edited**. |

### 2.2 Patch `0011` was NEVER in the image, and its check gave a false pass

Measured 2026-09-17: line 1141 of the image's `lmcache_mp_connector.py`
reads the unpatched `condition = tracker.needs_retrieve()`. Its sibling
`0010` is absent too. The old re-verification recipe grepped
`num_external_tokens`, which matches the **unpatched function signature and
docstring**, so it passed either way — and `patches/lmcache/README.md`
asserted a result it had never actually measured.

This matters because this cluster runs
`MultiConnector[NixlConnector, LMCacheMPConnector]`, exactly the composition
`0011` guards: a non-chosen sub-connector creates a retrieve that must not
happen and **leaks lookup locks**. It is now applied by
`container.sh lmcache-patch` (derived from the image, five self-invalidation
guards, all exercised).

### What works

- **P→D direct NIXL transfer, against the currently-running model
  (Qwen3-8B/TP=1).** `scripts/verify/50-verify-pd-direct.sh`: **9/9
  passing**. External prefix cache hit rate rose 0.0% → 100.0%; decode's
  `Avg prompt throughput` held at **0.0 tokens/s** — decode does zero
  prefill work, which is the acceptance signal. Negative control (handoff
  deliberately withheld): 124.7 tokens/s, and the hit rate **falls**. This
  is not a transport benchmark — the P→D leg runs over the 1 GbE
  management NIC (`ens51f0`), not the RDMA fabric.
- `scripts/verify/40-verify-disagg.sh`: **9/9**.
- `scripts/verify/20-verify-nixl-plugin.sh`: **6/6 on both nodes**.
- **Cross-node storage-tier store+retrieve, proven directly, both
  directions**, on a clean namespace (`nuse: 0` beforehand), using
  `scripts/verify/30-verify-kv-roundtrip.sh` (keys derived from
  `(nonce, size)` via sha256 — the two sides never exchange the key
  directly, so a successful cross-node read is proof the namespace is
  shared, not proof the test leaked information):

  | direction | size | parts | result |
  |---|---|---|---|
  | `smc1` write → `smc2` read | 24,576 B | 6 | `RESULT:OK` |
  | `smc2` write → `smc1` read | 1,048,576 B | 256 | `RESULT:OK` |
  | `smc1` write → `smc2` read, production geometry | 196,608 B | 6 × 32768 | `RESULT:OK` |
  | negative control: never-written nonce | — | — | `RESULT:QUERY_MISS`, non-zero exit |

- **The `nixl_kv` adapter's naming scheme is PROVEN cross-node, byte-exact,
  both directions** — `scripts/verify/35-verify-nixl-kv-smoke.sh`, **8/8**,
  exercising the real grammar (`{ns}@{key}~{ordinal}` pages plus a
  `{ns}@{key}!c` commit object) with **three negative controls**: probe
  before write MISSes, an unwritten nonce MISSes, and a foreign namespace
  MISSes. Page content is per-ordinal, so a collapsed tile ordinal would
  fail loudly rather than silently. A page-count disagreement is rejected by
  the commit record (`COMMIT_INVALID`), never reassembled.
  **Coverage gap, found 2026-09-18, closed 2026-09-18 (TODO 6.29/6.34):**
  this rung writes its commit object through the raw NIXL agent path
  (`register_memory` + `initialize_xfer`), one name at a time, not the
  adapter's own commit-write path (`register_host_buffer` +
  `register_obj_names` + `make_transfer`) — it validates the naming
  SCHEME, and structurally still cannot hold two overlapping OBJ
  registrations, so it never exercised (and still doesn't exercise) the
  aliasing mechanism TODO 6.34 found. The gap is closed by six new offline
  tests in `test_nixl_kv_naming.py` (44/44) that construct that overlap
  directly — those tests, not this rung, are the regression guard for that
  bug class.
- **`nixl_kv` registers and initialises inside the live MP daemon on both
  nodes** — `container.sh adapter-check`, plus its counters exposed at
  the daemon's `http://127.0.0.1:8080/status`. Both nodes independently
  derive the same geometry fingerprint `ns=d9dbd20693b2`. **All ten
  counters — five outcome, five attempt — have now been observed on
  hardware, both pre- and post-fix** (TODO 6.28/6.34): pre-fix,
  `l2_lookup_calls=1`, `l2_lookup_executions=1`, `l2_keys_probed=4`,
  `l2_probe_misses=4`, `l2_device_hits=0`, proving lookup ran end to end
  and the device genuinely said absent; post-fix, the same sequence
  returns `l2_device_hits=4`, `l2_probe_misses=0` — see below.
- **The engine-level acceptance run (rung `60`) step 5 PASSES — a genuine
  cross-node L2 hit, on a cold reader.** A decode node with its container
  recreated (counters confirmed at zero) asked, with prefill's vLLM **and**
  daemon killed and removed (port confirmed unreachable), for a prompt
  only prefill had ever computed: `l2_device_hits=4`, `l2_index_hits=0`,
  `l2_probe_errors=0`, `l2_load_aborts=0`, and TOKEN IDENTITY matched the
  recompute baseline. Negative control A (unseen nonce) passed: no new
  device hits (4 → 4). 9 of 11 checks passed overall; the 2 failures are
  both step 7's negative control, VOID BY CONSTRUCTION because this run
  used `--no-drain` (see below, and TODO 6.34) — not a partial failure.
  Soundness: the run used a per-run nonce (`acc-<epoch>-<pid>`), so its
  chunk hashes and ObjectKeys are unique to it and no prior run's object
  could have satisfied it; negative control A independently confirms
  unseen content misses.
- **The KV namespace is confirmed SHARED across `smc1` and `smc2`**:
  `nvme ns-descs /dev/ng1n1` returns `csi: 0x1` and `eui64
  e46cfefeffcdae01`, **identical on both nodes**. The host is **not** the
  NVMe-oF initiator here — the DSC is. Each compute node's own Pensando
  DSC is itself an NVMe-oF initiator peered to `smc3`'s `nvmf_tgt`, and
  transparently re-exports `smc3`'s namespace as a local PCIe function.
  There is no "local, independent, unshareable" device here — `/dev/ng1n1`
  on `smc1` and on `smc2` are the same backing store, one hop apart.

### What does not work

- **Rung `60` step 7's negative control is unvalidated, and validating it
  is blocked.** This session's acceptance run used `--no-drain` (§3.2.2/6.18
  forbid draining the shared target unilaterally), so step 2's commit
  object was legitimately still on the device and step 7's "a drained
  namespace yields no device hit" control cannot hold under that
  condition — the script itself flags it as VOID, and it is not evidence
  against the fix (soundness for *this* run instead rests on the per-run
  nonce plus negative control A, both of which passed — see above).
  Validating it for real needs a namespace drain, and the drain is itself
  blocked: `scripts/target/50-reset-namespace.sh` refuses to run because
  the live `nvmf_tgt` backing `/dev/ng1n1` was not started by this repo's
  scripts (TODO 6.34's operational note, §3.3). This is the one open item
  the fix itself did not close.
- **The OLD adapter (`nixl_store`) never retrieves anything a live vLLM
  engine stored.** Measured on both roles: the live engines together store
  **36,864 objects** into the (now-proven-working) namespace and retrieve
  **zero** of them (`retrieve_ops=0` on both, `store=36,864`).
  **Cause, isolated beyond argument**: `nixl_store_l2_adapter.py` names
  every stored object `obj_{i}_{uuid.uuid4().hex[0:4]}`, with a fresh
  `uuid4` drawn independently by each daemon at startup. **This is not a
  naming typo** — these are **pre-registered pool-slot names**, built once
  by `init_storage_handlers_object(page_size, num_pages)` at daemon
  startup; the function never sees a content key at all. The
  content→slot-name map lives in an in-process dict inside each daemon and
  dies with it. Prefill and decode therefore can never agree on a name for
  identical content, **by construction**, regardless of what the
  underlying device or namespace is capable of — this is a targeted
  LMCache patch to make, not an open-ended investigation (TODO 6.21).
  Cross-node KV movement on this stack happens over the P→D `NixlConnector`
  handoff (above), which is the only mechanism this architecture has for
  it; the storage tier is a reuse tier, not a substitute transport.
  (The old "separate, still-open question" about prefill-only
  `retrieve_ops=0` that used to sit here is **answered and is not a bug** —
  L1 never evicts, so L2 is never read back. It is stated once, in §2.0;
  do not restore it here as open.)

### Measured hardware facts to carry forward

- **`max_value_size` ceiling is EXACTLY 32768**, on the DSC firmware
  running today. The device's own KV Identify Namespace **advertises
  4096** — it **understates its true ceiling by 8x**. Measured by storing
  a single value (`num_parts=1`) at each size with
  `NIXL_XNVME_KV_DEBUG=1`:

  | size | result |
  |---|---|
  | 32768 | `ok=1 sct=0 sc=0` — PASS, read back cross-node |
  | 33792 – 49152 | `ok=0 sct=7 sc=234` |
  | 65536 | `ok=0 sct=7 sc=234` — FAILS |
  | 131072 | `ok=0 sct=7 sc=234` — FAILS |

  `sct=7 sc=234` arrives as a **completion after a successful submit**
  (~70–85 µs) — device rejection, not a host or transport error.
  `KV_MAX_VALUE_SIZE_XNVME=32768` in `config/cluster.env`, matching this.
  The plugin logs a loud startup **WARNING** because 32768 exceeds the
  advertised 4096 — that warning is **expected and correct on this
  hardware**; do not silence it by lowering the value, and do not set
  `NIXL_KV_STRICT_DEVICE_CEILING=1` (§4).
- **The DSC DOES populate `cdw0` on Retrieve with the retrieved value's
  length** (`len=32768` → `cdw0=32768`, confirmed across a 6-part
  196,608 B cross-node read). The retrieve-length validation this repo
  added to guard against a silent short-read is therefore live on this
  hardware, not a no-op.
- **The DSC has a boot-time race** (§3.4). Both compute nodes rebooted
  three times during the 2026-09-17 session alone; `smc2` has previously
  shown 7 boots in one day. **Check `uptime` before planning anything that
  takes minutes.**
- **The P→D leg's transport is the 1 GbE management NIC** (`ens51f0`,
  both nodes) — RDMA acceptance is a separate, still-open workstream
  (§7.4–§7.6). No P→D number in this document is a transport benchmark.
- **Side-channel bind addresses are pinned in creds**:
  `PD_SIDE_CHANNEL_HOST_PREFILL=10.30.75.198`,
  `PD_SIDE_CHANNEL_HOST_DECODE=30.2.1.1`. Unpinned, `lib.sh` falls back to
  `hostname -I | awk '{print $1}'` — the **first** IP — and `smc2`
  enumerates fabric NICs before its management NIC, so an unpinned decode
  binds a fabric address silently. This is asymmetric by IP class (prefill
  ends up on management, decode on fabric) and nothing has broken because
  of it yet, but resolve it to one class before trusting it under a
  topology change.
- **What runs is the image PLUS three read-only bind-mount overlays, not
  the image alone.** `scripts/common/container.sh` mounts: the repo-built
  `libplugin_XNVME_KV.so` (**the image's own copy has no
  `nixlXnvmeKvEngine::queryMem` override** — existence probes, and therefore
  any L2 discovery, exist only because of this mount), a patched vLLM
  `nixl_utils.py` (the image ships a ROCm-patched `nixl` and no `rixl`, so
  upstream's hardcoded platform test rejects a working install), and a
  patched LMCache `lmcache_mp_connector.py` (patch `0011`, see below). The
  image itself is **vanilla** — verified 2026-09-17 by `docker history`
  (every layer is `docker build`/buildkit, no `docker commit`) and by
  re-running the patch check in a **fresh container with no mounts**.
- **LMCache in the vendor image is patched at build time, not by
  anything in this repo.** `0006`–`0009` were extracted from a sibling
  build repo, verified applied in the running image, and (policy change,
  2026-09-17) their `.patch` files were then **deleted** from
  `patches/lmcache/` — if the image ships it, this repo no longer carries
  the diff. `0006` widens the NIXL-backend allowlist to include
  `XNVME_KV`/`SPDK_NVMe_KV`; `0007` is the **origin** of `mem_split_n`/
  `_resolve_mem_split()` and the `#{j}` multipart-suffix scheme — this is
  not upstream LMCache. `patches/lmcache/` now carries exactly one diff,
  `0011`, precisely because it is verified **absent** from the image and
  this cluster's `MultiConnector[NixlConnector, LMCacheMPConnector]`
  composition needs its guard. It is applied at run time by
  `scripts/common/container.sh lmcache-patch`, which derives the override
  from the image's own copy and bind-mounts it read-only — the same
  mechanism already used for vLLM's `nixl_utils.py` and the repo-built
  `libplugin_XNVME_KV.so`. **The running stack is therefore image + three
  overlays, not the image alone** (§2). **Do not repeat the retracted claim that the
  vendor image accepts these backends unpatched** (§7.8) — it does not;
  it ships prebuilt with `0006`–`0009` already in place. See
  `patches/lmcache/README.md` for the per-patch table, checksums, and
  re-verification recipe.

---

## 3. How to resume

If you read nothing else in this document, read this section.

### 3.1 Cluster state as handed over

Measured, not assumed, at the end of the 2026-09-17 session — re-measure
before trusting any of it (§3.5):

| Node | State |
|---|---|
| `smc1` prefill | Rebooted during the session; GPUs and `/dev/ng1n1` require the per-boot ritual below before anything will start. |
| `smc2` decode | Same. Has a documented history of reboot instability (§3.2). |
| `smc3` target | Shared with another party. Confirm the subsystem `nqn.2024-01.io.nixl:kv0` / namespace this repo expects still exists before assuming it is available (§3.2). |

Nothing of this project's is left running deliberately at the end of a
session — containers carry no `--restart` policy.

### 3.2 Check these things before touching anything

Each of these has cost a run already, and each presents as a failure in
whatever you were actually testing rather than as itself.

1. **`uptime` on both compute nodes.** `smc2` has shown 7 reboots in one
   day, cycling every 3–13 minutes — shorter than a model load takes. Both
   nodes rebooted 3 times during the 2026-09-17 session. If a node has
   been up less than the time your step needs, you will lose the run and
   the failure will look like something else (TODO 6.20).
2. **Who owns `smc3` right now, and whether our subsystem still exists on
   it.** It is shared and has been reconfigured out from under this
   project before. Do not restart another party's target to reclaim it —
   agree ownership first (TODO 6.18).
3. **`modprobe amdgpu` on both compute nodes.** `modprobe.blacklist=amdgpu`
   is on the kernel cmdline on both nodes and suppresses **autoload
   only** — it does not block an explicit `modprobe amdgpu` by name, and
   there is no reboot required, but every boot needs this run again.
   `01-host-prep.sh` does it automatically (opt-out `AMDGPU_AUTOLOAD=0`).
4. **`/dev/ng1n1` exists on both compute nodes before starting anything.**
   See the boot-time race at §3.4 — a missing device after a reboot is not
   necessarily a dead card.
5. **Whether the LMCache MP daemon is already up before running
   `start-vllm.sh` (or a role script) by hand.** It is idempotent and the
   role scripts start it automatically, but `start-vllm.sh`'s own gate
   will `die` with a pointer back to `start-lmcache-daemon.sh` if it is
   not reachable — read that message before assuming vLLM itself is
   broken.

### 3.3 What to do, in order

**Step 0 — bring up the one stack, on both nodes.** There is no
"compute-first, storage-tier later" sequence — the MP daemon and its
`nixl_kv` L2 adapter are what "starting this stack" means now
(`nixl_store` is kept byte-identical only as the A/B control, TODO 6.21):

```
scripts/common/start-lmcache-daemon.sh     # on smc1 AND smc2 — idempotent
scripts/prefill/03-start-prefill.sh        # on smc1 — starts the daemon
itself first if needed
scripts/decode/03-start-decode.sh          # on smc2 — same
scripts/proxy/start-proxy.sh               # fronting both
```

Send one long (≥1000-token) prompt with a per-run nonce through the proxy
and confirm **decode's `Avg prompt throughput` is 0.0 with `External
prefix cache hit rate` rising toward 100%**, while prefill's throughput is
non-zero. That is the §2 P→D result — it proves the P→D handoff, **not**
the storage tier: a healthy daemon and a working `--l2-adapter` spec are
required for vLLM to start at all now, but starting is not the same as
the tier serving a hit.

**Step 1 — TODO 6.34 is fixed and verified; pick up the drain decision,
then 6.15/1.13.** The blocker rung `60` step 5 diagnosed is cleared:
`register_obj_names()` now allocates `devId` from a daemon-global
monotonic counter and the page dlist is deregistered before the commit
registration is created, so the page and commit OBJ registrations can no
longer alias. Rung `60` step 5 **PASSES** on the fix — a genuinely cold
decode node served content only prefill had computed
(`l2_device_hits=4`, token identity matched) — and both consequences of
the old bug (missing commit object, page-0 corruption) are independently
confirmed gone by direct device inspection. Do **not** re-run rung `60`'s
step 5 expecting new information from it — this is closed.

**What's next, in order:**

1. **Decide how to drain the namespace**, so rung `60` step 7's negative
   control (currently VOID BY CONSTRUCTION under `--no-drain`) can be
   validated for real. `50-reset-namespace.sh` refuses to run because the
   live `nvmf_tgt` backing `/dev/ng1n1` was not started by this repo's
   scripts (TODO 6.34's operational note) — draining means either
   replacing that target with this repo's own (`03-start-kv-target.sh`) or
   an RPC-level bdev recreate against the one already running, and both
   risk the DSC/DPU peering that currently makes `/dev/ng1n1` work (DSC
   recovery is non-deterministic and slow, TODO 6.26). This decision, not
   more adapter work, is what's blocking step 7.
2. **TODO 6.15** — cross-instance reuse measurement, now that the composed
   path genuinely serves a hit — and **TODO 1.13** (benchmark rework), so
   6.15's number means something. Both are natural next work now that the
   tier works, not blocked on the adapter anymore.

**Ordering, and why it matters, for the record:** the ladder ran bottom-up
this session and stopped correctly at the first red, before the fix
landed. `20` (plugin) → `30` (device/namespace roundtrip) → `35`
(**nixl_kv naming, cross-node** — green, 8/8) → `50` (P→D direct) → `60`
(**L2 cross-node acceptance** — 10/11 pre-fix, the one red assertion
diagnosed as TODO 6.34; 9/11 post-fix, the remaining 2 being step 7's void
control). `35` green and `60` red correctly pointed at the LMCache→adapter
seam per this section's own logic — the counters then narrowed that seam
to the STORE side, not the LOOKUP side originally suspected. **`35`'s 8/8
covered the naming SCHEME only, not the adapter's own commit-write
MECHANISM** — the gap is now closed by offline regression tests, not by
`35` itself (see §2's rung-35 entry).

**Separately, and not blocking any of the above — RDMA acceptance.** This
is a transport upgrade for the P→D path, independent work from the
storage tier. The routing gap between the two nodes' fabric subnets is
closed and RC queue pairs move real cross-node traffic (§7.6), but **UD
queue-pair creation fails on this driver/firmware**, which breaks
`rdma_cm` and the GSI/MAD QP — `UCX_TLS=ib` pulls in UD transports, so the
transport spec needs narrowing to RC explicitly without weakening
invariant 6's exclusion of `tcp`. This is the sole remaining RDMA-stack
blocker (TODO 3.9) — see §7.5–§7.6 for the history.

### 3.4 The per-boot ritual — none of this survives a reboot

1. **`modprobe amdgpu`** on both compute nodes (§3.2.3). `01-host-prep.sh`
   does this automatically.
2. **Confirm `/dev/ng1n1` exists before starting anything on that node.**
   The DSC NVMe controller has a boot-time race: the kernel probes it
   (PCIe `0000:36:00.0`) roughly 3 seconds after PCIe enumeration —
   before the DPU-side application is ready — and gets
   `Device not ready; aborting initialisation, CSTS=0x0`. The driver
   detaches and **nothing re-probes it**. Distinguish this from a dead
   card: the DSC's *other* PCI functions (`pds_core`, `ionic`) bind and
   work fine on the same boot, config-space reads succeed
   (`setpci -s 36:00.0 00.L` → `10051dd8`), and the PCIe link itself is
   healthy — a `CSTS=0x0` alongside all of that means the DPU-side
   NVMe/KV application simply is not serving yet, not that the card, slot,
   or link is bad. Recovery, **validated repeatedly, on both nodes, with
   no reboot**, once the DPU side is confirmed up:
   ```
   echo -n "0000:36:00.0" > /sys/bus/pci/drivers/nvme/bind
   ```
   Takes roughly 2 minutes to resolve either way; if the DPU side is not
   yet ready it fails with the identical `CSTS=0x0` signature, and you
   simply retry once it is. Success looks like
   `nvme nvme1: 63/0/0 default/read/poll queues` followed by
   `block device for nsid 1 not supported (csi 1)` — **the second line is
   EXPECTED, not an error**: `csi 1` is the KV command set, which has no
   block-device semantics, hence the char-only `/dev/ng1n1` with no
   `/dev/nvme1n1` beside it. **Per the hardware owner, this race is
   expected behaviour on this hardware, not a defect** — treat it as a
   documented procedure, not an open bug. `start-vllm.sh` hard-gates on
   `/dev/ng1n1` by design, but a manual roundtrip run or verify-script
   invocation ahead of that gate will not, and will instead report a
   confusing device-open failure.
3. **The KV target.** Does not survive a reboot of `smc3`, and as handed
   over the more common problem is that another party's subsystem is on
   it — resolve ownership (§3.2.2) before assuming this step is yours to
   perform.
4. **`nvme connect`** on both compute nodes — no `--persistent`, no
   systemd unit (TODO 6.9). Moot until (3) is resolved.
5. **Start the LMCache MP daemon on both nodes** —
   idempotent, and the role start scripts call it automatically, but it
   does not survive a reboot and `start-vllm.sh`'s gate will `die`, not
   silently proceed, if it is not up.

### 3.5 The hardware is shared, and it changes under you

This is the single most important thing a new session needs to
internalise — it has invalidated recorded facts on this cluster more than
half a dozen times over the project's life (§7.1, §7.5–§7.6):

- The KV target has been reconfigured by another party mid-session more
  than once.
- The DSC driver/firmware bundle was replaced between sessions without
  notice, fixing (and later not fixing) different halves of what looked
  like one blocker.
- Physical links have come up and gone down between sessions.
- Both compute nodes have rebooted unprompted, repeatedly, for reasons
  never fully explained (TODO 6.20).

**Re-measure; do not trust a recorded measurement of driver, device, or
library state.** Prefer a check that fails loudly over a note in a
document. Facts about hardware identity, plugin source, and upstream
review status are the exception — those don't drift.

### 3.6 Standing setup, if starting from a fresh checkout

1. `scripts/common/init-creds.sh 4`, populate it, confirm
   `source config/cluster.env` resolves real addresses.
2. `scripts/common/deploy.sh` to push the repo and creds onto each node.
   No node has a shared filesystem, and SSH key auth is **not**
   configured anywhere — everything depends on the passwords in
   `creds/active.env`, which `deploy.sh` pushes to all three machines by
   default (TODO 2.12).
3. Then §3.3 above. [BRINGUP.md](BRINGUP.md) is the long-form guide, but
   note it predates the container-path decision and partly describes a
   from-source build this repo no longer runs (§6.3).

---

## 4. Invariants — do not break these

Each guards a **silent** failure: the cluster looks healthy while doing
the wrong thing. This is why several scripts refuse to start rather than
warn.

1. **A repeatable `--l2-adapter` `pool_size` must be set, and must be
   `>0`.** It selects a pool of **pre-allocated, fixed-size slots** — the
   objects are named `obj_{slot}_{uuid4}`, where the `uuid4` identifies
   the *daemon process*, not the content. This is not a content-addressed
   backend, and there is no `pool_size=0` mode any more: the in-process
   content-derived-key path (`LMCacheConnectorV1`'s
   `NixlDynamicStorageBackend`) was removed from this repo's live code
   path entirely (TODO 6.23) once it was confirmed dead — `LMCacheMPConnector`
   is the only connector this repo runs, and its `nixl_store_l2_adapter.py`
   only ever builds the static, slot-based backend. This same
   per-daemon-`uuid4` naming is also why cross-node LMCache retrieve does
   not work today (§2) — not a config mistake to fix by finding a
   `pool_size=0` mode, there isn't one.

2. **The `ldd` self-containment check** on `libplugin_SPDK_NVMe_KV.so`. A
   `DT_NEEDED` on `librte_eal.so` or `libspdk_*.so` makes NIXL's
   `dlopen()` fail *silently* and report only "unsupported backend." This
   is why SPDK is built `--without-shared` and `meson.build` links
   explicit `.a` paths.

3. **`PYTORCH_HIP_ALLOC_CONF=expandable_segments:False`.** Otherwise
   vLLM's KV tensors cannot be exported over HIP IPC and registration
   fails.

4. **Geometry (`max_value_size`) comes from CONFIG, not from the device,
   and the device is a validator, not the authority.** The old model —
   `NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` opting into the device-reported
   ceiling — is **gone**; that variable no longer exists in the plugin.
   The current model: `KV_MAX_VALUE_SIZE_EFFECTIVE` (`config/cluster.env`,
   backend-aware) is exported as `NIXL_KV_MAX_VALUE_SIZE`, and
   `xnvme_kv_configured_max_value_size()` is the single value both
   `getParams()` and the create-time device check read — they cannot
   disagree by construction, which the old, call-order-dependent opt-in
   flag could. If the configured value exceeds what the device's KV
   Identify Namespace reports, the plugin logs a loud **WARNING** and
   proceeds — **on this hardware, that warning is expected and correct**:
   the device's advertised ceiling (4096) has been measured to
   understate its true, working ceiling (32768) by 8x (§2). The warning
   is promotable to a hard failure with `NIXL_KV_STRICT_DEVICE_CEILING=1`
   — **do not set that here**; it would refuse to start on exactly the
   configuration measured working. Whenever `max_value_size` changes,
   drain the namespace (invariant 5) — nothing records the `sub_size` an
   object was written with, so a reader can reassemble a half-stale page
   from sub-keys written under a different split without error.

5. **Drain the namespace whenever `KV_MAX_VALUE_SIZE_EFFECTIVE` (or
   `--l1-align-bytes`) changes** — `scripts/target/50-reset-namespace.sh`.
   Same root cause as (4).

6. **`UCX_TLS` must include `rocm` and must not include `tcp`.** Without
   `rocm`, UCX loads no ROCm memory domain, reports VRAM as host, and NIXL
   refuses registration with an error blaming a missing ROCm build —
   misleading, because the build has ROCm and `UCX_TLS` configured it
   out. Without excluding `tcp`, RDMA acceptance can pass on a silent TCP
   fallback. Current value: `ib,rocm,self,sm` — **`ib` also pulls in
   UD-based transports, which fail on this hardware** (§3.3, §7.5); narrow
   to RC explicitly when doing RDMA-acceptance work, but do not simply
   drop the exclusion of `tcp` to make it pass (TODO 3.9).

7. **`max_io_qpairs_per_ctrlr = 512`, spelled exactly that way.** SPDK
   silently ignores the older `max_qpairs_per_ctrlr` spelling, leaving the
   default 127. One plugin instance opens all available qpairs on its
   controller, so against a shared target the first role to connect takes
   the whole budget and the second is refused — surfacing as `CQ transport
   error -6` and `NIXL_ERR_BACKEND` while LMCache logs a successful store
   and HTTP returns 200, with **zero bytes reaching the device**.

8. **The chunk-size ceiling.** `LMCACHE_CHUNK_SIZE` (tokens) times the
   model's per-rank KV geometry must fit within `NVMF_MAX_IO_SIZE`:
   `layers × chunk × (kv_heads/TP) × head_dim × 2 × 2` bytes per rank,
   checked by `scripts/target/05-check-chunk-ceiling.sh` against
   `NVMF_MAX_IO_SIZE` (16 MiB by default in `config/cluster.env` — note
   the target has been measured actually advertising a much smaller
   `max_io_size`, 128 KiB, at the transport layer; this is a standing,
   unresolved discrepancy, not yet reconciled, see TODO 6.4). Exceeding
   the transfer-size ceiling fails the store with `NIXL_ERR_BACKEND` and
   can take the server down rather than degrading. **`LMCACHE_CHUNK_SIZE`
   is part of the cache key, so both roles must use the same value** or
   the receiver silently re-prefills. Re-run the check whenever `MODEL`,
   `TP_SIZE`, or `LMCACHE_CHUNK_SIZE` change.

9. **`LMCACHE_MAX_LOCAL_CPU_SIZE` (L1 pinned host memory) is PER TP
   WORKER, not per node.** At TP=8 a value of 80 (GiB) asks for 640 GiB of
   pinned (`hipHostMalloc`) memory — this has taken a node down before
   (every prefill worker failing `hipHostMalloc failed: 2`, and the peer
   node stopping SSH and rebooting mid-configuration). A value in the
   single digits per worker is ample for a correctness proof.

10. **Never point `AIC_XNVME_DEV` (or the resolved KV device) at
    `/dev/ng0n1` on `smc1`/`smc2`.** `/dev/ng0n1` is the **OS boot drive**
    (`Micron_7450_MTFDKBA800TFS`, 800 GB, carrying the boot partitions).
    The actual Pensando DSC KV device is `/dev/ng1n1`. The KV device must
    also be resolved by **subsystem NQN, not by path** —
    `resolve_xnvme_kv_dev()` does this — because the kernel numbers
    controllers in attach order, so the correct device can be
    `/dev/ng1n1` on one node and `/dev/ng2n1` on the other, and a node can
    have more than one KV-capable controller present.

11. **Startup preconditions in `start-vllm.sh`** — target reachable,
    LMCache MP daemon reachable, side channel not loopback, RDMA access
    confirmed in RDMA mode. Without them vLLM serves from local cache only
    and disaggregation does nothing while appearing correct.

---

## 5. Traps that have actually bitten, distilled

Not hypothetical — each cost real time on this project.

| Trap | Detail |
|---|---|
| A correct completion proves **nothing**. | Two separate defects have produced perfect output at plausible latency while transferring zero KV. Read the two engines' throughput counters, not the response text or the HTTP status. |
| `UCX_NET_DEVICES` unset makes UCX advertise the first TCP device it enumerates — an unroutable fabric NIC. | `<auto>` was never a safe default; it was the bug. Pin `PREFILL_PD_IF`/`DECODE_PD_IF` explicitly. |
| `LMCACHE_MAX_LOCAL_CPU_SIZE` is **per TP worker**. | At TP=8, a value of 80 means 640 GiB of pinned memory. It took a node down (invariant 9). |
| `LMCacheMPConnector` silently ignores `enable_nixl_storage`/`nixl_backend`/`nixl_backend_params`. | Not rejected — ignored. Those keys belong to the (now-deleted) in-process config surface; the live one is the daemon's `--l2-adapter` JSON (§1.1). Reading "the ignored keys are the wrong surface" as "the connector is incapable" was a real, documented mistake — before concluding a component can't do something, confirm you've found *every* config surface it exposes, not just the one you expected it to use. |
| A YAML emitting the "right" keys is not proof the tier is configured. | The deleted `gen-lmcache-config.sh` emitted `enable_nixl_storage`/`nixl_backend`/`nixl_backend_params` — a config surface that only ever mattered for the in-process `LMCacheConnectorV1` path this repo has never run in production. Under MP mode the backend is set on the **daemon** via `--l2-adapter`, not in vLLM's connector config at all. Reading "the YAML has the right keys" as "the tier is configured" was the exact mistake behind the previous row — check which layer actually consumes a config file before trusting its presence. |
| vLLM's own prefix cache sits upstream of every connector. | If it hits, no connector — LMCache included — is even consulted. A valid reuse number must be cross-instance or measured only after genuine eviction; same-endpoint repeats prove nothing. |
| `nixl_rocm._api.create_backend()` has no `return` statement. | It is always `None`, on success and on failure alike. Check `agent.backends[<name>]` instead of the return value. |
| `ibv_rc_pingpong`'s `Mbit/s` figure is latency-bound loopback, not throughput. | It sends one message and waits for the reply, and (unless explicitly run cross-node with distinct GIDs) never leaves the host. Use `ib_write_bw`/`ib_send_bw`, cross-node, for a real number. |
| A device's **advertised** ceiling (`value_max`, or any similar self-reported field) can understate real capability by a large factor. | Measured on this exact hardware: advertised 4096, real working ceiling 32768 — 8x. Measure the actual boundary (store increasing sizes until the device rejects one) before trusting a self-reported field, in either direction. |
| `query_memory()` reports PRESENT as `{}` — an **empty, falsy dict** — and ABSENT as `None`. | Hit and miss are separable **by identity only**. Any code written `if resp[i]:` scores every hit as a miss and reproduces `retrieve_ops=0` with a brand-new root cause. Measured 2026-09-17; probe latency 57 µs/descriptor. |
| `pkill -f lmcache.v1.multiprocess.http_server` does **not** kill the MP daemon. | Measured 2026-09-18: the daemon survived it (same pid before and after) while `pkill -f api_server` killed vLLM fine. A surviving daemon keeps **L1 and the in-process index warm**, which silently invalidates any cold-reader test. `container.sh down <role>` + `up <role>` (recreating the container) is the only reliable way to get a genuinely cold reader. |
| `nuse` does **not** track KV writes on this device. | Stayed `0x0` after 256+ pages were written and read back successfully. It is not a capacity or progress signal — use the adapter's `l2_commit_writes`, or the plugin's `m_completions_ok`. Any check asserting "nuse grows" is asserting nothing. |
| Counting only successes makes a failure undiagnosable. | The `nixl_kv` adapter counted `l2_device_hits`/`l2_probe_errors` but not *attempts*, so a zero reading could not distinguish "probed and missed" from "never probed" — precisely the state the 2026-09-18 acceptance run left open (TODO 6.28). Now instrumented: five attempt counters added. The sharper, transferable version of the lesson: the attempt must be counted at the *synchronous entry point*, not inside the async work — count it inside the coroutine instead and you reproduce the exact same ambiguity one layer down, because a call that never gets scheduled onto a wedged event loop never increments anything either way. |
| A green low-level check can validate a SCHEME while never exercising the MECHANISM the production path actually uses. | Rung `35` writes its commit object through the raw NIXL agent path (`register_memory` + `initialize_xfer`); the adapter's own store path writes it through `register_host_buffer` + `register_obj_names` + `make_transfer` — a different call sequence entirely. `35` passed 8/8 while the adapter's real commit-write path was silently broken underneath it (TODO 6.34). Compare code paths, not just outcomes, before trusting a lower rung to cover a higher one. |
| The NIXL Python API has several non-obvious shapes that are easy to get wrong silently. | `register_memory` takes `backends` as a **list**; OBJ transfer descriptors must come from `register_memory(...).trim()`, not a raw 4-tuple; `remote_agent` must be the agent's own name for a local storage transfer, not `""`; `nixl_agent_config(backends=[X])` auto-instantiates `X` with **default** params, so a later `create_backend(X, params)` fails "already created" and the real params silently never apply. |
| Two live registrations that are indistinguishable by `(addr, len, devId)` will alias — and the symptom shows up at a DIFFERENT layer, with no error raised anywhere. | `NixlKvStorageAgent`'s page and commit OBJ registrations both use `addr=0`, `devId=`position; the page registration outlives the commit one, so the commit writes land under a page's device key instead of their own (TODO 6.34). The symptom is a missing object (the commit) plus a corrupted neighbour (the aliased page) — not an error on the commit write itself: zero adapter failures, zero exceptions, zero NIXL errors, and `l2_commit_writes` incremented 4 times for four writes that never created their object. A success counter that counts "the call returned" rather than "the effect happened" is not instrumentation. |

---

## 6. Lab, credentials, repo map

### 6.1 Credentials and lab identity

Per-setup identity lives outside the repo entirely:

```
creds/setup-4.env     real values, mode 0600, untracked
creds/active.env      symlink -> setup-4.env
config/creds.env.template   tracked template, placeholders only
scripts/common/init-creds.sh   scaffolds a creds file and the symlink
```

`.gitignore` carries a bare `/creds/` with **no negation exceptions** — a
`!creds/...` rule is one typo away from tracking a real credentials file
in a public repo, so the template deliberately sits on the tracked side of
that line in `config/`. `init-creds.sh` additionally refuses to write if
`creds/` is not ignored, verifying the assumption rather than trusting it.

`config/cluster.env` sources `${CREDS_FILE:-creds/active.env}` before its
own defaults, so creds always win. Anything unset falls back to a
placeholder on the reserved `.invalid` TLD — a checkout with no creds file
fails DNS immediately rather than resolving to a real machine.

To get a fresh checkout running: `scripts/common/init-creds.sh 4`, edit the
file, then `scripts/common/00-preflight.sh`.

> **Outstanding:** the BMC and root passwords were committed to a public
> repo before an earlier cleanup purged the history. If anyone cloned or
> GitHub cached it during that window, rotation is the only real remedy
> (TODO 0.2, not closed by the purge).

**The repository is PUBLIC.** Everything lab-specific has been
externalised; no credential or lab identifier appears in any blob of any
commit.

### 6.2 Repository map

```
config/cluster.env          single source of truth; sources creds/active.env
first
config/creds.env.template   tracked template for a per-setup creds file
creds/                      UNTRACKED, gitignored — real addresses and passwords
scripts/common/             lib.sh (shared vocabulary), init-creds, preflight,
                            SPDK/UCX/NIXL build chain, venv, LMCache MP daemon
                            lifecycle, shared vLLM launcher, deploy.sh
                            (repo sync + remote exec onto the three bare nodes)
scripts/target/             SPDK build + nvmf_tgt, verify, namespace reset,
                            chunk-ceiling guard
scripts/prefill/             host prep, vLLM as kv_producer
scripts/decode/               host prep, vLLM as kv_consumer
scripts/proxy/                async disaggregation router (three-step XpYd
handshake)
scripts/verify/               10 network → 20 plugin → 30 KV roundtrip →
                              35 nixl_kv naming (cross-node, GREEN) →
                              40 end-to-end → 50 direct P/D transfer →
                              60 L2 cross-node acceptance (step 5 GREEN
                              post-fix, TODO 6.34; step 7 void pending a
                              namespace drain)
scripts/bench/                llama-benchy harness + compare_runs.py
patches/spdk/                 4 NVMe-KV patches (2 still required, see below)
patches/lmcache/               ONE diff (0011) carried here — verified NOT
                              in the vendor image; we apply it ourselves by
                              overlaying the file into the running
                              container, and it needs to reach the next
                              image build. 0006-0009 are baked into
                              the image at BUILD time and, since
                              2026-09-17, no longer carried as .patch
                              files here; see patches/lmcache/README.md
                              and §7.8
plugins/                      vendored SPDK_NVMe_KV and XNVME_KV NIXL backends
overlays/lmcache/             THIS REPO's LMCache source, bind-mounted into
                              the vendor container at run time (container.sh):
                              nixl_kv_l2_adapter.py (the content-addressed L2
                              adapter, TODO 6.21/6.28) + its offline tests.
                              Distinct from plugins/ (vendored C++) and
                              patches/ (diffs) — this is source we author.
docs/design/                  nixl-kv-l2-adapter.md — the adapter's spec:
                              problem statement, measured facts, protocol,
                              init asserts, acceptance test, and §11's record
                              of decisions taken where the spec was silent
docs/                         ARCHITECTURE, BRINGUP, TROUBLESHOOTING,
BENCHMARKING,
                              TODO, HANDOFF
```

### 6.3 SPDK: upstream plus two open patches; the container path is what actually runs

There is **no private SPDK fork**. NVMe-KV support is four upstream-bound
patches by Ben Walker (NVIDIA) on review.spdk.io, vendored in
`patches/spdk/`:

| Patch | Gerrit | Status |
|---|---|---|
| `0001` nvme: recognize KV namespaces | 28260 | **MERGED** (`8dc8327`) |
| `0002` bdev/kvmalloc | 27889 | **OPEN** — CR+2, Verified+1, mergeable |
| `0003` nvmf: KV namespace support | 28298 | **OPEN** — CR+2 ×2, Verified+1; depends on 0002 |
| `0004` nvme: KV unit tests | 27886 | **MERGED** (`b12a372`) |

Only 0002 and 0003 must be carried — re-check
`https://review.spdk.io/q/topic:kv+status:open`; when they land, the
vendored copies can be dropped. See
[patches/spdk/README.md](../patches/spdk/README.md).

**This repo's own from-source build chain (`05-build-spdk-initiator.sh`,
`10-build-stack.sh`, `20-build-vllm-lmcache.sh`) is not what this lab
actually runs.** The working deployment is the vendor container image
`rocm-aic:mp-pd-ionic2609` — vLLM 0.26.0+rocm, LMCache 0.5.3, NIXL plugins
already built, `nixl`/`rixl` both present. The from-source path is
deprioritized, not deleted (TODO 6.2); if it is ever revived, note that an
attempted from-source SPDK build against current `master` failed to apply
patch 0002 as vendored — master has moved since these patches were cut, so
pin a compatible SHA or rebase before trying again.

### 6.4 The KV target device, concretely

- The DSC namespace is real and provisioned: `nvme id-ns /dev/ng1n1` gives
  `nsze = 0x200000` blocks at `lbads 9` (512 B) = 1 GiB. `nvme list`
  showing "0.00 B / 0.00 B" is `nuse=0` (unused, not unprovisioned) — do
  not read that as an absent namespace. 1 GiB is small for a KV tier;
  flag as a sizing question to confirm before relying on it at scale, not
  as a blocker today.
- `smc3` (`volcano17`) runs `nvmf_tgt`, and both compute nodes' DSCs are
  its NVMe-oF peers (§2) — `smc3` stays; there is no local-DSC path that
  avoids depending on it (§7.3).

---

## 7. History: corrections that still matter

This project accumulated twelve chronological session logs before this
rewrite. Most of what they recorded is now either dead (superseded facts
about hardware that has since changed again) or already folded into §§1–6
above as current truth. What's kept here is the set of corrections whose
*lesson*, not just their conclusion, is worth carrying forward — several
of them corrected an earlier correction, and carrying both forever was
most of the original bloat. State only the current truth; do not restore
the withdrawn conclusion alongside it.

### 7.1 The hardware is shared, and it changes under you

Established as a standing rule after it happened five separate times in
two sessions (2026-09-14/15): the KV target's subsystem was reconfigured
by another party mid-session; the DSC driver/firmware bundle was replaced
between sessions; a 200G link came up during an unrelated investigation;
`ionic_N`→netdev mapping changed; `amdgpu` was loaded by someone else
mid-boot. **Lesson:** a recorded measurement of driver, device, or library
state has a shelf life on this cluster — re-measure, don't trust the
document (§3.5).

### 7.2 GPU blacklist is autoload-only, not a hard block

2026-09-14/15: an earlier pass concluded `modprobe.blacklist=amdgpu`
required a GRUB edit and a reboot to lift. It does not: the blacklist
suppresses udev/alias autoload only, and an explicit `modprobe amdgpu` by
name works immediately, every boot, no reboot needed. It also does not
survive a reboot, so the explicit `modprobe` has to run every time (§3.4).

### 7.3 A "local DSC" device turned out to be the shared target, one hop closer

2026-09-16/17: each compute node's own Pensando DSC exposes `/dev/ng1n1`,
and this was initially read as an independent, node-local 1 GiB device —
raising a real "maybe we don't need the shared target at all" option.
Measured: `nvme ns-descs` returns an identical `eui64` and `csi` on both
nodes' `/dev/ng1n1` — same namespace, re-exported transparently over each
node's own PCIe function by the DSC acting as an NVMe-oF initiator to
`smc3`. There was never a choice between "local DSC" and "the shared
target" — they were the same object (§2, §6.4). A separate, sharper
warning survives from the same investigation and is now invariant 10: the
vendor reference script's device default, `/dev/ng0n1`, is this hardware's
**OS boot drive**, not a KV device.

### 7.4 RDMA fabric, break one — userspace provider ABI mismatch (fixed)

2026-09-15/16: after an OS upgrade, `ibv_devinfo` returned `No IB devices
found` on both compute nodes despite sysfs reporting all 8 ports healthy
on each — the DSC's userspace provider (`libionic-rdmav59.so`) was built
against a newer `rdma-core` ABI than the installed `libibverbs` (50)
loads, so it silently loaded no ionic provider at all. Fixed when another
party installed a 24.04-matched vendor DSC bundle; `ibv_devinfo` then
enumerated 8 devices per node cleanly.

### 7.5 RDMA fabric, break two — UD queue-pair creation still fails

Independent of §7.4, and not fixed by it: **UD queue-pair creation fails
on this driver/firmware** (`CREATE_QP ... BAD_ATTR`), which breaks the
GSI/MAD QP and therefore `rdma_cm`. A later firmware update leveled 15 of
the 16 cards across both nodes and, by making the one remaining
old-firmware card fail **identically** to the newly-leveled ones,
**disproved** firmware skew as the cause — a card on old firmware and
cards on new firmware fail the same way, so this is a driver-level defect,
not a firmware-version mismatch. This remains the sole open RDMA-stack
blocker (invariant 6, TODO 3.9): `UCX_TLS=ib` pulls in UD transports,
which fail here, so Phase 2 needs the transport spec narrowed to RC
explicitly without weakening invariant 6's exclusion of `tcp`.

### 7.6 RDMA fabric, break three — routing gap closed, first real cross-node throughput

The cross-node routing gap between the two nodes' `/24` fabric subnets —
long the stated blocker — closed on its own (another party configured
static routes). With RC queue pairs already working (§7.4) and firmware
levelled (§7.5), cross-node RC queue pairs were then measured moving real
data (`ib_write_bw`, ~88% of 400 Gb/s line rate) — the first real RDMA
throughput number on this cluster. Getting that number needed its own
correction: the kernel netdev byte counters read near-zero for RoCE
traffic (RoCE bypasses the netdev path entirely), and a too-short settle
window on the MAC-level counter that does work produced a false "did not
cross" reading before a longer settle window showed the real number.
**Lesson, twice over, generalized in §5:** an instrument reading zero is
not evidence of absence until you've shown the instrument responds at
all; and `ibv_rc_pingpong`'s `Mbit/s` figure is a latency-bound loopback
test, not a throughput measurement.

### 7.7 A connector wrongly declared incapable of the one thing it does

2026-09-16: an investigation correctly found that `LMCacheMPConnector`
ignores `extra_config{enable_nixl_storage, nixl_backend,
nixl_backend_params}` — true — and concluded from that alone that MP mode
is architecturally incapable of reaching a KV backend at all,
recommending a switch to the in-process `LMCacheConnectorV1` instead.
**This was wrong.** `LMCacheMPConnector` reaches `XNVME_KV`/`SPDK_NVMe_KV`
through a second, separate route the investigation never examined: the
daemon-side `nixl_store` L2-adapter (`--l2-adapter` JSON, §1.1) — the
vendor's own reference deployment runs exactly this. This repo's actual
scripts (`gen-kv-transfer-config.sh`, `cluster.env`) had been emitting the
correct `LMCacheMPConnector` composition the entire time; only the docs
had drifted toward the wrong conclusion, and no code ever needed to
change. **Lesson:** a negative result about one configuration surface is
not a negative result about the component — before concluding "X cannot
do Y," confirm every config surface X exposes has been checked, not just
the one expected to be used. (One finding from that same investigation
*did* hold up and is now enforced in code: `NixlConnector` must be listed
first in `MultiConnector`, or a decode-side LMCache hit silently pre-empts
the remote-prefill pull — §1.)

### 7.8 "The image accepts these backends unpatched" was false

2026-09-17: the vendored LMCache 0.5.3 carries `XNVME_KV`/`SPDK_NVMe_KV`
in its hardcoded backend allowlists. One pass correctly identified this
repo's own from-source LMCache patch generator as dead code (it targets a
from-source build that has never completed) and, on the same day,
incorrectly concluded from "no marker string of our own edits in the
installed source" that the vendor image needed no patch at all — and
staged `git rm -r patches/lmcache/` on that premise. That delete was
caught and reverted before it reached a commit. **The image ships
pre-patched**, built from a sibling repo's `patches/lmcache/`
(`0006`–`0009`) applied at image-build time — a conventional
`.patch` diff simply doesn't leave a marker string the way an in-repo
generator's own edits would have. (This section originally listed `0011`
in that set too. **That was wrong** — `0011` was never applied to this
image; it was assumed present because the re-verification recipe of the
day gave a false pass on it. Corrected below.) **Lesson:** "no marker of
our tooling having run" is not evidence of "no patch" when a different
toolchain could have produced the same file. `patches/lmcache/0007` is also
worth knowing by name: it is the **origin** of the `mem_split_n`/`#{j}`
multipart-split scheme the storage tier depends on — not upstream LMCache
behavior.

**2026-09-17, later the same day — a related but opposite deletion, this
time correct.** `patches/lmcache/0006`, `0007`, `0008`, `0009` were
re-measured against `rocm-aic:mp-pd-ionic2609` with a rewritten recipe (the
old one gave a false pass — see the end of this entry) and confirmed
present in the image. On that basis their `.patch` files were deleted from
this repo under a new policy: **if the vendor image ships it, this repo
does not carry the diff; the image is the source of truth, and
`patches/lmcache/README.md` is the record of what that truth must
contain.** Do not confuse this with the delete above. The delete above was
staged while *wrongly believing the image was unpatched* — deleting the
record would have destroyed the only account of a dependency nothing else
documents, with no image-side guarantee to fall back on. Today's deletion
is the opposite: the image is **measured patched**, every entry stays in
the README's table with a working, re-run-able check, and the one patch
the image was measured to *lack* — `0011`, guarding
`LMCacheMPConnector.update_state_after_alloc()` against a non-chosen
`MultiConnector` sub-connector's spurious retrieve/lock-leak — is the one
still carried as a `.patch` file here. The same investigation also found
the *previous* re-verification recipe gave a false pass on `0011` (it
grepped `num_external_tokens`, which matches that function's unpatched
signature and docstring too); the recipe in `patches/lmcache/README.md` is
rewritten so every check greps a string that exists only in the patched
form.

### 7.9 A kernel-dependent fact was read as a flat contradiction

2026-09-15: a KV namespace was found to create *no* device node at all on
`5.15.0-191-generic` (`unknown csi 1 for nsid 1`), disproving the plugin
header's claim that it always appears as `/dev/ngXnY`. After the compute
nodes were upgraded to Ubuntu 24.04.5 / kernel 6.8.0-139, the identical
test **did** create the char device (`block device ... not supported
(csi 1)`, correctly no block device beside it). Neither finding was
wrong — each was true of a different kernel. **Lesson:** "disproven" can
mean "true of a different environment than the one being read"; check
which axis actually changed before concluding a claim is simply false.
This is why `KV_BACKEND=XNVME_KV` (kernel `nvme-of`) is viable at all
today.

### 7.10 A proxy's silence was read as a design decision, twice

2026-09-15: the vendored `disagg_proxy_demo.py` threads no
`kv_transfer_params` at all. Two separate passes concluded from this that
the field was "settled and unused." Measured directly: the real XpYd
handshake is **three** steps, not two — the priming request must itself
*request* the handoff (`do_remote_decode: true`) before prefill will
populate `kv_transfer_params` in its response at all. Without step one,
every request "succeeds" and decode silently re-prefills the entire
prompt — HTTP 200, coherent text, `finish_reason: stop`, and **zero** KV
crossing the wire. **Lesson:** an absence in a reference implementation is
evidence about that implementation, not about the interface it happens to
share a name with. This repo's own `scripts/proxy/disagg_proxy.py` is the
router now, and it performs step one.

### 7.11 The device's advertised ceiling was trusted, then measured, and the measurement won

2026-09-17: the XNVME_KV plugin originally established
`max_value_size=32768` as a real, working ceiling (65536 measured failing
with `sct=7 sc=234`). Later the same device began advertising
`value_max=4096` at backend init. On the strength of that advertised
field alone, `config/cluster.env` was changed to
`KV_MAX_VALUE_SIZE_XNVME=4096` and the change was recorded as "resolved."
**That resolution is retracted.** Storing a single 32768 B value against
the *current* firmware still succeeds cleanly (`sct=0 sc=0`); 33792
already fails. The device's advertised field understates its own true,
measured ceiling by 8x — nobody had actually tried storing 32768 against
the newly-advertising firmware before lowering the config to match it.
`KV_MAX_VALUE_SIZE_XNVME` is back to 32768 (§2, §4 invariant 4); the
resulting startup WARNING (configured value exceeds the advertised one) is
correct and expected, not a bug to silence. **Lesson**, now generalized as
a trap in §5: never trust a self-reported ceiling over a direct
measurement of the actual boundary.

### 7.12 A verification script's own defects produced a false negative

2026-09-17: `50-verify-pd-direct.sh` had four independent bugs — priming
without the handoff field, checking the wrong side-channel address,
racing vLLM's periodic stats logger, and a hard assertion on a log string
this vLLM/LMCache version never emits — each one enough on its own to
fail the acceptance rung regardless of whether the underlying P→D
transfer worked. All four are fixed; the rung now passes 9/9. **Lesson:**
the "a check can pass while proving nothing" failure family cuts both
ways — a check can also *fail* while proving nothing, and a red result
deserves the same scrutiny as a green one before it's read as a real
regression.

### 7.13 Still-open operational note: unexplained reboots

Both compute nodes have rebooted unexpectedly and repeatedly across
multiple sessions, with no panic, MCE, OOM, or thermal event in the
journal to explain most of them (TODO 6.20). One instance is explained (an
oversized per-worker `LMCACHE_MAX_LOCAL_CPU_SIZE`, invariant 9); most are
not. Check `uptime` before starting anything that takes minutes (§3.2).

</content>

### 7.14 A root cause stated as one thing when it was two

2026-09-18: TODO 6.21's cause was recorded as LMCache's per-daemon
`obj_{i}_{uuid4}` naming, "isolated beyond argument". That was true but
**incomplete**, and the incompleteness mattered: the adapter also has no
way to ASK the shared medium about a key it did not store
(§2.0, Blocker 1). Reading source rather than re-deriving from the
conclusion is what surfaced it. The tell was already in the record and had
been misread as a dead end: restoring the plugin's `queryMem()` override
changed nothing — because the verb existed one layer down and the layer
above never called it. **Lesson:** "isolated beyond argument" is a claim
about how hard you looked, not about the system. When a fix that should
have helped changes nothing, that is evidence of a SECOND cause, not
evidence the first one was wrong.

### 7.15 A verification recipe that could not fail

2026-09-18: `patches/lmcache/README.md` claimed all five LMCache patches
were verified present in the vendor image. Its check for `0011` grepped
`num_external_tokens` and expected hits at two line numbers — which are the
**function signature and its docstring**, present in the unpatched file. The
check passed whether or not the patch was applied, and `0011` had in fact
never been in the image at all. Every check in that recipe now greps a
string that exists only in the patched form, and each was tested against a
deliberately-mutated input to prove it can report MISS. **Lesson:** a
verification recipe is code. "It printed what I expected" is not the same as
"it could have printed otherwise" — this is §7.6's instrument lesson applied
to documentation, and it is why the 2026-09-17 deletion of `0006`–`0009`
was only safe *after* the recipe was rebuilt.

### 7.16 Deleting the record vs. deleting a redundant copy

2026-09-17 (a): a pass concluded from "no marker of our edits in the
installed source" that the image needed no patches, and staged
`git rm -r patches/lmcache/` — reverted before commit (§7.8).
2026-09-17 (b): `0006`–`0009` were deleted **deliberately and correctly**,
after being measured present in a fresh container with no mounts, with each
entry keeping a working check in the README and the one patch the image
*lacks* (`0011`) still carried. These look like the same action and are
opposites. The distinguishing question is not "is this redundant?" but
**"if this claim were false, what would tell me?"** In (a) nothing would
have; in (b) the recipe does. Record sha256s of anything deleted so a copy
recovered from git history can be identity-checked.
