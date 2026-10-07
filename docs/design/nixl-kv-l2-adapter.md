# Design: `nixl_kv` — a content-addressed, cross-node LMCache L2 adapter

Status: **specification**, 2026-09-17. Implements the fix for TODO 6.21.
Read [HANDOFF §2](../HANDOFF.md#2-current-state) first.

## 1. The problem, stated correctly

The handoff has said the cause of `retrieve_ops=0` is LMCache's per-daemon
`obj_{i}_{uuid4}` object naming. That is real, but it is the **second** of two
independent blockers, and on its own it is the less fundamental one.

**Blocker 1 — discovery is a missing verb.**
`NixlStoreL2Adapter._execute_lookup_in_the_loop()` consults only the
in-process `self._memory_objects: dict[ObjectKey, NixlStoreObj]`. A daemon
never asks the shared medium about a key it did not itself store. Every
cross-daemon lookup is a miss **before naming is even consulted**. You cannot
patch a name into existence — the operation does not exist.

This is why restoring the plugin's `queryMem()` override was correct and
changed nothing: the verb existed at the plugin layer and the adapter above it
still never called it.

**Blocker 2 — names are pool slots, not content.**
`init_storage_handlers_object(page_size, num_pages)` pre-registers `pool_size`
names as `f"obj_{i}_{uuid.uuid4().hex[0:4]}"` at daemon startup. The function
never sees a content key; the content→slot map is the in-process dict.

Neither fix alone changes the outcome. Both are required.

> A third thing was long filed alongside these as "a separate, still-open
> question": `retrieve_ops=0` on prefill **by itself**. It is now answered and
> is **not a bug** — the daemon log shows
> `Prefetch request completed (L1+L2): 4/4 retained keys (4 L1, 0 L2)`.
> L1 holds everything, so L2 is never read back. Any acceptance test must
> force L1 eviction or it will measure `retrieve_ops≈0` against a working
> implementation and call it a failure.

## 2. Measured facts this design is built on

All measured on the live cluster 2026-09-17. Re-measure before trusting
(HANDOFF §3.5).

| Fact | Value | Why it matters |
|---|---|---|
| `query_memory()` PRESENT | `{}` — an **empty, falsy dict** | `if resp[i]:` scores every hit as a miss |
| `query_memory()` ABSENT | `None` | hit/miss separable **by identity only** |
| probe latency | **57 µs** per descriptor | at page granularity a chunk costs 0.53 s |
| `page_size` (`--l1-align-bytes`) | **4096** | the transfer unit |
| declared `max_value_size` | **32768** | `4096 ≤ 32768` ⇒ `mem_split_n == 1` |
| chunk geometry (Qwen3-8B, chunk=256) | 36 MiB = **9,216 pages per ObjectKey** | one key ⇒ many device objects |
| `make_key()` with non-empty `metaInfo` | FNV-1a×2 of `metaInfo` alone, **ignores devId/addr** | a content-derived `metaInfo` is a stable cross-node address |
| `registerMem` for `OBJ_SEG` | `new nixlXnvmeKvMD()` + string copy, **no device I/O** | dynamic per-transfer registration is cheap |
| device key length | `make_key` emits 12 B, device `key_max=16` | 4 spare bytes available |
| delete primitive | **none wired** | device space is never reclaimed |
| namespace size | 1 GiB = **262,144 pages** ≈ 28 chunks ≈ 7k tokens | demonstrable, not sustainable |

## 3. Why a new module, not a patch to `nixl_store`

`nixl_store_l2_adapter.py` is the file both `0006` and `0007` modify, inside a
vendor image we cannot rebuild. A new module has permanently zero textual
conflict with either, and **`pkgutil` auto-discovers any `*_l2_adapter.py`
dropped into the package directory** (`l2_adapters/__init__.py` iterates
`__path__`), so registration costs **zero vendor-file edits**.

It also keeps `nixl_store` byte-identical as an A/B control — switching
between broken and fixed is one JSON edit, which is worth a great deal on a
cluster whose history is full of false negatives.

Overlay delivery mirrors `container.sh`'s existing pattern for `0011` and
`nixl_utils.py`.

## 4. Naming scheme

```
page   :  {ns}@{object_key_string}~{page_ordinal}
commit :  {ns}@{object_key_string}!c
```

- `object_key_string` —
  `<model_name>@<kv_rank:08x>@<object_group_id:x>@<chunk_hash.hex()>[@<cache_salt>]`.
  `ObjectKey.__post_init__` enforces the `@`-free invariant on `model_name`
  and `cache_salt`, so the encoding is unambiguous.

  > **Revised 2026-09-17 — spell it ourselves, do not import it.** This
  > section originally said to import `_object_key_to_string()` from
  > `s3_l2_adapter.py`, on the grounds that `valkey_l2_adapter.py` already
  > imports it from a sibling adapter. Two things were wrong with that.
  > First, valkey imports it from `native_connector_l2_adapter.py`, not from
  > `s3_l2_adapter.py`. Second, and decisively: LMCache ships **four
  > independent private copies** of this function (`s3`, `bigtable`,
  > `hfbucket`, `native_connector`), and they are **not** all the same —
  > `native_connector`'s is parameterised on a module-level `_KEY_SEP`
  > (currently `"@"`, so its output agrees *today*). None of the four is a
  > public API.
  >
  > This string is our **persistence format**: it determines the 12-byte
  > device key through the plugin's FNV-1a derivation. Importing it makes
  > on-device naming hostage to a vendor edit we cannot see, and because
  > this backend has **no delete primitive**, a silent format change does
  > not degrade gracefully — every object already on the device becomes
  > unreachable at once, and two nodes on different images silently stop
  > agreeing on names. So the adapter owns the function and a unit test pins
  > its exact output bytes.
- `~{page_ordinal}` — **the tile ordinal, and it is load-bearing.** One
  `ObjectKey` tiles into `phy_size / align_bytes` pages (9,216 in production
  geometry). Naming every page with one string makes each page overwrite the
  last. See §7 S1 for why nothing in the stack catches that.
  `~` deliberately avoids `#`, which patch `0007` uses for its *value-size*
  sub-split, so the two schemes can never be confused when reading device
  keys.
- `ns` — the **geometry fingerprint** (§5).

## 5. The geometry fingerprint `ns`

`ObjectKey` carries `model_name`, `kv_rank`, `object_group_id`, `chunk_hash`
and `cache_salt` — and **no dtype, and no KV-plane layout**. Two daemons
running different `--kv-cache-dtype`, or a fused-vs-split KV cache, produce
**the same key for different bytes**, at the same byte count. Patch `0009`
exists precisely because a plane-layout mismatch has the same total size and a
wrong per-token stride, and corrupts every chunk without raising.

`ns` is a short hash over everything that changes on-wire meaning:

```
ns = sha256("v1|{model}|{tp}|{chunk_size}|{kv_cache_dtype}|{align_bytes}|{max_value_size}")[:12]
```

Computed by `start-lmcache-daemon.sh` from `config/cluster.env` — the same
file on both nodes, and invariant 8 already requires both roles to agree on
`LMCACHE_CHUNK_SIZE` — and passed in the `--l2-adapter` JSON as
`"namespace": "<ns>"`. Both nodes therefore derive it identically **by
construction**, and any divergence changes the namespace, which turns silent
corruption into an ordinary **miss**.

It also gives two things we otherwise lack: isolation from the 36,864 stale
`obj_N_uuid` keys and from the other party sharing `smc3`, and a **migration
path** — a schema change gets a new prefix instead of colliding with stale
data in a namespace we cannot drain in production.

`ns` MUST be rejected at config parse time if it contains `@`, `~` or `!`.

## 6. Protocol

### Store (`_execute_store_in_the_loop`)

1. Skip keys already in `_memory_objects`.
2. `page_count = obj.meta.phy_size // align_bytes`; assert exact division.
3. Build `page_count` OBJ registration tuples `(0, align_bytes, i, page_name)`.
4. One batched `WRITE` transfer, L1 side reusing the prepped whole-buffer
   dlist exactly as `nixl_store` does (`get_memory_indices()` semantics are
   unchanged).
5. **Await completion. Verify `DONE`, not `ERR`.**
6. **Only then** write the commit object.
7. Only then insert into `_memory_objects` and `_notify_keys_stored`.

Ordering is the whole point: a key is never discoverable until its pages are
durable. The commit object is this medium's `os.rename`.

**Hard invariant (TODO 6.34, fixed and verified 2026-09-18): no two live OBJ
registrations may ever share `(addr, len, devId)`.** Every OBJ descriptor
this adapter registers is `(addr=0, slot_size, devId, metaInfo=name)`; the
plugin resolves an object's identity from the descriptor NIXL binds to that
`(addr, devId)` pair, not from `metaInfo` alone, so two live registrations
that collide on it are indistinguishable to the plugin — whichever
registration NIXL binds first "wins" the identity, silently. This was
violated before the fix: `devId` was assigned positionally per call
(`devId=i`), so the page registration (`devId` 0..page_count-1) and the
commit registration (`devId` 0..batch_size-1, created before the pages were
deregistered) collided on the overlapping range, and commit writes landed
on page 0..N-1 of the data instead of their own object.

The invariant is enforced two ways, not one, because ordering alone does not
hold once stores run concurrently:

1. **`devId` is a daemon-global monotonic counter** (`self._next_devid`,
   guarded by `self._devid_lock` in `NixlKvStorageAgent.register_obj_names()`),
   used for every OBJ descriptor this adapter ever registers — page or
   commit, any call. Two registrations are therefore disjoint by `devId`
   construction regardless of call order or overlap, including the
   cross-task overlap that `submit_store_task` can produce by scheduling
   concurrent awaiting coroutines. This is the invariant; it does not depend
   on anything being deregistered in time.
2. **Defence in depth, and the ordering this section originally specified:**
   the page dlist is deregistered immediately after the page write is
   confirmed durable (`post_non_blocking` has been awaited and did not
   raise), before the commit dlist is registered — so at most one OBJ
   registration touching this object's pages is ever live at a time, on top
   of (1)'s disjointness. This preserves the atomicity ordering above (pages
   are already durable at that point) without relying on it for the
   aliasing guarantee.

Any future change to `register_obj_names()`'s descriptor shape must keep
(1) intact — a return to positional or otherwise call-scoped `devId`
reintroduces this bug regardless of ordering discipline.

Commit object payload (JSON, `≤ max_value_size`, padded to `align_bytes`):

```json
{"v":1,"ns":"<ns>","pages":9216,"page_size":4096,"phy_size":37748736}
```

### Lookup (`_execute_lookup_in_the_loop`)

1. In-process `_memory_objects` hit → `l2_index_hits += 1`.
2. Otherwise batch `query_memory()` over **commit keys only** — one Exist per
   ObjectKey, not per page. This is the difference between 57 µs and 0.53 s
   per chunk.
3. **`resp[i] is not None`** — never truthiness. PRESENT is `{}`, which is
   falsy.
4. On a device hit: `l2_device_hits += 1`, lazily populate `_memory_objects`
   (mirroring `nixl_store_dynamic`'s `_secondary_lookup_locked`), set the bit,
   take the pin.
5. `query_memory()` **raises** on `NIXL_ERR_BACKEND` (only `NIXL_SUCCESS` and
   `NIXL_IN_PROG` are non-throwing). Catch it, count `l2_probe_errors`, log
   rate-limited at WARNING, and report miss for that batch. **Never fabricate
   a hit.** `l2_probe_errors == 0` is an acceptance assertion — without it a
   flaky device degrades to a permanent 0% hit rate that looks exactly like
   today's bug.

Lookup must not be allowed to block the event loop. Probing is synchronous,
mutex-serialised, and runs on the caller's thread; group-granular probing
keeps a realistic batch at single-digit milliseconds. Bound it with a deadline
and report miss past it, so a wedged DSC degrades throughput instead of
hanging the engine.

### Load (`_execute_load_in_loop`)

1. Read the commit object first. Verify `v`, `ns`, `page_size`, and that
   `pages` matches the caller's `phy_size // align_bytes`.
2. **Any mismatch ⇒ abort the whole group, report miss, `l2_load_aborts += 1`.**
   Never hand partial or mis-shaped data upward.
3. Batched `READ` of all `page_count` pages under their `~ordinal` names.
4. Any sub-read failure ⇒ abort the entire group. Never a partial hit.
5. Release every lookup lock the hit acquired. Patch `0011` exists because
   this codebase has already shipped a lookup-lock leak; the device-hit branch
   is a brand-new path into that same failure.

### Delete / eviction

There is no device delete. `delete()` removes the index entry only; device
space is **not** reclaimed. This must be logged plainly, and the adapter must
maintain a high-water mark and refuse loudly as it approaches the namespace
capacity, rather than letting stores start failing. `scripts/target/50-reset-namespace.sh`
is the only reclamation mechanism and belongs in the acceptance procedure.

## 7. Hard asserts at init — refuse to start, do not warn

Each guards a silent failure.

1. **`mem_split_n == 1`.** Derived from `page_size ≤ max_value_size`. If
   `--l1-align-bytes` ever exceeds `max_value_size`, `0007`'s `#{j}` split
   wakes up, a page becomes a multi-command publish with no atomicity, and
   nothing records the `sub_size` an object was written with (invariant 4).
   Refuse to start.
2. **`page_size` divides `phy_size` exactly** for every stored object.
3. **`ns` is set, non-empty, and free of `@~!`.**
4. **`pool_size` is not required** — this adapter is content-addressed and has
   no pool. Reject the key if present rather than silently ignoring it.
5. **A self-probe at init** — the plugin's `query_dev_` handle open is
   deliberately **non-fatal** (`xnvme_kv_backend.cpp`), so a failed open leaves
   every lookup returning absent forever while the daemon looks healthy. The
   only signal is one stderr line: `lookup=KV Exist` vs `lookup=UNAVAILABLE`.
   Probe one known-absent key at init and refuse to advertise as a working L2
   tier if the probe path is dead.

## 8. Counters

`report_status()` must expose, and the acceptance test must assert on:

| Counter | Meaning |
|---|---|
| `l2_index_hits` | served from the in-process dict |
| `l2_device_hits` | **served by discovering a key this daemon never wrote** |
| `l2_probe_errors` | `queryMem` raised — device error, not a miss |
| `l2_commit_writes` | groups made durable |
| `l2_load_aborts` | group rejected on geometry or partial-read |

`l2_device_hits > 0` **and** `l2_index_hits == 0` on a cold reader is the only
signal that specifically proves Blocker 1 is fixed. Everything else is
satisfiable by a same-daemon hit.

### 8.1 Attempt counters — added after the first acceptance run (TODO 6.28)

The five counters above record only **outcomes**, and that turned out to be
insufficient in the worst way: the 2026-09-18 acceptance run returned
`l2_device_hits=0` with `l2_probe_errors=0`, a reading equally consistent
with "lookup ran and the names did not match" and "lookup was never
invoked". The two have entirely different fixes and the counters could not
separate them. The spec was wrong to count only outcomes; these five close
that gap.

| Counter | Meaning |
|---|---|
| `l2_lookup_calls` | `submit_lookup_and_lock_task` entries — did the layer above us ask at all |
| `l2_lookup_keys` | ObjectKeys presented across those calls |
| `l2_lookup_executions` | `_execute_lookup_in_the_loop` entries |
| `l2_keys_probed` | keys that actually reached a batched device probe |
| `l2_probe_misses` | probed keys the device reported absent |

**`l2_lookup_calls` must be counted on the synchronous entry, not inside the
coroutine.** `asyncio.run_coroutine_threadsafe` swallows a wedged or dead
event loop, so a coroutine-side count would collapse "never called" and
"never ran" back into one number and reintroduce the exact ambiguity these
counters exist to remove — one layer further down, and harder to see.
`l2_lookup_executions` is the coroutine-side counterpart; a gap between the
two *is* the wedged-loop signal.

`l2_keys_probed` must be incremented **before** the probe can fail, or a
probe that always raises reports `keys_probed=0` and the reading is
undiagnosable again.

Reading the combination:

- `calls==0` → the LMCache→adapter seam never called us; the fault is above
  this adapter.
- `calls>0` & `executions==0` → wedged event loop.
- `keys_probed==0` & `calls>0` → every key short-circuited on the in-process
  index; the device was never asked.
- `probe_misses>0` → we probed and the device said absent: a naming /
  key-derivation divergence, not plumbing.

Paired with these, two **one-shot** INFO logs make the last case directly
checkable: `FIRST DEVICE PROBE` (reader) and `FIRST COMMIT WRITE` (writer),
each naming the first commit key that daemon probes or writes. Writer-vs-
reader name agreement is then a two-line grep across the two daemons' logs.
One-shot deliberately: the *first* name is the evidence, and logging every
batch would bury it at request rate.

Generalised, this is the transferable lesson — **instrument the attempt, not
just the outcome**, and instrument it at the point of entry, not at the point
of work.

## 9. Acceptance — "cold reader, dead writer, bypassed proxy"

Three maskers must be defeated, not two: vLLM's own prefix cache, the P→D
`NixlConnector` leg, and **L1**.

There is also a structural trap: `MultiConnector` gives the entire load to the
first child reporting a non-zero match and `NixlConnector` is hardcoded first,
so anything arriving through the normal P→D flow is claimed before LMCache is
asked. The test must construct a case where `NixlConnector` *cannot* match.

0. Drain the namespace (`50-reset-namespace.sh`), record `nuse`. Set
   `LMCACHE_MAX_LOCAL_CPU_SIZE` small enough that L1 provably cannot hold the
   working set.
1. **Ground-truth baseline** on node A: temperature 0, fixed seed, L2
   disabled, nonce-prefixed prompt ≥ 2 chunks. Save the exact token sequence.
2. Node A with L2 enabled, same prompt. Assert prompt throughput > 0, device
   `m_completions_ok` rises, `nuse` grows.
3. **Kill node A's vLLM *and* its LMCache daemon.** This destroys the
   in-process index and node A's prefix cache by construction.
4. On node B — different node, different daemon — send the same prompt
   **directly to node B's engine, bypassing the proxy**. With A down,
   `NixlConnector` structurally cannot serve it.
5. Assert **all** of:
   - node B prompt throughput ≈ 0, external hit rate → 100%
   - `m_retrieve_ops > 0`, retrieve `m_completions_ok > 0`,
     `m_retr_len_checked > 0`, zero length mismatches
   - **`l2_device_hits > 0` and `l2_index_hits == 0`**
   - `l2_probe_errors == 0`, `l2_load_aborts == 0`
   - **node B's output is token-for-token identical to step 1's baseline**
6. **Negative control A** — unseen nonce: throughput > 0, hit rate low,
   `m_retrieve_ops` flat.
7. **Negative control B** — re-drain, repeat step 4 with the correct nonce:
   must miss. Proves the hit came from the device.

The token-identity check in (5) is not optional. **Every other assertion in
that list passes under the §7-S1 page-collapse failure**, because a read of
4096 bytes returns 4096 bytes and `cdw0` matches. It is the only assertion
that cannot pass while the bytes are wrong.

## 10. Known limitations to state plainly, not to fix here

- **1 GiB ≈ 28 chunks ≈ 7,000 tokens**, with no reclamation. This is a tier
  that can be *demonstrated*, not *used*. Sizing is a hardware-owner question.
- No device delete ⇒ capacity is monotonic within a namespace generation; the
  `ns` prefix is the migration lever.
- Probe cost is uninstrumented in the plugin; `queryMem` touches none of the
  `m_*` counters.
- `m_store_ops` counts **submission accepted**, not completion succeeded.
  `m_completions_ok`/`m_completions_err` are the durability signal.

## 11. Implementation decisions taken where this spec was silent

Recorded so a reviewer can find them without reading 1,400 lines.

1. **Store batches monolithically, load aborts per key.** A store task
   flattens every key into one WRITE, so a transfer failure fails the whole
   task (matching `base.py`'s coarse store contract). A load runs each key as
   its own coroutine under `asyncio.gather(..., return_exceptions=True)`, so
   one key's group-abort cannot fail its batch-mates. "Group" in §6 means
   **one ObjectKey's page set**, not the submitted batch.
2. **`_notify_keys_stored` is deferred on the device-hit path.** An OBJ
   `Exist` probe returns `{}` and carries **no size**, unlike
   `nixl_store_dynamic`'s `os.stat()`. A lookup-time device hit therefore
   populates the index with an unknown size, and accounting is only notified
   once load has read and validated the commit object. A `recorded` flag
   prevents double counting.
3. **Probe deadline is 200 ms**, on a 2-worker thread pool via
   `run_in_executor` + `wait_for`, so a wedged DSC degrades throughput
   instead of hanging the event loop. A blocked C call cannot be cancelled,
   so the thread is abandoned on timeout. Not currently a config knob.
4. **The commit object needs its own scratch buffer** — its payload is JSON,
   not KV bytes from the caller's L1 region — so an ephemeral host buffer is
   registered per commit I/O and deregistered after.
5. **The §7 assert-5 self-probe is weaker than the spec implies.** The real
   signal (`lookup=KV Exist` vs `lookup=UNAVAILABLE`) is a C++ stderr line
   emitted at backend creation and not reachable from Python. The adapter
   issues a probe for a known-absent key and treats a **raised exception** as
   fatal; a clean `None` is accepted, since "device fine, key absent" and
   "probe path dead, everything reports absent" are indistinguishable from
   here. Watch that stderr line at daemon startup — it remains the only
   direct evidence.
6. **Namespace capacity is not enforced.** §6 asks the adapter to refuse
   loudly as it approaches capacity, but no capacity is derivable from the
   config shape. `delete()` is index-only with a plain WARNING that device
   space is not reclaimed. **Open gap** — 1 GiB / 4096 = 262,144 pages ≈ 28
   chunks, so this will be reached in practice, not in theory.
