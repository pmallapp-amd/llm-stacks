# HANDOFF — 2026-09-08

State of the P+D disaggregation bring-up on the Austin MI300X cluster, what was fixed, what is
still broken, and the one thing to do next.

**Hostnames are placeholders here**, per this repo's convention. Real IPs, credentials and BMC
addresses are in `lab/lab-inventory.local.md` (gitignored, never committed). Read that first.

Commits: `e3e5eba` (build + target + queryMem), `0b399ff` (corruption localised). Branch
`rocm-aic`, **not pushed**.

---

## TL;DR

Five real defects fixed — two of which meant this repo could not build at all. STORE now works
end to end and KV genuinely moves through the SPDK target. **P+D is still not usable**, blocked by
one remaining defect that is now precisely localised. A benchmark was run, but only on the
configuration that is verified correct.

| | |
|---|---|
| Single node, **static** backend (default `AIC_KV_POOL`) | ✅ correct, benchmarked |
| Cross-process lookup (`queryMem`) | ✅ correct both directions |
| **Dynamic** backend read path (`AIC_KV_POOL=0`) | ❌ **returns wrong data** |
| P+D disaggregation | ❌ blocked — it requires the dynamic backend |

---

## NEXT ACTION

**Confirm the descriptor granularity mismatch at the NIXL dlist level.** That single measurement
decides where the fix belongs, and everything else is blocked behind it.

Instrument `postXfer()` in `plugins/nvme-kv/spdk_nvme_kv_backend.cpp` to log, for one transfer:

- `local.descCount()` vs `remote.descCount()`
- each `local[i].len` and `remote[i].len`

Then run a single store of one 256-token chunk and read the counts.

**What the answer means:**

| Observation | Conclusion | Fix belongs in |
|---|---|---|
| `local` has N page-sized descs, `remote` has 1 | Confirms the mismatch | plugin — gather N pages into one KV value |
| counts match but `remote[i].len` is 4096, not 5.5 MB | Registration size is wrong | LMCache — `page_size` passed to `_acquire_storage_handle` |
| counts and lengths both match | Hypothesis is wrong | look at value assembly inside the plugin's retrieve path |

The relevant LMCache code is at `nixl_storage_backend.py:1838` (`mem_to_storage`, dynamic) and
`_acquire_storage_handle`, which passes `page_size = self.memory_allocator.align_bytes` (4096)
while `_build_descs()` emits **one object per chunk** (5.5 MB for TinyLlama at `chunk_size=256`).
The static pool matched 1:1 — one object per 4096 B page — and is correct. Extract the file with:

```bash
docker create --name tmpx rocm-aic:kv-query-final
docker cp tmpx:/usr/local/lib/python3.12/dist-packages/lmcache/v1/storage_backend/nixl_storage_backend.py .
docker rm tmpx
```

**Do not rebuild the image to test this.** Compile the plugin in-place instead (~2 min vs ~90):

```bash
docker run --rm -v ~/rocm-aic/plugins/nvme-kv:/src:ro -v /var/tmp/kvplugin:/out \
  --entrypoint bash rocm-aic:kv-query-final -c \
  'cp -r /src /b && meson setup /tmp/b /b -Dnixl_path=/opt/nixl -Dspdk_path=/opt/spdk-kv \
     -Drocm_path=/opt/rocm -Denable_vram=true --prefix=/opt/nixl --buildtype=release \
   && ninja -C /tmp/b && cp /tmp/b/libplugin_SPDK_NVMe_KV.so /out/'
# then bake a thin layer and deploy with IMAGE_REF=
printf 'FROM rocm-aic:kv-query-final\nCOPY libplugin_SPDK_NVMe_KV.so /opt/nixl/lib/x86_64-linux-gnu/plugins/\n' \
  > /var/tmp/kvplugin/Dockerfile
docker build -q -t rocm-aic:kv-test /var/tmp/kvplugin
```

---

## The blocker, with evidence

`NixlDynamicStorageBackend` returns **wrong data** on read. Correct key, full byte count, wrong
content. It is **not** a P/D problem — it reproduces on a single node:

```
PASS1 (store):                     ' the very first code word listed was "charlie golf"'
PASS2 (after restart, from store): ' fox20000039999999'
                                   hit tokens: 1280, need to load: 1280
LMCache INFO: Retrieved 1280 out of 1280 required tokens. size: 0.0269 gb, 0.9242 GB/s
```

Why this matters more than a plain miss: the dynamic backend is the **only** LMCache storage
backend whose keys are content-derived, so it is the only one that can share a namespace across
processes — which is the whole basis of P+D via shared storage. Until the read is correct, P+D
cannot work, and `AIC_KV_POOL=0` is actively dangerous: it turns "never hits" into "hits with
wrong data".

**Keep `AIC_KV_POOL` at its default (static) until this is fixed.**

---

## ⚠️ Test methodology — read before trusting any correctness check

**vLLM's own prefix cache will fake a passing result.** Send the same prompt twice to one
instance and the second is served from vLLM's prefix cache without touching storage:

```
Total tokens 1350, Inference Engine computed tokens: 1344, LMCache hit tokens: 1280, need to load: 0
                                                                                     ^^^^^^^^^^^^^^
```

Output matches, the check looks green, and **storage was never read**. An earlier run of exactly
this check passed for exactly this wrong reason.

To force a read through the storage tier, **restart the container between passes** and require
`need to load` to be non-zero. That is what exposed the corruption above.

Second trap: a short prompt (< `chunk_size`, default 256 tokens) is never stored at all, so it
also proves nothing. Use ≥ 800 words, and keep prompt + `max_tokens` under `MAX_MODEL_LEN`
(2048 for TinyLlama) or the request 400s.

---

## What is deployed right now

| Node (placeholder) | Role | State |
|---|---|---|
| `<SETUP3_PREFILL_NODE>` | prefill | **clean** — P/D torn down |
| `<SETUP3_DECODE_NODE>` | decode | `aic-spdk-single` on `:8302` — static backend, **verified correct**, benchmarked |
| `<SETUP3_TARGET_NODE>` | SPDK KV target | running: `max_io_size=16MB`, `max_io_qpairs_per_ctrlr=512` |

The P/D pair and the dynamic single-node instance were deliberately **removed** — they produced
corrupt output and should not sit there looking serviceable.

Images on the GPU nodes:

- `rocm-aic:kv-query-final` — current, all patches + `queryMem` (also tagged `latest` on prefill node)
- `rocm-aic:kv-canonical` — same minus `queryMem`; what the running single-node instance uses
- `rocm-aic:kv-query`, `rocm-aic:kv-fix` — thin throwaway layers from bisecting

The SPDK target is **not** managed by any supervisor. If it dies, restart with
`SPDK_SRC=<...> LISTEN_ADDR=<routable-ip> HUGE_PAGES=256 bash target.sh` — `LISTEN_ADDR` must be
the routable IP, not the default loopback.

---

## What was fixed (and why each was invisible)

1. **`build.sh` staged SPDK patches as `*.patch`; the Dockerfile globs `*.diff`.** Failed at build
   stage 27/33 — after ~40 min of successful vLLM/NIXL compilation.
2. **Both `meson.build` files referenced the removed `src/` level.** Hard meson error, immediately
   after SPDK finished building.
3. **`target.sh` `max_io_size` was 1 MB; one TinyLlama KV chunk is 5.5 MB.** The target rejected
   every write (`SGL length 0x580000 exceeds max io size 0x100000`) and let the qpair die on a
   30 s timeout. The client saw only `CQ transport error -6` while LMCache logged a successful
   `Stored 1024 of 1024 tokens`. **The target-side log is the only place the real reason appears** —
   check it first when stores look successful but `completed_nvme_io` doesn't move.
4. **`max_io_qpairs_per_ctrlr`:** one plugin instance takes all 127 default qpairs, starving the
   second role. Note the exact key — SPDK v26.05 silently ignores `max_qpairs_per_ctrlr`.
5. **`queryMem()` implemented** via NVMe KV Exist, dispatched to reactor 0 through
   `spdk_thread_send_msg` (never touching a qpair from the caller thread). Bounded wait
   (`NIXL_KV_QUERY_TIMEOUT_MS`, default 2 s); every failure path degrades to a miss, so a false
   hit is not representable.

---

## Other traps worth knowing

- **Don't run `deploy.sh` under `sudo` on an NFS home.** `root_squash` maps root to `nobody` and it
  dies on `mkdir`. Run as your user; pre-allocate hugepages once with sudo.
- **`ROCM_ARCH` is required even with `SKIP_BUILD=1`.**
- **Plugins present ≠ patches present.** The pre-existing images had both `.so` files but not the
  LMCache patches. Check both.
- **Same tag ≠ same image.** The two GPU nodes were running *different* builds of
  `libplugin_SPDK_NVMe_KV.so` under `rocm-aic:latest`. Build once, `docker save | ssh docker load`.
- **`pgrep`/`pkill -f` with a pattern that matches your own SSH command string will kill your own
  shell.** Cost several confusing "it didn't start" cycles here.
- **MP mode cannot span hosts.** `LMCacheMPConnector` moves KV via CUDA/HIP IPC handles, which are
  node-local; a remote client dies in `_get_device_index_from_uuid`. `deploy.sh` is right to refuse
  `PD_ROLE` with `MODE=mp`, though for a stronger reason than its comment says.

---

## Benchmark status

`llama-benchy` was run against the verified-correct single-node endpoint. Results and provenance:
`kv-cache/results/<SETUP3_DECODE_NODE>/2026-09-08-llama-benchy/`.

**Stamped `VERDICT: UNTUNED` — not a headline number.** Two reasons, both flagged by the harness:

- the deployment still carries `degraded=unvalidated-first-run`; clear `DEPLOY_DEGRADED=` on a
  correctness-checked redeploy to lift it
- *"a serving sweep ... does not necessarily exercise KV store/retrieve at all"* — llama-benchy
  draws fresh content per cell. **It characterises the serving stack, not the storage tier.**

For the KV path specifically the harness points at `bench/kv-spillover-probe/`, which has **not**
been run. That is the right tool once the read path is fixed.

---

## Recovery

Three long-running deployments (ATOM, MORI, kvng) were stopped to free GPUs. `docker inspect`
JSON for each is in `lab/recovery/` — enough to reconstruct them.

`kvng-xnvme-offload-8000` held `/dev/ng3n1` on a real Pensando DSC3. It was stopped with
authorisation and **did not wedge the device** — `nvme list` clean afterwards, PCIe link still
32 GT/s x16. The safety rule at the top of `README.md` still stands; one clean stop is not
evidence that it is safe.
