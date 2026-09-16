# kv-cache — P/D-disaggregated vLLM KV cache cluster

This repo builds and operates a prefill/decode (P/D) disaggregated vLLM
serving cluster across three physical hosts: **SMC1** (prefill), **SMC2**
(decode), and **SMC3** — a third, GPU-less node that is the physical KV
store, running [SPDK](https://spdk.io) v26.05's `nvmf_tgt` with a
`bdev_kvmalloc` KV namespace, exported over NVMe-oF/TCP as
`nqn.2024-01.io.nixl:kv0`. It uses
[vLLM](https://github.com/vllm-project/vllm) +
[LMCache](https://github.com/LMCache/LMCache) +
[NIXL](https://github.com/ai-dynamo/nixl) and two purpose-built NIXL storage
plugins (`plugins/nvme-kv`, `plugins/xnvme-kv`). It is a from-scratch,
script-driven bring-up of the pattern described by
[ROCm/rocm-aic](https://github.com/ROCm/rocm-aic), targeting three specific
physical hosts (below), not a generic deployment tool.

Prefill (SMC1) and decode (SMC2) each run vLLM+LMCache on 8x MI300X with the
**exact same, fixed connector composition** —
`MultiConnector[NixlConnector, LMCacheMPConnector]`, with `NixlConnector`
always first (not configurable — see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md))
— and **both KV paths that composition carries are always active**, not
alternatives to pick between:

1. **The P→D handoff.** `NixlConnector` moves prefill's computed KV blocks
   directly into decode's GPU memory over UCX (`KV_TRANSPORT=tcp|rdma`) —
   genuine GPU-to-GPU peer transfer, SMC3 never involved. This is what the
   proxy's 3-step handshake (below) exists to trigger.
2. **The storage tier.** `LMCacheMPConnector` hands completed KV chunks over
   a local ZMQ channel (loopback, port 6557) to the **LMCache MP daemon** —
   a separate host process running on the same node as vLLM — whose L2
   (`nixl_store`) adapter stores them on SMC3 via the `XNVME_KV` (default)
   or `SPDK_NVMe_KV` NIXL plugin. This is the tier that is shared across
   both roles and is what the rest of this README calls the "storage leg".

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design and
data flow, including why the storage tier is still storage-mediated even
though the P→D handoff itself is genuine peer-to-peer.

## Status

> **Two KV paths, both always on — read [`docs/HANDOFF.md`](docs/HANDOFF.md) first.**
>
> `NixlConnector` and `LMCacheMPConnector` are composed together
> (`MultiConnector[NixlConnector, LMCacheMPConnector]`) on every vLLM
> instance, always, on both roles — they are not alternative architectures
> to choose between. See [`docs/HANDOFF.md` §16](docs/HANDOFF.md) for the
> correction (an earlier pass's §12.1 wrongly concluded MP mode couldn't
> reach the storage backend at all; that conclusion is withdrawn).
>
> The **P→D handoff** (`NixlConnector`, prefill → decode, direct GPU-to-GPU
> over the DSC3 NICs) is the path the RDMA acceptance criterion applies to.
> It runs TCP today; `KV_TRANSPORT=tcp|rdma` is the single switch that gates
> it.
>
> The **storage tier** (`LMCacheMPConnector` → the LMCache MP daemon → SMC3
> over NVMe-oF) is **TCP by design, permanently** — not a phase to be
> upgraded. Its backend plugin is a separate switch,
> `KV_BACKEND=XNVME_KV|SPDK_NVMe_KV` (`XNVME_KV` is now the default — the
> kernel CSI-1 blocker that made it unusable is closed; `SPDK_NVMe_KV` is
> kept working as the comparison point, not deleted).
>
> Task list: [`docs/TODO.md`](docs/TODO.md).

| Phase | Transport | State |
|---|---|---|
| **Phase 1 — bring-up** | NVMe-oF/TCP (storage tier, always) + UCX/TCP (P→D handoff) | Implemented in this repo (`KV_TRANSPORT=tcp`, the default in `config/cluster.env`). **Not yet run on the physical hardware** — every script has been written and reasoned through against the actual plugin/SPDK/LMCache source, but no end-to-end run on SMC1/SMC2/SMC3 has been recorded in this repo. |
| **Phase 2 — acceptance** | UCX/RoCE (P→D handoff only — the storage tier is TCP by design, permanently) | **Implemented; raw fabric proven, full run not yet recorded.** The direct P→D transfer is in place as `MultiConnector[NixlConnector, LMCacheMPConnector]`, `NixlConnector` always child[0]; flipping it to RDMA is [`docs/TODO.md` §3](docs/TODO.md#3-acceptance-phase-2-rdma-on-the-compute-leg). Cross-node RC now works and `ib_write_bw` reached ~41,898 MiB/s (~351 Gb/s, ~88% of the 400 Gb/s DSC3 line rate) at 8 MiB — the fabric itself is proven; a full `KV_TRANSPORT=rdma` vLLM run has not yet been recorded end-to-end in this repo. A previous pass added *storage-tier* RDMA groundwork under the wrong premise (an `-Denable_rdma` meson option, an `nvme_rdma.o` split archive); both have been removed entirely — the proven target configuration this repo now follows never exercises NVMe-oF/RDMA. |

`KV_TRANSPORT=tcp|rdma` in `config/cluster.env` is the single switch that
gates the P→D handoff's transport between these two phases (see that file's
comment block). It does not touch the storage tier, which is TCP-only
regardless of phase; the storage tier's own switch is `KV_BACKEND`.

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
                     ┌────────────────────────────────┐
                     │  scripts/proxy/disagg_proxy.py  │  3-step handoff: prime prefill
                     │  EndpointPool per role,          │  (max_tokens=1,
                     │  round-robin — 1P1D today,        │  do_remote_decode=true),
                     │  upgradable to xPyD by adding      │  extract kv_transfer_params,
                     │  fleet entries, no restructuring    │  thread into decode's request
                     └───────────────┬─────────────────┘
              primer + handoff ask   │      real request + kv_transfer_params
                          ▼                                        ▼
      ┌─────────────────────────────┐              ┌─────────────────────────────┐
      │ SMC1 — prefill                │              │ SMC2 — decode                 │
      │ vLLM: MultiConnector[           │◄══ UCX ════│ vLLM: MultiConnector[           │
      │   NixlConnector(kv_producer),   │ KV_TRANSPORT│   NixlConnector(kv_consumer),   │ ← always child[0]
      │   LMCacheMPConnector ]           │  =tcp|rdma  │   LMCacheMPConnector ]           │
      │ runs prompt forward pass        │  P→D handoff│ pulls staged KV, generates       │
      └───────────────┬────────────────┘              └───────────────┬────────────────┘
                       │ ZMQ, loopback:6557                            │ ZMQ, loopback:6557
                       ▼                                               ▼
      ┌─────────────────────────────┐              ┌─────────────────────────────┐
      │ LMCache MP daemon (on SMC1)   │              │ LMCache MP daemon (on SMC2)   │
      │ separate HOST PROCESS,         │              │ separate HOST PROCESS,         │
      │ L1: pinned DRAM, L2: --l2-      │              │ L1: pinned DRAM, L2: --l2-      │
      │ adapter type=nixl_store          │              │ adapter type=nixl_store          │
      └───────────────┬────────────────┘              └───────────────┬────────────────┘
                       │ KV_BACKEND=XNVME_KV (default) | SPDK_NVMe_KV  │
                       └───────────────────────┬───────────────────────┘
                                               ▼
                     NVMe-oF/TCP  (storage tier — TCP by design, permanently;
                                   see Status above)
                                               │
                     ┌─────────────────────────▼──────────────────────┐
                     │ SMC3 — target: the PHYSICAL KV STORE               │
                     │ nvmf_tgt (upstream SPDK + patches/spdk/0002+0003)  │
                     │ bdev_kvmalloc namespace, exported as                │
                     │ nqn.2024-01.io.nixl:kv0                             │
                     └─────────────────────────────────────────────────────┘
```

**Two KV paths, both always active — not independently enableable legs.**
Every vLLM instance runs the exact same fixed composition,
`MultiConnector[NixlConnector, LMCacheMPConnector]` with `NixlConnector`
always `child[0]` (`multi_connector.py:387-400` assigns the whole load to
the first child that reports a match, so if `LMCacheMPConnector` were listed
first it would win on decode and the direct pull below would never fire —
this order is not configurable). The two paths this composition carries:

- **The P→D handoff** (`NixlConnector`, prefill `kv_producer` → decode
  `kv_consumer`, over UCX): genuine GPU-to-GPU peer transfer, SMC3 never
  involved. Transport is `KV_TRANSPORT=tcp|rdma` — the one surviving axis,
  and the Phase-2 acceptance gate. This is what the proxy's 3-step handshake
  above exists to trigger.
- **The storage tier** (`LMCacheMPConnector` → ZMQ, loopback `:6557` → the
  **LMCache MP daemon**, a separate host process on that same node → the
  daemon's L2 `nixl_store` adapter → the `KV_BACKEND` NIXL plugin → SMC3):
  this is where `plugins/nvme-kv/spdk_nvme_kv_backend.h`'s
  `supportsRemote() == false` still matters — the storage-backend plugins
  themselves cannot do peer-to-peer transfer, which is why *this* path (not
  the one above) has to be mediated through SMC3. See
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full lifecycle.

The old `PD_ENABLED`/`PD_CONNECTOR`/`PD_LMCACHE_FIRST` switches that used to
select among alternative architectures (and the single-connector
`LMCacheConnectorV1` mode they enabled) are gone — there is exactly one
supported architecture now, generated unconditionally by
`scripts/common/gen-kv-transfer-config.sh`.

`KV_TRANSPORT` only gates the P→D handoff's transport: `tcp` picks
`UCX_TLS="tcp,self,sm"`, `rdma` picks `UCX_TLS="ib,rocm,self,sm"` (see
`scripts/common/lib.sh`'s `setup_ucx_env` for why `rocm` is a required
memory-domain component, not an optional network transport). The storage
tier never changes with this switch — it is TCP-only regardless of phase;
its own axis is `KV_BACKEND=XNVME_KV|SPDK_NVMe_KV`. See Status above and
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
    gen-kv-transfer-config.sh
                             Emits the fixed --kv-transfer-config JSON for one role: always
                             MultiConnector[NixlConnector, LMCacheMPConnector], NixlConnector
                             always child[0] — no longer configurable, see Architecture above.
    gen-lmcache-config.sh    Emits the LMCache YAML for one role (prefill|decode). Under MP mode
                             its extra_config.{enable_nixl_storage,nixl_backend,...} block is NOT
                             consumed — that surface belongs to the (unused) in-process
                             LMCacheConnectorV1 path; the storage tier's real config is
                             start-lmcache-daemon.sh's --l2-adapter JSON, below.
    start-vllm.sh            Shared body that launches vLLM+LMCache for a role; exec'd by
                             scripts/prefill/03-start-prefill.sh and scripts/decode/03-start-decode.sh.
                             Refuses to start unless the LMCache MP daemon (below) and SMC3 are
                             both already reachable.
    start-lmcache-daemon.sh   Starts the LMCache MP daemon (a separate host process, ZMQ on
    stop-lmcache-daemon.sh    loopback:6557) on this node, with the storage tier attached via a
                             repeatable --l2-adapter {"type":"nixl_store",...} spec. Unnumbered,
                             like start-vllm.sh/deploy.sh/tune-tcp.sh — the numbered scripts above
                             (00-/05-/10-/20-/25-) are ordered one-time build/setup steps, these
                             are runtime lifecycle.
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
  nvme-kv/                    SPDK_NVMe_KV NIXL plugin — NVMe-oF/TCP to the SMC3 target via
                             SPDK's userspace initiator (vfio-pci, hugepages). Storage-tier
                             backend, selected by KV_BACKEND=SPDK_NVMe_KV — kept working as the
                             comparison point, no longer the default (see "SPDK and the NVMe-KV
                             patches" above and docs/HANDOFF.md §10/§16 for why XNVME_KV replaced
                             it as default).
    spdk_nvme_kv_backend.h/.cpp, spdk_nvme_kv_plugin.cpp, meson.build, meson_options.txt
    prepare-spdk-libs.sh      Generates the "_only" split static archives (TCP, PCIe, POSIX sock)
                             meson.build needs.
  xnvme-kv/                    XNVME_KV NIXL plugin — kernel `nvme connect` to SMC3 (generic char
                             device, e.g. /dev/ngXnY) driven by libxnvme's io_uring_cmd passthru.
                             **The default storage-tier backend** (KV_BACKEND=XNVME_KV) — no
                             vfio-pci, no hugepages, no DPDK/SPDK version pairing. See
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
| `KV_TRANSPORT` | `tcp` | **The** phase gate for the P→D handoff only — `tcp` (Phase 1) or `rdma` (Phase 2); drives `NixlConnector`'s `UCX_TLS`. Does **not** touch the storage tier, which is NVMe-oF/TCP unconditionally regardless of this value. See Status above. |
| `KV_BACKEND` | `XNVME_KV` | The storage tier's NIXL plugin, attached to the LMCache MP daemon via its `--l2-adapter` spec — `XNVME_KV` (kernel `nvme connect` + io_uring_cmd, default, canonical since the CSI-1 kernel blocker closed) or `SPDK_NVMe_KV` (userspace SPDK initiator, kept working as the comparison point). Switching drains-and-reinterprets the namespace — see `KV_MAX_VALUE_SIZE_XNVME` in `config/cluster.env`. |
| `KV_BDEV_NAME` / `KV_BDEV_MAX_KEY_SIZE` / `KV_BDEV_VALUE_MAX` | `KvMalloc0` / `16` / `67108864` | `bdev_kvmalloc_create`'s `name`/`max_key_size`/`max_value_size` RPC params — an in-memory red-black tree with no separate total-size knob (there is no `KV_BDEV_SIZE_GB`; an earlier version of this file guessed a `-b/-s/--value-max-size` shape that `bdev_kvmalloc_create` does not accept). |
| `KV_MAX_VALUE_SIZE` | `524288` | Plugin's advertised per-STORE/RETRIEVE ceiling (NOT a device limit — see `docs/ARCHITECTURE.md`). Changing it requires draining the namespace first (`scripts/target/50-reset-namespace.sh`). |
| `NVMF_MAX_IO_SIZE` / `NVMF_LARGE_BUFSIZE` | `16777216` / `1048576` | The SGL ceiling `nvmf_tcp_create()` enforces is `max_io_size / large_bufsize <= 16` (`SPDK_NVMF_MAX_SGL_ENTRIES`) — note the denominator is `large_bufsize` (iobuf pool sizing), not `NVMF_IO_UNIT_SIZE`. Asserted arithmetically before `nvmf_tgt` even launches by `scripts/target/lib-kv-rpc.sh`'s `kv_target_check_sgl()`. Also the ceiling `scripts/target/05-check-chunk-ceiling.sh` checks one LMCache chunk against — see that script. |
| `NVMF_MAX_IO_QPAIRS_PER_CTRLR` | `512` | **The exact RPC key** — SPDK silently ignores the older `max_qpairs_per_ctrlr` spelling and keeps its default of 127 qpairs on a single controller, which makes P+D against a shared target impossible (whichever role connects first takes the whole budget; the second's I/O queue is refused, invisibly — see `config/cluster.env`'s comment for the exact failure signature). `scripts/target/04-verify-target.sh` hard-checks this field actually took. |
| `TARGET_HUGE_PAGES` | `0` | Opt-in on the target only. `0` (default) runs `nvmf_tgt --no-huge -s ${TARGET_MEM_MB}` (malloc-backed, no hugetlbfs dependency); `>0` allocates that many 2 MiB hugepages instead. SMC1/SMC2's `HUGEPAGE_COUNT` is separate and always-on (the plugin embeds SPDK/DPDK EAL). |
| `NVMF_TRSVCID` | `4420` | NVMe-oF target TCP port on SMC3 (the storage tier is TCP-only — see `KV_TRANSPORT` above). |
| `PREFILL_HOST` / `DECODE_HOST` / `TARGET_HOST` | `*.invalid` placeholders | The three nodes. `PREFILL_HOSTS`/`DECODE_HOSTS` (plural, space-separated, default to a single-entry list built from these) are the 1P1D→xPyD upgrade seam: add entries here (and to the matching `_PORTS` below) and `disagg_proxy.py`'s `EndpointPool` load-balances across them — no structural change. |
| `PREFILL_PORT` / `DECODE_PORT` / `PROXY_PORT` | `8100` / `8200` / `8000` | vLLM and proxy HTTP ports. `PREFILL_PORTS`/`DECODE_PORTS` (plural, default to a single-entry list built from these) are the xPyD fleet ports — see `disagg_proxy.py`'s `EndpointPool` below. |
| `NIXL_SIDE_CHANNEL_PORT_PREFILL` / `_DECODE` | `5600` / `5601` | Per-role **base** ports for the out-of-band NIXL handshake (`NixlConnector`'s memory-descriptor exchange, not the UCX data path itself). Per-instance in an xPyD fleet: instance *i* of a role uses `base+i`. The old single, never-wired-up `NIXL_SIDE_CHANNEL_PORT` is gone, not renamed. |
| `SPDK_VERSION` | `v26.05` | Upstream SPDK release `05-build-spdk-initiator.sh` clones for SMC1/SMC2; the first release with the NVMe-KV initiator API upstream. |
| `SPDK_INITIATOR_FLAVOR` | `upstream` | `upstream`\|`fork` — SMC1/SMC2's SPDK tree. `upstream` self-clones `SPDK_UPSTREAM_REPO`@`SPDK_VERSION`; `fork` expects SMC3's built tree rsynced in, for ruling out version skew. |
| `SPDK_TARGET_REF` | `master` | Git ref SMC3's SPDK tree is built from (`scripts/target/02-build-spdk-kv.sh`) before `patches/spdk/`'s `0002`/`0003` are applied on top. `master` already carries `0001`/`0004`; pin an explicit SHA for a reproducible build. |
| `SPDK_PATCH_DIR` | `<repo>/patches/spdk` | Where `scripts/target/02-build-spdk-kv.sh` reads the four NVMe-KV `.patch` files from — see "SPDK and the NVMe-KV patches" above. |
| `HF_TOKEN` | *(empty)* | HuggingFace token — required, `MODEL`'s default is gated. |
| `HF_HOME` | `/data/hf` | Model weights cache directory; pre-stage ~145 GB for the default `MODEL`. |
| `LMCACHE_CHUNK_SIZE` | `256` | LMCache KV page size in tokens; actual page bytes scale with the model's hidden size/layer count — see `docs/ARCHITECTURE.md` §2. |
| `LMCACHE_MAX_LOCAL_CPU_SIZE` | `80` | GiB of host DRAM for LMCache's local L1 tier; also what `start-lmcache-daemon.sh` passes as `--l1-size-gb` to the MP daemon. |
| `LMCACHE_MP_HOST` / `LMCACHE_MP_PORT` | `tcp://127.0.0.1` / `6557` | The ZMQ control channel `LMCacheMPConnector` uses to reach the LMCache MP daemon. Loopback by design, not just convenience — the daemon is a separate host process on the *same* node, and `MemoryObjMetadata.address` is a raw pointer only meaningful within that host's IPC namespace. |
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
| `20-verify-nixl-plugin.sh` | The configured `KV_BACKEND` plugin (`XNVME_KV` by default, or `SPDK_NVMe_KV`) loads (`ldd` self-containment: no stray `librte_*.so`/`libspdk_*.so` DT_NEEDED for the SPDK plugin), and `create_backend()` actually connects to SMC3 — entirely without vLLM, LMCache, or the MP daemon. | SMC1 or SMC2 |
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
   never sets `metaInfo`** — see `plugins/nvme-kv/spdk_nvme_kv_backend.h`'s
   `make_key()` comment. `kv_io.py`/`nixlbench`-style tooling that calls the
   plugin directly (bypassing the LMCache MP daemon entirely) will hit this;
   see `docs/ARCHITECTURE.md` §3 for the up-to-date account of how the
   daemon's own `nixl_store` L2 adapter addresses objects.
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
  the `MultiConnector[NixlConnector, LMCacheMPConnector]` / `kv_role`
  mechanism `scripts/common/gen-kv-transfer-config.sh` generates and
  `scripts/common/start-vllm.sh` passes to vLLM.
- [SPDK NVMe-oF target](https://spdk.io/doc/nvmf.html) — the target-side
  transport this repo's `plugins/nvme-kv` and `scripts/target/` build on.
  [SPDK v26.05](https://github.com/spdk/spdk) (released 2026-05-29) is the
  release the initiator-side NVMe-KV command set (contributed by NVIDIA)
  landed in — see `docs/ARCHITECTURE.md` §7.
- [llama-benchy](https://github.com/eugr/llama-benchy) (MIT) — the
  `scripts/bench/` harness's HTTP-endpoint benchmarking tool; see
  [`docs/BENCHMARKING.md`](docs/BENCHMARKING.md).
