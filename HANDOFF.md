# HANDOFF — 2026-09-09 (fourth pass)

**The KV corruption is fixed, built into an image, and deployed.** A ≥800-word prompt is stored,
the container restarted, and the prompt's needle recovered correctly from the NVMe KV target with
`need to load` non-zero — three times now, with different needles, the last one against the built
image rather than a hand-patched container. As far as this repo's records go that is the **first
correct cross-process KV read this stack has ever performed**; every chunk before it was half-empty.

The fix is `patches/0009-lmcache-fused-kv-plane-count.patch`, shipped in **`rocm-aic:kv-planefix`**
and running as `aic-spdk-planefix`. `use_gpu_connector_v3: True` was tried first, per the previous
NEXT ACTION, and does not work — that finding is kept below because it rules out the cheap option.

Two corrections to earlier passes are recorded below and both matter more than they look:
the shape's real origin is **not** `integration/vllm/utils.py:278`, and the deploy.sh config
clobbering is **not** a co-residency problem — it is an **NFS-shared config file**.

**Hostnames are placeholders here**, per this repo's convention. Real IPs, credentials and BMC
addresses are in `lab/lab-inventory.local.md` (gitignored, never committed). Read that first.

Branch `rocm-aic`, **not pushed**. The plugin instrumentation described below is committed
(`784ad64`), as is the `deploy.sh` co-resident fix (`610067d`) and the root cause (`bdd5511`).

---

## TL;DR

The KV corruption is **not in the storage stack**. The NVMe target, the NIXL plugin, and LMCache's
memory-object layer all carry the bytes faithfully. The bytes are **already wrong before they are
stored**: LMCache's legacy V2 GPU connector allocates a 2-plane *split* K/V destination for vLLM
0.26's 1-plane *fused* KV cache, so the copy kernel reads with half the correct per-token stride.
Half the tokens, the wrong tokens, and no V at all.

This is an upstream LMCache defect, not a rocm-aic one. It affects **every** backend on this path —
static included. Only the dynamic backend ever reads its data back, which is why only it looked
broken.

The second finding is the more uncomfortable one: **the "verified correct" static backend was never
reading from storage at all.** It recomputes. That is why it looked correct, and why the benchmark
taken against it does not measure the KV path.

| | |
|---|---|
| NVMe KV target (store + retrieve) | ✅ correct — full length, exact `cdw0`, no truncation |
| NIXL plugin descriptors / keys | ✅ correct — counts, lengths, and derived keys all match |
| LMCache page mapping (store↔read) | ✅ correct — page md5s identical byte-for-byte across processes |
| **GPU → staging gather (store side)** | ✅ **FIXED** by `patches/0009-…` — destination is now 1-plane `[1, 22, 256, 512]` |
| **End-to-end cross-process KV read** | ✅ **verified twice** — needle recovered, `need to load: 1024` |
| Static backend read path | ⚠️ **still never exercised** — cannot hit across a restart by construction |
| `use_gpu_connector_v3: True` as a fix | ❌ tried, does not work — V3 dispatches, shape stays 2-plane (init-order) |
| Decode node config mismatch | ✅ repaired — but see the NFS finding; it is one shared file |
| Data written **before** the fix | ❌ **poisoned** — half-empty; a correct reader returns garbage from it |
| P+D disaggregation | ⚠️ unblocked in principle — the defect that blocked it is gone, but P+D itself is untested |

---

## The fix — `patches/0009-lmcache-fused-kv-plane-count.patch`

### Correction: the shape's origin is not where the last handoff said

The previous pass named `integration/vllm/utils.py:278`. That line is real, but it lives in
`create_lmcache_metadata()`, whose **only** caller is `vllm_ec_adapter.py:103` — the EC adapter,
which this deployment does not use. Patching it changes nothing here; a probe inserted there never
fired.

The live path is `VllmServiceFactory.get_or_create_metadata()`,
**`integration/vllm/vllm_service_factory.py:103-109`**, which builds the same hardcoded tuple. Its
effect is visible in the server's own startup line:

```
num_layer: 22, chunk_size: 256, num_kv_head (per gpu): 4, head_size: 64,
hidden_dim (D) for KV (per gpu): 256, use mla: False, kv shape: (22, 2, 256, 4, 64)
```

`kv_shape` feeds `LMCacheMetadata`, and from there **both** consumers that decide the layout: the
staging allocator and the dynamic backend's read layout. Fixing it in one place fixes all of them,
which is why this is the right seam.

### What the patch does

`kv_shape` is built before any KV tensor exists, so the runtime format detector cannot be consulted
— that constraint is real and is what defeated v3. But vLLM's **attention backend** can answer at
init, and authoritatively: `get_kv_cache_shape()` returns exactly the tensor it will go on to
allocate. So the patch asks it:

```
rocm-aic: attention backend TRITON_ATTN reports kv_cache_shape=(8, 4, 16, 128)
  -> kv_plane_count=1, per_head_width=128 (the unpatched assumption would have been (2, 64))
```

- rank 4 → fused, K and V packed in the trailing axis (`2 * head_size` = 128) → `kv_size=1`
- rank 5 with a leading 2 → split → `kv_size=2`, unchanged behaviour
- rank 3 → MLA → `kv_size=1`
- anything else, or any failure to reach the backend → falls back to the old assumption with a
  warning, so a future vLLM that moves this API degrades instead of failing to boot

The query runs inside `set_current_vllm_config(...)`. Without it `get_attn_backend` raises in the
**scheduler** role (measured) and only succeeds in the worker — which would have left the two halves
of one deployment silently disagreeing about the layout. That is the same class of bug as the one
being fixed, so it is worth not reintroducing.

`kv_size` is then carried through `metadata.kv_shape[1]` into
`VLLMPagedMemGPUConnectorV2.__init__`, and `get_shape()` uses it instead of recomputing
`1 if use_mla else 2`. `hidden_dim_size` comes from `kv_shape[4]`, which is now the true per-head
width, so both fused and split stay correct.

Finally, `_initialize_pointers()` **cross-checks** the assumption against the real tensors the
first moment they exist, and raises if they disagree:

```python
detected_kv_size = get_kv_size(kv_caches, self.engine_kv_format)
if detected_kv_size != self.kv_size:
    raise RuntimeError(...)
```

This matters because a mismatch is otherwise undetectable — the byte totals are equal either way,
nothing downstream complains, and the only symptom is silently corrupt KV. On this stack the check
**passes**, which is independent confirmation from the runtime detector that `kv_size=1` is right.

### Verification

All three consumers now agree, where before only the allocator was visible and it read `2`:

```
rocm-aic: attention backend TRITON_ATTN ... -> kv_plane_count=1, per_head_width=128
kv shape: (22, 1, 256, 4, 128)
Paged tensor memory allocator initialized, shapes: [torch.Size([1, 22, 256, 512])] ... align bytes: 5767168
Initialized nixl object backend metadata: shape: torch.Size([1, 22, 256, 512]) ... fmt: MemoryFormat.KV_2LTD
```

`align bytes` is unchanged at 5,767,168 — the same total, re-shaped, which is exactly why this was
invisible for so long.

End-to-end, on the dynamic backend, with **fresh keys** (the target's older data is poisoned):

| run | needle | cold store | after restart | accounting on the read |
|---|---|---|---|---|
| 1 | `sierra papa` | ✅ correct | ✅ **`sierra papa`** | `computed 0, hit 1024, need to load: 1024` |
| 2 | `quebec romeo` | ✅ correct | ✅ **`quebec romeo`** | `need to load: 1024` |

`need to load: 1024` is the number that matters — a genuine cross-process read, not a prefix-cache
hit and not a cold recompute. Reproduce with `/var/tmp/fix_test.txt` and `/var/tmp/fix2.txt` on the
prefill node.

### Now baked into an image

The patch is no longer a `docker cp`. `ROCM_ARCH=gfx942 bash build.sh` staged it as
`patches/lmcache/18-fused-kv-plane-count.patch` and the Docker build applied it:

```
Applied: /app/patches/lmcache/18-fused-kv-plane-count.patch
```

Result tagged **`rocm-aic:kv-planefix`** (also `rocm-aic:latest`). The build took ~10 minutes, not
the ~90 the header quotes, because the layer cache was warm — only the LMCache layer onward
rebuilt. Verified in the image itself, not just the source:

```
$ docker run --rm --entrypoint sh rocm-aic:kv-planefix -c 'grep -c _aic_kv_plane_count .../vllm_service_factory.py'
2
$ ... 'ls /opt/nixl/lib/x86_64-linux-gnu/plugins/ | grep -E "SPDK_NVMe_KV|XNVME_KV"'
libplugin_SPDK_NVMe_KV.so
libplugin_XNVME_KV.so
```

Pre-flight before building, worth repeating before any future pin bump: the patch was checked
against a pristine `LMCache v0.5.3` clone (`git apply --check` → clean), the two files it touches
were confirmed byte-identical to the ones it was developed against, no other patch in the series
touches them, and the **whole 18-patch series was replayed in the Dockerfile's exact lexical order**
against a scratch clone. All clean. That is ~2 minutes of checking against a build that can fail an
hour in.

### Redeployed from the image, and re-verified

Deployed as **`aic-spdk-planefix`** with `INSTANCE=planefix`, which gives it **its own config file**
(`pd-configs/lmcache-planefix-spdk.yaml`) instead of the shared `lmcache-single-spdk.yaml` — so this
deployment cannot clobber the decode node's config, which is exactly what the `INSTANCE` knob from
`610067d` is for. That is the working mitigation for the NFS problem until `CONFIG_DIR` is moved.

The acceptance test was re-run against the image build, with a fresh needle and fresh keys:

| | needle | result |
|---|---|---|
| cold store | `hotel yankee` | ✅ correct |
| **after `docker restart`** | `hotel yankee` | ✅ **correct**, `computed 0, hit 1024, need to load: 1024` |

With `local_cpu: False` and a freshly restarted container there is no local cache to serve that
from — the bytes came back from the NVMe KV target.

**Deploy gotcha:** `HF_HOME` defaults to `~/.cache/huggingface`, which `docker run` cannot create on
the NFS home (`permission denied`, and the deploy dies *after* writing its config). Pass
`HF_HOME=/var/tmp/hf`, which is what the earlier containers used.

Full invocation, for reproduction:

```bash
MODE=inprocess INSTANCE=planefix BACKEND=spdk PORT=8303 GPU=0 \
TENSOR_PARALLEL_SIZE=1 MAX_MODEL_LEN=2048 AIC_KV_POOL=0 \
HF_TOKEN=none HF_HOME=/var/tmp/hf IMAGE_REF=rocm-aic:kv-planefix \
AIC_SPDK_KV_TRID="<trid>" bash deploy.sh
```

---

## The first valid KV-path benchmark

Full result and provenance: `kv-bench/results/<prefill-host>/2026-09-09-kv-spillover-probe/RESULT.md`
on the prefill node. TTFT, cold compute vs read-back from the NVMe KV target, TinyLlama at ~1900
tokens/prompt:

| concurrency | store (cold) | retrieve (from target) | change |
|---|---|---|---|
| 1 | 152.6 ± 28.8 ms | **63.5 ± 3.2 ms** | **2.40x faster** |
| 4 | 289.9 ± 32.2 ms | 274.3 ± 29.3 ms | 1.06x faster |

**Use `bench/kv-spillover-probe`, not `bench/llama-benchy`.** The throughput profile says so in its
own caveat — llama-benchy draws fresh content per cell and never exercises store/retrieve. Running
it would have produced another number that says nothing about KV, which is exactly the mistake the
previous pass recorded.

### Two conditions, each of which silently voids the measurement

Both were violated by earlier attempts in this session, and both produced plausible-looking numbers.

1. **vLLM prefix caching must be off.** It defaults on, and the GPU KV cache here is **8,285,648
   tokens** — so vLLM answers every repeat itself and LMCache is never consulted. The probe's EVICT
   phase (~20k tokens) is 0.2% of that and cannot evict it, which is very likely why the probe's own
   README records "RETRIEVE never reaches the backend" as an unexplained bug since 2026-08-12.
   `deploy.sh` now takes `VLLM_EXTRA_ARGS="--no-enable-prefix-caching"`.

2. **Every run needs fresh seeds.** The backend is persistent, so a repeat run with the same seeds
   measures retrieval in its own STORE phase. **Varying `--sentence-repeats` does not achieve this**
   — `sentence * N` is a strict prefix of `sentence * (N+1)` and chunk keys are prefix-derived, so
   it only rekeys the final chunk. This is the same prefix-keying trap recorded for the needle test,
   and it was walked into again here.

Discarded because of these: a run showing store and retrieve as identical (152 vs 153 ms), and one
showing a flattering 2887 vs 255 ms "11x" at c=4 that did not reproduce.

**Always run the server-side cross-check.** The accepted run matched its prediction exactly:

```
cold (need to load == 0): 40   expected 40 = (8 store + 12 filler) x 2 levels
warm (need to load  > 0): 16   expected 16 = 8 retrieve x 2 levels
```

### On the greedy-decode mismatches

The probe reports 1/8 and 4/8 output mismatches store vs retrieve. They are **not** corruption:
every output on both sides is fluent English sharing a 66–91 character prefix before diverging into
an equally plausible continuation, the direction varies (both phases produce both variants), and
mismatches rise with concurrency — the signature of batch composition, not a lossy path. The prompt
is one sentence repeated 34 times, so the model sits on near-ties. Pre-fix corruption looked
nothing like it (`29.\n\n209.comaparticular, and a/heydatabase.`).

The discriminative check is the needle test on the same configuration: `november five` stored and
recovered exactly, `need to load: 1024`, no restart needed.

---

## ⚠️ The config file is NFS-shared across every node — one file, not one per node

Found while repairing the decode node, and it re-frames the `deploy.sh` bug recorded further down.

The lab home directory is an NFS mount (`<NFS_SERVER>:<LAB_HOME>`) shared by all Setup-3 hosts. The config
path is inside it, and `deploy.sh` derives it as
`CONFIG_FILE="${CONFIG_DIR}/lmcache-${INSTANCE}-${BACKEND}.yaml"` (`deploy.sh:1278`) with
`INSTANCE` defaulting to `${PD_ROLE:-single}`. Both the prefill and decode nodes therefore resolve
to the **same file, same inode**:

```
prefill: inode=2592618328   decode: inode=2592618328   (identical md5)
```

So this was never a co-residency problem. **Any deploy on any node clobbers the mounted config of
every other node using the same `INSTANCE`** — which is precisely how the decode node ended up
describing `nixl_pool_size: 0` while running `2000000`, and why its bind mount reads
`Stale file handle` (the inode was replaced underneath it).

The `INSTANCE` fix in `610067d` is still correct and still worth having, but it only separates
deployments that are given *different* `INSTANCE` values. Two nodes both defaulting to `single`
still collide, silently, across hosts.

**This bit during this session**: repairing the decode node's `nixl_pool_size` to `2000000` also
flipped the prefill node to the static backend on its next restart. It had to be temporarily set
back to `0` to finish testing, then restored.

**Resolved.** The prefill node now writes its config host-local under `AIC_RUNTIME_DIR`, so the two
nodes no longer share a file at all. The NFS `lmcache-single-spdk.yaml` reads `nixl_pool_size:
2000000` and has exactly one remaining user, the decode node, which it correctly describes — proven
by restarting it (below).

### FIXED — runtime state moved off the shared filesystem

`deploy.sh` no longer derives runtime paths from `ROCM_AIC_DIR`. A new **`AIC_RUNTIME_DIR`**
(default `/var/tmp/aic-$(id -u)`) owns both the bind-mounted LMCache config and the log directory:

```
config: /var/tmp/aic-<uid>/pd-configs/lmcache-<instance>-<backend>.yaml
logs  : /var/tmp/aic-<uid>/logs/<instance>
```

`/var/tmp` is host-local and survives reboots, which a bind mount outliving its container needs
(`/run` does not); the uid keeps two operators on one host apart. `ROCM_AIC_DIR` is now **source
only**.

The log directory had the identical defect and is fixed with it — both nodes defaulted to
`INSTANCE=single`, so two hosts were writing one NFS log directory.

**A guard now enforces the class of mistake, not just this instance of it.** `deploy.sh` stats the
filesystem behind `CONFIG_DIR` and refuses `nfs/cifs/smb/9p/glusterfs/ceph/lustre/afs`, pointing at
`AIC_RUNTIME_DIR`; `AIC_ALLOW_SHARED_CONFIG=1` overrides it for a genuinely single-host path. The
check runs **before** the `docker rm -f`, deliberately — a guard that refuses only after destroying
the running container is worse than no guard.

Verified on the real hosts, both directions:

| | result |
|---|---|
| `stat -f -c %T` on the NFS home | `nfs` → matches |
| `stat -f -c %T` on `/var/tmp` | `ext2/ext3` → passes |
| redeploy with the default | config + logs land under `/var/tmp/aic-<uid>/` |
| redeploy with `AIC_RUNTIME_DIR=<nfs path>` | **refused, exit 1** |
| the running container during that refusal | **untouched** — identical `StartedAt` |

Re-verified end-to-end afterwards: needle `oscar mike` stored, container restarted, recovered with
`need to load: 1024`.

**Migration complete.** Both nodes have been redeployed onto `AIC_RUNTIME_DIR`. Verified directly:

```
$ for c in $(docker ps -q); do docker inspect -f '{{.Name}}: {{range .Mounts}}{{.Source}} {{end}}' $c; done | grep /home/
  (nothing, on either node)
```

No container on either host mounts anything from the shared filesystem any more. The stale
`vendor/rocm-aic/pd-configs/` and `logs/` trees on NFS now have zero users and can be deleted
whenever convenient.

---

## `use_gpu_connector_v3` — TRIED, DOES NOT WORK

The one-line config escape hatch is closed. It was applied to `aic-spdk-single` on the prefill node,
tested, and reverted; the instance is byte-identical to its pre-trial state.

**It is not rejected and it is not inert — V3 is genuinely dispatched, and the shape is still
2-plane.** The device gate is not the problem: `_DEVICE_SCOPED_VLLM_BOOL_FEATURES`
(`v1/gpu_connector/__init__.py:17-20`) restricts the flag to `{"cuda", "xpu"}`, and ROCm reports
`torch_device_type == "cuda"` (HIP 7.2), so it passes. A temporary probe on the dispatch branch
confirmed `VLLMPagedMemGPUConnectorV3` by name.

The reason it cannot work is an **initialisation-order** one, and it is the part the previous
handoff got wrong. `LMCacheMetadata.get_shapes()` does read `group.shape_desc.kv_size` — but only
once `kv_layer_groups_manager` exists, and that is populated **lazily**, inside V3's
`_initialize_kv_cache_pointers()` (`gpu_connectors.py:477-482`), which is reached only from
`to_gpu`/`from_gpu` (`:545`, `:579`). Both consumers that actually decide the layout are bound
*before* any of that, so both take the `None` fallback to `metadata.kv_shape` — the hardcoded 2
from `integration/vllm/utils.py:278`:

```
Paged tensor memory allocator initialized, shapes: [torch.Size([2, 22, 256, 256])],
    dtypes: [torch.bfloat16], align bytes: 5767168   (paged_tensor_memory_allocator.py:108)
Initialized nixl object backend metadata: shape: torch.Size([2, 22, 256, 256]),
    dtype: torch.bfloat16, fmt: MemoryFormat.KV_2LTD  (nixl_storage_backend.py:1552)
```

Both lines are from the **v3 run**. The `PagedTensorMemoryAllocator` is fixed-shape (`align_bytes`
is the whole 5,767,168 B chunk), and the dynamic backend's read layout is frozen at init, so even a
later-correct `get_shapes()` could not retroactively change either.

`VLLMPagedMemGPUConnectorV3.get_shape()` is `raise NotImplementedError` (`:640-641`). That never
fires here only because the sole caller is `store_layer` (`cache_engine.py:683`), which is the
`use_layerwise` path. Anyone enabling `use_layerwise` **and** v3 will hit it immediately.

### The measurement

A needle-in-haystack prompt makes this objective rather than a judgement call — `aic_prompt.txt`
ends by asking for a code word, so a correct read has exactly one right answer.

| pass | tokens | accounting | answer |
|---|---|---|---|
| cold, no cache (control) | 1086 | `computed 0, hit 0, load 0` | ✅ `charlie golf` |
| cold, needle changed (control) | 1088 | `computed 0, hit 0, load 0` | ✅ `victor tango` |
| **after restart, from storage** | 1088 | `computed 0, hit 1024, **load 1024**` | ❌ `29.\n\n209.comaparticular, and a/heydatabase.` |

`need to load: 1024` is the important number — a genuine cross-process read, not a prefix-cache hit
and not a cold recompute. The data came back from the target and it was wrong.

**Two traps worth recording**, both of which cost time here:

- Appending `\nAnswer:` is required. Without it TinyLlama emits EOS immediately
  (`completion_tokens: 1`, empty string) and an empty answer looks like corruption but is not.
- Changing the *tail* of the prompt only rekeys the final chunk — chunk keys are prefix-derived. To
  force a genuinely cold store you must change the **beginning** of the prompt.

Reproduce with `/var/tmp/v3final.txt` on the prefill node (md5 `854435096cd096ac81b7f27546b151ba`,
needle `victor tango`) and `/var/tmp/v3req.json`.

---

## NEXT ACTION

**P+D is the only major thing left.** The KV path now has a valid measurement (below).

Disaggregation has still never been run end-to-end here. The defect that blocked it is gone, but
expect it to have its own problems; do not read "gather fixed" as "P+D works".

Smaller follow-ups, in rough priority order:

1. **Upstream the probe fixes.** `--seed-base` lives only in
   `/var/tmp/kvbench/kv_offload_bench_seeded.py` on the prefill node. Without it every repeat run
   of `bench/kv-spillover-probe` silently measures retrieval in its own STORE phase. Its stock
   defaults also overflow TinyLlama's context by exactly one token.
2. **Re-measure on a bigger model.** TinyLlama-1.1B has cheap prefill, so the 2.4x below is a floor,
   not a headline.
3. **`use_layerwise` is a landmine** — `VLLMPagedMemGPUConnectorV3.get_shape()` is
   `raise NotImplementedError` and `store_layer` (`cache_engine.py:683`) is its only caller.

**On purging the target — lower priority than the previous pass implied.** Chunk keys are
content-derived, so pre-fix poisoned entries are only reachable by replaying a pre-fix *prompt*.
Any new benchmark generates new keys and cannot collide with them. The poisoned entries waste RAM
on the target and will mislead anyone who re-runs an old prompt, but they do **not** corrupt new
measurements. Clear it when convenient (the RAM-backed target drops everything on restart) rather
than treating it as a blocker — and note the target is shared with the decode node, so a restart is
not a private action.

Both nodes now run the fix, so nothing in the lab is still writing corrupt chunks.

**Moving the image between hosts — verify by CONTENT, not by image ID.** The README already warns
"same tag ≠ same image"; the inverse also bites. `docker save | ssh docker load` produced a
*different* image ID on the receiving host for byte-identical content:

```
prefill: sha256:ce7c3279…    decode: sha256:84eeb9b4…
```

Both contain the same files (`md5` of the two patched sources matches exactly, both plugins
present). Compare file hashes inside the image, not IDs, or you will chase a difference that is not
there. Note also that the decode node had its own unrelated `rocm-aic:latest` — always transfer and
deploy by an explicit tag.

The two nodes can `ssh` to each other directly, so the transfer does not need to be routed through
a workstation:

```bash
docker save rocm-aic:kv-planefix | ssh <other-node> 'docker load'
```

Two things worth carrying forward regardless:

- **`use_layerwise` is now a landmine.** `VLLMPagedMemGPUConnectorV3.get_shape()` is
  `raise NotImplementedError` and `store_layer` (`cache_engine.py:683`) is its only caller. Enabling
  layerwise with v3 will hit it immediately.
- **The static backend still cannot read across a restart** — unchanged by this patch, and
  structural (fresh `uuid4` per process in its key derivation). It is still not a control.

**Do not rebuild the image just to iterate.** Patch Python in place while experimenting:

```bash
docker cp <file> aic-spdk-single:/usr/local/lib/python3.12/dist-packages/lmcache/...
docker restart aic-spdk-single      # ~80-90s to ready
```

Seconds, not the ~90 minutes a full image build costs. Rebuild only to make it durable.

---

## The defect, with evidence

Each KV chunk is 5,767,168 B, declared as `MemoryFormat.KV_2LTD`, `torch.Size([2, 22, 256, 256])`,
bf16 — 44 planes of `[256,256]`, 131,072 B each. Fingerprinting the staging buffer at store time,
gathered from a **cold, correct prefill whose own completion was coherent English**:

| planes | bytes | content |
|---|---|---|
| 0–21 — `tensor[0]`, **K**, all 22 layers | 2,883,584 | real, distinct per chunk and per prompt |
| 22–31 — `tensor[1]`, **V**, layers 0–9 | 1,310,720 | one fixed 128 KiB block repeated 10×, **identical across two unrelated prompts** |
| 32–43 — `tensor[1]`, **V**, layers 10–21 | 1,572,864 | all zero |

So the model's KV cache was good, and the gather turned it into a half-empty chunk. Everything
below faithfully stored and returned those already-wrong bytes.

### Root cause — confirmed

**LMCache allocates a 2-plane split destination for a KV cache that is 1-plane fused, and the copy
kernel derives its source stride from that wrong shape.**

vLLM 0.26.0 presents a rank-4 **fused** cache: `22 × [517853, 16, 4, 128]`, where the trailing
`CS = 2 * head_size = 128` packs K and V together.
`gpu_connector/kv_format/detectors/vllm.py:43-51` correctly classifies it
`EngineKVFormat.NL_X_NB_BS_NH_CS`, and `NL_X_NB_BS_NH_CS_Spec.kv_size()` correctly returns **1** —
"K/V stay packed in the content axis; a single fused plane", per-token width `NH*CS = 512`.

Two places ignore that and hardcode 2:

- `VLLMPagedMemGPUConnectorV2.get_shape()` (`gpu_connectors.py:416-418`):
  `kv_size = 1 if self.use_mla else 2` → a split `KV_2LTD [2, NL, T, num_kv_head*head_size]`,
  i.e. per-token width **256**.
- `integration/vllm/utils.py:278`:
  `kv_shape = (num_layer, 1 if use_mla else 2, chunk_size, num_kv_head, head_size)`. This is
  computed from the model config at engine init — *before* the KV tensors exist and before
  `_initialize_pointers` detects the format — so it structurally **cannot** know the cache is fused.

The byte totals coincide (`2*22*256*256 == 1*22*256*512`), which is why nothing downstream ever
complains.

Measured consequence: the transfer reads token *i* from engine element offset `slot_mapping[i]*256`
when the true per-token stride is `512`. So the source token index is effectively **halved**, only
half the payload per token is copied, only **128 of 256** tokens are represented, what lands in the
"K" plane is really K and V interleaved by head *for the wrong tokens*, and the V plane is **never
written at all**.

A brute-force needle search over all 11.5 M int16 of the request's KV slots located every
destination row at exactly one place: `dest[0,L][row r]` = layer `L`, token
`slot_mapping[start]/2 + r/2`, byte offset `(r%2)*512`. 12/12 exact md5 matches to that wrong-stride
model across 4 chunks × 3 layers; 0/12 to any correct gather.

**The kernel is not at fault — the destination shape is.** Handing the *same*
`multi_layer_kv_transfer`, same format, same `head_size=128`, same pointers, a single-plane
`[1, 22, 256, 512]` buffer produced a byte-exact correct fused gather with zero poison remaining.
Keeping 2 planes but passing `head_size=64` still wrote only plane 0.

### How the poison test settled it

Filling both `memory_obj.tensor` and `self.gpu_buffer` with `0xA5A5` before the gather: the V plane
read back `poison=65536/65536` at L=0, 10 and 21, on every chunk. On the *following* un-poisoned
chunk the V plane was **still** 100% poison — carried over from the previous chunk's fill of the
reused `gpu_buffer`.

That kills the "write bounded at 4 MiB" alternative outright. 2,883,584 + 1,310,720 = exactly
4 MiB was a **coincidence**: the V region's content tracks allocator history, so it is untouched
residue. It also explains why the junk block was identical across unrelated prompts — `gpu_buffer`
is allocated once in `__init__` and its V half is never written by anything.

---

## ⚠️ Correction to the previous handoff: static is not a control

The previous handoff recorded the single-node static backend as "✅ correct, benchmarked". That
status was measured, on the same host and the same image as the dynamic instance, and it does not
hold in the way it reads:

| op, cumulative over 3 processes | static | dynamic |
|---|---|---|
| `postXfer op=READ` | **0** | 6 |
| `queryMem` | **0** | 12 |
| `postXfer op=WRITE` | 3 | 1 |

**The static backend never issued a single read or lookup.** Every pass logged
`Inference Engine computed tokens: 0, LMCache hit tokens: 0, need to load: 0` — a full cold prefill
followed by a fresh store. Its output was coherent and byte-identical across passes because it was
*recomputed each time*, not retrieved.

This is structural, not incidental. `NixlObjectPool` names slots
`obj_{i}_{uuid.uuid4().hex[0:4]}` (`nixl_storage_backend.py:383`) — a fresh uuid4 per process, so
the derived key changes on every restart (observed `76d3` → `8976` → `e80d` for slot 1999999). And
`NixlStaticStorageBackend.contains()` (`:1242-1260`) is a pure in-process `key_dict` lookup, empty
after a restart. So static **cannot** serve a cross-process hit, and within one process vLLM's
prefix cache absorbs any repeat before LMCache is consulted.

Consequences:

- Static's read path has never been exercised. It is not evidence that reads work.
- It cannot expose the gather defect, which is why dynamic looked uniquely broken. **Both backends
  are storing half-empty chunks**; only the one that reads notices.
- `AIC_KV_POOL=0` is not "actively dangerous" relative to the default, as the previous handoff
  stated. It is the only setting that reads back at all, and therefore the only one that surfaces a
  defect both share.

---

## `deploy.sh` destroying a co-resident in-process deployment — FIXED

Two independent failure modes, both hit when deploying a second in-process instance on one host:

1. `CONTAINER_NAME="aic-${BACKEND}-${PD_ROLE:-single}"` was hardcoded and `docker rm -f`'d
   unconditionally. `COMPOSE_PROJECT` does not disambiguate it — on this path that value is only
   ever attached as a docker *label*.
2. `CONFIG_FILE` resolved to a fixed path, `pd-configs/lmcache-single-spdk.yaml`, which is
   bind-mounted **into the already-running container**. A second deploy rewrote it underneath the
   live instance — and it did so *before* the removal, so even a failed deploy left the running
   container pointing at someone else's config.

Failure mode 2 already bit: the decode node's mounted `config.yaml` read `nixl_pool_size: 0`,
while the process actually running there loaded `2000000` and logged
`Created backend: NixlStorageBackend (NixlStaticStorageBackend)`. The file on disk did not
describe the running container, so a restart would silently have swapped the decode node onto the
dynamic backend.

**This has now been repaired (2026-09-09).** `nixl_pool_size` on
`<SETUP3_DECODE_NODE>:~/rocm-aic/vendor/rocm-aic/pd-configs/lmcache-single-spdk.yaml` is back to
`2000000`; the previous file is saved as
`/var/tmp/kvdiag/lmcache-single-spdk.yaml.mismatched.<timestamp>`. Nothing was restarted — the
container is still the same 26-hour-old process, still the untouched reference instance. The
repaired file was verified by parsing it with LMCache's own loader in that container and comparing
every key against the live process's startup config:

```
nixl_pool_size = 2000000   dynamic_storage = False   => NixlStaticStorageBackend
```

which matches `dynamic_storage = pool_size == 0` (`nixl_storage_backend.py:208`) and the backend the
live process actually built. `2000000` is also `AIC_KV_POOL`'s default (`deploy.sh:663`), so a plain
redeploy now reproduces the running state rather than diverging from it.

One artefact worth knowing, because it is the physical signature of this failure: inside the
container `cat /etc/lmcache/config.yaml` returns **`Stale file handle`**. The overwriting deploy
replaced the file's *inode* on NFS, and the bind mount still points at the deleted one. The running
process is unaffected (it read its config at startup), and `docker restart` re-resolves the path —
but it means you cannot read the live container's config through the mount. Read the startup log.

The fix keys the container name, the config file and the log directory off a new `INSTANCE`
(default `${PD_ROLE:-single}`, so no existing name changes), moves the removal to *before* the
config write, and refuses two specific accidents:

| situation | behaviour |
|---|---|
| redeploy same instance, same port | proceeds |
| second deploy, `INSTANCE` not set, different port | **refuses** — points at `INSTANCE=` / `REPLACE=1` |
| same, with `REPLACE=1` | proceeds |
| `INSTANCE=<other>`, free port | proceeds |
| `INSTANCE=<other>`, port already held | **refuses** — names the holder |

All five verified against live container state under `set -euo pipefail`.

---

## What is deployed right now

| Node (placeholder) | Role | State |
|---|---|---|
| `<SETUP3_PREFILL_NODE>` | patched host | **`aic-spdk-planefix` :8303, `rocm-aic:kv-planefix`, dynamic backend, GPU 0** — the fix baked in, deployed by `deploy.sh`, acceptance-tested. Uses its **own** config `lmcache-planefix-spdk.yaml`, so it no longer shares a file with the decode node. The old `aic-spdk-single` diagnosis container was removed (its `docker cp` patch is now in the image). `aic-spdk-static` :8304 stays torn down; GPU 1 free. |
| `<SETUP3_DECODE_NODE>` | decode | **`aic-spdk-single` :8302, `rocm-aic:kv-planefix`, static, GPU 1 — redeployed 2026-09-09.** Now on the fix (`kv shape: (22, 1, 256, 4, 128)`) and on host-local `AIC_RUNTIME_DIR`. Config preserved as `nixl_pool_size: 2000000`, so it is still `NixlStaticStorageBackend` and still cannot read across a restart — that is structural, not something this patch changes. Before the redeploy it was restarted from its old image and came back identically (`2000000` / static), which is the proof the earlier config repair held. |
| `<SETUP3_TARGET_NODE>` | SPDK KV target | running: `max_io_size=16MB`, `max_io_qpairs_per_ctrlr=512`, never restarted. **Holds a mix**: everything written before the fix is poisoned; the two verification runs are correct. Clear it before benchmarking. |

Target-reported limits, from the plugin's own startup line:
`device KV format 0: value_max=67108864 key_max=16, ctrlr max_xfer=16777216 -> effective=16777216`
(compiled-in default 524288). 5.5 MB values fit comfortably; size is not a constraint here.

Images on the prefill node: `rocm-aic:kv-dbg2` (current, both instrumentation rounds),
`rocm-aic:kv-dbg`, `rocm-aic:kv-query-final`, `rocm-aic:kv-canonical`.

Diagnostic artifacts on the prefill node under `/var/tmp/kvdiag/` — including
`nixl_storage_backend.py.orig` (pristine) — and `/var/tmp/aic_prompt.txt`, the 854-word test prompt
(md5 `6d0069ecbc2d0aa8b18c81e06806089a`). The container's patched Python was reverted and verified.

---

## Instrumentation added (uncommitted)

`plugins/nvme-kv/spdk_nvme_kv_backend.cpp` — gated by `NIXL_KV_DEBUG_XFER=<n>`, the number of
`postXfer`/`queryMem` **calls** to dump. Inert when unset; the disabled path is one load of a
function-local static.

- `postXfer` dump: per-side descriptor counts, per-descriptor lengths, `devId`/`addr`, whether
  `metadataP` is null, `metaInfo`, and the derived 12-byte key — with explicit
  `<-- DESC COUNT MISMATCH` / `<-- BYTE TOTAL MISMATCH` markers.
- `queryMem` dump: the same, from the derivation the probe actually uses, so a lookup key and a
  store key can be compared by eye.
- Completion dumps: `store cpl` and `retrieve cpl` lines carrying status, `sct`/`sc`, and — on
  retrieve — **`cdw0`**, the true stored value length, with a `<-- LENGTH MISMATCH` marker. This
  matters because the target completes SUCCESS in *both* truncation directions
  (`kvmalloc_handle_retrieve` does `copy_len = min(data_len, entry->value_len)`), so without `cdw0`
  a short read is indistinguishable from a correct one.

`deploy.sh` — plumbs `NIXL_KV_DEBUG_XFER` through the **in-process** path only. The sidecar
(`MODE=mp`) path would also need it in the compose service's `environment:` list; passing it there
without that would silently do nothing.

---

## What the measurement settled

Every hypothesis in the previous handoff's decision table is dead, **including its premise**. It
expected `page_size = memory_allocator.align_bytes = 4096`; for `PagedTensorMemoryAllocator`,
`align_bytes` is the *whole chunk* (`paged_tensor_memory_allocator.py:62-63`, `# full chunk size
bytes`), and CPU mode is guarded to that allocator class.

Measured on both store and read:

| | store | read |
|---|---|---|
| descriptor counts, local/remote | 4 / 4 | 4 / 4 |
| per-descriptor length | 5767168 B both sides | 5767168 B both sides |
| `metaInfo` | real content-derived name | same name |
| derived 12-byte key | 4 distinct | **identical to store's** |
| NVMe completion | SUCCESS | SUCCESS, `cdw0` == requested |

Also killed along the way:

- **`metaInfo` empty → key falls back to a pool slot index.** Not happening;
  `meta=TinyLlama_..._<hash>_bfloat16`, `md=yes`.
- **All descriptors of one object alias onto one key.** Not happening; all four keys distinct.
- **Store/read layout disagreement.** Not happening; both carry
  `torch.Size([2, 22, 256, 256])` / bf16 / `KV_2LTD`. The asymmetry is real as a design fragility —
  the dynamic store records no layout (`nixl_storage_backend.py:1838-1846`) while the dynamic read
  invents one from config (`:1684-1712`, `:1540-1551`), where static uses recorded per-key metadata
  (`:1185-1205`) — but it is not firing.
- **Recycled/aliased destination page.** Not happening; `raw_ptr == page_ptr == expect_ptr`, pages
  verified all-zero pre-transfer and correctly filled post-transfer.

---

## Test methodology — still true, and one addition

**vLLM's own prefix cache will fake a passing result.** Same prompt twice against one instance and
the second is served without touching storage:

```
Total tokens 1350, Inference Engine computed tokens: 1344, LMCache hit tokens: 1280, need to load: 0
                                                                                     ^^^^^^^^^^^^^^
```

Restart the container between passes and require `need to load` to be non-zero.

**New:** `need to load: 0` **together with** `Inference Engine computed tokens: 0` and
`hit tokens: 0` is a different thing again — a full cold recompute, not a prefix-cache hit. That is
what the static backend does on every pass, and reading it as "correct" is what produced the
previous handoff's incorrect status. Check all three numbers, not just one.

Second trap unchanged: a prompt shorter than `chunk_size` (256 tokens) is never stored. Use ≥ 800
words, and keep prompt + `max_tokens` under `MAX_MODEL_LEN` (2048 for TinyLlama).

Third: another user may be issuing requests to the same endpoint. Match on `Total tokens` (1074 for
`aic_prompt.txt`) before trusting a log line is yours.

---

## Other traps worth knowing

- **Don't run `deploy.sh` under `sudo` on an NFS home.** `root_squash` maps root to `nobody` and it
  dies on `mkdir`. Run as your user; pre-allocate hugepages once with sudo.
- **`ROCM_ARCH` is required even with `SKIP_BUILD=1`.**
- **Plugins present ≠ patches present.** Check both.
- **Same tag ≠ same image.** Build once, `docker save | ssh docker load`.
- **`pgrep`/`pkill -f` with a pattern that matches your own SSH command string will kill your own
  shell.**
- **MP mode cannot span hosts.** `LMCacheMPConnector` moves KV via CUDA/HIP IPC handles, which are
  node-local.
- **`patches/0007` only covers the sidecar path.** It patches
  `lmcache/v1/distributed/l2_adapters/nixl_store_l2_adapter.py`, so the in-process path issues
  unsplit 5.5 MB values while the plugin still advertises `max_value_size=524288` through
  `getParams()`. Harmless on this target (effective limit 16 MB) but a real inconsistency.

---

## Benchmark status

`llama-benchy` results in `kv-cache/results/<SETUP3_DECODE_NODE>/2026-09-08-llama-benchy/` are
stamped `VERDICT: UNTUNED`. That stamp should now be read as stronger than "untuned": the harness
warned that *"a serving sweep ... does not necessarily exercise KV store/retrieve at all"*, and that
is now **confirmed** rather than suspected — the endpoint it ran against issued zero reads and zero
lookups. It characterises the serving stack with the storage tier dormant.

`bench/kv-spillover-probe/` remains the right tool, and remains un-run. It is not worth running
until the gather defect is fixed, because every chunk currently stored is half empty.

---

## Recovery

Three long-running deployments (ATOM, MORI, kvng) were stopped to free GPUs. `docker inspect` JSON
for each is in `lab/recovery/` — enough to reconstruct them.

`kvng-xnvme-offload-8000` held `/dev/ng3n1` on a real Pensando DSC3. It was stopped with
authorisation and **did not wedge the device** — `nvme list` clean afterwards, PCIe link still
32 GT/s x16. The safety rule at the top of `README.md` still stands; one clean stop is not evidence
that it is safe.
