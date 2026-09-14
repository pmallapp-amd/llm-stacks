# TODO

Working task list for the P/D-disaggregated KV cache cluster.

Status key: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked
(on a decision or on someone else)

Last updated: 2026-09-14

## How to use this list

Every item has a stable ID — `N` for a section, `N.M` for a leaf item,
`N.M.K` if a leaf ever needs its own sub-steps. IDs are how you refer to
work in this file: "do 2.3", "what's blocking 3.1". This is the first pass
at assigning IDs; from here on, IDs are not renumbered — a finished item
keeps its number in §5 (Done), and a dropped item is marked `[x]` with a
one-line note on why rather than deleted, so a stale reference to it fails
loud, not silently. New items take the next unused number in their
section.

Before starting an item, check whether it carries a `blocked by` note, and
confirm that dependency is *actually* resolved, not just present in this
file.

## Status summary

| § | Section | Items | Done | Blocked |
|---|---|---|---|---|
| 0 | Blocking decisions | 1 | 0 | 1 |
| 1 | Architecture correction (compute leg) | 9 | 0 | 2 |
| 2 | Hardware bring-up (Phase 1, TCP) | 9 | 0 | 0 |
| 3 | Acceptance (Phase 2, RDMA compute leg) | 4 | 0 | 0 |
| 4 | Open items / known limitations | 5 | 0 | 0 |
| 5 | Done | 13 | 13 | 0 |

---

## 0. Blocking decisions (need an answer before more code lands)

Done means: the decision below is recorded, with rationale, in this file
and reflected in HANDOFF.md §3.

- [!] **0.1 — Scope of SMC3 in the P→D path.** The acceptance criterion says P→D transfer
  is RDMA; SMC3 is NVMe-oF/TCP by definition. But `plugins/nvme-kv/spdk_nvme_kv_backend.h`
  (the `queryMem()` comment) documents storage-mediated P/D as a real, intended,
  previously-broken-and-fixed path. Both can be true. Pick one:
  1. **Both legs, direct wins** — NixlConnector carries P→D, SMC3 sits behind it as
     an L2 tier for cross-request reuse and capacity spill. Likely needs `MultiConnector`.
  2. **Direct only** — SMC3 demoted to optional/experimental, out of the acceptance path.
  3. **Keep both as peers** — storage-mediated P/D retained as a comparison route
     against the direct leg.

  Recommendation: (1). It matches the hardware layout and the plugin's design intent,
  and is reinforced by 5.13 below: a sibling project independently reached the same
  storage-mediated-as-L2 conclusion after separately confirming LMCache's own p2p path
  is unusable with this plugin. This decision determines the scope of 1.1 and 1.4.

---

## 1. Architecture correction (compute leg)

Done means: the direct SMC1↔SMC2 NIXL/UCX transfer exists in the repo, is
composed with the storage leg per the decision in **0.1**, the proxy
threads `kv_transfer_params` to trigger it, and the verify ladder can
prove a hit was a direct transfer rather than a storage-mediated one.

Context: the two legs were conflated by an earlier pass. See
[HANDOFF.md §3](HANDOFF.md#3-the-correction) for the full account. The
corrected model:

| Leg | Path | Transport | NICs |
|---|---|---|---|
| A — P→D KV transfer | SMC1 → SMC2 direct, GPU-to-GPU via NIXL/UCX | TCP now → **RDMA = acceptance** | DSC3-2Q400 |
| B — Shared KV storage | SMC1/SMC2 → SMC3 over NVMe-oF | **TCP, permanently by design** | Pollara-1Q400 |

- [~] **1.1** Research vLLM `NixlConnector`: `--kv-transfer-config` schema, side-channel
  handshake and port allocation (per-TP-rank?), `kv_transfer_params` flow, which NIXL
  backend it uses and whether `UCX_TLS` genuinely reaches RDMA on ROCm. Plus
  `MultiConnector` schema, LMCache `nixl` p2p keys, and a recommendation between
  MultiConnector and LMCache-only composition. *(Previous run was aborted.)*
  **blocked by 0.1** — re-dispatch once the scoping decision is made.

- [ ] **1.2** Split the conflated transport switch. `KV_TRANSPORT` currently drives both
  legs. Replace with `PD_TRANSPORT=tcp|rdma` (compute leg, the acceptance gate) and a
  storage leg that is fixed TCP with no flip available. Touches
  `config/cluster.env`, `scripts/common/{lib.sh,00-preflight.sh,10-build-stack.sh,start-vllm.sh,tune-tcp.sh}`,
  `scripts/{prefill,decode,target}/01-host-prep.sh`, `scripts/target/03-start-kv-target.sh`,
  `scripts/verify/10-verify-network.sh`, `scripts/bench/{lib-bench.sh,40-bench-transport-compare.sh}`,
  and all five docs.

- [ ] **1.3** Implement the direct P→D leg. It does not exist in the repo today — `grep`
  for `NixlConnector|MultiConnector|SIDE_CHANNEL|kv_transfer_params` finds one unused
  variable (`NIXL_SIDE_CHANNEL_PORT`) and two comments. This is the path that carries
  the acceptance criterion. Depends on **1.1**.

- [ ] **1.4** Compose leg A with leg B in `scripts/common/start-vllm.sh`'s
  `--kv-transfer-config` (MultiConnector chain, or LMCache configured for both p2p
  and storage). **blocked by 0.1**.

- [ ] **1.5** Fix `scripts/proxy/disagg_proxy.py` to thread `kv_transfer_params` from the
  prefill response into the decode request. Today it replays the prompt to prefill then
  decode, which populates a cache but will **not** trigger a direct NIXL transfer.

- [ ] **1.6** Open NIXL side-channel ports SMC1↔SMC2 in `scripts/prefill/01-host-prep.sh`
  and `scripts/decode/01-host-prep.sh`. Likely a per-TP-rank port *range*, not a single
  port — confirm in **1.1**.

- [ ] **1.7** Retarget `scripts/verify/10-verify-network.sh` RDMA checks from the Pollara
  storage leg to the DSC3 compute leg (`ibv_devinfo`, `ib_write_bw` SMC1↔SMC2), and add a
  verify rung proving the direct transfer actually fired (NIXL transfer counters or the
  side-channel handshake in logs). Today `scripts/verify/40-verify-disagg.sh` asserts a
  cache-hit counter rises, which passes identically whether the hit came from SMC3 or
  from a direct transfer — it cannot distinguish them, so it cannot verify acceptance.

- [ ] **1.8** Rewrite the two-leg architecture in docs — `README.md` status block,
  `ARCHITECTURE.md`, `BRINGUP.md` §9, `TROUBLESHOOTING.md`. State plainly that the
  storage leg is TCP *by design*, not by phase. Retarget
  `scripts/bench/40-bench-transport-compare.sh` and `docs/BENCHMARKING.md` so the
  TCP-vs-RDMA comparison measures the compute leg.

- [ ] **1.9** Commit the correction as its own staged commits on top of the existing history.

---

## 2. Hardware bring-up (Phase 1, TCP)

Done means: the verify ladder (`scripts/verify/run-all.sh`, rungs
10→20→30→40) is green end-to-end on real SMC1/SMC2/SMC3 hardware, and the
baseline + prefix-cache benchmark numbers in
[BENCHMARKING.md](BENCHMARKING.md) are measured, not estimated.

- [ ] **2.1** Preflight all three nodes — `scripts/common/00-preflight.sh`. Confirm the
      DSC3 NICs expose RDMA devices on SMC1/SMC2 (needed later for **3.x**).
- [ ] **2.2** Build the SMC3 target tree — `scripts/target/02-build-spdk-kv.sh`. Confirm
      patches `0002`/`0003` apply cleanly against whatever `SPDK_TARGET_REF` SHA ends
      up pinned (currently `master`, see `config/cluster.env`), and that the build
      produces `build/bin/nvmf_tgt` and `build/lib/libspdk_bdev_kvmalloc.a`. The
      argument names and formulas below are verified against a working sibling
      deployment (HANDOFF.md §5) but have never been exercised on THIS hardware.
- [ ] **2.3** Start the target (`scripts/target/03-start-kv-target.sh`) and run
      `scripts/target/04-verify-target.sh`. In particular, hard-confirm
      `max_io_qpairs_per_ctrlr` reports **512** on real hardware and not the
      silently-retained default of 127 (the wrong-key failure mode is invisible
      until two roles both attach — see `config/cluster.env`'s
      `NVMF_MAX_IO_QPAIRS_PER_CTRLR` comment) — and that the chunk-size ceiling
      check (`scripts/target/05-check-chunk-ceiling.sh`) passes for the configured
      `MODEL`/`TP_SIZE`/`LMCACHE_CHUNK_SIZE`.
- [ ] **2.4** `nvme discover -t tcp` against the target from both SMC1 and SMC2.
- [ ] **2.5** Reconcile LMCache YAML keys and the NIXL backend allowlist patch against
      the installed LMCache — `scripts/common/25-validate-lmcache-config.sh`,
      `patches/lmcache/apply-patches.sh --dry-run`.
- [ ] **2.6** Build the stack on SMC1/SMC2 (`scripts/common/05-build-spdk-initiator.sh`,
      `scripts/common/10-build-stack.sh`); pass the `ldd` self-containment check on
      `libplugin_SPDK_NVMe_KV.so`.
- [ ] **2.7** Pre-stage Qwen2.5-72B-Instruct weights (~145 GB) on both compute nodes.
- [ ] **2.8** Verify ladder 10 → 20 → 30 → 40 green with the compute leg on TCP.
- [ ] **2.9** Baseline + prefix-cache benchmark; record real numbers in
      [BENCHMARKING.md](BENCHMARKING.md).

---

## 3. Acceptance (Phase 2, RDMA compute leg)

Done means: `PD_TRANSPORT=rdma` (once **1.2** lands) carries the P→D
transfer over the DSC3 fabric, proven by counters rather than throughput
inference, and the verify ladder plus transport-compare benchmark both
pass in that mode.

- [ ] **3.1** RoCE fabric config on the DSC3 NICs SMC1↔SMC2 — PFC/ECN/DSCP, MTU 9000.
- [ ] **3.2** Flip `PD_TRANSPORT=rdma`. `setup_ucx_env` in `scripts/common/lib.sh`
      deliberately omits `tcp` from `UCX_TLS` in RDMA mode so a half-configured fabric
      fails loudly instead of silently falling back — keep that property. Depends on **1.2**.
- [ ] **3.3** Prove RDMA is actually carrying the KV traffic (counters, not inference from
      throughput alone).
- [ ] **3.4** Re-run the verify ladder and `scripts/bench/40-bench-transport-compare.sh`.

---

## 4. Open items / known limitations

Done means: N/A for this section — these are accepted limitations and
watch items, not work items with a completion state. Re-review each at
the next relevant hardware session.

- [ ] **4.1** SMC3 Pollara serial console (`telnet REDACTED-ADDR 2022/2023`) refused
      connection when last tried. Lower priority now that this leg is TCP-only; BMC
      (`REDACTED-ADDR`) is the fallback out-of-band path.
- [ ] **4.2** No geometry manifest for stored KV objects — changing `KV_MAX_VALUE_SIZE`
      without draining the namespace silently yields half-stale reads. Mitigated by
      `scripts/target/50-reset-namespace.sh` and documented, but not solved.
- [ ] **4.3** uuid4-keyed objects have no restart survival or cross-process sharing. Only the
      content-derived dynamic-storage path (`nixl_pool_size: 0`) works across processes.
- [ ] **4.4** **Watch, low priority:** track Gerrit
      [27889](https://review.spdk.io/c/spdk/spdk/+/27889) (`0002`) and
      [28298](https://review.spdk.io/c/spdk/spdk/+/28298) (`0003`) —
      re-check <https://review.spdk.io/q/topic:kv+status:open> periodically. Once both
      merge into a released v26.09, the vendored `patches/spdk/0002-*.patch` and
      `0003-*.patch` can be dropped and `SPDK_TARGET_REF` pinned to that release instead
      of `master`. See [`patches/spdk/README.md`](../patches/spdk/README.md).
- [ ] **4.5** Re-run `scripts/target/05-check-chunk-ceiling.sh` whenever `MODEL`,
      `TP_SIZE`, or `LMCACHE_CHUNK_SIZE` changes. The current default (Qwen2.5-72B-Instruct,
      TP=8, chunk=256 → 10 MiB) fits under `NVMF_MAX_IO_SIZE` (16 MiB) with only 37%
      headroom — dropping to TP=4 with the same chunk size blows straight through it.

---

## 5. Done

- [x] **5.1** Analysed `plugins/nvme-kv` and `plugins/xnvme-kv` source.
- [x] **5.2** Researched the rocm-aic reference implementation, SPDK v26.05 NVMe-KV upstream
      status, and llama-benchy.
- [x] **5.3** `config/cluster.env` + `scripts/common/lib.sh` cluster contract.
- [x] **5.4** SMC3 target scripts, compute build chain, LMCache patch + config generation,
      serving + proxy, verify ladder, benchmark harness.
- [x] **5.5** README + ARCHITECTURE + BRINGUP + TROUBLESHOOTING + BENCHMARKING.
- [x] **5.6** Switched model to Qwen2.5-72B-Instruct; migrated to SPDK v26.05
      (upstream initiator / fork target split).
- [x] **5.7** Fixed `BENCHY_BASE_URL` forward-reference bug in `config/cluster.env`.
- [x] **5.8** Git history rebuilt as staged, dependency-ordered commits.
- [x] **5.9** Confirmed there is no private SPDK fork. NVMe-KV support is four
      upstream-bound Gerrit patches by Ben Walker `<ben@nvidia.com>`, vendored at
      `patches/spdk/`; removed the `KV_SPDK_REPO` blocker, which never described
      reality (see **4.4** for the follow-up watch item).
- [x] **5.10** Rewrote the SMC3 target configuration to match a proven sibling
      deployment: `nvmf_tgt` (not `spdk_tgt`), a single `--json` startup config instead
      of an `rpc.py` sequence, `max_io_qpairs_per_ctrlr=512` under its exact key name,
      the `max_io_size / large_bufsize <= 16` SGL formula, the real
      `bdev_kvmalloc_create` argument names (`name`/`max_key_size`/`max_value_size`),
      and opt-in hugepages (`TARGET_HUGE_PAGES`, default 0, `--no-huge`).
- [x] **5.11** Removed storage-leg RDMA scaffolding entirely — the `-Denable_rdma` meson
      option, the `nvme_rdma.o` split archive, and `--with-rdma` on the target/initiator
      SPDK configure lines (`plugins/nvme-kv/meson.build`, `meson_options.txt`,
      `prepare-spdk-libs.sh`, `scripts/target/02-build-spdk-kv.sh`,
      `scripts/common/05-build-spdk-initiator.sh`). The storage leg is NVMe-oF/TCP by
      design; carrying an unvalidated opt-in for a requirement that does not exist was
      pure liability.
- [x] **5.12** Added `scripts/target/05-check-chunk-ceiling.sh` — the per-rank
      chunk-size-vs-`max_io_size` correctness guard — and wired it as a hard check into
      `scripts/target/04-verify-target.sh`.
- [x] **5.13** Confirmed (via a sibling project's independent investigation) that
      LMCache's own `enable_pd`/`pd_role` peer-to-peer path is unusable with this
      plugin (`spdk_nvme_kv_backend.h` declares `supportsRemote() { return false; }`,
      which `pd_backend.py`'s `transfer_channel` requires `true` for). Narrows, but
      does not close, **0.1**.
