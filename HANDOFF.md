# HANDOFF — 2026-09-09

**The stack works, and it now works on a model worth running.** The KV corruption that blocked
everything is fixed and shipped in an image; single-node store/retrieve is verified and measured;
P+D disaggregation runs end to end across two hosts — on **Qwen2.5-72B-Instruct at TP=4**, not just
TinyLlama. None of that was true at the start of the day.

Getting to a real model surfaced a ceiling that had been latent the whole time: **one chunk is one
stored object, and the device caps a single value at 16 MiB.** Every result on this branch before
today was taken at TinyLlama's 5.5 MiB and never approached it. See "The 16 MiB store ceiling".

**And now the uncomfortable part: it was measured, and P/D loses.** Against a single aggregated
node the disaggregated pair runs at 0.17–0.41x the throughput while holding twice the GPUs, and
concurrency widens the gap rather than closing it. The stack is correct; the architecture, on this
transport, does not pay for itself. That is the honest headline and OPEN-1 carries the numbers.

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
| **P+D on a real model** | ✅ **Qwen2.5-72B-Instruct, TP=4**, 4/4 needles, `need to load: 1152` |
| P+D under concurrency | ✅ measured at c=1/4/8 — and the gap **widens** with load |
| **P+D latency/throughput** | ⚠️ **measured, and it LOSES**: 0.17–0.41x an aggregated node on 2x the GPUs. Correct, not worthwhile. See OPEN-1 |
| **KV reuse (cache) case** | ⚠️ **measured, dead heat** — cache hit confirmed (`need to load: 3840`) and still no gain. See OPEN-1b |
| **Root cause of both** | 🔎 **KV path runs at ~20% of line rate** (617 MB/s on a 25 Gb/s link). At line rate reuse would win **4.7x**. See OPEN-1c |
| `patches/0009` upstreamed | ❌ **don't** — superseded by LMCache PR #4467, see OPEN-2 |
| LMCache PR #4467 on MI300X | ✅ **validated, replaces `patches/0009`** — 72B TP=4 P/D, 4/4, `need to load: 1152` |

### What is deployed

All containers on `rocm-aic:kv-planefix`. Runtime config and logs are host-local under
`AIC_RUNTIME_DIR` (`/var/tmp/aic-$(id -u)`); nothing mounts the NFS home any more.

| node | container | port | GPU | model | backend |
|---|---|---|---|---|---|
| `<SETUP3_PREFILL_NODE>` | `aic-spdk-planefix` | 8303 | 0 | TinyLlama | dynamic (single-node bench instance) |
| `<SETUP3_PREFILL_NODE>` | `aic-spdk-producer` | 8301 | 1 | TinyLlama | dynamic, `store_location` only |
| `<SETUP3_PREFILL_NODE>` | **`aic-spdk-producer72`** | **8401** | **2,3,4,5** | **Qwen2.5-72B** | dynamic, `store_location`, `chunk_size 128` |
| `<SETUP3_PREFILL_NODE>` | `proxy.py` | 9000 | — | TinyLlama pair | `/var/tmp/start_pd_proxy.sh` |
| `<SETUP3_PREFILL_NODE>` | **`proxy.py`** | **9001** | — | **72B pair** | PID in `/var/tmp/proxy9001.pid` |
| `<SETUP3_DECODE_NODE>` | `aic-spdk-receiver` | 8301 | 0 | TinyLlama | dynamic, `retrieve_locations` only |
| `<SETUP3_DECODE_NODE>` | `aic-spdk-single` | 8302 | 1 | TinyLlama | **static** — cannot read back, see OPEN-5 |
| `<SETUP3_DECODE_NODE>` | **`aic-spdk-receiver72`** | **8401** | **2,3,4,5** | **Qwen2.5-72B** | dynamic, `retrieve_locations`, `chunk_size 128` |
| `<SETUP3_TARGET_NODE>` | SPDK NVMe-KV target | 4420 | — | — | RAM-backed, holds pre-fix poison + post-fix data |

Four in-process instances now coexist per node on distinct GPUs, ports and `INSTANCE` names. Cards
6 and 7 are free on both nodes.

**The TinyLlama pair is deliberately still up as a live control.** It is worth far more than the two
GPUs it costs: when the 72B receiver shows `need to load: 0`, the first question is "did the stack
regress, or is this config wrong?", and without a known-good pair that cannot be answered without a
teardown. It was re-verified 4/4 after every step of the 72B bring-up.

Both 72B roles carry `DEPLOY_DEGRADED=enforce-eager,disable-custom-all-reduce,gpu-mem-util-0.6,tp4,chunk128`.
`--enforce-eager` is hardcoded (`deploy.sh`) and will distort any latency number taken from them.

---

## OPEN ITEMS

Ordered by what I would do next.

### OPEN-1 — MEASURED: P+D is correct, and on this stack it is **not worth it** *(answered)*

Measured 2026-09-09 with `pd_bench.py`, Qwen2.5-72B TP=4, ~3940-token prompts, 8 requests per
level, unique prefixes throughout. Both arms verified from the receiver's own log: the
disaggregated arm loaded (`need to load: 3840`, 30 chunks × 128) and the aggregated arm cold-computed
(`hit 0, need to load: 0`). 24 requests each, no errors.

| concurrency | disaggregated (8 GPUs) | aggregated, one node (4 GPUs) | disagg vs agg |
|---|---|---|---|
| 1 | 0.062 req/s · 16.1 s mean | 0.153 req/s · 6.5 s mean | **0.41x** |
| 4 | 0.087 req/s · 42.2 s mean | 0.506 req/s · 7.9 s mean | **0.17x** |
| 8 | 0.147 req/s · 43.2 s mean | 0.692 req/s · 11.3 s mean | **0.21x** |

**Disaggregation is 2.4–5.8x slower while using twice the GPUs — roughly 5–12x worse per GPU.** It
also scales worse with load: 1 → 2.36x from c=1 to c=8, against the aggregated instance's 4.52x.

The concurrency argument this item was built on does not rescue it. The prediction was that a
single-request measurement would look like a loss and only concurrency would show the win. Concurrency
was measured, and the gap **widens** rather than closes.

Why, mechanically: a one-shot P/D handoff moves the **entire** KV over the wire —
`3840 tokens × 320 KiB = ~1.2 GB per request`, as ~120 objects (30 chunks × 4 ranks) — and the proxy
is sequential, so store-to-target and load-from-target both sit on the critical path rather than
overlapping with compute. The aggregated instance keeps that KV in HBM and never pays it, and its
continuous batching packs concurrent requests into one engine instead of splitting them across two
with a serialization point between.

**What this does and does not say.** It is one configuration: SPDK-KV over **TCP** to a RAM-backed
target, `--enforce-eager` hardcoded on both roles, a sequential proxy, `chunk_size 128`. It says this
stack's P/D path is not competitive as built. It does **not** say P/D disaggregation is worthless —
the honest reading is that a one-shot handoff has to move KV faster than the prefill it saves, and
TCP to a remote target does not. Before quoting this anywhere, note the aggregated arm was
`receiver72` itself, which still pays a lookup miss per request, so the aggregated numbers are if
anything slightly pessimistic.

Where the architecture could still pay, in rough order of promise: **KV reuse across many requests**
(the caching case, where one store amortises over many loads — unlike this one-shot handoff), a
**faster transport** (RDMA, or the real DSC device rather than TCP), and a **non-sequential proxy**
that overlaps the decode host's load with the prefill host's next request. Also worth re-running
without `--enforce-eager`, which is hardcoded in `deploy.sh` and inflates decode on both arms.

The 2.40x single-node figure in "Benchmarking" is not in tension with this: that measures
**retrieve-vs-recompute on one host**, which is the reuse case. This measures a **cross-host one-shot
handoff**. They are different questions and only the first one currently wins.

### OPEN-1b — MEASURED: the reuse case doesn't pay either, and now we know why *(answered)*

The handoff case lost, so the obvious follow-up was the **reuse** case — one store amortised over
many loads, which is where the 2.40x single-node figure came from. Measured on a single `kv_both`
72B instance (`reuse72`, TP=4, vLLM prefix caching off), shared 3840-token prefix vs a unique prefix
per request:

| concurrency | A: unique prefix (full recompute) | B: shared prefix (warmed, cache hit) |
|---|---|---|
| 1 | 0.120 req/s · 8.31 s | 0.118 req/s · 8.45 s |
| 4 | 0.253 req/s · 15.74 s | 0.285 req/s · 14.02 s |
| 8 | 0.332 req/s · 23.78 s | 0.341 req/s · 23.48 s |

**A dead heat.** And the cache really was hit — 24/24 requests logged
`hit tokens: 3840, need to load: 3840`, so this is not the silent-re-prefill failure mode. Reuse
genuinely fetched the KV and still bought nothing.

Isolating decode with a tiny 81-token prompt at the same `max_tokens=32` gives **6.41 s**, which is
what makes the result legible:

| | |
|---|---|
| KV per request (3840 tok × 320 KiB) | **1.26 GB** |
| Prefill 3840 tokens (8.31 − 6.41) | **1.90 s** |
| KV load 3840 tokens (8.45 − 6.41) | **2.04 s** → **617 MB/s** |
| Link (decode node → target, `ens50f0`) | 25 Gb/s = **3125 MB/s** |
| **Storage path efficiency** | **~20% of line rate** |
| Decode share of request latency | **76%** |

Three conclusions, in order of usefulness:

1. **The KV path runs at ~20% of the wire.** 617 MB/s against a 25 Gb/s link. The bottleneck is not
   the network and not the GPU — it is the software path: ~120 objects per request (30 chunks × 4
   ranks) and `nixl_buffer_device: "cpu"`, so every byte stages GPU → host → NIC → host → GPU.
2. **Fix that and reuse wins.** At line rate the same 1.26 GB lands in **0.40 s** against a **1.90 s**
   recompute — a **4.7x** win. The prize is real and roughly 5x of software headroom stands between
   here and it. That is the single most valuable thing left in this repo.
3. **`--enforce-eager` is distorting everything.** 6.41 s of decode is 76% of each request, so both
   arms are mostly measuring a handicap that is hardcoded in `deploy.sh` with no override. Remove it
   before taking any further performance number.

Caveat on the arithmetic: decode was isolated at 81 tokens of context, and decode attention costs
slightly more at 3840, so the 1.90 s and 2.04 s are mild over-estimates. They move together, so the
comparison holds; treat them as "roughly equal, ~2 s" rather than as three-significant-figure values.

**Why this does not contradict the 2.40x.** That was TinyLlama — 22 KiB/token, so ~22 MB for 1024
tokens, small enough that even a 20%-of-line-rate path beat recompute. Scaling to 72B multiplied KV
volume by ~55x while MI300X prefill stayed fast, and the storage path did not scale with it.

### OPEN-1c — Fix the KV transfer path, then re-measure *(high)*

Both cases are now measured and both lose, but OPEN-1b localises **why** to one place: the KV
transfer path delivers **~20% of line rate**. Everything below is ordered by that finding rather
than by guesswork, and the prize is quantified — a **4.7x** win on the reuse case if the path
reaches the wire.

1. **Drop `--enforce-eager` first.** 76% of request latency, hardcoded in `deploy.sh` with no
   override. Until it goes, every number is mostly measuring it, and the two arms of any comparison
   will look identical for reasons that have nothing to do with the cache. Cheapest fix, biggest
   distortion removed.
2. **Attack the staging path.** `nixl_buffer_device: "cpu"` means every byte goes GPU → host → NIC →
   host → GPU. A GPU-resident buffer, or RDMA straight from device memory, removes two copies. This
   is where the missing 5x most likely lives.
3. **Cut the object count.** ~120 objects per request (30 chunks × 4 ranks) at `chunk_size 128`. If
   per-object round trips dominate rather than bandwidth, larger chunks help — but see the 16 MiB
   ceiling, which is what forced 128 in the first place. Measure per-object overhead before
   assuming it.
4. **Only then re-measure.** Another sweep of the current path will reproduce the dead heat above.

Re-run with `pd_bench.py` (`--reuse KEY` selects the shared-prefix arm). Whatever changes, keep
checking `need to load` — a "win" that turns out to be a silent re-prefill is the standing failure
mode here, and a dead heat that turns out to be a cache *miss* is its twin.

`MAX_MODEL_LEN=32768` allows 8k–16k prompts if a longer-prefill regime is wanted; note 16k tokens is
~5 GB of KV per request, and the target is RAM-backed.

### OPEN-2 — Validate LMCache PR #4467 on our MI300X *(high)*

**Do not submit `patches/0009` upstream. It is superseded, and the bug was already known.** This
item said the opposite; that was wrong, and checking took ten minutes that were not spent.

- **Issue [#4463]** — "Silent KV cache corruption on vLLM 0.26 fused/packed KV layout", filed
  **2026-08-08** by `shadowpa0327`, a month before we rediscovered it. Open.
- **PR [#4467]** — `thegoldenflow`, opened 2026-08-09. Open, unmerged. It is a **more thorough fix
  than ours**: an explicit `MemObjKVLayout` contract (`SPLIT_KV_2LTD` / `FUSED_PACKED`) rather than
  a derived plane count, and it fixes the fused kernels, V3's lazy-discovery first-store crash and
  CacheBlend as well as V2, with `tests/v1/test_fused_kv_transfer.py` and
  `tests/v1/test_metadata_shapes.py`. It already contains our V3 finding as its root cause #3.
- The defect is still on `dev` today: `gpu_connectors.py:428` is still
  `kv_size = 1 if self.use_mla else 2`, and V3's `get_shape()` still raises.

**Our correction to carry forward: this is not ROCm-specific.** `Vivo50E` reproduced it on
**A100 / `FLASH_ATTN` / vLLM 0.27** (Qwen2.5-Omni-3B), so it hits CUDA users identically, and
vLLM-Omni's KV offload is blocked on it. Anything we write that implies this is our platform's
problem is wrong.

**What is actually blocking #4467 is the one thing we have.** Every CPU lane is green and the PR
carries the `amd` label, but the author wrote on 2026-09-01:

> "I don't have AMD hardware locally, so I'll rely on that lane for HIP/ROCm validation."

The AMD lane never reported. The PR has been frozen at head `0eaaf282` and untouched for over a
week, with the end-to-end results table in its own description still reading `pending` in every
"after" cell, because **the development machine used for the fix has no GPU at all.**

We have 8×MI300X, a working ROCm build, a two-node P/D pair and a needle harness that can tell a
real KV movement from the illusion. Validating #4467 here is worth far more than re-reporting a
known bug, and it is a harsher test than the one they are asking for: our path runs the fix through
NIXL → SPDK NVMe-KV over TCP across two hosts, not just a local CPU tier.

### Validation result — #4467 PASSES on MI300X (2026-09-09)

Built as `rocm-aic:pr4467` from the PR head with **`patches/0009` removed**, and validated twice:

| check | result |
|---|---|
| #4467's kernels compile under ROCm/HIP, gfx942 | ✅ `MemObjKVLayout`/`SPLIT_KV_2LTD`/`FUSED_PACKED` in the built `lmcache_native` .so |
| **#4467's own test suites, on an MI300X** | ✅ **221 passed, 0 failed** — `test_fused_kv_transfer.py` + `test_metadata_shapes.py` |
| ⤷ of which, on the GPU rather than the CPU oracle | ✅ **97 GPU/HIP** vs 96 CPU `py` — the compiled kernels really ran |
| **V2** TinyLlama TP=1, store → **container restart** → retrieve | ✅ needle recovered, `hit 1280, need to load: 1280` |
| **V3** (`use_gpu_connector_v3: True`), same cycle | ✅ **no crash**, `VLLMPagedMemGPUConnectorV3` dispatched, `need to load: 1280` |
| **Qwen2.5-72B, TP=4, two hosts, through the proxy** | ✅ **4/4 needles**, producer `need to load: 0`, receiver `need to load: 1152` |
| TinyLlama control pair (still on `kv-planefix`) | ✅ 4/4 throughout, never disturbed |

The V3 result is worth its own line. #4463 reports V3 as a **hard first-store crash**
(`RuntimeError: The size of tensor a (1024) must match the size of tensor b (2048)`), and our own
earlier note called `use_gpu_connector_v3` a landmine. Under #4467 it stores, survives a restart and
reads back, on the fused format (`EngineKVFormat.NL_X_NB_BS_NH_CS`). Both in-process connectors are
fixed, not just V2.

### #4463's own repro script, before and after, on the same GPU

The upstream table could not be filled from our needle harness, so we ran **their**
`repro_lmcache_fused_kv.py` (Qwen3-8B, `chunk_size 256`, `local_cpu`, prefix caching off) on one
MI300X, varying only the image:

| image | fix present | mode | offload verified | MATCH | exit |
|---|---|---|---|---|---|
| `kv-query-final` | **none** | `lmcache` | LMCache loaded 528.5 MB in 14 chunks | ❌ **False** | 1 |
| `pr4467` | **#4467** | `lmcache` | LMCache loaded 528.5 MB in 14 chunks | ✅ **True** | 0 |
| `kv-planefix` | ours (`0009`) | `lmcache` | LMCache loaded 528.5 MB in 14 chunks | ✅ True | 0 |
| `pr4467` | #4467 | `vllm-offload` | vLLM loaded 14 chunks from its CPU tier | ✅ True | 0 |
| `pr4467` | #4467 | `baseline` | n/a — no offload tier | ✅ True | 0 |

Two things make this worth more than a bare pass:

- **The bug reproduces on ROCm identically to the CUDA report.** `528.5 MB in 14 chunks` is
  byte-for-byte the figure in #4463. This was never a platform-specific defect.
- **The offload volume is unchanged across all three images.** Same MB, same chunk count, only
  `MATCH` flips. The fix corrects the data; it does not quietly stop offloading — which is the
  failure mode that would otherwise make a green run meaningless. The script asserts a transfer
  happened for exactly this reason.

`lmcache-mp` was **not run** — it needs a separate MP server process, and #4463 already establishes
the MP connector is unaffected.

Test suites were run from the PR's own tree mounted into the image:

```bash
docker run --rm --device /dev/kfd --device /dev/dri -e ROCR_VISIBLE_DEVICES=7 \
  -v /var/tmp/lmc-tests-pr4467:/tests:ro --entrypoint bash rocm-aic:pr4467 \
  -c 'cd /tests && python3 -m pytest v1/test_metadata_shapes.py v1/test_fused_kv_transfer.py -q'
```

The GPU/CPU split matters and is easy to get wrong: the suite parametrises on
`_BACKENDS = ["py"] + (["cuda"] if _CUDA else [])`, so on a box without a visible GPU it still
reports all-green while only ever exercising the CPU reference. Count `PASSED` lines containing
`cuda` before believing it proves anything about the kernels. Here: `torch 2.13.0+rocm7.2`,
`torch.cuda.is_available() == True`, device `AMD Instinct MI300X`.

That is a strictly harsher test than the one being asked for upstream: it crosses two hosts through
NIXL → SPDK NVMe-KV over TCP, not a local CPU tier, and it exercises TP=4 rather than TP=1.

Note their fix and ours take **different approaches**, and theirs is the better one. Ours changed
the LMCache side to match the engine (`kv shape (22, 1, 256, 4, 128)`). Theirs keeps the LMCache
side split (`(22, 2, 256, 4, 64)`) and fixes the *kernel addressing*, so `kv_size = 1 if use_mla
else 2` is still in `get_shape()` on purpose. `AIC_CHUNK_SIZE` is unaffected — total chunk bytes are
identical, so Qwen at TP=4 still needs 128.

**Reproducing the build** (the three dropped patches are rocm-aic's own, and none is on our code
path — `03` is GDS logging, `10`/`11` are MP-path; we run in-process with SPDK-KV):

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

`IMAGE_TAG` must be set: the Makefile derives the tag from `LMCACHE_REF`, and a branch name with a
`/` in it produces an invalid Docker tag and fails the build immediately.

### What is left

1. **A HUMAN posts the validation to #4467.** It is the one thing blocking a PR that fixes silent
   corruption for every vLLM 0.26+ LMCache user, and we are positioned to give it.

   **This is a human step by policy, not a blocked automated one.** Nothing in this repo's tooling
   may write to an external repository — no comments, no issues, no PRs, no pushes. Do not "fix"
   this by granting an agent a broader token. Paste the text below by hand, under a name, with a
   judgement attached. Verified never posted: the thread ends at `thegoldenflow 2026-09-01`.

   <details>
   <summary>Ready-to-post text for <a href="https://github.com/LMCache/LMCache/pull/4467">#4467</a></summary>

   > **Validated on AMD MI300X (gfx942) — the fix works.**
   >
   > Picking up the AMD-lane gap noted above: we hit this bug independently on ROCm and wrote our own
   > narrower fix before finding #4463/#4467. Yours is the better approach, so we tested yours
   > instead of proposing ours.
   >
   > Built LMCache at `0eaaf282` inside AMD's `rocm-aic` container (vLLM 0.26, ROCm 7.14,
   > `torch 2.13.0+rocm7.2`, `TRITON_ATTN`), with our own fix removed. Engine format detected as
   > `EngineKVFormat.NL_X_NB_BS_NH_CS`.
   >
   > **Your test suites, on the GPU:**
   >
   > ```
   > tests/v1/test_metadata_shapes.py + tests/v1/test_fused_kv_transfer.py
   > 221 passed, 0 failed  —  97 on the cuda/HIP backend, 96 on the py oracle
   > ```
   >
   > Worth stating explicitly because the suite parametrises on
   > `_BACKENDS = ["py"] + (["cuda"] if _CUDA else [])`: this ran with
   > `torch.cuda.is_available() == True` on an `AMD Instinct MI300X`, so the 97 `cuda` cases
   > exercised the compiled HIP kernels rather than silently degrading to the CPU reference.
   >
   > **Your `repro_lmcache_fused_kv.py` from #4463, before and after on the same GPU** — varying
   > only the image, so the `after` column of the table in the description:
   >
   > | build | mode | offload verified | MATCH | exit |
   > |---|---|---|---|---|
   > | no fix | `lmcache` | LMCache loaded 528.5 MB in 14 chunks | **False** | 1 |
   > | **#4467** | `lmcache` | LMCache loaded 528.5 MB in 14 chunks | **True** | 0 |
   > | #4467 | `vllm-offload` | vLLM loaded 14 chunks from its CPU tier | True | 0 |
   > | #4467 | `baseline` | n/a | True | 0 |
   >
   > Two things worth noting. The bug reproduces on ROCm with **exactly** the numbers reported on
   > CUDA — `528.5 MB in 14 chunks` — so this was never platform-specific. And the offload volume is
   > identical before and after, with only `MATCH` flipping, so the fix corrects the data rather
   > than quietly suppressing the offload.
   >
   > `lmcache-mp` not run (needs the separate MP server, and the issue already establishes MP is
   > unaffected).
   >
   > **End-to-end, in-process, against an NVMe-KV storage backend:**
   >
   > - **V2** — TinyLlama-1.1B, TP=1. Store → full container restart → retrieve: needle recovered,
   >   `LMCache hit tokens: 1280, need to load: 1280`. Pre-fix this path produced corrupt output.
   > - **V3** (`use_gpu_connector_v3: True`) — same cycle, no crash. `VLLMPagedMemGPUConnectorV3`
   >   dispatched, `need to load: 1280`, needle recovered. This is the path #4463 reports as a hard
   >   first-store `RuntimeError: The size of tensor a (1024) must match the size of tensor b (2048)`.
   > - **Qwen2.5-72B-Instruct, TP=4, two hosts, prefill/decode disaggregated.** 4/4 needle prompts
   >   correct through the proxy; producer `need to load: 0`, receiver `hit tokens: 1152,
   >   need to load: 1152`.
   >
   > Note the end-to-end path is harsher than the CPU-tier repro: KV crosses two machines via NIXL
   > to an NVMe-KV target over TCP, and TP=4 validates the fused addressing under tensor-parallel
   > sharding as well as at TP=1.
   >
   > A caveat for reproducibility: we dropped three of rocm-aic's own LMCache patches that conflict
   > at this head (a GDS logging patch and two MP-path patches). None of them touches the in-process
   > fused path under test.
   >
   > Happy to re-run any of this after the rebase onto `dev`.

   </details>

   Deliberately does **not** claim we ran their `repro_lmcache_fused_kv.py` — we ran our own needle
   harness, so the before/after table in the PR description cannot be filled 1:1 without running
   their script separately.
2. **Do not pin production to the fork branch.** `patches/0009` stays the shipping fix for now: it
   works against our pinned `LMCACHE_REF=v0.5.3`, whereas #4467 exists only on a third-party branch
   that can be force-pushed or deleted, and taking it means moving LMCache forward 143 commits and
   dropping three rocm-aic patches. **Delete `patches/0009` and bump the pin when #4467 merges** —
   that is the exit criterion, and it is now a documented, validated switch rather than a hope.

[#4463]: https://github.com/LMCache/LMCache/issues/4463
[#4467]: https://github.com/LMCache/LMCache/pull/4467

### OPEN-3 — Upstream the probe fixes *(medium)*

`--seed-base` exists only in `/var/tmp/kvbench/kv_offload_bench_seeded.py` on the prefill node. I did
not edit the shared `bench/` tree unasked. Until it lands, **every repeat run of
`bench/kv-spillover-probe` silently measures retrieval in its own STORE phase**. Its stock defaults
also overflow TinyLlama's 2048 context by exactly one token (2017 prompt + 32 output), so every
request 400s; `--sentence-repeats 34` fits.

Its README's "Known status (2026-08-12): RETRIEVE never reaches the backend" should be revisited —
that is very likely the prefix-cache masking described in "Benchmarking" below, not a backend bug.

### OPEN-4 — Purge the pre-fix poison from the target *(medium)*

Every chunk written before `patches/0009` is half-empty and mis-strided. Keys are content-derived,
so this is only reachable by replaying a pre-fix prompt — it does **not** corrupt new work — but it
will mislead anyone who re-runs an old prompt. The RAM-backed target clears on restart. It is shared
with the decode node, so restarting it is not a private action.

### OPEN-5 — Decide what the static single-node instance is for *(medium)*

`aic-spdk-single` :8302 is still deliberately on the static backend. Static **cannot serve a
cross-process or cross-restart hit** — `NixlObjectPool` names slots `obj_{i}_{uuid4()}`
(`nixl_storage_backend.py:383`), a fresh uuid per process. It stores and never reads. It is not a
control and never was; keep it only if something needs a store-only instance, otherwise redeploy it
with `AIC_KV_POOL=0` or remove it.

### OPEN-6 — Housekeeping *(low)*

- Delete the now-unused `vendor/rocm-aic/pd-configs/` and `logs/` trees on the NFS home. Nothing
  mounts them since both nodes moved to `AIC_RUNTIME_DIR`.
- `NIXL_KV_DEBUG_XFER` instrumentation (`784ad64`) stays in the tree — inert when unset, and it is
  what found the bug. Keep.
- Setup-3 BMC addresses were never captured; the `reg` entries carry `''`.
- `use_layerwise` is a landmine: `VLLMPagedMemGPUConnectorV3.get_shape()` raises
  `NotImplementedError` and `store_layer` (`cache_engine.py:683`) is its only caller.

---

## P+D on a real model — Qwen2.5-72B-Instruct at TP=4

Verified 2026-09-09. 4/4 needles correct through proxy 9001, and the discriminative check passes:

```
producer72:  Total tokens 1199, computed 0, LMCache hit tokens: 0,    need to load: 0      <- stores
receiver72:  Total tokens 1199, computed 0, LMCache hit tokens: 1152, need to load: 1152   <- loads
```

`1152 = 9 chunks x 128`. `Total tokens` matches the requests sent, per the rule below about shared
endpoints. Run it with `needle_test.py` (now in the tree):

```bash
python3 needle_test.py --port 9001 --model Qwen/Qwen2.5-72B-Instruct \
  --seed-base <fresh> --count 4 --repeats 34
```

`--seed-base` must be fresh on every run: chunk keys are prefix-derived and the backend is
persistent, so a repeat run measures retrieval in its own store phase.

### The 16 MiB store ceiling — the thing that actually blocked this

**One LMCache chunk is stored as ONE object, and the SPDK-KV device caps a single value at the
controller's max transfer size.** Logged at every startup, and previously ignored:

```
[SPDK_NVMe_KV] device KV format 0: value_max=67108864 key_max=16,
  ctrlr max_xfer=16777216 -> effective=16777216 (compiled-in default 524288)
```

Per rank, one chunk is `layers * chunk_size * (kv_heads/TP) * head_size * 2(K,V) * 2(bf16)`. The
producer's own log prints every term:

```
num_layer: 80, chunk_size: 256, num_kv_head (per gpu): 2, head_size: 128
  -> 80 * 256 * 2 * 128 * 4 = 20 MiB, against a 16 MiB ceiling
```

Over the ceiling the **store dies with `NIXL_ERR_BACKEND`** out of
`mem_to_storage -> post_blocking -> check_xfer_state`, and it **takes the whole vLLM server down**
rather than degrading. Both roles come up healthy first, so this only appears on the first real
request.

Three consequences worth carrying forward:

- **Every result on this branch before today was taken below the ceiling.** TinyLlama at TP=1 is
  22 layers and 4 kv heads — 5.5 MiB. It never came close.
- **The multipart-split path that `patches/0007` exists for has therefore never carried a chunk**,
  and it does not save us here. That patch is effectively unexercised.
- **The ceiling is a joint constraint on `(model, TP, chunk_size)`, not a property of the model.**
  Raising TP lowers per-rank chunk bytes by cutting `kv_heads/TP`, so TP=8 would also have fitted —
  which is a genuine argument for TP=8 that nobody had made, and is *not* the GPU-count argument
  given below.

`AIC_CHUNK_SIZE` (new, `deploy.sh`) sets `chunk_size`; unset leaves LMCache's 256 and the generated
config byte-identical to before the knob existed. `128` halves the Qwen chunk to 10 MiB and it fits.
**It is part of the cache key, so both P/D roles must carry the same value** — a mismatch makes the
receiver derive different keys and silently re-prefill, the same signature as the static-backend
illusion.

### `--disable-custom-all-reduce` is required for any TP>1 on this image

Without it a TP=4 server **hangs at init**, it does not crash. All ranks load, allocate KV, reach
`all_gather_into_tensor`, and then the EngineCore repeats:

```
No available shared memory broadcast block found in 60 seconds.
```

`wait_for_health` just times out, which reads as a slow model rather than a hang. Adding
`--disable-custom-all-reduce` to `VLLM_EXTRA_ARGS` fixed it outright — READY in 460 s.

This was found in **three minutes** by rehearsing TP=4 with TinyLlama on weights already on disk,
before touching the 72B. Any TP>1 change should be rehearsed that way; hitting this first on a 145 GB
model costs a 20-minute load per attempt and looks like a model problem.

### Two corrections to the previous handoff

- **"`Qwen2.5-72B` at TP=8 needs all 8 GPUs per node, so the single-node instances must come down
  first" was wrong, and circular** — it assumed TP=8 and derived the GPU count from it. On 192 GB
  MI300X parts the model is ~36 GB/rank at TP=4. It was run on the six idle GPUs and **the TinyLlama
  pair stayed up throughout as a control.** Nothing had to come down.
- **A TP mismatch between roles produces a key miss, not a misread.** The symptom is
  `need to load: 0` — indistinguishable from the static-backend illusion, so pin TP explicitly on
  both roles rather than diagnosing it as a storage bug.

### Staging the model

`HF_HOME=/var/tmp/hf` on both nodes, and `/var/tmp/hf/hub` is **root-owned** because the download
runs inside the container as root. Consequences that cost time:

- Download inside the image (`--entrypoint hf ... download <repo>`); the hosts have no
  `huggingface_hub`. Do **not** use `--local-dir` — vLLM needs the `hub/models--*/{blobs,snapshots}`
  layout or it silently re-downloads 145 GB inside the container.
- Node-to-node copy needs `rsync -aH --rsync-path="sudo rsync"`; without the `sudo` rsync-path it
  fails `mkdir: Permission denied` on the root-owned `hub/`. **`-H` matters** — `-L` would
  dereference the `snapshots/`→`blobs/` symlinks and double the transfer to 290 GB.
- 65 MB/s from HuggingFace, 550 MB/s node-to-node. Download once, then push.

---

## The fix — `patches/0009-lmcache-fused-kv-plane-count.patch`

> This is **our** fix, and it works, but it is not the one to upstream — LMCache PR #4467 fixes the
> same defect more thoroughly and was opened a month earlier. **#4467 has now been validated on this
> hardware and fully replaces this patch** (see OPEN-2). It stays only because #4467 is unmerged and
> lives on a third-party branch; **delete it when #4467 lands.** Read this section for what the bug
> *is*, not for what to ship.

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

**This is TinyLlama, single-node, at 5.5 MiB chunks — comfortably under the 16 MiB ceiling.** It says
nothing about the 72B pair, whose chunks are twice the size and whose store path crosses a host. No
equivalent number exists for a real model; that is OPEN-1.

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
b3419ca  Add AIC_CHUNK_SIZE, and pin the 16 MiB store ceiling that blocks real models
f289325  Make P/D default to the dynamic backend, and rewrite the handoff
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
