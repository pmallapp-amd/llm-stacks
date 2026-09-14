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
| SMC1 | `smc1` | REDACTED-ADDR | Prefill — 8× MI300X, 2× DSC3-2Q400 |
| SMC2 | `smc2` | REDACTED-ADDR | Decode — 8× MI300X, 2× DSC3-2Q400 |
| SMC3 | `target` | REDACTED-ADDR | Storage target — no GPU, 2× POLLARA-1Q400 |

Stack: vLLM + LMCache + NIXL + the two NIXL plugins vendored in `plugins/`.
Model: Qwen2.5-72B-Instruct at TP=8. Reference implementation:
[ROCm/rocm-aic](https://github.com/ROCm/rocm-aic).

**Acceptance criterion: the P→D KV transfer runs over RDMA.** TCP is the
bring-up phase, not the destination.

---

## 2. Current state

Ten commits on `main`, 59 files, clean tree. Everything is written and
lint-clean; **nothing has run on hardware.** Treat every performance claim and
every RPC argument name as unvalidated.

```
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
address, port or size. Credentials are committed deliberately — private repo.

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

2. **Twelve files carry storage-leg RDMA scaffolding** from the bad premise —
   the `nvme_rdma.o` split archive, `-Denable_rdma`, `SPDK_WITH_RDMA`,
   `NVMF_TRTYPE=RDMA`. To be deleted, not kept. Unvalidated opt-in code for a
   requirement that does not exist will mislead the next reader.

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

---

## 4. Repository map

```
config/cluster.env          single source of truth — topology, transport, model, paths
scripts/common/             lib.sh (shared vocabulary), preflight, build chain, venv,
                            LMCache config generation + validation, shared vLLM launcher
scripts/target/             SMC3: SPDK build, spdk_tgt + bdev_kvmalloc, verify, ns reset
scripts/prefill/            SMC1: host prep, vLLM as kv_producer
scripts/decode/             SMC2: host prep, vLLM as kv_consumer
scripts/proxy/              async disaggregation router
scripts/verify/             10 network → 20 plugin → 30 KV roundtrip → 40 end-to-end
scripts/bench/              llama-benchy harness + compare_runs.py
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
  codes in `nvme_spec.h`. The compute nodes need no fork.
- SPDK v26.05 did **not** upstream the target side — no `bdev_kvmalloc`, no KV
  opcode routing in `lib/nvmf/ctrlr_bdev.c`. SMC3 still needs the fork.
- SPDK v26.05 deprecated `io_unit_size` to a no-op. The
  `max_io_size / io_unit_size ≤ 16` SGL rule that originally justified
  `KV_MAX_VALUE_SIZE=524288` is no longer the governing constraint on ≥26.05.
- llama-benchy's CLI surface and JSON schema; `--enable-prefix-caching` runs a
  two-step context-load-then-inference protocol; it drives
  `/v1/chat/completions` only.

### Assumed (will need reconciling on first contact with hardware)

- **`bdev_kvmalloc_create` RPC argument names.** The fork is not vendored here.
  Scripts try one form, then print `--help` and die; override with
  `KV_BDEV_CREATE_ARGS`.
- **LMCache YAML key names and the allowlist patch sites.** Derived against
  v0.5.4 and validated only against a mock. `apply-patches.sh` fails loudly if it
  finds zero allowlist sites, because that means the assumption has gone stale.
- **The NIXL Python API surface** used by the verify scripts — partially grounded,
  partially inferred. Failures surface as specific `AttributeError`s rather than
  silent false passes.
- **`nvme_rdma.o` as the RDMA object name** inside `libspdk_nvme.a`. Moot if the
  storage-leg RDMA scaffolding is removed as planned.
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

7. **Startup preconditions in `start-vllm.sh`** — target reachable, LMCache
   config validated. Without them vLLM serves happily from local cache only and
   disaggregation does nothing while appearing correct.

---

## 7. How to resume

1. Answer the two blocking items in [TODO.md §0](TODO.md#0-blocking-decisions-need-an-answer-before-more-code-lands):
   the SMC3 scoping decision, and the `KV_SPDK_REPO` fork URL.
2. Re-run the aborted research on `NixlConnector` / `MultiConnector` / LMCache
   nixl-p2p. Its scope depends on the scoping decision.
3. Work [TODO.md §1](TODO.md#1-architecture-correction-in-flight) — split the
   transport switch, delete the misplaced RDMA scaffolding, build leg A, fix the
   proxy and the verifier.
4. Only then go to hardware ([TODO.md §2](TODO.md#2-hardware-bring-up-phase-1-tcp))
   and follow [BRINGUP.md](BRINGUP.md).

Do not skip step 3. Bringing up the current repo on hardware would produce a
system that caches through SMC3 and never does a direct transfer — and the
verify ladder as written would pass it.
