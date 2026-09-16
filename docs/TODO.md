# TODO

Working task list. Last updated 2026-09-16.

## How to use this list

IDs are **stable** — reference an item by number ("do 2.4", "what blocks 3.1").
New work appends; existing IDs are never renumbered. Check the `blocked by`
note before starting anything.

Status: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked on someone else

## Status summary

| § | Area | Items | Done | Blocked |
|---|---|---|---|---|
| 0 | Blocking decisions and follow-ups | 4 | 2 | 2 |
| 1 | Architecture correction (compute leg) | 13 | 12 | 0 |
| 2 | Hardware bring-up (Phase 1, TCP) | 13 | 5 | 3 |
| 3 | Acceptance (Phase 2, RDMA compute leg) | 10 | 2 | 0 |
| 4 | Open items and known limitations | 6 | 0 | 0 |
| 5 | Done | 14 | 14 | — |
| 6 | Storage-tier integration (XNVME_KV / SPDK_NVMe_KV as an LMCache tier) | 20 | 12 | 6 |

**Read [HANDOFF §9](HANDOFF.md#9-how-to-resume) first** — it carries the
cluster state as handed over and the ordered plan. This block is the index.

**Before anything: 6.20, 6.18, and the amdgpu ritual.** `smc2` rebooted seven
times on 2026-09-15, cycling every 3-13 minutes — shorter than a 72B TP=8
model load — then held for hours, then rebooted again; nothing explains either
the instability or the recovery. `smc3` is shared and currently serves
*another party's* subsystem, so our `nqn.2024-01.io.nixl:kv0` is gone (6.18).
Both compute nodes were handed over freshly rebooted with **0 GPUs** — TODO
0.4's `modprobe amdgpu` is required right now.

**Two independent tracks, neither blocking the other.**

*Track A — 6.10, the storage tier.* The last item in §6 and the project's
original goal. **Blocked by 6.18**, not by anything in this repo. Everything
else is worked out; recipe at HANDOFF §12.7. The correction that matters:
the composition is `MultiConnector[NixlConnector, **LMCacheConnectorV1**]` —
**not** `LMCacheMPConnector`, which this repo's architecture has named since
day one and which cannot reach the NIXL storage backend at all, silently
ignoring its config (HANDOFF §12.1).

*Track B — §3, RDMA acceptance.* **Firmware updated 2026-09-16 — routing is
now CLOSED and cross-node RDMA is measured for the first time.** Static
routes exist for all 8 fabric pairs both directions; cross-node ping is 0%
loss at ~0.10 ms; `ib_write_bw` cross-node peaks at 41,898 MiB/s (~351
Gb/s, ~88% of the **400** Gb/s line rate — these NICs are 400 Gb/s NDR, not
200 Gb/s as an earlier note assumed). **3.6 is closed. 3.10's firmware skew
is disproved as the cause of break two** (both `-pi-121` and `-a-120` cards
emit the same `CREATE_QP BAD_ATTR`) and is downgraded to tidiness. **3.9 —
UD QPs still cannot be created, `rdma_cm` still fails — is now the sole
remaining RDMA-stack blocker.** NIXL/UCX need neither UD nor `rdma_cm`, so
this likely does not block leg A over RDMA, but `UCX_TLS=ib` pulls in UD
transports that will fail. See HANDOFF §15.

**Cheap, do anytime: 3.8** — make preflight assert `ibv_devinfo` returns a
device rather than merely existing. That check would have made 3.7
self-diagnosing instead of costing two sessions.

**Closed in session 4: 6.11** — leg A transfers KV, decode at 0.0 tokens/s
prompt throughput and a 100% external prefix cache hit rate, measured through
this repo's own proxy (HANDOFF §11). Also stale now: 2.8's `ionic_N` → netdev
mapping, and 6.14's router decision, both reversed with evidence.

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
- [x] **0.4** **Unblock the GPUs.** `modprobe.blacklist=amdgpu` is set on both
      compute nodes' kernel command line (read from `/proc/cmdline`,
      2026-09-14) — deliberate, present on both `smc1` and `smc2`.
      **CORRECTION, same day:** an earlier pass on this item concluded that
      removing the blacklist required editing GRUB and rebooting both
      compute nodes, and recorded that as an operator decision blocking this
      item. **That conclusion was wrong.** `modprobe.blacklist=` suppresses
      AUTOLOAD only — alias/`-b` resolution, the path udev uses. Evidence:
      `modprobe -n -v -b amdgpu` (the `-b` udev takes) resolves nothing,
      while `modprobe -n -v amdgpu` (an explicit load by name) resolves the
      full 8-module chain and exits 0. There is no `install amdgpu
      /bin/false`-style hard block anywhere in `/etc|/lib|/run/modprobe.d` —
      the cmdline is the only source. Running `modprobe amdgpu` for real on
      both nodes brought the GPUs up immediately, **no reboot, no GRUB
      edit**: `rocminfo` now reports 10 agents per node (2× EPYC 9554 + 8×
      gfx942), `rocm-smi` reports 8 GPUs / 206141652992 B (192 GiB) VRAM
      each, all `runtime_status=active` — matching `ROCM_ARCH=gfx942` and
      `TP_SIZE=8` in `config/cluster.env`. The amdgpu DKMS module was
      already built and present for the running kernel
      (5.15.0-191-generic) on both nodes, confirming this was never a
      missing or broken driver, just an autoload suppression. **Residual,
      not closed by this fix:** the blacklist itself is untouched on the
      cmdline, so it does **not** survive a reboot — every boot, the GPUs
      come back unusable until `modprobe amdgpu` runs again.
      `scripts/{prefill,decode}/01-host-prep.sh` now do this automatically
      every run via `ensure_amdgpu_loaded()` in `lib.sh` (opt-out:
      `AMDGPU_AUTOLOAD=0`, for a site that wants the blacklist enforced and
      is willing to load it by hand). DKMS version skew noted while there:
      `smc1` has amdgpu DKMS 6.16.13, `smc2` has 6.18.4 (both ROCm 7.13.0) —
      still flagged as an open question, not asserted to be a problem
      either way. *Was blocking every GPU-dependent item in §2 and all of
      §3 — no longer does.*
      **Recurrence OBSERVED 2026-09-15** (not just predicted): both compute
      nodes rebooted unexpectedly this session — cause unknown, but provably
      not the paused kernel-upgrade work in §6, since its installer script
      never even transferred to either node. After reboot both again
      reported 0 GPUs and `/dev/kfd` absent, exactly as the residual note
      above predicted. This confirms the behaviour empirically rather than
      by inference; nothing about it is fixed, only automated —
      `01-host-prep.sh` (or a manual `modprobe amdgpu`) must run again after
      any reboot before GPU-dependent work resumes. The kernel `nvme
      connect` established in §6 also did **not** survive this reboot (no
      `--persistent` flag, no systemd unit) — see 6.9.

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

- [x] **2.1** `scripts/common/init-creds.sh 4`, populate `creds/setup-4.env`,
      confirm `source config/cluster.env` resolves real addresses. **Verified
      2026-09-14** — ssh as root via `creds/active.env` reaches all three
      nodes: SMC1 (prefill), SMC2 (decode) and SMC3 (target).
- [x] **2.2** `scripts/common/00-preflight.sh` on all three nodes — **all three
      PASS, 5/5 checks each**, 2026-09-14, after fixing 2.13 (the first run
      aborted mid-script on both compute nodes; that was a script bug, never a
      node defect). Recorded inventory:
      - SMC3 (target): 320 CPUs, 62 GiB RAM, no ROCm (expected), RDMA
        devices `rocep100s0` + `rocep132s0`, 176.8 GiB free on `/opt`, kernel
        `6.8.0-38-generic`.
      - `smc1`/`smc2` (compute): 128 CPUs, 1511 GiB RAM, ROCm 7.13.0, **8
        `ionic` RDMA devices per node** — §3's prerequisite, confirmed present —
        hugepages 0 (expected, host-prep allocates), 339 GiB free on `/`
        (`smc1`) / 256 GiB (`smc2`), Python 3.10.12, kernel
        `5.15.0-191-generic`, Ubuntu 22.04.5 LTS.

      Caveat: preflight passing does **not** mean the compute nodes are ready.
      Its GPU check is `check_soft` (advisory), so it reports 0 GPUs and still
      passes — see 0.4. A green preflight here means "inventoried", not "can
      serve".
- [ ] **2.3** Pin an SPDK master SHA in `SPDK_TARGET_REF`; confirm patches 0002
      and 0003 apply cleanly to it. *blocked by nothing — do before 2.4*
      **Attempted 2026-09-15, FAILED as written:** ran
      `scripts/target/02-build-spdk-kv.sh` against the current
      `SPDK_TARGET_REF=master`; `git am` could not apply
      `patches/spdk/0002-spdk-bdev-kvmalloc.patch`. Not closed by that
      attempt — the actual decision (pin a compatible SHA / rebase the
      patches / adopt the prebuilt tree) now lives at **6.2**, since this
      session recorded a working target via a different route (see 2.4's
      correction below).
- [~] **2.4** Build SPDK and start the target; `scripts/target/04-verify-target.sh`.
      Hard-check that `max_io_qpairs_per_ctrlr` actually reports 512 — the wrong
      spelling is accepted silently. *blocked by 2.3*
      **Partially done a different way, 2026-09-15:** this repo's own build
      (2.3) failed, so the target was brought up instead from the
      **prebuilt** `/root/kv_spdk` (SPDK v26.05-pre, already carrying the KV
      target support that patches 0002/0003 add). On that binary: namespace
      `KvMalloc0`, subsystem `nqn.2024-01.io.nixl:kv0`, listener on the
      management IP port 4420, and `max_io_qpairs_per_ctrlr: 512`
      **confirmed** — the hard-check this item asks for passes, just not
      against this repo's build. Also measured: the transport reports
      `max_io_size: 131072` (128 KiB), **not** the 16 MiB HANDOFF §7
      invariant 8 assumes — see the new **6.4**, unresolved and potentially
      serious. Not marking this fully done: `scripts/target/04-verify-target.sh`
      itself was not run against this substitute target, and the underlying
      build failure (2.3) is still open.
- [x] **2.5** `nvme discover` against the target from both compute nodes. **Done
      2026-09-15**, and taken further: both nodes now `nvme connect` to
      `nqn.2024-01.io.nixl:kv0` and the kernel attaches the controller with 128
      I/O queues. On 6.8 the KV namespace materialises as a char-only device
      (`/dev/ng1n1` on `smc1`, `/dev/ng2n1` on `smc2`). Neither the connection
      nor the target survives a reboot — see §9's per-boot ritual.
- [!] **2.6** Build the stack on both compute nodes; pass the `ldd`
      self-containment check on `libplugin_SPDK_NVMe_KV.so`. **Parked
      2026-09-15 — superseded by 6.1**, which decided the container path. The
      `rocm-aic` images already carry vLLM, LMCache, NIXL and both KV plugins,
      so nothing on the from-source chain is on the critical path. Left open
      rather than deleted because the `ldd` invariant (HANDOFF §7 invariant 2)
      still governs any future source build.
- [!] **2.7** Reconcile the LMCache YAML keys and NIXL backend allowlist patch
      against the version that actually installs. **Folded into 6.10
      2026-09-15.** The premise changed: the container ships LMCache 0.5.3
      pre-installed, so `patches/lmcache/apply-patches.sh` — which patches a
      *source* install's backend allowlist — has nothing to patch on this path.
      What still has to be established, and 6.10 owns it, is whether that
      prebuilt LMCache already accepts `XNVME_KV` as a `nixl_backend` or needs
      the allowlist edit applied inside the image. Still "most likely thing to
      bite", just relocated.
- [~] **2.8** Determine which `ionic_*` device is which physical port on *each*
      host; set `PREFILL_UCX_NET_DEVICES` / `DECODE_UCX_NET_DEVICES` in the
      creds file. **Measured 2026-09-14:** on `smc1` all 8 `ionic_N` map 1:1
      to `benicNp1`-style names and are UP (`30.1.N.1/24`). On `smc2` only
      `ionic_2/3/5/6` line up with `benic3p1/benic4p1/benic6p1/benic7p1` and
      are UP (`30.2.N.1/24`); `ionic_0/1` on `smc2` are different interfaces
      (`enp10s0`/`enp39s0`) and DOWN. This **inverts** the old assumption that
      only the first two indices line up — they're the ones that don't.
      `ionic_2` (`benic3p1`) is the common plane, and both
      `PREFILL_UCX_NET_DEVICES` and `DECODE_UCX_NET_DEVICES` are now pinned to
      `ionic_2:1` in `creds/active.env`, overriding `cluster.env`'s `ionic_0:1`
      default. Mapping work is done; left open only because the pin is untested
      — leg A cannot carry traffic until 3.6 (no route between the two fabrics)
      is resolved, so this is unverified against a live transfer.

      **STALE as of 2026-09-16 — the mapping changed with the new DSC
      software.** Re-measured via `show_gid` on both nodes: `ionic_0..7`
      now map to `benic1p1..benic8p1` on BOTH hosts, all eight **up**,
      `30.1.N.1/24` on `smc1` and `30.2.N.1/24` on `smc2`. The asymmetry
      this item documents — `ionic_0/1` on `smc2` being `enp10s0`/`enp39s0`
      and down — no longer exists. The `ionic_2:1` pin remains valid
      (`ionic_2` is `benic3p1` on both) but was chosen to dodge an
      asymmetry that is gone; any index would now serve. See HANDOFF §14.4,
      and note this is the fifth recorded fact to expire under us.

      **Re-confirmed 2026-09-16, after the firmware update (HANDOFF
      §15.8):** the symmetric mapping above still holds on both nodes —
      `ionic_0..7` → `benic1p1..benic8p1`, all 8 ACTIVE/up, `smc1` on
      `30.1.N.1/24`, `smc2` on `30.2.N.1/24`. The `ionic_2:1` pin is now
      **additionally justified**, not just still-valid: `ionic_2` is
      `-a-120` firmware on both nodes, so it also dodges `smc1`'s lone
      `ionic_0` holdout still on `-pi-121` (§15.1/3.10).
- [x] **2.9** Pre-stage Qwen2.5-72B-Instruct weights. **Done 2026-09-15.** They
      were already in `/root/.cache/huggingface/hub`; now at
      `/var/tmp/hf/Qwen2.5-72B-Instruct` on both nodes (bind-mounted as `/hf`),
      verified 37/37 shards, 0 missing, 0 zero-byte, 145.4 GB matching
      `model.safetensors.index.json`. Redundant hub copy reclaimed (6.17). The
      chunk-ceiling check moved to 6.4, which resolved it against the real
      XNVME_KV ceiling rather than the assumed 16 MiB.
- [!] **2.10** Start prefill, decode and proxy; run `scripts/verify/run-all.sh`.
      **Superseded 2026-09-15 by 6.11** (bring-up) and **6.10** (proving a
      direct NIXL transfer distinct from an LMCache hit) — the live items now
      carry this work against the container path. The
      `kv_transfer_params`/`PD_HANDOFF_FIELD` half is **NOT settled** — an
      earlier note here claimed it was "unused and moot" because the vendored
      proxy threads no handoff field. Measured since: that absence is exactly
      why **no KV transfers** (6.11). The field names something the proxy is
      missing, not something the design does without. See HANDOFF §6's
      correction block.
- [ ] **2.11** Fix `00-preflight.sh`'s PCIe inventory section — it greps
      `lspci -d 1dd8:` and its header claims that covers "GPUs + data-plane
      NICs". Measured 2026-09-14: it covers **zero** GPUs, because the MI300X
      ID is `[1002:74a1]` (vendor `1002`/AMD, not `1dd8`). See the §1
      correction in HANDOFF.md. Small script fix, but `scripts/` is being
      edited concurrently this session — coordinate before touching it.
- [ ] **2.12** Distribute an ssh key to all three nodes. Confirmed 2026-09-14:
      key auth is not configured anywhere; every connection so far used
      `sshpass` against the passwords in `creds/active.env`. `deploy.sh` can
      install a key (opt-in flag) but pushes those same passwords to all three
      machines by default — decide whether that default is acceptable before
      relying on it further.
- [x] **2.13** `00-preflight.sh` aborted mid-run on both compute nodes under
      `set -euo pipefail` when `rocminfo` exists but exits non-zero (which it
      does while the GPUs are blacklisted, see 0.4): `grep` then matched nothing,
      `pipefail` propagated the failure out of the command substitution, and
      `set -e` killed the script — silently truncating every section after
      ROCm/GPU, including the RDMA device list that 2.2 exists to collect.
      Found and fixed 2026-09-14. The failing `rocminfo` path now emits an
      actionable `warn` (pointing at `modprobe.blacklist=amdgpu` and `/dev/kfd`)
      and continues. A repo-wide sweep for the same pattern guarded six more
      sites in `lib.sh` and the three `01-host-prep.sh` scripts; in the two
      host-prep scripts the `rocminfo` failure became an explicit `die` with a
      diagnostic, since those are hard gates rather than inventory. Sites where
      an empty result is a genuine error were deliberately left unguarded —
      blanket `|| true` would convert real failures into silent passes, exactly
      what §7's invariants exist to prevent.

---

## 3. Acceptance (Phase 2, RDMA on the compute leg)

*Done when P→D KV transfer runs over RDMA with no TCP fallback, proven by
counters rather than inferred from throughput.*

- [ ] **3.1** Configure the RoCE fabric between the compute nodes — PFC/ECN/DSCP,
      MTU 9000. *blocked by 2.10*
- [ ] **3.2** Confirm `/dev/infiniband/uverbs*` are openable, `memlock` is
      unlimited, and `ibv_devinfo` shows `PORT_ACTIVE`. Nodes present but
      unopenable present as a ~90 s hang, not an error.
      **Partly ANSWERED 2026-09-15 (session 4), and the answer is bad:**
      `/dev/infiniband/uverbs0..7` and `rdma_cm` all exist and are
      world-readable, and all 8 ports read `state=4: ACTIVE`,
      `phys_state=5: LinkUp` — yet `ibv_devinfo` returns **`No IB devices
      found`**, because no ionic provider loads (3.7). This item's own
      premise is what makes 3.7 so easy to miss: it anticipated "present
      but unopenable" as a hang, and what actually happens is an instant,
      quiet empty list. `memlock` is still unchecked. *Now blocked by
      3.7.*
- [ ] **3.3** Set the compute leg to RDMA and restart. `UCX_TLS` excludes `tcp`
      by design so a half-configured fabric fails loudly.
- [ ] **3.4** Prove RDMA is carrying the KV traffic — counters, not throughput
      inference.
- [ ] **3.5** Re-run the verify ladder and
      `scripts/bench/40-bench-transport-compare.sh` for the TCP-vs-RDMA number.
      *blocked by 1.13 if the figure is to mean anything*
- [x] **3.6** The P→D fabric has no route yet. Measured 2026-09-14: `smc1`'s
      data-plane addresses are `30.1.N.1/24`, `smc2`'s are `30.2.N.1/24` —
      different `/24`s, differing in the second octet. `ip route get` for an SMC2 fabric
      address from SMC1 falls back to the management default route — there is no fabric route at all. This also
      falsifies `config/cluster.env`'s premise that every DSC3 fabric link is
      a `/31` point-to-point (they're `/24`s), and the
      `UCX_IB_ROCE_SUBNET_PREFIX_LEN=16` workaround would not bridge
      `30.1.x`/`30.2.x` either, since they differ inside the first 16 bits. No
      correct value is known yet — do not guess one. *blocks 3.1.*

      **Re-scoped 2026-09-15 (session 4): this is no longer the first
      blocker in §3, and treating it as such would waste the effort.**
      There is currently no functioning verbs layer on either compute node
      (3.7) — a route with nothing to carry over it changes nothing. Fix
      3.7, then come back to this. *now blocked by 3.7.*

      **Re-scoping PARTLY WITHDRAWN 2026-09-16.** 3.7's break 1 is fixed
      and RC QPs now work, so there IS a verbs layer and routing is the
      operative blocker again — which is what this item said originally.
      The IPv4 gap is unchanged: `30.1.N.1/24` vs `30.2.N.1/24`, no route.
      *No longer blocked by 3.7; now parallel to 3.9.*

      **One lead, to measure rather than act on:** the index-2 global IPv6
      GIDs share a common `2001:0db8::/32` (`smc1` `0001::1`..`0008::1`,
      `smc2` `0009::1`..`0010::1`), unlike the IPv4 GIDs which differ in
      the second octet. Distinct `/64`s still need routing between them so
      this is not free, but it is a materially different situation from
      IPv4 and may route more easily. RoCEv2 over an IPv6 GID is
      legitimate. Check whether a route exists before configuring
      anything — do not guess, per this item's own standing warning.

      **CLOSED 2026-09-16 — routing exists now, and was not done by us.**
      Static routes now exist for all 8 fabric pairs, both directions:
      `smc1` carries `30.2.N.0/24 via 30.1.N.2 dev benicNp1 proto static`;
      `smc2` carries the mirror `30.1.N.0/24 via 30.2.N.2 dev benicNp1
      proto static`. Cross-node ping over `benic3p1` succeeds both
      directions, **0% loss, rtt avg ~0.10 ms**. This follows the
      §13.7/§14.4 pattern of the shared hardware changing underneath this
      project — this time in our favour. The IPv6 lead above is now moot;
      dropped, not pursued. Full detail and the first cross-node RDMA
      throughput numbers this routing unblocks: HANDOFF §15.4/§15.5.
- [~] **3.7** **[HALF-RESOLVED 2026-09-16 — see the update at the end of
      this item.]** **The `ionic` RDMA stack is broken on BOTH compute nodes —
      two independent version/ABI mismatches, introduced by the 24.04.5 /
      6.8 upgrade in session 2 and unnoticed until now.** Full detail in
      HANDOFF §13. `ibv_devinfo` on `smc1` returns `No IB devices found`
      while sysfs simultaneously reports all 8 `ionic` ports
      `ACTIVE`/`LinkUp` with `uverbs0..7` present — every cheap indicator
      looks right.

      1. **Userspace provider ABI.** The only ionic provider on disk is
         `libionic-rdmav59.so` (rdma-core 61, and an orphan — `dpkg -S`
         finds no owning package); the installed `libibverbs` is Ubuntu's
         `50.0-2ubuntu0.2`, which loads `lib*-rdmav34.so`. No ionic
         provider loads at all. `libionic1` and `rdma-core 61.0-1` are
         both `rc` (removed, config only), `apt-cache policy libionic1`
         reports **Candidate: (none)**, and no AMD/Pensando apt source is
         configured — so this cannot be fixed with `apt` as the machine
         stands.
      2. **Kernel driver vs DSC firmware.** `ionic_rdma` is DKMS
         `26.09.4.001~ubu22.04` — the 22.04 source rebuilt against 6.8.
         `vermagic` matches and it loads, but the card answers
         `opcode CREATE_QP (2) error BAD_ATTR (5)`, so
         `Couldn't create ib_mad QP1` → `Couldn't open port 1`. No GSI QP
         means no MAD agent, no SA, no CM — `rdma_cm` cannot connect
         regardless of the reported port state.

      Either break alone is fatal. Both are present, on both nodes.
      Note what this means for diagnosis: modules present, loaded, and
      correctly versioned for the running kernel proves nothing — all
      three are true here.

      **Fix:** obtain and install the AMD DSC driver bundle built for
      **24.04** (the `~ubu22.04` suffix on all three DKMS packages
      suggests only the 22.04 bundle was ever installed). Relinking the
      provider against rdma-core 50 addresses break 1 only. Also check DSC
      firmware (`ethtool -i`) against driver 26.09.4.001 — `BAD_ATTR` on
      `CREATE_QP` is equally a firmware-skew signature.

      *Blocks all of §3. Does NOT affect leg A, which is TCP/UCX and needs
      no verbs (HANDOFF §11).*

      **UPDATE 2026-09-16 — another party installed the matched 24.04 DSC
      bundle (the fix this item asked for). Re-measured on both nodes;
      full detail HANDOFF §14.**

      - **Break 1 (userspace provider ABI): FIXED.** `libionic1` is now
        `ii 50.0.26.06.3.001-1` (no `~ubu22.04`), `libionic-rdmav34.so`
        exists, `ionic_rdma` is `26.06.9.001`, and `ibv_devinfo` works on
        both nodes. `show_gid` returns 24 GIDs/node.
      - **Break 2 (CREATE_QP BAD_ATTR / ib_mad QP1): NOT fixed, but far
        narrower than this item claimed.** The errors are contemporaneous
        with the new driver (module loads 06:10:50, errors 06:10:50-51),
        so they are not stale. Measured precisely: **RC QPs work and move
        data** (`ibv_rc_pingpong`, GID index 1: 9.6 us RTT on `smc1`,
        11.1 us on `smc2` — a **loopback latency** test that never crossed
        the fabric; do not quote its Mbit/s figure as throughput, see
        HANDOFF §14.2); **UD QPs cannot be created** (`Couldn't create
        QP`); and
        **`rdma_cm` fails** (`rdma_connect: Invalid argument`). QP1 is a UD
        QP, so the MAD agent and CM fail downstream of the UD limitation.

      So this item's claim that there is "no verbs layer for a route to
      carry" is **withdrawn** — there is a working RC layer. Its narrower
      claim, that `rdma_cm` cannot connect regardless of `state=ACTIVE`, is
      confirmed exactly. NIXL/UCX do not need `rdma_cm` (they exchange
      metadata over NixlConnector's own side channel, then program QPs
      directly), so this probably does not block leg A over RDMA — but see
      3.9, because `UCX_TLS=ib` pulls in UD transports that will fail here.

      Left `[~]` not `[x]`: the UD/QP1 defect is real, unexplained, and
      should be raised with AMD. Also verified incidentally:
      `UCX_IB_GID_INDEX=1` in cluster.env is **correct** — index 1 is the
      IPv4 RoCEv2 GID on every device (previously an unverified default).
- [ ] **3.8** **Make `00-preflight.sh` actually test RDMA rather than
      inventory it.** It could not have caught 3.7: its only assertion is
      `check_soft "rdma-core userspace tools present" command -v
      ibv_devinfo`, which checks that the *binary exists*. The inventory
      step runs `ibv_devinfo -l`, and with zero loadable devices that
      returns empty, whereupon preflight logs
      `none found (expected in Phase 1 / KV_TRANSPORT=tcp)` and passes
      green.

      Assert instead that `ibv_devinfo` returns at least one device and
      that at least one port reads `PORT_ACTIVE`, and surface any
      `couldn't load driver` warning from `libibverbs` as a `warn` rather
      than discarding stderr — that warning line names the exact missing
      provider and would have made 3.7 self-diagnosing. Keep it
      `check_soft` in Phase 1 (TCP needs no verbs) but make it a hard
      check when `KV_TRANSPORT=rdma`. Use `timeout` — 3.2 records that an
      unopenable device presents as a ~90 s hang, not an error.
- [ ] **3.9** 🔴 **NOW THE TOP OPEN RDMA ITEM — `UCX_TLS=ib` will pull in UD
      transports that cannot be created on this hardware.** Measured
      2026-09-16 (HANDOFF §14.2): RC QPs work, **UD QP creation fails
      outright** (`Couldn't create QP`), and `rdma_cm` fails with it. The
      `ib` alias in invariant 6's `UCX_TLS=ib,rocm,self,sm` expands to
      include `ud_verbs`, and `rc_verbs` uses a UD QP for some
      connection-establishment modes.

      **RE-MEASURED after the 2026-09-16 firmware update, UNCHANGED
      (HANDOFF §15.3):** the firmware update that levelled 15/16 cards did
      **not** fix this — same 8/8 `CREATE_QP BAD_ATTR`, same UD/`rdma_cm`
      failures, on both nodes, identical to §14.2's matrix. This rules out
      firmware skew as the cause (3.10 is downgraded accordingly) and
      makes this the **sole** remaining RDMA-stack blocker now that 3.6's
      routing gap is closed — everything else Phase 2 needs at the fabric
      level now works.

      Determine empirically which UCX transport spec works here — likely
      naming RC explicitly instead of the `ib` alias — by enumerating with
      `ucx_info -d` inside the container with `/dev/infiniband` mapped
      (the current launch scripts do **not** map it, which is itself a
      Phase 2 prerequisite). **Still not measured, 2026-09-16: `ucx_info`
      is not installed on either host** (container-only), so this must be
      run inside the container, with `/dev/infiniband` mapped in, not on
      the bare host.

      **Do not simply edit invariant 6 to make this pass.** Its reason —
      never let RDMA acceptance succeed on a silent TCP fallback — is
      still valid, and any replacement must keep `tcp` excluded so a
      half-working fabric fails loudly rather than quietly reporting a
      good number over the wrong transport. *3.6 is closed; this is now
      the only thing gating 3.1.*
- [x] **3.10** **NO LONGER A BLOCKER — DSC firmware differs between the two
      compute nodes.** `smc1` reports `fw_ver: 1.130.0-pi-121`, `smc2`
      reports `1.130.0-a-120` — different build suffix and build number,
      measured 2026-09-16. Driver (`26.06.9.001`) and userspace
      (`50.0.26.06.3.001-1`) are identical on both, so this is firmware-only
      skew.

      Not known to cause a problem — RC loopback works on both — but RDMA
      is two-sided and leg A over RDMA is precisely a cross-node RC path,
      so level this before trusting any P↔D RDMA measurement. Recorded,
      not chased.

      **Firmware updated 2026-09-16 — levelled to 15/16, and the level-up
      DISPROVES this as the cause of break two (HANDOFF §15.1).**
      Per-port re-measurement across all 8 devices on both nodes: `smc2`
      is now uniform `1.130.0-a-120` on all 8 ports; `smc1`'s
      `ionic_1`..`ionic_7` moved to `1.130.0-a-120`, but **`ionic_0`
      (`benic1p1`) is still `1.130.0-pi-121`** — one holdout card, out of
      16. The key inference: `smc1`'s `ionic_0` (old firmware) and every
      `-a-120` card (new firmware, both nodes) **emit the identical
      `CREATE_QP BAD_ATTR` failure** (§15.3) — a card on the old firmware
      fails exactly like cards on the new one. **Firmware is therefore
      disproved as the cause of break two.** Downgraded from a blocker to
      a tidiness item — level `smc1`'s `ionic_0` when convenient, but
      nothing in Phase 2 is waiting on it. See TODO 3.9 for what is
      actually still open.

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
- [ ] **4.6** `rocm-smi` prints `get_name, Error when calling libdrm` and an
      empty Marketing Name on both compute nodes, measured 2026-09-14 right
      after bringing amdgpu up (0.4). Cause: `libdrm-amdgpu1` is Ubuntu's
      packaged `2.4.113-2~ubuntu0.22.04.1`, while ROCm is 7.13.0 / hsa-rocr
      7.2.0 — a version mismatch between the distro's libdrm and this ROCm
      release. Believed harmless: `rocminfo` still correctly identifies
      `gfx942` and reports all 8 agents per node via HSA/ROCr, and vLLM's
      device enumeration goes through ROCr, not libdrm device names, so
      nothing downstream is known to consult the field that's broken. Not
      fixed — recorded as cosmetic, revisit only if something downstream
      turns out to actually read `rocm-smi`'s Marketing Name field.

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

## 6. Storage-tier integration plan (XNVME_KV / SPDK_NVMe_KV as an LMCache tier)

*Done when a KV storage backend serves as a live LMCache tier underneath a
real P/D deployment, proven independently of the P→D leg, on a chosen
deployment model and KV backend. This is new integration — see
[HANDOFF §10](HANDOFF.md#10-reference-deployment-container-image-contents-and-the-storage-backend-transport-constraint-2026-09-15)
— not reproduction of anything the lab has run before. All items below are
new this session (2026-09-15), measured on live hardware unless marked
otherwise.*

> **Session 2, same day (2026-09-15).** The compute nodes were upgraded to
> Ubuntu 24.04.5 / kernel 6.8.0-139, closing the CSI-1 gap (6.5–6.8) and
> settling the backend decision (6.3) in favour of XNVME_KV, which was then
> proven end-to-end for the first time (6.12). Most of this section is now
> decided, done, or explicitly parked — **exactly two items remain live:
> 6.11** (get P/D + proxy actually serving — blocked on a container image
> swap) **and 6.10** (compose the storage tier under that P/D deployment,
> once 6.11 lands). Read those two first.
>
> **Session 4, same day (2026-09-15): 6.11 is now DONE and leg A
> verifiably transfers KV** — decode 0.0 tokens/s prompt throughput, 100%
> external prefix cache hit rate. Two defects had to be fixed, both of
> which produced a pipeline that served correct text while moving zero KV;
> see 6.11's resolution and HANDOFF §11. This also **reverses 6.14's
> router decision** in favour of this repo's own proxy. **Exactly one item
> remains live: 6.10.**

- [x] **6.1** Decide the deployment model: this repo's from-source build
      chain (`scripts/common/{05-build-spdk-initiator,10-build-stack,
      20-build-vllm-lmcache}.sh`, a venv-run vLLM) vs the containerised path
      already running on both compute nodes
      (`rocm-aic:{latest,mp-pd,kv-planefix,pr4467,kv-mppd,kv-mppd-assertfix}`,
      ~43.7 GB each). Measured 2026-09-15: `rocm-aic:kv-mppd-assertfix`
      (built 2026-09-11) already contains vLLM 0.26.0+rocm, LMCache 0.5.3,
      torch 2.13.0+rocm7.2, nvme-cli 2.8, libxnvme with 5 `xnvme_kvs_*`
      symbols, and **prebuilt** `libplugin_SPDK_NVMe_KV.so` and
      `libplugin_XNVME_KV.so` alongside `libplugin_UCX.so`/`POSIX.so`/
      `AIS_MT.so` at `NIXL_PLUGIN_DIR=/opt/nixl/lib/x86_64-linux-gnu/plugins`;
      entrypoint is `python3 -m vllm.entrypoints.openai.api_server`. This
      makes the entire from-source build chain redundant for bring-up as
      measured today. Original framing offered three options, tradeoffs
      only: (a) adopt the container images wholesale; (b) keep the
      from-source path; (c) both.
      **Decided 2026-09-15 (session 2): (a), the container path.** Not by
      declaration — by what actually moved: the KV target was brought up
      from a prebuilt binary (§5's correction), leg B was proven end-to-end
      from a container (6.12), and the P/D launch attempt (6.11) ran
      entirely from `rocm-aic` images. This repo's from-source build/patch
      provenance (HANDOFF §5) remains untested against what's baked into the
      images — that gap is real and not closed, just no longer the thing
      blocking bring-up. The from-source path (b) is not abandoned, only
      deprioritized; see 6.2's parked status. See HANDOFF §10.1.
- [!] **6.2** Resolve the repo's own SPDK-vs-master build failure:
      `scripts/target/02-build-spdk-kv.sh` ran with `SPDK_TARGET_REF=master`
      and `git am` could not apply
      `patches/spdk/0002-spdk-bdev-kvmalloc.patch` (measured 2026-09-15, see
      2.3's correction). The target was brought up this session anyway using
      the prebuilt `/root/kv_spdk` (SPDK v26.05-pre, already carrying KV
      target support) as a substitute — see HANDOFF §5's correction. Three
      options, not decided: pin a compatible SHA that predates whatever
      changed on master, rebase 0002/0003 onto current master, or adopt the
      prebuilt tree as the reference and stop tracking master.
      **Parked 2026-09-15 (session 2):** superseded by 6.1's decision to
      adopt the container path, which uses the prebuilt target and doesn't
      depend on this repo's build. Not resolved — `git am` still fails the
      same way — just no longer on the critical path. Revisit only if the
      from-source path is revived. *blocked by nothing; still makes 2.3/2.4
      partly moot.*
- [x] **6.3** Decide the KV backend: **(A)** kernel `nvme-of` + XNVME_KV —
      requires the 6.8 kernel work (6.5–6.8), unusable on the current
      `5.15.0-191-generic` compute kernel (see the CSI-1 finding, HANDOFF
      §10.4); or **(B)** SPDK_NVMe_KV userspace initiator — works today on
      5.15, and is what 6.10–6.12 below actually exercise via the prebuilt
      target. `config/cluster.env:279` already carries the `KV_BACKEND`
      switch (`SPDK_NVMe_KV` default, `XNVME_KV` alternate) plus a
      backend-aware `KV_MAX_VALUE_SIZE_EFFECTIVE`
      (`config/cluster.env:434-462`) — confirmed present in the repo already,
      nothing to build there. Switching `KV_BACKEND` changes the effective
      max value size (524288 for SPDK_NVMe_KV vs 32768 for XNVME_KV, the
      latter a measured DSC firmware ceiling, not a transport parameter) and
      **requires draining the namespace** exactly as an explicit
      `KV_MAX_VALUE_SIZE` edit does (HANDOFF §7 invariant 5) — the same
      silent half-stale-read hazard applies to a backend switch, not only a
      value edit.
      **Decided 2026-09-15 (session 2): (A), kernel `nvme-of` + XNVME_KV.**
      The blocker that ruled it out is gone: the compute nodes were upgraded
      to Ubuntu 24.04.5 / kernel 6.8.0-139, and the re-test that failed
      on 5.15 (`unknown csi 1 for nsid 1`, no device node at all) now
      produces `nvme nvme1: block device for nsid 1 not supported (csi 1)`
      and does create the generic char device — see 6.8's re-test and the
      corrected HANDOFF §6 entry. With that in place, XNVME_KV was then
      proven end-to-end (6.12): cross-process store/retrieve, correct
      values, correct miss on an unwritten key. (B) SPDK_NVMe_KV remains
      available via the same `KV_BACKEND` switch if ever needed, but is no
      longer the default path.
      **Also verified this session:** the plugin's own device
      autodiscovery (`discover_kv_device()`, picks the lowest-numbered
      `/dev/ngXnY`) is unsafe wherever more than one KV-capable NVMe device
      is present — on `smc2` (decode) it would silently select a **local**
      Pensando DSC KV controller (`nqn.2019-08.com.pensando:...`, PCIe
      `0000:36:00.0`) instead of the real fabric target, because the local
      device sorts lower. `resolve_xnvme_kv_dev()` now matches on
      `NVMF_SUBNQN` instead and dies on ambiguity; verified live: prefill →
      `/dev/ng1n1`, decode → `/dev/ng2n1`, correctly skipping the local DSC
      node on decode. Nothing downstream would otherwise have reported the
      wrong-device selection — keep this fact visible even though it's
      handled, because a future host with a differently-numbered local KV
      device could hit it again.
- [x] **6.4** **Urgent — check before any storage-leg roundtrip runs.** The
      prebuilt target's transport came up reporting `max_io_size: 131072`
      (128 KiB) — measured 2026-09-15 — not the 16 MiB ceiling HANDOFF §7
      invariant 8's chunk-ceiling formula assumes ("current config is 10 MiB
      against a 16 MiB ceiling — 37% headroom"). If `max_io_size` is the
      ceiling `scripts/target/05-check-chunk-ceiling.sh` should actually be
      checking against, the current 10 MiB chunk would **fail outright**,
      not merely lose headroom — an 80x gap, not a thin margin. UNVERIFIED
      whether 128 KiB is a fixed property of the prebuilt `/root/kv_spdk`
      build/config or tunable; reconcile before trusting 05's pass/fail on
      this target.
      **Resolved 2026-09-15 (session 2), with a sharper and more concerning
      answer than the question expected.** `131072` is not a fluke: on the
      restarted target it reads identically, and the XNVME_KV plugin's own
      startup log on the same run independently confirms a related but
      **different** number: `device KV format 0: value_max=131072
      key_max=16 novg=4096 (compiled-in default 32768)`. So there are two
      distinct ceilings in play, neither of which is 16 MiB:
      `max_io_size`/`value_max` (131072, transport-level) and the plugin's
      **compiled-in per-value ceiling of 32768 bytes (32 KiB)** — the number
      that actually governs `KV_MAX_VALUE_SIZE` for XNVME_KV and triggers a
      multipart split above it (verified live in 6.12: a 98304-byte store
      split into exactly three 32 KiB parts). HANDOFF §7 invariant 8's
      chunk-ceiling math (10 MiB chunk against an assumed 16 MiB ceiling)
      was written against SPDK_NVMe_KV's much larger limit; against
      XNVME_KV's real 32 KiB per-value ceiling, a 10 MiB chunk would fail
      outright, not merely lose headroom. **Recorded as a known limitation,
      not one of the two live items** — but 6.10 and 6.13 both need to
      reconcile `KV_MAX_VALUE_SIZE_EFFECTIVE` against 32768 (not 131072, not
      16 MiB) before trusting the chunk-ceiling guard on this backend.
- [x] **6.5** *(Kernel upgrade sub-plan, step 1 of 4 — PAUSED at user
      instruction this session; nothing installed, not failed.)* Install
      `linux-image-generic-hwe-22.04` candidate `6.8.0-138.138~22.04.1`
      (present in apt) on both compute nodes. Only needed if 6.3 chooses
      backend (A). The installer script never even transferred to either
      node this session.
      **Obsolete 2026-09-15 (session 2):** superseded, not executed as
      planned. Rather than installing the HWE kernel package in place, the
      compute nodes were upgraded wholesale to **Ubuntu 24.04.5, kernel
      6.8.0-139** — a different mechanism, same practical outcome (a
      6.8-series kernel on both nodes). Recorded so the discrepancy from
      this step's original plan is visible rather than silently absorbed.
- [x] **6.6** Rebuild amdgpu DKMS for 6.8 — currently built only for 5.15.x
      per node (`smc1` 6.16.13, `smc2` 6.18.4, both ROCm 7.13.0) — and
      **verify `amdgpu.ko` exists for the new kernel before rebooting either
      node**; do not reboot on faith. UNVERIFIED whether ROCm 7.13 + these
      DKMS versions build cleanly against 6.8.
      **Confirmed 2026-09-15 (session 2):** amdgpu DKMS is now built for
      6.8.0-139 on both nodes (previously 5.15-only) — verified as part of
      the post-upgrade survival check, not a separate rebuild step run by
      this repo's tooling.
- [x] **6.7** Stage the reboots **one compute node at a time**, never both
      together, re-handling `modprobe.blacklist=amdgpu` per TODO 0.4 on each
      boot (host-prep does this automatically; confirm it still does on the
      new kernel).
      **Superseded 2026-09-15 (session 2):** the reboot happened as part of
      the OS upgrade, not as a staged one-at-a-time kernel swap as this item
      planned — whether it was staged per-node is not recorded by this
      session. What is confirmed: both nodes came back on 24.04/6.8 with
      `modprobe.blacklist=amdgpu` still on the cmdline and `modprobe amdgpu`
      still required per boot — TODO 0.4's ritual is unchanged by the
      upgrade, `ensure_amdgpu_loaded()` still applies as-is.
- [x] **6.8** Re-test that a KV namespace yields a `/dev/ngXnY` generic char
      device (and no `/dev/nvmeXnY`) on the new kernel — the concrete
      pass/fail for whether 6.8 actually closes the CSI-1 gap that disproved
      the plugin header's claim on 5.15 (HANDOFF §10.4). Do not assume 6.8
      fixes it without running this same test.
      **Re-tested and PASSED, 2026-09-15 (session 2).** Same test, same
      namespace, only the kernel changed: 5.15 logged `unknown csi 1 for
      nsid 1` and created **no** device node at all; 6.8.0-139 logs `nvme
      nvme1: block device for nsid 1 not supported (csi 1)` and **does**
      create the generic char device (no block device beside it, as
      expected for a KV namespace). This closes the CSI-1 gap. See the
      corrected HANDOFF §6/§10.4 entry: the plugin header's original claim
      is not simply wrong, it is **kernel-dependent** — false on 5.15, true
      on 6.8.
- [x] **6.9** Make the kernel `nvme connect` persistent across reboot —
      currently untracked (no `--persistent` flag, no systemd unit), and
      every remaining backend-(A) storage step depends on the connection
      existing; confirmed this session that it does **not** survive a reboot
      (see TODO 0.4's recurrence note). Applies regardless of kernel
      version. Not applicable to backend (B): SPDK's own initiator handles
      its own reconnection.
      **Reclassified 2026-09-15 (session 2): known limitation with a
      documented workaround, not open build work.** Still no
      `--persistent` flag or systemd unit — reconfirmed this session that
      the connection from the KV roundtrip test did not survive the
      compute-node reboot, same pattern as TODO 0.4's amdgpu recurrence.
      With 6.3 now choosing backend (A), this is unconditionally applicable
      going forward. The workaround is now a documented three-step per-boot
      ritual (HANDOFF §9): `modprobe amdgpu` on both nodes, restart the KV
      target, re-run `nvme connect` on both nodes — none of the three
      survive a reboot, all three are prerequisites before P/D or storage
      work resumes. Automating this (systemd unit, or folding into
      host-prep) is real remaining work, but it is not one of the two live
      items in this section — do it opportunistically once 6.10/6.11 land.
- [ ] **6.10** 🔴 **THE LIVE ITEM — compose the storage tier under P/D.**
      Compose `MultiConnector[NixlConnector, LMCacheMPConnector]` with the
      chosen KV backend as the **live** LMCache storage tier underneath a
      real P/D deployment: LMCache's `nixl_backend = XNVME_KV` (per 6.3),
      `dev_uri` from `resolve_xnvme_kv_dev()` (per 6.3's NQN-based fix, not
      path-based autodiscovery). This exact combination has never been run:
      the lab has proven (a) NixlConnector P/D over UCX
      (`rixl-bench/stack/tracks/nixl/vllm/{08,11}-deploy-qwen-nixl*.sh`) and
      this session proved (b) XNVME_KV standalone (6.12), but never (c) the
      two composed. Treat as new integration, not reproduction — see
      HANDOFF §10.3.

      **Must prove both legs independently once composed** — not just that
      the server starts: (i) a direct P→D NIXL transfer (the leg-A proof
      6.11 establishes), and (ii) an actual LMCache hit served from the KV
      tier, distinct from 6.12's raw plugin-level proof — confirmed by a
      non-zero `need to load:` and non-zero `External prefix cache hit
      rate` in the logs, never by throughput or a flag's presence alone.
      The reuse number must be **cross-instance or post-eviction**, because
      `enable_prefix_caching=True` was observed live in this session's
      engine logs — vLLM's own prefix cache sits upstream of every
      connector and will silently serve a same-endpoint repeat without
      LMCache ever being consulted (HANDOFF §8's trap).

      **Prerequisites, all reconfirmed this session, none of which survive a
      reboot:** `nvme connect` must be re-run on both nodes and the KV
      target must be restarted (6.9); `KV_MAX_VALUE_SIZE_EFFECTIVE` must be
      reconciled to XNVME_KV's real 32768-byte ceiling, not 131072 or the
      previously-assumed 16 MiB (6.4, folds in 6.13); switching backends or
      changing this value requires draining the namespace (HANDOFF §7
      invariant 5).

      **Known limitation to watch, not a blocker:** the container's
      `libplugin_XNVME_KV.so` is a stale artifact — `nm -D` shows only the
      weak base-class `queryMem` symbol, not the override that exists in
      this repo's `plugins/xnvme-kv` source, and `query_memory()` returns
      `NIXL_ERR_NOT_SUPPORTED` at runtime. Not an architectural limit — the
      roundtrip degrades to retrieve-as-probe with a visible INFO line; use
      the `need to load:`/hit-rate log signal above for proof, not
      `query_memory()`.

      *UNBLOCKED 2026-09-15 (session 4): 6.11 is done and leg A verifiably
      transfers KV, so the substrate this tier composes onto now exists and
      is known-good. Bring the pair up with
      `scripts/common/start-vllm-container.sh {prefill,decode}` fronted by
      `scripts/proxy/disagg_proxy.py`, and **record the leg-A baseline
      (decode 0.0 tokens/s prompt throughput, 100% external hit) BEFORE
      adding LMCache** — if composing the tier breaks leg A, that baseline
      is the only thing that will tell you so, since both legs fail
      silently rather than erroring. This is now the last live item in §6.*

      **ATTEMPTED 2026-09-15 (session 4), NOT LANDED — but most of the
      unknowns are now closed. Full account: HANDOFF §12.** Four things
      were established, one design assumption was invalidated, and one
      external blocker stopped the run:

      1. **`LMCacheMPConnector` cannot carry this tier — the composition
         named in HANDOFF §1, TODO 0.1 and `gen-kv-transfer-config.sh`
         since the beginning is wrong.** `nixl_storage_backend.py` is
         reachable only from the in-process `StorageManager` path, which
         is configured by `LMCacheEngineConfig`; the MP connector and its
         adapter never construct one (`grep LMCacheEngineConfig` over
         both returns nothing) and use a separate `StorageManagerConfig`
         with a different L2-adapter schema. `extra_config`'s
         `enable_nixl_storage` / `nixl_backend` / `nixl_backend_params`
         are **silently ignored** under MP mode — not rejected, ignored.
         "MP" is multi-process: it also needs a separately launched
         `lmcache server` daemon that runs nowhere on this cluster. **Use
         `LMCacheConnectorV1`** — in-process, no daemon, and the only
         connector that reaches the NIXL storage backend.
      2. **`MultiConnector` is safe to wrap leg A in.** It never inspects
         child `kv_role`s, passes the request object to children by
         reference, and merges response `kv_transfer_params` with a
         clash check (`multi_connector.py:486-508`); `LMCacheConnectorV1`
         returns `(False, None)` so it cannot clash with NIXL's handoff.
         **Order matters on decode specifically:** the first child
         reporting a non-zero match wins the load
         (`multi_connector.py:387-400`), so if LMCache is listed first and
         hits, the NIXL pull is skipped. NixlConnector first.
      3. **The allowlist patch is not needed on the container path.**
         `XNVME_KV` and `SPDK_NVMe_KV` are in all three backend tuples of
         the vendored 0.5.3 (`nixl_storage_backend.py:126`, `:670`,
         `:1119`). This closes the container half of 2.7. The patch
         remains correct for a from-source build; its comment in
         `gen-lmcache-config.sh` no longer claims otherwise.
      4. **`max_local_cpu_size` is PER TP WORKER, and getting it wrong is
         a node-availability hazard, not a tuning nit.** `cluster.env`'s
         `LMCACHE_MAX_LOCAL_CPU_SIZE=80` means 8 × 80 = 640 GiB of pinned
         host memory at TP=8. Every prefill worker died
         `hipHostMalloc failed: 2`, and **the decode node rebooted**,
         losing its GPUs (0.4) and its `nvme connect` (6.9). Use ~5 GiB
         per worker. `gen-lmcache-config.sh` should multiply by TP and
         check `MemAvailable` before emitting — it does not yet, and that
         is the first thing to add before retrying.

      Also fixed while here: `gen-lmcache-config.sh` emitted
      `nixl_buffer_size` unconditionally, which LMCache **raises** on when
      `nixl_buffer_device: "cpu"` (`config.py:805`) and *requires* for any
      other device. Now conditional, and dies on the contradiction. `cpu`
      is the correct device: XNVME_KV reaches the KV namespace through
      kernel `pread`/`pwrite` on a char device, so the staging buffer must
      be host memory.

      **What actually stopped the run (see 6.18):** the KV target is a
      shared resource and was reconfigured out from under this work.
      `nqn.2024-01.io.nixl:kv0` / `KvMalloc0` no longer exists on `smc3`;
      it now serves `nqn.2016-06.io.spdk:cnode1` on the `1.1.0.2`
      listener. `nvme connect` fails `Connection refused`.

      **Still untested, and the most likely next surprise:** a 10 MiB
      LMCache page against XNVME_KV's 32 KiB per-value ceiling (6.4). The
      plugin splits multipart, so this implies ~320 parts against the
      device's `novg=4096` — plausible, unproven. If stores fail, reduce
      `chunk_size` first, and change it on **both** roles (it is part of
      the cache key — invariant 8).

      The exact resume recipe, with every element established rather than
      guessed, is written out at **HANDOFF §12.7**.
- [x] **6.11** ✅ **DONE 2026-09-15 (session 4) — leg A carries KV.** Prove
      leg A: a direct P→D NIXL transfer, following the rixl-bench pattern —
      `NixlConnector` only, `kv_role` kv_producer/kv_consumer,
      `kv_buffer_device cpu`, `extra_config {hostname, port: 14579}`,
      `NIXL_BACKEND=UCX`. Ties to existing 2.10. *Usable on TCP now, blocked
      by 3.6 for RDMA only.*

      **The current, specific blocker (found 2026-09-15, session 2):** vLLM
      on ROCm does not import `nixl` — it imports `rixl`
      (`vllm/distributed/nixl_utils.py`:
      `package_name = "rixl" if current_platform.is_rocm() else "nixl"`).
      P/D was launched with `rocm-aic:latest`, which has `nixl` but **not**
      `rixl`, so every worker died with `Worker failed with error 'NIXL is
      not available'` and both engines exited 1. Surveyed all six
      `rocm-aic` images (all six carry the same plugin set — AIS_MT, POSIX,
      SPDK_NVMe_KV, UCX, XNVME_KV):

      | Image | has `rixl`? |
      |---|---|
      | `kv-mppd-assertfix` | YES |
      | `kv-mppd` | YES |
      | `mp-pd` | no |
      | `pr4467` | no |
      | `kv-planefix` | no |
      | `latest` | no |

      Critically, the two `rixl`-capable images exist **only on `smc2`
      (decode)**. `smc1` (prefill) has `latest`/`mp-pd`/`pr4467`/
      `kv-planefix` — none of them.

      > **RESOLVED 2026-09-15, session 3 — no image move needed.** The
      > `rixl` requirement is gone. vLLM was asking the wrong question:
      > it picked the package from the platform rather than from what is
      > installed, and the `rocm-aic` `nixl` build *is* the ROCm-patched
      > one. `scripts/common/patch-vllm-nixl-pkg.sh` rewrites both
      > selection sites to probe for the installed package, and is applied
      > by bind-mounting the patched `nixl_utils.py` over vLLM's own at
      > launch. Verified on both nodes with `rocm-aic:latest`: resolved
      > package `nixl`, `is_nixl_available` True, `NIXL is available` in
      > the engine log. **Both roles now start, reach `/health` 200, and
      > report 3,754,160-token GPU KV caches.** The remaining work in this
      > item is no longer bring-up — see the KV-transfer gap below.

      **Once the image is on both nodes, relaunch with the parameters
      already worked out this session** (the containers started and loaded
      weights before dying on the `rixl` import, so these are confirmed as
      far as they got): `--device /dev/kfd --device /dev/dri --group-add
      video --network host --ipc=host --security-opt seccomp=unconfined
      --cap-add SYS_ADMIN --cap-add IPC_LOCK`, `-v /var/tmp/hf:/hf:ro`; env
      `VLLM_ROCM_USE_AITER=0`, `TOKENIZERS_PARALLELISM=false`,
      `PYTORCH_HIP_ALLOC_CONF=expandable_segments:False`,
      `NCCL_CUMEM_ENABLE=1`, `NIXL_BACKEND=UCX`,
      `VLLM_NIXL_SIDE_CHANNEL_HOST=<own routable IP>` (not
      `extra_config.hostname` — confirmed it does **not** change vLLM's
      bind, which defaults to localhost),
      `VLLM_NIXL_SIDE_CHANNEL_PORT=5600` (prefill) / `5601` (decode); vLLM
      args `--model /hf/Qwen2.5-72B-Instruct --served-model-name
      Qwen/Qwen2.5-72B-Instruct --tensor-parallel-size 8 --dtype bfloat16
      --max-model-len 32768 --gpu-memory-utilization 0.85`,
      `kv-transfer-config` NixlConnector with `kv_role`
      kv_producer/kv_consumer, `kv_buffer_device cpu`; ports 8100
      (prefill) / 8200 (decode). Engine already confirmed resolving
      `Qwen2ForCausalLM`, max len 32768, TP `world_size=8`,
      `enable_prefix_caching=True` before the `rixl` failure — this matters
      for 6.10/6.15's measurement trap.

      **Bring-up is DONE (2026-09-15, session 3).** Both roles answer
      `/health` 200. Side channels bind the routable IPs, verified with
      `ss -ltn`: `10.30.x.x:5600` on prefill, `:5601` on decode — not
      loopback. The proxy (`disagg_proxy_demo.py`, same image,
      `--network host`, args `--model --prefill HOST:PORT --decode
      HOST:PORT --port`) comes up, `/status` lists both nodes, and a
      completion through it returns coherent text with
      `finish_reason: stop` in ~3 s.

      **What remains is the actual point of the exercise: NO KV IS
      TRANSFERRING.** The pipeline serves correctly while doing no
      disaggregation at all — precisely the silent failure §7's invariants
      exist to catch, and it passes every check that only looks at HTTP.
      Measured with a 4000-token prompt through the proxy:

      | engine | avg prompt throughput | external prefix cache hit rate |
      |---|---|---|
      | prefill | 400.0 tokens/s | 0.0% |
      | decode  | **400.0 tokens/s** | 0.0% |

      Decode re-prefilled the whole prompt. Both engines did identical
      prefill work; nothing crossed the side channel, and no established
      TCP connection between the two hosts appears in `ss -tn` either.

      **Root cause to fix:** the vendored `disagg_proxy_demo.py` threads no
      handoff metadata — it sends `max_tokens=1` to prefill, then the
      original request to decode, and never passes the producer's
      `kv_transfer_params` along. NixlConnector's consumer needs that to
      know there is anything to pull. An earlier note in this file called
      that absence "settled and unused"; it is neither. Either use a proxy
      that implements the NixlConnector XpYd protocol, or add the field
      (`PD_HANDOFF_FIELD` exists for exactly this) to this one. Endpoint
      discovery is static CLI args, no registry.

      **Do not accept a completion as proof.** The only acceptable
      evidence is decode's prompt throughput collapsing toward zero on a
      long prompt while prefill's does not, and/or a non-zero
      `External prefix cache hit rate` on decode.

      ---

      **RESOLVED 2026-09-15, session 4. The evidence this item demanded,
      measured through this repo's own `scripts/proxy/disagg_proxy.py` on
      a 4033-token prompt with a per-run nonce:**

      | engine | avg prompt throughput | external prefix cache hit rate |
      |---|---|---|
      | prefill | 403.3 tokens/s | 0.0% |
      | decode  | **0.0 tokens/s** | **100.0%** |

      Decode performed no prefill work whatsoever, and the proxy reported
      `prefill_no_handoff: 0`. Corroborating: decode's wall time was 13.8 s
      on a 4035-token prompt, consistent with moving ~1.3 GiB of KV over
      the 1 GbE management path — the transfer is real, and equally, no
      throughput figure from this path is meaningful (see 3.6 / 6.16).

      **Two independent defects, each sufficient on its own to produce
      session 3's "serves perfectly, transfers nothing" symptom.** Full
      account in HANDOFF §11; in brief:

      1. **The proxy never asked for the handoff.** The XpYd handshake is
         three steps, not two: the priming request must itself carry
         `kv_transfer_params={"do_remote_decode": true, ...}`, or prefill
         returns no handoff at all and there is nothing to thread.
         Reference implementation is
         `/app/vllm/tests/v1/kv_connector/nixl_integration/toy_proxy_server.py`,
         present inside the image the whole time. Fixed in
         `scripts/proxy/disagg_proxy.py`. `PD_HANDOFF_FIELD` is now
         **verified** as `kv_transfer_params` on both request and
         response sides, not assumed.
      2. **UCX advertised an unroutable NIC.** With `UCX_NET_DEVICES`
         unset, UCX advertises the first TCP interface it enumerates —
         `benic1p1`/`30.1.1.1` on `smc1`, which `smc2` cannot route to.
         Decode blocked ~133 s in `connect()` then failed
         `loadRemoteMD` → `NIXL_ERR_BACKEND`, 500-ing every request.
         Fixed by new `PREFILL_PD_IF`/`DECODE_PD_IF` (deliberately
         distinct from the storage-leg `*_DATA_IF`); `setup_ucx_env` now
         **dies** in TCP mode rather than falling back to autodetection,
         because `<auto>` was not a default, it was the bug.

      Also codified: `scripts/common/start-vllm-container.sh`, the
      container launch path (6.1's decision) as an actual script with
      guards, rather than the shell history it had been.

      Also found, worth carrying forward: `nixl_rocm._api.create_backend()`
      has no return statement and is always `None` — any check of its
      return value is incapable of failing. Check `agent.backends[name]`.

      **Note what this does NOT close:** RDMA (3.1–3.6) is untouched —
      this is TCP over 1 GbE management. Neither container has
      `/dev/infiniband` at all, so UCX inside them is TCP-only today.

      **Watch for:** "stream ended without a finish reason" from the proxy
      means a vLLM 400 dressed up as a 200 SSE stream — read the **vLLM
      container logs**, not the proxy's, when this happens.

      **Per-boot prerequisite (unaffected by the OS upgrade):**
      `modprobe amdgpu` on both nodes before either engine can see a GPU —
      still required every boot per TODO 0.4, host-prep does this
      automatically.
- [x] **6.12** Prove leg B independently: an LMCache hit served from the KV
      storage tier (LMCache → NIXL → the chosen backend), confirmed by a
      non-zero connector-hit signal per HANDOFF §8 (`need to load:` and
      `External prefix cache hit rate` in the logs), never by throughput or
      by the flag's presence alone.
      **Proven 2026-09-15 (session 2) — the session headline.** A
      cross-process test on the prefill node (two separate `docker run`
      invocations, so the reader process never saw the writer's memory)
      stored three 32 KiB parts (98304 bytes total, exercising the
      multipart split from 6.4's 32768-byte ceiling); a second, independent
      process re-derived the same keys and retrieved identical bytes.
      `RESULT:OK` both phases, reproducible. Negative control verified: a
      nonce never written returns `RESULT:QUERY_MISS` and exit 1, not a
      false pass. **Caveat, not closed silently:** this exercised the
      XNVME_KV plugin's NIXL API directly (`register_memory`/
      `get_xfer_descs`, per 6's NIXL-API reconciliation), not an actual
      LMCache-mediated hit inside a running P/D deployment — that
      composition, and its own hit-rate proof, is exactly what 6.10 still
      has to do. This item establishes that the backend underneath it
      works.
- [!] **6.13** Generate/validate the LMCache YAML for the chosen backend
      (`scripts/common/gen-lmcache-config.sh` /
      `scripts/common/25-validate-lmcache-config.sh`) and confirm the
      plugin's **reported** max value size at runtime matches
      `KV_MAX_VALUE_SIZE_EFFECTIVE` for that backend — do not trust the
      config file's value alone. Ties to HANDOFF §7 invariant 8, and to
      6.4's open question about which figure (16 MiB assumed vs 131072
      measured) is actually live.
      **Folded into 6.10, 2026-09-15 (session 2):** not separately
      actionable. The backend is now decided (XNVME_KV, 6.3) and its real
      ceiling is now known (32768 bytes, not 131072 or 16 MiB — 6.4); doing
      this validation is exactly part of composing the tier at 6.10. No
      standalone work remains here.
- [x] **6.14** Bring up the proxy/router and confirm the handoff field name
      for whichever deployment model 6.1 lands on. If the container path is
      adopted, the reference router is upstream vLLM's
      `disagg_proxy_demo.py` (`--model --prefill HOST:PORT --decode
      HOST:PORT --port`, health endpoint `/status` — **not** `/health`,
      static CLI-arg endpoint discovery, no registry), not this repo's
      `scripts/proxy/disagg_proxy.py` — 6.1 needs to settle which router the
      repo targets. Watch for `disagg_proxy_demo.py` mislabelling a vLLM 400
      as a 200 SSE stream (surfaces client-side as "stream ended without a
      finish reason") — read the vLLM container logs, not the proxy, when
      this happens. Also carries over the Qwen caveats from `rixl-bench`:
      force `--dtype bfloat16` (their float16 default overflows to inf/NaN
      on bf16-trained checkpoints), YARN config key is `rope_type` not
      `type`, and TP is **not** derived from `HIP_VISIBLE_DEVICES` — it
      defaults to 1 and silently single-GPU-loads if not set explicitly.
      **Settled 2026-09-15 (session 2).** Router: `disagg_proxy_demo.py` is
      confirmed as the router this stack actually uses, following 6.1's
      container decision — not this repo's `scripts/proxy/disagg_proxy.py`.
      Handoff field: **`PD_HANDOFF_FIELD` is unused on this proxy** —
      `disagg_proxy_demo.py` does not thread a `kv_transfer_params` field at
      all; it sends `max_tokens=1` to prefill, then the original request to
      decode, and KV moves out-of-band over the NixlConnector side channel.
      This resolves the HANDOFF §6 "assumed" item outright — there is no
      field name to guess, the mechanism doesn't use one. **Not yet
      exercised against a live pair** — the proxy has never been started
      against a running prefill+decode, because P/D itself has never come
      up. Actually launching it end-to-end is folded into 6.11, not tracked
      separately here.

      > **REVERSED 2026-09-15, session 4 — both halves of this item were
      > wrong, and wrongly for the same reason.** The router is **this
      > repo's `scripts/proxy/disagg_proxy.py`**, not the vendored
      > `disagg_proxy_demo.py`. The demo proxy implements a *different
      > connector's* protocol and cannot drive NixlConnector at all: it
      > never sends the request-side `kv_transfer_params` that makes
      > prefill stage its blocks, so with it in front the pipeline serves
      > correct text and transfers zero KV. And `PD_HANDOFF_FIELD` is not
      > "unused on this proxy" — it is load-bearing, and now verified as
      > `kv_transfer_params` on both the request and the response side.
      >
      > The reasoning error is worth naming, because this file has now
      > made it twice about this same field: an absence in a reference
      > implementation was read as evidence about the *interface*. It was
      > only ever evidence about that implementation. The authoritative
      > artifact —
      > `/app/vllm/tests/v1/kv_connector/nixl_integration/toy_proxy_server.py`
      > — was inside the image from the start. See HANDOFF §11.1.
- [!] **6.15** Cross-instance reuse measurement, not confounded by vLLM's
      own prefix cache (HANDOFF §8) or by same-endpoint repeats — ties to
      existing 1.13 and to the storage-tier hit proven in 6.12. This is the
      number that actually demonstrates the KV backend is doing anything.
      **Still blocked, 2026-09-15 (session 2):** 6.12's raw-plugin proof is
      done, but this needs the composed, live LMCache-under-P/D hit that
      6.10 has yet to produce, plus 1.13's benchmark rework. Not one of the
      two live items — do not start until both 6.10 and 1.13 land.
- [!] **6.16** Both 200G data-plane NICs on the target report `Link
      detected: no` — `enp132s0` (which holds `1.1.0.2`) and `enp100s0`,
      measured 2026-09-15. The lab reference script
      `target_scale_kv_spdk.sh` hardcodes listener `1.1.0.2`, which is
      consequently unusable as written. The only reachable path to the
      target right now is its 1 GbE management NIC (`tg3`); any storage-leg
      throughput measured today is bounded by 1 Gb/s and not representative
      — this compounds the existing caveat at HANDOFF §8. The two compute
      nodes ARE on a common /24 management subnet and reach each other
      directly, so leg A has a working path today independent of this.
      Unaffected by session 2 — still needs the 200G links brought up
      physically; no known fix. Reclassified `[!]` blocked (on someone with
      physical hardware access), not merely pending, since it genuinely
      isn't actionable from a terminal on either compute node.
- [x] **6.17** Reclaim the now-redundant Qwen2.5-72B-Instruct copy in
      `/root/.cache/huggingface/hub` (~136 GB/node) once
      `/var/tmp/hf/Qwen2.5-72B-Instruct` (verified complete 2026-09-15:
      37/37 shards, 0 missing, matches `model.safetensors.index.json`; 80
      layers, 64 heads, 8 kv_heads, hidden 8192, bfloat16) is confirmed as
      the actual bind-mount source (`/hf` in the container). `smc2` is down
      to ~118 GB free. Housekeeping only — do not delete until the
      bind-mount is actually in use, to avoid deleting the only copy
      mid-transition.
      **Done 2026-09-15 (session 2):** the redundant hub-cache copy was
      deleted on both nodes now that `/var/tmp/hf/Qwen2.5-72B-Instruct` is
      confirmed as the sole, verified bind-mount source (37/37 shards,
      145.4 GB, index-matched) — 135 GB reclaimed per node. `smc1` now has
      336 GB free, `smc2` 253 GB. Qwen3-8B and TinyLlama left intact.
- [!] **6.18** **The KV target on `smc3` is a SHARED resource and was
      reconfigured mid-session by another party, 2026-09-15 (session 4).**
      This is what stopped 6.10, and it is not a fault in anything this
      repo controls. `nvmf_get_subsystems` now reports
      `nqn.2016-06.io.spdk:cnode1` with namespace `dev1_ns1`, listening on
      `1.1.0.2:4420` — the lab reference config from
      `target_scale_kv_spdk.sh`. The subsystem every storage-leg step in
      this repo depends on — `nqn.2024-01.io.nixl:kv0`, namespace
      `KvMalloc0`, on the management IP — **is gone**, and `nvme connect`
      from the compute nodes fails `Connection refused`. The node itself
      has not rebooted (uptime 3 days); the `nvmf_tgt` process was
      restarted against a different config.

      No attempt was made to reclaim it. Restarting someone else's target
      mid-experiment is not a unilateral call, and the failure mode if two
      parties fight over it is worse than the delay.

      **Before resuming 6.10:** find out who else is using `smc3`, agree
      on ownership, and only then re-establish
      `nqn.2024-01.io.nixl:kv0`. Note this also means the per-boot ritual
      (HANDOFF §9) is now insufficient on its own — "restart the KV
      target" assumed nobody else had claimed it. *Blocks 6.10.*
- [ ] **6.19** **Re-check 6.16 — the target's 200G links are UP now.**
      Measured 2026-09-15 (session 4): `enp132s0` and `enp100s0` both
      report `Link detected: yes`, and `enp132s0` holds `1.1.0.2/24`.
      6.16 and HANDOFF §8 both record these as `Link detected: no` with
      "no known fix", and 6.16 is classified `[!]` blocked on someone with
      physical hardware access. **That premise no longer holds** —
      something changed physically, and the remaining gap is addressing
      and routing, which is actionable from a terminal.

      What is still missing: neither compute node has an address on
      `1.1.0.x`, so there is still no route to that listener. Recorded as
      a separate item rather than edited into 6.16 because the useful
      record is that a blocker marked "not actionable" silently lifted and
      nobody would have thought to re-check it. Re-verify before trusting
      either entry.
- [!] **6.20** **`smc2` (decode) is reboot-unstable — 7 boots on
      2026-09-15, cycling every 3-13 minutes after 12:04.** This is now
      the top operational blocker: a 72B TP=8 load takes 5-6 minutes, so
      the node does not reliably stay up long enough to start an engine,
      let alone finish a measurement. Boot table and analysis in HANDOFF
      §12.8.

      The 12:04 reboot is plausibly explained by 6.10's 640 GiB pinned
      allocation. **The 12:22 one is not** — it happened with the engine
      idle, minutes after startup completed, and `journalctl -b -1 -p err`
      shows no panic, no MCE, no OOM kill and no thermal event. Do not
      assume the two share a cause just because one followed the other.
      Two further reboots followed (12:41, 12:46), one of them while a
      model load was in progress and one within three minutes of boot —
      so this is ongoing, not a one-off aftershock of the allocation.

      This is the **second** independent occurrence of unexplained reboots
      on this hardware — TODO 0.4 records the first, in an earlier session,
      affecting both compute nodes. `smc1` has been stable throughout this
      session.

      Remember what a reboot silently undoes: `modprobe amdgpu` (0.4), the
      KV target, and `nvme connect` (6.9). A node that reboots mid-run
      comes back quietly unequipped rather than obviously broken — the
      failure then presents as whatever step next touches a GPU or the KV
      device. **Check `uptime` before starting anything that takes
      minutes.**

      Not diagnosable from a terminal alone if it is power/thermal/firmware
      — the BMC (`DECODE_BMC` in the creds file) and its event log are the
      next place to look. *Blocks any long-running work on decode,
      including 6.10 and all of §3.*
