# Handoff

State of the P/D-disaggregated KV cache project, for whoever picks this up next
(including future me). Written 2026-09-14.

Read this before [BRINGUP.md](BRINGUP.md). It tells you what is real, what is
assumed, and what is wrong.

---

## 1. What this project is

Three nodes, splitting vLLM inference so prefill and decode run on different
machines and share KV cache:

| Node | Host | Address | Role |
|---|---|---|---|
| SMC1 | `${PREFILL_NAME}` | `${PREFILL_HOST}` | Prefill — 8× MI300X, 2× DSC3-2Q400 |
| SMC2 | `${DECODE_NAME}` | `${DECODE_HOST}` | Decode — 8× MI300X, 2× DSC3-2Q400 |
| SMC3 | `${TARGET_NAME}` | `${TARGET_HOST}` | Storage target — no GPU, 2× POLLARA-1Q400 |

Real values for the live lab come from `creds/active.env` (untracked) —
see the README's "Credentials / lab setup" section.

Stack: vLLM + LMCache + NIXL + the two NIXL plugins vendored in `plugins/`.
Model: Qwen2.5-72B-Instruct at TP=8. Reference implementation:
[ROCm/rocm-aic](https://github.com/ROCm/rocm-aic).

**Acceptance criterion: the P→D KV transfer runs over RDMA.** TCP is the
bring-up phase, not the destination.

---

## 2. Current state

Thirteen commits on `main`, 67 files, clean tree (commit hashes below are
pre-history-purge; see the credentials note in §2 below — they will differ
after the rewrite). The target-side
configuration (§5, §6 below) now derives from a proven sibling deployment
rather than inference — every RPC argument name, transport-sizing formula
and startup flag traces to a working target with measured failure dates,
not a guess. That does not mean it has run *here*: **nothing in this repo
has run on the actual SMC1/SMC2/SMC3 hardware yet.** Treat every
performance claim as unvalidated even where the configuration itself is
now verified.

```
2a78374  fix(target): rebuild SMC3 from the proven rocm-aic configuration
e896a37  docs: fix two broken cross-doc anchors
9913206  docs: add handoff and todo, flag the architecture correction
c77daa5  docs: README, architecture, bring-up, troubleshooting, benchmarking
275381e  feat(bench): llama-benchy prefix-cache benchmark harness
efe2044  feat(verify): staged verification ladder
aab60b9  feat(serving): prefill, decode and disaggregation proxy
41f062f  feat(lmcache): NIXL backend allowlist patch and config generation
6eef1f4  feat(build): SPDK initiator, UCX, NIXL and plugin build chain
c76551e  feat(target): SPDK NVMe-KV target for SMC3
f0d2574  feat(config): cluster topology contract and shared shell library
6f33589  feat(plugins): NIXL storage backends for NVMe Key-Value devices
a0a2c7b  chore: add gitignore
```

`config/cluster.env` is the single source of truth. No script hardcodes an
address, port or size.

**This repo is public.** An earlier version of this project committed real
lab credentials and addresses directly into `config/cluster.env` and the
docs on the (since-invalidated) premise that the repo was private. That
premise no longer holds. The fix:

- `config/cluster.env` now sources per-setup identity from an untracked,
  gitignored `creds/` directory (`creds/active.env`, a symlink to the live
  `creds/setup-N.env`), falling back to safe `.invalid`-TLD placeholders
  when no creds file is present — see the README's "Credentials / lab
  setup" section and `config/cluster.env`'s own header comment.
- Every tracked file (`README.md`, `docs/*`, `scripts/*`) has been scrubbed
  of the literal addresses, users, and passwords that were previously
  committed; they now reference `${PREFILL_HOST}`-style variables or
  `creds/active.env` instead.
- **Git history was purged** of the commits that carried the real values,
  via `git filter-repo`, before this repo was made public. If you have an
  older clone or fork with the pre-purge history, discard it and re-clone —
  do not merge it back in.

---

## 3. The correction

**This is the most important section. A previous pass got the architecture
wrong, and the wrong version is still partly baked into the repo.**

### What went wrong

The `SPDK_NVMe_KV` plugin reports `supportsRemote() == false`. That is true: it
is a storage backend, not a peer-to-peer transport. From that I concluded that
*all* P→D traffic must flow through SMC3, and therefore that satisfying the RDMA
acceptance criterion meant making the **storage** leg (NVMe-oF to SMC3) speak
RDMA.

That conclusion does not follow. The premise only rules out *that plugin* as a
peer transport. It says nothing about NIXL's **UCX** backend, which does support
remote peers and does reach RDMA. Meanwhile the original spec is explicit that
SMC3 is "accessible via TCP" — TCP is definitional there, not a phase.

### The corrected model — two independent legs

| Leg | Path | Transport | NICs |
|---|---|---|---|
| **A — P→D KV transfer** | SMC1 → SMC2, direct, GPU-to-GPU via NIXL/UCX | TCP now → **RDMA = acceptance** | DSC3-2Q400 |
| **B — Shared KV storage** | SMC1/SMC2 → SMC3 over NVMe-oF | **TCP, permanently by design** | Pollara-1Q400 |

This also matches the hardware: the RDMA-capable DSC3 NICs are on the two
compute nodes, which is exactly where leg A runs.

### What that invalidates

1. **Leg A does not exist in the repo.** `grep -rn 'NixlConnector\|MultiConnector\|SIDE_CHANNEL\|kv_transfer_params'`
   over `scripts/` finds one unused variable (`NIXL_SIDE_CHANNEL_PORT`) and two
   comments. Everything currently routes P→D *through* SMC3 via
   `LMCacheConnectorV1`. **The path carrying the acceptance criterion was never
   built.** This is the single biggest gap.

2. ~~Twelve files carried storage-leg RDMA scaffolding from the bad
   premise~~ — **done.** The `nvme_rdma.o` split archive, `-Denable_rdma`,
   `SPDK_WITH_RDMA`, and the `NVMF_TRTYPE=RDMA` branch have all been
   removed (`plugins/nvme-kv/meson.build`, `meson_options.txt`,
   `prepare-spdk-libs.sh`, `scripts/target/02-build-spdk-kv.sh`,
   `scripts/common/05-build-spdk-initiator.sh`, `config/cluster.env`) as
   part of rewriting the target from a proven configuration — see §5 and
   TODO 5.11. Unvalidated opt-in code for a requirement that does not exist
   would have misled the next reader; it no longer can.

3. **`KV_TRANSPORT` conflates both legs** across 18 files. Needs splitting into
   `PD_TRANSPORT` (compute leg, the real acceptance gate) and a storage leg with
   no flip available at all.

4. **The proxy cannot trigger a direct transfer.** `scripts/proxy/disagg_proxy.py`
   replays the prompt to prefill then decode. That populates a cache, but a
   direct NIXL handoff needs `kv_transfer_params` threaded from the prefill
   response into the decode request.

5. **The end-to-end verifier cannot prove acceptance.**
   `scripts/verify/40-verify-disagg.sh` asserts a cache-hit counter rises. That
   passes identically whether the hit came from SMC3 or from a direct transfer.
   It cannot tell them apart.

6. **`verify/10-verify-network.sh` checks RDMA on the wrong NICs** — Pollara
   (storage leg) instead of DSC3 (compute leg).

One thing survived the correction intact: `setup_ucx_env` in
`scripts/common/lib.sh` deliberately omits `tcp` from `UCX_TLS` in RDMA mode, so
a half-configured fabric fails loudly instead of silently falling back. That is
now the actual acceptance switch. Keep that property.

### Open scoping question

The plugin header (`spdk_nvme_kv_backend.h`, the `queryMem()` comment) documents
storage-mediated P/D as a real, intended path that was previously broken and
fixed. So SMC3 *can* carry P→D — it just cannot do so over RDMA.

Both can be true: direct RDMA as the fast path, SMC3 as an L2 tier for
cross-request reuse and capacity spill. That is the recommended reading, but it
needs an explicit decision before more code lands. See
[TODO.md §0](TODO.md#0-blocking-decisions-need-an-answer-before-more-code-lands).

This reading is now independently reinforced, not just recommended. A
sibling project reached the same storage-mediated conclusion on its own and
went further: it confirmed LMCache's own peer-to-peer path (`enable_pd` /
`pd_role`, `lmcache/v1/storage_backend/pd_backend.py`) is **unusable** with
this plugin — `pd_backend.py`'s `transfer_channel` requires a backend with
`supportsRemote() == true`, and `spdk_nvme_kv_backend.h` declares
`supportsRemote() { return false; }`. What that sibling project uses instead
is `enable_nixl_storage` / `store_location` / `retrieve_locations`
(`nixl_storage_backend.py`) — ordinary persistent L1→L2 storage, with two
independent plugin instances against the same target and vLLM's own
`kv_role` gating enforcing the P/D asymmetry (`vllm_v1_adapter.py` lines
1050, 1141, 1661). That is disaggregation-via-shared-persistent-store, the
same shape as this repo's current (pre-correction) path — it does **not**
rule out vLLM's `NixlConnector` over the UCX backend for the RDMA compute
leg, since UCX is a different NIXL backend that does support remote peers.
It narrows the open question rather than closing it: LMCache's own p2p path
is confirmed out; `NixlConnector` remains the candidate for leg A.

---

## 4. Repository map

```
config/cluster.env          single source of truth — topology, transport, model, paths
scripts/common/             lib.sh (shared vocabulary), preflight, build chain, venv,
                            LMCache config generation + validation, shared vLLM launcher
scripts/target/             SMC3: SPDK build (upstream + patches/spdk/), nvmf_tgt +
                            bdev_kvmalloc, verify (incl. chunk-ceiling check), ns reset
scripts/prefill/            SMC1: host prep, vLLM as kv_producer
scripts/decode/             SMC2: host prep, vLLM as kv_consumer
scripts/proxy/              async disaggregation router
scripts/verify/             10 network → 20 plugin → 30 KV roundtrip → 40 end-to-end
scripts/bench/              llama-benchy harness + compare_runs.py
patches/spdk/               four upstream-bound NVMe-KV patches (Gerrit, no private fork)
patches/lmcache/            NIXL backend allowlist patch, generated at apply time
plugins/                    vendored SPDK_NVMe_KV and XNVME_KV NIXL backends
docs/                       ARCHITECTURE, BRINGUP, TROUBLESHOOTING, BENCHMARKING,
                            TODO, HANDOFF
```

---

## 5. Verified vs assumed

Be rigorous about this distinction. The repo's scripts are written to fail loudly
on the assumed items rather than guess silently — preserve that when editing.

### Verified (found in code, release notes or vendored source)

- The plugin's env vars, params and failure modes — read directly from
  `plugins/nvme-kv/*.{h,cpp}`. The `queryMem()`, `make_key()` and
  `max_value_size` comments are the authoritative source for why several design
  choices are what they are.
- SPDK **v26.05** (2026-05-29) carries NVIDIA's NVMe-KV **initiator** API
  upstream: `nvme_kv.h`, `lib/nvme/nvme_kv.c`, the full
  `spdk_nvme_kv_{store,retrieve,exist,delete,list}()` surface, opcodes and status
  codes in `nvme_spec.h`. The compute nodes need no fork — there is no fork at
  all, see below.
- **There is no private SPDK fork.** NVMe-KV support is four upstream-bound
  patches by Ben Walker `<ben@nvidia.com>` on the public SPDK Gerrit queue
  (`patches/spdk/README.md`): `0001` (recognize KV namespaces) and `0004`
  (KV unit tests) merged upstream 2026-08-25; `0002` (`bdev/kvmalloc`) and
  `0003` (nvmf KV namespace support) still open (Gerrit 27889/28298 —
  CR+2, Verified+1, mergeable, hashtag `26.09`) as of 2026-09-14. SMC3
  builds upstream SPDK at `SPDK_TARGET_REF` and applies `0002`/`0003` from
  `patches/spdk/`; SMC1/SMC2 need none of the four.
- **`bdev_kvmalloc_create`'s RPC argument names** — `name` / `max_key_size` /
  `max_value_size` — taken from a working sibling deployment
  (`rocm-aic/target.sh`), not guessed. There is no `-b/-s/--value-max-size`
  form and no `KV_BDEV_CREATE_ARGS` escape hatch; both were removed.
- **The chunk-size-vs-transfer-ceiling formula**
  (`layers * chunk_size * (kv_heads/TP) * head_size * 2(K,V) * 2(bf16)`,
  `scripts/target/05-check-chunk-ceiling.sh`), validated against two measured
  points: TinyLlama TP=1 chunk=256 → 5.5 MiB (fits); Qwen2.5-72B TP=4
  chunk=256 → 20 MiB (measured 2026-09-09, does **not** fit). This repo's
  configuration (Qwen2.5-72B TP=8 chunk=256 → 10 MiB) fits with 37%
  headroom.
- SPDK v26.05 deprecated `io_unit_size` to a no-op. The governing SGL rule on
  ≥26.05 is `max_io_size / large_bufsize ≤ 16` (note the denominator is
  iobuf's `large_bufsize`, not `io_unit_size` — an earlier version of this
  repo divided by the wrong one).
- llama-benchy's CLI surface and JSON schema; `--enable-prefix-caching` runs a
  two-step context-load-then-inference protocol; it drives
  `/v1/chat/completions` only.

### Assumed (will need reconciling on first contact with hardware)

- **LMCache YAML key names and the allowlist patch sites.** Derived against
  v0.5.4 and validated only against a mock. `apply-patches.sh` fails loudly if it
  finds zero allowlist sites, because that means the assumption has gone stale.
- **The NIXL Python API surface** used by the verify scripts — partially grounded,
  partially inferred. Failures surface as specific `AttributeError`s rather than
  silent false passes.
- **That `patches/spdk/0002`/`0003` still apply cleanly to whatever
  `SPDK_TARGET_REF` SHA ends up pinned.** They are known to apply to v26.05
  and to a pre-`0002`/`0003` master; if master drifts far enough that the
  surrounding code changes shape, that needs a manual rebase, not a blind
  retry (`scripts/target/02-build-spdk-kv.sh` says so explicitly on failure).
- **All benchmark numbers in `BENCHMARKING.md`** are order-of-magnitude
  estimates, explicitly labelled as such. Replace with measured values.

---

## 6. Invariants — do not break these

Each of these guards a failure that is **silent**, i.e. the cluster looks healthy
while doing the wrong thing. They are the reason several scripts refuse to start.

1. **`nixl_pool_size: 0`** selects LMCache's content-derived-key dynamic storage
   backend. The object-pool backend names objects `obj_{slot}_{uuid4}` — per
   process random — so prefill and decode derive different keys for identical
   content and every decode lookup misses. Symptom: `LMCache hit tokens: 0`.

2. **The `ldd` self-containment check** on `libplugin_SPDK_NVMe_KV.so`. A
   `DT_NEEDED` on `librte_eal.so` or `libspdk_*.so` makes NIXL's `dlopen()` fail
   *silently* and report only "unsupported backend", with nothing indicating a
   shared library was the cause. This is why SPDK is built `--without-shared` and
   why `meson.build` links explicit `.a` paths.

3. **`PYTORCH_HIP_ALLOC_CONF=expandable_segments:False`.** With expandable
   segments on, vLLM's KV tensors cannot be exported over HIP IPC and
   registration fails with an invalid device pointer.

4. **`NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` stays unset.** Adopting the
   device-reported ceiling changes on-wire object geometry, and nothing records
   the `sub_size` an object was written with — a reader would reassemble a
   half-stale page without error.

5. **Drain the namespace whenever `KV_MAX_VALUE_SIZE` changes** —
   `scripts/target/50-reset-namespace.sh`. Same root cause as (4).

6. **`UCX_TLS` excludes `tcp` in RDMA mode.** Acceptance must fail loudly rather
   than quietly fall back to TCP and report a passing result.

7. **`max_io_qpairs_per_ctrlr` is spelled exactly that, value 512** —
   `config/cluster.env`'s `NVMF_MAX_IO_QPAIRS_PER_CTRLR`. SPDK silently
   accepts the older `max_qpairs_per_ctrlr` spelling and keeps its default
   of 127 in force, no error anywhere. One `SPDK_NVMe_KV` plugin instance
   opens all of a controller's qpairs, so against a shared target whichever
   role connects first takes the whole budget and the second is refused —
   invisibly: the client logs `CQ transport error -6` and
   `NIXL_ERR_BACKEND`, while LMCache still logs a successful store and HTTP
   returns 200, with zero bytes reaching the device. Confirmed 2026-09-07.
   `scripts/target/04-verify-target.sh` hard-checks this field actually took.

8. **The chunk-size ceiling** — one LMCache chunk is one NIXL object, and
   must fit under `NVMF_MAX_IO_SIZE`
   (`scripts/target/05-check-chunk-ceiling.sh`). Exceeding it fails the
   STORE with `NIXL_ERR_BACKEND` and takes the whole vLLM server down rather
   than degrading. `chunk_size` is also part of the cache key, so both P/D
   roles must use the same `LMCACHE_CHUNK_SIZE` or the receiver derives a
   different key and silently re-prefills.

9. **Startup preconditions in `start-vllm.sh`** — target reachable, LMCache
   config validated. Without them vLLM serves happily from local cache only and
   disaggregation does nothing while appearing correct.

---

## 7. How to resume

1. Answer the blocking item in [TODO.md §0](TODO.md#0-blocking-decisions-need-an-answer-before-more-code-lands):
   the SMC3 scoping decision (0.1). The `KV_SPDK_REPO` fork blocker that used
   to sit alongside it never described reality and has been removed — see §3
   and §5.
2. Re-run the aborted research on `NixlConnector` / `MultiConnector` / LMCache
   nixl-p2p (TODO 1.1). Its scope depends on the scoping decision.
3. Work [TODO.md §1](TODO.md#1-architecture-correction-compute-leg) — split the
   transport switch, build leg A, fix the proxy and the verifier. The
   misplaced storage-leg RDMA scaffolding this step used to also need to
   delete is already gone (TODO 5.11).
4. Only then go to hardware ([TODO.md §2](TODO.md#2-hardware-bring-up-phase-1-tcp))
   and follow [BRINGUP.md](BRINGUP.md).

Do not skip step 3. Bringing up the current repo on hardware would produce a
system that caches through SMC3 and never does a direct transfer — and the
verify ladder as written would pass it.
