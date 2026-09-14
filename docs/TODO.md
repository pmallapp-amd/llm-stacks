# TODO

Working task list for the P/D-disaggregated KV cache cluster.

Status key: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked
(on a decision or on someone else)

Last updated: 2026-09-14 (compute-leg direct-transfer implementation pass)

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
| 0 | Blocking decisions | 1 | 1 | 0 |
| 1 | Architecture correction (compute leg) | 13 | 6 | 0 |
| 2 | Hardware bring-up (Phase 1, TCP) | 9 | 0 | 0 |
| 3 | Acceptance (Phase 2, RDMA compute leg) | 4 | 0 | 0 |
| 4 | Open items / known limitations | 5 | 0 | 0 |
| 5 | Done | 13 | 13 | 0 |

---

## 0. Blocking decisions (need an answer before more code lands)

Done means: the decision below is recorded, with rationale, in this file
and reflected in HANDOFF.md §3.

- [x] **0.1 — Scope of SMC3 in the P→D path. DECIDED: option (1), both legs, direct
  wins.** The acceptance criterion says P→D transfer is RDMA; SMC3 is NVMe-oF/TCP by
  definition. But `plugins/nvme-kv/spdk_nvme_kv_backend.h` (the `queryMem()` comment)
  documents storage-mediated P/D as a real, intended, previously-broken-and-fixed path.
  Both can be true — and now are: vLLM runs `MultiConnector[NixlConnector,
  LMCacheMPConnector]`. NixlConnector carries the direct P→D transfer (the RDMA
  acceptance criterion); LMCacheMPConnector stays `kv_both` on both sides as an L2 reuse
  tier, not the P/D transport. Confirmed by reading the live `MultiConnector` class
  (`multi_connector.py:213`) and that both children implement `SupportsHMA`, so the
  hybrid KV cache manager needs no disabling. See
  `scripts/common/gen-kv-transfer-config.sh` for the exact composed JSON. This matches
  the hardware layout and the plugin's design intent, and is reinforced by 5.13: a
  sibling project independently reached the same storage-mediated-as-L2 conclusion
  after separately confirming LMCache's own p2p path is unusable with this plugin.

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

- [x] **1.1** Research vLLM `NixlConnector`: `--kv-transfer-config` schema, side-channel
  handshake and port allocation, `kv_transfer_params` flow, which NIXL backend it uses
  and whether `UCX_TLS` genuinely reaches RDMA on ROCm. Plus `MultiConnector` schema,
  LMCache `nixl` p2p keys, and a recommendation between MultiConnector and LMCache-only
  composition. Resolved: `MultiConnector[NixlConnector, LMCacheMPConnector]` (see 0.1);
  side channel is `VLLM_NIXL_SIDE_CHANNEL_HOST`/`_PORT`, one port per role (not a
  per-TP-rank range — no evidence for that was found; ports 5600/5601, see
  `config/cluster.env`'s `NIXL_SIDE_CHANNEL_PORT_PREFILL`/`_DECODE`); `UCX_TLS` reaches
  RDMA on ROCm only with `ib,rocm,self,sm` (see 3.2's note — the OLD
  `rc_verbs,rc_mlx5,dc,ud,self,sm` value was wrong on two counts, fixed in `lib.sh`'s
  `setup_ucx_env`).

- [ ] **1.2** Split the conflated transport switch. `KV_TRANSPORT` currently drives both
  legs. Replace with `PD_TRANSPORT=tcp|rdma` (compute leg, the acceptance gate) and a
  storage leg that is fixed TCP with no flip available. Touches
  `config/cluster.env`, `scripts/common/{lib.sh,00-preflight.sh,10-build-stack.sh,start-vllm.sh,tune-tcp.sh}`,
  `scripts/{prefill,decode,target}/01-host-prep.sh`, `scripts/target/03-start-kv-target.sh`,
  `scripts/verify/10-verify-network.sh`, `scripts/bench/{lib-bench.sh,40-bench-transport-compare.sh}`,
  and all five docs. **Explicitly NOT done by the 1.3-1.7 direct-leg implementation
  pass** — that pass was told to keep `KV_TRANSPORT`'s name as-is rather than rename it
  here, so all of this task's new RDMA-mode plumbing (`UCX_TLS_RDMA`,
  `require_rdma_access`, `PREFILL_UCX_NET_DEVICES`/`DECODE_UCX_NET_DEVICES`, etc.) is
  still keyed off `KV_TRANSPORT`, unchanged. Revisit whether `PD_TRANSPORT` is still
  worth introducing once the compute leg has been exercised on real hardware.

- [x] **1.3** Implement the direct P→D leg. It did not exist in the repo before this —
  `grep` for `NixlConnector|MultiConnector|SIDE_CHANNEL|kv_transfer_params` used to find
  one unused variable (`NIXL_SIDE_CHANNEL_PORT`) and two comments. Now:
  `scripts/common/gen-kv-transfer-config.sh` emits the composed `--kv-transfer-config`;
  `lib.sh`'s `setup_pd_env`/`require_rdma_access` wire the side channel and the F4 device
  preflight; `scripts/common/start-vllm.sh` calls all of it. `PD_ENABLED=0` reverts to
  exactly the pre-correction LMCache-only form.

- [x] **1.4** Compose leg A with leg B in `scripts/common/start-vllm.sh`'s
  `--kv-transfer-config` — done via `gen-kv-transfer-config.sh`'s `MultiConnector[
  NixlConnector, LMCacheMPConnector]`, order controlled by `PD_LMCACHE_FIRST`.

- [x] **1.5** Fix `scripts/proxy/disagg_proxy.py` to thread `kv_transfer_params` from the
  prefill response into the decode request — `_prime_prefill()` now parses prefill's JSON
  response, extracts `PD_HANDOFF_FIELD` (configurable; exact field name not independently
  verified against a specific installed vLLM, see that variable's comment), and
  `handle_completion()` merges it into decode's request body. `Stats.prefill_no_handoff`
  counts responses missing the field — the signature of a misconfigured direct leg.

- [x] **1.6** Open NIXL side-channel ports SMC1↔SMC2 in `scripts/prefill/01-host-prep.sh`
  and `scripts/decode/01-host-prep.sh` — one port per role (5600/5601, not a per-TP-rank
  range; see 1.1), opened via `ufw`/`firewalld` mirroring the target's existing pattern.

- [x] **1.7** Add a verify rung proving the direct transfer actually fired, distinct from
  a storage/L2 cache hit — `scripts/verify/50-verify-pd-direct.sh`, wired into
  `scripts/verify/run-all.sh`. Asserts on non-zero `need to load:` **and** non-zero
  `External prefix cache hit rate` in decode's own log (F5 — never on a flag), and
  explicitly distinguishes NixlConnector-direct / LMCache-L2 / vLLM's-own-prefix-cache
  outcomes. **Split off, NOT closed by this item:** retargeting
  `scripts/verify/10-verify-network.sh`'s RDMA checks away from the Pollara storage leg
  (which is TCP-only, permanently, by design — those checks running against it at all is
  stale) onto the DSC3 compute leg specifically — spun out as new item **1.10** below,
  since it touches a different file this pass did not.

- [ ] **1.8** Rewrite the two-leg architecture in docs — `README.md` status block,
  `ARCHITECTURE.md`, `BRINGUP.md` §9, `TROUBLESHOOTING.md`. State plainly that the
  storage leg is TCP *by design*, not by phase. Retarget
  `scripts/bench/40-bench-transport-compare.sh` and `docs/BENCHMARKING.md` so the
  TCP-vs-RDMA comparison measures the compute leg. `docs/BENCHMARKING.md`'s F5 confound
  section (added this pass, see 1.7/1.13) can be folded into this rewrite rather than
  duplicated.

- [ ] **1.9** Commit the correction as its own staged commits on top of the existing history.

- [ ] **1.10** Retarget `scripts/verify/10-verify-network.sh`'s RDMA fabric checks
  (`ibv_devinfo`, `ib_write_bw`) so they run against the DSC3 compute leg (SMC1↔SMC2)
  specifically, not against `TARGET_HOST`/Pollara — the storage leg is TCP-only,
  permanently, by design (see `config/cluster.env`'s "Transport selection" comment), so an
  RDMA check against it is stale regardless of `KV_TRANSPORT`. Split off from 1.7 (done)
  because it touches a different file. Depends on **1.2** for a clean `*_RDMA_DEV` vs.
  `*_UCX_NET_DEVICES` naming pass while in there.

- [ ] **1.11** Per-host `PREFILL_UCX_NET_DEVICES`/`DECODE_UCX_NET_DEVICES` mapping (F3):
  both default to `ionic_0:1` today because that is the one index confirmed to line up on
  both hosts. `scripts/{prefill,decode}/01-host-prep.sh` now report each host's
  `ionic_* -> pci=` mapping, but nobody has cross-checked that report against the actual
  DSC3 cabling on SMC1/SMC2 — do that on first real hardware contact, and pin
  higher-numbered `ionic_N` values explicitly (not by copying one host's report to the
  other) if the fabric ever uses more than the one confirmed-symmetric port pair.

- [ ] **1.12** Connector-order experiment: run `scripts/verify/50-verify-pd-direct.sh` and
  `scripts/bench/20-bench-prefix-cache.sh --confirm-connector-hit` under both
  `PD_LMCACHE_FIRST=0` (default — NixlConnector first refusal) and `PD_LMCACHE_FIRST=1`
  (LMCache first refusal) and record how often each connector actually ends up serving a
  given request under each order. This is the follow-up `PD_LMCACHE_FIRST`'s own
  `config/cluster.env` comment references; nobody has run it on real hardware yet.

- [ ] **1.13** F5 benchmark rework: `scripts/bench/20-bench-prefix-cache.sh` now warns
  about and has a `--confirm-connector-hit` mode for the "vLLM's own prefix cache sits
  upstream of the connector" confound (see `docs/BENCHMARKING.md`'s F5 section), but the
  underlying sweep still re-sends context to the SAME decode instance — a genuinely
  cross-instance or post-eviction measurement protocol (per F5's own recommendation) has
  not been built. Design and add that as its own script/mode once real hardware is
  available to validate the eviction-forcing mechanism against.

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
- [ ] **3.2** Flip `KV_TRANSPORT=rdma` (still this variable's name until **1.2** lands —
      see 1.2's note). `setup_ucx_env` in `scripts/common/lib.sh` now exports
      `UCX_TLS="ib,rocm,self,sm"` in RDMA mode (corrected this pass — the old
      `rc_verbs,rc_mlx5,dc,ud,self,sm` pinned a transport, `rc`, this fabric's ionic
      provider doesn't expose at all; see the F3 writeup in `setup_ucx_env`'s own
      comment) and deliberately still omits `tcp` from `UCX_TLS` so a half-configured
      fabric fails loudly instead of silently falling back — keep that property.
      `require_rdma_access` (also new this pass) is the preflight that catches an
      unopenable `/dev/infiniband/uverbs*` node before vLLM burns ~90s looking like a
      hang (F4) — run it (via `start-vllm.sh`, automatic) before assuming a failure
      here is the fabric's fault.
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
