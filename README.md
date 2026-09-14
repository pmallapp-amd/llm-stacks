# kv-cache — P/D-disaggregated vLLM KV cache cluster

This repo builds and operates a prefill/decode (P/D) disaggregated vLLM
serving cluster whose KV cache is shared between the two roles through a
remote NVMe Key-Value (NVMe-KV) storage target built on
[SPDK](https://spdk.io) v26.05, using
[vLLM](https://github.com/vllm-project/vllm) +
[LMCache](https://github.com/LMCache/LMCache) +
[NIXL](https://github.com/ai-dynamo/nixl) and two purpose-built NIXL plugins
(`plugins/nvme-kv`, `plugins/xnvme-kv`). It is a from-scratch, script-driven
bring-up of the pattern described by
[ROCm/rocm-aic](https://github.com/ROCm/rocm-aic), targeting three specific
physical hosts (below), not a generic deployment tool.

Prefill (SMC1) and decode (SMC2) run vLLM+LMCache on 8x MI300X each and never
talk to each other's GPU memory directly for the KV cache: prefill **stores**
its computed KV blocks to a shared NVMe-KV namespace on a third, GPU-less
storage node (SMC3); decode **probes for existence** and **retrieves** from
the same namespace. This is storage-mediated P/D handoff, not peer-to-peer
GPU-to-GPU transfer — see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for
why.

## Status

> **Two independent legs — read [`docs/HANDOFF.md`](docs/HANDOFF.md) first.**
>
> The **P→D transfer** (prefill → decode, direct GPU-to-GPU over the DSC3 NICs)
> is the leg the RDMA acceptance criterion applies to. It runs TCP today.
>
> The **storage tier** (compute nodes → target over NVMe-oF) is **TCP by design,
> permanently** — not a phase to be upgraded. An earlier pass conflated the two
> and built RDMA groundwork on the storage leg; that has been removed.
>
> Both legs and the reasoning: [`docs/HANDOFF.md` §1](docs/HANDOFF.md#1-what-this-project-is).
> Task list: [`docs/TODO.md`](docs/TODO.md).

| Phase | Transport | State |
|---|---|---|
| **Phase 1 — bring-up** | NVMe-oF/TCP (storage leg) + UCX/TCP (compute leg) | Implemented in this repo (`KV_TRANSPORT=tcp`, the default in `config/cluster.env`). **Not yet run on the physical hardware** — every script has been written and reasoned through against the actual plugin/SPDK/LMCache source, but no end-to-end run on SMC1/SMC2/SMC3 has been recorded in this repo. |
| **Phase 2 — acceptance** | UCX/RoCE (compute leg only — the storage leg is TCP by design, permanently; see [`docs/HANDOFF.md` §3](docs/HANDOFF.md#1-what-this-project-is)) | **Implemented, unvalidated on hardware.** The direct compute-leg transfer is in place as `MultiConnector[NixlConnector, LMCacheMPConnector]`; flipping it to RDMA is [`docs/TODO.md` §3](docs/TODO.md#3-acceptance-phase-2-rdma-on-the-compute-leg). A previous pass added *storage-leg* RDMA groundwork under the wrong premise (an `-Denable_rdma` meson option, an `nvme_rdma.o` split archive); both have been removed entirely — the proven target configuration this repo now follows never exercises NVMe-oF/RDMA. |

`KV_TRANSPORT=tcp|rdma` in `config/cluster.env` is the single switch that
gates both legs of the datapath between these two phases (see that file's
comment block).

## Topology

| Host / Card | Address | Credentials |
|---|---|---|
| **SMC1** (prefill role), 8x MI300X `[1dd8:5303]` | `${PREFILL_HOST}` | `creds/active.env` |
| &nbsp;&nbsp;└ BMC | `${PREFILL_BMC}` | `creds/active.env` |
| &nbsp;&nbsp;└ Serial console (2x DSC3-2Q400 `[1dd8:5200]` host) | `${PREFILL_CONSOLE}` / `${PREFILL_CONSOLE_ALT}` | `creds/active.env` |
| **SMC2** (decode role), 8x MI300X `[1dd8:5303]` | `${DECODE_HOST}` | `creds/active.env` |
| &nbsp;&nbsp;└ BMC | `${DECODE_BMC}` | `creds/active.env` |
| &nbsp;&nbsp;└ Serial console (2x DSC3-2Q400 `[1dd8:5200]` host) | `${DECODE_CONSOLE}` / `${DECODE_CONSOLE_ALT}` | `creds/active.env` |
| **SMC3** (storage target role), no GPU | `${TARGET_HOST}` | `creds/active.env` |
| &nbsp;&nbsp;└ BMC | `${TARGET_BMC}` | `creds/active.env` |
| &nbsp;&nbsp;└ Serial console (2x POLLARA-1Q400 `[1dd8:1002]` @ 64:00.0, 84:00.0) | `${TARGET_CONSOLE}` / `${TARGET_CONSOLE_ALT}` | `creds/active.env` — **connection REFUSED when last tried — unresolved, see gap #5 below** |

Compute nodes (SMC1, SMC2) each carry 2x DSC3-2Q400 `[1dd8:5200]` data-plane
NICs. The storage node (SMC3) carries 2x POLLARA-1Q400 `[1dd8:1002]`. Both
families are 400G-class NICs. This repo's `config/cluster.env` is the
machine-readable form of this table's shape; the actual values for the live
lab are not in this table, or in this repo at all.

This repo is public. Per-setup identity (addresses, users, passwords, BMC
and console endpoints) lives entirely in the untracked, gitignored `creds/`
directory, never in a tracked file. `creds/active.env` is a symlink to
whichever `creds/setup-N.env` is the current lab. To point this repo at a
new lab, create `creds/setup-N.env` (shape below, real values only) and
repoint the symlink:

```bash
ln -sfn setup-N.env creds/active.env
```

```bash
# creds/setup-N.env — shape only; never commit real values
PREFILL_HOST=10.0.0.1
PREFILL_NAME=prefill-host
PREFILL_USER=root
PREFILL_PASS=<password>
PREFILL_BMC=10.0.0.2
PREFILL_BMC_USER=admin
PREFILL_BMC_PASS=<password>
PREFILL_CONSOLE="telnet 10.0.0.3 2024"
PREFILL_CONSOLE_ALT="telnet 10.0.0.3 2025"
# DECODE_* / TARGET_* mirror the PREFILL_* shape above
SSH_USER=root
```

See "Credentials / lab setup" under Configuration below for the full
mechanism, including the `CREDS_FILE` override and how a missing creds file
fails.

## Architecture

```
                          client (OpenAI-compatible request)
                                     │
                                     ▼
                     ┌───────────────────────────────┐
                     │  scripts/proxy/disagg_proxy.py │   (conventionally on SMC2;
                     │  primes prefill, then streams   │    host-agnostic — see its
                     │  from decode)                   │    own docstring)
                     └───────────────┬────────────────┘
                     max_tokens=1 primer │ real request (unmodified)
                          ▼                          ▼
        ┌───────────────────────────┐   ┌───────────────────────────┐
        │ SMC1 — prefill            │   │ SMC2 — decode             │
        │ vLLM + LMCache            │   │ vLLM + LMCache            │
        │ kv_role=kv_producer       │   │ kv_role=kv_consumer       │
        │ runs prompt forward pass  │   │ token-by-token generation │
        └─────────────┬─────────────┘   └─────────────┬─────────────┘
                      STORE                     queryMem() probe, RETRIEVE
                       │                                │
                       └────────────┬───────────────────┘
                                    ▼
                     NVMe-oF/TCP  (permanently, by design — see Status above;
                                   this leg never speaks RDMA at any phase)
                                     │
                     ┌──────────────▼───────────────┐
                     │ SMC3 — storage target          │
                     │ nvmf_tgt (upstream SPDK +       │
                     │ patches/spdk/0002+0003) +        │
                     │ NVMe-KV namespace (bdev_kvmalloc,│
                     │ RAM-backed)                     │
                     └────────────────────────────────┘

        SMC1  ═══════════════ direct NIXL/UCX side channel ═══════════════  SMC2
              (KVConnector handshake + rendezvous; UCX_TLS="tcp,self,sm" in
               Phase 1, "rc_verbs,rc_mlx5,dc,ud,self,sm" in Phase 2 — see
               scripts/common/lib.sh's setup_ucx_env)
```

Two independent legs, two independent transports:

- **Storage leg** (SMC1/SMC2 → SMC3): the `SPDK_NVMe_KV` NIXL plugin
  (`plugins/nvme-kv/`) is what actually moves KV bytes to/from the namespace.
  Both compute nodes are NVMe-oF **initiators**; SMC3 is the sole **target**.
  As of SPDK v26.05 these two roles build against genuinely different SPDK
  trees — the initiator API landed upstream, the target's `bdev_kvmalloc` +
  NVMe-KV opcode routing did not — see
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#7-spdk-upstream-initiator-forked-target)
  for why the boundary falls exactly there.
  `plugins/nvme-kv/spdk_nvme_kv_backend.h` declares
  `supportsRemote() == false` — this plugin is a storage backend, not a
  peer-to-peer transfer backend, which is why the handoff goes through SMC3
  rather than directly between SMC1 and SMC2. See
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full lifecycle.
- **Compute leg** (SMC1 ↔ SMC2 direct): vLLM's `LMCacheConnectorV1` uses a
  direct NIXL/UCX side channel for its own producer/consumer handshake and
  rendezvous, independent of the KV bytes themselves. This is what
  `NIXL_SIDE_CHANNEL_PORT` and `setup_ucx_env` in `scripts/common/lib.sh`
  govern.

`KV_TRANSPORT` in `config/cluster.env` flips both legs together: `tcp` picks
NVMe-oF/TCP for the storage leg and `UCX_TLS="tcp,self,sm"` for the compute
leg; `rdma` picks NVMe-oF/RDMA and `UCX_TLS="rc_verbs,rc_mlx5,dc,ud,self,sm"`
(TCP deliberately excluded from the RDMA list — see that function's comment).
The two legs' RDMA readiness is **not** the same — see Status above and
[`docs/BRINGUP.md` §9](docs/BRINGUP.md#9-phase-2-tcp-rdma).

## SPDK and the NVMe-KV patches

This project builds **upstream** SPDK — there is no private fork — and
layers four small, upstream-bound patches on top for the target side.
SMC1/SMC2 (the initiators) need none of them: the NVMe-KV *initiator* API
(`spdk_nvme_kv_store/retrieve/exist/delete/list()`) has been upstream since
SPDK v26.05. SMC3 (the target) needs `bdev_kvmalloc` and the nvmf KV opcode
routing, which have not both landed upstream yet, so
`scripts/target/02-build-spdk-kv.sh` clones upstream SPDK at
`SPDK_TARGET_REF` and applies whichever of the four patches below aren't
already present in that tree (detected by content, not by ref name).

All four patches are authored by Ben Walker `<ben@nvidia.com>` and tracked
on the public SPDK Gerrit review queue
(<https://review.spdk.io/q/topic:kv>):

| # | Subject | Status |
|---|---|---|
| `0001` | nvme: recognize KV command set namespaces | **MERGED** 2026-08-25 (`8dc8327`) |
| `0002` | bdev/kvmalloc: malloc-like bdev supporting the KV command set | **OPEN** — Gerrit [27889](https://review.spdk.io/c/spdk/spdk/+/27889), CR+2, Verified+1, hashtag `26.09` |
| `0003` | nvmf: add KV namespace support | **OPEN** — Gerrit [28298](https://review.spdk.io/c/spdk/spdk/+/28298), CR+2 (two reviewers), Verified+1, hashtag `26.09`; depends on `0002` |
| `0004` | nvme: unit test suite for the KV command set | **MERGED** 2026-08-25 (`b12a372`) |

**v26.05** (the initiator's default `SPDK_VERSION`) has the initiator API
but predates all four patches. **Current master** (`26.09.0-pre`, the
target's default `SPDK_TARGET_REF`) already carries `0001`/`0004`; only
`0002` and `0003` — the target-side pieces — still need to be applied, and
both are review-complete (`CR+2`, mergeable) as of this writing. Re-check
<https://review.spdk.io/q/topic:kv+status:open> periodically — see
[TODO.md §4.4](docs/TODO.md#4-open-items-and-known-limitations). Full per-patch
detail, Change-Ids and the apply order:
[`patches/spdk/README.md`](patches/spdk/README.md) — this section
summarises it, it does not duplicate it.

## Repository layout

```
config/
  cluster.env               Single source of truth for every tunable — see Configuration below.
  creds.env.template         Tracked template of every variable a creds file can set — placeholder
                             values only. See "Credentials / lab setup" above.

creds/                      (untracked, gitignored — /creds/ in .gitignore — created by init-creds.sh)
  active.env                 Symlink to whichever setup-N.env is the live lab.
  setup-N.env                 Real per-lab credentials, mode 0600; one file per lab. Never committed.

scripts/
  common/
    lib.sh                   Shared bash helpers: logging, retry/wait_for_*, start_bg/stop_bg,
                             setup_ucx_env / setup_nixl_kv_env, the check/checks_summary harness.
    init-creds.sh             Scaffold creds/setup-N.env from config/creds.env.template and activate
                             it. Run this before 00-preflight.sh on a fresh checkout.
    00-preflight.sh          Read-only inventory + go/no-go, any node.
    05-build-spdk-initiator.sh
                             Build the INITIATOR-side SPDK tree (SMC1/SMC2) — upstream v26.05 by
                             default (SPDK_INITIATOR_FLAVOR=upstream); must run before 10-.
    10-build-stack.sh        Build UCX + NIXL + both NIXL plugins (SMC1/SMC2); requires 05- first.
    20-build-vllm-lmcache.sh Venv with pinned vLLM + LMCache + NIXL python bindings (SMC1/SMC2).
    25-validate-lmcache-config.sh
                             Introspects the INSTALLED LMCache to prove a generated YAML is
                             actually accepted (not just well-formed).
    gen-lmcache-config.sh    Emits the LMCache YAML for one role (prefill|decode).
    start-vllm.sh            Shared body that launches vLLM+LMCache for a role; exec'd by
                             scripts/prefill/03-start-prefill.sh and scripts/decode/03-start-decode.sh.
    tune-tcp.sh              Shared sysctl tuning for large-payload TCP flows (all three nodes).
  prefill/
    01-host-prep.sh          SMC1 GPU-node prep (hugepages, ROCm check, memlock, kernel modules).
    03-start-prefill.sh       Thin wrapper: exec's start-vllm.sh prefill.
    99-stop.sh                Stop vllm-prefill (optional --clean-shm).
  decode/                    Mirrors prefill/ for SMC2 (DECODE_* vars, kv_consumer role).
  target/
    01-host-prep.sh          SMC3 storage-node prep (hugepages opt-in, kernel modules, firewall,
                             memlock).
    02-build-spdk-kv.sh       Clone upstream SPDK at SPDK_TARGET_REF and apply patches/spdk/'s
                             0002/0003 (skipping any of the four already present by content) —
                             see "SPDK and the NVMe-KV patches" above.
    03-start-kv-target.sh     Generate the --json config (lib-kv-rpc.sh) and start nvmf_tgt —
                             the whole configuration is applied atomically at startup, not via
                             a separate rpc.py sequence.
    04-verify-target.sh       Verify the target is up and correctly configured; HARD-checks
                             max_io_qpairs_per_ctrlr and the chunk-size ceiling (05- below).
    05-check-chunk-ceiling.sh Correctness guard: does one LMCache chunk fit in one NVMe-oF
                             transfer for the current MODEL/TP_SIZE/LMCACHE_CHUNK_SIZE? See
                             Configuration below.
    50-reset-namespace.sh     Drain and recreate the namespace (required after changing
                             KV_MAX_VALUE_SIZE — see Configuration below) by restarting nvmf_tgt.
    99-stop.sh                Stop kv-target (optional --release-hugepages, --clean-config).
    lib-kv-rpc.sh             kv_target_gen_json_config() (the --json generator 03- uses) plus
                             read-only rpc.py inspection helpers used only by 04-.
  proxy/
    disagg_proxy.py           Minimal async P/D router: primes prefill (max_tokens=1), then
                             streams the real request from decode. See its own docstring.
    start-proxy.sh             Launch disagg_proxy.py under start_bg.
  verify/
    10-verify-network.sh      Reachability, MTU, throughput, RDMA fabric (hard in rdma mode).
    20-verify-nixl-plugin.sh  Plugin loads + ldd self-containment + backend construction —
                             no vLLM/LMCache in the picture.
    30-verify-kv-roundtrip.sh Cross-PROCESS STORE/RETRIEVE proof (the property P/D needs).
    40-verify-disagg.sh       End-to-end proof through the real proxy/vLLM/LMCache stack.
    run-all.sh                Runs the applicable verify/ scripts in order for this node's role.
    _kv_roundtrip.py          Engine invoked by 30-verify-kv-roundtrip.sh.
  bench/
    01-install-benchy.sh      Install llama-benchy into the shared vLLM venv.
    lib-bench.sh              Shared preflight/run.env-writing helpers for the scripts below.
    10-bench-baseline.sh      Cold denominator (--no-cache --depth 0).
    20-bench-prefix-cache.sh  The headline measurement: does the decode node get a cache hit?
    30-bench-concurrency.sh   Sweep concurrency to find the SPDK-qpair/-ENOMEM saturation knee.
    40-bench-transport-compare.sh
                             Re-runs 20- under KV_TRANSPORT=tcp and =rdma and diffs them.
    compare_runs.py           Diffs two result.json files; --prefix-benefit for the headline number.
    run-all.sh                install -> baseline -> prefix-cache -> concurrency -> summary.
    See docs/BENCHMARKING.md for what each measures and why.

patches/spdk/
  README.md                  Per-patch Gerrit status, Change-Ids, and apply order for the four
                             upstream-bound NVMe-KV patches — see "SPDK and the NVMe-KV patches"
                             above for the summary.
  0001-spdk-nvme-recognize-kv-namespaces.patch / 0002-spdk-bdev-kvmalloc.patch /
  0003-spdk-nvmf-kv-namespace.patch / 0004-spdk-nvme-kv-unit-tests.patch
                             Applied by scripts/target/02-build-spdk-kv.sh; 0001/0004 are
                             skipped automatically on trees where they're already merged.

patches/lmcache/
  README.md                  Why/what/how of the LMCache NIXL-backend-allowlist patch, with an
                             explicit VERIFIED-vs-ASSUMED accounting.
  apply-patches.sh            Applies the patch to the INSTALLED LMCache (not a static .patch file).
  _patch_engine.py            tokenize/ast-based source transformation the above invokes.

plugins/
  nvme-kv/                    SPDK_NVMe_KV NIXL plugin — NVMe-oF (TCP, PCIe) to the SMC3 target.
                             Primary storage-leg backend. No RDMA transport is linked — the
                             storage leg is TCP by design, not a build-time option (see "SPDK and
                             the NVMe-KV patches" above).
    spdk_nvme_kv_backend.h/.cpp, spdk_nvme_kv_plugin.cpp, meson.build, meson_options.txt
    prepare-spdk-libs.sh      Generates the "_only" split static archives (TCP, PCIe, POSIX sock)
                             meson.build needs.
  xnvme-kv/                    XNVME_KV NIXL plugin — io_uring_cmd against a locally-attached
                             KV-namespace char device (kernel `nvme` driver, no SPDK/DPDK/VFIO).
                             Not this cluster's storage-leg backend (that's remote NVMe-oF); kept
                             for local-device testing and as a comparison point — see
                             docs/ARCHITECTURE.md's plugin comparison table.
    xnvme_kv_backend.h/.cpp, xnvme_kv_plugin.cpp, meson.build, meson_options.txt

docs/
  HANDOFF.md                  START HERE. Project state, the architecture correction,
                             verified-vs-assumed inventory, and the invariants that guard
                             the silent failure modes.
  TODO.md                     Working task list: blocking decisions, the in-flight
                             architecture correction, hardware bring-up, acceptance.
  ARCHITECTURE.md             Design deep-dive: why storage-mediated, full KV lifecycle,
                             key-derivation scheme, memory tiers, threading/backpressure model,
                             plugin comparison, SPDK upstream-vs-fork split.
  BRINGUP.md                  Exhaustive, sequenced operational procedure — the primary deliverable.
  TROUBLESHOOTING.md           Symptom → cause → fix, plus a diagnostic-commands appendix.
  BENCHMARKING.md              What scripts/bench/ measures and why (llama-benchy against the
                             real proxy/prefill/decode path), and how to read a negative result.
```

## Quick start

This is the shortest path from bare nodes to a serving cluster. Every
command below is also documented in full, with expected output and failure
handling, in [`docs/BRINGUP.md`](docs/BRINGUP.md) — read that before running
this for the first time on real hardware. `HF_TOKEN` (the default `MODEL`
is gated) must be supplied out of band; see Configuration below. `MODEL`'s
bf16 weights are ~145 GB — pre-stage the download to `HF_HOME` before
bring-up rather than discovering the wait during it (see `docs/BRINGUP.md`
§0).

```bash
# on SMC1, SMC2, AND SMC3 — read-only inventory, run first everywhere
scripts/common/00-preflight.sh

# on SMC3 (target) — builds upstream SPDK + patches/spdk/'s 0002/0003
# (bdev_kvmalloc + nvmf KV opcode routing aren't upstream yet — see
# "SPDK and the NVMe-KV patches" above)
scripts/target/01-host-prep.sh
scripts/target/02-build-spdk-kv.sh
scripts/target/03-start-kv-target.sh
scripts/target/04-verify-target.sh

# on SMC1 (prefill) AND SMC2 (decode), each independently
scripts/prefill/01-host-prep.sh          # or scripts/decode/01-host-prep.sh
sudo scripts/common/05-build-spdk-initiator.sh   # UPSTREAM SPDK v26.05 — no fork needed here
sudo scripts/common/10-build-stack.sh
scripts/common/20-build-vllm-lmcache.sh
patches/lmcache/apply-patches.sh
scripts/common/25-validate-lmcache-config.sh <path-you-will-pass-to-start-vllm>

# on SMC1
HF_TOKEN=<token> scripts/prefill/03-start-prefill.sh

# on SMC2
HF_TOKEN=<token> scripts/decode/03-start-decode.sh

# on SMC2 (or wherever PROXY_HOST points)
scripts/proxy/start-proxy.sh

# from any node with network reach to all three
scripts/verify/run-all.sh

# then, from any node with reach to the proxy — see Benchmarking below
scripts/bench/run-all.sh
```

## Configuration

`config/cluster.env` is the single source of truth for every tunable in this
repo; every script sources it via `scripts/common/lib.sh`. Every variable is
individually overridable by exporting it before invoking a script. The
variables an operator most commonly touches:

| Variable | Default | Affects |
|---|---|---|
| `MODEL` | `Qwen/Qwen2.5-72B-Instruct` | Model vLLM serves; must fit the chosen `TP_SIZE`/`GPU_MEM_UTIL`. bf16 weights ~145 GB (~18 GB/GPU at `TP_SIZE=8`), leaving most of each MI300X's 192 GB HBM for KV cache — deliberate, so the remote L2 tier is actually worth measuring. Alternates: `Qwen/Qwen2.5-72B-Instruct-AWQ` (4-bit, ~40 GB), `Qwen/Qwen2.5-32B-Instruct` (bring-up iteration). There is no Qwen3 72B (Qwen3's dense line tops out at 32B). |
| `TP_SIZE` | `8` | Tensor-parallel shard count; host-prep scripts hard-fail if fewer GPUs are visible. |
| `MAX_MODEL_LEN` | `32768` | `Qwen2.5-72B-Instruct`'s native context. `131072` needs a YaRN `rope_scaling` override (via `VLLM_EXTRA_ARGS`) and materially more KV per sequence — a deliberate change, not a config bump alone. |
| `KV_TRANSPORT` | `tcp` | **The** phase gate — `tcp` (Phase 1) or `rdma` (Phase 2); drives both NVMe-oF transport and `UCX_TLS`. See Status above. |
| `KV_BDEV_NAME` / `KV_BDEV_MAX_KEY_SIZE` / `KV_BDEV_VALUE_MAX` | `KvMalloc0` / `16` / `67108864` | `bdev_kvmalloc_create`'s `name`/`max_key_size`/`max_value_size` RPC params — an in-memory red-black tree with no separate total-size knob (there is no `KV_BDEV_SIZE_GB`; an earlier version of this file guessed a `-b/-s/--value-max-size` shape that `bdev_kvmalloc_create` does not accept). |
| `KV_MAX_VALUE_SIZE` | `524288` | Plugin's advertised per-STORE/RETRIEVE ceiling (NOT a device limit — see `docs/ARCHITECTURE.md`). Changing it requires draining the namespace first (`scripts/target/50-reset-namespace.sh`). |
| `NVMF_MAX_IO_SIZE` / `NVMF_LARGE_BUFSIZE` | `16777216` / `1048576` | The SGL ceiling `nvmf_tcp_create()` enforces is `max_io_size / large_bufsize <= 16` (`SPDK_NVMF_MAX_SGL_ENTRIES`) — note the denominator is `large_bufsize` (iobuf pool sizing), not `NVMF_IO_UNIT_SIZE`. Asserted arithmetically before `nvmf_tgt` even launches by `scripts/target/lib-kv-rpc.sh`'s `kv_target_check_sgl()`. Also the ceiling `scripts/target/05-check-chunk-ceiling.sh` checks one LMCache chunk against — see that script. |
| `NVMF_MAX_IO_QPAIRS_PER_CTRLR` | `512` | **The exact RPC key** — SPDK silently ignores the older `max_qpairs_per_ctrlr` spelling and keeps its default of 127 qpairs on a single controller, which makes P+D against a shared target impossible (whichever role connects first takes the whole budget; the second's I/O queue is refused, invisibly — see `config/cluster.env`'s comment for the exact failure signature). `scripts/target/04-verify-target.sh` hard-checks this field actually took. |
| `TARGET_HUGE_PAGES` | `0` | Opt-in on the target only. `0` (default) runs `nvmf_tgt --no-huge -s ${TARGET_MEM_MB}` (malloc-backed, no hugetlbfs dependency); `>0` allocates that many 2 MiB hugepages instead. SMC1/SMC2's `HUGEPAGE_COUNT` is separate and always-on (the plugin embeds SPDK/DPDK EAL). |
| `NVMF_TRSVCID` | `4420` | NVMe-oF target TCP/RDMA port on SMC3. |
| `PREFILL_PORT` / `DECODE_PORT` / `PROXY_PORT` | `8100` / `8200` / `8000` | vLLM and proxy HTTP ports. |
| `NIXL_SIDE_CHANNEL_PORT` | `5557` | Direct P↔D NIXL/UCX handshake port (compute leg). |
| `SPDK_VERSION` | `v26.05` | Upstream SPDK release `05-build-spdk-initiator.sh` clones for SMC1/SMC2; the first release with the NVMe-KV initiator API upstream. |
| `SPDK_INITIATOR_FLAVOR` | `upstream` | `upstream`\|`fork` — SMC1/SMC2's SPDK tree. `upstream` self-clones `SPDK_UPSTREAM_REPO`@`SPDK_VERSION`; `fork` expects SMC3's built tree rsynced in, for ruling out version skew. |
| `SPDK_TARGET_REF` | `master` | Git ref SMC3's SPDK tree is built from (`scripts/target/02-build-spdk-kv.sh`) before `patches/spdk/`'s `0002`/`0003` are applied on top. `master` already carries `0001`/`0004`; pin an explicit SHA for a reproducible build. |
| `SPDK_PATCH_DIR` | `<repo>/patches/spdk` | Where `scripts/target/02-build-spdk-kv.sh` reads the four NVMe-KV `.patch` files from — see "SPDK and the NVMe-KV patches" above. |
| `HF_TOKEN` | *(empty)* | HuggingFace token — required, `MODEL`'s default is gated. |
| `HF_HOME` | `/data/hf` | Model weights cache directory; pre-stage ~145 GB for the default `MODEL`. |
| `LMCACHE_CHUNK_SIZE` | `256` | LMCache KV page size in tokens; actual page bytes scale with the model's hidden size/layer count — see `docs/ARCHITECTURE.md` §2. |
| `LMCACHE_MAX_LOCAL_CPU_SIZE` | `80` | GiB of host DRAM for LMCache's local L1 tier. |
| `STACK_ROOT` | `/opt/kvstack` | Build/install prefix on every node (venv, NIXL, UCX, plugins, logs, run state). |
| `PREFILL_DATA_IF` / `DECODE_DATA_IF` | *(unset, autodetected)* | NIC carrying the compute-leg UCX side channel; pin explicitly once known — see `01-host-prep.sh`'s comment. |
| `PREFILL_RDMA_DEV` / `DECODE_RDMA_DEV` / `TARGET_RDMA_DEV` | *(unset)* | RDMA device names; required once `KV_TRANSPORT=rdma`. |
| `BENCHY_VERSION` / `BENCHY_BASE_URL` / `BENCHY_PP` / `BENCHY_TG` / `BENCHY_DEPTH` / `BENCHY_CONCURRENCY` / `BENCHY_RUNS` / `BENCHY_RESULT_DIR` | see `config/cluster.env` | `scripts/bench/*` sweep shape and result location — see [`docs/BENCHMARKING.md`](docs/BENCHMARKING.md). |

See `config/cluster.env` itself for the full list (~50 variables), each with
an inline comment explaining what reads it and why its default is what it
is.

### Credentials / lab setup

`config/cluster.env` is tracked and public, but it carries no addresses,
usernames, passwords, or console endpoints — only safe `.invalid`-TLD
(RFC 2606) placeholders such as `prefill.invalid`, `prefill-bmc.invalid`.
Per-setup identity lives in `creds/`, which is entirely gitignored — the
`.gitignore` rule is a bare `/creds/` with no negation exceptions, since a
`!creds/...` carve-out is one typo away from tracking a real credentials
file in a public repo. `config/creds.env.template` — the tracked,
fully-commented template of every variable a creds file can set,
placeholder values only — deliberately lives on the `config/` side of that
boundary rather than inside `creds/`, so an accidental commit of real
credentials is structurally impossible rather than merely unlikely.

Bootstrap a lab from the template with `scripts/common/init-creds.sh`:

```bash
# any machine
scripts/common/init-creds.sh 4     # -> creds/setup-4.env + active.env symlink
$EDITOR creds/setup-4.env
source config/cluster.env && echo "${PREFILL_HOST}"
```

- `scripts/common/init-creds.sh --show` reports which `setup-N.env` is
  currently active, or that none is (in which case every address falls
  back to its `.invalid` placeholder).
- Run several labs side by side by keeping `creds/setup-1.env`,
  `creds/setup-2.env`, ... and repointing the `active.env` symlink —
  `scripts/common/init-creds.sh <N>` does this by default, or by hand:
  `ln -sfn setup-N.env creds/active.env`.
- `CREDS_FILE` overrides the symlink entirely, e.g. for CI or a one-off
  lab: `CREDS_FILE=/path/to/other.env scripts/common/00-preflight.sh`.

See `config/creds.env.template` for the authoritative, commented list of
every variable a creds file can set (`PREFILL_*`/`DECODE_*`/`TARGET_*`
hosts, BMCs, consoles, data-plane interfaces, `HF_TOKEN`, and more) — this
section does not duplicate that list.

`config/cluster.env` sources `${CREDS_FILE:-creds/active.env}` **first**, so
every real value wins over its `.invalid` fallback when the file is
present. If no creds file is present — a fresh clone, or a misconfigured
symlink — every address degrades to its `.invalid` placeholder, so a
missing creds file fails loudly (DNS/connection failure against a
reserved, unroutable TLD) instead of silently pointing at whatever real
host happens to resolve. See `config/cluster.env`'s own header comment for
the mechanics.

## Verification

`scripts/verify/run-all.sh` runs the applicable ladder below for whichever
node it's run on, stopping at the first hard failure (each layer assumes the
one below it passed):

| Script | Proves | Node |
|---|---|---|
| `10-verify-network.sh` | Reachability, MTU (jumbo-frame path, not just local config), storage-leg throughput floor, and — hard in `KV_TRANSPORT=rdma` — RDMA fabric health. | any |
| `20-verify-nixl-plugin.sh` | The `SPDK_NVMe_KV` plugin loads (`ldd` self-containment: no stray `librte_*.so`/`libspdk_*.so` DT_NEEDED), and `create_backend()` actually connects to SMC3 — entirely without vLLM or LMCache. | SMC1 or SMC2 |
| `30-verify-kv-roundtrip.sh` | A STORE from one OS process and a RETRIEVE from a different one agree on the same content-derived key — the exact property P/D disaggregation requires. | SMC1 or SMC2 (or split across both for a genuinely cross-node proof) |
| `40-verify-disagg.sh` | End-to-end: identical prompt sent twice through the real proxy; LMCache hit-token counter increases and TTFT improves on the second request. | any host with reach to proxy + both vLLM servers |

Run individually while debugging (each is also a `scripts/verify/*.sh`
script with its own `--help`-equivalent header comment); run
`scripts/verify/run-all.sh` for the overall go/no-go.

## Benchmarking

`scripts/bench/*` (a `llama-benchy`-based harness) answers the question the
functional verification ladder above doesn't: not just "does the cache hit",
but "how much prefill latency does the remote KV cache on SMC3 actually save,
over the real network path, and at what concurrency does it stop keeping
up". Run it after `scripts/verify/run-all.sh` passes:

```bash
scripts/bench/run-all.sh          # install -> baseline -> prefix-cache -> concurrency -> summary
scripts/bench/run-all.sh --quick  # smoke test only — not reportable numbers, see the script's header
```

See [`docs/BENCHMARKING.md`](docs/BENCHMARKING.md) for what each script
measures, why `llama-benchy` specifically (the only tool that is both a
remote HTTP client and has a native prefix-reuse protocol), why `e2e_ttft`
rather than `ttfr` is the honest user-facing number, and how to read a
negative result.

## Known gaps / open items

1. **Gerrit 27889 (`0002`) and 28298 (`0003`) have not merged upstream yet.**
   Both are review-complete (`CR+2`, mergeable, `hashtag 26.09`) but still
   open as of 2026-09-14 — see `patches/spdk/README.md`. This repo carries
   them as vendored `.patch` files applied by
   `scripts/target/02-build-spdk-kv.sh`; once both merge into a released
   v26.09, they can be dropped and `SPDK_TARGET_REF` pinned to that release
   instead of `master`. Tracked at
   [TODO.md §4.4](docs/TODO.md#4-open-items-and-known-limitations).
2. **The LMCache backend-allowlist patch is generated at apply time, not a
   pinned diff.** `patches/lmcache/apply-patches.sh` scans and patches
   whatever LMCache version is actually installed, rather than applying a
   static `.patch` file — see `patches/lmcache/README.md`'s explicit
   VERIFIED-vs-ASSUMED section for exactly which parts of this are confirmed
   against real LMCache source and which are best-effort.
3. **LMCache's config YAML key names are not a stable contract across
   versions.** `scripts/common/gen-lmcache-config.sh` targets `LMCACHE_VERSION=0.5.4`
   specifically; `scripts/common/25-validate-lmcache-config.sh` exists
   precisely because a config can load cleanly and still silently never
   reach the NIXL storage backend on a different installed version.
4. **No restart-survival or cross-process value sharing for a caller that
   never sets `metaInfo`** (i.e. any caller other than LMCache's
   `NixlDynamicStorageBackend` — see `plugins/nvme-kv/spdk_nvme_kv_backend.h`'s
   `make_key()` comment). This cluster's actual LMCache path always sets
   `metaInfo`, so this gap does not affect normal operation, but any custom
   tooling built against `kv_io.py`/`nixlbench`-style calls will hit it.
5. **SMC3's Pollara serial console (`${TARGET_CONSOLE}` / `${TARGET_CONSOLE_ALT}`) refused
   the connection the last time it was tried.** Unresolved; out-of-band
   access to SMC3 in a wedged state currently depends on its BMC
   (`${TARGET_BMC}`) instead.
6. **No geometry manifest for stored KV objects.** Nothing records the
   `max_value_size` an object was split under; changing `KV_MAX_VALUE_SIZE`
   without draining the namespace first
   (`scripts/target/50-reset-namespace.sh`) silently reassembles half-stale
   pages on read. See `docs/ARCHITECTURE.md` and
   `docs/TROUBLESHOOTING.md`.

## References

- Reference implementation this repo's pattern is based on:
  [ROCm/rocm-aic](https://github.com/ROCm/rocm-aic)
- [NIXL](https://github.com/ai-dynamo/nixl) — the transfer-library
  abstraction both plugins implement.
- [LMCache](https://github.com/LMCache/LMCache) — the KV-cache management
  layer vLLM delegates to.
- [vLLM disaggregated serving / KVConnector](https://github.com/vllm-project/vllm) —
  the `LMCacheConnectorV1` / `kv_role` mechanism `scripts/common/start-vllm.sh`
  configures.
- [SPDK NVMe-oF target](https://spdk.io/doc/nvmf.html) — the target-side
  transport this repo's `plugins/nvme-kv` and `scripts/target/` build on.
  [SPDK v26.05](https://github.com/spdk/spdk) (released 2026-05-29) is the
  release the initiator-side NVMe-KV command set (contributed by NVIDIA)
  landed in — see `docs/ARCHITECTURE.md` §7.
- [llama-benchy](https://github.com/eugr/llama-benchy) (MIT) — the
  `scripts/bench/` harness's HTTP-endpoint benchmarking tool; see
  [`docs/BENCHMARKING.md`](docs/BENCHMARKING.md).
