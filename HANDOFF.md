# HANDOFF — 2026-09-09 (end of session 2)

**The stack is correct. It is also, as built, not worth running.**

Everything works: the KV corruption is fixed, P+D runs across two hosts on a real 72B model, and
the upstream fix that supersedes ours is validated on this hardware. Then it was measured, and both
value propositions failed — disaggregation loses to simply not disaggregating, and KV reuse ties
with recomputing from scratch.

One number explains both: **the KV transfer path sustains ~20% of line rate.** Fix that and the
reuse case turns into a 4.7x win. That is the whole job now; everything else here is context.

This document replaces the previous pass. Everything below was executed, not inferred — where
something is reasoning rather than measurement, it says so.

**Hostnames are placeholders**, per this repo's convention. Real IPs, credentials and MACs are in
`lab/lab-inventory.local.md` and `lab/lab-inventory.local.env` (gitignored, never committed, never
synced). Read those first.

Branch `rocm-aic`, **pushed** to `origin` (`llm-stacks`). History was scrubbed of two real
identifiers on 2026-09-09 — see "Repo hygiene". The remote GPU-node trees are plain copies kept in
sync by `rsync --files-from=<(git ls-files)`; they are not git repos.

> **Policy: nothing in this repo writes to an external repository.** No comments, no issues, no
> PRs, no pushes anywhere but `origin`. Where an upstream action is needed, the text is prepared
> here and **a human posts it**. Do not resolve this by widening a token.

---

## Current state

| | |
|---|---|
| KV correctness | ✅ fixed — ours (`patches/0009`) and upstream's (LMCache #4467) both verified |
| Single-node store → restart → retrieve | ✅ verified repeatedly, V2 **and** V3 |
| **P+D across two hosts, real model** | ✅ Qwen2.5-72B TP=4, 4/4 needles, `need to load: 1152` |
| **P+D throughput** | ⚠️ **LOSES**: 0.17–0.41x an aggregated node, on 2x the GPUs → OPEN-1 |
| **KV reuse (cache) throughput** | ⚠️ **dead heat** vs recompute, with the cache confirmed hit → OPEN-2 |
| **Root cause of both** | 🔎 **KV path = 617 MB/s on a 25 Gb/s link (~20%)**. At line rate reuse wins **4.7x** → OPEN-3 |
| LMCache PR #4467 on MI300X | ✅ validated end-to-end; supersedes `patches/0009` |
| #4467 merged upstream | ❌ open since 2026-08-09; **a human still has to post our validation** → OPEN-4 |

### What is deployed

Verified at end of session. Runtime config and logs are host-local under `AIC_RUNTIME_DIR`
(`/var/tmp/aic-$(id -u)`); nothing mounts the NFS home.

| node | container | port | GPU | model / role |
|---|---|---|---|---|
| `<SETUP3_PREFILL_NODE>` | `aic-spdk-planefix` | 8303 | 0 | TinyLlama, single-node bench |
| `<SETUP3_PREFILL_NODE>` | `aic-spdk-producer` | 8301 | 1 | TinyLlama, P/D producer |
| `<SETUP3_PREFILL_NODE>` | `aic-spdk-pr4467` | 8305 | 6 | TinyLlama on `rocm-aic:pr4467`, **V3 enabled** |
| `<SETUP3_PREFILL_NODE>` | `proxy.py` | 9000 | — | fronts the TinyLlama P/D pair |
| `<SETUP3_DECODE_NODE>` | `aic-spdk-receiver` | 8301 | 0 | TinyLlama, P/D receiver |
| `<SETUP3_DECODE_NODE>` | `aic-spdk-single` | 8302 | 1 | **static** — cannot read back, see OPEN-6 |
| `<SETUP3_DECODE_NODE>` | **`aic-spdk-reuse72`** | **8402** | **2,3,4,5** | **Qwen2.5-72B TP=4, `kv_both` — the measurement rig** |
| `<SETUP3_TARGET_NODE>` | SPDK NVMe-KV target | 4420 | — | RAM-backed, 3 TB, ~2.5 TB free |

Free: prefill cards **2,3,4,5,7**; decode cards **6,7**.

**The TinyLlama pair on 9000 is the control.** Re-verified 4/4 after every step this session; it is
how you tell "the stack regressed" from "my config is wrong" without a teardown. Keep it.

**The 72B P/D pair no longer exists.** `receiver72` was replaced by `reuse72` (they contend for the
same decode GPUs), so `producer72` and proxy 9001 were removed rather than left dangling. The P/D
measurement is recorded in OPEN-1; rebuild from README Step 5–7 if it is needed again.

---

## OPEN ITEMS

Ordered by what I would do next.

### OPEN-1 — ANSWERED: P+D disaggregation loses *(closed)*

Qwen2.5-72B TP=4, ~3940-token prompts, unique prefixes, 8 requests/level.

| concurrency | disaggregated (8 GPUs) | aggregated, one node (4 GPUs) | ratio |
|---|---|---|---|
| 1 | 0.062 req/s · 16.1 s | 0.153 req/s · 6.5 s | **0.41x** |
| 4 | 0.087 req/s · 42.2 s | 0.506 req/s · 7.9 s | **0.17x** |
| 8 | 0.147 req/s · 43.2 s | 0.692 req/s · 11.3 s | **0.21x** |

2.4–5.8x slower on twice the GPUs (5–12x worse per GPU), and it scales worse under load: 2.36x from
c=1→c=8 against the aggregated instance's 4.52x.

**The concurrency argument did not save it.** This item was written predicting that a single-request
measurement would look like a loss and that only concurrency would show the win. Concurrency was
measured and the gap *widens*.

Mechanically: a one-shot handoff moves the entire KV over the wire (~1.2 GB/request as ~120 objects)
and the proxy is sequential, so store and load both sit on the critical path. The aggregated
instance keeps that KV in HBM and batches concurrent requests in one engine.

Both arms were verified from the receiver's log — 24 requests at `need to load: 3840`, 24 at
`hit 0, need to load: 0`. Without that this is indistinguishable from a silent re-prefill.

### OPEN-2 — ANSWERED: KV reuse ties with recompute *(closed)*

Single `kv_both` 72B (`reuse72`), shared 3840-token prefix vs unique prefix, vLLM prefix caching off.

| concurrency | unique prefix (recompute) | shared prefix (cache hit) |
|---|---|---|
| 1 | 0.120 req/s · 8.31 s | 0.118 req/s · 8.45 s |
| 4 | 0.253 req/s · 15.74 s | 0.285 req/s · 14.02 s |
| 8 | 0.332 req/s · 23.78 s | 0.341 req/s · 23.48 s |

**A dead heat, with the cache genuinely hit** — 24/24 at `hit 3840, need to load: 3840`. Reuse
fetched the KV and bought nothing. This is not the silent-re-prefill failure mode in disguise.

Isolating decode with an 81-token prompt at the same `max_tokens=32` gives **6.41 s**, which is what
makes it legible:

| | |
|---|---|
| KV per request (3840 tok × 320 KiB) | **1.26 GB** |
| Prefill 3840 tokens (8.31 − 6.41) | **1.90 s** |
| KV load, same tokens (8.45 − 6.41) | **2.04 s** → **617 MB/s** |
| Link, decode → target (`ens50f0`) | 25 Gb/s = **3125 MB/s** |
| **Path efficiency** | **~20% of line rate** |
| Decode share of request latency | **76%** |

Caveat: decode was isolated at 81 tokens of context and costs slightly more at 3840, so 1.90 and
2.04 are mild over-estimates that move together. Treat them as "roughly 2 s each".

**No contradiction with the old 2.40x**, which was TinyLlama — 22 KiB/token, ~22 MB per 1024 tokens,
small enough that even a 20%-of-line-rate path beat recompute. 72B multiplied KV volume ~55x while
MI300X prefill stayed fast; the storage path did not scale with it.

### OPEN-3 — Fix the KV transfer path, then re-measure *(HIGH — this is the job)*

At line rate, 1.26 GB lands in **0.40 s** against a **1.90 s** recompute: a **4.7x win**. Roughly 5x
of software headroom stands between here and that. Ordered by the root cause, not by guesswork:

1. **Drop `--enforce-eager` first.** 76% of request latency. Hardcoded in `deploy.sh` with no
   override. While it stands, both arms of any comparison look identical for reasons unrelated to
   the cache. Cheapest fix, biggest distortion removed.
2. **Attack the staging path.** `nixl_buffer_device: "cpu"` means every byte goes GPU → host → NIC →
   host → GPU. A GPU-resident buffer, or RDMA from device memory, removes two copies. Most likely
   home of the missing 5x.
3. **Cut the object count.** ~120 objects/request (30 chunks × 4 ranks) at `chunk_size 128`. If
   per-object round trips dominate rather than bandwidth, larger chunks help — but see the 16 MiB
   ceiling, which is what forced 128. **Measure per-object overhead before assuming.**
4. **Only then re-measure.** Another sweep of the current path reproduces the dead heat.

Use `pd_bench.py` (`--reuse KEY` for the shared-prefix arm). Whatever changes, keep checking
`need to load` — a "win" that is really a silent re-prefill is the standing failure mode here, and a
dead heat that is really a cache *miss* is its twin.

### OPEN-4 — A HUMAN posts the #4467 validation *(high, human-only)*

#4467 fixes silent KV corruption for **every** vLLM 0.26+ LMCache user (CUDA and ROCm). It has been
open since 2026-08-09, is green on every CPU lane, carries the `amd` label, and is frozen at head
`0eaaf282` — because the author has no GPU at all and said plainly they would rely on the AMD lane,
which never reported. Its own results table still reads `pending` in every "after" cell.

We have the validation. Posting it is a **human step by policy** (see the banner at the top). Paste
into <https://github.com/LMCache/LMCache/pull/4467>. Confirmed never posted: the thread ends at
`thegoldenflow 2026-09-01`. If the author rebases onto `dev` first, this is stale — re-run before
posting.

<details>
<summary>Ready-to-post text (already stripped of quoting — paste as-is)</summary>

**Validated on AMD MI300X (gfx942) — the fix works.**

Picking up the AMD-lane gap noted above: we hit this bug independently on ROCm and wrote our own
narrower fix before finding #4463/#4467. Yours is the better approach, so we tested yours instead of
proposing ours.

Built LMCache at `0eaaf282` inside AMD's `rocm-aic` container (vLLM 0.26, ROCm 7.14,
`torch 2.13.0+rocm7.2`, `TRITON_ATTN`), with our own fix removed. Engine format detected as
`EngineKVFormat.NL_X_NB_BS_NH_CS`.

**Your test suites, on the GPU:**

```
tests/v1/test_metadata_shapes.py + tests/v1/test_fused_kv_transfer.py
221 passed, 0 failed  —  97 on the cuda/HIP backend, 96 on the py oracle
```

Worth stating explicitly because the suite parametrises on
`_BACKENDS = ["py"] + (["cuda"] if _CUDA else [])`: this ran with `torch.cuda.is_available() == True`
on an `AMD Instinct MI300X`, so the 97 `cuda` cases exercised the compiled HIP kernels rather than
silently degrading to the CPU reference.

**Your `repro_lmcache_fused_kv.py` from #4463, before and after on the same GPU** — varying only the
image, so the `after` column of the table in the description:

| build | mode | offload verified | MATCH | exit |
|---|---|---|---|---|
| no fix | `lmcache` | LMCache loaded 528.5 MB in 14 chunks | **False** | 1 |
| **#4467** | `lmcache` | LMCache loaded 528.5 MB in 14 chunks | **True** | 0 |
| #4467 | `vllm-offload` | vLLM loaded 14 chunks from its CPU tier | True | 0 |
| #4467 | `baseline` | n/a | True | 0 |

Two things worth noting. The bug reproduces on ROCm with **exactly** the numbers reported on CUDA —
`528.5 MB in 14 chunks` — so this was never platform-specific. And the offload volume is identical
before and after, with only `MATCH` flipping, so the fix corrects the data rather than quietly
suppressing the offload.

`lmcache-mp` not run (needs the separate MP server, and the issue already establishes MP is
unaffected).

**End-to-end, in-process, against an NVMe-KV storage backend:**

- **V2** — TinyLlama-1.1B, TP=1. Store → full container restart → retrieve: needle recovered,
  `LMCache hit tokens: 1280, need to load: 1280`. Pre-fix this path produced corrupt output.
- **V3** (`use_gpu_connector_v3: True`) — same cycle, no crash. `VLLMPagedMemGPUConnectorV3`
  dispatched, `need to load: 1280`, needle recovered. This is the path #4463 reports as a hard
  first-store `RuntimeError: The size of tensor a (1024) must match the size of tensor b (2048)`.
- **Qwen2.5-72B-Instruct, TP=4, two hosts, prefill/decode disaggregated.** 4/4 needle prompts
  correct through the proxy; producer `need to load: 0`, receiver `hit tokens: 1152,
  need to load: 1152`.

Note the end-to-end path is harsher than the CPU-tier repro: KV crosses two machines via NIXL to an
NVMe-KV target over TCP, and TP=4 validates the fused addressing under tensor-parallel sharding as
well as at TP=1.

A caveat for reproducibility: we dropped three of rocm-aic's own LMCache patches that conflict at
this head (a GDS logging patch and two MP-path patches). None of them touches the in-process fused
path under test.

Happy to re-run any of this after the rebase onto `dev`.

</details>

The draft deliberately does **not** claim we ran their harness where we ran ours, and marks
`lmcache-mp` not-run rather than folding it in as a pass. Keep that honesty if you edit it.

### OPEN-5 — Delete `patches/0009` when #4467 merges *(medium, blocked)*

Our fix is superseded and **validated as replaceable**, but it stays for now, and the reason is not
technical merit: #4467 is unmerged and lives on a third-party branch that can be force-pushed or
deleted, and taking it means moving LMCache 143 commits forward and dropping three rocm-aic patches.
Pinning production to that is the worse trade. **When #4467 merges: delete `patches/0009`, bump
`LMCACHE_REF`, re-run the needle checks.** The switch is measured, not assumed.

### OPEN-6 — Decide what the static single-node instance is for *(medium)*

`aic-spdk-single` :8302 is still deliberately on the static backend. Static **cannot serve a
cross-process or cross-restart hit** — `NixlObjectPool` names slots `obj_{i}_{uuid4()}`
(`nixl_storage_backend.py:383`), a fresh uuid per process. It stores and never reads. It is not a
control and never was; keep it only if something needs a store-only instance, otherwise redeploy it
with `AIC_KV_POOL=0` or remove it.

### OPEN-7 — Upstream the probe fixes *(medium, human-only)*

`--seed-base` exists only in `/var/tmp/kvbench/kv_offload_bench_seeded.py` on the prefill node. Until
it lands, **every repeat run of `bench/kv-spillover-probe` silently measures retrieval in its own
STORE phase**. Its stock defaults also overflow TinyLlama's 2048 context by exactly one token
(2017 prompt + 32 output), so every request 400s; `--sentence-repeats 34` fits. Its README's "Known
status (2026-08-12): RETRIEVE never reaches the backend" is very likely the prefix-cache masking
described under "Benchmarking", not a backend bug. External repo → human posts.

### OPEN-8 — Housekeeping *(low)*

- Purge the pre-fix poison from the target. Every chunk written before `patches/0009` is half-empty
  and mis-strided. Keys are content-derived so this is only reachable by replaying a pre-fix prompt
  — it does **not** corrupt new work — but it will mislead anyone re-running an old prompt. The
  RAM-backed target clears on restart; it is shared, so restarting it is not a private action.
- Delete the unused `vendor/rocm-aic/pd-configs/` and `logs/` trees on the NFS home.
- `NIXL_KV_DEBUG_XFER` instrumentation (`784ad64`) stays — inert when unset, and it found the bug.
- Setup-3 BMC addresses were never captured; the `reg` entries carry `''`.
- `/var/tmp/lmc-tests-pr4467`, `/var/tmp/repro_lmcache_fused_kv.py`, `/var/tmp/lmcpf` are validation
  scratch on the prefill node; safe to delete.

---

## The KV transfer path — the one number that matters

Measured, not modelled:

```
1.26 GB of KV, loaded in 2.04 s          = 617 MB/s
link speed (ens50f0, decode -> target)   = 25 Gb/s = 3125 MB/s
                                           -> ~20% of line rate
recompute of the same 3840 tokens        = 1.90 s
```

So the storage tier is **slower than the GPU it is meant to save**. Neither the network nor the GPU
is the bottleneck — the software path is. Two concrete suspects, both cheap to test:

- **`nixl_buffer_device: "cpu"`** — every byte stages GPU → host → NIC → host → GPU.
- **~120 objects per request** — 30 chunks × 4 ranks at `chunk_size 128`.

The prize: at line rate the load is 0.40 s against a 1.90 s recompute, a **4.7x** win, and that is
the reuse case that the whole storage tier exists to serve.

---

## Constraints that will bite you

### The 16 MiB store ceiling

**One LMCache chunk is stored as ONE object, and the SPDK-KV device caps a single value at the
controller's max transfer size.** Logged at every startup:

```
[SPDK_NVMe_KV] device KV format 0: value_max=67108864 key_max=16,
  ctrlr max_xfer=16777216 -> effective=16777216
```

Per rank a chunk is `layers * chunk_size * (kv_heads/TP) * head_size * 2(K,V) * 2(bf16)`. The
producer's own log prints every term. Qwen2.5-72B at TP=4, `chunk_size 256`:
`80 * 256 * 2 * 128 * 4 = 20 MiB` against a 16 MiB ceiling.

Over the ceiling the **store dies with `NIXL_ERR_BACKEND`** and **takes the vLLM server down** rather
than degrading. Both roles come up healthy first, so it only appears on the first real request.

- **Every result before 2026-09-09 was below the ceiling.** TinyLlama at TP=1 is 5.5 MiB.
- **`patches/0007`'s multipart split has therefore never carried a chunk**, and does not save you.
- **It constrains `(model, TP, chunk_size)` jointly** — raising TP also lowers per-rank bytes.

`AIC_CHUNK_SIZE` (in `deploy.sh`) sets `chunk_size`; unset leaves LMCache's 256 and a byte-identical
config to before the knob existed. **Both P/D roles must carry the same value** — it is part of the
cache key, and a mismatch makes the receiver derive different keys and silently re-prefill.

### `--disable-custom-all-reduce` is required for any TP>1 on this image

Without it a TP=4 server **hangs at init**, it does not crash. All ranks load, allocate KV, reach
`all_gather_into_tensor`, then the EngineCore repeats `No available shared memory broadcast block
found in 60 seconds` until `wait_for_health` times out — which reads as a slow model. With it,
READY in 460 s.

**Rehearse any TP>1 change with TinyLlama first.** `INSTANCE=tp4probe PORT=8304
TENSOR_PARALLEL_SIZE=4 GPU=2,3,4,5` on weights already on disk reproduces this in ~3 minutes.
Hitting it first on a 145 GB model costs a 20-minute load per attempt and looks like a model problem.

### P/D requires `AIC_KV_POOL=0` on both roles

`AIC_KV_POOL=0` selects `NixlDynamicStorageBackend`, whose object names are content-derived. The
default (`2000000`) selects the static backend, whose names carry a per-process `uuid4`, so the
receiver can never derive the producer's keys, **no KV moves at all — and the answers still come back
correct.** `deploy.sh` now defaults it to 0 under `PD_ROLE` and refuses non-zero
(`AIC_ALLOW_STATIC_PD=1` overrides).

**The only check separating a working pair from the illusion is `need to load` on the receiver.**

### GPU placement

`ROCR_VISIBLE_DEVICES` is the *sole* isolation mechanism — `--device /dev/dri` exposes every render
node. It renumbers: `GPU=2,3,4,5` becomes `cuda:0..3` inside. Do not also set `HIP_VISIBLE_DEVICES`.
vLLM computes `gpu_memory_utilization` against **total**, not free, and fails loud if free memory is
short (`Free memory on device ... is less than desired`), so a mis-targeted GPU exits rather than
starving a neighbour. Verified this session, deliberately and accidentally.

Pre-raise hugepages before TP>1: each rank builds its own SPDK instance. `sudo sysctl -w
vm.nr_hugepages=4096`. `deploy.sh` only ever raises to 512 and never lowers.

---

## Benchmarking — what makes a number real here

Tools now in-tree:

- **`needle_test.py`** — correctness. Sends N long needle prompts through a proxy or endpoint. Ends
  by printing the receiver log-scrape rather than a verdict, because correctness **cannot**
  distinguish a working pair from the illusion; both answer correctly.
- **`pd_bench.py`** — throughput/latency. Unique-prefix prompts by default, `--reuse KEY` for the
  shared-prefix arm, concurrency sweep. Prints the c=1 caveat in its own output.

Traps, each of which silently produces a plausible but meaningless number:

1. **vLLM prefix caching must be off.** It defaults on and the GPU KV cache here is millions of
   tokens, so vLLM answers every repeat itself and LMCache is never consulted. Deploy with
   `VLLM_EXTRA_ARGS="--no-enable-prefix-caching"`.
2. **Every run needs fresh seeds.** The backend is persistent, so a repeat run measures retrieval in
   its own STORE phase. Varying prompt *length* does not help — chunk keys are prefix-derived, so
   `sentence * N` is a strict prefix of `sentence * (N+1)` and only the final chunk rekeys. Change
   the **beginning**.
3. **Always cross-check server-side.** `need to load: 0` *with* `computed 0` and `hit 0` is a full
   cold recompute, not a cache hit — that misreading produced the original "static backend verified"
   claim. On the target, `nvmf_get_stats | grep completed_nvme_io` must increase; use
   `nvmf_get_stats`, **not** `bdev_get_iostat`, which never moves for the KV command set.
4. **Isolate decode before attributing anything.** `--enforce-eager` made decode 76% of latency this
   session; without isolating it, prefill and load looked identical for the wrong reason.
5. **Match on `Total tokens`** before trusting a log line is yours; another user may share the host.
6. Prompts shorter than `chunk_size` are never stored. Append `\nAnswer:` or TinyLlama emits EOS
   immediately and an empty answer looks like corruption.

---

## Infrastructure traps

**The lab home is one NFS export shared by every Setup-3 node — same inode on all of them.**
`AIC_RUNTIME_DIR` (`/var/tmp/aic-$(id -u)`) now owns config and logs, and `deploy.sh` refuses a
shared filesystem (`AIC_ALLOW_SHARED_CONFIG=1` overrides). The guard runs **before** the
`docker rm -f`. Symptom of the old bug: `cat /etc/lmcache/config.yaml` inside a container returning
**`Stale file handle`**.

- **`INSTANCE` defaults to `PD_ROLE`**, so the naive "same command, bigger model" invocation is the
  destructive one — `docker rm -f` on the existing container is unconditional. **Always pass both
  `INSTANCE=` and a fresh `PORT=`.** Either alone is guarded; neither is not.
- **`HF_HOME` must not be the NFS home.** `docker run` cannot create it there. Use `/var/tmp/hf`.
  Note `/var/tmp/hf/hub` is **root-owned** because downloads run inside the container as root.
- **Never run `deploy.sh` under `sudo` on an NFS home** — `root_squash` kills it on its own `mkdir`.
- **`pkill -f "proxy.py --host"` kills your own shell** — the pattern matches the SSH command string.
  Match `"[p]roxy"`, or kill by PID. Note `$!` after a `bash -c ... &` records the **wrapper** PID,
  not python's.
- **Same tag ≠ same image, and same image ≠ same ID.** Always move and deploy by explicit tag;
  `docker save | ssh docker load` gives byte-identical content a *different* image ID. Verify by
  `md5` of files **inside** the image. The nodes can ssh each other directly (~550 MB/s).
- **`ROCM_ARCH` is required even with `SKIP_BUILD=1`.** Deployment records land in
  `${XDG_RUNTIME_DIR}/kv-cache-bench/` when the deploy runs non-root.

### Staging a model

Download **inside the image** (`--entrypoint hf ... download <repo>`); the hosts have no
`huggingface_hub`. Do **not** use `--local-dir` — vLLM needs the `hub/models--*/{blobs,snapshots}`
layout or it silently re-downloads inside the container. Node-to-node copy needs
`rsync -aH --rsync-path="sudo rsync"`; **`-H` matters** — `-L` dereferences the `snapshots/`→`blobs/`
symlinks and doubles the transfer. ~65 MB/s from HuggingFace, ~550 MB/s node-to-node.

### Rebuilding

`ROCM_ARCH=gfx942 bash build.sh` picks up `patches/0009` automatically. ~10 minutes with a warm layer
cache. Pre-flight before spending a build — `git apply --check` the whole series in the Dockerfile's
**lexical order** against a scratch clone. That two-minute check caught every problem this session.

To rebuild the #4467 validation image:

```bash
ROCM_ARCH=gfx942 SKIP_BUILD=1 bash build.sh
cd vendor/rocm-aic
rm -f patches/lmcache/{03-*,10-*,11-*,18-fused-kv-plane-count}.patch   # 18 = our 0009
# add `LMCACHE_GIT_URL:` under `args:` in docker/docker-compose.yml
env ROCM_ARCH=gfx942 IMAGE_TAG=pr4467 \
    LMCACHE_GIT_URL=https://github.com/thegoldenflow/LMCache.git \
    LMCACHE_REF=fix/4463-fused-cs-inprocess \
    make build
```

`IMAGE_TAG` must be set by hand: the Makefile derives the tag from `LMCACHE_REF`, and a branch name
containing `/` produces an invalid Docker tag that fails in the first seconds.

---

## The bug, for reference — `patches/0009`

**LMCache built a 2-plane split staging destination for vLLM 0.26's 1-plane fused KV cache.** The
copy kernel derives its source stride from that destination shape, so it read at half the correct
per-token stride: half the tokens, from the wrong offsets, V never written. Byte totals coincide
(`2*NH*HS == 1*NH*2*HS`), so nothing downstream complained.

Our fix asks vLLM's attention backend for the real shape at init (rank 4 → fused, rank 5 → split,
rank 3 → MLA) and cross-checks against the real tensors, raising on disagreement. The query must run
inside `set_current_vllm_config(...)` — without it `get_attn_backend` raises in the **scheduler** and
succeeds in the **worker**, leaving the two halves of one deployment disagreeing about layout.

**Upstream's fix takes a different and better route**: it keeps the LMCache side split and fixes the
*kernel addressing*, so `kv_size = 1 if use_mla else 2` remains in `get_shape()` by design. This is
why the two produce different `kv shape` log lines and both are correct. See OPEN-5.

`use_gpu_connector_v3: True` **does not work on v0.5.3** — V3 is dispatched but the shape stays
2-plane because `kv_layer_groups_manager` is populated lazily. Under #4467 it works; verified.

---

## Repo hygiene

The branch is public (`llm-stacks`). History was rewritten on 2026-09-09 to scrub **three real
identifiers** — a decode-node hostname, a PD-node IP and a colleague's username — from comments in
`plugins/*.cpp` and one README line, across all 17 commits. Each is now the matching
`<PLACEHOLDER>`; resolve them via `lab/lab-inventory.local.md`. Verified clean afterwards, and no
credentials were ever committed.

**Do not restate the scrubbed values anywhere in the tracked tree** — writing them into a note
*about* the scrub re-publishes them, which happened once while drafting this file and was caught by
the pre-commit grep below. Re-check before every commit:

```bash
grep -nE '10\.(235|30)\.[0-9]+\.[0-9]+|<cluster-user>|<node-hostnames>' README.md HANDOFF.md *.py
```

A local `pre-scrub-backup` tag and `refs/original/` still hold the unscrubbed objects — **delete
both** once you are satisfied, or they keep those blobs alive.

`.gitignore` is **default-deny** (`/*`) with an explicit allowlist, because the working tree is
shared with `main`, which carries a dozen trees this branch exists to exclude. Add single files to
the allowlist; **never** allowlist a directory — `lab/` holds the real inventory.

---

## Commits (this branch, pushed to `origin/rocm-aic`)

```
54e7fb6  Measure the reuse case too, and localise why neither case pays
00e7a78  Measure P+D, and record that it loses to not disaggregating
7d1fa6c  Run #4463's own repro on ROCm, before and after, and fill the upstream table
850f195  Run #4467's own test suites on an MI300X, and clear V3 as well as V2
702cfb1  Carry the upstream validation comment in-tree, and record why it is unposted
24b897d  Validate LMCache PR #4467 on MI300X: it replaces patches/0009
baecacd  Correct OPEN-2: the bug was already reported, and our patch is superseded
2f2ace5  Run P+D on a real model, and record the ceiling that had been hiding under TinyLlama
b3419ca  Add AIC_CHUNK_SIZE, and pin the 16 MiB store ceiling that blocks real models
```
