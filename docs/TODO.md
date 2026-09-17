# TODO

Working task list. Last updated 2026-09-17.

## How to use this list

IDs are **stable** — reference an item by number ("do 2.4", "what blocks 3.1").
New work appends; existing IDs are never renumbered. Check the `blocked by`
note before starting anything.

Status: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked on someone else

## Status summary

| § | Area | Items | Done | Blocked |
|---|---|---|---|---|
| 0 | Blocking decisions and follow-ups | 4 | 2 | 2 |
| 1 | Architecture correction (compute leg) | 14 | 12 | 0 |
| 2 | Hardware bring-up (Phase 1, TCP) | 13 | 6 | 2 |
| 3 | Acceptance (Phase 2, RDMA compute leg) | 10 | 3 | 0 |
| 4 | Open items and known limitations | 6 | 1 | 0 |
| 5 | Done | 14 | 14 | — |
| 6 | Storage-tier integration (XNVME_KV / SPDK_NVMe_KV as an LMCache tier) | 23 | 14 | 6 |

**Read [HANDOFF §3](HANDOFF.md#3-how-to-resume) first** — it carries the
cluster state as handed over and the ordered resume plan. This file is the
task index.

**Before anything:** `uptime` on both compute nodes (6.20), confirm who owns
`smc3` right now (6.18), `modprobe amdgpu` (0.4), and the LMCache MP daemon
must be up before `start-vllm.sh` will proceed (HANDOFF §1.1, §3.4).

**The composition is fixed, not configurable:** `MultiConnector[NixlConnector,
LMCacheMPConnector]`, `NixlConnector` hardcoded as `connectors[0]` — see
HANDOFF §1. This closed out 4.5's old connector-order question.

**Model running today:** `Qwen/Qwen3-8B`, `TP_SIZE=1` — **not**
`config/cluster.env`'s tracked default (`Qwen2.5-72B-Instruct`, TP=8). Every
throughput/latency figure in this file dated before 2026-09-16 predates that
switch and is not comparable to anything measured after it (HANDOFF §1).

**Storage tier, current state:** cross-node store+retrieve is PROVEN, both
directions, at the plugin/device layer (6.25). The live vLLM engines still
store thousands of objects and retrieve zero — isolated to LMCache's
per-daemon object-naming scheme, not to the device or topology (6.21, HANDOFF
§2). This is the one live blocker in this section.

**RDMA acceptance (§3 below)** is a separate, independent transport upgrade
for the P→D path — routing is closed and RC queue pairs move real cross-node
traffic; UD queue-pair creation still fails on this driver/firmware, which is
the sole remaining blocker (3.9, HANDOFF §7.5).

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
- [x] **0.4** **Unblock the GPUs.** `modprobe.blacklist=amdgpu` is on both
      compute nodes' kernel cmdline and suppresses **autoload only** —
      `modprobe amdgpu` (no reboot, no GRUB edit) restores all 8 GPUs per node
      immediately (`rocm-smi`: 192 GiB VRAM × 8, `runtime_status=active`).
      Does not survive a reboot — `01-host-prep.sh` / `ensure_amdgpu_loaded()`
      in `lib.sh` runs it automatically every run (opt-out `AMDGPU_AUTOLOAD=0`).
      **Recurrence observed 2026-09-15:** both nodes rebooted unexpectedly and
      came back with 0 GPUs again, exactly as predicted — confirms the pattern
      empirically, not fixed, only automated. The kernel `nvme connect` from §6
      also did not survive that reboot (no `--persistent`, no systemd unit —
      see 6.9).

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
- [x] **1.7** Added `scripts/verify/50-verify-pd-direct.sh`, distinguishing a
      direct NIXL transfer from an LMCache hit from vLLM's own prefix cache.
      Four independent bugs, each producing a FALSE NEGATIVE on a fully
      healthy system, found and fixed 2026-09-16: the priming request never
      threaded the handoff field, the side-channel check probed the wrong
      host, a race against vLLM's periodic stats logger, and a dead string
      assertion. Passes **9/9** against the current (Qwen3-8B/TP=1) stack;
      re-verified 9/9 again 2026-09-17 after both compute nodes were rebooted.
      Full account: HANDOFF §7.12.
- [x] **1.8** Fix `setup_ucx_env` — `ib,rocm,self,sm`, RoCE `/31` subnet handling,
      per-role device pinning.
- [x] **1.9** Add `setup_pd_env` (refuses a loopback side-channel address) and
      `require_rdma_access` (opens a uverbs node rather than stat-ing it).
      Bind addresses are now pinned in creds
      (`PD_SIDE_CHANNEL_HOST_PREFILL`/`_DECODE`) rather than relying on
      `hostname -I`'s first-IP guess. Known, non-correctness asymmetry: bulk
      KV rides the management NIC on both nodes, but decode's side channel
      now sits on a fabric NIC, not management — harmless today, resolve
      before trusting it under a topology change (HANDOFF §2).
- [x] **1.10** Open side-channel ports in both host-prep scripts.
- [x] **1.11** Record the SPDK patch provenance and upstream status.
- [x] **1.12** Externalise credentials, purge history, add template + bootstrap.
- [ ] **1.13** Rework `scripts/bench/20-bench-prefix-cache.sh` for cross-instance
      or post-eviction measurement. As written it repeats the same context to the
      same endpoint, which vLLM's own prefix cache may serve without consulting
      any connector — see [HANDOFF §5](HANDOFF.md#5-traps-that-have-actually-bitten-distilled).
      The warning and `--confirm-connector-hit` are in place; the restructure is not.
- [~] **1.14** Implement and prove the 1P1D→xPyD fleet-shape seam: plural
      `PREFILL_HOSTS`/`_PORTS`/`DECODE_HOSTS`/`_PORTS` (defaulting to the
      existing singulars), an `EndpointPool` round-robin `select()` in
      `scripts/proxy/disagg_proxy.py` replacing the four scalar endpoint
      variables, and a per-instance NIXL side-channel port. **Done:** the
      code exists and is unit-tested against fake upstreams for the
      handoff-semantics risks this refactor could introduce (priming body,
      the `min_tokens`/`stream_options` drop, handoff threading,
      `prefill_no_handoff`, the swallow-prefill/502-on-decode asymmetry —
      HANDOFF §7.10 has the underlying handoff-protocol history this guards
      against). **Not done:** never run against more than one real prefill
      or decode instance on live hardware — every measurement in this file
      is still N=1. Prove it on real xPyD hardware before trusting the
      fleet shape beyond N=1. 2026-09-16.

---

## 2. Hardware bring-up (Phase 1, TCP)

*Done when the verify ladder is green end to end with the compute leg on TCP.*

- [x] **2.1** `scripts/common/init-creds.sh 4`, populate `creds/setup-4.env`;
      `source config/cluster.env` resolves real addresses. Verified
      2026-09-14 — ssh as root reaches all three nodes.
- [x] **2.2** `00-preflight.sh` on all three nodes — 5/5 checks each,
      2026-09-14 (after fixing 2.13). Inventory: `smc3` 320 CPUs / 62 GiB
      RAM, no ROCm, RDMA `rocep100s0`+`rocep132s0`, kernel 6.8.0-38;
      `smc1`/`smc2` 128 CPUs / 1511 GiB RAM, ROCm 7.13.0, 8 `ionic` RDMA
      devices/node, kernel 5.15.0-191 (later upgraded to 24.04.5/6.8.0-139,
      see 6.5–6.8). Caveat: its GPU check is advisory (`check_soft`) — green
      here means "inventoried", not "can serve" (0.4).
- [ ] **2.3** Pin an SPDK master SHA in `SPDK_TARGET_REF`; confirm patches 0002
      and 0003 apply cleanly to it. **Attempted 2026-09-15, FAILED:** `git am`
      could not apply `patches/spdk/0002` against current `master`. Not
      closed — the actual decision (pin a SHA / rebase / adopt the prebuilt
      tree) now lives at 6.2, since this session got a working target via a
      different route (2.4).
- [~] **2.4** Build SPDK and start the target; `scripts/target/04-verify-target.sh`.
      *blocked by 2.3.* **Partial workaround, 2026-09-15:** brought up
      instead from the prebuilt `/root/kv_spdk` (SPDK v26.05-pre) —
      namespace `KvMalloc0`, subsystem `nqn.2024-01.io.nixl:kv0`,
      `max_io_qpairs_per_ctrlr: 512` confirmed (HANDOFF §4 invariant 7).
      Transport reports `max_io_size: 131072` (128 KiB), not the 16 MiB
      invariant 8 assumed — see 6.4 (now resolved: 32768 is the real
      per-value ceiling that matters, not this number). Not fully done:
      `04-verify-target.sh` itself was never run against this substitute
      target, and 2.3's build failure is still open.
- [x] **2.5** `nvme discover` from both compute nodes — done 2026-09-15;
      both `nvme connect` to `nqn.2024-01.io.nixl:kv0` with 128 I/O queues.
      KV namespace materializes as a char-only device (`/dev/ng1n1` on
      `smc1`, `/dev/ng2n1` on `smc2`). Neither the connection nor the target
      survives a reboot (HANDOFF §3.4).
- [!] **2.6** Build the stack on both compute nodes; pass the `ldd`
      self-containment check on `libplugin_SPDK_NVMe_KV.so`. **Parked
      2026-09-15 — superseded by 6.1**, which decided the container path.
      Left open rather than deleted because the `ldd` invariant (HANDOFF §4
      invariant 2) still governs any future source build.
- [x] **2.7** Reconcile the LMCache backend allowlist against what's
      actually installed. **Answered:** the vendored LMCache 0.5.3 accepts
      `XNVME_KV`/`SPDK_NVMe_KV` because the vendor image was built with
      `patches/lmcache/0006`–`0008` applied at image-build time — not by
      anything in this repo (HANDOFF §7.8, `patches/lmcache/README.md`).
      The from-source patch generator this item originally targeted is
      correctly withdrawn (that build path has never completed) and
      survives only in git history.
- [~] **2.8** Map `ionic_*` devices to physical ports per host; pin
      `PREFILL_UCX_NET_DEVICES`/`DECODE_UCX_NET_DEVICES`. **Current state,
      re-confirmed 2026-09-16 after a firmware update:** `ionic_0..7` →
      `benic1p1..benic8p1` on both nodes, all 8 ACTIVE, `smc1` on
      `30.1.N.1/24`, `smc2` on `30.2.N.1/24`. Pinned to `ionic_2:1` on both
      nodes — `ionic_2` is `-a-120` firmware on both, additionally dodging
      `smc1`'s lone `ionic_0` holdout on `-pi-121` (3.10). Two earlier
      mappings recorded here (2026-09-14, 2026-09-15) were each correct for
      their own moment and then invalidated by the hardware changing
      underneath (HANDOFF §7.1).
- [x] **2.9** Pre-staged Qwen2.5-72B-Instruct weights to `/var/tmp/hf/` on
      both nodes (bind-mounted `/hf`), verified 37/37 shards, 145.4 GB,
      index-matched. Redundant hub-cache copy reclaimed later (6.17).
- [!] **2.10** Start prefill/decode/proxy; run the verify ladder.
      **Superseded by 6.11** (bring-up) and **6.10** (compose the storage
      tier) — those items now carry this work against the container path.
      The `kv_transfer_params` handoff field is load-bearing, not "unused"
      as the vendored proxy's silence once suggested — HANDOFF §7.10.
- [ ] **2.11** Fix `00-preflight.sh`'s PCIe inventory section — it greps
      `lspci -d 1dd8:` and claims that covers "GPUs + data-plane NICs".
      Measured 2026-09-14: it covers **zero** GPUs, because the MI300X ID
      is `[1002:74a1]` (vendor `1002`/AMD, not `1dd8`) — see HANDOFF §1's
      hardware table. Small script fix, but `scripts/` is being edited
      concurrently this session — coordinate before touching it.
- [ ] **2.12** Distribute an ssh key to all three nodes. Confirmed
      2026-09-14: key auth is not configured anywhere; every connection so
      far used `sshpass` against `creds/active.env`. `deploy.sh` can install
      a key (opt-in flag) but pushes those same passwords to all three
      machines by default — decide whether that default is acceptable.
- [x] **2.13** Fixed `00-preflight.sh` aborting mid-run under
      `set -euo pipefail` when `rocminfo` exits non-zero (GPUs blacklisted,
      0.4) — a `grep`+`pipefail` interaction silently truncated every
      section after ROCm/GPU. Swept six more sites in `lib.sh` and the
      three `01-host-prep.sh` scripts; host-prep sites now `die` with a
      diagnostic instead of warning, since those are hard gates. 2026-09-14.

---

## 3. Acceptance (Phase 2, RDMA on the compute leg)

*Done when P→D KV transfer runs over RDMA with no TCP fallback, proven by
counters rather than inferred from throughput.*

- [ ] **3.1** Configure the RoCE fabric between the compute nodes — PFC/ECN/DSCP,
      MTU 9000. *blocked by 2.10*
- [ ] **3.2** Confirm `/dev/infiniband/uverbs*` are openable, `memlock` is
      unlimited, and `ibv_devinfo` shows `PORT_ACTIVE`. **Partly answered,
      2026-09-15 — badly:** the devices exist and all 8 ports read
      `ACTIVE`/`LinkUp`, yet `ibv_devinfo` returned `No IB devices found`
      because no ionic provider loaded — see 3.7. A device present but
      unopenable presents as a ~90s hang, not an error. `memlock` still
      unchecked.
- [ ] **3.3** Set the compute leg to RDMA and restart. `UCX_TLS` excludes `tcp`
      by design so a half-configured fabric fails loudly.
- [ ] **3.4** Prove RDMA is carrying the KV traffic — counters, not throughput
      inference.
- [ ] **3.5** Re-run the verify ladder and
      `scripts/bench/40-bench-transport-compare.sh` for the TCP-vs-RDMA number.
      *blocked by 1.13 if the figure is to mean anything*
- [x] **3.6** P→D fabric had no route: `smc1`'s data-plane addresses are
      `30.1.N.1/24`, `smc2`'s are `30.2.N.1/24` — different `/24`s, no
      fabric route, falsifying `config/cluster.env`'s `/31`
      point-to-point premise. **CLOSED 2026-09-16 — not done by us:**
      static routes now exist for all 8 fabric pairs, both directions;
      cross-node ping is 0% loss at ~0.10 ms. First real cross-node RDMA
      throughput once routing closed: `ib_write_bw` ~41,898 MiB/s (~88% of
      the **400** Gb/s line rate — these are 400 Gb/s NDR NICs, not 200 as
      earlier assumed). See HANDOFF §7.1 (the shared-hardware pattern) and
      §7.6 (the throughput measurement itself).
- [~] **3.7** The `ionic` RDMA stack had two independent breaks, introduced
      by the 24.04.5/6.8 upgrade, on both compute nodes. **Break 1
      (userspace provider ABI mismatch): FIXED** — another party installed
      a matched 24.04 DSC bundle; `ibv_devinfo` now works on both nodes,
      `show_gid` returns 24 GIDs/node (HANDOFF §7.4). **Break 2: RC QPs
      work and move data** (`ibv_rc_pingpong` — loopback only, do not quote
      its `Mbit/s` as throughput); **UD QP creation fails**
      (`CREATE_QP BAD_ATTR`) and `rdma_cm` fails with it, since QP1 is a UD
      QP. NIXL/UCX don't need `rdma_cm` (they program QPs directly after
      exchanging metadata over their own side channel), so this likely
      doesn't block leg A over RDMA — but `UCX_TLS=ib` pulls in UD
      transports that will fail (HANDOFF §7.5). `UCX_IB_GID_INDEX=1`
      confirmed correct (the IPv4 RoCEv2 GID on every device). Left `[~]`:
      the UD/QP1 defect is real, unexplained, and should be raised with
      AMD. See 3.9 for what's still open.
- [x] **3.8** `00-preflight.sh` now asserts `ibv_devinfo` enumerates ≥1 RDMA
      device (previously only checked the binary existed) and surfaces
      libibverbs' `couldn't load driver` warning explicitly — that warning
      names the exact missing provider from 3.7's break 1 (HANDOFF §7.4)
      and would have made it self-diagnosing. `require_rdma_access` (1.9)
      already hard-gates in RDMA mode, satisfying that half independently.
      2026-09-16.
- [ ] **3.9** 🔴 **The sole remaining RDMA-stack blocker.** `UCX_TLS=ib`
      pulls in UD transports; UD QP creation fails outright on this
      driver/firmware (`Couldn't create QP`), and `rdma_cm` fails with it
      (HANDOFF §7.5). A firmware update that levelled 15/16 cards did NOT
      fix this — identical failure on old and new firmware alike, which
      disproves firmware skew as the cause (downgrades 3.10). Need to
      determine empirically which UCX transport spec works — likely naming
      RC explicitly instead of the `ib` alias — via `ucx_info -d` inside
      the container with `/dev/infiniband` mapped in (not yet done;
      `ucx_info` isn't installed on the bare host). **Do not simply edit
      invariant 6 to make this pass** — its exclusion of `tcp` must stay,
      so a half-working fabric fails loudly rather than reporting a good
      number over the wrong transport (HANDOFF §4 invariant 6). *3.6 is
      closed; this is the only thing gating 3.1.*
- [x] **3.10** DSC firmware differed between nodes (`smc1` `1.130.0-pi-121`
      vs `smc2` `1.130.0-a-120`) — not known to cause a problem by itself.
      **Firmware updated 2026-09-16, levelled to 15/16 cards** (`smc1`'s
      `ionic_0` held back) — and this DISPROVES firmware skew as 3.7 break
      2's cause: the one remaining old-firmware card fails with the
      identical `CREATE_QP BAD_ATTR` as every levelled card (HANDOFF §7.5).
      Downgraded from blocker to tidiness — level `smc1`'s `ionic_0` when
      convenient; nothing in Phase 2 waits on it. See 3.9.

---

## 4. Open items and known limitations

- [ ] **4.1** The target's Pollara serial console refused connection when last
      tried. Low priority — that leg is TCP-only.
- [ ] **4.2** No geometry manifest for stored KV objects: changing
      `KV_MAX_VALUE_SIZE` (or `--l1-align-bytes`) without draining yields
      silent half-stale reads. Mitigated by
      `scripts/target/50-reset-namespace.sh`, not solved.
- [ ] **4.3** uuid4-keyed objects have no restart survival or cross-process
      sharing. Only a content-derived key could cross processes, and no such
      path exists under `nixl_store` (see 6.21).
- [ ] **4.4** Watch Gerrit 27889 / 28298. Both are review-complete and tagged
      `26.09`; when they merge, drop the vendored `patches/spdk/0002` and `0003`
      and move `SPDK_TARGET_REF` to the release tag.
- [x] **4.5** ~~Connector-order experiment (`PD_LMCACHE_FIRST`)~~ —
      **obsolete, 2026-09-16.** There is no posture left to experiment with:
      `NixlConnector` is hardcoded as `connectors[0]` in
      `gen-kv-transfer-config.sh`, because letting LMCache go first would
      silently skip the P→D remote-prefill pull whenever the L2 tier has
      anything cached (HANDOFF §1).
- [ ] **4.6** `rocm-smi` prints `get_name, Error when calling libdrm` and an
      empty Marketing Name on both nodes — `libdrm-amdgpu1` (Ubuntu-packaged)
      vs ROCm 7.13.0/hsa-rocr 7.2.0 version mismatch. Believed harmless:
      `rocminfo` still correctly identifies `gfx942` via HSA/ROCr, which is
      what vLLM's device enumeration uses. Cosmetic; revisit only if
      something downstream reads `rocm-smi`'s Marketing Name field.

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

---

## 6. Storage-tier integration (XNVME_KV / SPDK_NVMe_KV as an LMCache tier)

*Done when a KV storage backend serves as a live LMCache tier underneath a
real P/D deployment, proven independently of the P→D leg.* See HANDOFF §1 for
why a KV backend can only ever be an LMCache storage tier, never
`NixlConnector`'s own transport, and HANDOFF §6.3 for the
container-vs-source-build decision.

- [x] **6.1** Decided the deployment model: the vendor container image
      (`rocm-aic:...`), not this repo's from-source build chain — the image
      already ships vLLM 0.26.0+rocm, LMCache 0.5.3, and prebuilt
      `libplugin_SPDK_NVMe_KV.so`/`libplugin_XNVME_KV.so`. The from-source
      path is deprioritized, not deleted; its patch provenance remains
      untested against what's baked into the image (HANDOFF §6.3).
      2026-09-15.
- [!] **6.2** This repo's own SPDK-vs-`master` build fails: `git am` cannot
      apply `patches/spdk/0002` against current master (2026-09-15). Parked,
      not resolved — superseded by 6.1's container-path decision, which
      doesn't depend on this build. Three options undecided: pin a
      compatible SHA, rebase the patches, or adopt the prebuilt tree as
      reference. Revisit only if the from-source path is revived.
- [x] **6.3** Decided the KV backend: kernel `nvme-of` + **XNVME_KV** (not
      SPDK_NVMe_KV) — unblocked once the compute nodes moved to kernel 6.8
      (closing the CSI-1 gap, 6.8). Proven end-to-end via 6.12. `KV_BACKEND`
      switch and backend-aware `KV_MAX_VALUE_SIZE_EFFECTIVE` already existed
      in `config/cluster.env`; SPDK_NVMe_KV stays available for comparison.
      Also fixed: device autodiscovery (`discover_kv_device()`) could
      silently pick a local Pensando DSC controller instead of the fabric
      target on a host with more than one KV-capable NVMe device —
      `resolve_xnvme_kv_dev()` now matches by `NVMF_SUBNQN` and dies on
      ambiguity. Default flip to XNVME_KV landed later, see 6.22.
- [x] **6.4** Target transport reports `max_io_size: 131072` (128 KiB), not
      the 16 MiB invariant 8's formula assumed — but the number that
      actually governs `KV_MAX_VALUE_SIZE` for XNVME_KV is the plugin's own
      per-value ceiling (32768 B, see 6.24). **Narrowed 2026-09-16:**
      irrelevant to the path this repo runs — the daemon's `--l2-adapter`
      tiles storage at `--l1-align-bytes` (4096 B default), not at the
      whole LMCache chunk, so `_resolve_mem_split()` always returns
      `mem_split_n=1` and splitting is currently DEAD CODE on the live
      path. Whether `--l1-align-bytes` should ever change, and what that
      would do to the split logic if it ever engages, is still an open,
      deferred question. HANDOFF §4 invariant 8.
- [x] **6.5** Kernel-upgrade sub-plan step 1 (install HWE kernel package) —
      superseded: the nodes were upgraded wholesale to Ubuntu
      24.04.5/kernel 6.8.0-139 instead, same practical outcome.
- [x] **6.6** amdgpu DKMS rebuild for 6.8 — confirmed built on both nodes as
      part of the OS upgrade, not a separate step.
- [x] **6.7** Stage reboots one node at a time — happened as part of the OS
      upgrade; both nodes came back on 24.04/6.8 with the amdgpu
      blacklist/ritual unchanged (0.4).
- [x] **6.8** Re-test that a KV namespace yields `/dev/ngXnY` (not
      `/dev/nvmeXnY`) on the new kernel. **PASSED 2026-09-15:** 5.15 logged
      `unknown csi 1 for nsid 1` and created no device node; 6.8.0-139
      creates the char device correctly. Closes the CSI-1 gap — the
      plugin header's claim was kernel-dependent, not simply wrong
      (HANDOFF §7.9).
- [x] **6.9** Kernel `nvme connect` is not persistent (no `--persistent`, no
      systemd unit) — confirmed does not survive a reboot. Reclassified as
      a known limitation with a documented per-boot workaround (HANDOFF
      §3.4) rather than open build work; automating it is optional future
      work.
- [~] **6.10** Compose the storage tier under P/D:
      `MultiConnector[NixlConnector, LMCacheMPConnector]` with the
      daemon-side `--l2-adapter` (XNVME_KV, `dev_uri` via
      `resolve_xnvme_kv_dev()`). **Implemented** (commits `c055f7d`,
      `0b75adb`): `start-lmcache-daemon.sh`/`stop-lmcache-daemon.sh`, wired
      into the role start scripts and gated by `start-vllm.sh`; validated
      against the installed LMCache parser and a live
      `get_plugin_params()` query. **Not done:** an actual live LMCache hit
      through this composed path — blocked purely on 6.21 (LMCache's own
      key-derivation scheme), not on 6.18 (`smc3` ownership, resolved
      per-session), 6.20 (decode instability), or any remaining code gap.
      See 6.21. HANDOFF §1.1.
- [x] **6.11** ✅ P→D direct NIXL transfer proven via this repo's own proxy
      — decode 0.0 tokens/s prompt throughput, 100% external prefix cache
      hit rate (4033-token prompt, per-run nonce). Two defects fixed: the
      proxy wasn't requesting the handoff (the XpYd handshake is three
      steps, not two — HANDOFF §7.10) and UCX was advertising an
      unroutable NIC (fixed via `PREFILL_PD_IF`/`DECODE_PD_IF`). Also
      found: `nixl_rocm._api.create_backend()` has no return statement and
      is always `None` — check `agent.backends[name]` instead. 2026-09-15.
- [x] **6.12** Proved the XNVME_KV backend itself (not through LMCache)
      does cross-process store/retrieve: two independent `docker run`
      processes, correct bytes back, correct `QUERY_MISS` on an unwritten
      key. Established the backend works; composing it under LMCache was
      left to 6.10. 2026-09-15.
- [!] **6.13** Generate/validate the LMCache YAML for the chosen backend —
      folded into 6.10 once the backend (XNVME_KV) and its real ceiling
      (32768 B, not 131072 or 16 MiB) were known. No standalone work
      remains.
- [x] **6.14** Proxy/router decision: this repo's own
      `scripts/proxy/disagg_proxy.py`, not the vendored
      `disagg_proxy_demo.py` — the vendored proxy cannot drive
      `NixlConnector` at all (never threads `kv_transfer_params`), see
      HANDOFF §7.10. `PD_HANDOFF_FIELD` = `kv_transfer_params`,
      load-bearing on both request and response sides.
- [!] **6.15** Cross-instance reuse measurement, not confounded by vLLM's
      own prefix cache or same-endpoint repeats — the number that actually
      demonstrates the KV backend is doing anything under live LMCache.
      Blocked on 6.21 (the composed hit itself doesn't exist yet) and 1.13
      (benchmark rework); do not start until both land.
- [!] **6.16** ~~Both 200G data-plane NICs on the target reported `Link
      detected: no`~~ — **superseded by 6.19:** the links are up now; the
      remaining gap is addressing/routing to `1.1.0.x`, not physical
      access.
- [x] **6.17** Reclaimed the redundant Qwen2.5-72B-Instruct copy in the hub
      cache (~135 GB/node) once `/var/tmp/hf/Qwen2.5-72B-Instruct` was
      confirmed as the sole bind-mount source (37/37 shards, 145.4 GB,
      index-matched). `smc1` now 336 GB free, `smc2` 253 GB. 2026-09-15.
- [!] **6.18** `smc3`'s KV target is SHARED and has been reconfigured by
      another party mid-session more than once — most recently our
      subsystem `nqn.2024-01.io.nixl:kv0`/`KvMalloc0` was replaced by
      `nqn.2016-06.io.spdk:cnode1` (2026-09-15), and `nvme connect` fails
      `Connection refused` until ownership is re-established. Do not
      restart another party's target unilaterally — agree ownership first.
      The local DSC (`/dev/ng1n1`) is **not** an escape hatch: it's the
      same namespace, re-exported (HANDOFF §7.3, confirmed by 6.25) —
      whoever else is on `smc3` is exactly as visible through it. *Blocks
      6.10/storage-tier work whenever ownership is unclear; check before
      every session (HANDOFF §3.2).*
- [ ] **6.19** Target's 200G links are UP (`enp132s0`/`enp100s0`, `Link
      detected: yes`, `enp132s0` holds `1.1.0.2/24`), reversing 6.16.
      Neither compute node has an address on `1.1.0.x` yet, so there's
      still no route to that listener — that's the remaining gap, and it's
      now actionable from a terminal (addressing/routing), not blocked on
      physical access.
- [!] **6.20** `smc2` (decode) is reboot-unstable — 7 boots in one day,
      cycling every 3–13 minutes at one point (2026-09-15), and both nodes
      have rebooted unexplained, repeatedly, since; `journalctl -b -1 -p
      err` shows no panic/MCE/OOM/thermal event for most of them. One
      instance is explained (an oversized per-worker
      `LMCACHE_MAX_LOCAL_CPU_SIZE`, HANDOFF §4 invariant 9); most are not.
      **Check `uptime` before starting anything that takes minutes.** Not
      diagnosable from a terminal alone if power/thermal/firmware — the
      BMC event log is next. See HANDOFF §7.13. *Blocks any long-running
      work on decode.*
- [ ] **6.21** 🔴 **The LMCache L2 retrieve blocker — the live blocker for
      6.10/6.15.** Never launch the vendor's `deploy-xnvme.sh` without
      overriding `AIC_XNVME_DEV` — its default `/dev/ng0n1` is the OS boot
      drive on both `smc1`/`smc2`, not a KV device; the real local
      Pensando DSC is `/dev/ng1n1` (HANDOFF §4 invariant 10). Always set
      `AIC_XNVME_DEV=/dev/ng1n1` explicitly.

      **The retrieve blocker itself, measured 2026-09-16/17 — live vLLM
      engines: store=36,864, retrieve=0, on both roles.**
      `nixl_store_l2_adapter.py` names every stored object
      `obj_{i}_{uuid4().hex[0:4]}`, a fresh `uuid4` drawn per daemon at
      startup. **This is not a uuid4 typo and not fixable by swapping in a
      content hash:** these names are PRE-REGISTERED POOL SLOTS, built
      once by `init_storage_handlers_object(page_size, num_pages)` at
      daemon startup, which never sees a content key at all — the
      content→slot map lives in an in-process dict that dies with the
      daemon. `pool_size` is required `>0`; there is no `pool_size=0`
      content-addressed escape hatch under `nixl_store`. Cross-node
      LMCache retrieve is therefore impossible by construction, regardless
      of device or topology — confirmed by 6.25's roundtrip proving the
      identical plugin/device/namespace supports cross-node store+retrieve
      directly, while the live engines' counters stayed unchanged
      alongside it. This is an LMCache patch to make, not an open-ended
      investigation. See HANDOFF §4 invariant 1, §2.

      **Separate, still-open question:** `retrieve_ops=0` on **prefill
      alone** (a same-daemon L1-eviction miss should force an L2
      read-back, needing no cross-daemon key agreement at all) is not
      explained by the uuid4 cause above and has not been investigated on
      its own. HANDOFF §2.
- [x] **6.22** `KV_BACKEND` default flipped `SPDK_NVMe_KV`→`XNVME_KV`
      (2026-09-16), matching 6.3's decision; `SPDK_NVMe_KV` stays wired for
      comparison (HANDOFF §1). Separately: the DSC wedges under sustained
      load — signature is `completions_err`/`stalls` in exact multiples of
      the 64-deep queue (e.g. `704 == 11×64`), worsening within a session
      up to a full first-store hang; only a DPU-side restart clears it,
      host-side resets make it worse. Cleared to `completions_err=0`/
      `stalls=0` after both nodes were rebooted 2026-09-17 — not proven
      immune to recurrence under the same load.
- [x] **6.26** The DSC NVMe controller has a boot-time race: the kernel
      probes it (`0000:36:00.0`) ~3 s after PCIe enumeration, before the
      DPU-side app is ready, gets `CSTS=0x0`/"Device not ready", detaches,
      and nothing re-probes it — `/dev/ng1n1` then stays absent. Not a dead
      card: the DSC's other PCI functions (`pds_core`, `ionic`) bind fine,
      config-space reads succeed, and the link is healthy. Recovery,
      validated repeatedly on both nodes, no reboot needed, once the DPU
      side is confirmed up:
      `echo -n "0000:36:00.0" > /sys/bus/pci/drivers/nvme/bind` (~2 min;
      fails identically if the DPU side isn't ready yet — just retry).
      Success looks like `nvme nvme1: 63/0/0 default/read/poll queues`
      then `block device for nsid 1 not supported (csi 1)` — the second
      line is EXPECTED. **Per the hardware owner, this is expected
      behavior, not a defect** — a documented per-boot procedure (HANDOFF
      §3.4), not an open bug.

### 6.23 The in-process `LMCacheConnectorV1` config surface is removed

Removed the dead in-process `LMCacheConnectorV1` config surface:
`gen-lmcache-config.sh`, `LMCACHE_CONFIG_FILE`, `LMCACHE_LOCAL_CPU`, and
`start-vllm.sh --skip-validate`. Verified dead — `LMCacheMPConnector` never
reads any of it; the live surface remains `start-lmcache-daemon.sh`'s
`--l2-adapter` flag, unmodified.

### 6.24 `XNVME_KV`'s device `value_max` moved 32768 → 4096 — CLOSED: the ceiling is 32768, not 4096

`XNVME_KV`'s device-reported `value_max` moved 32768→4096 underneath us
(shared-hardware drift). **Retracted the same day:** the advertised 4096 is
not the real ceiling — probed by storing single values at each size with
`NIXL_XNVME_KV_DEBUG=1`: 32768 → `ok=1 sct=0 sc=0` (PASS, reads back
cross-node); 33792/34816/36864/40960/49152/65536/131072 → `ok=0 sct=7 sc=234`
(FAIL, all of them). **32768 is the EXACT ceiling.** `KV_MAX_VALUE_SIZE_XNVME`
is reverted to 32768, the plugin was rebuilt on both nodes to match, and
`20-verify-nixl-plugin.sh` now passes 6/6 on both. The resulting startup
WARNING (configured value exceeds the advertised one) is expected and
correct — do not silence it by lowering the config, and do not set
`NIXL_KV_STRICT_DEVICE_CEILING=1`. See HANDOFF §2, §7.11, §4 invariant 4.

### 6.25 Cross-node store+retrieve PROVEN, both directions — the topology blocker is gone

`/dev/ng1n1` on both `smc1` and `smc2` is the SAME namespace: `nvme ns-descs`
returns identical `csi: 0x1` and `eui64 e46cfefeffcdae01` on both — each
node's own Pensando DSC is itself an NVMe-oF initiator peered to `smc3`, not
an independent local device. On a namespace confirmed clean beforehand
(`nuse: 0`), with keys derived from `(nonce, size)` via sha256 (neither side
sees the other's key directly):

| direction | size | parts | result |
|---|---|---|---|
| `smc1` write → `smc2` read | 24,576 B | 6 | `RESULT:OK` |
| `smc2` write → `smc1` read | 1,048,576 B | 256 | `RESULT:OK` |
| `smc1` write → `smc2` read, production geometry (32768 ceiling) | 196,608 B | 6 × 32768 | `RESULT:OK` |
| negative control: never-written nonce | — | — | `RESULT:QUERY_MISS`, non-zero exit |

This closes the topology question this project carried since day one — a KV
storage backend can be a shared, cross-node tier, proven directly rather than
inferred from matching `eui64`s. The remaining blocker was never topology: it
is 6.21, LMCache's own per-daemon key naming. HANDOFF §1, §2.

### 6.27 The DSC DOES report retrieve length in `cdw0` — ANSWERED

When the retrieve-length validation was added to `completion_trampoline()`
(`plugins/xnvme-kv/xnvme_kv_backend.cpp`), whether this DSC populates `cdw0`
with the retrieved value's length on Retrieve at all was an open
MUST-MEASURE. **Answered: yes.** Measured across a 6-part 196,608 B
cross-node read, every part reporting `len=32768 → cdw0=32768`. The
short-read guard is therefore live on this hardware, not a no-op; the
`cdw0==0` fallback stays in the code for devices that don't report a length.
HANDOFF §2.
