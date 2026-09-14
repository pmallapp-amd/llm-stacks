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

| Phase | Transport | State |
|---|---|---|
| **Phase 1 — bring-up** | NVMe-oF/TCP (storage leg) + UCX/TCP (compute leg) | Implemented in this repo (`KV_TRANSPORT=tcp`, the default in `config/cluster.env`). **Not yet run on the physical hardware** — every script has been written and reasoned through against the actual plugin/SPDK/LMCache source, but no end-to-end run on SMC1/SMC2/SMC3 has been recorded in this repo. |
| **Phase 2 — acceptance** | NVMe-oF/RDMA + UCX/RoCE | Groundwork landed, opt-in, **unvalidated on hardware**. `plugins/nvme-kv/prepare-spdk-libs.sh` splits `nvme_rdma.o` into `libspdk_nvme_rdma_only.a` when the initiator's SPDK tree was built `--with-rdma`, and `meson.build`'s `-Denable_rdma=true` (default `false`, `meson_options.txt`) links it plus `-lrdmacm -libverbs`. Nobody has rebuilt with `-Denable_rdma=true`, flipped `KV_TRANSPORT=rdma`, or run the RDMA path end to end yet — see [`docs/BRINGUP.md` §9.1](docs/BRINGUP.md#91-initiator-side-current-state) and gap #1 below. |

`KV_TRANSPORT=tcp|rdma` in `config/cluster.env` is the single switch that
gates both legs of the datapath between these two phases (see that file's
comment block).

## Topology

| Host / Card | IP / Address | User | Password |
|---|---|---|---|
| **SMC1 — smc1** (prefill role), 8x MI300X `[1dd8:5303]` | `REDACTED-ADDR` | `root` | `docker` |
| &nbsp;&nbsp;└ BMC | `REDACTED-ADDR` | `admin` | `REDACTED-PASSWORD` |
| &nbsp;&nbsp;└ Serial console (2x DSC3-2Q400 `[1dd8:5200]` host) | `telnet REDACTED-ADDR 2024 / 2025` ("REDACTED-LABEL") | — | — |
| **SMC2 — smc2** (decode role), 8x MI300X `[1dd8:5303]` | `REDACTED-ADDR` | `root` | `docker` |
| &nbsp;&nbsp;└ BMC | `REDACTED-ADDR` | `admin` | `REDACTED-PASSWORD` |
| &nbsp;&nbsp;└ Serial console (2x DSC3-2Q400 `[1dd8:5200]` host) | `telnet REDACTED-ADDR 2022 / 2023` | — | — |
| **SMC3 — target** (storage target role), no GPU | `REDACTED-ADDR` | `root` | `docker` |
| &nbsp;&nbsp;└ BMC | `REDACTED-ADDR` | `root` | `REDACTED-PASSWORD` |
| &nbsp;&nbsp;└ Serial console (2x POLLARA-1Q400 `[1dd8:1002]` @ 64:00.0, 84:00.0) | `telnet REDACTED-ADDR 2022 / 2023` ("REDACTED-LABEL/2") | — | — **connection REFUSED when last tried — unresolved, see gap #6 below** |

Compute nodes (SMC1, SMC2) each carry 2x DSC3-2Q400 `[1dd8:5200]` data-plane
NICs. The storage node (SMC3) carries 2x POLLARA-1Q400 `[1dd8:1002]`. Both
families are 400G-class NICs. This repo's `config/cluster.env` is the
machine-readable form of this table.

This is a private repo; the credentials above are intentionally committed —
see `config/cluster.env`'s own header comment.

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
                     NVMe-oF/TCP  (Phase 1; RDMA is Phase 2, opt-in groundwork
                                   landed, unvalidated — see §9 below)
                                     │
                     ┌──────────────▼───────────────┐
                     │ SMC3 — storage target          │
                     │ spdk_tgt (kv_spdk fork) +       │
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
[`docs/BRINGUP.md` §9](docs/BRINGUP.md#9-phase-2-tcp--rdma).

## Repository layout

```
config/
  cluster.env               Single source of truth for every tunable — see Configuration below.

scripts/
  common/
    lib.sh                   Shared bash helpers: logging, retry/wait_for_*, start_bg/stop_bg,
                             setup_ucx_env / setup_nixl_kv_env, the check/checks_summary harness.
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
    01-host-prep.sh          SMC3 storage-node prep (hugepages, kernel modules, firewall, memlock).
    02-build-spdk-kv.sh       Clone/build the TARGET-side SPDK tree — the kv_spdk fork by default
                             (SPDK_TARGET_FLAVOR=fork; bdev_kvmalloc + NVMe-KV opcode routing
                             never landed upstream, see ARCHITECTURE.md §7 and cluster.env).
    03-start-kv-target.sh     Start spdk_tgt and configure the NVMe-KV namespace via RPC.
    04-verify-target.sh       Verify the target is up and correctly configured.
    50-reset-namespace.sh     Drain and recreate the namespace (required after changing
                             KV_MAX_VALUE_SIZE — see Configuration below).
    99-stop.sh                Stop kv-target (optional --release-hugepages, --clean-config).
    lib-kv-rpc.sh             Shared spdk_tgt RPC sequence used by 03- and 50- (kept in one
                             place so "fresh start" and "reset" cannot drift apart).
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

patches/lmcache/
  README.md                  Why/what/how of the LMCache NIXL-backend-allowlist patch, with an
                             explicit VERIFIED-vs-ASSUMED accounting.
  apply-patches.sh            Applies the patch to the INSTALLED LMCache (not a static .patch file).
  _patch_engine.py            tokenize/ast-based source transformation the above invokes.

plugins/
  nvme-kv/                    SPDK_NVMe_KV NIXL plugin — NVMe-oF (TCP, PCIe linked always; RDMA
                             linked opt-in via -Denable_rdma=true, default false, unvalidated) to
                             the SMC3 target. Primary storage-leg backend.
    spdk_nvme_kv_backend.h/.cpp, spdk_nvme_kv_plugin.cpp, meson.build, meson_options.txt
    prepare-spdk-libs.sh      Generates the "_only" split static archives meson.build needs
                             (including libspdk_nvme_rdma_only.a when the SPDK tree has it).
  xnvme-kv/                    XNVME_KV NIXL plugin — io_uring_cmd against a locally-attached
                             KV-namespace char device (kernel `nvme` driver, no SPDK/DPDK/VFIO).
                             Not this cluster's storage-leg backend (that's remote NVMe-oF); kept
                             for local-device testing and as a comparison point — see
                             docs/ARCHITECTURE.md's plugin comparison table.
    xnvme_kv_backend.h/.cpp, xnvme_kv_plugin.cpp, meson.build, meson_options.txt

docs/
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
this for the first time on real hardware. `KV_SPDK_REPO` (the kv_spdk fork
URL, needed only for the SMC3 target — see gap #2) and `HF_TOKEN` (the
default `MODEL` is gated) must be supplied out of band; see Configuration
below. `MODEL`'s bf16 weights are ~145 GB — pre-stage the download to
`HF_HOME` before bring-up rather than discovering the wait during it (see
`docs/BRINGUP.md` §0).

```bash
# on SMC1, SMC2, AND SMC3 — read-only inventory, run first everywhere
scripts/common/00-preflight.sh

# on SMC3 (target) — builds the kv_spdk FORK (bdev_kvmalloc isn't upstream)
scripts/target/01-host-prep.sh
KV_SPDK_REPO=<fork-url> scripts/target/02-build-spdk-kv.sh
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
| `KV_BDEV_SIZE_GB` | `64` | Size of the RAM-backed `bdev_kvmalloc` namespace on SMC3. |
| `KV_MAX_VALUE_SIZE` | `524288` | Plugin's advertised per-STORE/RETRIEVE ceiling (NOT a device limit — see `docs/ARCHITECTURE.md`). Originally derived from the NVMe-oF/TCP transport's SGL ceiling, which is no longer the governing constraint on SPDK >=26.05 (see `docs/ARCHITECTURE.md` §7) — the default is unchanged regardless. Changing it requires draining the namespace first (`scripts/target/50-reset-namespace.sh`). |
| `NVMF_TRSVCID` | `4420` | NVMe-oF target TCP/RDMA port on SMC3. |
| `PREFILL_PORT` / `DECODE_PORT` / `PROXY_PORT` | `8100` / `8200` / `8000` | vLLM and proxy HTTP ports. |
| `NIXL_SIDE_CHANNEL_PORT` | `5557` | Direct P↔D NIXL/UCX handshake port (compute leg). |
| `SPDK_VERSION` | `v26.05` | Upstream SPDK release both `05-build-spdk-initiator.sh` and (as a fallback flavor) `02-build-spdk-kv.sh` clone; this is the first release with the NVMe-KV initiator API upstream. |
| `SPDK_INITIATOR_FLAVOR` | `upstream` | `upstream`\|`fork` — SMC1/SMC2's SPDK tree. `upstream` self-clones `SPDK_UPSTREAM_REPO`@`SPDK_VERSION`; `fork` expects the kv_spdk tree rsynced in from SMC3. See `docs/ARCHITECTURE.md` §7. |
| `SPDK_TARGET_FLAVOR` | `fork` | `fork`\|`upstream` — SMC3's SPDK tree. `fork` (default) is required: stock upstream SPDK has no `bdev_kvmalloc` module. |
| `KV_SPDK_REPO` | *(unset)* | kv_spdk fork git URL — **must be supplied for the SMC3 target**; not vendored in this repo. No longer needed on SMC1/SMC2 (default `SPDK_INITIATOR_FLAVOR=upstream`). See gap #2. |
| `SPDK_WITH_RDMA` | `1` | Configures every SPDK tree (target and initiator) `--with-rdma` so RDMA is a relink, not a rebuild, later. Does not by itself enable RDMA in the plugin — that's `plugins/nvme-kv/meson.build`'s `-Denable_rdma` meson option (default `false`), see `docs/BRINGUP.md` §9.1. |
| `NVMF_IOBUF_SMALL_CACHE_SIZE` / `NVMF_IOBUF_LARGE_CACHE_SIZE` | `128` / `32` (KiB) | SPDK >=26.05's iobuf-pool sizing for `nvmf_create_transport`, replacing the deprecated `io_unit_size`/`buf-cache-size`/`num-shared-buffers` knobs. |
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

1. **Phase 2 RDMA groundwork has landed but is unvalidated.**
   `plugins/nvme-kv/prepare-spdk-libs.sh` splits `nvme_rdma.o` into
   `libspdk_nvme_rdma_only.a` when the initiator's SPDK tree was configured
   `--with-rdma`, and `meson.build`'s `-Denable_rdma` option (default
   `false`, `meson_options.txt`) adds it to the `--whole-archive` group plus
   `-lrdmacm -libverbs`. Nobody has rebuilt with `-Denable_rdma=true`, set
   `KV_TRANSPORT=rdma`, or run the storage leg over an actual RoCE fabric
   yet. See `docs/BRINGUP.md` §9.1 for exactly what's implemented vs. what
   remains and how to prove RDMA is carrying traffic rather than TCP.
2. **`KV_SPDK_REPO` is not vendored, and is needed only for the SMC3
   target.** As of SPDK v26.05 the NVMe-KV **initiator** API
   (`spdk_nvme_kv_store/retrieve/delete/exist/list()`) is upstream, so
   SMC1/SMC2 build a stock SPDK tree (`scripts/common/05-build-spdk-
   initiator.sh`, `SPDK_INITIATOR_FLAVOR=upstream`) and need no fork at all.
   The **target** side (`bdev_kvmalloc`, and `lib/nvmf/ctrlr_bdev.c`'s KV
   opcode routing) did not land upstream, so SMC3 still needs the kv_spdk
   fork; its URL/ref must be supplied by the operator —
   `scripts/target/02-build-spdk-kv.sh` fails loudly and explains this if
   neither `KV_SPDK_REPO` nor a pre-built tree at `SPDK_TARGET_SRC` is
   available. See `docs/ARCHITECTURE.md` §7 for why the boundary falls
   exactly there.
3. **The LMCache backend-allowlist patch is generated at apply time, not a
   pinned diff.** `patches/lmcache/apply-patches.sh` scans and patches
   whatever LMCache version is actually installed, rather than applying a
   static `.patch` file — see `patches/lmcache/README.md`'s explicit
   VERIFIED-vs-ASSUMED section for exactly which parts of this are confirmed
   against real LMCache source and which are best-effort.
4. **LMCache's config YAML key names are not a stable contract across
   versions.** `scripts/common/gen-lmcache-config.sh` targets `LMCACHE_VERSION=0.5.4`
   specifically; `scripts/common/25-validate-lmcache-config.sh` exists
   precisely because a config can load cleanly and still silently never
   reach the NIXL storage backend on a different installed version.
5. **No restart-survival or cross-process value sharing for a caller that
   never sets `metaInfo`** (i.e. any caller other than LMCache's
   `NixlDynamicStorageBackend` — see `plugins/nvme-kv/spdk_nvme_kv_backend.h`'s
   `make_key()` comment). This cluster's actual LMCache path always sets
   `metaInfo`, so this gap does not affect normal operation, but any custom
   tooling built against `kv_io.py`/`nixlbench`-style calls will hit it.
6. **SMC3's Pollara serial console (`telnet REDACTED-ADDR 2022/2023`) refused
   the connection the last time it was tried.** Unresolved; out-of-band
   access to SMC3 in a wedged state currently depends on its BMC
   (`REDACTED-ADDR`) instead.
7. **No geometry manifest for stored KV objects.** Nothing records the
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
