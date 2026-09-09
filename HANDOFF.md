# HANDOFF — 2026-09-09

**The stack works.** The KV corruption that blocked everything is fixed and shipped in an image;
single-node store/retrieve is verified and measured; P+D disaggregation runs end to end across two
hosts. None of that was true at the start of the day.

This document replaces the four earlier passes. Everything below has been executed, not inferred —
where something is reasoning rather than measurement, it says so.

**Hostnames are placeholders**, per this repo's convention. Real IPs, credentials, MACs and the
Setup-3 operational block are in `lab/lab-inventory.local.md` and `lab/lab-inventory.local.env`
(gitignored, never committed, never synced). Read those first.

Branch `rocm-aic`, **not pushed**. The remote GPU-node tree is a plain copy kept in sync by
`rsync --files-from=<(git ls-files)`; it is not a git repo.

---

## Current state

| | |
|---|---|
| KV correctness | ✅ fixed by `patches/0009`, in `rocm-aic:kv-planefix` |
| Single-node store → restart → retrieve | ✅ verified repeatedly (needle recovered, `need to load: 1024`) |
| KV-path benchmark | ✅ first valid one taken: **2.40x** faster than recompute at c=1 |
| **P+D across two hosts** | ✅ **verified end to end**, 4/4 needles through the proxy |
| P+D on a real model | ❌ never run — everything here is TinyLlama-1.1B |
| P+D under concurrency | ❌ never measured |
| `patches/0009` upstreamed | ❌ still carried out-of-tree |

### What is deployed

All containers on `rocm-aic:kv-planefix`. Runtime config and logs are host-local under
`AIC_RUNTIME_DIR` (`/var/tmp/aic-$(id -u)`); nothing mounts the NFS home any more.

| node | container | port | GPU | backend |
|---|---|---|---|---|
| `<SETUP3_PREFILL_NODE>` | `aic-spdk-planefix` | 8303 | 0 | dynamic (single-node bench instance) |
| `<SETUP3_PREFILL_NODE>` | `aic-spdk-producer` | 8301 | 1 | dynamic, `store_location` only |
| `<SETUP3_PREFILL_NODE>` | `proxy.py` | 9000 | — | started via `/var/tmp/start_pd_proxy.sh` |
| `<SETUP3_DECODE_NODE>` | `aic-spdk-receiver` | 8301 | 0 | dynamic, `retrieve_locations` only |
| `<SETUP3_DECODE_NODE>` | `aic-spdk-single` | 8302 | 1 | **static** — cannot read back, see OPEN-6 |
| `<SETUP3_TARGET_NODE>` | SPDK NVMe-KV target | 4420 | — | RAM-backed, holds pre-fix poison + post-fix data |

The two single-node instances and the P+D pair coexist on different GPUs and ports.

---

## OPEN ITEMS

Ordered by what I would do next.

### OPEN-1 — Run P+D on a real model *(high)*

P+D is proven **correct**, not proven **worthwhile**. TinyLlama-1.1B's prefill is so cheap that
disaggregation cannot pay for itself — it is also why the single-node benchmark is only 2.40x.
Nothing about the value of this architecture has been demonstrated.

Both roles must use the same `MODEL` **and** the same `TENSOR_PARALLEL_SIZE`: the KV chunk layout
depends on TP, so a mismatch makes the stored cache unreadable to the other side. `Qwen2.5-72B` at
TP=8 needs all 8 GPUs per node, so the single-node instances must come down first.

### OPEN-2 — Measure P+D, don't just run it *(high)*

No latency or throughput number has been taken through the proxy. Note the proxy is **sequential** —
it calls prefill with `max_tokens=1`, discards the response, then streams from decode — so
end-to-end latency is both legs. The win has to come from freeing the decode host from prefill work,
which only appears under **concurrent** load. A single-request measurement will look like a loss and
that would be a misreading, not a result.

### OPEN-3 — Upstream `patches/0009` to LMCache *(high)*

This is an **upstream defect, not a rocm-aic one**, and it silently corrupts every KV chunk on this
path for any vLLM 0.26 fused-cache deployment — not just ours. We carry a fix; upstream does not
have one. `VLLMPagedMemGPUConnectorV3.get_shape()` (`raise NotImplementedError`) should probably be
part of that conversation too.

### OPEN-4 — Upstream the probe fixes *(medium)*

`--seed-base` exists only in `/var/tmp/kvbench/kv_offload_bench_seeded.py` on the prefill node. I did
not edit the shared `bench/` tree unasked. Until it lands, **every repeat run of
`bench/kv-spillover-probe` silently measures retrieval in its own STORE phase**. Its stock defaults
also overflow TinyLlama's 2048 context by exactly one token (2017 prompt + 32 output), so every
request 400s; `--sentence-repeats 34` fits.

Its README's "Known status (2026-08-12): RETRIEVE never reaches the backend" should be revisited —
that is very likely the prefix-cache masking described in "Benchmarking" below, not a backend bug.

### OPEN-5 — Purge the pre-fix poison from the target *(medium)*

Every chunk written before `patches/0009` is half-empty and mis-strided. Keys are content-derived,
so this is only reachable by replaying a pre-fix prompt — it does **not** corrupt new work — but it
will mislead anyone who re-runs an old prompt. The RAM-backed target clears on restart. It is shared
with the decode node, so restarting it is not a private action.

### OPEN-6 — Decide what the static single-node instance is for *(medium)*

`aic-spdk-single` :8302 is still deliberately on the static backend. Static **cannot serve a
cross-process or cross-restart hit** — `NixlObjectPool` names slots `obj_{i}_{uuid4()}`
(`nixl_storage_backend.py:383`), a fresh uuid per process. It stores and never reads. It is not a
control and never was; keep it only if something needs a store-only instance, otherwise redeploy it
with `AIC_KV_POOL=0` or remove it.

### OPEN-7 — Housekeeping *(low)*

- Delete the now-unused `vendor/rocm-aic/pd-configs/` and `logs/` trees on the NFS home. Nothing
  mounts them since both nodes moved to `AIC_RUNTIME_DIR`.
- `NIXL_KV_DEBUG_XFER` instrumentation (`784ad64`) stays in the tree — inert when unset, and it is
  what found the bug. Keep.
- Setup-3 BMC addresses were never captured; the `reg` entries carry `''`.
- `use_layerwise` is a landmine: `VLLMPagedMemGPUConnectorV3.get_shape()` raises
  `NotImplementedError` and `store_layer` (`cache_engine.py:683`) is its only caller.

---

## The fix — `patches/0009-lmcache-fused-kv-plane-count.patch`

**LMCache built a 2-plane split staging destination for vLLM 0.26's 1-plane fused KV cache.** The
copy kernel derives its source stride from that destination shape, so it read at half the correct
per-token stride: half the tokens, from the wrong offsets, with the V plane never written at all.
Byte totals coincide (`2*NH*HS == 1*NH*2*HS`), so nothing downstream ever complained.

The shape is built at engine init, before any KV tensor exists, so the runtime format detector
cannot be consulted — that constraint is real, and it is what defeats the `use_gpu_connector_v3`
workaround. But vLLM's **attention backend** can answer at init and does so authoritatively:

```
rocm-aic: attention backend TRITON_ATTN reports kv_cache_shape=(8, 4, 16, 128)
  -> kv_plane_count=1, per_head_width=128 (the unpatched assumption would have been (2, 64))
```

rank 4 → fused (`kv_size=1`, width `2*head_size`); rank 5 with leading 2 → split; rank 3 → MLA;
anything else falls back to the old assumption with a warning. The query runs inside
`set_current_vllm_config(...)` — without it `get_attn_backend` raises in the **scheduler** role and
succeeds in the **worker**, which would leave the two halves of one deployment disagreeing about
layout. The result is cross-checked against the real tensors in `_initialize_pointers()` and
**raises** on disagreement, because a mismatch is otherwise undetectable.

After: `kv shape: (22, 1, 256, 4, 128)`, allocator and NIXL read layout both `[1, 22, 256, 512]`.

### Two corrections to earlier passes

- The origin is **`integration/vllm/vllm_service_factory.py:103`**, not `integration/vllm/utils.py:278`.
  The latter is real but sits in `create_lmcache_metadata()`, whose only caller is the EC adapter,
  which this deployment does not use. A probe inserted there never fired.
- `use_gpu_connector_v3: True` **does not work**. It is accepted, V3 really is dispatched (confirmed
  by name), and the shape stays 2-plane, because `kv_layer_groups_manager` is populated lazily inside
  `_initialize_kv_cache_pointers()` while the allocator and the NIXL read layout are both bound
  before that and take the `None` fallback.

---

## P+D — and why the documented recipe moved no KV

Verified across two hosts: producer stores, receiver loads, 4/4 needles correct through the proxy.

```
producer:  Total tokens 1091, computed 0, LMCache hit tokens: 0,    need to load: 0      <- stores
receiver:  Total tokens 1091, computed 0, LMCache hit tokens: 1024, need to load: 1024   <- loads
```

**P/D requires `AIC_KV_POOL=0` on both roles.** The README used to prescribe the static default with
differing `AIC_SPDK_KV_SLOT_OFFSET`. That was deployed verbatim and measured:

```
receiver: Total tokens 1089, computed 0, LMCache hit tokens: 0, need to load: 0
```

No KV crossed; the receiver silently re-prefilled — **and still returned the correct needle**. A P/D
pair built from the old instructions was an expensive illusion.

Two reasons: static object names carry a per-process `uuid4`, so the receiver can never derive the
producer's keys; and the slot-offset advice is **inert** on this path (`make_key()` derives from
`metaInfo` and ignores `devId` whenever `metaInfo` is set, which LMCache always does in OBJ mode)
while, taken literally, pointing the roles at *different* key spaces.

`deploy.sh` now defaults `AIC_KV_POOL=0` when `PD_ROLE` is set and **refuses** a non-zero pool
(`AIC_ALLOW_STATIC_PD=1` overrides). Both paths tested: the refusal exits 1 and leaves the running
container untouched; with no `AIC_KV_POOL` passed at all, P/D comes up dynamic.

**The only check that separates a working pair from the illusion is `need to load` on the
receiver.** Output correctness cannot — both configurations answer correctly.

---

## Benchmarking — what makes a number real here

Result: `kv-bench/results/<prefill-host>/2026-09-09-kv-spillover-probe/RESULT.md` on the prefill node.

| concurrency | store (cold) | retrieve (from target) | change |
|---|---|---|---|
| 1 | 152.6 ± 28.8 ms | **63.5 ± 3.2 ms** | **2.40x faster** |
| 4 | 289.9 ± 32.2 ms | 274.3 ± 29.3 ms | 1.06x faster |

**Use `bench/kv-spillover-probe`, not `bench/llama-benchy`.** The throughput profile says so in its
own caveat: llama-benchy draws fresh content per cell and never exercises store/retrieve.

Three traps, each of which silently produces a plausible but meaningless number. All three were hit
in this session.

1. **vLLM prefix caching must be off.** It defaults on and the GPU KV cache here is **8,285,648
   tokens**, so vLLM answers every repeat itself and LMCache is never consulted. The probe's EVICT
   phase (~20k tokens) is 0.2% of that and cannot evict it. Deploy with
   `VLLM_EXTRA_ARGS="--no-enable-prefix-caching"`.
2. **Every probe run needs fresh seeds.** The backend is persistent, so a repeat run measures
   retrieval in its own STORE phase. **Varying `--sentence-repeats` does not help** — `sentence * N`
   is a strict prefix of `sentence * (N+1)` and chunk keys are prefix-derived, so it only rekeys the
   final chunk. Same prefix-keying trap as the needle test.
3. **Always run the server-side cross-check.** The accepted run predicted and matched exactly:
   `cold (need to load == 0): 40`, `warm (> 0): 16`. Discarded runs that failed it: one showing store
   and retrieve identical (152 vs 153 ms), one showing a flattering 2887 vs 255 ms "11x" that did not
   reproduce.

**On the probe's greedy-decode mismatches (1/8 at c=1, 4/8 at c=4):** not corruption. Both sides are
fluent English sharing a 66–91 character prefix before diverging into an equally plausible
continuation, the direction varies, and mismatches rise with concurrency — batch-composition
near-ties on a prompt that is one sentence repeated 34 times. Pre-fix corruption looked nothing like
it (`29.\n\n209.comaparticular, and a/heydatabase.`). The discriminative check is the needle test.

### Test methodology that still holds

- **Restart between store and retrieve, or disable prefix caching** — otherwise vLLM serves the
  repeat itself.
- **Check all three numbers**, not just one. `need to load: 0` *with* `computed 0` and `hit 0` is a
  full cold recompute, not a cache hit — that misreading is what produced the original "static
  backend verified" claim.
- **Prompts shorter than `chunk_size` (256 tokens) are never stored.** Use ≥800 words.
- **Chunk keys are prefix-derived.** To force a cold store, change the **beginning** of the prompt.
- **Append `\nAnswer:`** to the needle prompt or TinyLlama emits EOS immediately
  (`completion_tokens: 1`) and an empty answer looks like corruption.
- **Match on `Total tokens`** before trusting a log line is yours; another user may share the endpoint.

---

## Infrastructure traps

**The lab home is one NFS export shared by every Setup-3 node — same inode on all of them.** This is
not a detail: `CONFIG_DIR` and `LOG_SUBDIR` used to derive from `ROCM_AIC_DIR`, so a deploy on one
node rewrote the LMCache config bind-mounted into a live container on another. `INSTANCE` could not
help — both nodes default to the same value. Fixed: `AIC_RUNTIME_DIR` (`/var/tmp/aic-$(id -u)`) owns
both, and `deploy.sh` refuses a shared filesystem (`AIC_ALLOW_SHARED_CONFIG=1` overrides). The guard
runs **before** the `docker rm -f` — a guard that refuses after destroying the container is worse
than none, which is how it was first written.

Symptom to recognise: `cat /etc/lmcache/config.yaml` inside the container returning **`Stale file
handle`** means the inode was replaced underneath a live bind mount. The process is unaffected (it
read its config at startup) but a restart adopts the other deployment's config.

Other traps, each of which cost time:

- **`HF_HOME` must not be the NFS home.** `docker run` cannot create it there, and the deploy dies
  *after* writing its config. Pass `HF_HOME=/var/tmp/hf`.
- **Never run `deploy.sh` under `sudo` on an NFS home** — `root_squash` maps root to `nobody` and it
  dies on its own `mkdir`. Pre-allocate hugepages once with sudo instead.
- **`pkill -f "proxy.py --host"` kills your own shell** — the pattern matches the SSH command string.
  Match `"[p]roxy"`. This happened.
- **Same tag ≠ same image, and same image ≠ same ID.** The decode node had its own unrelated
  `rocm-aic:latest`; always move and deploy by explicit tag. `docker save | ssh docker load` gives
  byte-identical content a *different* image ID (`ce7c3279` vs `84eeb9b4`) — verify by `md5` of files
  **inside** the image. The nodes can ssh each other directly, so 43 GB needs no workstation in the
  path.
- **`ROCM_ARCH` is required even with `SKIP_BUILD=1`.**
- **Deployment records** land in `${XDG_RUNTIME_DIR}/kv-cache-bench/` when the deploy runs non-root,
  not `/run/kv-cache-bench/`.

### Rebuilding

`ROCM_ARCH=gfx942 bash build.sh` picks up `patches/0009` automatically (staged as
`patches/lmcache/18-…`). It took ~10 minutes with a warm layer cache, not the ~90 the header quotes.

Pre-flight before spending a build — about two minutes, and it catches a failure that otherwise
surfaces an hour in: `git apply --check` the patch against a pristine `LMCache v0.5.3` clone, confirm
the files it touches are unchanged from what it was written against, and replay the **whole** patch
series in the Dockerfile's lexical order against a scratch clone.

---

## Commits (this branch, not pushed)

```
3296a4b  Run P+D end to end, and correct a recipe that moved no KV
4f922ce  Take the first valid KV-path benchmark on the Austin cluster
2fd74e1  Redeploy the decode node onto the fix and host-local runtime paths
99beb28  Move per-host runtime state off the shared filesystem
72d1ce8  Build the plane-count fix into an image and redeploy on it
a7fc3b1  Fix the KV corruption: derive the K/V plane count instead of assuming 2
f2be5ce  Rule out use_gpu_connector_v3, and repair the decode node's config
bdd5511  Pin the root cause: a 2-plane destination for a 1-plane fused KV cache
610067d  Stop deploy.sh from destroying a co-resident in-process deployment
784ad64  Instrument the NIXL descriptor and completion paths, and relocate the bug
```
