# Known issues register

Problems this project has actually hit, and what to do about them. Each entry
is a real failure that cost time at least once — the symptom as it presents,
what it really was, and the fix.

**This file is authoritative.** `AGENTS.md` names it, and `docs/HANDOFF.md`,
`docs/TODO.md` and `config/cluster.env` cite entries here by number. Do not
fork it, and do not renumber entries — references elsewhere break silently.

Split out of `docs/BRINGUP.md` §7 on 2026-10-12 so that BRINGUP could become a
pure step-by-step procedure. Entry numbers are unchanged from §7.

For the procedure itself, see [`BRINGUP.md`](BRINGUP.md).

---


Everything below was hit for real on this cluster. Ordered roughly by how
likely you are to hit it.

### 1. `lmcache bench l2` fails: `local index out of range`

```
makeXferReq: local index out of range at index 0 with value 340075
nixlInvalidParamError: NIXL_ERR_INVALID_PARAM
```

**Cause:** upstream LMCache 0.5.3. `init_mem_handlers()` builds the L1
dlist base-relative; `get_memory_indices()` returns an absolute page index.
They agree only when the buffer base is 0. Confirmed upstream by A/B
against the untouched vendor `nixl_store`, which fails identically.

**Solution:** invoke via `scripts/bench/l2-block-bench.py` (§3.0), never
`lmcache bench l2` directly.

**Related open question:** production uses the same arithmetic and does not
crash only because its 4 GiB L1 makes the bad index land *in range* —
shifted, not rejected. Whether the serving path is silently mis-indexed is
**untested** (TODO 6.35). Do not "fix" the adapter on the strength of this
section alone.

### 2. Every llama-benchy sweep dies instantly: `unrecognized arguments: --warmup-runs`

**Cause:** llama-benchy 0.4.0 has **no `--warmup-runs` flag** (verified:
`--help | grep -c -- --warmup-runs` → `0`). It always runs exactly one
discarded warmup iteration; the only control is `--no-warmup`.
`lib-bench.sh` passed the non-existent flag unconditionally, so the harness
could not run at all.

**Solution:** fixed in `scripts/bench/lib-bench.sh` — `BENCHY_WARMUP_RUNS=0`
now maps to `--no-warmup`, anything else uses the built-in single warmup,
and a value >1 warns rather than silently delivering 1.

### 3. `llama-benchy not found at /opt/kvstack/venv/bin/llama-benchy` after a successful install

**Cause:** inside the container `${VENV}` is a **shim, not a virtualenv** —
`container.sh shim` creates `python`/`python3` symlinks and a no-op
`activate`, because the image carries vllm/lmcache/nixl on the *system*
interpreter. pip therefore installs console scripts to `/usr/local/bin`.

**Solution:** `01-install-benchy.sh` now bridges it automatically. By hand:
`ln -sfn "$(command -v llama-benchy)" /opt/kvstack/venv/bin/llama-benchy`.

### 4. `unknown adapter type 'nixl_kv'` (and `nixl_store` missing too)

**Cause:** you exported `LD_LIBRARY_PATH` or `NIXL_PLUGIN_DIR` and clobbered
the container's working values. `import nixl` then fails, and LMCache's
lazy adapter loader **swallows the ImportError**, silently dropping all
three NIXL adapters from the registry. The error names the adapter, not the
real cause.

**Solution:** do not set those variables. The container already has them
right. Diagnose with:

```bash
python3 -c "from nixl._api import nixl_agent; print('nixl OK')"
```

**Generalisable lesson:** if an adapter/plugin registry reports a type as
unknown, check whether its module failed to *import* before concluding it
was never installed.

### 5. Store "succeeds" in 0.47 ms with `success_keys=0/N`

**Cause:** every transfer raised and the exception was caught and logged
per-task, so the round completed almost instantly.

**Solution:** read durations, not just success counts, and always run
`--no-skip-verify` on a smoke test. A real 16-page store is ~41 ms.

### 6. `--confirm-connector-hit` cannot find `vllm-decode.log`

**Cause:** `container.sh` bind-mounts `REPO_ROOT`, `STACK_ROOT` and
`HF_HOME` — but **not** `LOG_DIR` (`/var/log/kvstack`). The log exists only
*inside* the container.

**Solution:** run that script via `container.sh exec decode`, not on the
host. Note results under `/opt/kvstack` **are** visible from both, because
`STACK_ROOT` is mounted.

### 7. `FAIL unknown argument: decode`

**Cause:** the bench scripts differ. `10-bench-baseline.sh` accepts
`--target=decode` and `--target decode`; `30-bench-concurrency.sh` accepts
**only** the `=` form for `--pp/--tg/--depth`.

**Solution:** always use `--flag=value` in `scripts/bench/`.

### 8. A "cold reader" test that is not actually cold

**Cause:** `pkill -f lmcache.v1.multiprocess.http_server` **does not kill
the MP daemon** — measured: same pid before and after, while
`pkill -f api_server` kills vLLM fine. A surviving daemon keeps L1 and the
in-process index warm, silently invalidating the test.

**Solution:** `container.sh down <role>` then `up <role>`. Recreating the
container is the only reliable way to get a genuinely cold reader — and
remember it destroys the container's `/tmp`, so re-stage anything you put
there.

### 9. The KV device is missing after a reboot

See §1.3 — and **resolve the device by NQN before concluding it is gone**;
on a kernel-NVMe-oF lab the index moves across boots, so "`/dev/ng1n1` is
missing" may only mean it is now `/dev/ng3n1`.

On DSC-attached labs, rebind via `/sys/bus/pci/drivers/nvme/bind`, expect
to retry over several minutes, and treat `block device for nsid 1 not
supported (csi 1)` as success rather than failure.

### 10. Loud startup warning: `device advertises value_max=4096 but configured max_value_size=32768`

**This warning is expected and correct on this hardware.** The device
understates its true ceiling by 8x: 32768 stores succeed and read back
cross-node; 33792 and above fail with `sct=7 sc=234`. 32768 is the exact
measured ceiling.

**Do not** silence it by lowering the configured value, and **do not** set
`NIXL_KV_STRICT_DEVICE_CEILING=1` — that would refuse to start on exactly
the configuration measured working. Changing this value changes on-wire
object geometry, which would require a namespace drain (currently blocked).

#### Above 32768 there is ONE gate, and it is a safety gate, not a limit

An earlier revision of this note claimed page sizes above 32 KiB were
"gated by two independent mechanisms" and that 32 KiB was "the largest
usable page". **That was wrong and is retracted.** A later "64 KiB works
and is only stopped by a Python assert" revision was also wrong in a
different way. **Measured 2026-10-12: the behaviour is PLUGIN-DEPENDENT, and
the two nodes currently run different plugin binaries** (`smc1` clean,
`smc2` reverted `beca7b7` fan-out — see `docs/KV-BLOCK-MOVEMENT.md` and
AGENTS.md §5.1). NIXL is byte-identical on both nodes, so the sub-chunking
is **not** "inside NIXL's vendor transfer engine" and **not** absent from
this repo's source — it is this repo's own reverted fan-out build, live only
on decode.

**On the clean build (`smc1`/prefill), the 32768 ceiling is real and is
reached.** A single device Store carries the full `align_bytes` (1:1), and
`align_bytes=65536` **fails outright**: `store_ops=4`, `completions_ok=0`,
`completions_err=36`, 0/32 keys stored. 4096/16384/32768 all succeed 32/32
with `completions_err=0`, following `device_ops_per_key = pages + 1`
(measured 2080/544/288 ops for 32 keys at 256 KiB/key). The item 10
`sct=7 sc=234` ceiling does **not** "belong to a different code path" — this
path reaches it directly, and 32768 is exactly the largest page that works.

**On the fan-out build (`smc2`/decode), the ceiling is never reached.**
`build_and_enqueue_parts()` splits every page by the device-discovered
`value_max=4096`, so **no single device Store command ever exceeds 4096
bytes**, and `align_bytes=65536` "succeeds" 32/32. The law is
`ops = pages × (⌈align_bytes/4096⌉ + 1) + keys × 2`. Decode's commit-read
path is additionally broken: `read_commit()` registers `max_value_size`, so
the plugin requests `⌈mvs/4096⌉` parts when only one was written — measured
`completions_err` of exactly 224 (=32×7) at `mvs=32768` and 480 (=32×15) at
`mvs=65536`; prefill has 0 such errors.

**The remaining gate is about atomicity, not capability.**
`nixl_kv_l2_adapter.py:371` (`§7 assert 1`) refuses when
`align_bytes > max_value_size`:

> `the value-size split this would require has no recorded sub_size and no
> atomicity. Refusing to start.`

Read that carefully: the objection is that the 16 pieces are **not
crash-consistent**, not that they cannot be written. Raising
`NIXL_KV_MAX_VALUE_SIZE` to enable larger pages **bypasses a deliberate
safety gate** — it works mechanically, but a crash mid-write leaves
independently-keyed fragments with nothing recording that the set is
incomplete. Do not raise it in production on the strength of the throughput
numbers alone.

Measured on the **decode/fan-out build** across three sizes (2026-10-12)
— the below is *that* build's law, not a property of the hardware:

| `align_bytes` | device ops/key | ops per KiB | bandwidth |
|---|---|---|---|
| 4096 | 4 | 1.00 | 0.60–0.67 MB/s |
| 32768 | 11 | 0.34 | 4.8–5.5 MB/s |
| 65536 | **19** | **0.29** | **8.95 MB/s** |

`device_ops_per_key = ceil(align_bytes / 4096) + 3` holds exactly at all
three points. The 64 KiB run resolved the previously-unexplained `+3` by
direct wire count: **16 × `len=4096` (data) + 2 × `len=1` + 1 × `len=94`
(the commit JSON)**. The **clean build's** law is the simpler
`device_ops_per_key = pages + 1` (2080/544/288 ops for 32 keys at
4096/16384/32768), and it does **not** hold the 65536 point — that one fails
0/32 (see above).

Ops per *key* rises with page size; ops per *byte* falls. Key rate stays
flat (~143–171/s — the serialized producer of item 11), so bandwidth scales
with page size almost for free. The gain comes from amortizing the fixed
3-op overhead: 75% of ops are overhead at 4 KiB, 27% at 32 KiB, 16% at
64 KiB.

Full per-`align_bytes` tables for both builds, the read-path error
arithmetic, and the reproduction recipe are in
[`docs/KV-BLOCK-MOVEMENT.md`](KV-BLOCK-MOVEMENT.md).

Changing `align_bytes` changes the namespace fingerprint and therefore
strands every object already written, and there is no delete primitive to
reclaim them.

### 11. Huge `submit_retry`, low bandwidth

Measured ~568 retries per completed op. The reactor busy-spins on `-EBUSY`
once the queue is full.

**Solution / next step:** raising `NIXL_XNVME_NUM_QUEUES` alone does **not**
help (the producer is serialized). Raising concurrent submits
(`--in-flight 4`) gives 2.3–2.5x. Reducing the retry storm is an open
optimisation target, not a solved problem.

### 12. The namespace filled up / stale objects

**No delete primitive**, shared with another party, and it still holds
pre-fix corrupt objects. `50-reset-namespace.sh` currently **refuses to
run** because the live `nvmf_tgt` was not started by this repo's scripts;
replacing it risks the DSC/DPU peering, and DSC recovery is
non-deterministic and slow.

**Do not size against "1 GiB"** — that limit was never real (§3.6,
TODO 6.39). If you are running out of room, the cause is the absent delete
primitive, not a capacity ceiling you have hit.

**Solution:** size runs (§3.6) and use a distinct `namespace` per run so
old objects can never be mistaken for new hits. Do not attempt a drain
without deciding the ownership question first (TODO 6.34, 6.18).

### 13. Everything passes but no KV moves

**A correct completion proves nothing.** Two separate defects in this
project produced perfect output at plausible latency while transferring
zero KV. Read the two engines' throughput counters, not the response text
or the HTTP status.

Specifically: `query_memory()` reports **PRESENT as `{}` — an empty, falsy
dict** — and ABSENT as `None`. Code written `if resp[i]:` scores every hit
as a miss and reproduces `retrieve_ops=0` with a brand-new root cause. Use
the identity check (`is_probe_hit`), never truthiness.

### 14. A green low-level check that proves nothing about the layer above

Rung `35` passed 8/8 while the adapter's real commit-write path was
silently broken underneath it, because `35` writes its commit object
through a *different* NIXL call sequence than the adapter does, and
structurally can never hold two overlapping OBJ registrations.

**Lesson:** compare **code paths**, not just outcomes, before trusting a
lower rung to cover a higher one.

### 15. `01-install-benchy.sh` dies with `KeyError: 'MODEL'`

```
File "<stdin>", line 4, in <module>
KeyError: 'MODEL'
```

**Cause:** the tokenizer pre-download heredoc is a separate python process
reading `os.environ["MODEL"]`; `cluster.env` sets `MODEL` without exporting
it. `HF_HOME`/`HF_TOKEN` were exported right above it, `MODEL` was not.
Because the kill lands under `set -e` **before** the CLI verification, the
install reports FAILURE while pip has actually **SUCCEEDED** — and the
tokenizer this step exists to pre-cache is left uncached, so the next timed
sweep pays for a cold HF fetch inside its own measurement.

**Solution:** fixed 2026-09-21 — `export MODEL` added. If you see this on
an older checkout, the install did work; re-run after the fix to warm the
tokenizer cache.

### 16. Rung 50 reports `decode side channel reachable (30.2.1.1:5601)` FAILED from the control host

**Cause:** decode's NIXL side channel is bound to a **FABRIC** address
(`PD_SIDE_CHANNEL_HOST_DECODE=30.2.1.1`) that the control host has no route
to, and the log-based verdict needs `/var/log/kvstack/vllm-decode.log`,
which is not bind-mounted (§2.4).

**Solution:** run rung 50 **on the decode node, in the container**. This is
a **FALSE FAIL** on an otherwise healthy stack, not a real defect.

**The context has moved, and it is worth restating precisely (§1.4).**
`30.2.1.1` is `benic1p1`, but both roles' `UCX_NET_DEVICES` are pinned to
a **different** device entirely. That means the side channel and the
actual UCX data device sit on **different fabric planes**, not merely
different subnets — TODO 1.9's original "harmless today" qualifier on
this asymmetry is now stale and should not be read as still current;
resolve which plane each is meant to be on before trusting either address
under a topology change.

### 17. `--prefix-benefit` reports a speedup below 1.0 on a healthy tier

**Cause:** `compare_runs.py --prefix-benefit` pairs inference@depth=0
against inference@depth>0 — two different workloads, not a like-for-like
cache comparison (§4.4, §4A.2).

**Solution:** do not trust the ratio; compare the context-load row against
the inference row at the **same depth** instead. See TODO 1.13.

### 18. The first llama-benchy run in a fresh container downloads a text corpus

```
Downloading book from https://www.gutenberg.org/files/1661/1661-0.txt...
Saved text to cache: /root/.cache/llama-benchy/…
```

**Cause:** llama-benchy sources its prompt corpus from Project Gutenberg
and caches it under `/root/.cache/llama-benchy`. Only
`/root/.cache/huggingface` is bind-mounted (as `HF_HOME`) — that directory
is **not**, so the corpus is re-downloaded after every `container.sh
down/up`, and the run needs egress to gutenberg.org.

**Solution:** it happens during llama-benchy's startup, before the timed
runs, so it does not land inside a measured window — but it **will** fail a
run on a host with no external egress. Re-run `01-install-benchy.sh` after
any container recreation, and expect the corpus fetch on the first sweep
afterwards.

### 19. `ipc_wrapper.py:85` KV-cache registration OOM — root cause NOT established

```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 2.00 MiB.
GPU 0 has a total capacity of 191.98 GiB of which 28.37 GiB is free.
```

**Cause:** the LMCache MP daemon fails `REGISTER_KV_CACHE` with the above
`torch.OutOfMemoryError` on a **2 MiB** allocation against **28.37 GiB
free**, on IPC import 1 of 36. vLLM decode's `EngineCore` then times out
at 300 s waiting for the daemon and its worker segfaults during HSA
teardown, inside PyTorch's **vendored** `libhsa-runtime64.so`. Root cause
is **NOT established** — seven candidate causes have been eliminated
(kernel OOM, physical HBM capacity, GPU virtual address space, an env-var
discriminator, a `dma_buf` IPC leak, container/host ROCm version skew,
and cross-process IPC handle transport as a sufficient cause on its
own), and none is confirmed.

**2026-09-29 refinement — this is not what it looks like.** The
allocator is already dead **before** the IPC import: a bare
`torch.empty(2<<20, device='cuda:0')` in the same container, with no
LMCache, no NIXL, no IPC involved at all, fails **identically** while
vLLM decode is resident. So this is **not** an IPC failure and **not**
an LMCache failure — it is something vLLM's `EngineCore` does that
leaves the GPU unable to hand out any allocation to any other process,
and every earlier "IPC" framing of this defect, including this entry's
own title, is aimed at the wrong layer.

**2026-10-05 — there are TWO distinct faults landing on this one line.**
Reduced to three lines, no vLLM, no LMCache, no NIXL, no second process,
in an ephemeral container on an **idle** GPU:

```python
a = torch.ones((256,1024), dtype=torch.float16, device="cuda:0")  # OK
h = a.untyped_storage()._share_cuda_()                            # OK (8 fields)
torch.UntypedStorage._new_shared_cuda(0, *h[1:])                  # FAILS
#   torch.AcceleratorError: HIP error: invalid device context (hipErrorInvalidContext)
```

Note what this does **not** show: plain allocation and the IPC *export*
both succeed. The allocator is healthy. Only the IPC **import** fails.
That is a different fault from the 2026-09-29 one above, where a resident
vLLM leaves *every* allocation failing. Both surface at `ipc_wrapper.py:85`,
which is why they have been conflated:

| | 2026-09-29 fault | 2026-10-05 fault |
|---|---|---|
| vLLM resident? | **yes** (required) | **no** (idle GPU) |
| plain `torch.empty` | **fails** | succeeds |
| `_share_cuda_` (export) | — | succeeds |
| `_new_shared_cuda` (import) | — | **fails**, `hipErrorInvalidContext` |

Reproduced identically across **6 images** (5× `rocm-aic:*` plus stock
`rocm/pytorch:latest`), **2 torch builds** (`2.13.0+rocm7.2`,
`2.10.0+rocm7.2.4`), **2 kernel drivers** (smc1 `6.16.13`, smc2 `6.18.4`),
**both** values of `HSA_ENABLE_IPC_MODE_LEGACY`, and at **TP=1 and TP=2**.
So it is not node-specific, not driver-version-specific, not TP-related,
and not fixed by the legacy IPC mode flag.

**`expandable_segments` — tried, does NOT fix the live stack.** In the
*same-process* snippet above, `expandable_segments:True` makes
`_new_shared_cuda` pass. That is misleading: importing a handle you just
exported in the same process does not model the real topology. Across
**processes** the reproducer segfaults under *every* combination
(`exp=False/imp=True`, `True/True`, `True/False`). Running the MP daemon
with `expandable_segments:True` while vLLM kept `False` was implemented,
deployed and measured — the daemon's process env was verified to carry it —
and decode still failed with a fresh OOM. **That change was reverted**;
invariant 3 (`expandable_segments:False`) stands. Do not re-try this
without new evidence.

**Also corrected 2026-10-05:** TP=2 was briefly suspected (the first
observed failure was on GPU 1, the second TP worker's device). That is
wrong — it reproduces at TP=1 on GPU 0, and single-process with no tensor
parallelism at all. The GPU index simply follows whichever device the
worker holds.

**Solution:** none on the production build. `gpu_memory_utilization` 0.85
→ 0.60 was tried and changed nothing — this is not a headroom problem.

**2026-10-01 — a different vLLM build does not reproduce it.**
`rocm/vllm:latest` (AMD's ROCm-fork build, `0.11.2.dev673+g839868462`),
run standalone with no LMCache/NIXL at all, did NOT poison the allocator
at a comparable-or-tighter free-VRAM margin than the documented failure.
Not yet proof production can move to it — LMCache's compatibility with
that build is a separate open question. See
TROUBLESHOOTING.md's `ipc_wrapper.py:85` entry (2026-10-01 box, at the
top) for the full measurement and its caveats, and TODO 6.47.

**2026-10-07 — `gpu_memory_utilization=0.45` avoided the fault twice in a
row on smc2 (decode); does NOT overturn "not a headroom problem" above.**
Full stack (vLLM + LMCache MP daemon + the `nixl_kv` L2 adapter), fresh
containers, `GPU_MEM_UTIL=0.85` (the repo default): decode's `EngineCore`
died at `ipc_wrapper.py:85` during `REGISTER_KV_CACHE`, identical
signature to this entry, reproduced on a second fresh attempt after
clearing the resulting zombie daemon (item 20). Only change:
`GPU_MEM_UTIL=0.45` (passed as a one-off env override, not yet wired to
persist — see `config/cluster.env`'s `GPU_MEM_UTIL` comment). Both the
LMCache daemon and vLLM came up healthy; a subsequent `scripts/bench/
run-all.sh --quick` ran end to end against the live proxy with no
further faults.

This is one data point at one additional value, on top of the existing
"0.85 → 0.60 changed nothing" result — not a root-cause finding, and not
strong enough to contradict the extensive same-process reproduction above
showing the import fails independent of any allocator headroom at all.
Plausible reconciliation: a lower utilization changes vLLM's *memory-
profiling sequence* before it commits its KV-cache reservation (this repo
reports "174 GiB free" at OOM time despite the failure, i.e. this is not
a simple capacity exhaustion), which could shift timing/ordering enough
to dodge whichever process/context state triggers the import fault,
without fixing it. Re-test at 0.60 and 0.45 again before trusting this as
reproducible, and record whether it holds on smc1 too (only exercised on
decode/smc2 so far). `KV_CACHE_MEMORY_BYTES` (vLLM's own
`kv_cache_memory_bytes` config field, bypasses the utilization-fraction
profiling path entirely per its docstring) is an untried, more targeted
experiment — see `config/cluster.env`'s `GPU_MEM_UTIL` comment.

**2026-10-08 — reproduced at 0.85 on a fully idle GPU; 0.45 confirmed on
BOTH nodes; `kv_cache_memory_bytes` TRIED and does NOT bypass the fault.**
Three of the open questions above are now answered:

1. **Not headroom — measured on a clean GPU.** After clearing the leaked
   IPC pin described below, every GPU on smc2 read `297771008` B (284 MiB,
   the idle baseline). Starting decode at `GPU_MEM_UTIL=0.85` gave
   `Available KV cache memory: 146.77 GiB` / `GPU KV cache size:
   1,068,736 tokens`, reached `Wrapping 36 KV cache tensors for IPC`, and
   the daemon failed at `ipc_wrapper.py:85`:

   ```
   torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 2.00 MiB.
   GPU 0 has a total capacity of 191.98 GiB of which 175.18 GiB is free.
   Of the allocated memory 0 bytes is allocated by PyTorch, and 0 bytes is
   reserved by PyTorch but unallocated.
   ```

   A 2 MiB allocation failing against 175 GiB free, in a process holding
   **zero** PyTorch allocations, is a stronger form of the existing
   "174 GiB free" datapoint: no fragmentation story and no capacity story
   survives it. Treat "not a headroom problem" as settled.

2. **`kv_cache_memory_bytes` does NOT bypass it** — the "untried, more
   targeted experiment" named above and in `config/cluster.env`. On vLLM
   `0.26.0+rocm`, `VLLM_EXTRA_ARGS="--kv-cache-memory-bytes 42949672960"`
   never reaches the IPC path at all: `request_memory()` in
   `vllm/v1/worker/utils.py:435` still validates free VRAM against the
   utilization fraction first and dies with `ValueError: Free memory on
   device cuda:0 (121.32/191.98 GiB) on startup is less than desired GPU
   memory utilization (0.85, 163.19 GiB)`. The flag parses and is
   accepted; it simply does not remove the utilization check from the
   startup path on this build, contrary to its own docstring. Re-read
   `request_memory()` in the installed build before spending time here
   again.

3. **0.45 holds on smc1 too** (the entry above asked for this). Both nodes
   now run `GPU_MEM_UTIL=0.45` and both daemons log `Registered KV cache
   for GPU ID <id> with 36 layers` — which **prefill had never once done**
   before this date.

**The failure is role-asymmetric, and prefill's half is silent. That is
the operationally important part.** At 0.85:

| | decode (smc2) | prefill (smc1) |
|---|---|---|
| symptom | **fatal** — `ConnectionError: LMCache server did not respond to register_kv_caches within 300.0s`; EngineCore dies | **silent** — `vllm-prefill.log` stops after `Wrapping 36 KV cache tensors for IPC`; server comes up healthy and serves |
| daemon | dies, leaves a zombie (item 20) | alive, but with **no GPU context ever registered** |
| visible as | node down, obvious | `No GPU context registered for instance ID <n>` on every store; `No GPU context found for model ... during lookup!` on every lookup |

Measured 2026-10-08: prefill had been in that state since **2026-10-07
14:57** — about 16 hours — serving traffic throughout. The proxy hides it
by design: `prefill priming failed (TimeoutError: ) — degraded,
forwarding to decode without a primed cache`. Output stays correct, so
nothing alarms, but every request pays the proxy's full 60 s priming
timeout before falling through and the KV tier contributes nothing.
End-to-end this reads as a **hang**, not a cache miss: a ~1 400-token
streaming request returned TTFB `60.7 s` (and, before the proxy was
separately restarted, zero bytes / `HTTP 000`), while a 20-token request
answered in 0.03 s. That shape is what makes this look like a network or
proxy bug rather than a registration failure.

**Confirming a healthy node is cheap, so confirm it.** After any restart,
on **each** node:

```bash
docker exec kvstack-<role> grep -c 'Registered KV cache' /var/log/kvstack/lmcache-mp-daemon.log
docker exec kvstack-<role> grep -c 'No GPU context'      /var/log/kvstack/lmcache-mp-daemon.log
```

The first must be ≥ 1 for the current start; the second must be 0.
`/health`, `/v1/models` and short completions **all pass** on a node whose
LMCache leg is dead — none of them touch it.

After the fix, same hardware and prompt: TTFB `0.029–0.077 s` (from
60.7 s), decode `External prefix cache hit rate: 100.0%` (from 0.7 %),
`NixlPullConnector` moving 78 MB per transfer at 2797 MB/s, and
`scripts/verify/40-verify-disagg.sh` passing all 9 checks with TTFT
improving 2.15× (threshold 1.5×) — the same script having failed
`request 1 body non-empty` an hour earlier.

**Related, and easy to misdiagnose as this OOM: the daemon pins a dead
engine's KV cache.** Killing vLLM does not free its KV cache while the MP
daemon still holds the imported CUDA IPC handles. Measured 2026-10-08 on
smc2 with vLLM already dead (a zombie, item 20): GPU 0 still read
**70.98 GiB** used, while `rocm-smi --showpids` attributed only 682 MiB to
the daemon — because the pin is an *import* of an allocation the dead
exporter owned. Stopping the daemon dropped GPU 0 to 284 MiB at once.
Until that memory is released the next start fails the `request_memory()`
precheck quoted in (2), which is a **different** error from this item's
OOM. **Restart the daemon, not just vLLM.**

### 19b. `No GPU context found ... during lookup!` — the daemon is up and the L2 tier is unreachable

**Measured 2026-10-12 on decode.** The daemon answers `/status`, reports
`event_loop_alive: true`, and serves Prometheus — and still rejects **every**
lookup:

```
ERROR: No GPU context found for model Qwen/Qwen3-8B with world size 2 during lookup!
       (lookup.py:205)
```

The rejection happens at `lookup.py:205`, **before** L1 or L2 is consulted. So
the whole KV tier reads as idle: `l2_lookup_calls`, `l2_commit_writes` and every
device `store_ops`/`retrieve_ops` stay at zero while traffic flows normally.
Nothing in `/status` says anything is wrong — the counters are *honest*, the
tier genuinely did nothing.

**Cause:** a vLLM worker registers its GPU context with the daemon when its
connector initialises. Restart the daemon under a **live** vLLM and that
registration is lost with the old process; the new daemon never acquires one.
This is the same hazard item 19's table calls "alive, but with **no GPU context
ever registered**".

**Consequence for benchmarking:** a full llama-benchy sweep ran in this state on
2026-10-12 and produced a healthy-looking 100 % `vllm:external_prefix_cache_hits_total`
— entirely from the NixlConnector P→D leg, with the LMCache tier contributing
nothing. **Always cross-check `:8080/status` before attributing a hit rate to
the KV cache.**

**Fix:** respect bring-up order (`AGENTS.md` §6) — daemon first, **then** vLLM.
After any daemon restart, restart the role's vLLM or the L2 tier stays dark.
Grep for the line directly:

```bash
docker exec kvstack-<role> grep -c 'No GPU context found' \
    /var/log/kvstack/lmcache-mp-daemon.log
```

### 20. Zombie PID silently blocks a daemon restart

**Cause:** the role container's PID 1 is `sleep infinity`, which never
reaps. A dead LMCache MP daemon or a crashed vLLM worker therefore
lingers as a **zombie**, and `start-lmcache-daemon.sh`'s liveness check
uses `kill -0`, which succeeds against a defunct pid — so it reports
`already running (pid N) — not restarting` for a daemon that is
actually dead, and silently refuses to start a working one in its place.
**NOT FIXED** in the scripts.

**Solution (lighter, measured 2026-10-08):** the zombie cannot be reaped
without replacing PID 1, but it does not have to be — only the **pidfile**
blocks the restart. Verify death by process *state* instead of `kill -0`,
clear the pidfile, then start normally:

```bash
docker exec kvstack-<role> bash -c '
for n in vllm-<role> lmcache-mp-daemon; do
  pf=/run/kvstack/$n.pid; [ -f "$pf" ] || continue
  p=$(cat "$pf"); st=$(ps -o stat= -p "$p" 2>/dev/null | tr -d " ")
  case "$st" in ""|Z*) echo "clearing $n (pid $p stat=[$st])"; rm -f "$pf" ;; esac
done'
```

`ps -o stat=` prints nothing for a reaped pid and `Z`/`Zs` for a zombie;
both mean "not running", and `kill -0` cannot distinguish either from a
live process. Measured clearing `lmcache-mp-daemon pid=10016 stat=[Zs]`
on smc2, then restarting daemon and vLLM successfully **without touching
the container**. `container.sh down`/`up` still works and is still the
right move when you want a genuinely cold reader (item 8).

**Trap: the pidfile holds a container-namespace pid.** Checking it against
a host `ps` is meaningless and will make a live daemon look dead.
`rocm-smi` and `/sys/class/kfd/` report **host** pids while `ps` inside
the container reports **namespace** pids; for the same process these
differ (measured 2026-10-08: the MP daemon was pid `6091` in-container and
`55802` on the host). Run the check inside the container, as above.

### 21. RDMA mode connects anyway over TCP

**Cause:** a silent TCP fallback can pass RDMA acceptance even with
`KV_TRANSPORT=rdma` set. By design `setup_ucx_env` excludes `tcp` from
`UCX_TLS` in RDMA mode (HANDOFF invariant 6), but anything that bypasses
`setup_ucx_env` — a hand-launched vLLM process, or `UCX_TLS` exported
earlier in the environment and left to override what this function
sets — reintroduces it invisibly. This is now **live-relevant**, not
theoretical: `creds/setup-4.env` sets `KV_TRANSPORT="rdma"` for this
cluster.

**Solution:** confirm nothing pre-sets `UCX_TLS` before `setup_ucx_env`
runs, and confirm which leg you are actually observing — the storage leg
is NVMe-oF/TCP unconditionally by design, and seeing TCP there is
correct, not a fallback. See TROUBLESHOOTING.md's "RDMA mode connects
anyway over TCP" entry for the full diagnostic.

### 22. `UCX_IB_ROCE_SUBNET_PREFIX_LEN` must be 8, not 16

**Cause:** prefill and decode sit in different `/24`s — smc1 is
`30.1.N.1/24`, smc2 is `30.2.N.1/24` — so UCX's RoCE local-subnet
reachability check needs to compare at `/8` to see them as the same
fabric. At the old `/16` setting UCX reports `Destination is
unreachable` on every transport and silently discards the RoCE lane,
falling back to shm/ROCm-only transports that cannot do active
messages. **A verbs-level check cannot detect this**: `ib_send_bw` over
the identical devices at the identical GID index reads a healthy
**25858 MiB/s** regardless of this setting, because `ib_send_bw` never
consults it — this is a UCX policy filter, not a fabric fault.

**Solution:** `UCX_IB_ROCE_SUBNET_PREFIX_LEN` must be `8`. See
`config/cluster.env`'s comment on this variable for the isolated,
single-variable measurement.

### 23. `NIXL_ERR_BACKEND` / `EngineCore failed to start` from a stale RDMA device pin

**Cause:** a reboot renamed every RoCE device on both nodes (§1.4), and
creds still pinned the old names. **Measured 2026-09-30:** after the
2026-09-29 reboot, devices came back as `roce_benicNp1` while creds still
pinned `ionic_7:1`. UCX matches no device, falls back to a transport that
cannot do active messages, and `NixlConnector` dies at construction with
`NIXL_ERR_BACKEND`; vLLM surfaces this as `EngineCore failed to start`
from `multi_connector.py`. See §1.4 for the check that catches this and
the full failure signature.

**The diagnostic lesson is worth keeping on its own:** the top-level
Python traceback (`RuntimeError: Engine core initialization failed`)
never names a device. The UCX `WARN` that does — and that lists the
correct device names to use instead — sits ~6 lines **above**
`EngineCore failed to start` in the container's `vllm-decode.log`.
Always read upward from that line, not just at it.

### 24. `assert req_id in self.requests` kills EngineCore once KV transfer actually works

**Cause:** `vllm/v1/core/sched/scheduler.py:2648`, in
`_update_from_kv_xfer_finished()` — a NIXL KV transfer completes and is
reported for a request the scheduler has already dropped. The assert has
no handling path, so `EngineCore` dies and the API server follows with
`vllm.v1.engine.exceptions.EngineDeadError`. **NOT FIXED**; upstream
assert, no workaround known.

**Measured 2026-10-08 on setup-4**, immediately after item 19's
registration failure was fixed: both nodes' EngineCores died within ~60 s
of each other (decode 08:46:12, prefill 08:47:14) under ordinary proxy
traffic. Restarting both cleared it, and it did not recur across the
verification runs that followed.

**Why it shows up *now*:** while LMCache registration was failing (item
19) no real KV transfers happened, so nothing ever reached this code path.
Fixing registration is what made it reachable. Expect it to be latent on
any deployment whose LMCache/NIXL leg has silently been dead.

**Suspected trigger:** a request that disappears mid-transfer — a client
disconnect or a truncated stream. While debugging, read streaming
responses to completion rather than truncating them (`curl ... | head`).
This is a hypothesis, not a confirmed reproducer: the observed crash also
followed ordinary, non-aborted requests.

---

---

