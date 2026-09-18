# Architecture

This document explains *why* the cluster is built the way it is, not just
how to run it (see [`BRINGUP.md`](BRINGUP.md) for that). Read
[`../README.md`](../README.md) first for the topology and the one-page
picture.

## 1. Two KV paths: a direct P→D transfer, and a shared storage tier

Every vLLM instance (prefill and decode alike) runs the exact same, fixed
connector composition:

```
MultiConnector[NixlConnector, LMCacheMPConnector]
```

`NixlConnector` is always `child[0]`; this is not configurable. The order
matters mechanically, not just stylistically:
`MultiConnector.get_num_new_matched_tokens()` (`multi_connector.py:387-400`)
walks its children in list order and assigns the **entire** load to the
first one that reports a non-zero match — it does not merge matches across
children. If `LMCacheMPConnector` were listed first, a decode-side request
whose prefix is already in the local storage tier would be satisfied by
LMCache before `NixlConnector` was ever asked, and the direct P→D pull below
would silently never fire. So `NixlConnector` must go first, unconditionally.

This composition carries **two KV paths, both always active** — they are
not alternative architectures to pick between, and an earlier design in this
repo that framed them as independently-enableable "leg A"/"leg B" options
(via `PD_ENABLED`/`PD_CONNECTOR`/`PD_LMCACHE_FIRST`, and a single-connector
`LMCacheConnectorV1` mode as the alternative to `MultiConnector`) has been
collapsed to this one, unconditional shape. `scripts/common/gen-kv-transfer-config.sh`
generates the composition above for both roles, always, with no variable
left that can select something else.

**Path 1 — the P→D handoff (`NixlConnector`).** This is genuine GPU-to-GPU
peer-to-peer transfer: prefill's `kv_producer` writes staged KV blocks that
decode's `kv_consumer` pulls directly over UCX, no third node involved.
Transport is `KV_TRANSPORT=tcp|rdma` (`config/cluster.env`) — the one
surviving axis from the old design, and the axis the Phase-2 RDMA acceptance
criterion applies to. Making this fire is entirely the proxy's job (§1.1
below); `NixlConnector` itself does no priming.

**Path 2 — the storage tier (`LMCacheMPConnector`).** This path *is* still
storage-mediated, for the same underlying reason the original design in this
repo identified: `plugins/nvme-kv/spdk_nvme_kv_backend.h` declares

```cpp
bool supportsRemote() const override { return false; }
```

`SPDK_NVMe_KV` (and its sibling `XNVME_KV`, the current default via
`KV_BACKEND`) are **storage** backends in NIXL's model, not **transfer**
backends — their contract is STORE/RETRIEVE/(queryMem) against an
addressable namespace, not "move these bytes into a peer agent's registered
memory region." That header comment also notes the GPU and the data-plane
NIC sit on different NUMA nodes/CPU sockets on these hosts, so building
genuine GPU-to-GPU peer transport *through this plugin* was never a
worthwhile investment — every VRAM-side transfer already bounces through a
host staging buffer (`spdk_zmalloc()` + `hipHostRegister()`, `hipMemcpy` in
and out). None of that changed; what changed is that a *separate* connector
(`NixlConnector`, Path 1 above) now supplies the peer-to-peer transfer this
plugin was never going to provide, so the storage tier no longer has to
pretend to be the whole P/D story — it only has to be a good shared,
content-addressed reuse tier, which SMC3 is.

`LMCacheMPConnector` does not talk to the storage plugin directly. It hands
completed KV chunks over a local ZMQ channel (loopback, `LMCACHE_MP_PORT`
default `6557`) to the **LMCache MP daemon** — a separate host process
(`scripts/common/start-lmcache-daemon.sh`) running on that same node. The
daemon's L2 tier is attached via a repeatable `--l2-adapter` JSON spec, type
`nixl_store` (the *static* adapter — `nixl_store_dynamic` is a different,
file-oriented thing that requires `backend_params.file_path` and registers
`mem_type=FILE`; wrong for a KV backend):

```json
{"type":"nixl_store","backend":"XNVME_KV","backend_params":{"dev_uri":"..."},"pool_size":2000000}
```

That adapter is what actually calls into the NIXL storage plugin
(`XNVME_KV` or `SPDK_NVMe_KV`) against SMC3 — the same plugin C++ code
described throughout the rest of this document, just invoked from the
daemon process instead of from an in-process LMCache connector. `pool_size`
counts `--l1-align-bytes`-sized (default 4096 B) storage slots, **not**
LMCache chunks — a multi-MiB LMCache page tiles into many pool slots, which
is why the default is large. This `--l2-adapter` JSON is the *only* LMCache
storage-tier config surface in this repo: an earlier, separate surface (a
generated YAML with its own `extra_config.{enable_nixl_storage,nixl_backend,
nixl_backend_params}` block) belonged to the in-process `LMCacheConnectorV1`
path, which this cluster never runs, and has since been removed along with
the rest of that path's dead config (`docs/TODO.md` §6.23). Mistaking that
now-removed surface for this one produced a withdrawn conclusion in this
project's history (`docs/HANDOFF.md` §12.1, corrected in §16) that MP mode
could not reach the KV backend at all.

### 1.1 Full request flow

```
 client
   │  POST /v1/chat/completions
   ▼
 disagg_proxy.py (proxy)
   │  STEP 1: prime prefill — max_tokens=1, kv_transfer_params=
   │          {do_remote_decode:true, do_remote_prefill:false, remote_*:None}
   ▼
 SMC1 prefill vLLM ── runs the prompt forward pass
   │  MultiConnector[NixlConnector(kv_producer), LMCacheMPConnector]
   │
   ├─(a) NixlConnector stages the computed KV blocks and returns a
   │     populated kv_transfer_params (remote_engine_id/block_ids/host/
   │     port/...) in its HTTP response
   │
   └─(b) LMCacheMPConnector ships the same KV chunks over ZMQ
         (loopback:6557) to the LMCache MP daemon on SMC1, whose
         --l2-adapter (nixl_store, backend=KV_BACKEND) STOREs them
         on SMC3 over NVMe-oF/TCP
   │
   ▼ (back at the proxy)
 STEP 2: extract kv_transfer_params from prefill's JSON response
 STEP 3: thread it into the real (unmodified) request body
   │
   ▼
 SMC2 decode vLLM ── MultiConnector[NixlConnector(kv_consumer), LMCacheMPConnector]
   │
   ├─(a) NixlConnector is child[0]: it sees the threaded kv_transfer_params
   │     and PULLS the staged KV blocks directly from SMC1 over UCX
   │     (KV_TRANSPORT=tcp|rdma) — genuine peer-to-peer, no SMC3 involved.
   │     This is the common case and is what makes P/D disaggregation work
   │     without ever touching the storage tier on the hot path.
   │
   └─(b) only if (a) doesn't apply (e.g. NixlConnector reports no match —
         short prompt, missing handoff, cold decode instance restarted):
         LMCacheMPConnector's own daemon probes/RETRIEVEs the same content
         via its --l2-adapter against SMC3 — the storage tier acting as
         the shared, cross-restart reuse tier it's meant to be.
   │
   ▼
 token-by-token generation, streamed back through the proxy to the client
```

Step (a) under decode is what the pre-consolidation design in this document
called "storage-mediated" for the *entire* P/D handoff; it is now only true
of the fallback path (b) and of the always-on storage tier's own semantics
(surviving what a single request needs — see §4).

## 2. Storage-tier KV lifecycle: the daemon's L2 adapter path

This section covers Path 2 from §1 — the always-on storage tier — in
detail. Path 1 (the direct `NixlConnector` P→D pull) is covered by §1.1's
flow diagram; it does not go through any of the machinery below.

Numbers below correspond to `LMCACHE_CHUNK_SIZE=256` (tokens per LMCache
"page") and `KV_MAX_VALUE_SIZE=524288` / `KV_MAX_VALUE_SIZE_XNVME=32768`
(the plugins' advertised per-transfer ceilings for `SPDK_NVMe_KV` /
`XNVME_KV` respectively), all from `config/cluster.env`. The default
`MODEL` is `Qwen/Qwen2.5-72B-Instruct` at `TP_SIZE=8` — a page's actual byte
size scales with the model's layer count/hidden size/KV-head count (not
recomputed here for this model specifically), but the invariant this
section depends on holds regardless: a KV page is normally larger than
either ceiling, which is why some form of splitting is always in play.

**Prefill side (STORE):**

1. vLLM (SMC1) runs the prompt forward pass; per-layer, per-block KV tensors
   land in GPU memory as usual.
2. `LMCacheMPConnector` (child[1] of `MultiConnector`) hands completed KV
   blocks to LMCache, which groups tokens into pages of
   `LMCACHE_CHUNK_SIZE=256` tokens — several MB per page for
   `Qwen2.5-72B-Instruct`'s KV shape at `TP_SIZE=8` (larger than an
   8B-class model's, given its layer count and hidden size; the exact byte
   count is not derived here — see the note at the top of this section).
3. Unlike the pre-consolidation, in-process `LMCacheConnectorV1` design (§1),
   the chunk does not go straight into a NIXL storage backend from inside
   vLLM's own process. It crosses a ZMQ control channel (loopback,
   `LMCACHE_MP_PORT` default `6557`) to the **LMCache MP daemon** — a
   separate host process (`scripts/common/start-lmcache-daemon.sh`) — whose
   storage manager owns the actual L1 (pinned DRAM)/L2 tiering.
4. On an L1 eviction (or directly, depending on the daemon's policy), the L2
   tier's `nixl_store` adapter (`--l2-adapter`, backend = `KV_BACKEND`)
   takes over. It tiles the chunk's bytes into `--l1-align-bytes`-sized
   (default 4096 B) pool slots — **not** directly into
   `KV_MAX_VALUE_SIZE`-sized sub-transfers, because 4096 B is already under
   both plugins' ceilings (see step below on `mem_split_n`).

   > **Correction, 2026-09-17.** An earlier version of this sentence
   > attributed `mem_split_n`-style splitting to "the old in-process
   > `LMCacheConnectorV1` path" and said its "allowlist-patch generator
   > script was deleted... as dead code" — implying this file's splitting
   > machinery was itself dead/withdrawn. **That is wrong on two counts.**
   > First, `mem_split_n`/`_resolve_mem_split()` live in *this exact file*
   > (`nixl_store_l2_adapter.py`, the daemon's L2 adapter — the live path,
   > not the in-process one) and are supplied by
   > `patches/lmcache/0007`, baked into the vendor image. (As of
   > 2026-09-17 that patch is verified present in the image and its
   > `.patch` file is no longer carried in this repo — see the policy
   > change in `patches/lmcache/README.md`. Note also that it is currently
   > **dormant, not load-bearing**: measured `page_size=4096` against a
   > declared `max_value_size=32768`, so `_resolve_mem_split()` returns 1
   > and the `#{j}` split path never executes. It becomes live only if
   > `--l1-align-bytes` rises above `max_value_size`.) Second, the
   > withdrawn generator targeted a *different* file entirely
   > (`nixl_storage_backend.py`, the in-process path's allowlist — see
   > `patches/lmcache/0008` for that file's equivalent patch, likewise
   > verified present and no longer carried) and its
   > withdrawal has no bearing on whether this file's splitting exists —
   > it does, and it is not upstream LMCache. See
   > `patches/lmcache/README.md` for the full account.

   `pool_size` in the `--l2-adapter` spec counts these 4096 B
   slots, one per raw page tile, which is why its default (2,000,000) looks
   large relative to a single chunk. Because 4096 B is well under both
   plugins' advertised ceilings (524288 / 32768), this adapter-level tiling
   resolves to a single sub-transfer per slot (`mem_split_n=1`) at default
   settings — no further adapter-level splitting engages.
5. `backend_params` (e.g. `{"dev_uri": "..."}` for `XNVME_KV`,
   `{"trid": "...", "kv_slot_offset": "..."}` for `SPDK_NVMe_KV`) are
   forwarded verbatim to `nixl_agent.create_backend()` — the same NIXL
   plugin construction path both `NixlConnector`'s own initialization and
   the old in-process YAML use. From here down, the plugin-level mechanics
   are unchanged from the pre-consolidation design regardless of which
   caller (daemon adapter vs. in-process connector) invoked them: each
   sub-transfer becomes one NIXL descriptor,
   `nixlSpdkKvEngine::registerMem()` captures its `metaInfo`, `postXfer()`
   derives the 12-byte on-wire key via `make_key()` — two
   independently-seeded FNV-1a hashes over `metaInfo` (see §3) — and
   heap-allocates one `SpdkKvWorkEx` per descriptor.
6. `postXfer()` submits **all** work items in the batch without waiting
   (`spdk_nvme_kv_store()`/`XNVME_KV`'s equivalent), then returns; it does
   not block per-item.
7. The request travels over NVMe-oF/TCP (`SPDK_NVMe_KV`) or a kernel
   `nvme`/io_uring_cmd session (`XNVME_KV`) — always TCP-transport
   underneath, regardless of `KV_TRANSPORT` (§1) — to SMC3's `nvmf_tgt`,
   which writes it into the `bdev_kvmalloc` namespace (`KV_BDEV_NAME`).
   That namespace is an in-memory red-black tree sized only by
   `KV_BDEV_MAX_KEY_SIZE`/`KV_BDEV_VALUE_MAX` (no separate total-size RPC
   parameter exists — a `KV_BDEV_SIZE_GB` this document previously
   referenced here does not exist in `config/cluster.env` and never did;
   see that file's own comment on why it was removed, not renamed).
8. `checkXfer()` polls an atomic pending counter per request handle; it
   returns `NIXL_IN_PROG` until every sub-transfer's completion callback has
   fired, then `NIXL_SUCCESS` (or a failure state — see §5).

**XNVME_KV's own internal splitting is a separate, lower-layer concern.**
Independent of the adapter-level 4096 B tiling above, the `XNVME_KV` plugin
itself may still further split a single value against its own 32 KiB
`max_value_size` ceiling internally — this is the plugin's own multipart
mechanism (referenced in `docs/HANDOFF.md` §12.7 as "32 KiB parts") and is
unrelated to, and unaffected by, the adapter's `pool_size`/`align_bytes`
accounting.

**Decode side (RETRIEVE), for a request whose prompt matches or shares a
prefix with something prefill already stored, and for which the direct
`NixlConnector` pull (Path 1, §1.1) did not apply:**

1. LMCache (via `LMCacheMPConnector` → the MP daemon on SMC2) computes the
   identical content-derived key for each candidate chunk — same model
   identity, same chunk position, same token-content hash, because both
   sides derive it from prompt content, not from anything transmitted
   between the processes.
2. Before issuing any RETRIEVE, the daemon's `nixl_store` adapter calls the
   NIXL storage backend's existence probe. `queryMem()` issues an NVMe KV
   *Exist* command per candidate key and reports engaged/absent per key —
   this is the call whose *absence* was this cluster's first recorded
   production bug (see §2.1).
3. For every key the probe confirms exists, the adapter issues a RETRIEVE
   the same way STORE was issued (tiled by `--l1-align-bytes`, same
   `metaInfo` derivation).
4. `postXfer()`/`checkXfer()` follow the identical async submit-all/poll-count
   pattern as the write side.
5. Reassembled KV pages travel back over ZMQ to `LMCacheMPConnector` and are
   handed to vLLM's model runner, which skips recomputing the corresponding
   portion of the prefill forward pass.

### 2.1 The `queryMem()` incident (canonical failure signature)

Before `queryMem()` existed, NIXL's base `nixlBackendEngine` answered every
existence query with `NIXL_ERR_NOT_SUPPORTED`. Whichever LMCache caller sets
content-derived keys rather than a per-process `uuid4` (see §3) — the only
kind that can support cross-node P/D sharing at all — treated that as
"every key is a miss," unconditionally. Prefill's STOREs still succeeded
(writes don't need an existence probe); decode's RETRIEVE path never even
tried, because its own lookup logic short-circuited on the probe result.
Observed 2026-09-07 as `LMCache hit tokens: 0` on every single decode
request — this is the canonical P/D failure signature for this cluster, and
the reason `queryMem()`'s doc comment in
`plugins/nvme-kv/spdk_nvme_kv_backend.h` (lines ~233-250) is as detailed as
it is. `scripts/verify/30-verify-kv-roundtrip.sh` and `40-verify-disagg.sh`
both exist specifically to catch a regression of this exact bug before it
reaches a live serving test.

## 3. Key-derivation scheme

> **Which caller this describes.** The mechanics below (`make_key()`,
> `metaInfo`, FNV-1a) are the NIXL storage plugin's own C++ code and are
> unchanged by anything in §1/§2's consolidation — they fire identically
> regardless of which process calls into the plugin. What *has* changed is
> the caller: this section (and the historical incident in §2.1) was
> written against LMCache's in-process `NixlDynamicStorageBackend` /
> `NixlDynamicStorageAgent` (the `LMCacheConnectorV1` path, configured via
> `nixl_pool_size: 0` in a since-removed generated YAML — see
> `docs/TODO.md` §6.23). This cluster now runs `LMCacheMPConnector`
> instead, and the caller into the plugin is the MP daemon's `nixl_store`
> L2 adapter (§1/§2), configured via `--l2-adapter` JSON, not that YAML.
> Whether the adapter's object-naming
> scheme is the same content-derived `CacheEngineKey`-based `metaInfo` this
> section describes, or a different addressing scheme (the daemon's own
> `get_memory_indices()`/`get_storage_indices()` machinery referenced in
> `scripts/common/start-lmcache-daemon.sh` suggests it may tile by pool-slot
> position rather than by content hash) has **not** been independently
> confirmed for this document and should be verified against
> `nixl_store_l2_adapter.py` before relying on the cross-node-sharing
> argument below for the MP path specifically.

`plugins/nvme-kv/spdk_nvme_kv_backend.h`'s `make_key()` derives a 12-byte
on-wire NVMe-KV key one of two ways, selected by whether the caller set
`nixlBlobDesc::metaInfo`:

- **`metaInfo` set**: two independently-seeded 64-bit FNV-1a hashes over the
  `metaInfo` string — `h1 = fnv1a64(metaInfo, 14695981039346656037ULL)` (the
  FNV offset basis) into the low 8 key bytes,
  `h2 = fnv1a64(metaInfo, 0x9E3779B97F4A7C15ULL)` (a different, arbitrary
  seed) truncated to 4 bytes into the high 4 key bytes. FNV-1a was chosen
  over `std::hash` specifically because the on-wire key must be
  reproducible **across processes, hosts, and rebuilds** — `std::hash`'s
  implementation is only guaranteed stable within a single process/build,
  which is not a contract two independent agents (prefill, decode) can rely
  on agreeing on.
- **`metaInfo` empty** (callers that never set it — `kv_io.py`, `nixlbench`):
  falls back to 8 bytes of `devId` + the low 4 bytes of `addr`. This is a
  storage-pool slot index allocated independently by each caller's
  `NixlObjPool`, starting from 0 — which is exactly why two independent
  deployments sharing a namespace on this path collide on their early slot
  indices unless given disjoint `KV_SLOT_OFFSET_PREFILL`/`KV_SLOT_OFFSET_DECODE`
  values (`config/cluster.env`).

**Why the `metaInfo` path is what makes cross-deployment sharing safe, on
the in-process `LMCacheConnectorV1` path this was originally verified
against:** `NixlDynamicStorageAgent._format_object_key()` derives `metaInfo`
from the `CacheEngineKey` — model identity + chunk position + a hash of the
actual token content — which is identical on any process, on any host, that
sees the same prompt prefix. Two processes that have never communicated
compute the same `metaInfo` string, and therefore (via FNV-1a) the same
12-byte on-wire key, for the same content. That agreement, not any
transmitted identifier, is what lets decode discover keys it never wrote.

By contrast, LMCache's *other* NIXL storage backend mode — the static object
pool, selected by `nixl_pool_size > 0` — names objects
`obj_{slot}_{uuid4}[#{part}]`: a pool-slot prefix plus a `uuid4` suffix
generated independently, and differently, by every process at startup. Two
processes with the same prompt produce **different** object names under this
mode, so cross-process/cross-node lookup can never succeed — this is why the
in-process path's now-removed YAML generator hard-required
`nixl_pool_size: 0` (see `docs/TODO.md` §6.23), and why that value would
need to stay `0` if this cluster were ever pointed back at
`LMCacheConnectorV1`.

## 4. Memory-tier picture

```
   GPU VRAM (MI300X, 192 GB HBM3 each)
        │  vLLM's live KV cache during the forward/decode pass. At
        │  MODEL=Qwen/Qwen2.5-72B-Instruct, TP_SIZE=8, bf16 weights are
        │  ~18 GB/GPU — deliberately small relative to the 192 GB available,
        │  so most of each GPU's HBM is free for KV cache. This is the point:
        │  a model whose whole working set fit on-GPU would never exercise
        │  the remote L2 tier below at all.
        │
        ├──── Path 1 (NixlConnector): direct GPU→GPU pull over UCX ────►
        │      decode's GPU VRAM, bypassing every tier below entirely.
        │      This is the fast, common-case path (§1.1).
        ▼
   ZMQ (loopback) to the LMCache MP daemon — a SEPARATE HOST PROCESS.
   Both L1 and L2 below are owned by the daemon, not by vLLM's own process
   (unlike the pre-consolidation in-process `LMCacheConnectorV1` design,
   where L1 lived inside vLLM itself).
        │
        ▼
   Daemon L1: pinned DRAM  ("local_cpu"-equivalent, `--l1-size-gb` =
        │      LMCACHE_MAX_LOCAL_CPU_SIZE GiB)
        │      fast, host-local, does NOT survive a daemon restart,
        │      does NOT cross nodes
        ▼
   Daemon L2 `nixl_store` adapter → KV_BACKEND plugin (XNVME_KV default |
        │      SPDK_NVMe_KV) → SMC3 NVMe-KV namespace (bdev_kvmalloc — an
        │      in-memory red-black tree bounded by KV_BDEV_MAX_KEY_SIZE /
        │      KV_BDEV_VALUE_MAX, no separate total-size RPC parameter)
        │      the ONLY tier that crosses nodes via Path 2; content-derived
        │      keys (§3, caveat noted there for the MP path specifically)
        │      are what would make it shared between prefill and decode;
        │      RAM-backed means it does NOT survive an nvmf_tgt restart
        │      either (see gap #7 in the README and
        │      scripts/target/50-reset-namespace.sh's own comment)
```

Both daemon-side tiers are consulted in order on a Path-2 lookup; a hit in
L1 never reaches the NIXL storage backend at all. But Path 1
(`NixlConnector`) is tried first on decode regardless (§1) — it is not part
of this L1/L2 hierarchy at all, and when it succeeds none of the tiers above
are touched for that request. The property the *storage tier* depends on is
specifically its L2 being shared and content-addressed; L1 is purely a
single-node cache and has no bearing on cross-node behavior either way.

## 5. Threading / async model

Both plugins share the same submit-all/poll-count design:

- **One qpair per reactor thread.** `nixlSpdkKvEngine` spawns
  `KV_NUM_QPAIRS` reactor threads at construction, each owning exactly one
  SPDK qpair (`qpairs_[i]`). A qpair is touched *only* by the reactor thread
  that owns it — never from `postXfer()`'s calling thread, never from
  another reactor. This is why the engine needs no mutex around qpair
  access: single-writer/single-reader per qpair, enforced by construction,
  not by locking.
- **`postXfer()` submits all descriptors in a batch without waiting.** Each
  descriptor becomes one heap-allocated `SpdkKvWorkEx`, dispatched (round-robin
  across reactors via `next_qpair_`) onto its owning reactor via
  `spdk_thread_send_msg`. `postXfer()` returns immediately after enqueueing
  every item in the batch; it never blocks on any single item's completion.
- **`checkXfer()` polls an atomic countdown**, not a per-item wait: each
  `nixlSpdkKvReqH` holds `std::atomic<int> pending`, decremented by the
  completion callback (`kv_store_cb_async`/`kv_retrieve_cb_async` →
  `kv_complete_cb`) for every item in the batch. `checkXfer()` returns
  `NIXL_IN_PROG` until `pending` reaches 0. `nixlbench`'s `waitXfer()` simply
  spins on `checkXfer()` — no condition variable is needed on the fast path;
  the `cv`/`mtx` members exist only for a caller that explicitly blocks.

### 5.1 `-ENOMEM` backpressure and its deadline

SPDK's submission queue can be momentarily full — `spdk_nvme_kv_store()`/
`retrieve()` returning `-ENOMEM`/`-EAGAIN` is a **retryable** condition, not a
failure, and is treated as such: the work item is pushed onto a per-reactor
deferred queue (`retry_qs_[idx]`, touched only by that reactor's own thread —
same single-owner rule as the qpairs themselves) and re-submitted on a later
loop iteration, specifically *after*
`spdk_nvme_qpair_process_completions()` in the same iteration, since draining
completions is what frees the submission-queue slots a retry needs.

This retry is deliberately bounded. Each deferred item records the steady-clock
timestamp of its *first* `-ENOMEM` (`enomem_since_ns`); if that item is still
sitting in the retry queue after `NIXL_KV_ENOMEM_TIMEOUT_SEC` (default 30s,
`config/cluster.env`'s `KV_ENOMEM_TIMEOUT_SEC`), it is failed outright rather
than retried again. Without this deadline, a permanently stalled device would
leave `pending` never reaching 0 and `checkXfer()` returning `NIXL_IN_PROG`
forever — indistinguishable from a hang. The deadline is what turns "the
device stopped draining" into a reported failure instead of a silent stall.

Backpressure is logged three times, deliberately, because any one of these
alone was found insufficient in practice: a one-shot notice the moment
backpressure first occurs (`enomem_logged_`), a periodic report throttled by
`NIXL_KV_BACKPRESSURE_LOG_SEC` while it continues (not throttled by count,
because a single large batch can defer thousands of items in well under a
second), and a final total at engine teardown. A total that only prints at
shutdown does not exist for a server process that runs for days.

## 6. Plugin comparison: `SPDK_NVMe_KV` vs `XNVME_KV`

| | `SPDK_NVMe_KV` (`plugins/nvme-kv/`) | `XNVME_KV` (`plugins/xnvme-kv/`) |
|---|---|---|
| Transport | NVMe-oF (TCP and PCIe always linked; RDMA linked **opt-in**, `-Denable_rdma=true`, default `false` and unvalidated on hardware — see README gap #1 and §7 below) via SPDK's kernel-bypass driver, embedded statically | `io_uring_cmd` against the kernel's own `nvme` char-device passthrough (`/dev/ngXnY`) — no VFIO, no DPDK, no hugepages |
| `max_value_size` default | `524288` (512 KiB) — **not** a device limit. Originally derived from the NVMe-oF/TCP transport's SGL ceiling (`nvmf_tcp_create()` rejecting `max_io_size/io_unit_size > SPDK_NVMF_MAX_SGL_ENTRIES(16)`), which is no longer the governing constraint on SPDK >=26.05 — see §7 below. The default value itself is unchanged; raising it is a deliberate experiment either way. | `32768` (32 KiB) — a **real, empirically-measured** Pensando DSC firmware limit: 32768 B stores/retrieves cleanly, 65536 B fails with NVMe completion `sct=7 sc=234` |
| Device access model | Requires the target device bound to `vfio-pci`/`uio_pci_generic`; hugepage-backed DMA memory; a KV-patched SPDK/DPDK build (`kv_spdk`) matched at build **and** run time | Kernel `nvme connect` to SMC3 creates a generic char device (`/dev/ngXnY`); no vfio-pci, no hugepages, no DPDK/SPDK version pairing — `XNVME_DEV` resolves this device at runtime by matching `NVMF_SUBNQN`, since the device index is not stable across hosts or reboots |
| Use in this cluster | **Retained, not the default.** `KV_BACKEND=SPDK_NVMe_KV` still connects to SMC3 over NVMe-oF/TCP and is fully wired end-to-end (build step, plugin, `lib.sh` arm, `--l2-adapter` spec, verify ladder) — kept as the comparison point, per `config/cluster.env`'s 2026-09-16 decision. | **The default** (`KV_BACKEND=XNVME_KV`). Also connects to SMC3 remotely, over the kernel's own NVMe-oF/TCP session — not a locally-attached device in this cluster's actual usage, despite the name; the CSI-1 kernel blocker that made this unusable on 5.15 (`unknown csi 1`, no device node) is closed on 6.8 (creates the char device, HANDOFF §10.4-§10.5), and it needs none of `SPDK_NVMe_KV`'s VFIO/hugepage/version-pairing machinery. |
| When to use which | The comparison point, or a rollback target if `XNVME_KV` regresses. | Default choice for any topology where the KV namespace lives on a remote node reached over NVMe-oF (this cluster) and the kernel is >=6.x (CSI-1 support). The plugin is also usable against a genuinely locally-attached KV device — see `xnvme_kv_backend.h`'s header comment — though that is not this cluster's configuration. |

Both plugins share the identical `queryMem()` rationale (§2.1), the identical
`make_key()` FNV-1a derivation (§3), and the identical staged-VRAM approach
(host bounce buffer via `hipMemcpy`, never direct GPU-NIC DMA — see §1).

## 7. SPDK: upstream initiator, forked target

As of SPDK v26.05 (released 2026-05-29), NVIDIA's NVMe Key-Value command-set
**initiator** support is upstream: `include/spdk/nvme_kv.h`, `lib/nvme/nvme_kv.c`,
and the full `spdk_nvme_kv_{store,retrieve,delete,exist,list}()` API —
exactly the surface `plugins/nvme-kv/` compiles against. That is the entire
reason this cluster's compute nodes (SMC1/SMC2) build a stock upstream
`SPDK_VERSION=v26.05` tree (`scripts/common/05-build-spdk-initiator.sh`,
`SPDK_INITIATOR_FLAVOR=upstream`, the default) instead of the private
kv_spdk fork — a genuine simplification versus the pre-v26.05 world, where
both roles had to share one forked tree.

**What did NOT land upstream is the target side.** There is no
`bdev_kvmalloc` (or any KV bdev) module anywhere under `module/bdev/`, and
`lib/nvmf/ctrlr_bdev.c` still dispatches only NVM command-set opcodes
(READ/WRITE/FLUSH/DSM/WRITE_ZEROES) — no KV opcode routing, and no
`SPDK_NVME_CSI_KV` constant exists to route to. `spdk_bdev_get_nvme_csi()`
was added in v26.05, but nothing upstream ever sets it to a KV CSI. A stock
v26.05 `spdk_tgt` therefore builds cleanly and simply cannot serve a KV
namespace — `scripts/target/02-build-spdk-kv.sh`'s artifact check fails on
this on purpose (`libspdk_bdev_kvmalloc.a` missing) so this is caught at
build time, not discovered as an inexplicable RPC failure later. SMC3 is
therefore the one node still built from the kv_spdk fork
(`SPDK_TARGET_FLAVOR=fork`, the default; see `config/cluster.env`'s SPDK
section and `scripts/target/02-build-spdk-kv.sh`).

**Why the boundary falls exactly at initiator-vs-target and not somewhere
else:** the plugin `plugins/nvme-kv/` implements is an NVMe-oF *initiator* —
it only ever calls the `spdk_nvme_kv_*()` client-side API, never anything
target-side. Everything that API needs is upstream. Everything the
*target's* bdev layer and nvmf dispatch need to actually export a KV
namespace over the wire is not. This is precisely why `config/cluster.env`
splits `SPDK_INITIATOR_FLAVOR` (default `upstream`) from `SPDK_TARGET_FLAVOR`
(default `fork`) as two independent variables rather than one — the two
roles are, as of v26.05, built from genuinely different trees for a
principled reason, not an arbitrary one.

**RDMA groundwork:** `lib/nvme/nvme_rdma.c` (→ `nvme_rdma.o` in
`libspdk_nvme.a`, conditional on the tree being configured `--with-rdma`) is
also upstream and part of the initiator surface. `plugins/nvme-kv/prepare-spdk-libs.sh`
splits `nvme_rdma.o` into `libspdk_nvme_rdma_only.a` whenever it's present in
the built archive (a clean no-op otherwise), and `meson.build`'s
`-Denable_rdma` option (default `false`) adds that archive to the same
`--whole-archive` group TCP/PCIe are already in, plus `-lrdmacm -libverbs`.
This is implemented and builds; it has not been exercised end to end — see
`docs/BRINGUP.md` §9.1 for exactly what remains.

**What now governs the value-size ceiling:** SPDK v26.05 deprecated
`io_unit_size`, `buf-cache-size`, and `num-shared-buffers` in
`nvmf_create_transport` to no-ops; the transport now sizes its buffers from
the iobuf pool (`iobuf-small-cache-size`/`iobuf-large-cache-size` — see
`NVMF_IOBUF_SMALL_CACHE_SIZE`/`NVMF_IOBUF_LARGE_CACHE_SIZE` in
`config/cluster.env`) instead. The `max_io_size / io_unit_size <=
SPDK_NVMF_MAX_SGL_ENTRIES(16)` rule that originally justified
`KV_MAX_VALUE_SIZE=524288` (§6 above) is therefore no longer the governing
constraint on `>=26.05` — `scripts/target/lib-kv-rpc.sh`'s
`kv_target_check_sgl()` still computes and logs the ratio on every version,
but only `die()`s on a bad ratio pre-26.05; on `>=26.05` it `warn()`s instead,
since the ratio may or may not still matter on a given tree. This does
**not** mean `KV_MAX_VALUE_SIZE` is now free to raise casually: it remains
the validated default regardless of which rule technically enforces it, and
changing it is still an experiment requiring a namespace drain
(`scripts/target/50-reset-namespace.sh`) and a re-run of
`scripts/verify/30-verify-kv-roundtrip.sh` with a larger payload to prove the
new ceiling actually round-trips.
