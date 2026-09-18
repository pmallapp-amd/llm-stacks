# TODO

Working task list. Last updated 2026-09-18.

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
| 6 | Storage-tier integration (XNVME_KV / SPDK_NVMe_KV as an LMCache tier) | 35 | 25 | 5 |

Counts are per **ID**, so §6's include its `###` subsections (6.23–6.35), not
just its checkbox bullets — a subsection counts as Done when its heading says
so (`✅`, CLOSED, ANSWERED, PROVEN). §6's row had drifted, reading 28/18: that
was correct through 6.28 and was never updated as 6.29–6.33 were appended.
**Recounted 2026-09-18: 6.34 flips to `✅`, one more than the row it
replaces.** Recount from the IDs when you add one.

**Read [HANDOFF §3](HANDOFF.md#3-how-to-resume) first** — it carries the
cluster state as handed over and the ordered resume plan. This file is the
task index.

**Before anything:** `uptime` on both compute nodes (6.20), confirm who owns
`smc3` right now (6.18), `modprobe amdgpu` (0.4 — needed every boot; it was
NOT loaded at the start of the 2026-09-18 session), and the LMCache MP daemon
must be up before `start-vllm.sh` will proceed (HANDOFF §1.1, §3.4).

**The storage tier now serves a cross-node hit — read 6.34.** 6.34's root
cause (the page and commit OBJ registrations were indistinguishable by
`(addr, len, devId)` and aliased, so every commit write landed on a *page*
key) is **fixed and verified**: `devId` is now allocated from a
daemon-global monotonic counter instead of restarting at the list position
on every call, and the page dlist is now deregistered immediately after
the page write is durable, before the commit registration is created.
Rung `60`'s acceptance run **step 5 PASSES for the first time**: a
genuinely cold decode node served content only prefill had ever computed
(`l2_device_hits=4`, token identity confirmed against the recompute
baseline). Both consequences of the old bug — the missing commit object
and the page-0 corruption — are independently confirmed fixed by direct
device inspection. 6.28 is closed end to end, pointing at 6.34. **What
remains:** step 7's negative control is unvalidated pending a namespace
drain (blocked — see 6.34's operational note), and 6.15 / 1.13 are the
natural next items now that the tier works. The adapter's design is
written down in
[docs/design/nixl-kv-l2-adapter.md](design/nixl-kv-l2-adapter.md) — do not
re-derive it.

**The composition is fixed, not configurable:** `MultiConnector[NixlConnector,
LMCacheMPConnector]`, `NixlConnector` hardcoded as `connectors[0]` — see
HANDOFF §1. This closed out 4.5's old connector-order question.

**Model running today:** `Qwen/Qwen3-8B`, `TP_SIZE=1` — **not**
`config/cluster.env`'s tracked default (`Qwen2.5-72B-Instruct`, TP=8). Every
throughput/latency figure in this file dated before 2026-09-16 predates that
switch and is not comparable to anything measured after it (HANDOFF §1).

**Storage tier, current state (2026-09-18): it serves a cross-node hit.**
This repo's replacement L2 adapter **`nixl_kv`** is written, unit-tested
(44/44, offline regression + mutation tested), deployed and registered on
both nodes, **proven cross-node byte-exact at the naming layer** (6.29,
rung `35`, 8/8 with three negative controls), and — new this session —
**proven at the engine level**: rung `60` step 5 PASSES, 9 of 11 checks
(the other 2 are step 7's negative control, VOID BY CONSTRUCTION under
`--no-drain`, not a fix failure). A genuinely cold decode node (container
recreated, writer's vLLM and daemon killed and removed) served content
only prefill had ever computed: `l2_device_hits=4`, `l2_index_hits=0`,
`l2_probe_errors=0`, `l2_load_aborts=0`, and TOKEN IDENTITY matched the
recompute baseline; negative control A (unseen nonce) also passed. **The
fault that blocked this (6.34) is fixed**: the page and commit OBJ
registrations no longer alias — `devId` is a daemon-global monotonic
counter, and the page dlist is deregistered before the commit registration
is created. Verified by direct device inspection on a fresh, post-fix key:
the commit object now exists (`<key>!c` HITs), and page `~0` now reads
back as real bf16 KV bytes, not commit-record JSON. 6.21's root cause (it
was always TWO blockers) is resolved end to end — HANDOFF §2.0. **What
remains:** step 7's control needs a namespace drain to validate, and that
drain is itself blocked (6.34's operational note); 6.15 and 1.13 are the
natural next items now that the tier works.

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
      **Scope narrowed 2026-09-18 (6.35):** this item is now only about the
      *engine-level* question. KV-BLOCK accounting (blocks stored/requested,
      hit rate, block size, store/read MB/s) is answered directly and with
      device-level cross-checks by `lmcache bench l2` via
      `scripts/bench/l2-block-bench.py` — that path never touches vLLM, so
      the prefix-cache confound this item exists to fix cannot apply to it.
      Do not rebuild block-level measurement on top of llama-benchy.
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
      As of 2026-09-17 those diffs are no longer carried as `.patch` files
      in this repo (verified present in the image, then deleted per the
      new policy — see `patches/lmcache/README.md`); `0011` is the one
      LMCache diff still carried here, because it's verified **absent**
      from the image. The from-source patch generator this item originally
      targeted is correctly withdrawn (that build path has never
      completed) and survives only in git history.
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
- [ ] **3.9** 🔴 **The sole remaining RDMA-stack blocker. SHARPENED
      2026-09-18 — the premise was wrong twice over.**

      **(a) The container never had RDMA access at all.** `container.sh`
      mapped only `/dev/kfd`, `/dev/dri` and the KV char device. The host
      showed 8 uverbs devices and a full RoCEv2 GID table (`VER v2`,
      IPv4 GID at index 1, `PORT_ACTIVE`, MTU 4096) while `ucx_info -d`
      **inside the container** enumerated only
      `cma/posix/rocm_copy/rocm_ipc/self/sysv/tcp` — no IB transport of
      any kind. UCX is built with verbs (`libuct_ib.so` present, the
      `HAVE_DECL_IBV_*` block is set); it simply had no device. **Every
      earlier in-container RDMA conclusion was therefore answering a
      different question than the serving path asks.** Fixed: `container.sh`
      now maps `/dev/infiniband` with `--ulimit memlock=-1` and
      `--cap-add IPC_LOCK`, and warns loudly when the host has no
      `/dev/infiniband` rather than silently producing a TCP-only container.

      **(b) There is no RC transport to narrow to.** This item previously
      proposed "naming RC explicitly instead of the `ib` alias". Measured
      after fix (a): `ucx_info -d -t rc_verbs` returns **0 transport/device
      pairs**, and `UCX_TLS=rc_verbs ucx_info -u t -d` falls through to
      `tcp` on the `benicN` interfaces. UCX never attempts RC on ionic at
      all. The only IB transport it offers is `ud_verbs`, on all 8 devices,
      and opening it fails on every one:

      ```
      ib_iface.c:1269 UCX ERROR ionic_N: iface failed to create UD QP
        TX wr:256 sge:6 inl:64 resp:0 RX wr:4096 sge:1 resp:0
        failed: Invalid argument
      ```

      Constraining the parameters named in that message
      (`UCX_IB_TX_MAX_SGE=1`, `UCX_UD_VERBS_TX_INLINE=0`) does **not** change
      the outcome. Note `ibv_rc_pingpong` works on the host (3.7), so the
      hardware does support RC queue pairs — UCX's `rc_verbs` iface needs
      more from the provider than pingpong does, and the ionic userspace
      provider does not satisfy it.

      **Consequence, stated plainly: P→D over RDMA RoCEv2 is NOT achievable
      on this stack today.** Not for want of configuration — UCX has no
      usable RDMA transport here. This is now a driver/provider issue to
      raise with AMD (the `ud_verbs` QP rejection and the absent `rc_verbs`
      support), not a UCX_TLS tuning exercise. Do not spend more time on
      transport-spec permutations until the provider exposes a working
      transport.

      *Original framing, retained for context:* `UCX_TLS=ib`
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

      **Drifted again, 2026-09-18** (§7.1/§3.5 pattern, recorded rather than
      chased): `pds_core` firmware now reads `1.130.0.a.129`, ionic driver
      `26.09.4.001` on both nodes — different from every value previously
      on record (`1.130.0-pi-121` / `1.130.0-a-120`). Not known to change
      anything in 3.9's UD-QP finding; recorded as the new current value.

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
      `get_plugin_params()` query. **DONE 2026-09-18:** the composed path
      served a live cross-node LMCache hit — rung `60` step 5,
      `l2_device_hits=4` on a cold reader with the writer killed (6.34).
      The old blocker cited here (6.21's `nixl_store` key derivation) was
      superseded by the `nixl_kv` adapter, and the fault that actually
      remained was 6.34's OBJ descriptor aliasing, now fixed.
      HANDOFF §1.1.
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
- [ ] **6.15** Cross-instance reuse measurement, not confounded by vLLM's
      own prefix cache or same-endpoint repeats — the number that actually
      demonstrates the KV backend is doing anything under live LMCache.
      **Unblocked 2026-09-18:** the composed hit now exists (6.34, rung
      `60` step 5), so the old "the hit itself doesn't exist yet" blocker
      is gone. Still gated on 1.13 (benchmark rework) for the figure to
      mean anything. This is now the natural next item.
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

      **Re-confirmed 2026-09-18: still shared, still not ours.** `smc3`'s
      `nvmf_tgt` (running since Wed Sep 16 22:33) serves only
      `nqn.2016-06.io.spdk:cnode1`, namespace `dev1_ns1` (a "KVMalloc disk")
      on listener TCP `1.1.0.2:4420` — our subsystem
      `nqn.2024-01.io.nixl:kv0` is absent, same as before. Despite that,
      `/dev/ng1n1` came up on both compute nodes this session with `csi
      0x1`, `nsze 0x200000` (1 GiB), and `eui64 e46cfefeffcdae01` —
      identical on both and matching the recorded value — and rungs 30/35
      both passed cross-node against it. **Open question, not yet
      answered:** where does our KV data physically live, given our NQN is
      absent from `smc3`'s target? The medium is shared and demonstrably
      working; we do not know which physical namespace it actually maps to.
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

      **RESTATED 2026-09-18 — this was always TWO blockers, and the one
      named above is the second.** Blocker 1: `nixl_store`'s lookup
      consults ONLY its in-process `_memory_objects` dict, so a daemon
      never asks the device about a key it did not store — every
      cross-daemon lookup misses *before naming is consulted*. Discovery
      is a MISSING OPERATION, not a wrong value; that is why restoring the
      plugin's `queryMem()` override correctly changed nothing. Blocker 2
      is the naming. Neither fix alone helps. HANDOFF §2.0, §7.14.

      **The "separate, still-open question" is ANSWERED and is NOT a bug.**
      `retrieve_ops=0` on prefill alone is caused by L1 never evicting, so
      L2 is never read back — measured:
      `Prefetch request completed (L1+L2): 4/4 retained keys (4 L1, 0 L2)`.
      **Consequence:** a correct implementation shows the same thing on a
      warm same-daemon path. Only a COLD READER proves anything.

      **Superseded by 6.28** — `nixl_store` is not being fixed; it is kept
      byte-identical as the A/B control (`LMCACHE_L2_ADAPTER_TYPE=nixl_store`)
      and `nixl_kv` replaces it.
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

      **Sharpened 2026-09-18: the retry is not deterministic on the first
      attempt.** Both nodes hit the identical `Device not ready; aborting
      initialisation, CSTS=0x0` signature at t=6.1s after a fresh reboot;
      the documented rebind failed twice with the same signature before
      succeeding on the third attempt, ~20 minutes after boot. Expect to
      retry over a span of minutes, not once — "just retry once it is
      [ready]" above understates it.

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

### 6.28 ✅ RESOLVED — the fault was 6.34's OBJ descriptor aliasing, not the LMCache→adapter seam; 6.34's fix closes it end to end

*Start here for how this was diagnosed, then 6.34 for the mechanism, the
fix, and its verification — rung `60` step 5 now PASSES on that fix,
which is the closing evidence for this item.* The design is written
([docs/design/nixl-kv-l2-adapter.md](design/nixl-kv-l2-adapter.md), including
§11's record of decisions taken where the spec was silent) — **do not
re-derive it**. **Diagnosed 2026-09-18:** rung `60` ran twice this session
(first without the attempt counters, then with them) and the combination
falsified the leading hypothesis below and isolated the real fault to the
adapter's commit-object write. 6.34 has since gone further and established
the exact mechanism (OBJ descriptor aliasing between the live page
registration and the commit registration) with direct debug-key evidence —
this item's diagnosis work is done; the counter values below are the
record of how it was reached.

**What was run (2026-09-18).** `scripts/verify/60-verify-l2-crossnode.sh`'s
sequence, executed step by step. All three maskers excluded structurally, not
by argument:

| Masker | Exclusion | Verified |
|---|---|---|
| vLLM's own prefix cache | decode container **recreated** | `L1 objects=0`, all counters 0 |
| P→D `NixlConnector` leg | prefill vLLM **and** daemon killed | prefill confirmed unreachable |
| L1 / in-process index | fresh daemon in fresh container | `stored_object_count=0` |

The test nonce was computed **only by prefill** (`l2_commit_writes` 4→8).

**Result:** `l2_device_hits=0`, `l2_index_hits=0`, `l2_probe_errors=0`,
`Avg prompt throughput: 108.3 tokens/s`,
`External prefix cache hit rate: 0.0%` — decode recomputed everything.
LMCache *was* consulted (connector live, reported 0.0%) and L1 was empty, so
the request should have reached the adapter's lookup and probed the device.

**Blocking sub-task — instrumentation. DONE, and RUN this session (see
below).** Landed in `overlays/lmcache/nixl_kv_l2_adapter.py`:
five attempt counters — `l2_lookup_calls`, `l2_lookup_keys`,
`l2_lookup_executions`, `l2_keys_probed`, `l2_probe_misses` — all exposed
via `report_status()` on the daemon's `:8080/status` alongside the existing
five outcome counters.

`l2_lookup_calls` is counted on the SYNCHRONOUS entry
(`submit_lookup_and_lock_task`), deliberately NOT inside the coroutine:
counting it in the coroutine would leave "LMCache never called lookup" and
"our event loop never ran the coroutine" indistinguishable, because
`asyncio.run_coroutine_threadsafe` swallows the latter. `l2_lookup_executions`
is the coroutine-side counterpart; a gap between the two IS the wedged-loop
signal.

Two one-shot INFO logs were also added: `FIRST DEVICE PROBE` (reader) and
`FIRST COMMIT WRITE` (writer), each naming the first commit key that daemon
probes/writes. Together they make the writer-vs-reader name comparison a
two-line grep across the two daemons' logs — see below for the run that
used it, and 6.34 for the comparison it produced.

How to read the combination (this is the reading the run below actually
produced):

- `calls==0` → the LMCache→adapter seam never called us; fault is ABOVE the
  adapter.
- `calls>0` & `executions==0` → wedged event loop.
- `keys_probed==0` & `calls>0` → everything short-circuited on the
  in-process index, device never asked.
- `probe_misses>0` → we probed and the device said absent — a
  naming/key-derivation divergence, NOT plumbing.

Offline coverage: `overlays/lmcache/test_nixl_kv_naming.py` is now **38/38**
(was 31); the 7 new tests are structural (`ast`-based), because the adapter
class sits behind the nixl/lmcache import guard and cannot be instantiated
on a control host. Mutation-tested: moving the `l2_lookup_calls` increment
into the coroutine, deleting a `report_status` key, and removing the
probe-name log call site were each caught by the tests meant to catch them.

**Both runs above happened this session.** The first (no counters) left
`l2_device_hits=0` undiagnosable; the second (counters live) resolved the
ambiguity on its first run: `l2_lookup_calls=1`, `l2_lookup_executions=1`,
`l2_keys_probed=4`, `l2_probe_misses=4` — lookup ran and the device said
ABSENT for every key. **This diagnosis is now closed** — the tier still
serves zero hits, but that fact is fully explained by 6.34, and the live
piece of work is 6.34's fix, not another run of this rung.

**That comparison has now been made — the hypothesis is FALSIFIED.** The
writer's and reader's one-shot logs name the identical commit key, byte for
byte (6.34 has the exact strings). `model_name`, `chunk_hash`,
`cache_salt`, `kv_rank`, and `object_group_id` all agree; naming divergence
between the two roles is not the cause and must not be re-investigated. The
`prefetch lookup_phase_count = 0` reading that once looked suggestive of a
naming split is superseded by this direct comparison.

**That check has now been done, and it clears the seam above the adapter.**
Rung `35` proves the naming scheme works cross-node byte-exact (6.29); the
attempt counters now additionally prove the LMCache→adapter lookup path
itself runs correctly end to end. The fault was inside the adapter, on the
STORE side — 6.34.

**Closing evidence, 2026-09-18.** 6.34's fix (monotonic `devId`, page dlist
deregistered before the commit registration is created) is landed and
verified. Rung `60` step 5 — the same acceptance sequence this item's
diagnosis was built on — **PASSES for the first time**: a cold decode node
served content only prefill had computed, `l2_device_hits=4`, token
identity confirmed. This item is resolved end to end, not just diagnosed;
6.34 carries the fix and the full verification chain (A/B/C).

### 6.29 ✅ `nixl_kv` — built, registered, and proven at the naming layer

- `overlays/lmcache/nixl_kv_l2_adapter.py` — content-addressed L2 adapter.
  Names: `{ns}@{object_key_string}~{ordinal}` per page plus a
  `{ns}@{object_key_string}!c` commit object written **only after every page
  is durable** (this medium has no `os.rename`; the commit record is the
  whole atomicity story). Lookup probes **only the commit key** — 1 Exist per
  ObjectKey instead of 9,216, i.e. 57 µs instead of 0.53 s per chunk.
- **Registration costs ZERO vendor-file edits**: `l2_adapters/__init__.py`
  auto-discovers any `*_l2_adapter.py` in the package dir via `pkgutil`, so
  the adapter is simply bind-mounted in (`container.sh adapter-overlay` /
  `adapter-check`). It also leaves `nixl_store` byte-identical as an A/B
  control.
- `ns` is a geometry fingerprint over
  `v1|MODEL|TP|CHUNK|KV_CACHE_DTYPE|align_bytes|max_value_size`, derived
  independently on both nodes (`d9dbd20693b2`). `ObjectKey` carries **no
  dtype and no KV-plane layout**, and patch `0009` exists because a plane
  mismatch corrupts silently at identical byte count — the prefix turns that
  class of divergence into an ordinary MISS.
- 31 offline unit tests, no NIXL/LMCache/hardware needed. **Mutation-tested**:
  reverting the probe check to truthiness, dropping the tile ordinal, and
  changing the key format were each caught by the specific tests meant to
  catch them.
- Rung `35` (`35-verify-nixl-kv-smoke.sh`): **8/8**, both directions, three
  negative controls. **Coverage gap, found 2026-09-18, closed 2026-09-18:**
  rung 35 writes its commit object through the raw NIXL agent path, one
  name registered at a time, and never held two overlapping OBJ
  registrations — so it could not have caught 6.34's aliasing bug, and
  structurally still can't: it is a naming-scheme proof, not a regression
  guard for that class of bug. The gap is closed by six new offline tests
  in `test_nixl_kv_naming.py` (44/44) that construct exactly two
  simultaneous, overlapping OBJ registrations and assert the second one's
  writes land under its own name — those tests, not rung 35, are what
  would catch a recurrence.
- **Known gap, deliberate:** namespace capacity is not enforced. 1 GiB /
  4096 = 262,144 pages ≈ **28 chunks ≈ 7,000 tokens** for this model, with no
  device delete primitive, so space is never reclaimed. This tier is
  *demonstrable*, not *usable*, at current sizing — raise with the hardware
  owner (relates to 6.18).

### 6.30 Patch `0011` was never in the image; its check could not fail

`0011` (the `num_external_tokens` guard on `LMCacheMPConnector`'s load path)
was **absent** from `rocm-aic:mp-pd-ionic2609`, and so was its sibling `0010`.
`patches/lmcache/README.md` claimed otherwise because its check grepped
`num_external_tokens`, which matches the *unpatched* signature and docstring.

This matters: we run `MultiConnector[NixlConnector, LMCacheMPConnector]`,
exactly the composition `0011` guards — without it a non-chosen sub-connector
creates a retrieve that must not happen and **leaks lookup locks**.

Now applied by `container.sh lmcache-patch`, derived from the image's own copy
with five self-invalidation guards (already-patched / line absent /
duplicated / wrong enclosing function / output not valid Python), all five
exercised. Resolved via `importlib.util.find_spec()` rather than a filesystem
`find`, because the module exists at three paths in the image and mounting
over a build-tree copy is a **silent no-op**. HANDOFF §2.2, §7.15.

### 6.31 `0006`–`0009` diffs deleted; the image is vanilla + three overlays

Verified in a **fresh container with no mounts**: `0006`/`0007`/`0008`/`0009`
are present in the image, which is itself vanilla (every layer
`docker build`/buildkit, no `docker commit`). Their `.patch` files were
deleted under a new policy — *if the vendor image ships it, this repo does not
carry the diff* — with sha256s recorded for identity-checking a copy recovered
from git history, and a rewritten, **discriminating** re-verification recipe.

Also recorded: what actually runs is the image **plus three bind-mount
overlays**, and one is load-bearing — **the image's own
`libplugin_XNVME_KV.so` has no `nixlXnvmeKvEngine::queryMem` override**, so
existence probing (and therefore all L2 discovery) exists only because the
repo-built plugin is mounted over it. HANDOFF §2.1, §7.16.

### 6.32 ✅ `60-verify-l2-crossnode.sh` — six defects found by running it; the rung now runs to completion

Written 2026-09-18 and exercised twice this session. The first exercise
(the manual run that produced 6.28's original result) had to work around
the first three defects below; the second (scripted, end to end) surfaced
three more before completing and producing 6.34's diagnosis. Each is the
"a check can fail while proving nothing" family (HANDOFF §7.12). All six
fixes have landed in the script, which now runs end to end (10/11 checks,
the one failure being 6.34):

1. **`role_down` did not actually stop the daemon** — measured:
   `pkill -f lmcache.v1.multiprocess.http_server` left it running (same pid
   before and after), so L1 and the in-process index stayed warm and the
   "cold reader" was not cold. `pkill -f api_server` kills vLLM fine — that
   asymmetry was the trap. **Fixed:** `role_down` now tears the container
   down via `container.sh down <role>` and then PROVES the daemon is gone by
   curling `:8080` over plain ssh, `die`ing if it still answers; `role_up`
   correspondingly `container.sh up`s first. Consequence worth recording:
   step 3's writer-unreachable check had to stop using `container.sh exec`,
   because with the container removed an exec-based curl would be
   vacuously "unreachable" regardless of actual state — a check that passes
   while proving nothing, the exact family this repo keeps hitting.
2. **`role_up` sent start output to `/dev/null`**, so a vLLM that starts and
   dies presents as a silent 600 s timeout — it cost a full diagnostic
   cycle. **Fixed:** `role_up` now captures the backgrounded start to
   `/tmp/60-acc-<role>-<nonce>.log` and prints the last 40 lines before
   `die`ing on timeout.
3. **Step 0's drain silently failed** (`50-reset-namespace.sh` non-zero from
   the control host) and the script only warned — a stale namespace can turn
   a real MISS into a spurious HIT. **Fixed:** step 0's drain failure is now
   FATAL. Step 7's stays a warning (a stale namespace there cannot manufacture
   a false PASS the way step 0's can) but now says the control is VOID.
4. **New:** step 5 now reads the five attempt counters and, when
   `l2_device_hits==0`, prints a self-diagnosing interpretation block, so a
   failing run does not cost another full cycle.
5. **`engine_gen()` declared a third parameter (`prompt`) it never read**,
   while all five call sites passed two — under `set -u` this killed the
   run on `"$3: unbound variable"` **after both models had already loaded**
   (~5 min in). **Fixed:** the stale parameter is removed; the prompt is
   read from a file on the node, not passed as an argument.
6. **The prompt was staged on the HOST's `/tmp` via `_ssh`, but
   `engine_gen` reads it INSIDE the container via `_in`.** The container
   does not share the host's `/tmp`, so staging wrote a file nothing ever
   read (`FileNotFoundError`, again ~5 min in). **Fixed:** `stage_prompt()`
   stages the prompt INSIDE the container.
7. **Compounding 6: `role_down` REMOVES the container**, destroying its
   `/tmp`, so anything staged before the cold-start sequence is gone by the
   time it is needed. **Fixed:** `stage_prompt()` is called after EVERY
   bring-up (initial, step 4, step 6, step 7), not once up front.

Defects 5–7 generalise as the same family already named above: a check
that fails while proving nothing, and a setup step whose vantage point
doesn't match its reader's.

**New capability: `--no-drain`.** `50-reset-namespace.sh` RESTARTS
`nvmf_tgt` on the shared target, which would destroy the other party's
RAM-backed namespace — forbidden by §3.2.2/6.18. `--no-drain` skips it with
a loud warning. **The soundness argument, stated honestly:** the drain is
defence-in-depth, NOT the soundness argument — soundness comes from the
per-run nonce (content, and therefore chunk hashes and ObjectKeys, unique
to each run) plus step 6's "unseen nonce must MISS" negative control, which
passed. **This session's run used `--no-drain`**, so step 7's negative
control was VOID and is reported as such.

**New: the rung harvests names before they're destroyed.** The writer's
`FIRST COMMIT WRITE` is captured in step 2, BEFORE step 3 destroys that
container, and the reader's `FIRST DEVICE PROBE` in step 5; the script
prints them side by side and branches on agree/differ. Harvesting late
would have been the same as not instrumenting at all.

Negative finding, recorded rather than fixed: the "nuse grows" assertion
this section previously described was searched for and **does not exist
anywhere in the repo** — only an accurate comment saying nuse is unusable
survives, in the script itself. That comment's warning stands: `nuse` does
not track KV writes on this device — measured `0x0` after 256+ pages stored
and read back. Use `l2_commit_writes`, or the plugin's `m_completions_ok`.

### 6.33 Move the value-size split into the plugin's `postXfer` (Option A)

`0007`'s `mem_split_n`/`#{j}` scheme splits oversized values **in LMCache**,
inside an image we cannot rebuild. The plugin is C++ we own and rebuild in
~2 minutes, it is the layer that knows the device ceiling, and GDS already
does exactly this internally — so the split arguably belongs in `postXfer()`,
which would delete `0007` and its hand-mirrored copy in `_kv_roundtrip.py`.

Not urgent: on the live path `page_size=4096 ≤ max_value_size=32768`, so
`_resolve_mem_split()` returns 1 and the split path is **dead code today**.

Four things it must own, or it just relocates the hazard:
1. **`queryMem` symmetry — a live bug if missed.** LMCache would register the
   *unsuffixed* name, so `make_key(metaInfo)` would name nothing on the
   device and every split object would report MISS.
2. **Retrieve-side part count** must be recorded, not inferred from the
   descriptor length.
3. **Partial-write atomicity gets worse**, not better — n sub-values with no
   commit record, each full-length, so the `cdw0` guard passes.
4. **Geometry drift** becomes invisible to Python.

Note the device allows a 16-byte key and `make_key()` emits 12 — the 4 spare
bytes can carry a part ordinal structurally instead of hashing it in.

### 6.34 ✅ FIXED and verified — OBJ descriptor aliasing between the live PAGE registration and the COMMIT registration is gone; the tier now serves a genuine cross-node hit

**Resolved 2026-09-18.** The mechanism below (established the same day with
direct debug-key evidence) is fixed by two changes in
`overlays/lmcache/nixl_kv_l2_adapter.py`, and both the missing-commit-object
and the page-corruption consequences are independently verified gone by
direct device inspection (Verification C, below). The diagnostic chain that
follows is kept in full — it is the record of how the fault was found and
is why the fix takes the shape it does.

Established 2026-09-18 with **direct evidence**, superseding the previous
"mechanism not yet isolated" framing. Method: daemon restarted with
`NIXL_XNVME_KV_DEBUG=1`, one generation driven through decode's own engine,
the plugin's per-op debug lines (`op=store key=<hex> len=<n> t=submit`)
analysed against independently predicted keys.

**Mechanism.** `NixlKvStorageAgent.register_obj_names()`
(`overlays/lmcache/nixl_kv_l2_adapter.py`) builds every OBJ descriptor as
`(addr=0, len=slot_size, devId=i, metaInfo=name)` — **every entry sits at
address 0**, distinguished only by `devId` = its position in that call's
name list. In `_execute_store_in_the_loop`, the PAGE registration (this
session: 36,864 entries, `devId` 0..36863, `addr=0`) is deregistered only
in the trailing `finally` — it is still **live** when the COMMIT
registration (4 entries, `devId` 0..3, `addr=0`) is created a few lines
later. The two OBJ registrations are therefore indistinguishable by
`(addr, len, devId)` for `devId` 0..3.

The plugin (`xnvme_kv_backend.cpp:1212`, `postXfer`) resolves object
identity from `file_desc.metadataP` (`nixlXnvmeKvMD::meta_info`) and calls
`make_key(devId, addr, meta_info, ...)`. The comment at that call site says
this exists so callers "don't collide on devId/addr alone" — but the guard
only works if `metadataP` resolves to the intended registration, and with
two live registrations sharing `(addr=0, devId=0..3)`, NIXL binds the
commit descriptors' `metadataP` to the still-live **PAGE** registration.
`make_key()` then hashes the **page's** name, not the commit's.

**Evidence:**

1. `make_key()` replicated in Python (FNV-1a 64 over `meta_info`, seeds
   `14695981039346656037` / `0x9E3779B97F4A7C15`, 8 bytes of `h1` LE + low
   4 bytes of `h2` LE = the 12-byte key) and **validated**: it predicts the
   exact keys appearing in the plugin's own debug output for page
   ordinals.
2. The predicted key for the commit name
   (`5571a49e2ab93c0865eaf3c6`, for commit name
   `d9dbd20693b2@Qwen/Qwen3-8B@01000100@0@ccf4461a92c0b745e0814642299dfcec0d5aa546010ba58bec152e10f158789f!c`)
   appears **zero** times in the debug log — the commit write is never
   submitted under its own key.
3. **36,868 store submits, all `len=4096`, but only 36,864 distinct
   keys.** Zero adapter store-task failures, zero exceptions, zero NIXL
   errors anywhere in the daemon log — nothing was raised.
4. The four doubly-submitted keys are exactly the predicted keys for page
   ordinals **0, 1, 2, 3** — matching `commit_indices = [0,1,2,3]` for the
   four commit objects in the batch. This is the aliasing, observed
   directly.
5. **Silent data corruption, confirmed by reading the page back.** Page
   `~0` of the object now contains the commit record, not KV bytes:
   `{"ns":"d9dbd20693b2","page_size":4096,"pages":9216,"phy_size":37748736,"v":1}`
   followed by NUL padding. Page `~5000` of the same object still holds
   intact bf16 KV data — the commit payload physically overwrote page 0.

**Severity — two consequences, and the second is worse than the one being
chased.**

1. The commit object never exists. Lookup probes ONLY the commit key
   (design §6 / 6.29), so every cross-node lookup misses even though
   ~100% of the pages are present and correctly named. This is the entire
   6.28 symptom.
2. Pages 0..N-1 of every stored object are silently overwritten with
   commit-record JSON. The data is WRONG, not merely unreachable.

Consequence 2 is currently **masked** by consequence 1 — because lookup
never hits, Load never runs, so the corrupted pages are never read back,
and the acceptance run's token-identity check passed regardless. **Anyone
who fixes the commit-key aliasing without also fixing the page overwrite
will turn a tier that serves nothing into a tier that serves CORRUPTED
KV.**

**Why rung `35` stayed green — sharpened.** `scripts/verify/_nixl_kv_smoke.py`'s
`_xfer()` registers ONE object name, transfers, and deregisters it in a
`finally` — exactly one OBJ registration is ever live. It structurally
cannot produce two overlapping registrations and therefore cannot
reproduce this bug, no matter how thoroughly the naming scheme is
exercised. A regression test for this must hold **two simultaneous,
overlapping OBJ registrations** whose descriptors share `(addr, len,
devId)`, then assert the second registration's writes land under its OWN
names, not the first's. Testing the naming scheme alone will never catch
it.

**Fix taken.** Of the three directions once listed here, the one landed is
the ordering change (deregister the page dlist before the commit dlist is
registered) *plus* the deeper/defensive option (stop deriving OBJ identity
from `(addr=0, devId=index)` at all) — together, not either alone, because
the deeper fix is what makes the guarantee hold across `submit_store_task`'s
concurrent, awaiting coroutines, not just within one call:

1. **`register_obj_names()` now draws `devId` from a daemon-global
   monotonic counter** (`self._next_devid`, under `self._devid_lock`), used
   in both the `reg_list` and `xfer_desc` comprehensions, instead of
   restarting at the call's list position `i` every time. Any two
   simultaneously-live OBJ registrations are therefore disjoint by
   construction — covering both the within-store page/commit overlap this
   item found and the cross-task overlap possible because
   `submit_store_task` schedules concurrent coroutines that await.
2. **The page dlist is now deregistered immediately after the page write is
   confirmed durable, before the commit registration is created** —
   `page_reg_descs`/`page_xfer_handler` are cleared to `None` so the
   trailing `finally` does not double-deregister. Defence in depth: exactly
   one OBJ registration is live across that boundary. `post_non_blocking`
   raises on `ERR`, so durability is already confirmed at that point — the
   design's commit-after-durable ordering (design §6 Store) is preserved,
   not weakened.

`devId` does not affect the device key when `metaInfo` is non-empty
(`make_key()` hashes the name), and `query_exists()` passes `metaInfo`
directly without registering — neither path is affected by the widened
`devId` range.

**Verification (2026-09-18, post-fix).**

**A — Offline, `overlays/lmcache/test_nixl_kv_naming.py`: 44/44** (was 38).
Six new tests target this bug specifically: structural checks on the
monotonic-counter shape plus a behavioural test that constructs two
simultaneous, overlapping OBJ registrations and asserts the second one's
writes land under its own name — exactly what §6.34's "why rung 35 stayed
green" note above said a regression test would need to hold. Mutation-tested:
reverting `register_obj_names` to positional `devId`, moving the early
deregistration to after the commit registration, and deleting the
`page_xfer_handler = None` clear were each caught by exactly the test meant
to catch it, no collateral failures.

**B — Rung `60`, the acceptance run: step 5 PASSES for the first time.** A
genuinely cold decode node (container recreated, counters confirmed at
zero) with the writer's vLLM **and** daemon killed and its container
removed (port confirmed unreachable) served content only prefill had ever
computed: `l2_device_hits=4`, `l2_index_hits=0`, `l2_probe_errors=0`,
`l2_load_aborts=0`, and TOKEN IDENTITY matched the recompute baseline.
Negative control A passed: an unseen nonce produced no new device hits (4
→ 4). Overall **9 of 11** checks passed; the 2 failures are both step 7's
negative control, which is **VOID BY CONSTRUCTION** — this run used
`--no-drain`, so step 2's commit object is legitimately still on the
device, and "a drained namespace yields no device hit" cannot hold under
that condition. The script itself flags the control as void; this is not a
partial failure of the fix. Soundness note: the run used a per-run nonce
(`acc-<epoch>-<pid>`), so its chunk hashes and ObjectKeys are unique to
this run and no object left by a previous run could have satisfied it —
negative control A independently confirms unseen content misses.

**C — Both consequences verified fixed by direct device inspection**, on a
fresh key from a post-fix generation
(`...@28f6a7846aca5715f44b4c4a8606ff3e8ee00121c0fd649fa61f5fedd4a19ffb`):
the commit object now EXISTS (probing `<key>!c` returns HIT — it was MISS
before the fix), and page `~0` now reads back as real bf16 KV bytes
(`\xa3\xc00@\x10@\x1d@...`), not the commit-record JSON it held before the
fix. The silent corruption is gone.

**Operational note — the namespace still holds pre-fix corruption, and
draining it is blocked.** Objects written by PRE-FIX runs still have
commit-record JSON in place of KV bytes at pages 0..N-1. They are keyed by
old per-run nonces, so nothing will ever read them, but they are dead
weight in a 1 GiB namespace with no delete primitive (6.29's capacity
gap), and they will persist until a drain happens.
`scripts/target/50-reset-namespace.sh` **refused to run this session**: it
reports
"kv-target is not running — nothing to reset", because the live `nvmf_tgt`
on the target was not started by this repo's scripts — it is the
long-running process serving `nqn.2016-06.io.spdk:cnode1` (6.18), which
appears to be what actually backs the working `/dev/ng1n1` on both compute
nodes. Draining therefore requires either killing and replacing that
target with this repo's own (`03-start-kv-target.sh`) or an RPC-level bdev
recreate against the one already running — both risk dropping the DSC/DPU
peering that currently makes `/dev/ng1n1` work, and DSC recovery is known
to be non-deterministic and slow (6.26). **This is the open decision
blocking step 7's validation** — record it as such, do not attempt a drain
without deciding it first.

### 6.35 ✅ KV-block-level measurement exists and is PROVEN — via `lmcache bench l2`, unblocked by an upstream L1-indexing defect

**Measured 2026-09-18 on `smc2` (decode), against `nixl_kv`/`XNVME_KV`
on `/dev/ng1n1`.** This answers the "how many KV blocks, what hit rate,
what block size, what store/read bandwidth" question directly, at the L2
adapter — **no vLLM, no proxy, no TTFT anywhere in the number.**

**The tool.** LMCache 0.5.3 ships `lmcache bench l2`
(`lmcache/cli/commands/bench/l2_adapter_bench/`). It drives an L2 adapter
through its real `submit_store_task`/`submit_lookup_and_lock_task`/
`submit_load_task` interface using the same `--l2-adapter '<JSON>'` spec
`start-lmcache-daemon.sh` already builds, and reports per operation:
total keys, total success, **actual hit rate**, MB/s avg/min/max, ops/s,
per-key latency, p50/p99. Upstream also ships `benchmarks/storage_backend_io`
and `benchmarks/microbenchmark`.

**Blocker found, and it is UPSTREAM, not ours.** `lmcache bench l2`
cannot drive *any* NIXL-backed L2 adapter as shipped:

```
makeXferReq: local index out of range at index 0 with value 340075
nixl_rocm._bindings.nixlInvalidParamError: NIXL_ERR_INVALID_PARAM
```

`NixlStorageAgent.init_mem_handlers()` builds the L1 transfer dlist
**base-relative** (entry `i` is `buffer_ptr + i*page_size`), but
`NixlStorageAgent.get_memory_indices()` returns an **absolute** page
number, `raw_addr // l1_align_bytes`, with no base subtracted. The two
agree only when `buffer_ptr == 0`. Measured with the benchmark's own
buffer: `ptr=665980928`, 32 dlist entries, absolute index `162593`
(out of range) vs correct relative index `0`.

**Confirmed upstream, not a `nixl_kv` regression:** the untouched vendor
`nixl_store` fails on the identical line with the identical error and
`Total success: 0`. `nixl_kv` inherits `get_memory_indices` unchanged.

**Fix used, deliberately process-local:** `scripts/bench/l2-block-bench.py`
patches the vendor base class **in the benchmark process only** to be
base-relative, and range-checks the result so an out-of-bounds index
raises instead of silently landing on the wrong page. The adapter file on
disk and the running daemon are untouched. Round-trip verification
(`--no-skip-verify`) passes byte-exact at every block size, which is
independent evidence that base-relative is the correct reading.

**🔴 OPEN QUESTION — is production silently mis-indexed?** The live MP
daemon uses the same absolute arithmetic (`L1MemoryDesc.ptr =
buffer.data_ptr()`, a real pointer — `l1_memory_manager.py:213`). It does
not crash only because the production L1 buffer is 4 GiB (1,048,576 dlist
entries), so `addr // 4096` lands *in range* — but shifted by
`ptr // 4096`. In-range-but-wrong is exactly the silent class this repo
keeps hitting (HANDOFF §5, 6.34). Rung `60`'s token-identity pass argues
against actual corruption, so this is **not** an assertion of a
production bug — it is an untested hypothesis that needs its own decisive
test (store a known pattern, read it back by direct device inspection at
a known offset) **before** anyone changes `get_memory_indices` on the
serving path.

**Results — adapter level** (32 keys/round, 3 measured rounds + 1 warmup,
`--l1-align-bytes 4096`, one namespace per point, all ops 96/96 success,
round-trip verified):

| block | pages/key | device ops | store MB/s | load MB/s | store ms | load ms |
|---|---|---|---|---|---|---|
| 16 KB | 4 | 160 | 12.2 | 10.0 | 41.1 | 53.4 |
| 64 KB | 16 | 544 | 40.0 | 36.5 | 55.3 | 57.9 |
| 256 KB | 64 | 2080 | 119.5 | 136.1 | 67.3 | 59.0 |

Per-key latency is nearly flat (1.29 → 2.10 ms) while bandwidth scales
~10x, so this regime is dominated by **per-key/per-batch fixed overhead,
not device bandwidth**.

**Concurrency is the lever, not queue count** (256 KB/key):

| queues | in-flight | store MB/s | load MB/s | peak_in_flight | submit_retry |
|---|---|---|---|---|---|
| 1 | 1 | 119.5 | 136.1 | 64 | 2,159,089 |
| 8 | 1 | 115.4 | 109.8 | 512 | 7,151,168 |
| 8 | 4 | **279.0** | **340.5** | 512 | 37,812,606 |

Raising `NIXL_XNVME_NUM_QUEUES` alone does nothing (the producer is
serialized); raising in-flight submits gives 2.3–2.5x. Note
`submit_retry` is ~568 retries per completed op — the reactor busy-spins
on `-EBUSY` backpressure. **That, not the device, is where the time goes**
and it is the obvious next optimization target.

**Hit rate, measured on a genuine cold reader** (fresh process, empty
in-process index, so every probe reaches the device). Positive and
negative control both clean:

| requested | keys | hits | hit rate | us/key |
|---|---|---|---|---|
| `--lookup-max-hit-rate 1.0` | 96 | 96 | **1.00** | 69–90 |
| `--lookup-max-hit-rate 0.0` | 96 | 0 | **0.00** | 70–88 |

Device probe (KV Exist) costs ~70–90 µs/key and **hit and miss cost the
same** — there is no short-circuit on either. The warm in-process index
serves the same lookup at ~3 µs/key, i.e. the commit-key index is worth
~25x on a repeat.

**Device-level cross-check** — the plugin's own counters
(`NIXL_KV_METRICS_PATH`) reconcile exactly with the adapter-level
predictions, which is what makes the numbers above trustworthy rather
than merely plausible:

| block | predicted ops `(pages+1)*32*4` | `store_ops` | `retrieve_ops` | `store_bytes` | err | stalls |
|---|---|---|---|---|---|---|
| 16 KB | 640 | 640 | 640 | 2,621,440 | 0 | 0 |
| 64 KB | 2176 | 2176 | 2176 | 8,912,896 | 0 | 0 |
| 256 KB | 8320 | 8320 | 8320 | 34,078,720 | 0 | 0 |

`store_bytes == store_ops * 4096` exactly; `retrieve_ops == store_ops`
(load reads back every page plus the commit object). `completions_err=0`,
`submit_fail=0`, `stalls=0` throughout — no DSC wedge (6.22) at this load.
`retrieve_len_checked == retrieve_ops` with `unreported=0`, independently
re-confirming 6.27 (this DSC does populate `cdw0` on every Retrieve).

**Why this supersedes the llama-benchy path for this question.** 1.13's
confound (vLLM's own prefix cache sitting upstream of every connector)
does not exist here at all — this never goes through vLLM. 1.13 and 6.15
remain the right tools for the *engine-level* question; they are not the
right tool for KV-block accounting.
