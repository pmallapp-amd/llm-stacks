# HANDOFF — 2026-09-08 (second pass)

The previous handoff's NEXT ACTION has been carried out. It answered the question it set out to
answer, and the answer was "the hypothesis is wrong" — so the blocker has moved. This document
replaces the earlier one; the measurement that produced it is reproducible from the instrumentation
now in the tree.

**Hostnames are placeholders here**, per this repo's convention. Real IPs, credentials and BMC
addresses are in `lab/lab-inventory.local.md` (gitignored, never committed). Read that first.

Branch `rocm-aic`, **not pushed**. The plugin instrumentation described below is **uncommitted**.

---

## TL;DR

The KV corruption is **not in the storage stack**. The NVMe target, the NIXL plugin, and LMCache's
memory-object layer all carry the bytes faithfully. The bytes are **already wrong before they are
stored** — the gather out of vLLM's GPU KV cache into LMCache's staging buffer fills only the K
half of each chunk.

The second finding is the more uncomfortable one: **the "verified correct" static backend was never
reading from storage at all.** It recomputes. That is why it looked correct, and why the benchmark
taken against it does not measure the KV path.

| | |
|---|---|
| NVMe KV target (store + retrieve) | ✅ correct — full length, exact `cdw0`, no truncation |
| NIXL plugin descriptors / keys | ✅ correct — counts, lengths, and derived keys all match |
| LMCache page mapping (store↔read) | ✅ correct — page md5s identical byte-for-byte across processes |
| **GPU → staging gather (store side)** | ❌ **writes K, leaves V unwritten** |
| Static backend read path | ⚠️ **never exercised** — cannot hit across a restart by construction |
| P+D disaggregation | ❌ still blocked, but on the defect above, not on anything in this repo |

---

## NEXT ACTION

**Confirm the fault site inside `lmc_ops.multi_layer_kv_transfer`, then decide where the fix
belongs — almost certainly upstream in LMCache, not here.**

The cleanest discriminator is a **poison test**: fill the destination `memory_obj.tensor` with a
distinctive pattern (e.g. `0xA5A5`) immediately before the gather, run one store, and read the V
region back.

| Observation | Conclusion |
|---|---|
| V region still reads `0xA5A5` | V is **never written** — the gather only emits the K half |
| V region reads zeros or the repeated constant | something *is* writing it; the fault is a wrong source offset, not an omission |

Instrument LMCache's GPU connector immediately after `lmc_ops.multi_layer_kv_transfer` returns
(`/usr/local/lib/python3.12/dist-packages/lmcache/v1/gpu_connector/`), and for layers 0, 10 and 21
compare `memory_obj.tensor[0, L]` (K) and `[1, L]` (V) against a direct torch gather from
`kv_caches[L]` using the request's `slot_mapping`, de-interleaving the packed trailing axis
yourself. The copy kernel itself is compiled into `lmcache.c_ops` and cannot be read — measure its
effect instead.

**Do not rebuild the image to test this.** Patch the Python in place:

```bash
docker cp <file> aic-spdk-single:/usr/local/lib/python3.12/dist-packages/lmcache/v1/...
docker restart aic-spdk-single
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

The format mismatch that explains it: vLLM 0.26.0 presents a **rank-4 fused** KV cache, and
`gpu_connector/kv_format/detectors/vllm.py:43-51` classifies *any* rank-4 vLLM tensor list as
`EngineKVFormat.NL_X_NB_BS_NH_CS`, whose trailing `CS` axis is `2 * head_size` — K and V packed
together. LMCache's destination metadata is `kv_shape=(22, 2, 256, 4, 64)`, a **split** K/V layout
with `head_size=64`. The de-interleave of the packed axis into the separate one is where the K half
survives and the V half does not.

Note the two readings of the byte counts, which the poison test separates: 2,883,584 + 1,310,720 is
exactly 4 MiB, which could mean a write bounded at 4 MiB — or could be 22 planes of real data
followed by 10 planes of coincidental allocator residue. Do not assume the round number is
meaningful.

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

Failure mode 2 already bit: the decode node's mounted `config.yaml` reads `nixl_pool_size: 0`,
while the process actually running there loaded `2000000` and logged
`Created backend: NixlStorageBackend (NixlStaticStorageBackend)`. **The file on disk does not
describe the running container.** That instance is still live and still mismatched — read the
container's own startup log, not the config file, and expect it to adopt the *other* config if it
is ever restarted.

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
| `<SETUP3_PREFILL_NODE>` | diagnosis host | `aic-spdk-single` :8303 (dynamic, GPU 0), `rocm-aic:kv-dbg2`. The static control `aic-spdk-static` :8304 was torn down once it had served its purpose; GPU 1 is free. |
| `<SETUP3_DECODE_NODE>` | decode | `aic-spdk-single` :8302, `rocm-aic:kv-canonical`, static — **untouched throughout** |
| `<SETUP3_TARGET_NODE>` | SPDK KV target | running: `max_io_size=16MB`, `max_io_qpairs_per_ctrlr=512`, never restarted |

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
