# HANDOFF — 2026-09-09 (third pass)

The second pass's NEXT ACTION has been carried out. `use_gpu_connector_v3: True` **does not fix
the gather** — it is accepted, the V3 connector really is dispatched, and the destination is still
2-plane. The root cause identified in the second pass stands unchanged; what has moved is that the
cheap escape hatch is now closed and the fix must be a patch. The decode node's config mismatch has
been repaired.

The root-cause analysis below (second pass) is unchanged and still correct; the measurement that
produced it is reproducible from the instrumentation now in the tree.

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
| **GPU → staging gather (store side)** | ❌ **root cause — 2-plane destination for a 1-plane fused cache** |
| Static backend read path | ⚠️ **never exercised** — cannot hit across a restart by construction |
| `use_gpu_connector_v3: True` as a fix | ❌ **tried, does not work** — V3 dispatches, shape stays 2-plane (init-order) |
| Decode node config mismatch | ✅ **repaired** — file now describes the live process; nothing restarted |
| Data already on the target | ❌ **poisoned** — every chunk ever stored is half-empty; a correct reader still returns garbage |
| P+D disaggregation | ❌ still blocked, but on the defect above, not on anything in this repo |

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

**Patch the shape at its origin — `integration/vllm/utils.py:278` — and carry it in `patches/`.**
There is no config-only route left.

```python
kv_shape = (num_layer, 1 if use_mla else 2, chunk_size, num_kv_head, head_size)
```

This runs at engine init, before the KV tensors exist, so it cannot *detect* the fused layout — it
has to be told. For vLLM 0.26 on this stack the correct value is `kv_size = 1` with per-token width
`num_kv_head * 2 * head_size = 512`, which is what `NL_X_NB_BS_NH_CS_Spec.kv_size()` already returns
once tensors exist. Patch `VLLMPagedMemGPUConnectorV2.get_shape()` (`gpu_connectors.py:416-418`) to
match, so the allocator, the backend metadata and the gather all agree on one plane.

Do it under V2 and leave `use_gpu_connector_v3` at its default — v3 buys nothing here and adds the
`store_layer` landmine above.

Verify with the protocol in the table above: the post-restart read must return `victor tango` with
`need to load` non-zero. The gather being correct is necessary but not sufficient — **every chunk
currently on the target was written half-empty and must be treated as poisoned**; clear it or use
fresh keys, or a correct reader will still return garbage from old data.

**Do not rebuild the image to test this.** Patch the Python in place:

```bash
docker cp <file> aic-spdk-single:/usr/local/lib/python3.12/dist-packages/lmcache/v1/...
docker restart aic-spdk-single      # ~80s to ready
```

Seconds, not the ~90 minutes a full image build costs.

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
| `<SETUP3_PREFILL_NODE>` | diagnosis host | `aic-spdk-single` :8303 (dynamic, GPU 0), `rocm-aic:kv-dbg2`. Restored to its exact pre-v3-trial state: config byte-identical, container Python pristine, `use_gpu_connector_v3` back to `False`. The static control `aic-spdk-static` :8304 stays torn down; GPU 1 is free. |
| `<SETUP3_DECODE_NODE>` | decode | `aic-spdk-single` :8302, `rocm-aic:kv-canonical`, static — process still **untouched** (not restarted). Its on-disk config was repaired to match it, see above. |
| `<SETUP3_TARGET_NODE>` | SPDK KV target | running: `max_io_size=16MB`, `max_io_qpairs_per_ctrlr=512`, never restarted. **Holds poisoned data** — every chunk stored by any backend so far is half-empty and mis-strided. |

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
