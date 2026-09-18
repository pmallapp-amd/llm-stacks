# Bring-up and benchmarking runbook

How to get this cluster into a state where a benchmark number means
something, and then how to run the three benchmark harnesses that exist.

Last updated 2026-09-18.

> **Scope change, 2026-09-18.** This document used to be a full
> from-source bring-up guide (build SPDK, build UCX/NIXL, install vLLM).
> That path has not completed successfully in this project and is not what
> the cluster runs — the deployment unit is the vendor container image
> (HANDOFF §6.3, TODO 6.1). Those sections are **removed, not
> superseded**: recover them from git history (`git log -- docs/BRINGUP.md`)
> if the from-source path is ever revived. What remains here is the path
> that is actually exercised: bring the containerised stack up, prove the
> environment is sane, then benchmark it.
>
> **Read [HANDOFF §3](HANDOFF.md#3-how-to-resume) first** if you are
> resuming — it carries cluster state as handed over. This document assumes
> you have done that.

---

## §0 The three harnesses, and which question each one answers

Pick the harness that matches your question. They measure different layers
and are not interchangeable; the most common way to waste a day here is to
ask a KV-block question of an engine-level harness.

| Harness | Layer | Answers | Status on this cluster |
|---|---|---|---|
| **`lmcache bench l2`** (§3) | L2 adapter → NIXL → device | KV blocks stored/requested, **hit rate**, block size, **store/load MB/s**, per-key latency | ✅ **VERIFIED 2026-09-18** — numbers in §3.7, device-cross-checked |
| **llama-benchy** (§4) | HTTP / inference engine | TTFT, tokens/s, prefix-cache benefit, concurrency behaviour | ✅ **VERIFIED 2026-09-18** — runs end to end; but see the F5 confound in §4.4 |
| **nixlbench** (§5) | NIXL transport | raw per-backend transfer bandwidth and latency | ❌ **NOT BUILT** — source only, blocked on a missing dependency (§5.2) |

**Decision guide.**

- "How many KV blocks were stored, how many were asked for, what fraction
  hit, how big are they, how fast do they move?" → **§3.** It never touches
  vLLM, so no engine-level cache can confound it.
- "Does the user-visible latency improve, and does the cache help
  end-to-end?" → **§4**, and read §4.4 before believing the answer.
- "How fast is the transport itself, independent of LMCache?" → **§5**, once
  it is built. Until then, do not quote a transport number.

**§3 does not require vLLM, the proxy, or even prefill.** It needs only the
device, the plugin, and the adapter. If you only need block-level numbers,
skip §2 entirely — it is the fastest path to signal, and the least likely
to be invalidated by something unrelated breaking.

---

## §1 Environment sanity — do this before every session

Each check below has cost this project at least one wasted run, and each
one presents as a failure in whatever you were actually testing rather than
as itself. Run them in order; each is cheap.

Throughout, `[SMC1]` = prefill, `[SMC2]` = decode, `[SMC3]` = KV target.
Addresses come from `creds/active.env` (§6 of HANDOFF); nothing here
hardcodes them.

### §1.1 Node uptime — are the machines even stable right now

```bash
# [SMC1] and [SMC2]
uptime
```

**Expect:** an uptime comfortably longer than the step you are about to
run.

**If it is short:** `smc2` has shown 7 boots in one day, cycling every
3–13 minutes — shorter than a model load takes (TODO 6.20). Both nodes
rebooted 3 times in a single session. If a node has been up for less time
than your step needs, you will lose the run and the failure will look like
something else entirely. Wait, or pick a shorter step.

### §1.2 GPUs — `amdgpu` does not autoload here

```bash
# [SMC1] and [SMC2]
lsmod | grep -c amdgpu      # expect a non-zero count
rocm-smi                    # expect 8 GPUs, 192 GiB VRAM each
```

**If zero:** `modprobe.blacklist=amdgpu` is on the kernel cmdline on both
nodes. It suppresses **autoload only** — an explicit `modprobe amdgpu`
restores all 8 GPUs with no reboot and no GRUB edit:

```bash
modprobe amdgpu
```

`scripts/common/01-host-prep.sh` does this automatically every run
(opt-out `AMDGPU_AUTOLOAD=0`). It does not survive a reboot. Not needed at
all for §3.

### §1.3 The KV device — `/dev/ng1n1` must exist

```bash
# [SMC1] and [SMC2]
ls -l /dev/ng1n1
nvme ns-descs /dev/ng1n1     # expect csi: 0x1 and eui64 e46cfefeffcdae01
```

**Expect** a **char** device (`crw-...`), and **no** `/dev/nvme1n1` beside
it. That absence is correct: `csi 1` is the KV command set, which has no
block-device semantics.

**Never point anything at `/dev/ng0n1`.** That is the OS boot drive
(`Micron_7450`, 800 GB) on both compute nodes. The vendor's own
`deploy-xnvme.sh` defaults to it. Invariant 10.

**If `/dev/ng1n1` is missing** — this is the DSC boot-time race (TODO 6.26),
not a dead card. The kernel probes the controller ~3 s after PCIe
enumeration, before the DPU-side application is ready, gets
`Device not ready; aborting initialisation, CSTS=0x0`, detaches, and
nothing re-probes it. Distinguish it from real hardware failure:

```bash
dmesg | grep -i 'CSTS=0x0'                 # the race signature
setpci -s 36:00.0 00.L                     # expect 10051dd8 — link is fine
lspci -k -s 36:00.0                        # pds_core / ionic bind fine
```

All three healthy alongside a missing device means the DPU side is simply
not serving yet. Recovery, validated repeatedly on both nodes, no reboot:

```bash
echo -n "0000:36:00.0" > /sys/bus/pci/drivers/nvme/bind
```

**Expect** `nvme nvme1: 63/0/0 default/read/poll queues`, then
`block device for nsid 1 not supported (csi 1)` — **the second line is
expected, not an error.** Takes ~2 minutes to resolve either way.

**It is not deterministic on the first attempt.** Measured 2026-09-18: both
nodes hit the identical signature at t=6.1 s after a fresh reboot, and the
rebind failed **twice** with the same signature before succeeding on the
third attempt, ~20 minutes after boot. Expect to retry over minutes.

Per the hardware owner this race is expected behaviour on this hardware,
not a defect — treat it as a documented procedure, not an open bug.

### §1.4 The target is shared — confirm who owns it

```bash
# [SMC3]
ps -ef | grep nvmf_tgt | grep -v grep
/root/kv_spdk/scripts/rpc.py nvmf_get_subsystems 2>/dev/null | grep nqn
```

`smc3` is **shared with another party** and has been reconfigured out from
under this project more than once (TODO 6.18). **Do not restart another
party's target to reclaim it — agree ownership first.**

As of 2026-09-18 the live `nvmf_tgt` serves `nqn.2016-06.io.spdk:cnode1`,
**not** our `nqn.2024-01.io.nixl:kv0` — and `/dev/ng1n1` works on both
compute nodes anyway, because each node's own Pensando DSC is itself an
NVMe-oF initiator that re-exports the target's namespace as a local PCIe
function. There is no local, independent, unshareable device here.

**Consequence for benchmarking:** you are sharing a 1 GiB namespace with
someone else, and **there is no delete primitive** (TODO 6.29). Size your
runs (§3.6).

### §1.5 The container, and the overlays that make it work

```bash
# [SMC2] (and [SMC1] if you need prefill)
cd /root/kv-cache
./scripts/common/container.sh status decode
./scripts/common/container.sh up decode        # idempotent
```

What actually runs is **the image plus four bind-mount overlays**, not the
image (HANDOFF §2.1). Two are load-bearing:

| Overlay | Why it matters |
|---|---|
| repo-built `libplugin_XNVME_KV.so` | The image's own plugin has **no `queryMem` override**. Existence probing — and therefore all L2 discovery, and therefore every hit-rate number in §3 — exists *only* because of this mount. |
| `nixl_kv_l2_adapter.py` | This repo's L2 adapter. Auto-discovered by `pkgutil`; zero vendor files edited. |
| `lmcache_mp_connector.py` (patch 0011) | Verified **absent** from the image. Guards the `MultiConnector` composition this cluster runs. |
| `nixl_utils.py` | The image ships a ROCm-patched `nixl` and no `rixl`; upstream's platform test rejects a working install without this. |

Prove the adapter overlay actually took effect — a mount that silently did
not land is indistinguishable from a cache that stores and never retrieves:

```bash
./scripts/common/container.sh adapter-check decode
```

**Expect** confirmation that `nixl_kv` is registered and resolves. If it
does not, nothing in §3 will work and §4's cache numbers will be
meaningless.

### §1.6 One-shot sanity summary

```bash
# [SMC2] — everything §1 checks, in one paste
uptime
lsmod | grep -c amdgpu
ls /dev/ng1n1 && nvme ns-descs /dev/ng1n1 | grep -E 'csi|eui64'
cd /root/kv-cache && ./scripts/common/container.sh adapter-check decode
```

---

## §2 Start the stack — only needed for §4 (llama-benchy)

**Skip this entire section if you only need §3.** Block-level benchmarking
does not use vLLM, the MP daemon, or the proxy.

### §2.1 The LMCache MP daemon

The backend is configured **on the daemon**, not in vLLM's connector
config. There is no YAML in this path — `gen-lmcache-config.sh` was deleted
once confirmed dead (TODO 6.23). The live surface is a repeatable
`--l2-adapter '<JSON>'` flag:

```bash
# [SMC1] and [SMC2] — idempotent; the role start scripts call it for you
cd /root/kv-cache
./scripts/common/container.sh exec decode ./scripts/common/start-lmcache-daemon.sh
```

Verify:

```bash
./scripts/common/container.sh exec decode \
  "curl -s http://127.0.0.1:8080/status | python3 -m json.tool | head -40"
```

**Expect** `is_healthy: true`, and under
`storage_manager.l2_adapters[0]`: `"type": "NixlKvL2Adapter"`,
`"backend": "XNVME_KV"`, and a `namespace` fingerprint. **Both nodes must
derive the same namespace** (e.g. `d9dbd20693b2`) — it is a geometry
fingerprint over model/TP/chunk/dtype/align/max-value. If they differ, the
two nodes cannot see each other's objects and every cross-node lookup will
correctly miss.

### §2.2 Prefill, decode, proxy

```bash
# [SMC1]
./scripts/common/container.sh exec prefill ./scripts/prefill/03-start-prefill.sh
# [SMC2]
./scripts/common/container.sh exec decode  ./scripts/decode/03-start-decode.sh
# [SMC2] (proxy defaults to the decode host)
./scripts/common/container.sh exec decode  ./scripts/proxy/start-proxy.sh
```

These take **~5 minutes per role** at Qwen3-8B/TP=1. `start-vllm.sh`
hard-gates on the daemon being reachable and will `die` with a pointer back
to `start-lmcache-daemon.sh` rather than silently serving from local cache.

Verify each layer independently:

```bash
curl -s http://127.0.0.1:8100/v1/models   # [SMC1] prefill
curl -s http://127.0.0.1:8200/v1/models   # [SMC2] decode
curl -s http://127.0.0.1:8000/status      # [SMC2] proxy — fleet + stats JSON
```

### §2.3 Prove disaggregation actually works before benchmarking it

```bash
./scripts/verify/50-verify-pd-direct.sh    # expect 9/9
./scripts/verify/40-verify-disagg.sh       # expect 9/9
```

The acceptance signal is **decode's `Avg prompt throughput` at 0.0
tokens/s** with external prefix cache hit rate rising toward 100% — decode
does zero prefill work. A correct completion at plausible latency proves
**nothing**: two separate defects in this project produced perfect output
while transferring zero KV.

---

## §3 Benchmark A — LMCache L2 storage bench (KV-block level) ✅

**This is the harness for KV-block questions.** It drives the L2 adapter
through its real `submit_store_task` / `submit_lookup_and_lock_task` /
`submit_load_task` interface, using the same `--l2-adapter` JSON spec the
daemon uses — no vLLM, no proxy, no TTFT in any number it produces.

It ships with LMCache 0.5.3 as `lmcache bench l2`
(`lmcache/cli/commands/bench/l2_adapter_bench/`).

### §3.0 Why you must invoke it through a wrapper

`lmcache bench l2` **cannot drive any NIXL-backed L2 adapter as shipped**:

```
makeXferReq: local index out of range at index 0 with value 340075
nixl_rocm._bindings.nixlInvalidParamError: NIXL_ERR_INVALID_PARAM
```

`NixlStorageAgent.init_mem_handlers()` builds the L1 transfer dlist
**base-relative** (entry `i` is `buffer_ptr + i*page_size`) while
`get_memory_indices()` returns an **absolute** page number
(`raw_addr // l1_align_bytes`). They agree only when `buffer_ptr == 0`.

This is **upstream, not ours** — the untouched vendor `nixl_store` fails on
the identical line with the identical error. `scripts/bench/l2-block-bench.py`
corrects it **in the benchmark process only**, and range-checks the result
so an out-of-bounds index raises instead of silently landing on the wrong
page. The adapter file and the running daemon are untouched. Full reasoning,
including why this is deliberately *not* fixed in the adapter, is in
TODO 6.35.

### §3.1 Sanity: is the adapter reachable from a fresh process

```bash
# [SMC2]
cd /root/kv-cache
./scripts/common/container.sh exec decode \
  "python3 -c 'from lmcache.v1.distributed.l2_adapters.config import get_registered_l2_adapter_types as g; print(sorted(g()))'"
```

**Expect** `nixl_kv` (and `nixl_store`, `nixl_store_dynamic`) in the list.

**If they are missing**, the three NIXL adapters failed to import and were
silently skipped by the lazy loader. The usual cause is a **clobbered
environment** — see §7 item 4. Do **not** export `LD_LIBRARY_PATH` or
`NIXL_PLUGIN_DIR` yourself; the container already sets them correctly.

### §3.2 Smoke test — 4 keys, with round-trip verification

Always run this before a sweep. It is ~10 seconds and it catches every
setup problem that would otherwise produce a confidently wrong table.

```bash
./scripts/common/container.sh exec decode "
cd /root/kv-cache && LMCACHE_DISABLE_BANNER=1 \
python3 scripts/bench/l2-block-bench.py bench l2 \
  --l2-adapter '{\"type\":\"nixl_kv\",\"backend\":\"XNVME_KV\",\"backend_params\":{\"dev_uri\":\"/dev/ng1n1\"},\"namespace\":\"smoke\$(date +%s)\"}' \
  --l1-align-bytes 4096 --data-size-kb 16 --num-keys 4 --in-flight 1 \
  --rounds 1 --warmup-rounds 1 --lookup-max-hit-rate 1.0 --no-skip-verify"
```

**Expect all four of these:**

```
[l2-block-bench] base-relative L1 index patch INSTALLED
  [Store]  Round 1: ~41 ms, success_keys=4/4
  [Lookup] Round 1: ~0.1 ms, found=4/4
  [Load]   Round 1: ~41 ms, loaded=4/4
  [Verify] All 4 keys data verified OK.
```

**Read the timings, not just the success count.** A store of 16 pages that
completes in **0.47 ms is a failure**, not a fast device — it means every
transfer raised and was swallowed. A real store of that size is ~41 ms.
`success_keys=0/4` with a sub-millisecond duration is the signature of
§3.0's indexing bug (i.e. the wrapper did not take effect).

`--no-skip-verify` is the single most valuable flag here: it compares the
loaded bytes against the stored bytes and is the only check that a
"successful" round trip actually moved the right data.

### §3.3 Block-size sweep — bandwidth and block accounting

One namespace per sweep point, so hit/miss semantics stay clean:

```bash
./scripts/common/container.sh exec decode bash -c '
cd /root/kv-cache; export LMCACHE_DISABLE_BANNER=1
OUT=/opt/kvstack/bench/kvblock; mkdir -p $OUT
for KB in 16 64 256; do
  export NIXL_KV_METRICS_PATH=$OUT/plugin-$KB.json NIXL_KV_METRICS_INTERVAL_SEC=1
  python3 scripts/bench/l2-block-bench.py bench l2 \
    --l2-adapter "{\"type\":\"nixl_kv\",\"backend\":\"XNVME_KV\",\"backend_params\":{\"dev_uri\":\"/dev/ng1n1\"},\"namespace\":\"sweep$KB\"}" \
    --l1-align-bytes 4096 --data-size-kb $KB --num-keys 32 --in-flight 1 \
    --rounds 3 --warmup-rounds 1 --lookup-max-hit-rate 1.0 --no-skip-verify \
    --format json --output $OUT/full-$KB.json
done'
```

`--l1-align-bytes 4096` is **mandatory** and must match production. It is
the page size the adapter tiles objects into, so it sets how many device KV
operations one key becomes: `pages = data_size / 4096`, plus **one commit
object per key**.

### §3.4 Hit rate — you must use a cold reader

A lookup in the **same process** that stored the keys is served from the
adapter's in-process index and never reaches the device (~3 µs/key). That
number is real, but it is an *index* hit rate, not a *device* hit rate.

For a true device hit rate, run lookup in a **fresh process** against a
namespace a previous run populated, with both controls:

```bash
./scripts/common/container.sh exec decode bash -c '
cd /root/kv-cache; export LMCACHE_DISABLE_BANNER=1
for RATE in 1.0 0.0; do
  echo "### requested hit rate $RATE ###"
  python3 scripts/bench/l2-block-bench.py bench l2 \
    --l2-adapter "{\"type\":\"nixl_kv\",\"backend\":\"XNVME_KV\",\"backend_params\":{\"dev_uri\":\"/dev/ng1n1\"},\"namespace\":\"sweep256\"}" \
    --l1-align-bytes 4096 --data-size-kb 256 --num-keys 32 --in-flight 1 \
    --rounds 3 --warmup-rounds 1 --only lookup --lookup-max-hit-rate $RATE
done'
```

**Expect** `found=32/32` at rate 1.0 and `found=0/32` at rate 0.0. The
second is a genuine negative control: `--lookup-max-hit-rate 0.0` draws
keys from an index range guaranteed never to have been stored. **A run
without the 0.0 control is not evidence** — a lookup that returns "hit" for
everything, including things that were never written, is a bug that looks
like success.

### §3.5 Concurrency — where the bandwidth actually is

```bash
# same as §3.3 but vary these two, on a fresh namespace each time:
#   NIXL_XNVME_NUM_QUEUES=8      (device queues)
#   --in-flight 4                (concurrent submits per round)
```

### §3.6 Capacity — size runs before you launch them

The namespace is **1 GiB with no delete primitive** (TODO 6.29). Space is
never reclaimed, and pre-fix corrupt objects from earlier sessions are
still resident. Budget before running:

```
device ops per run = (data_size_kb/4 + 1) * num_keys * (rounds + warmup_rounds)
bytes on device    = device ops * 4096
```

The §3.3 sweep costs ~11,136 pages ≈ **43.5 MiB**. A 1024 KB block size at
the same shape would cost ~32,896 pages ≈ 128 MiB. Draining is currently
**blocked** — `50-reset-namespace.sh` refuses to run because the live
`nvmf_tgt` was not started by this repo's scripts, and replacing it risks
the DSC/DPU peering (TODO 6.34's operational note).

### §3.7 Cross-check against the device — do not skip this

The adapter's numbers and the plugin's own device counters must reconcile,
or the table is fiction. The plugin writes counters to
`$NIXL_KV_METRICS_PATH` (schema 2, rewritten every
`NIXL_KV_METRICS_INTERVAL_SEC`):

```bash
./scripts/common/container.sh exec decode \
  "python3 -c \"
import json; d=json.load(open('/opt/kvstack/bench/kvblock/plugin-256.json'))
t=d['completions_ok']+d['completions_err']
print('store_ops=%d retrieve_ops=%d store_bytes=%d'%(d['store_ops'],d['retrieve_ops'],d['store_bytes']))
print('err=%d submit_fail=%d stalls=%d peak_in_flight=%d'%(d['completions_err'],d['submit_fail'],d['stalls'],d['peak_in_flight']))
print('mean device latency %.0f us/op'%(d['lat_us_sum']/max(1,t)))\""
```

**The identity that must hold:**

```
store_ops == (pages_per_key + 1) * num_keys * (rounds + warmup)
store_bytes == store_ops * 4096
retrieve_ops == store_ops          # load reads every page plus the commit object
completions_err == 0 and submit_fail == 0 and stalls == 0
```

**Results measured 2026-09-18** (32 keys/round, 3 rounds + 1 warmup,
align 4096, all ops 96/96, round-trip verified, all identities held):

| block | pages/key | device ops | store MB/s | load MB/s | store ms | load ms |
|---|---|---|---|---|---|---|
| 16 KB | 4 | 640 | 12.2 | 10.0 | 41.1 | 53.4 |
| 64 KB | 16 | 2176 | 40.0 | 36.5 | 55.3 | 57.9 |
| 256 KB | 64 | 8320 | 119.5 | 136.1 | 67.3 | 59.0 |

Per-key latency barely moves (1.29 → 2.10 ms) while bandwidth scales ~10x:
this regime is dominated by **per-key fixed overhead, not device
bandwidth**.

Concurrency, at 256 KB/key:

| queues | in-flight | store MB/s | load MB/s | peak_in_flight | submit_retry |
|---|---|---|---|---|---|
| 1 | 1 | 119.5 | 136.1 | 64 | 2.16 M |
| 8 | 1 | 115.4 | 109.8 | 512 | 7.15 M |
| 8 | 4 | **279.0** | **340.5** | 512 | 37.8 M |

Raising `NIXL_XNVME_NUM_QUEUES` alone buys **nothing** — the producer is
serialized. In-flight submits buy 2.3–2.5x. Note `submit_retry` is ~568
retries per completed op: the reactor busy-spins on `-EBUSY` backpressure,
and that, not the device, is where the time goes.

Cold-reader hit rate:

| requested | keys | hits | hit rate | µs/key |
|---|---|---|---|---|
| 1.0 | 96 | 96 | **1.00** | 69–90 |
| 0.0 | 96 | 0 | **0.00** | 70–88 |

Device probe (KV Exist) costs ~70–90 µs/key and **hit and miss cost the
same**. The warm in-process index serves the same lookup at ~3 µs/key, so
the commit-key index is worth ~25x on a repeat.

---

## §4 Benchmark B — llama-benchy (engine level) ✅

Measures what a client sees: TTFT, tokens/s, and prefix-cache benefit, over
HTTP. **Requires the full stack from §2.**

### §4.1 Install

```bash
# [SMC2], inside the container
./scripts/common/container.sh exec decode ./scripts/bench/01-install-benchy.sh
```

Verify:

```bash
./scripts/common/container.sh exec decode "/opt/kvstack/venv/bin/llama-benchy --version"
# expect: llama-benchy 0.4.0
```

Two traps this script now handles, both verified 2026-09-18 — see §7 items
2 and 3 for the detail. If you are installing by hand instead, you must
bridge the console script yourself:

```bash
ln -sfn "$(command -v llama-benchy)" /opt/kvstack/venv/bin/llama-benchy
```

### §4.2 Sanity: the preflight is the check

`benchy_preflight` runs two independent checks and both matter. It waits
for `/v1/models`, **then sends a real 1-token POST to
`/v1/chat/completions`** — because llama-benchy drives chat completions
*exclusively*. A deployment serving only `/v1/completions` passes the first
check, passes llama-benchy's own model auto-detection, and then fails every
single shape in a long sweep with the same opaque 404, burning the whole
sweep's wall clock first.

### §4.3 Baseline — cold, no cache

```bash
./scripts/common/container.sh exec decode bash -c '
cd /root/kv-cache
export BENCHY_PP=512 BENCHY_TG=32 BENCHY_DEPTH=0 BENCHY_CONCURRENCY=1 BENCHY_RUNS=2
./scripts/bench/10-bench-baseline.sh --target=decode'
```

**Note the `=`.** `--target=decode` works; `--target decode` is rejected.

**Expect** a run directory under `/opt/kvstack/bench/` containing
`result.json`, `result.md`, `run.env`, `progress.jsonl`, and pre/post
`/metrics` snapshots. A verified example (Qwen3-8B, TP=1, pp=512, tg=32,
depth 0, 2 runs):

```
e2e_ttft       mean=33.126 ms   std=0.350
est_ppt        mean=15.915 ms   std=0.350
tg_throughput  mean=197.513 tok/s
pp_throughput  mean=32186.266 tok/s
```

`--no-cache` is passed deliberately: `--depth 0` only means "no cached
prefix was staged", it does **not** disable vLLM's own automatic prefix
caching. `--no-cache` does.

### §4.4 Prefix-cache benefit — and why the number is not what it looks like

```bash
./scripts/common/container.sh exec decode \
  "cd /root/kv-cache && ./scripts/bench/20-bench-prefix-cache.sh --confirm-connector-hit"
```

> **Read this before quoting any speedup from this script.** vLLM's own
> prefix cache sits **upstream of every connector**. If it hits, no
> connector — LMCache included — is consulted at all. This script's
> depth>0 step re-sends the *same* context to the *same* decode process a
> second time, which is exactly the shape vLLM's own cache serves. A
> speedup here is therefore **not**, on its own, evidence that the KV tier
> did anything.

An honest engine-level reuse number must be **cross-instance** (decode
loading what prefill stored, never having computed that context itself) or
measured only **after genuine eviction**. This restructure is TODO 1.13 and
is **not done**. Until it is, treat this script's output as a smoke test.

`--confirm-connector-hit` must run **on the decode node, inside the
container** — it greps `${LOG_DIR}/vllm-decode.log`, and `LOG_DIR` is *not*
bind-mounted, so that file exists only inside the container (§7 item 6).

For a trustworthy corroboration, snapshot the adapter's counters around the
sweep instead of trusting the log grep:

```bash
./scripts/common/container.sh exec decode \
  "curl -s http://127.0.0.1:8080/status | python3 -c \"
import json,sys; print(json.load(sys.stdin)['storage_manager']['l2_adapters'][0])\""
```

The number is only meaningful if `l2_device_hits` **rose** while
`l2_index_hits` stayed at 0.

### §4.5 Concurrency

```bash
./scripts/common/container.sh exec decode \
  "cd /root/kv-cache && ./scripts/bench/30-bench-concurrency.sh --pp=2048 --tg=128 --depth=4096"
```

Again `=`-form arguments only. Watch for backpressure in the engine logs:

```bash
grep -E 'ENOMEM|backpressure|drain_retry_queue|no forward progress' \
  /var/log/kvstack/vllm-*.log
```

### §4.6 How to read a NEGATIVE result

If warm rows come back roughly equal to or slower than cold, **do not
conclude "the remote KV cache doesn't help."** Conclude "something is
broken" and find out which:

1. `scripts/verify/40-verify-disagg.sh` — independent hit-token counter delta.
2. `scripts/verify/50-verify-pd-direct.sh` — distinguishes a NixlConnector
   direct hit from an LMCache L2 hit from vLLM's own upstream prefix cache.
3. §3 — if the block layer is healthy there but the engine shows no
   benefit, the fault is above the adapter, not in the storage tier.

### §4.7 Sizing warning

The tracked defaults (`BENCHY_PP="512 1024 2048"`, `BENCHY_TG="128 256"`,
`BENCHY_DEPTH="0 4096 8192 16384"`, `BENCHY_CONCURRENCY="1 2 4 8"`) are
**96 shapes** × 6 iterations × 2 phases — many hours. Shrink them via the
environment for anything exploratory, and note that `run-all.sh --quick`
results are explicitly **not reportable**.

---

## §5 Benchmark C — nixlbench (transport level) ❌ NOT BUILT

### §5.1 What it would answer

Raw NIXL transfer bandwidth and latency per backend, independent of LMCache
and vLLM. It is the right tool for "is the transport itself fast", which
neither §3 nor §4 isolates — §3's numbers include the full adapter path,
and §4's include the whole engine.

### §5.2 Current status — source present, dependency missing

Measured inside `kvstack-decode`, 2026-09-18:

| Component | Status |
|---|---|
| nixlbench source | ✅ `/tmp/nixl/benchmark/nixlbench` |
| meson / ninja | ✅ 1.12.0 / 1.13.2 |
| NIXL install | ✅ `/opt/nixl` (`include/`, `lib/`) |
| ROCm | ✅ `/opt/rocm` |
| **etcd-cpp-api headers** | ❌ **MISSING** |
| **libcpprest** | ❌ **MISSING** |
| **etcd server** | ❌ **MISSING** |

nixlbench uses etcd for metadata exchange between workers, so the missing
C++ client is a hard build blocker, not a runtime nicety.

### §5.3 Build recipe (UNVERIFIED — nobody has completed this)

```bash
# inside the container. Needs network access for the dependencies.
apt-get update && apt-get install -y \
  libcpprest-dev etcd-server etcd-client nlohmann-json3-dev

# etcd-cpp-apiv3 is not packaged for Ubuntu — build from source:
git clone https://github.com/etcd-cpp-apiv3/etcd-cpp-apiv3.git /tmp/etcd-cpp
cd /tmp/etcd-cpp && mkdir build && cd build && cmake .. && make -j && make install

# then nixlbench itself — note use_rocm, this cluster is AMD not NVIDIA
cd /tmp/nixl/benchmark/nixlbench
meson setup build -Dnixl_path=/opt/nixl -Duse_rocm=true --buildtype=release
cd build && ninja
```

`-Duse_rocm=true` is **required** here; the default builds against CUDA and
this cluster has no NVIDIA GPUs.

Running it needs an etcd endpoint reachable from every participating node:

```bash
nixlbench --etcd_endpoints http://<host>:2379 --backend UCX
```

> **Do not quote a transport number from nixlbench until it has actually
> been built and run on this cluster.** This section is a recipe, not a
> result. `ib_write_bw` cross-node (~41,898 MiB/s, ~88% of 400 Gb/s line
> rate) is the only real fabric throughput figure this project has, and it
> measures the RDMA fabric, not the KV path.

---

## §6 Where every counter lives

| Layer | Surface | Carries |
|---|---|---|
| L2 adapter | `http://127.0.0.1:8080/status` → `storage_manager.l2_adapters[0]` | `l2_device_hits`, `l2_index_hits`, `l2_probe_misses`, `l2_keys_probed`, `l2_lookup_calls/executions`, `l2_commit_writes`, `l2_load_aborts`, `l2_probe_errors` |
| NIXL plugin | JSON file at `$NIXL_KV_METRICS_PATH` | `store_ops`, `retrieve_ops`, `store_bytes`, `retrieve_bytes`, `completions_ok/err`, `submit_retry/fail`, `stalls`, `peak_in_flight`, `lat_us_sum`, `lat_us_bucket[8]`, `retrieve_len_checked` |
| vLLM engine | `/metrics` on 8100 / 8200 | prefix-cache queries/hits, throughput |

Two traps about these counters specifically:

- **`l2_lookup_calls` is counted at the synchronous entry point, not inside
  the coroutine.** That is deliberate: counting it in the coroutine would
  make "LMCache never called lookup" and "our event loop never ran it"
  indistinguishable. A gap between `l2_lookup_calls` and
  `l2_lookup_executions` **is** the wedged-event-loop signal.
- **`nuse` does not track KV writes on this device.** It stayed `0x0` after
  256+ pages were written and read back successfully. Any check asserting
  "nuse grows" is asserting nothing. Use `l2_commit_writes`, or the
  plugin's `completions_ok`.

---

## §7 Problems encountered, and what to do about them

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

### 9. `/dev/ng1n1` missing after a reboot

See §1.3. Rebind via `/sys/bus/pci/drivers/nvme/bind`, expect to retry over
several minutes, and treat `block device for nsid 1 not supported (csi 1)`
as success rather than failure.

### 10. Loud startup warning: `device advertises value_max=4096 but configured max_value_size=32768`

**This warning is expected and correct on this hardware.** The device
understates its true ceiling by 8x: 32768 stores succeed and read back
cross-node; 33792 and above fail with `sct=7 sc=234`. 32768 is the exact
measured ceiling.

**Do not** silence it by lowering the configured value, and **do not** set
`NIXL_KV_STRICT_DEVICE_CEILING=1` — that would refuse to start on exactly
the configuration measured working. Changing this value changes on-wire
object geometry, which would require a namespace drain (currently blocked).

### 11. Huge `submit_retry`, low bandwidth

Measured ~568 retries per completed op. The reactor busy-spins on `-EBUSY`
once the queue is full.

**Solution / next step:** raising `NIXL_XNVME_NUM_QUEUES` alone does **not**
help (the producer is serialized). Raising concurrent submits
(`--in-flight 4`) gives 2.3–2.5x. Reducing the retry storm is an open
optimisation target, not a solved problem.

### 12. The namespace filled up / stale objects

1 GiB, **no delete primitive**, shared with another party, and it still
holds pre-fix corrupt objects. `50-reset-namespace.sh` currently **refuses
to run** because the live `nvmf_tgt` was not started by this repo's scripts;
replacing it risks the DSC/DPU peering, and DSC recovery is
non-deterministic and slow.

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

---

## §8 Teardown

```bash
# [SMC2] proxy — no dedicated stop script; stop_bg's PID-file convention applies
kill "$(cat /run/kvstack/disagg-proxy.pid)"

# [SMC1] / [SMC2]
./scripts/decode/99-stop.sh          # or prefill/99-stop.sh
./scripts/common/container.sh down decode
```

Nothing is left running deliberately at the end of a session — containers
carry no `--restart` policy. Note that `99-stop.sh` alone does **not**
reliably stop the MP daemon (§7 item 8); `container.sh down` does.

---

## See also

- [HANDOFF.md](HANDOFF.md) — what is real, what is assumed, what is still
  wrong; §3 is the resume procedure.
- [TODO.md](TODO.md) — 6.35 (block-level benchmarking + the upstream
  indexing defect), 1.13 (engine-level benchmark rework), 6.15
  (cross-instance reuse).
- [BENCHMARKING.md](BENCHMARKING.md) — llama-benchy metric semantics and
  the reproducibility rule (`run.env` or it is not a result).
- [docs/design/nixl-kv-l2-adapter.md](design/nixl-kv-l2-adapter.md) — the
  adapter's naming scheme, protocol, and counters.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — failure signatures not
  specific to benchmarking.
