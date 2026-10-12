# How a KV block moves, per `align_bytes`

Measured 2026-10-12 on setup-4 (smc1 prefill, smc2 decode), `lmcache bench l2`
driving the `nixl_kv` L2 adapter directly against `/dev/ng1n1`. Read
[`../AGENTS.md`](../AGENTS.md) first. Where this file contradicts
[`KNOWN-ISSUES.md`](KNOWN-ISSUES.md) item 10 or
[`setups/setup-4.md`](setups/setup-4.md) §2.1, **this file is the measurement**
and those have been corrected in the same change (`AGENTS.md` §4).

---

> **STATUS 2026-10-12 — the divergence described in §0 has been FIXED.**
> Decode was rebuilt with `container.sh plugin-build` and its daemon restarted;
> both nodes now run the clean 1:1 build and measure identically. §0–§4 record
> the divergence **as found**, because the laws they establish are what make the
> fix verifiable. **[§9](#9-after-the-fix--parity-restored) has the post-fix
> numbers and is the current state of the system.**

## 0. The headline as found: the two nodes did not move KV blocks the same way

**smc1 and smc2 were running different `libplugin_XNVME_KV.so` binaries.** This
is not a configuration difference. It is two different compiled fan-out
behaviours, and it changes the device op count, the device bandwidth, and
whether a 64 KiB page works at all.

| | prefill (smc1) | decode (smc2) |
|---|---|---|
| md5 | `b07bff5e7d8907ed3bb1754203ad9bda` | `71ab5e25319055857d64665c459d9d13` |
| size / mtime | 174152 B, Oct 7 12:10 | 174736 B, Oct 7 11:48 |
| `build_and_enqueue_parts` symbol | **absent** | **present** |
| `effective_max_value_size` symbol | **absent** | **present** |
| corresponds to | clean tree (`80e05ef`) | **reverted** commit `beca7b7` |
| warning `__FILE__:__LINE__` | `xnvme_kv_backend.cpp:1031` | `xnvme_kv_backend.cpp:1178` |

`libnixl.so` is **byte-identical on both nodes**. That is the proof that the
sub-chunking is *not* in NIXL: NIXL cannot produce a behaviour present on one
node and absent on the other when NIXL itself is the same file.

How it survived a redeploy: `scripts/common/container.sh:624` is
`[ -f "${plugin_so}" ] || cmd_plugin_build` — it rebuilds **only when the `.so`
is absent**, and the install gate at `:608-614` only greps for
`nixlXnvmeKvEngine::queryMem`, which the reverted build also exports.

> **Check this before trusting any device-level number:**
> ```bash
> nm -C /opt/kvstack/plugins/libplugin_XNVME_KV.so | grep -c build_and_enqueue_parts
> # 0 -> clean build    2 -> fan-out build (reverted beca7b7)
> ```

---

## 1. The path a block takes, independent of plugin

A `256 KiB` LMCache object stored at `align_bytes = A` moves like this:

1. **`submit_store_task`** → `_execute_store_in_the_loop`
   (`nixl_kv_l2_adapter.py:467-490`).
2. `page_count = phy_size // align_bytes`, with `§7 assert 2` demanding exact
   division (`:474-478`).
3. **Exactly one** `write_pages()` call per ObjectKey (`:484-487`). There is no
   loop over sub-sizes in the adapter.
4. `write_pages` (`:197-218`) builds `page_count` OBJ descriptor tuples
   `(0, align_bytes, devid, page_name(ns, key, i))` and issues them as **one**
   `initialize_xfer`/`transfer`. The OBJ descriptor length is `align_bytes`
   **verbatim** — the adapter never sub-divides.
5. **Then** one `write_commit()` (`:488-490`) writing a small JSON
   `{"v":1,"ns":…,"pages":N,"page_size":A,"phy_size":P}`. A key is never
   discoverable until its pages are durable.

Names on the device:
```
page   : <ns>@<model>@<kv_rank:08x>@<group:x>@<chunk_hash_hex>~<i>
commit : <ns>@<model>@<kv_rank:08x>@<group:x>@<chunk_hash_hex>!c
```
Each is hashed to a 12-byte device key by `make_key()`
(`xnvme_kv_backend.h:554-570`, two FNV-1a passes over `meta_info`).

**What differs between the nodes is step 4's fate at the device.**

---

## 2. prefill (clean plugin) — `device_ops_per_key = pages + 1`

The plugin is 1:1: `postXfer()` (`xnvme_kv_backend.cpp:1185-1259`) sets
`pending = local.descCount()` and issues one `xnvme_kvs_store` per descriptor
with `buf_len = mem_desc.len`. **One page = one device Store of `align_bytes`.**

Measured, 32 keys × 256 KiB (8,388,608 B of payload):

| `align_bytes` | pages/key | predicted ops | **measured `store_ops`** | bytes per data op | store MB/s | success | `completions_err` |
|---|---|---|---|---|---|---|---|
| 4,096 | 64 | 2048 + 32 = **2080** | **2080** ✓ | 4,096 | 50.03 | 32/32 | 0 |
| 16,384 | 16 | 512 + 32 = **544** | **544** ✓ | 16,384 | 40.75 | 32/32 | 0 |
| 32,768 | 8 | 256 + 32 = **288** | **288** ✓ | 32,768 | 53.82 | 32/32 | 0 |
| 65,536 | 4 | 128 + 32 = 160 | **4** ✗ | 65,536 | — | **0/32** | **36** |

**64 KiB fails on this node.** 0 successful completions, 36 errors, the store
aborts after 4 ops. This is the single-oversized-Store path finally reached:
the device accepts a 32,768-byte value and refuses 65,536.

This **reinstates** `KNOWN-ISSUES.md` item 10's original ceiling. The claim that
the `sct=7 sc=234` signature "must belong to a different code path — this path
cannot reach it" was true only of the *decode* binary. On the clean binary the
ceiling is reached directly, and 32,768 is exactly the largest page that works.

---

## 3. decode (fan-out plugin) — `ops = pages × (⌈A/4096⌉ + 1) + keys × 2`

The reverted build interposes `build_and_enqueue_parts()`, splitting every
page by `effective_max_value_size()`, which is the **device-discovered**
`value_max = 4096` — *not* the configured `max_value_size = 32768`. Each page
also gets a 1-byte commit marker (`kXnvmeKvCommitMarker`).

Measured, same workload:

| `align_bytes` | pages/key | parts/page `⌈A/4096⌉` | ops/page (+marker) | predicted total | **measured `store_ops`** | bytes per data op | store MB/s | success |
|---|---|---|---|---|---|---|---|---|
| 4,096 | 64 | 1 | 2 | 4096 + 64 = **4160** | **4160** ✓ | 4,096 | 35.28 | 32/32 |
| 16,384 | 16 | 4 | 5 | 2560 + 64 = **2624** | **2624** ✓ | 4,096 | 34.56 | 32/32 |
| 32,768 | 8 | 8 | 9 | 2304 + 64 = **2368** | **2368** ✓ | 4,096 | 33.30 | 32/32 |
| 65,536 | 4 | 16 | 17 | 2176 + 64 = **2240** | **2240** ✓ | 4,096 | 32.39 | 32/32 |

**No device Store ever exceeds 4,096 bytes here**, which is why 64 KiB
"succeeds" on decode while failing on prefill. The 64 KiB page never reaches
the device as one object — it is decomposed into 16 independently-keyed 4 KiB
objects with no atomicity across them.

Note the direction of travel: on this binary, raising `align_bytes` **lowers**
total ops (4160 → 2240) because it reduces the number of adapter-level pages
faster than it raises parts-per-page. Store bandwidth is nearly flat
(35.3 → 32.4 MB/s): the device is doing the same 4 KiB writes either way.

---

## 4. The read path is broken on decode, and the error count proves it

`read_commit()` (`nixl_kv_l2_adapter.py:267-282`) registers an OBJ descriptor of
`self.max_value_size` for the commit key — not the commit's actual ~88 bytes.
The fan-out plugin therefore computes `⌈max_value_size / 4096⌉` parts and tries
to retrieve all of them, when only part 0 was ever written.

Predicted failures per key = `⌈max_value_size/4096⌉ − 1`. Measured:

| node | `max_value_size` | parts requested | predicted errors (32 keys) | **measured `completions_err`** |
|---|---|---|---|---|
| decode | 32,768 | 8 | 32 × 7 = **224** | **224** ✓ (at A = 4k, 16k, 32k) |
| decode | 65,536 | 16 | 32 × 15 = **480** | **480** ✓ (at A = 64k) |
| prefill | 32,768 | n/a (1:1) | 0 | **0** ✓ |

Exact at every point. **Every single commit read on decode burns 7 failed
device ops.** This is a real defect of the deployed binary, not a harness
artifact.

---

## 5. The `Load` column — CORRECTED 2026-10-12

> An earlier revision of this section called `Load 0/32` a harness artifact and
> located the abort at the geometry check. **Both claims were wrong.** The abort
> happens one step earlier, inside `read_commit()`, and it is a real defect.
> See §10.

`lmcache bench l2` reported `Load 0/32` at every point on both nodes. The
measured cause is `read_commit()` failing with `NIXL_ERR_BACKEND` — not the
geometry check, which is never reached. The harness's placeholder
`MemoryLayoutDesc` is real but irrelevant: the load dies before the layout is
consulted.

`Lookup 0/32` in those runs **is** expected, but not for the reason given
earlier: `lmcache bench l2` defaults to `--lookup-max-hit-rate 0.0`, which
deliberately probes a key range that was never stored. With
`--lookup-max-hit-rate 1.0` the same adapter returns **32/32** (§10).

---

## 6. Reaching 64 KiB at all requires bypassing a safety gate

`§7 assert 1` (`nixl_kv_l2_adapter.py:371-377`) refuses to start when
`align_bytes > max_value_size`. The objection is **atomicity, not capability**:
the pieces are not crash-consistent and nothing records that a set is
incomplete.

The 64 KiB points above were obtained by setting `NIXL_KV_MAX_VALUE_SIZE` to
65536 **for the benchmark process only**. The live daemons kept 32768 and were
not restarted. Do not raise this in production on the strength of the
throughput numbers — §4 shows the read path degrades as the ceiling rises.

---

## 7. `align_bytes` cannot currently be changed on the serving path

`scripts/common/start-lmcache-daemon.sh` **never passes `--l1-align-bytes`**
(`:466-474`, and the comment at `:319-326` says so deliberately).
`LMCACHE_L1_ALIGN_BYTES` feeds **only** the namespace fingerprint (`:407`):

```
sha256("v1|MODEL|TP|CHUNK|KV_CACHE_DTYPE|align_bytes|max_value_size")[:12]
```

So setting it moves the namespace while leaving the real `align_bytes` at the
argparse default **4096** — it strands every existing object and changes
nothing about how blocks move. There is **no delete primitive**, so stranded
objects are unreclaimable.

Live fingerprint, reproduced exactly:
```bash
printf '%s' "v1|Qwen/Qwen3-8B|2|256|auto|4096|32768" | sha256sum | cut -c1-12
# 29208c874b71   == the namespace both daemons are running
```

**To vary `align_bytes` you must drive the adapter directly** (`lmcache bench
l2 --l1-align-bytes N`), as this document does.

---

## 8. Reproducing this

Run inside the role container. The container maps `/dev/kfd`, `/dev/dri` and
`/dev/infiniband` **wholesale**, so pin the allocation yourself every time
(`setup-4.md` §1.1, §1.2):

```bash
export HIP_VISIBLE_DEVICES=0,1                  # GPU 0 and 1 ONLY
export UCX_NET_DEVICES=ionic_0:1,ionic_1:1      # 2 rails ONLY
export NIXL_KV_METRICS_PATH=/tmp/absweep/dev-$A.json   # isolates this run's device counters
export NIXL_KV_METRICS_INTERVAL_SEC=1

python3 scripts/bench/l2-block-bench.py bench l2 \
  --l2-adapter '{"type":"nixl_kv","backend":"XNVME_KV",
                 "backend_params":{"dev_uri":"/dev/ng1n1"},
                 "namespace":"<throwaway>"}' \
  --l1-align-bytes $A --num-keys 32 --data-size-kb 256 \
  --rounds 1 --warmup-rounds 0 --format json --output /tmp/absweep/bench-$A.json
```

- `--data-size-kb 256` divides exactly by all four `align_bytes` values —
  required by `§7 assert 2`.
- Use a **fresh throwaway namespace per point**; production is `29208c874b71`.
- Setting `NIXL_KV_METRICS_PATH` is what makes each point's device counters
  isolated instead of mixed into the daemon's file.
- Every point writes ~8 MB that **can never be reclaimed**. Budget accordingly.

---

## 9. After the fix — parity restored

Decode was rebuilt from this repo's source and its daemon restarted:

```bash
cp /opt/kvstack/plugins/libplugin_XNVME_KV.so \
   /opt/kvstack/plugins/libplugin_XNVME_KV.so.fanout-beca7b7.bak   # reversible
./scripts/common/container.sh plugin-build                         # no --device flags, no GPU
./scripts/common/container.sh exec decode ./scripts/common/stop-lmcache-daemon.sh   # NOT --clean-shm
./scripts/common/container.sh exec decode ./scripts/common/start-lmcache-daemon.sh
```

Resulting binary: **174152 B**, byte-size identical to prefill's, zero
`build_and_enqueue_parts` symbols, `queryMem` override present. The running
daemon's mapped `.so` is md5 `8c3c4f815da34f25b3db80a1df20a65d`, and its log
fingerprint moved from `xnvme_kv_backend.cpp:1178` to **`:1031`**.

Measured immediately after, same workload (32 keys × 256 KiB):

| config | store_ops | keys | MB/s | device IOPS | `compl_err` | retrieve_ops |
|---|---|---|---|---|---|---|
| decode 64K **before** (fan-out) | 2,240 | 32/32 | 32.39 | 9,068 | 480 | 544 |
| decode 64K **after** (clean) | **4** | **0/32** | — | 581 | **36** | 32 |
| prefill 64K (clean, reference) | 4 | 0/32 | — | 789 | 36 | 32 |
| | | | | | | |
| decode 4K **before** (fan-out) | 4,160 | 32/32 | 35.28 | 18,345 | **224** | 288 |
| decode 4K **after** (clean) | **2,080** | 32/32 | 44.05 | 11,454 | **0** | **32** |
| prefill 4K (clean, reference) | 2,080 | 32/32 | 50.03 | 13,008 | 0 | 32 |

Three things changed, all as predicted:

1. **The 2× op amplification is gone.** 4 KiB dropped 4,160 → 2,080 ops for the
   same 8 MB, because the fan-out's extra 1-byte commit marker per page is gone.
2. **The commit-read defect is gone.** `completions_err` 224 → **0**, and
   `retrieve_ops` 288 → 32. Every commit read now costs exactly one device op
   instead of one plus seven failures.
3. **64 KiB now fails on decode too** — 4 ops, 0 keys, 36 errors, the exact
   signature prefill produces. This is correct behaviour, not a regression: the
   device ceiling is real, and the clean build reaches it instead of silently
   decomposing the page into 16 non-atomic fragments.

**`align_bytes = 32768` is therefore the largest usable page on both nodes**,
and the `pages + 1` law (§2) now holds cluster-wide.

### 9.1 The daemon restart does NOT restore L2 on the serving path

Restarting the daemon under a **live** vLLM leaves the new daemon with no GPU
context, because registration happens when vLLM's connector initialises. The
symptom is in the daemon log, and it predates this work — it was already firing
throughout the 2026-10-12 llama-benchy sweep:

```
ERROR: No GPU context found for model Qwen/Qwen3-8B with world size 2 during lookup!
       (lookup.py:205)
```

Every lookup is rejected there, **before** L1 or L2 is consulted — which is the
real reason the KV tier recorded zero activity during that sweep. Neither
`align_bytes` nor the plugin had anything to do with it.

Bring-up order is load-bearing (`AGENTS.md` §6): **daemon first, then vLLM.** To
put L2 back on the serving path, vLLM decode must be restarted *after* the
daemon. Until then the L2 tier is correct and idle, and
`vllm:external_prefix_cache_hits_total` continues to measure only the
NixlConnector P→D leg.

---

## 10. Post-fix sweep: 4 / 16 / 32 KiB, with store, hit/miss and read-back separated

Decode, clean plugin, 32 keys × 256 KiB (8,388,608 B payload), `rounds=1`:

| `align_bytes` | pages/key | store_ops | B per op | device IOPS | MB/s | keys | mean lat µs | device err |
|---|---|---|---|---|---|---|---|---|
| 4,096 | 64 | 2,080 | 4,034 | 12,239 | 49.36 | 32/32 | 1262.3 | 0 |
| 16,384 | 16 | 544 | 15,425 | 3,746 | 57.76 | 32/32 | 1066.6 | 0 |
| 32,768 | 8 | 288 | 29,136 | 2,015 | 58.69 | 32/32 | 1061.3 | 0 |

`ops = pages + 1` holds exactly at all three (2080 / 544 / 288). Raising
`align_bytes` 8× cuts device ops **7.2×** and lifts store bandwidth ~19%
(49.4 → 58.7 MB/s), because the fixed per-key commit overhead is amortised and
each op carries more payload. Mean latency is flat ~1.1 ms — the device is not
the bottleneck; op *count* is.

### 10.1 Cache hit/miss — the L2 probe path WORKS

`--lookup-max-hit-rate` selects whether the probed key range was stored. Both
directions measured on the same namespace, in **separate processes** (so the
in-process `_memory_objects` index cannot serve the answer — a hit here is a
genuine device hit):

| pass | `--lookup-max-hit-rate` | result | latency |
|---|---|---|---|
| cold (keys never stored) | 0.0 | **0/32 hit** (correct miss) | 2.5–3.0 ms |
| warm (same ns, new process) | 1.0 | **32/32 hit** | 2.80 ms |

So `probe_commit()` → `queryMem` is healthy end to end, and a cold/warm
distinction is measurable. Note the probe path issues **no** counted
`store_ops`/`retrieve_ops` — it uses the plugin's `exist` path, which is not in
those counters. Judge lookups by `l2_keys_probed` / `l2_probe_misses`, never by
device op counts.

### 10.2 Read-back is BROKEN on the clean plugin — `read_commit()` sizing

Every `Load` aborts at `read_commit()` with `NIXL_ERR_BACKEND`:

```
WARNING nixl_kv commit read failed for bench-model@00000000@0@…: NIXL_ERR_BACKEND
        (nixl_kv_l2_adapter.py:615)
```

Identical at all three sizes, and the device counters show why:

| `align_bytes` | retrieve_ops | `retrieve_len_checked` | `retrieve_len_unreported` | device err |
|---|---|---|---|---|
| 4,096 / 16,384 / 32,768 | 32 | **32** | 0 | **0** |

All 32 commit reads reached the device and **succeeded at the device level**
(`completions_err = 0`). They were then rejected by the plugin's short-read
integrity guard (`xnvme_kv_backend.cpp:215-236`), which fires when
`cpl.cdw0 != work->buf_len`.

**The asymmetry is the bug, and it is in the adapter, not the plugin:**

| | size used | source |
|---|---|---|
| `write_commit()` | `len(payload)` — **~88 B** | `nixl_kv_l2_adapter.py:236-241` |
| `read_commit()` | `self.max_value_size` — **32768 B** | `nixl_kv_l2_adapter.py:268-274` |

The guard is correct — it exists to stop a part-new/part-stale buffer being
handed upward. The defect is that `read_commit()` asks for 32 KiB of an 88-byte
object. `docs/design/nixl-kv-l2-adapter.md:289` specifies the commit payload as
*"padded to `align_bytes`"*; **the padding was never implemented**, so write and
read disagree about the object's size.

Consequence: **stores land and can be found, but can never be read back** — the
exact "writes land and are unreachable" failure `xnvme_kv_backend.h` warns
about. Fix by making the two sides agree: either pad the commit object on write
(as designed), or have `read_commit()` request the real size.

> This is **independent** of the fan-out bug fixed in §9 — it reproduces on the
> clean build on both nodes, and it was previously masked on decode, where the
> fan-out's 224 device errors aborted the load before this guard was reached.

---

## 11. What happens at `align_bytes = 65536` — the device's own answer

Captured with `NIXL_XNVME_KV_DEBUG=1` on decode, clean plugin, 2026-10-12:

```
[XNVME_KV] op=store key=10752b06da58edfce04fc723 len=65536 t=submit rc=0      (x4)
[XNVME_KV] op=store key=10752b06da58edfce04fc723 len=65536 t=complete
           ok=0 sct=7 sc=234 cdw0=0 lat_us=83                                 (x4)
LMCache ERROR: nixl_kv store task 0 failed  (nixl_kv_l2_adapter.py:504)
  [Store] Round 1: 5.63 ms, success_keys=0/2
```

Device counters: `store_ops=4, store_bytes=262144, completions_ok=0,
completions_err=4`.

Three things happen, in order:

1. **`§7 assert 1` blocks startup first.** `align_bytes (65536) > max_value_size
   (32768)` → the adapter refuses to construct. Reaching the device at all
   requires raising `NIXL_KV_MAX_VALUE_SIZE` to 65536, which bypasses a
   deliberate **atomicity** gate. Done here for the benchmark process only; the
   live daemons kept 32768.
2. **The device rejects every oversized Store with `sct=7 sc=234`.** Four
   submits of `len=65536` (one key = 262144/65536 = 4 pages), four completions,
   all `ok=0`, `cdw0=0`, latency 83–128 µs — an immediate refusal, not a
   timeout or a retry-able condition.
3. **The whole store task aborts on the first failure.** `_execute_store_in_the_loop`
   wraps the entire key loop in one `try`, so only the first key's 4 ops are
   ever attempted; keys 2..N are never submitted. That is why `store_ops = 4`
   and not `keys × 4`.

### 11.1 This RESTORES item 10's original ceiling and refutes its retraction

`KNOWN-ISSUES.md` item 10 originally recorded `sct=7 sc=234` as the over-size
failure, then retracted it, claiming the signature *"was never reproduced at any
size up to 64 KiB, because this adapter path never attempts a >4096-byte
Store."*

**That retraction was an artifact of measuring on the fan-out build**, where no
device op ever exceeded 4096 bytes. On the clean build the signature reproduces
on the first attempt. The original claim was right.

### 11.2 The device understates its own ceiling by 8×

The startup warning is correct to be only a warning:

```
device advertises value_max=4096 but configured max_value_size=65536 —
stores at the configured size MAY be rejected (sct=7 sc=234 ...)
```

Measured truth on this DSC:

| Store size | result |
|---|---|
| 4,096 (advertised `value_max`) | OK |
| 16,384 | OK |
| 32,768 | **OK — the real ceiling** |
| 65,536 | **`sct=7 sc=234`** |

So `value_max=4096` understates capability 8×, and **32768 is the true maximum
single-value size**. Do not lower `NIXL_KV_MAX_VALUE_SIZE` to 4096 to silence
the warning, and do not set `NIXL_KV_STRICT_DEVICE_CEILING=1` — either would
refuse the configuration that actually works.

### 11.3 Summary of 64 KiB across both builds

| build | keys stored | store_ops | what reached the device |
|---|---|---|---|
| fan-out (decode, before) | **32/32** | 2,240 | 16 × 4 KiB objects per page, separately keyed, **no atomicity** |
| clean (both nodes, now) | **0/32** | 4 | one 65,536 B Store → `sct=7 sc=234` |

The fan-out build's "success" was never a 64 KiB page reaching storage — it was
a silent decomposition into 16 independent objects with nothing recording that
the set is incomplete. **The clean build's failure is the more honest result.**
