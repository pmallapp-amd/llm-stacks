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
| 0 | Blocking decisions and follow-ups | 4 | 2 | 2 |
| 1 | Architecture correction (compute leg) | 13 | 12 | 0 |
| 2 | Hardware bring-up (Phase 1, TCP) | 13 | 3 | 0 |
| 3 | Acceptance (Phase 2, RDMA compute leg) | 6 | 0 | 0 |
| 4 | Open items and known limitations | 6 | 0 | 0 |
| 5 | Done | 14 | 14 | — |

**Next action: 2.3.** 0.4 (the GPU blacklist) is resolved — `modprobe amdgpu`
was all it took, no reboot, and host-prep now redoes it automatically every
run (see 0.4's corrected record). The next actionable item is 2.3 (pin the
SPDK SHA), blocked by nothing; 2.4 onward follows. The current top *blocker*
(not merely next task) is 3.6 — the P→D fabric has no route yet and no
correct value is known to fix it.

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
- [ ] **2.9** Pre-stage Qwen2.5-72B-Instruct weights (~145 GB) on both compute
      nodes. Run `scripts/target/05-check-chunk-ceiling.sh` and confirm it passes
      for the final TP and chunk size.
- [ ] **2.10** Start prefill, decode and proxy; run
      `scripts/verify/run-all.sh`. Confirm 50 reports a **direct NIXL transfer**,
      not an LMCache hit. Confirm the `kv_transfer_params` field name is right —
      override with `PD_HANDOFF_FIELD` if not. *blocked by 2.4–2.9*
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
- [ ] **3.3** Set the compute leg to RDMA and restart. `UCX_TLS` excludes `tcp`
      by design so a half-configured fabric fails loudly.
- [ ] **3.4** Prove RDMA is carrying the KV traffic — counters, not throughput
      inference.
- [ ] **3.5** Re-run the verify ladder and
      `scripts/bench/40-bench-transport-compare.sh` for the TCP-vs-RDMA number.
      *blocked by 1.13 if the figure is to mean anything*
- [ ] **3.6** The P→D fabric has no route yet. Measured 2026-09-14: `smc1`'s
      data-plane addresses are `30.1.N.1/24`, `smc2`'s are `30.2.N.1/24` —
      different `/24`s, differing in the second octet. `ip route get` for an SMC2 fabric
      address from SMC1 falls back to the management default route — there is no fabric route at all. This also
      falsifies `config/cluster.env`'s premise that every DSC3 fabric link is
      a `/31` point-to-point (they're `/24`s), and the
      `UCX_IB_ROCE_SUBNET_PREFIX_LEN=16` workaround would not bridge
      `30.1.x`/`30.2.x` either, since they differ inside the first 16 bits. No
      correct value is known yet — do not guess one. *blocks 3.1.*

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
