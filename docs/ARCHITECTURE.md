# Architecture

This document explains *why* the cluster is built the way it is, not just
how to run it (see [`BRINGUP.md`](BRINGUP.md) for that). Read
[`../README.md`](../README.md) first for the topology and the one-page
picture.

## 1. Why storage-mediated, not peer-to-peer

The obvious design for P/D disaggregation is prefill pushing its KV blocks
directly into decode's GPU memory. This cluster does not do that, for one
concrete reason: `plugins/nvme-kv/spdk_nvme_kv_backend.h` declares

```cpp
bool supportsRemote() const override { return false; }
```

`SPDK_NVMe_KV` (and its sibling `XNVME_KV`) are **storage** backends in
NIXL's model, not **transfer** backends. A storage backend's contract is
STORE/RETRIEVE/(queryMem) against an addressable namespace, not "move these
bytes into a peer agent's registered memory region." Building genuine
GPU-to-GPU peer transport was evaluated and explicitly rejected for this
hardware: `spdk_nvme_kv_backend.h`'s own header comment notes the GPU and the
data-plane NIC sit on different NUMA nodes/CPU sockets on these hosts, so
true peer-to-peer DMA between them isn't a worthwhile investment — every
VRAM-side transfer already bounces through a host staging buffer
(`spdk_zmalloc()` + `hipHostRegister()`, `hipMemcpy` in and out) rather than
attempting a direct GPU-NIC DMA path.

Given that, the only two shapes available are: prefill and decode maintain a
*direct* NIXL/UCX channel and one side pushes/pulls raw bytes through it
(true P2P, ruled out above), or both sides talk to a *third* addressable
store and rendezvous there. This cluster does the second: SMC3 is that
third store. `KV_TRANSPORT` still governs a genuinely direct NIXL/UCX
channel between SMC1 and SMC2 — the **compute leg** — but that channel
carries `LMCacheConnectorV1`'s own handshake/rendezvous protocol, not KV
bytes; the KV bytes themselves only ever move over the **storage leg**,
through SMC3.

## 2. Full KV lifecycle for one request

Numbers below correspond to `LMCACHE_CHUNK_SIZE=256` (tokens per LMCache
"page") and `KV_MAX_VALUE_SIZE=524288` (the plugin's advertised per-transfer
ceiling), both from `config/cluster.env`. The default `MODEL` is
`Qwen/Qwen2.5-72B-Instruct` at `TP_SIZE=8` — a page's actual byte size scales
with the model's layer count/hidden size/KV-head count (not recomputed here
for this model specifically), but the invariant this section depends on
holds regardless: a KV page is normally larger than `KV_MAX_VALUE_SIZE`,
which is what makes the multipart split in step 4 load-bearing rather than
incidental.

**Prefill side (STORE):**

1. vLLM (SMC1) runs the prompt forward pass; per-layer, per-block KV tensors
   land in GPU memory as usual.
2. `LMCacheConnectorV1` (vLLM's connector plugin) hands completed KV blocks
   to LMCache. LMCache groups tokens into pages of `LMCACHE_CHUNK_SIZE=256`
   tokens — several MB per page for `Qwen2.5-72B-Instruct`'s KV shape at
   `TP_SIZE=8` (larger than an 8B-class model's, given its layer count and
   hidden size; the exact byte count is not derived here — see the note at
   the top of this section).
3. LMCache's `NixlDynamicStorageBackend` (selected by `nixl_pool_size: 0` —
   see §3) computes a content-derived key for the page (`CacheEngineKey`:
   model identity + chunk position + token-content hash) and calls into the
   NIXL storage backend with that key as `metaInfo`.
4. Because the page (several MB) exceeds `KV_MAX_VALUE_SIZE` (512 KiB), the
   LMCache-side multipart split (the second half of the
   `patches/lmcache/` patch family — see that README's "multipart-split"
   section) chops it into `ceil(page_size / KV_MAX_VALUE_SIZE)` sub-transfers,
   each carrying its own `metaInfo` suffixed `#{part}` (mirrored exactly by
   `plugins/nvme-kv/spdk_nvme_kv_backend.h`'s `make_key()` comment and by
   `scripts/verify/_kv_roundtrip.py`'s `chunk_meta_infos()`).
5. Each sub-transfer becomes one NIXL descriptor. `nixlSpdkKvEngine::registerMem()`
   captures the descriptor's `metaInfo`; `postXfer()` derives the 12-byte
   on-wire key via `make_key()` — two independently-seeded FNV-1a hashes over
   `metaInfo` (see §4) — and heap-allocates one `SpdkKvWorkEx` per descriptor.
6. `postXfer()` submits **all** work items in the batch without waiting
   (`spdk_nvme_kv_store()` over the SPDK qpair), then returns; it does not
   block per-item.
7. The SPDK qpair carries the request over NVMe-oF/TCP (Phase 1) to SMC3's
   `spdk_tgt`, which writes it into the RAM-backed `bdev_kvmalloc` namespace
   (`KV_BDEV_NAME`, sized `KV_BDEV_SIZE_GB`).
8. `checkXfer()` polls an atomic pending counter per request handle; it
   returns `NIXL_IN_PROG` until every sub-transfer's completion callback has
   fired, then `NIXL_SUCCESS` (or a failure state — see §5).

**Decode side (RETRIEVE), for a request whose prompt matches or shares a
prefix with something prefill already stored:**

1. `LMCacheConnectorV1` on SMC2 computes the identical content-derived key
   for each candidate chunk — same model identity, same chunk position, same
   token-content hash, because both sides derive it from prompt content, not
   from anything transmitted between the processes.
2. Before issuing any RETRIEVE, LMCache calls the NIXL storage backend's
   existence probe. `nixlSpdkKvEngine::queryMem()` issues an NVMe KV *Exist*
   command per candidate key and reports `nixl_query_resp_t` engaged/`nullopt`
   per key — this is the call whose *absence* was the cluster's first
   recorded production bug (see §2.1).
3. For every key the probe confirms exists, LMCache issues a RETRIEVE the
   same way STORE was issued (multipart, one NIXL descriptor per
   `KV_MAX_VALUE_SIZE`-sized sub-transfer, same `metaInfo` derivation).
4. `postXfer()`/`checkXfer()` follow the identical async submit-all/poll-count
   pattern as the write side.
5. Reassembled KV pages are handed back to vLLM's model runner, which skips
   recomputing the corresponding portion of the prefill forward pass.

### 2.1 The `queryMem()` incident (canonical failure signature)

Before `queryMem()` existed, NIXL's base `nixlBackendEngine` answered every
existence query with `NIXL_ERR_NOT_SUPPORTED`. LMCache's
`NixlDynamicStorageBackend` — the *only* LMCache storage backend whose keys
are content-derived rather than carrying a per-process `uuid4` (see §3), and
therefore the only one that can support cross-node P/D sharing at all —
treated that as "every key is a miss," unconditionally. Prefill's STOREs
still succeeded (writes don't need an existence probe); decode's RETRIEVE
path never even tried, because its own lookup logic short-circuited on the
probe result. Observed 2026-09-07 as `LMCache hit tokens: 0` on every single
decode request — this is the canonical P/D failure signature for this
cluster, and the reason `queryMem()`'s doc comment in
`plugins/nvme-kv/spdk_nvme_kv_backend.h` (lines ~233-250) is as detailed as it
is. `scripts/verify/30-verify-kv-roundtrip.sh` and `40-verify-disagg.sh` both
exist specifically to catch a regression of this exact bug before it reaches
a live serving test.

## 3. Key-derivation scheme

`plugins/nvme-kv/spdk_nvme_kv_backend.h`'s `make_key()` derives a 12-byte
on-wire NVMe-KV key one of two ways, selected by whether the caller set
`nixlBlobDesc::metaInfo`:

- **`metaInfo` set** (LMCache's `NixlDynamicStorageAgent`, always sets it):
  two independently-seeded 64-bit FNV-1a hashes over the `metaInfo` string —
  `h1 = fnv1a64(metaInfo, 14695981039346656037ULL)` (the FNV offset basis)
  into the low 8 key bytes, `h2 = fnv1a64(metaInfo, 0x9E3779B97F4A7C15ULL)`
  (a different, arbitrary seed) truncated to 4 bytes into the high 4 key
  bytes. FNV-1a was chosen over `std::hash` specifically because the on-wire
  key must be reproducible **across processes, hosts, and rebuilds** —
  `std::hash`'s implementation is only guaranteed stable within a single
  process/build, which is not a contract two independent agents (prefill,
  decode) can rely on agreeing on.
- **`metaInfo` empty** (callers that never set it — `kv_io.py`, `nixlbench`):
  falls back to 8 bytes of `devId` + the low 4 bytes of `addr`. This is a
  storage-pool slot index allocated independently by each caller's
  `NixlObjPool`, starting from 0 — which is exactly why two independent
  deployments sharing a namespace on this path collide on their early slot
  indices unless given disjoint `KV_SLOT_OFFSET_PREFILL`/`KV_SLOT_OFFSET_DECODE`
  values (`config/cluster.env`).

**Why the `metaInfo` path is what makes cross-deployment sharing safe:**
LMCache's `NixlDynamicStorageAgent._format_object_key()` derives `metaInfo`
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
mode, so cross-process/cross-node lookup can never succeed — this is why
`scripts/common/gen-lmcache-config.sh` hard-requires `nixl_pool_size: 0` (see
that script's "THE CONTENT-DERIVED-KEY CONSTRAINT" section) and why
`LMCACHE_NIXL_POOL_SIZE` should never be changed away from `0` on this
cluster.

## 4. Memory-tier picture

```
   GPU VRAM (MI300X, 192 GB HBM3 each)
        │  vLLM's live KV cache during the forward/decode pass. At
        │  MODEL=Qwen/Qwen2.5-72B-Instruct, TP_SIZE=8, bf16 weights are
        │  ~18 GB/GPU — deliberately small relative to the 192 GB available,
        │  so most of each GPU's HBM is free for KV cache. This is the point:
        │  a model whose whole working set fit on-GPU would never exercise
        │  the remote L2 tier below at all.
        ▼
   LMCache CPU DRAM  (L1 — "local_cpu", LMCACHE_MAX_LOCAL_CPU_SIZE GiB)
        │  fast, host-local, does NOT survive a process restart,
        │  does NOT cross nodes
        ▼
   SMC3 NVMe-KV namespace  (L2 — bdev_kvmalloc, KV_BDEV_SIZE_GB, RAM-backed)
        │  the ONLY tier that crosses nodes; content-derived keys make it
        │  shared between prefill and decode; RAM-backed means it does NOT
        │  survive an spdk_tgt restart either (see gap #7 in the README and
        │  scripts/target/50-reset-namespace.sh's own comment)
```

Both LMCache tiers are consulted in order on a lookup; a hit in L1 never
reaches the NIXL storage backend at all. The property this cluster's P/D
disaggregation depends on is specifically the L2 tier being shared and
content-addressed — L1 is purely a single-node cache and has no bearing on
cross-node behavior.

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
| Device access model | Requires the target device bound to `vfio-pci`/`uio_pci_generic`; hugepage-backed DMA memory; a KV-patched SPDK/DPDK build (`kv_spdk`) matched at build **and** run time | Requires the device bound to the kernel's stock `nvme` driver (`modprobe nvme`), exposing a generic char device; no VFIO group, no SPDK version pairing |
| Use in this cluster | **Yes** — this is the storage-leg backend against SMC3 over NVMe-oF | **No** — this cluster's storage is remote (SMC3 over the network), not a locally-attached KV device; kept for local-device testing and as the empirical basis for the `max_value_size` comparison above |
| When to use which | Any topology where the KV namespace lives on a remote node reached over NVMe-oF (this cluster) | A topology where the KV device is physically attached to the same host running vLLM, and Docker/VFIO DMA-mapping reliability for the admin queue is a concern (see `xnvme_kv_backend.h`'s header comment) |

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
