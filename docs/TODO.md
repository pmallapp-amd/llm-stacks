# TODO

Working task list for the P/D-disaggregated KV cache cluster.

Status key: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked on someone else

Last updated: 2026-09-14

---

## 0. Blocking decisions (need an answer before more code lands)

- [!] **Scope of SMC3 in the P→D path.** The acceptance criterion says P→D transfer
  is RDMA; SMC3 is NVMe-oF/TCP by definition. But `plugins/nvme-kv/spdk_nvme_kv_backend.h`
  (the `queryMem()` comment) documents storage-mediated P/D as a real, intended,
  previously-broken-and-fixed path. Both can be true. Pick one:
  1. **Both legs, direct wins** — NixlConnector carries P→D, SMC3 sits behind it as
     an L2 tier for cross-request reuse and capacity spill. Likely needs `MultiConnector`.
  2. **Direct only** — SMC3 demoted to optional/experimental, out of the acceptance path.
  3. **Keep both as peers** — storage-mediated P/D retained as a comparison route
     against the direct leg.

  Recommendation: (1). It matches the hardware layout and the plugin's design intent.
  This decision determines what the research task below has to cover.

- [!] **`KV_SPDK_REPO` fork URL.** Hard blocker for the target node. Stock SPDK v26.05
  carries the NVMe-KV *initiator* API but has no `bdev_kvmalloc` and no KV opcode
  routing in `lib/nvmf/ctrlr_bdev.c`, so a stock tree cannot export a KV namespace.
  `scripts/target/02-build-spdk-kv.sh` dies with an actionable message until this is set.

---

## 1. Architecture correction (in flight)

Context: the two legs were conflated. See [HANDOFF.md](HANDOFF.md#3-the-correction)
for the full account. The corrected model:

| Leg | Path | Transport | NICs |
|---|---|---|---|
| A — P→D KV transfer | SMC1 → SMC2 direct, GPU-to-GPU via NIXL/UCX | TCP now → **RDMA = acceptance** | DSC3-2Q400 |
| B — Shared KV storage | SMC1/SMC2 → SMC3 over NVMe-oF | **TCP, permanently by design** | Pollara-1Q400 |

- [~] **Research** vLLM `NixlConnector`: `--kv-transfer-config` schema, side-channel
  handshake and port allocation (per-TP-rank?), `kv_transfer_params` flow, which NIXL
  backend it uses and whether `UCX_TLS` genuinely reaches RDMA on ROCm. Plus
  `MultiConnector` schema, LMCache `nixl` p2p keys, and a recommendation between
  MultiConnector and LMCache-only composition. *(Previous run was aborted; re-dispatch
  once the scoping decision above is made.)*

- [ ] **Split the conflated transport switch.** `KV_TRANSPORT` currently drives both
  legs. Replace with `PD_TRANSPORT=tcp|rdma` (compute leg, the acceptance gate) and a
  storage leg that is fixed TCP with no flip available. Touches 18 files:
  `config/cluster.env`, `scripts/common/{lib.sh,00-preflight.sh,10-build-stack.sh,start-vllm.sh,tune-tcp.sh}`,
  `scripts/{prefill,decode,target}/01-host-prep.sh`, `scripts/target/03-start-kv-target.sh`,
  `scripts/verify/10-verify-network.sh`, `scripts/bench/{lib-bench.sh,40-bench-transport-compare.sh}`,
  and all five docs.

- [ ] **Remove storage-leg RDMA scaffolding** (built on the wrong premise — delete,
  do not keep "just in case"; unvalidated opt-in code for a requirement that does not
  exist is a liability):
  - `plugins/nvme-kv/prepare-spdk-libs.sh` — the `libspdk_nvme_rdma_only.a` split
  - `plugins/nvme-kv/meson.build`, `meson_options.txt` — the `enable_rdma` option
  - `scripts/target/lib-kv-rpc.sh` — the `NVMF_TRTYPE=RDMA` transport path
  - `config/cluster.env` — `SPDK_WITH_RDMA`, the RDMA branch of `NVMF_TRTYPE`
  - `--with-rdma` in `scripts/target/02-build-spdk-kv.sh`,
    `scripts/common/05-build-spdk-initiator.sh`, `scripts/common/10-build-stack.sh`

- [ ] **Implement the direct P→D leg.** It does not exist in the repo today — `grep`
  for `NixlConnector|MultiConnector|SIDE_CHANNEL|kv_transfer_params` finds one unused
  variable (`NIXL_SIDE_CHANNEL_PORT`) and two comments. This is the path that carries
  the acceptance criterion.

- [ ] **Compose leg A with leg B** in `scripts/common/start-vllm.sh`'s
  `--kv-transfer-config` (MultiConnector chain, or LMCache configured for both p2p
  and storage), per the scoping decision.

- [ ] **Fix `scripts/proxy/disagg_proxy.py`** to thread `kv_transfer_params` from the
  prefill response into the decode request. Today it replays the prompt to prefill then
  decode, which populates a cache but will **not** trigger a direct NIXL transfer.

- [ ] **Open NIXL side-channel ports** SMC1↔SMC2 in `scripts/prefill/01-host-prep.sh`
  and `scripts/decode/01-host-prep.sh`. Likely a per-TP-rank port *range*, not a single
  port — confirm in research.

- [ ] **Retarget `scripts/verify/10-verify-network.sh`** RDMA checks from the Pollara
  storage leg to the DSC3 compute leg (`ibv_devinfo`, `ib_write_bw` SMC1↔SMC2).

- [ ] **Add a verify rung proving the direct transfer fired** — NIXL transfer counters
  or the side-channel handshake in logs. Today `scripts/verify/40-verify-disagg.sh`
  asserts a cache-hit counter rises, which passes identically whether the hit came from
  SMC3 or from a direct transfer. It cannot distinguish them, so it cannot verify
  acceptance.

- [ ] **Rewrite the two-leg architecture in docs** — `README.md` status block,
  `ARCHITECTURE.md`, `BRINGUP.md` §9, `TROUBLESHOOTING.md`. State plainly that the
  storage leg is TCP *by design*, not by phase.

- [ ] **Retarget `scripts/bench/40-bench-transport-compare.sh`** and
  `docs/BENCHMARKING.md` so the TCP-vs-RDMA comparison measures the compute leg.

- [ ] **Commit the correction** as its own staged commits on top of the existing ten.

---

## 2. Hardware bring-up (Phase 1, TCP)

- [ ] Preflight all three nodes — `scripts/common/00-preflight.sh`. Confirm the DSC3
      NICs expose RDMA devices on SMC1/SMC2 (needed later for acceptance).
- [ ] Verify `bdev_kvmalloc_create` RPC argument names against the real fork. Scripts
      probe and die with `--help` output rather than guessing; override via
      `KV_BDEV_CREATE_ARGS`.
- [ ] Reconcile LMCache YAML keys and the NIXL backend allowlist patch against the
      installed LMCache — `scripts/common/25-validate-lmcache-config.sh`,
      `patches/lmcache/apply-patches.sh --dry-run`.
- [ ] Bring up the SMC3 target; `nvme discover` from both SMC1 and SMC2.
- [ ] Build the stack on SMC1/SMC2; pass the `ldd` self-containment check on
      `libplugin_SPDK_NVMe_KV.so`.
- [ ] Pre-stage Qwen2.5-72B-Instruct weights (~145 GB) on both compute nodes.
- [ ] Verify ladder 10 → 20 → 30 → 40 green with the compute leg on TCP.
- [ ] Baseline + prefix-cache benchmark; record real numbers in
      [BENCHMARKING.md](BENCHMARKING.md).

---

## 3. Acceptance (Phase 2, RDMA on the compute leg)

- [ ] RoCE fabric config on the DSC3 NICs SMC1↔SMC2 — PFC/ECN/DSCP, MTU 9000.
- [ ] Flip `PD_TRANSPORT=rdma`. `setup_ucx_env` in `scripts/common/lib.sh` deliberately
      omits `tcp` from `UCX_TLS` in RDMA mode so a half-configured fabric fails loudly
      instead of silently falling back — keep that property.
- [ ] Prove RDMA is actually carrying the KV traffic (counters, not inference from
      throughput alone).
- [ ] Re-run the verify ladder and `scripts/bench/40-bench-transport-compare.sh`.

---

## 4. Open items

- [ ] SMC3 Pollara serial console (`telnet REDACTED-ADDR 2022/2023`) refused connection
      when last tried. Lower priority now that this leg is TCP-only.
- [ ] No geometry manifest for stored KV objects — changing `KV_MAX_VALUE_SIZE` without
      draining the namespace silently yields half-stale reads. Mitigated by
      `scripts/target/50-reset-namespace.sh` and documented, but not solved.
- [ ] uuid4-keyed objects have no restart survival or cross-process sharing. Only the
      content-derived dynamic-storage path (`nixl_pool_size: 0`) works across processes.

---

## 5. Done

- [x] Analysed `plugins/nvme-kv` and `plugins/xnvme-kv` source.
- [x] Researched the rocm-aic reference implementation, SPDK v26.05 NVMe-KV upstream
      status, and llama-benchy.
- [x] `config/cluster.env` + `scripts/common/lib.sh` cluster contract.
- [x] SMC3 target scripts, compute build chain, LMCache patch + config generation,
      serving + proxy, verify ladder, benchmark harness.
- [x] README + ARCHITECTURE + BRINGUP + TROUBLESHOOTING + BENCHMARKING.
- [x] Switched model to Qwen2.5-72B-Instruct; migrated to SPDK v26.05
      (upstream initiator / fork target split).
- [x] Fixed `BENCHY_BASE_URL` forward-reference bug in `config/cluster.env`.
- [x] Git history rebuilt as 10 staged, dependency-ordered commits.
