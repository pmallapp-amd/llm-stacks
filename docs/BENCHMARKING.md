# Benchmarking

This document explains *what* `scripts/bench/*` measures and *why*, not
just how to run it (the scripts themselves carry the how, in their own
header comments). Read [`../README.md`](../README.md) first for topology,
[`ARCHITECTURE.md`](ARCHITECTURE.md) for why the datapath is shaped the
way it is, and [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) if a benchmark
run comes back negative.

## 1. What we measure, and why

The question this harness exists to answer: **does the remote KV cache on
SMC3 actually deliver a prefill-latency win for the decode node, over the
real disaggregated network path — not in some idealized in-process
simulation?**

That question has three sub-parts, each with its own script:

1. **Cold denominator** (`10-bench-baseline.sh`) — how slow is a request
   with no cache help at all? Every later claim of "N% faster" is a
   comparison against this number. Get it wrong (e.g. let vLLM's own
   automatic prefix cache sneak in) and every later number is inflated.
2. **Cache benefit** (`20-bench-prefix-cache.sh`) — the headline
   measurement. Stages a context through the prefill node (which stores
   it into LMCache's NIXL namespace on SMC3), then re-requests the same
   context and measures whether the decode node's lookup actually got a
   hit that shortened its critical path.
3. **Saturation** (`30-bench-concurrency.sh`) — at what concurrency does
   the remote tier stop keeping up (SPDK initiator qpair exhaustion,
   `-ENOMEM` backpressure)?

A fourth script, `40-bench-transport-compare.sh`, re-runs #2 under both
`KV_TRANSPORT=tcp` and `KV_TRANSPORT=rdma` and diffs them — this is the
literal acceptance-criteria measurement referenced in
`config/cluster.env`'s "Transport selection — THE phase gate" section.

## 2. `ttfr` vs `est_ppt` vs `e2e_ttft` — and why `e2e_ttft` is the honest number

llama-benchy reports three latency-shaped metrics per request shape, and
they are NOT interchangeable:

| Metric      | What it actually measures                                    |
|-------------|----------------------------------------------------------------|
| `ttfr`      | Time to first **stream chunk** off the wire. This is what vLLM's own `vllm bench serve` calls "TTFT" — but a stream chunk can be an empty SSE keepalive, a role-only delta (`{"role":"assistant"}`), or a genuinely empty first token, none of which the user perceives as "the model started answering." |
| `est_ppt`   | `ttfr` minus a measured per-token generation latency probe (`--latency-mode generation` sends 4 single-token requests, discards the first, averages the rest). This subtraction is what isolates the **true prefill time** — the thing a remote KV cache can actually shorten — from the noise `ttfr` inherits from decode's own token-generation latency and inter-token jitter. |
| `e2e_ttft`  | Wall-clock time to the first chunk that contains actual **content** — i.e., what a human staring at the screen experiences as "it started typing." |

**Why `e2e_ttft` is the number that matters for reporting a user-facing
win, and why a harness that reports `ttfr`-as-"TTFT" would flatter this
deployment specifically:** this cluster's own proxy
(`scripts/proxy/disagg_proxy.py`) streams the priming request's response
`.write()`-by-`.write()` and the real decode response the same way — but
the priming step and any role-only preamble chunk both arrive on the wire
*before* the first content token. A metric that stops the clock at the
first byte off the socket (`ttfr`) would credit this architecture with a
faster "TTFT" than the user actually experiences, precisely because of
plumbing (SSE framing, role deltas) that has nothing to do with whether
the remote cache helped. `est_ppt` is the right metric for isolating *why*
a request was fast (cache hit vs. cache miss); `e2e_ttft` is the right
metric for reporting *whether the user noticed*. Report both — never
substitute one for the other, and never call `ttfr` "TTFT" in a result
without the same caveat.

## 3. Why llama-benchy, not `vllm bench serve` or `benchmark_prefix_caching.py`

This is a constraint, not a preference:

- **`benchmark_prefix_caching.py`** (vLLM's own repo) drives an in-process
  `vllm.LLM(...)` instance. It has no HTTP client mode at all — it cannot
  talk to a remote endpoint, disaggregated or otherwise. It cannot see
  this cluster's proxy, prefill node, or decode node; it can only ever
  benchmark a single co-located model instance. That rules it out
  entirely for a deployment whose entire point is that prefill and decode
  are separate machines talking over a network.
- **`vllm bench serve`** does talk to a remote HTTP endpoint, but it has no
  prefix-reuse measurement mode: there is no flag that says "load this
  context once, then re-request it and tell me if the second request was
  faster." It is a pure load-generation tool (fixed request rate, fixed
  prompt distribution) with no built-in cold/warm comparison at all — you
  would have to hand-roll the two-step context-load-then-inference
  protocol llama-benchy already implements.
- **llama-benchy** is the only tool of the three that is BOTH an
  HTTP-endpoint client (so it can reach the real proxy/prefill/decode
  over the real network) AND has a native prefix-reuse protocol
  (`--enable-prefix-caching` + `--depth`) that stages a context and
  re-requests it, reporting cold vs. warm rows in one run.

## 4. The chat-completions-only constraint

llama-benchy drives `/v1/chat/completions` exclusively — it has no
`/v1/completions` code path at all. This is why
`scripts/bench/lib-bench.sh`'s `benchy_preflight` sends an actual 1-token
POST to `/v1/chat/completions` before any sweep starts: a deployment that
only serves the legacy completions route would otherwise fail every shape
in a long sweep identically, and only after burning that sweep's full wall
clock.

For the proxy (`scripts/proxy/disagg_proxy.py`) specifically: it forwards
both `/v1/completions` and `/v1/chat/completions` transparently (see
`COMPLETION_PATHS` in that file) and its priming logic sets both
`max_tokens` and `max_completion_tokens` on the primed request precisely
because it doesn't know in advance which schema a given client is using —
so the proxy itself imposes no additional constraint here beyond "whatever
vLLM already supports for chat completions" (which, for
Qwen2.5-72B-Instruct, is the full chat template).

## 5. The benchmarks, and how to read their output

All commands below assume `source config/cluster.env` has already run (or
equivalently that the `BENCHY_*`/`MODEL`/etc. env vars are already
exported — every script in `scripts/bench/` sources `config/cluster.env`
itself via `scripts/common/lib.sh`, so this is for a human running the
underlying `llama-benchy` invocation by hand, not a requirement for the
scripts).

### Install

```bash
scripts/bench/01-install-benchy.sh
```
Installs `llama-benchy==${BENCHY_VERSION}` into `${VENV}` and
pre-downloads the `${MODEL}` tokenizer (see that script's own comment for
why this must happen before any timed run, not during one). Prints the
resolved installed version.

### Baseline (cold denominator)

```bash
scripts/bench/10-bench-baseline.sh [--target prefill|decode|proxy]
```
Runs `--no-cache --depth 0` against the chosen endpoint (default: proxy).
Read `result.md`'s `pp{n}`/`tg{n}` rows as the cold numbers every later
comparison is measured against.

### Prefix-cache benefit (the headline number)

```bash
scripts/bench/20-bench-prefix-cache.sh
python3 scripts/bench/compare_runs.py --prefix-benefit --format md \
    "${BENCHY_RESULT_DIR}"/<timestamp>-prefix-cache/result.json
```
Read the `ctx_pp @ d{N}` rows as "the prefill node populating SMC3"; read
the `pp{n} @ d{N}` rows as "the decode node retrieving it." The
`--prefix-benefit` speedup column (`cold_est_ppt / warm_est_ppt`) is the
single number answering the task's central question. A speedup
meaningfully above 1.0x, marked significant (`*`), is a positive result.

### Concurrency saturation

```bash
scripts/bench/30-bench-concurrency.sh [--pp=N] [--tg=N] [--depth=N]
```
Fixed shape (defaults to the heaviest shape in `BENCHY_PP`/`BENCHY_TG`/
`BENCHY_DEPTH`), swept across `BENCHY_CONCURRENCY`. Read `est_ppt`/
`e2e_ttft` across the concurrency axis: flat-then-climbing is the
saturation knee. Cross-reference against
`grep -E 'ENOMEM|backpressure|drain_retry_queue' ${LOG_DIR}/vllm-{prefill,decode}.log`
for the same time window — the knee and the first backpressure log line
should coincide.

### Transport comparison (TCP vs RDMA — the acceptance measurement)

```bash
scripts/bench/40-bench-transport-compare.sh   # records a run under the CURRENT KV_TRANSPORT
# ... flip KV_TRANSPORT in config/cluster.env, restart target -> prefill -> decode ...
scripts/bench/40-bench-transport-compare.sh   # finds the prior run, diffs automatically
```
Read the `compare_runs.py` output's `ttfr`/`est_ppt`/`e2e_ttft` tables:
RDMA should show a lower mean, marked significant, at every shape — an
unmarked or reversed row is worth a second look before calling RDMA a win.

### Everything at once

```bash
scripts/bench/run-all.sh [--quick]
```
Runs install (if needed) -> baseline -> prefix-cache -> concurrency ->
prefix-benefit summary, and prints a final PASS/FAIL table. `--quick`
shrinks every sweep to a single shape with `--runs 2`, for confirming the
harness itself runs end to end — **`--quick` output is a smoke test, never
a reportable number** (2 samples barely constrain a standard deviation at
all, and one shape says nothing about how the benefit or saturation point
varies across the shapes that matter for this deployment).

## 6. How to interpret a NEGATIVE result

If `20-bench-prefix-cache.sh`'s warm rows (`pp{n} @ d{N}`) come back
roughly equal to (or slower than) the cold baseline — i.e.
`compare_runs.py --prefix-benefit` reports a speedup near 1.0x, or below
1.0x, or not marked significant — **the decode node is not actually
getting cache hits**, regardless of what the proxy or vLLM's own logs
claim about the request succeeding. Do NOT conclude "the remote KV cache
doesn't help" from this alone; conclude "something is broken" and go
find out which of the two known causes it is:

1. Run `scripts/verify/40-verify-disagg.sh` — it independently checks the
   same hit-token counter delta this harness cannot see (llama-benchy has
   no visibility into LMCache's own metrics), across a single controlled
   request pair rather than a full sweep. A clean pass there with a
   negative benchmark result here would itself be a useful, specific data
   point (worth filing as its own investigation).
2. Read `docs/TROUBLESHOOTING.md`'s **"LMCache hit tokens: 0" on every
   decode request** entry — it enumerates the two concrete causes this
   repo has hit before (wrong LMCache storage-backend mode; the plugin's
   `queryMem()` existence-probe missing or reverted) and how to
   distinguish them.

A benchmark harness cannot fix a broken cache; it can only tell you,
precisely, that one exists to fix.

## 7. Order-of-magnitude expectations — ESTIMATES, replace with measured values

**These numbers are placeholders based on general knowledge of MI300X
throughput and Qwen2.5-72B's parameter count — NOT measured on this
cluster. Nobody has run this harness against the real deployment yet.
Replace this entire section's numbers with §8's results log the first time
a full (non-`--quick`) run completes, and delete this caveat once real
numbers exist.**

| Shape (pp / tg / depth)      | Cold `est_ppt` (ESTIMATE) | Warm `est_ppt` (ESTIMATE) | Expected direction |
|-------------------------------|---------------------------|----------------------------|---------------------|
| pp=2048, tg=128, depth=0       | ~400-900 ms                | n/a (cold row)              | denominator |
| pp=2048, tg=128, depth=8192    | n/a                        | ~150-400 ms (if hit)        | 2-4x faster than cold |
| pp=2048, tg=128, depth=16384   | n/a                        | ~150-450 ms (if hit)        | depth should matter less than hit/miss |

These ranges assume TP=8 on MI300X easily holds Qwen2.5-72B's forward pass
well under a second for a 2K-token prefill, and that a genuine cache hit
collapses most of that to network + KV-retrieval overhead rather than
recomputation. If measured `est_ppt` for the warm case comes back within
noise of the cold case, treat that as a NEGATIVE result per §6, not as
"the estimate was just optimistic."

## 8. Results log (append here after every reportable run)

| Date | Repo commit | Transport | Model | Shape (pp/tg/depth) | Concurrency | Cold `est_ppt` | Warm `est_ppt` | Speedup | Notes |
|------|-------------|-----------|-------|----------------------|-------------|-----------------|------------------|---------|-------|
|      |             |           |       |                       |             |                  |                  |         |       |

(No rows yet — this table is seeded empty; every real run should add one.
Pull every column except "Notes" straight out of the run's own `run.env` +
`result.json`/`compare_runs.py --prefix-benefit` output — never hand-type
a number here without its source run directory in "Notes".)

## 9. Reproducibility

Every `scripts/bench/*` invocation that actually runs `llama-benchy`
writes a `run.env` file into its own timestamped result directory
(`${BENCHY_RESULT_DIR}/<timestamp>-<label>/run.env`), generated by
`scripts/bench/lib-bench.sh`'s `_bench_write_run_env`. It captures: the
model, `TP_SIZE`, `KV_TRANSPORT`, `KV_MAX_VALUE_SIZE`,
`LMCACHE_CHUNK_SIZE`, `KV_NUM_QPAIRS`, this repo's own git commit, and the
installed vLLM/LMCache/llama-benchy/SPDK versions.

**The rule this repo follows: a benchmark number without its `run.env` is
not a result.** "Prefill was 3x faster warm" is unfalsifiable six months
from now if nobody recorded whether that run was TCP or RDMA, what
`KV_MAX_VALUE_SIZE` was set to (it changes on-wire object geometry — see
`config/cluster.env`'s own comment on that variable), or which git commit
of `scripts/proxy/disagg_proxy.py`'s sequential priming logic was actually
running. Never quote a number from this harness without pointing at the
run directory that produced it.
