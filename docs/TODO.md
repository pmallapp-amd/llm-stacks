# TODO

Working task list. Last updated 2026-09-14.

## How to use this list

IDs are **stable** — reference an item by number ("do 2.4", "what blocks 3.1").
New work appends; existing IDs are never renumbered. Check the `blocked by`
note before starting anything.

Status: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked on someone else

## Status summary

| § | Area | Items | Done | Blocked |
|---|---|---|---|---|
| 0 | Blocking decisions and follow-ups | 3 | 1 | 2 |
| 1 | Architecture correction (compute leg) | 13 | 11 | 0 |
| 2 | Hardware bring-up (Phase 1, TCP) | 10 | 0 | 0 |
| 3 | Acceptance (Phase 2, RDMA compute leg) | 5 | 0 | 0 |
| 4 | Open items and known limitations | 5 | 0 | 0 |
| 5 | Done | 14 | 14 | — |

**Next action: 2.1.** The architecture work is complete; everything remaining
needs the hardware.

---

## 0. Blocking decisions and follow-ups

- [x] **0.1** Scope of the storage tier in the P→D path. **Decided:** both legs,
      direct wins — `MultiConnector[NixlConnector, LMCacheMPConnector]`, with
      NixlConnector carrying the P/D role and LMCache as a reuse tier. Settled by
      a working reference deployment, not inference.
- [!] **0.2** **Rotate the BMC and root passwords.** They were committed to a
      public repo before the cleanup. History is purged and the published branch
      is verified clean, but anyone who cloned or any GitHub cache during that
      window still has them. The purge does not close this.
- [!] **0.3** Rename remote branch `rocm-aic` → `old`. Requires a PAT with
      `Administration: write`; the current token is read-only for that endpoint.
      Cosmetic — `main` is already default and correct.

---

## 1. Architecture correction (compute leg)

*Done when the direct prefill→decode leg exists, is composed with the storage
tier, and can be verified independently of it.* Complete except the benchmark
rework.

- [x] **1.1** Establish the two-leg model and correct the conflated transport switch.
- [x] **1.2** Research `NixlConnector` / `MultiConnector` / LMCache p2p. Resolved
      from a working deployment. LMCache's own peer channel is unusable here
      (`supportsRemote() == false`).
- [x] **1.3** Remove storage-leg RDMA scaffolding built on the wrong premise.
- [x] **1.4** Implement the direct P→D leg — `scripts/common/gen-kv-transfer-config.sh`.
- [x] **1.5** Compose both legs in `scripts/common/start-vllm.sh`.
- [x] **1.6** Thread `kv_transfer_params` through `scripts/proxy/disagg_proxy.py`.
- [x] **1.7** Add `scripts/verify/50-verify-pd-direct.sh`, distinguishing a direct
      NIXL transfer from an LMCache hit from vLLM's own prefix cache.
- [x] **1.8** Fix `setup_ucx_env` — `ib,rocm,self,sm`, RoCE `/31` subnet handling,
      per-role device pinning.
- [x] **1.9** Add `setup_pd_env` (refuses a loopback side-channel address) and
      `require_rdma_access` (opens a uverbs node rather than stat-ing it).
- [x] **1.10** Open side-channel ports in both host-prep scripts.
- [x] **1.11** Record the SPDK patch provenance and upstream status.
- [x] **1.12** Externalise credentials, purge history, add template + bootstrap.
- [ ] **1.13** Rework `scripts/bench/20-bench-prefix-cache.sh` for cross-instance
      or post-eviction measurement. As written it repeats the same context to the
      same endpoint, which vLLM's own prefix cache may serve without consulting
      any connector — see [HANDOFF §8](HANDOFF.md#8-known-measurement-trap). The
      warning and `--confirm-connector-hit` are in place; the restructure is not.

---

## 2. Hardware bring-up (Phase 1, TCP)

*Done when the verify ladder is green end to end with the compute leg on TCP.*

- [ ] **2.1** `scripts/common/init-creds.sh 4`, populate `creds/setup-4.env`,
      confirm `source config/cluster.env` resolves real addresses.
- [ ] **2.2** `scripts/common/00-preflight.sh` on all three nodes. Confirm the
      DSC3 NICs expose RDMA devices on both compute nodes (needed for §3).
- [ ] **2.3** Pin an SPDK master SHA in `SPDK_TARGET_REF`; confirm patches 0002
      and 0003 apply cleanly to it. *blocked by nothing — do before 2.4*
- [ ] **2.4** Build SPDK and start the target; `scripts/target/04-verify-target.sh`.
      Hard-check that `max_io_qpairs_per_ctrlr` actually reports 512 — the wrong
      spelling is accepted silently. *blocked by 2.3*
- [ ] **2.5** `nvme discover` against the target from both compute nodes.
- [ ] **2.6** Build the stack on both compute nodes; pass the `ldd`
      self-containment check on `libplugin_SPDK_NVMe_KV.so`.
- [ ] **2.7** Reconcile the LMCache YAML keys and NIXL backend allowlist patch
      against the version that actually installs —
      `patches/lmcache/apply-patches.sh --dry-run`, then
      `scripts/common/25-validate-lmcache-config.sh`. **Most likely thing to
      bite first.**
- [ ] **2.8** Determine which `ionic_*` device is which physical port on *each*
      host; set `PREFILL_UCX_NET_DEVICES` / `DECODE_UCX_NET_DEVICES` in the creds
      file. The indices are not symmetric across machines.
- [ ] **2.9** Pre-stage Qwen2.5-72B-Instruct weights (~145 GB) on both compute
      nodes. Run `scripts/target/05-check-chunk-ceiling.sh` and confirm it passes
      for the final TP and chunk size.
- [ ] **2.10** Start prefill, decode and proxy; run
      `scripts/verify/run-all.sh`. Confirm 50 reports a **direct NIXL transfer**,
      not an LMCache hit. Confirm the `kv_transfer_params` field name is right —
      override with `PD_HANDOFF_FIELD` if not. *blocked by 2.4–2.9*

---

## 3. Acceptance (Phase 2, RDMA on the compute leg)

*Done when P→D KV transfer runs over RDMA with no TCP fallback, proven by
counters rather than inferred from throughput.*

- [ ] **3.1** Configure the RoCE fabric between the compute nodes — PFC/ECN/DSCP,
      MTU 9000. *blocked by 2.10*
- [ ] **3.2** Confirm `/dev/infiniband/uverbs*` are openable, `memlock` is
      unlimited, and `ibv_devinfo` shows `PORT_ACTIVE`. Nodes present but
      unopenable present as a ~90 s hang, not an error.
- [ ] **3.3** Set the compute leg to RDMA and restart. `UCX_TLS` excludes `tcp`
      by design so a half-configured fabric fails loudly.
- [ ] **3.4** Prove RDMA is carrying the KV traffic — counters, not throughput
      inference.
- [ ] **3.5** Re-run the verify ladder and
      `scripts/bench/40-bench-transport-compare.sh` for the TCP-vs-RDMA number.
      *blocked by 1.13 if the figure is to mean anything*

---

## 4. Open items and known limitations

- [ ] **4.1** The target's Pollara serial console refused connection when last
      tried. Low priority — that leg is TCP-only.
- [ ] **4.2** No geometry manifest for stored KV objects: changing
      `KV_MAX_VALUE_SIZE` without draining yields silent half-stale reads.
      Mitigated by `scripts/target/50-reset-namespace.sh`, not solved.
- [ ] **4.3** uuid4-keyed objects have no restart survival or cross-process
      sharing. Only the content-derived path works across processes.
- [ ] **4.4** Watch Gerrit 27889 / 28298. Both are review-complete and tagged
      `26.09`; when they merge, drop the vendored `patches/spdk/0002` and `0003`
      and move `SPDK_TARGET_REF` to the release tag.
- [ ] **4.5** Connector-order experiment. `PD_LMCACHE_FIRST=1` is the only
      posture in which the L2 tier can win a load; the default gives NixlConnector
      first refusal. Worth measuring once 1.13 makes the number trustworthy.

---

## 5. Done

- [x] **5.1** Analysed both NIXL plugins; researched rocm-aic, SPDK v26.05 and llama-benchy.
- [x] **5.2** `config/cluster.env` + `scripts/common/lib.sh` cluster contract.
- [x] **5.3** SMC3 target scripts.
- [x] **5.4** Compute-node build chain (SPDK initiator, UCX, NIXL, plugins, venv).
- [x] **5.5** LMCache allowlist patch and config generation/validation.
- [x] **5.6** Serving scripts and the disaggregation proxy.
- [x] **5.7** Verify ladder (5 rungs).
- [x] **5.8** llama-benchy benchmark harness.
- [x] **5.9** Full documentation set.
- [x] **5.10** Model set to Qwen2.5-72B-Instruct; SPDK migrated to v26.05+.
- [x] **5.11** Target rebuilt from a proven configuration, replacing inference.
- [x] **5.12** Chunk-ceiling guard, validated against two independent measurements.
- [x] **5.13** Direct P→D compute leg implemented and composed.
- [x] **5.14** Credentials externalised, history purged, repo published to
      `main` at `github.com/pmallapp-amd/llm-stacks`.
