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
| 6 | Storage-tier integration (XNVME_KV / SPDK_NVMe_KV as an LMCache tier) | 23 | 12 | 6 |

**Read [HANDOFF §9](HANDOFF.md#9-how-to-resume) first** — it carries the
cluster state as handed over and the ordered plan. This block is the index.

**Before anything: 6.20, 6.18, the amdgpu ritual, and the LMCache daemon.**
`smc2` rebooted seven times on 2026-09-15, cycling every 3-13 minutes —
shorter than a 72B TP=8 model load — then held for hours, then rebooted
again; nothing explains either the instability or the recovery. `smc3` is
shared and currently serves *another party's* subsystem, so our
`nqn.2024-01.io.nixl:kv0` is gone (6.18). Both compute nodes were handed
over freshly rebooted with **0 GPUs** — TODO 0.4's `modprobe amdgpu` is
required right now. **New per-boot step, 2026-09-16:** the LMCache MP
daemon (`scripts/common/start-lmcache-daemon.sh`) must also be up on both
nodes before vLLM will start — `scripts/{prefill,decode}/03-start-*.sh`
call it automatically, but `start-vllm.sh` now hard-gates and `die`s if
it isn't reachable (HANDOFF §17.3, §9.4).

**One stack now, not two tracks.** HANDOFF §17 (2026-09-16) collapses the
connector matrix this list used to call "Track A" into a single,
code-enforced composition — `MultiConnector[NixlConnector,
LMCacheMPConnector]`, `NixlConnector` hardcoded as `connectors[0]`, no
`PD_ENABLED`/`PD_CONNECTOR`/`PD_LMCACHE_FIRST` switches left to get
wrong — and gives `LMCacheMPConnector` an actual daemon with a working
`--l2-adapter` mechanism to attach XNVME_KV/SPDK_NVMe_KV
(`scripts/common/start-lmcache-daemon.sh`; HANDOFF §17.3/§17.4). **This
also resolves 4.5's connector-order ambiguity** (there is no longer a
`PD_LMCACHE_FIRST` to flip — see 4.5) **and HANDOFF §12.7's open
`max_value_size` question** (HANDOFF §17.5: the split never engages on
the path this repo actually runs — see 6.4/6.10).

**6.10 remains the one live item in §6 — and as of 2026-09-17 it is
blocked on exactly one thing, not several.** Bringing the composed
daemon+L2-adapter stack up and producing an actual cross-node LMCache hit
through it has still not been done — but 2026-09-17's roundtrip proof
(6.25) closes out every candidate cause *except* the one 6.21 already
named: two live vLLM engines this session stored 36,864 objects between
them and retrieved zero, while this repo's own standalone roundtrip tool
proved the identical plugin/device/namespace supports cross-node
store+retrieve in both directions on the same box, same session. 6.10 is
therefore no longer blocked on 6.18 (`smc3` ownership — moot, see below)
or on any plugin/topology gap; it is blocked on 6.21's LMCache
key-derivation patch, full stop.
~~Evaluate the local-DSC option (HANDOFF §16.8) first: both `smc1` and
`smc2` have their own local Pensando DSC (`/dev/ng1n1`), and a local-DSC
XNVME_KV tier would not need `smc3` at all — unproven, nothing deployed
yet.~~ **SUPERSEDED 2026-09-16/17 — see 6.25.** The remote target is up,
and the "local DSC" is not a separate device: `nvme ns-descs /dev/ng1n1`
on both `smc1` and `smc2` returns an identical `csi`/`eui64` and each
node's own Pensando DSC is itself an NVMe-oF initiator peered to `smc3`.
It **is** `smc3`, re-exported per-node — there is no local-DSC escape
from 6.18, and the topology question this paragraph was hedging against
is closed, not merely evaluated. **2026-09-17: this is no longer a
topology question at all — 6.25 now has an actual cross-node
store+retrieve measurement through it, not just matching `eui64`s.**

**Model changed underneath every number in this list — read before
quoting any throughput/latency figure.** The running stack is
`Qwen/Qwen3-8B`, `--tensor-parallel-size 1` (72B is a 145 GB download not
present on either compute node), `--gpu-memory-utilization 0.85`,
`--max-model-len 32768`, `--block-size 64` — **not**
`Qwen2.5-72B-Instruct` at TP=8, which every prior measurement in this
file and in HANDOFF.md predates. See HANDOFF §18.1. `config/cluster.env`'s
tracked default is unchanged; this is a creds-level override for the
current deployment.

**The KV device geometry still hasn't been reconciled on the plugin side
(6.24, unchanged), but the DSC wedge that used to be the top open
operational issue is CLEARED, and the storage tier's remaining blocker is
now isolated to one thing — see 6.24, 6.21 (updated 2026-09-17), 6.22
(updated 2026-09-17), 6.25 (updated 2026-09-17).** `XNVME_KV`'s
device-reported `value_max` is still 32768 → 4096
(`20-verify-nixl-plugin.sh` still fails on the mismatch until a plugin
rebuild lands — 6.24). The DSC stall watchdog 6.22 first recorded and
§18.5 found worsening (`completions_err`/`stalls` climbing within a
session, a standalone verify script wedging on its first store) is now
**cleared** after both compute nodes were rebooted with the DPU side up:
`completions_err=0`/`stalls=0` across every process, 2026-09-17 (HANDOFF
§19.3) — not proven immune to recurring under the same load, just
measured clear right now. And `retrieve_ops=0` on the live vLLM
engines — previously measured on both roles without a way to rule out
plugin/device/topology as the cause — is now isolated cleanly to 6.21's
LMCache key-derivation defect: this session's standalone roundtrip proved
the identical plugin/device/namespace supports cross-node store+retrieve
in both directions (6.25), while the live engines' `store=36,864` /
`retrieve=0` persisted unchanged alongside it. See HANDOFF §19.

**New this session, 2026-09-17 — a DSC boot-time race, not previously
recorded: see 6.26.** At boot the kernel can probe the DSC NVMe
controller before the DPU-side application is ready
(`CSTS=0x0`/"Device not ready"), the kernel driver detaches, and nothing
re-probes it — `/dev/ng1n1` then never appears until a manual rebind,
which itself only succeeds once the DPU side is actually up. Added to the
per-boot ritual: confirm `/dev/ng1n1` exists before starting anything.
HANDOFF §19.1/§9.4.

**The P→D verify ladder had four false-negative defects, now fixed and
re-passing 9/9 against the new model — see the note appended to 1.7.**
`scripts/verify/50-verify-pd-direct.sh` was failing on a fully healthy
system for reasons unrelated to the transfer itself (missing handoff in
its own priming request, wrong side-channel host resolution, a
stats-logger race, a dead string assertion). See HANDOFF §18.6/§18.7.

**Backend default — 6.22, done.** `config/cluster.env`'s `KV_BACKEND`
default is now **XNVME_KV**, matching the decision 6.3 already recorded.
`SPDK_NVMe_KV` stays fully wired for comparison, not deleted
(HANDOFF §17.7).

**RDMA acceptance — §3, the one genuinely separate remaining workstream.**
This was never a second "track" to compose with the storage tier; it is
an independent transport upgrade for the P→D path. **Firmware updated
2026-09-16 — routing is now CLOSED and cross-node RDMA is measured for
the first time.** Static routes exist for all 8 fabric pairs both
directions; cross-node ping is 0% loss at ~0.10 ms; `ib_write_bw`
cross-node peaks at 41,898 MiB/s (~351 Gb/s, ~88% of the **400** Gb/s
line rate — these NICs are 400 Gb/s NDR, not 200 Gb/s as an earlier note
assumed). **3.6 is closed. 3.10's firmware skew is disproved as the
cause of break two** (both `-pi-121` and `-a-120` cards emit the same
`CREATE_QP BAD_ATTR`) and is downgraded to tidiness. **3.9 — UD QPs still
cannot be created, `rdma_cm` still fails — remains the sole remaining
RDMA-stack blocker and the top open RDMA item.** NIXL/UCX need neither UD
nor `rdma_cm`, so this likely does not block the P→D path over RDMA, but
`UCX_TLS=ib` pulls in UD transports that will fail. See HANDOFF §15.

**Done, 2026-09-16: 3.8** — `00-preflight.sh` now asserts `ibv_devinfo`
actually enumerates a device rather than merely existing, and surfaces
libibverbs' `couldn't load driver` warning. That surfaced the exact
signature that made §13/§3.7 hide for two sessions.

**Closed in session 4: 6.11** — leg A transfers KV, decode at 0.0 tokens/s
prompt throughput and a 100% external prefix cache hit rate, measured through
this repo's own proxy (HANDOFF §11). Also stale now: 2.8's `ionic_N` → netdev
mapping, and 6.14's router decision, both reversed with evidence.

**Also new, 2026-09-16 — 1.14.** The 1P1D→xPyD fleet-shape seam
(`PREFILL_HOSTS`/`DECODE_HOSTS`, `EndpointPool` round-robin, per-instance
NIXL side-channel ports) is implemented and unit-tested against fake
upstreams, but has not been run against more than one real prefill or
decode instance on live hardware — every measurement in this doc is still
N=1. See 1.14.

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

      **Four defects found and fixed, 2026-09-16/17 — all four produced a
      FALSE NEGATIVE on a fully healthy system, not a false positive.**
      (1) The priming request never included
      `kv_transfer_params={"do_remote_decode":true,...}`, so
      `NixlConnector` never staged blocks and never returned a handoff —
      the exact trap `scripts/proxy/disagg_proxy.py`'s own module
      docstring documents (lines 44-51); the proxy was fixed 2026-09-15,
      this verify script was not updated to match. (2) The side-channel
      reachability check probed `${PREFILL_HOST}`/`${DECODE_HOST}`
      directly instead of resolving the same way `lib.sh`'s
      `setup_pd_env()` does — `smc2` enumerates fabric NICs before its
      management NIC, so decode had bound `30.2.1.1`, not the management
      address the check assumed. (3) A race against vLLM's ~10 s periodic
      stats logger — fixed by capturing a baseline before the request and
      polling up to 45 s for a new line. (4) A hard assertion on the
      literal string `need to load: <nonzero>`, which this stack never
      emits at default verbosity — demoted to corroborating-only; the
      hard assertion is now that the cumulative "External prefix cache
      hit rate" **increased** versus baseline. Also recorded: `bc` is not
      present in the `rocm-aic:mp-pd-ionic2609` image — float comparisons
      here use `awk`. With all four fixed, the rung **passes 9/9** against
      the current (Qwen3-8B/TP=1) stack; a controlled A/B on a fresh-nonce
      ~1230-token prompt reproduced §11's qualitative signature (decode
      0.0 tok/s / hit rate rising with the handoff threaded in; 124.7
      tok/s / hit rate falling without it), and
      `scripts/verify/40-verify-disagg.sh` passed 9/9 with TTFT improving
      2.14x. **Do not compare these throughput numbers against any
      pre-2026-09-16 figure in this file** — the model changed (HANDOFF
      §18.1). Full account: HANDOFF §18.6/§18.7.

      **RE-VERIFIED 2026-09-17 on the fully rebuilt stack, after both
      compute nodes were rebooted — same result, not a new one.**
      `50-verify-pd-direct.sh` **9/9 PASSED** again, external prefix cache
      hit rate rising 0.0% → 100.0% on a fresh engine (a genuine baseline,
      not a stale reading) with decode `Avg prompt throughput: 0.0
      tokens/s`; `40-verify-disagg.sh` **9/9 PASSED**; proxy `/status`
      `prefill_no_handoff: 0`; decode's NIXL side channel bound to
      `30.2.1.1:5601`, confirming the `PD_SIDE_CHANNEL_HOST_DECODE` pin
      (§1.9 below) is deterministic across a reboot. Full account: HANDOFF
      §19.5.
- [x] **1.8** Fix `setup_ucx_env` — `ib,rocm,self,sm`, RoCE `/31` subnet handling,
      per-role device pinning.
- [x] **1.9** Add `setup_pd_env` (refuses a loopback side-channel address) and
      `require_rdma_access` (opens a uverbs node rather than stat-ing it).

      **Bind addresses now pinned in creds, 2026-09-16/17** —
      `PD_SIDE_CHANNEL_HOST_PREFILL=10.30.75.198`,
      `PD_SIDE_CHANNEL_HOST_DECODE=30.2.1.1` — removing the `hostname -I`
      first-IP lottery that 1.7's defect (2) depended on to reproduce.
      **Known, non-correctness asymmetry, not fixed here:** bulk KV still
      rides UCX over `ens51f0` (management) on both nodes, while decode's
      metadata side channel now sits on a fabric NIC (`benic1p1`) rather
      than management. Nothing has broken because of it — 1.7's rung
      passes 9/9 with this pin in place — but resolve to one NIC class
      before trusting it under a topology change (e.g. 1.14's xPyD fleet
      shape). See HANDOFF §18.8.
- [x] **1.10** Open side-channel ports in both host-prep scripts.
- [x] **1.11** Record the SPDK patch provenance and upstream status.
- [x] **1.12** Externalise credentials, purge history, add template + bootstrap.
- [ ] **1.13** Rework `scripts/bench/20-bench-prefix-cache.sh` for cross-instance
      or post-eviction measurement. As written it repeats the same context to the
      same endpoint, which vLLM's own prefix cache may serve without consulting
      any connector — see [HANDOFF §8](HANDOFF.md#8-known-measurement-trap). The
      warning and `--confirm-connector-hit` are in place; the restructure is not.
- [~] **1.14** **NEW, 2026-09-16.** Implement and prove the 1P1D→xPyD
      fleet-shape seam: plural `PREFILL_HOSTS`/`PREFILL_PORTS`/
      `DECODE_HOSTS`/`DECODE_PORTS` in `config/cluster.env` (defaulting to
      the existing singulars, so 1P1D is unchanged), an `EndpointPool` with
      round-robin `select()` in `scripts/proxy/disagg_proxy.py` replacing
      the old four scalar endpoint variables, and a per-instance NIXL
      side-channel port (base port + instance index) for xPyD. **Done:**
      the code exists and the §11.1/§11.4 handoff-semantics risk in this
      refactor was tested against fake upstreams (priming body, the
      `min_tokens`/`stream_options` drop on the priming copy only, handoff
      threading, the empty-dict-is-absent rule, `prefill_no_handoff`, the
      swallow-prefill/502-on-decode asymmetry) — see HANDOFF §17.9. **Not
      done:** this has never been run against more than one real prefill
      or decode instance on live hardware; every measurement in this doc
      (§11, §12, §15) is still N=1. Prove it on real xPyD hardware before
      trusting the fleet shape beyond N=1.

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
- [x] **2.7** Reconcile the LMCache YAML keys and NIXL backend allowlist patch
      against the version that actually installs. **Folded into 6.10
      2026-09-15.** The premise changed: the container ships LMCache 0.5.3
      pre-installed, so the patch generator script — which patches a
      *source* install's backend allowlist — has nothing to patch on this path.
      What still has to be established, and 6.10 owns it, is whether that
      prebuilt LMCache already accepts `XNVME_KV` as a `nixl_backend` or needs
      the allowlist edit applied inside the image. Still "most likely thing to
      bite", just relocated.

      **ANSWERED 2026-09-17, corrected same day — the generator is
      withdrawn, but the patches it would have written by hand are real and
      already applied.** The vendored LMCache 0.5.3 accepts both backends
      because the vendor image was built with
      `patches/lmcache/0006`/`0007`/`0008` applied — an earlier note here
      said "no patch needed" and that was wrong, corrected the same day
      (see `docs/HANDOFF.md` §20 and
      [`patches/lmcache/README.md`](patches/lmcache/README.md) for the
      full record and re-verification recipe). The **generator script**
      this item was originally about is still correctly withdrawn from the
      tree for reason (1) below — that part stands:
      (1) it targeted the from-source build path
      (`scripts/common/20-build-vllm-lmcache.sh` -> `/opt/kvstack/venv`),
      which has never completed a build and is deprioritised (§6.2), so
      the generator has nothing to run against on this path and survives
      only in git history if that path is revived.
      The MP daemon start observed 2026-09-17 (`--l2-adapter
      '{"type":"nixl_store","backend":"XNVME_KV",...}'`, logging
      `nixl_store backend XNVME_KV: page_size=4096, declared
      max_value_size='32768'`, live engines storing ~1.16 GB through it) is
      real and still stands as evidence the patched backend works — it was
      the inference "therefore nothing was ever patched" that was false.
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
- [x] **3.8** **Make `00-preflight.sh` actually test RDMA rather than
      inventory it.** It could not have caught 3.7: its only assertion was
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

      **DONE, 2026-09-16.** `00-preflight.sh` now runs `ibv_devinfo -l`
      capturing stderr, asserts at least one device is enumerated
      (`check_soft "ibv_devinfo actually enumerates >= 1 RDMA device (not
      just installed)"`), and surfaces a `couldn't load driver`/`failed to
      load driver`/`no matching driver` line from libibverbs as an
      explicit `warn` block naming §13.3, instead of silently discarding
      stderr. **Not part of this change, but already covers the
      `KV_TRANSPORT=rdma` hard-check this item also asked for:**
      `lib.sh`'s `require_rdma_access` (added at 1.9) already `die`s if no
      RDMA port reports `PORT_ACTIVE` when `KV_TRANSPORT=rdma`, so the
      hard-check half of this item was satisfied independently, earlier.
      Nothing further to do here.
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
- [x] **4.5** Connector-order experiment. `PD_LMCACHE_FIRST=1` is the only
      posture in which the L2 tier can win a load; the default gives NixlConnector
      first refusal. Worth measuring once 1.13 makes the number trustworthy.

      **OBSOLETE, 2026-09-16 — there is no longer a posture to experiment
      with.** `PD_ENABLED`/`PD_CONNECTOR`/`PD_LMCACHE_FIRST` are all
      deleted; `gen-kv-transfer-config.sh` hardcodes `NixlConnector` as
      `connectors[0]` and there is no variable left that can put
      `LMCacheMPConnector` first (HANDOFF §17.1). This is not a decision
      not to run the experiment — it is that the "first refusal" behavior
      is no longer configurable at all, for the reason HANDOFF
      §12.1/§16.9 give: letting LMCache go first would silently skip the
      P→D remote-prefill pull whenever the L2 tier has anything cached.
      Closes out the connector-composition ambiguity this item and 6.10's
      old item 1 both used to carry.
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

**The default in `config/cluster.env` finally matches this decision,
       2026-09-16 — see 6.22.** This item decided XNVME_KV back in session
       2, but `KV_BACKEND`'s actual default stayed `SPDK_NVMe_KV` until now;
       the flip to `XNVME_KV` (with `SPDK_NVMe_KV` kept fully wired for
       comparison, not deleted) is now committed — see 6.22 and HANDOFF
       §17.7.
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

      **Narrowed, 2026-09-16 — this concern does not apply on the path
      this repo actually runs.** The 32768/524288 ceilings above are real
      (confirmed live via `nixl_agent.get_plugin_params()` against the
      installed plugins), but the daemon-side `--l2-adapter` path
      (HANDOFF §17.4) tiles storage at `--l1-align-bytes` (4096 B by
      default), not at the whole LMCache `chunk_size` — so
      `_resolve_mem_split()` returns `mem_split_n=1` for both backends and
      the adapter-level split described here never engages (HANDOFF
      §17.5). This item's ceiling math still matters for the in-process
      `LMCacheConnectorV1`/`nixl_storage_backend.py` path, which this repo
      does not run; it is not a live risk for 6.10 as currently composed.
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
- [~] **6.10** 🔴 **THE LIVE ITEM — compose the storage tier under P/D.**
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

         **CORRECTED 2026-09-16, HANDOFF §16 — this conclusion is WRONG.**
         `LMCacheMPConnector` reaches the same backend through a route
         this session never checked: the distributed L2-adapter path
         (`nixl_store_l2_adapter.py`), which routes `XNVME_KV` to
         `mem_type="OBJ"` exactly as §12.2 required, with `mem_split_n`
         written specifically for MP-mode chunk sizes against a KV
         backend. The `extra_config` keys above genuinely are ignored
         under MP — that observation was right — but the config surface
         MP actually uses is `kv_connector_extra_config:
         {"lmcache.mp.host", "lmcache.mp.port"}`, with the backend
         configured on a separate daemon process that the vendor ships as
         a compose service, not something absent from this cluster by
         design. **Use `LMCacheMPConnector`, not `LMCacheConnectorV1`** —
         see HANDOFF §16 for the corrected recipe and the vendor
         reference that runs it.
      2. **`MultiConnector` is safe to wrap leg A in.** It never inspects
         child `kv_role`s, passes the request object to children by
         reference, and merges response `kv_transfer_params` with a
         clash check (`multi_connector.py:486-508`); `LMCacheConnectorV1`
         returns `(False, None)` so it cannot clash with NIXL's handoff.
         **Order matters on decode specifically:** the first child
         reporting a non-zero match wins the load
         (`multi_connector.py:387-400`), so if LMCache is listed first and
         hits, the NIXL pull is skipped. NixlConnector first.
      3. **The allowlist is patched into the container image, not applied
         by anything in this repo.** `XNVME_KV` and `SPDK_NVMe_KV` are in
         all three backend tuples of the vendored 0.5.3
         (`nixl_storage_backend.py:126`, `:670`, `:1119`) because
         `patches/lmcache/0008` put them there at image-build time; the
         daemon path this repo actually runs uses `nixl_store_l2_adapter.py`
         instead, patched by `0006`/`0007`. This closes the container half
         of 2.7. **Corrected 2026-09-17 — a same-day note here and at 2.7
         wrongly said this meant "no patch needed" and withdrew
         `patches/lmcache/` entirely; that deletion was caught before
         commit and reverted.** The **generator script** remains withdrawn
         (the from-source path it targeted has never completed a build and
         is deprioritised, so nothing on this tree needs it; it survives in
         git history) — but the patches themselves are real, required, and
         tracked at `patches/lmcache/README.md`.
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

      > **ANSWERED, 2026-09-16 — see HANDOFF §17.5.** The paragraph above
      > was reasoning about the wrong layer. On the daemon-side
      > `--l2-adapter` path this repo actually runs, the pool tiles at
      > `--l1-align-bytes` (4096 B), not at the whole 10 MiB LMCache
      > chunk, so `mem_split_n=1` for both backends and the ~320-part
      > split described here never happens. This paragraph's arithmetic
      > only applies to the in-process `LMCacheConnectorV1` path, which
      > this repo does not run.

      The exact resume recipe, with every element established rather than
      guessed, is written out at **HANDOFF §12.7**.

      **IMPLEMENTED, 2026-09-16 (commits `c055f7d`, `0b75adb`) — the code
      this item needs now exists and is validated; a live composed run is
      still not.** What landed:

      - The connector-composition question this item's old item 1 argued
        about is now moot — `NixlConnector` as `connectors[0]` is
        hardcoded in `gen-kv-transfer-config.sh`, not a posture to choose
        (see 4.5, HANDOFF §17.1).
      - The MP daemon HANDOFF §12.1 said "nothing spawns" now has a
        launcher: `scripts/common/start-lmcache-daemon.sh` /
        `stop-lmcache-daemon.sh`, wired into
        `scripts/{prefill,decode}/03-start-*.sh` and `99-stop.sh`, gated
        on by `start-vllm.sh` (HANDOFF §17.3).
      - The KV tier attaches daemon-side via a repeatable `--l2-adapter
        <JSON>` flag (`nixl_store` type, `{backend, backend_params,
        pool_size}`), built by `start-lmcache-daemon.sh` from
        `KV_BACKEND`/`XNVME_DEV`/`KV_TRID` and validated against the
        installed LMCache parser by `25-validate-lmcache-config.sh
        --l2-adapter-json` before the daemon ever spawns (HANDOFF §17.4).
      - This item's own "still untested" paragraph above is now answered
        (HANDOFF §17.5) — the split never engages on this path.
      - `gen-lmcache-config.sh`'s header now states plainly that its YAML
        `extra_config` keys are not read by anything running under MP, so
        the next reader can't repeat this item's original mistake by
        staring at that file alone (HANDOFF §17.6).

      **Still not done: an actual live LMCache hit served through this
      composed path on real hardware.** Nothing above was run against
      `smc3` or the local DSC — it was validated against the installed
      parser and a live `get_plugin_params()` query inside
      `rocm-aic:mp-pd-ionic2609`, not against a running daemon serving a
      real store/retrieve. This item is blocked on precisely what it
      always was, **6.18** and **6.20** — not on any remaining code gap.
      The `KV_BACKEND=XNVME_KV` default flip this item's recipe now assumes
      is in place in `config/cluster.env` — see **6.22**.
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

      **No local-DSC escape hatch — see 6.25, measured 2026-09-16/17.**
      `/dev/ng1n1` on `smc1`/`smc2` is not an independent device; `nvme
      ns-descs` returns an identical `csi`/`eui64` on both nodes, and each
      node's own Pensando DSC is itself an NVMe-oF initiator peered to
      `smc3`. It **is** `smc3`'s namespace, re-exported per-node. Using
      the local DSC does not sidestep this item's ownership question —
      whoever else is on `smc3` is exactly as visible through
      `/dev/ng1n1` as through a direct `nvme connect`. This closes the
      "evaluate the local-DSC option" framing this repo's preamble and
      HANDOFF §16.8 carried — not by proving the option unworkable, but
      by showing it was never a different option to begin with.
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
- [ ] **6.21** 🔴 **HARD WARNING — never launch the vendor's
      `deploy-xnvme.sh` on `smc1`/`smc2` without overriding
      `AIC_XNVME_DEV`.** The script defaults `AIC_XNVME_DEV=/dev/ng0n1`.
      **On both nodes `/dev/ng0n1` is the OS boot drive**
      (Micron_7450_MTFDKBA800TFS, 800 GB, carrying partitions
      `nvme0n1p1`/`nvme0n1p2`), not a KV device. The real local Pensando
      DSC is `/dev/ng1n1` (`PDSNVME-00`, model `PDSNVME`). Running the
      reference with its default would point XNVME_KV writes at the root
      disk. **Always set `AIC_XNVME_DEV=/dev/ng1n1` explicitly on these
      two nodes.** See HANDOFF §16.7.

      Also note, not a blocker: `nvme id-ns /dev/ng1n1` reports `nsze =
      0x200000` blocks at `lbads 9` (512 B) = **1 GiB** — small for a KV
      tier, flag as a sizing question to confirm before relying on it.
      `nvme list` shows "0.00 B / 0.00 B" for this device only because
      `nuse=0` (unused) — do not read that as an absent namespace.
      Ties to the newly-available local-DSC option for the storage tier
      (6.10, HANDOFF §16.8).
- [x] **6.22** ✅ **DONE 2026-09-16 — `KV_BACKEND` default flipped to
      `XNVME_KV`.** `config/cluster.env`'s default moved from
      `SPDK_NVMe_KV` to **`XNVME_KV`**, finally matching the backend
      decision 6.3 recorded back in session 2, so a fresh checkout now
      picks up XNVME_KV without an override. `SPDK_NVMe_KV` stays fully
      wired — build step, plugin, `lib.sh` arm, `--l2-adapter` spec,
      verify ladder — so the comparison between the two backends remains
      available and a regression in one can be attributed against the
      other.       Rationale at HANDOFF §17.7: the CSI-1 kernel blocker is
      closed (§10.4's re-test, then proven end to end §10.5), and the
      path needs no vfio-pci, no hugepages and no DPDK/SPDK version
      pairing. Note a backend switch still requires draining the
      namespace — see 4.2 and the `KV_MAX_VALUE_SIZE_*` comments.
- [ ] **6.26** **NEW, 2026-09-17 — the DSC NVMe controller has a boot-time
      race; nothing re-probes it if the kernel wins the race.** At boot
      the kernel probes the DSC NVMe controller (`0000:36:00.0`,
      `[1dd8:1005]`) roughly 3 s after PCIe enumeration — before the
      DPU-side application is ready — and fails:
      `nvme nvme1: Device not ready; aborting initialisation, CSTS=0x0`.
      The kernel `nvme` driver detaches and nothing re-probes it:
      `/dev/ng1n1` is then absent, `enable=0`, no driver bound, while
      `lspci` still shows the function enumerated.

      Diagnostic that separates this from a dead card: the DSC's other
      PCI functions (`pds_core` on `08:00.2`, `ionic` on `35:00.0`) bind
      fine on the same boot, config space reads correctly (`setpci -s
      36:00.0 00.L` → `10051dd8`), and the PCIe link is healthy (`LnkSta`
      `32GT/s x16`) — so `CSTS=0x0` here means the DPU-side NVMe/KV
      application specifically isn't serving yet, not that the card,
      slot or link is bad.

      Manual recovery — **works only if the DPU side is already up**,
      takes ~2 min, and fails with the identical `CSTS=0x0` otherwise:
      `echo -n "0000:36:00.0" > /sys/bus/pci/drivers/nvme/bind`. On a
      boot where the DPU side was already up, the probe succeeds cleanly:
      `nvme nvme1: 63/0/0 default/read/poll queues` then
      `nvme nvme1: block device for nsid 1 not supported (csi 1)` — the
      second line is EXPECTED, not an error (csi 1 has no block-device
      semantics, so only the char device `/dev/ng1n1` appears).

      Added to the per-boot ritual (HANDOFF §9.4): confirm `/dev/ng1n1`
      exists before attempting to start anything; `start-vllm.sh` already
      hard-gates on it by design, but a manual roundtrip run ahead of
      that gate will not, and will instead report a confusing device-open
      failure that looks unrelated to boot order. Full account: HANDOFF
      §19.1.

### 6.21 The image's XNVME_KV plugin predates `queryMem()` — REBUILT, but it does not unlock cross-instance reuse

**Measured 2026-09-16, first composed run on live hardware.**

The `rocm-aic` image builds its plugin from the vendor's separate
`kv-plugins/xnvme-kv-plugin/` tree (its own runtime log lines name that
path), and that artifact — dated Sep 9 — predates this repo's
`queryMem()` override:

```
nm -D libplugin_XNVME_KV.so | c++filt | grep nixlXnvmeKvEngine::
  -> 25 methods; queryMem NOT among them.
     The only queryMem symbol is the WEAK base nixlBackendEngine::queryMem.
```

`scripts/common/container.sh plugin-build` now rebuilds it from
`plugins/xnvme-kv` with the image's OWN configure options (recovered from
`/tmp/xnvme-kv-build/meson-info/intro-buildoptions.json`, so the rebuild
differs in source only), refuses to install an artifact still missing the
override, and `up` bind-mounts it over the image's copy. Verified:
`T nixlXnvmeKvEngine::queryMem(...)`.

**It did not produce a cross-instance hit, and the reason is not the
plugin.** `query_memory` is called from exactly one place in the installed
lmcache 0.5.3:

```
grep -rl query_memory lmcache/ -> v1/storage_backend/nixl_storage_backend.py
```

— the **in-process `LMCacheConnectorV1`** path, which this repo does not
run. The MP daemon's **static `nixl_store` L2 adapter never calls it**.
That adapter is an `_IndexPool` — "a thread-safe pool of integer indices
representing pre-allocated storage slots" — and the chunk-to-slot mapping
lives only in that daemon's memory. So the store is **slot-addressed, not
content-addressed**: a daemon cannot discover a key it did not itself
write, and the mapping dies with the process.

**Sharpened after the fact — the real constraint is stronger than "the
index is in memory."** The object names themselves are per-process random.
`nixl_store_l2_adapter.py:407` builds every storage key as

```python
key = f"obj_{i}_{uuid.uuid4().hex[0:4]}"
```

— slot index plus a fresh `uuid4` drawn independently by EVERY daemon at
startup. Prefill's and decode's names for byte-identical content therefore
share nothing but the `obj_{i}_` prefix, so the receiver cannot guess the
writer's suffix. No index-keeping, no existence probe and no plugin change
can bridge that; it is impossible by construction, not merely unimplemented.
And there is no escape hatch on this adapter the way there was in-process
(`pool_size == 0` selecting the content-keyed `NixlDynamicStorageBackend`):
the MP adapter validates `pool_size` as **"required, >0"**
(`nixl_store_l2_adapter.py:~1160`), so the static, uuid-suffixed naming is
the only behaviour available under `nixl_store`.

The full statement of this, with the in-process history it came from, is
kept in `scripts/common/start-lmcache-daemon.sh` under "THE
CONTENT-DERIVED-KEY CONSTRAINT" — relocated there when the in-process YAML
generator that used to hold it was deleted (6.23).

Consequence, and it is architectural rather than a bug to fix here:

- Within one daemon lifetime the L2 tier is a genuine capacity extension
  (spill past L1) — that part works and is measured (6.22).
- **Cross-node and post-restart reuse through the shared KV device is not
  reachable via this adapter**, no matter what the plugin exports.
  Demonstrated: prefill stored 238,903 objects / 978 MB; decode, restarted
  with empty L1 and empty vLLM prefix cache, was then handed the identical
  prompt and recomputed all of it (`Avg prompt throughput: 1041.4`,
  `External prefix cache hit rate: 0.0%`).
- Cross-node KV movement therefore happens over the **P→D `NixlConnector`
  handoff**, which does work — the same stack shows decode at
  `Avg prompt throughput: 0.0` / `External prefix cache hit rate: 100.0%`
  on a proxy-routed request.

Open, and NOT actioned here because both options are worse than the
status quo without evidence: `nixl_store_dynamic` is the adapter that
would key by content, but `start-lmcache-daemon.sh`'s header already
documents why it was rejected — it is file-oriented, requires
`backend_params["file_path"]`, does `os.makedirs`, and registers
`mem_type="FILE"`, none of which suits a KV-keyed device. Re-evaluate only
with a measurement, not a preference.

**RE-MEASURED 2026-09-16/17, against the composed daemon+L2-adapter stack
now actually running: `retrieve_ops=0` confirmed on BOTH roles, not just
inferred from the key-naming argument above.** From
`${NIXL_KV_METRICS_PATH}` (`/run/kv-cache-bench/*.json`):

| role | store_ops | store_bytes | retrieve_ops | retrieve_bytes |
|---|---|---|---|---|
| prefill | 313,143 | 1.28 GB | **0** | **0** |
| decode | 442,368 (two engine pids: 368,640 + 73,728) | ~1.81 GB | **0** | **0** |

This confirms the finding above is still live, not stale — the per-daemon
`uuid4` key naming (`nixl_store_l2_adapter.py`'s
`obj_{i}_{uuid4().hex[0:4]}`) makes cross-node retrieve impossible by
construction, exactly as diagnosed.

**New and genuinely open, not explained by the paragraph above:**
`retrieve_ops=0` on **prefill by itself** deserves its own investigation.
`LMCACHE_MAX_LOCAL_CPU_SIZE=4` (GiB) should make L1 evict constantly under
this store volume, and a same-daemon L2 read-back on an L1-eviction miss
needs no cross-daemon key agreement at all — the uuid4 argument above
only explains why decode can never find prefill's keys, not why prefill
never reads back its own. Full account: HANDOFF §18.4. **Still open,
untouched by the 2026-09-17 update below.**

**RE-MEASURED 2026-09-17, after both compute nodes were rebooted — this
is no longer merely the diagnosed cause, it is the sole remaining
candidate, with every alternative directly ruled out.** Per-process
plugin metrics after a full stack run:

| role | pid | store | retrieve | identity |
|---|---|---|---|---|
| prefill | 193 | 6 | 0 | this session's own roundtrip write |
| prefill | 308 | 0 | 256 | this session's own roundtrip read |
| prefill | **759** | **36,864** | **0** | **the LIVE vLLM engine** |
| decode | 253 | 256 | — | this session's own reverse-direction write |
| decode | 28 | — | 6 | this session's own cross-node read |
| decode | **707** | **0** | **0** | **the LIVE vLLM engine** |

Every non-zero `retrieve_op` on the box came from the standalone
roundtrip runs (6.25), never from an LMCache-driven engine. The two live
engines stored 36,864 objects between them and retrieved zero. What makes
this session's measurement different from the one above: 6.25's roundtrip
proved, on this exact namespace, this exact session, that the
plugin/device/shared-namespace path supports cross-node store+retrieve in
both directions — so "maybe the device/topology can't do it" is no longer
an open alternative. This item's diagnosis (`nixl_store_l2_adapter.py`'s
per-daemon `uuid4` key naming) is not one of several candidate causes any
longer — it is **the** remaining blocker, and it is an LMCache patch, not
a plugin or topology problem. Full account: HANDOFF §19.4.

### 6.22 The KV pipeline is 8x64, and the DSC wedges under sustained load

**Measured 2026-09-16 alongside 6.21.**

Pipeline ceiling is **8 queues x 64 queue depth = 512** outstanding ops —
the depth is the plugin's fixed default (`xnvme_kv_backend.cpp:634`), and
both counters agree: `peak_in_flight: 512`, and the stall message reports
exactly `64 in flight` on the wedged queue. (An earlier guess of 8x256 in
the deployment write-up was wrong.)

Two separate things show up in the metrics and should not be conflated:

- **`submit_retry: 1,367,781,109` is a SPIN COUNT, not an error count.**
  On transient `-EBUSY/-EAGAIN/-ENOMEM` `submit_one()` returns `kRetry`,
  the reactor pushes the item back and breaks to poke for completions —
  correct behaviour, but the outer loop has no sleep or yield, so a
  saturated device is polled at memory speed across all 8 reactor threads.
  Harmless to correctness; it burns 8 cores and makes the counter
  meaningless as a health signal. A short backoff on the `kRetry` path
  would fix both.
- **`completions_err: 192` is real, dropped stores.** The 30 s stall check
  fired and `fail_queued_work()` failed queued items. The device genuinely
  stopped completing — the plugin distinguishes this from queue-full
  explicitly and refuses to attempt recovery, which is right: per the
  `stall_timeout_ns_` declaration, only a DPU-side restart clears a wedged
  DSC and host-side resets make it worse. Logged verbatim:

```
queue made no forward progress for 30s: 37705 op(s) queued, 64 in flight
```

  37,705 items backed up behind one wedged queue. This is the same failure
  the standalone round-trip hits: `--size` of 1 MiB / 2 MiB / 4 MiB pass,
  8 MiB (2048 parts) and 64 MiB fail.

**Not reconciled, and left stated rather than smoothed over:** the stall
log reports 37,705 queued items, but only 192 stores were counted as
failed (238,903 submitted vs 238,711 ok) — 192 is also exactly
`3 stalls x 64`. Whether `fail_queued_work()`'s `local`/`mbox` drain is
being under-counted, or the queued backlog drained normally after the
stall was reported, is unresolved. Do not quote either number as the
dropped-chunk count until this is settled.

Actionable, in order: (a) add backoff to the `kRetry` path; (b) establish
whether the wedge is load-rate or total-bytes triggered, since that
decides whether widening the pipeline helps or just reaches the wedge
sooner; (c) raise with the DSC vendor with the stall log above — this is
DPU-side behaviour, not something the plugin can resolve.

**UPDATE 2026-09-16/17 — the wedge is active and getting WORSE, and this
is now the top open operational issue for the storage tier, ahead of
6.21's key-derivation gap and 6.24's plugin rebuild.** Within a single
observation window this session, `completions_err` went **512 → 704**
and `stalls` went **8 → 11** (`704 == 11 x 64`, still the exact-multiple
stall-watchdog signature above, not size rejection). The stall log itself
now shows a different, and worse, shape than the backlog-draining case
recorded above:

```
queue made no forward progress for 30s: 0 op(s) queued, 1 in flight
```

Nearly idle (one outstanding op, nothing queued behind it) and still
cannot complete — the device is not merely behind, it does not answer at
all. **A standalone `scripts/verify/30-verify-kv-roundtrip.sh --write`
wedged on its very first store**, returning `NIXL_ERR_BACKEND`. Per the
plugin header's own `stall_timeout_ns_` documentation, only an
out-of-band DPU-side restart clears this — host-side resets make it
worse, confirming action (c) above rather than superseding it.

**Practical lesson, worth keeping separately from the finding itself: do
not run `30-verify-kv-roundtrip.sh` against a device a live vLLM engine
is already driving.** The standalone probe above hit an already-wedging
device mid-session; read in isolation its `NIXL_ERR_BACKEND` result would
misattribute the failure to the script or its inputs rather than to
device state that predated the probe. Full account: HANDOFF §18.5.

**CLEARED, 2026-09-17, after both compute nodes were rebooted with the
DPU side up (6.26).** Plugin metrics across every process, checked after
a full round of cross-node roundtrips (6.25) plus a live stack run:
**`completions_err=0`, `stalls=0`, everywhere.** The reboot cleared it,
consistent with this item's own note above that only a DPU-side restart
(not a host-side reset) is known to clear the condition. **Not proven
immune to recurrence** — this is a clean baseline measured right now, not
a claim that the same sustained-load conditions that produced 512→704
errs / 8→11 stalls can no longer reproduce it. Full account: HANDOFF
§19.3.

### 6.23 The in-process LMCacheConnectorV1 config surface is removed

The `LMCacheConnectorV1` (in-process) connector path itself was already
deleted in an earlier change — this repo has run exactly one composition,
`MultiConnector[NixlConnector, LMCacheMPConnector]` (MP mode), throughout
6.1-6.22 above. What survived that earlier deletion was its now-dead
**config** surface: `scripts/common/gen-lmcache-config.sh` (generated an
LMCache YAML per role), the `LMCACHE_CONFIG_FILE` env var
`scripts/common/start-vllm.sh` exported pointing at it,
`LMCACHE_LOCAL_CPU` (`config/cluster.env`, consumed only by that
generator), and `start-vllm.sh`'s `--skip-validate` flag (gated running
that YAML through the validator). None of it was reachable from MP mode,
so this removes all of it:

- `scripts/common/gen-lmcache-config.sh` — deleted.
- `scripts/common/start-vllm.sh` — no longer generates, validates, or
  exports a YAML; `--skip-validate` removed (its arg-parsing loop still
  `die`s on any unrecognized argument).
- `scripts/common/25-validate-lmcache-config.sh` — the YAML-validation
  mode (bare `<path-to-lmcache.yaml>` positional argument) removed; the
  `--l2-adapter-json <JSON>` mode (validates `start-lmcache-daemon.sh`'s
  live config surface) is untouched and remains the only mode.
- `config/cluster.env` — `LMCACHE_LOCAL_CPU` removed.
- `scripts/{prefill,decode}/03-start-*.sh` — `[--skip-validate]` dropped
  from their `# usage:` lines (they just forward `"$@"`).

**Evidence this surface was dead**, verified directly against the
installed lmcache 0.5.3 (not re-litigated here — see the task that made
this change for the full grep/read trail):
`lmcache/integration/vllm/lmcache_mp_connector.py`
(`LMCacheMPConnector` itself) never reads `LMCACHE_CONFIG_FILE` — it reads
everything it needs from `kv_transfer_config.extra_config`, which
`scripts/common/gen-kv-transfer-config.sh` emits. `LMCACHE_CONFIG_FILE` is
read only by `lmcache/integration/vllm/utils.py` (the in-process path,
never instantiated by this repo),
`lmcache/integration/tensorrt_llm/utils.py` (irrelevant here), and
`lmcache/v1/config.py` (the loader itself) — none of which sit on the path
this repo's MP daemon runs. The live storage-tier config surface is, and
remains, `scripts/common/start-lmcache-daemon.sh`'s `--l2-adapter <JSON>`
flag — unmodified by this change.

### 6.24 XNVME_KV's device `value_max` moved 32768 → 4096 — resolved on the config side, still open on the plugin side

**Measured 2026-09-16/17.** The plugin now logs, at backend init:

```
[XNVME_KV] device KV format 0: value_max=4096 key_max=16 novg=0 (compiled-in default 32768)
WARNING: device value_max=4096 is SMALLER than the compiled-in default 32768
```

6.4 recorded 32768 as a **measured DSC firmware ceiling** — real, not a
config knob. That is no longer true: the device's own advertised ceiling
moved under us, the same shared-hardware-changes-under-you pattern
HANDOFF §13.7/§14.4/§15 already catalogue for the RDMA fabric, now hitting
the storage device too. `scripts/verify/20-verify-nixl-plugin.sh`
currently **FAILS**:

```
RESULT:MAX_VALUE_SIZE_MISMATCH:reported='32768' expected=4096
```

**Resolved, config/comment side:**

- `creds/active.env` sets `KV_MAX_VALUE_SIZE_XNVME=4096`.
- `scripts/common/container.sh` no longer exports
  `NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` — it never took effect: `lib.sh`'s
  `setup_nixl_kv_env()` (`lib.sh:613-621`) `unset`s it unconditionally
  right after `env.sh` is sourced, per HANDOFF §7 invariant 4. See
  `container.sh`'s own comment for the full three-reason rationale.
- **Not destructive, for this transition specifically.** The MP daemon's
  `nixl_store` unit is `--l1-align-bytes` (4096 B), so `mem_split_n == 1`
  under both the old 32768 ceiling and the new 4096 one — no object has
  ever been split, so invariant 4's half-stale-reassembly hazard cannot
  fire here. **It would fire** if `--l1-align-bytes` changes, or if
  `max_value_size` ever drops below 4096 — the invariant is unaffected,
  only this one transition happens to be safe.

**STILL OPEN:** `XNVME_KV_DEFAULT_MAX_VALUE_SIZE`
(`plugins/xnvme-kv/xnvme_kv_backend.h:71`) is still `32768u`.
`scripts/common/container.sh plugin-build` has not been re-run to align
it, so `20-verify-nixl-plugin.sh`'s mismatch persists until it is.

**Recommended durable fix, NOT applied:** give the plugin an explicit
`NIXL_KV_MAX_VALUE_SIZE=<N>` override that `getParams()` returns
unconditionally, and promote the device-vs-config mismatch from a
`WARNING` to a hard init failure. The existing
`NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` knob is call-order dependent —
`getParams()` reads `discovered_max_value_size_`, populated only during
`create_backend()`, so a `get_plugin_params()`-before-`create_backend()`
caller (`20-verify-nixl-plugin.sh` itself, `:171` then `:214`) still sees
the stale compiled-in value even with the flag set. On-wire geometry must
never depend on call order: geometry should come from config
(`KV_MAX_VALUE_SIZE_EFFECTIVE`), the device should only validate. Full
account: HANDOFF §18.3.

**RE-CONFIRMED, unchanged, 2026-09-17, after both compute nodes were
rebooted:** `20-verify-nixl-plugin.sh` still fails the identical
`RESULT:MAX_VALUE_SIZE_MISMATCH:reported='32768' expected=4096`; the
compiled-in `xnvme_kv_backend.h:71` constant is untouched. This did
**not** block 6.25's cross-node roundtrip proofs below, because that
harness does its own splitting at `KV_MAX_VALUE_SIZE_EFFECTIVE=4096`
regardless of what the plugin reports — the two facts are independent.
Do not read 6.25's success as having resolved this item; it has not.

### 6.25 The KV namespace is confirmed SHARED across P and D, and cross-node store+retrieve is now PROVEN, in both directions — the topology blocker this project has carried since HANDOFF §1 is GONE

**Measured 2026-09-16/17 — this supersedes HANDOFF §16.7/§16.8's "local
DSC" framing, and the preamble/6.18 references to it above.**

`/dev/ng1n1` on both `smc1` and `smc2` is a local PCIe function of that
node's own Pensando DSC (`0000:36:00.0`, model `PDSNVME`, subsystem NQN
`nqn.2019-08.com.pensando:nvm-subsystem-sn-8001-0-0`) — as already
recorded at HANDOFF §16.7. `nvme id-ctrl`/`nvme id-ns` succeed on both.

**Decisive, and new:** `nvme ns-descs /dev/ng1n1 -n 1` returns `csi: 0x1`
(the KV command set) and `eui64: e46cfefeffcdae01` — **identical** on
both nodes. Same namespace, same identifier, both sides. (Namespace size
`nsze 0x200000` @ `lbads 9` = 1 GiB, unchanged from §16.7.)

The host is **not** the NVMe-oF initiator — the DSC is. `nvme list-subsys`
on both compute nodes shows only local PCIe subsystems, no NVMe-oF
connection at all. `smc3` (`volcano17`) runs `nvmf_tgt` serving
`nqn.2016-06.io.spdk:cnode1` on `1.1.0.2:4420`, and the two DSCs are its
peers — each re-exports that same remote namespace transparently as a
local PCIe function on its own host.

**This reverses HANDOFF §16.8's framing, not merely extends it.** §16.8
read `/dev/ng1n1` as a distinct, node-local, unshareable 1 GiB device, and
proposed a "local-DSC XNVME_KV tier" as an *alternative* to `smc3`
precisely because it looked independent. It is not independent — it
**is** `smc3`, one hop closer:

- **The topology blocker is gone.** A KV storage backend being a shared,
  cross-node tier was always assumed to require a remote NVMe-oF target;
  a node-local device looked like a dead end for that purpose. Both
  assumptions are moot: `/dev/ng1n1` on `smc1` and `/dev/ng1n1` on `smc2`
  already point at the same physical namespace, with nothing extra to
  wire up, and there was never a choice to make between "local DSC" and
  "`smc3`".
- **6.18 is NOT sidestepped by using the local DSC** — the opposite of
  what §16.8 speculated, and the preamble's evaluate-first framing above
  is corrected accordingly. Any other party's use of `smc3` is exactly as
  visible from `/dev/ng1n1` as from a direct `nvme connect`, because it is
  the same backing store.
- **The remaining blocker is unchanged, and it was never a topology
  problem.** Physical sharing was never what stood between this project
  and a cross-node hit — the per-daemon `uuid4` key naming (6.21) is, and
  it is untouched by this finding.

Full account: HANDOFF §18.2.

**UPGRADED FROM "CONFIRMED SHARED" TO "CONFIRMED WORKING", 2026-09-17,
after both compute nodes were rebooted.** Everything above proved the two
`/dev/ng1n1` devices are the *same namespace* by identity (`eui64`) —
it never moved a byte between nodes to prove it. This session did, on a
namespace confirmed clean beforehand (`nuse: 0`) with no vLLM engine
running — a clean, uncontaminated test, not one sharing the device with a
live workload. Using `scripts/verify/30-verify-kv-roundtrip.sh` (keys
derived purely from `(nonce, size)` via sha256 — the two sides never
exchange the key):

- **WRITE on `smc1` (prefill) → READ on `smc2` (decode):** 24,576 B,
  `max_value_size=4096`, 6 parts. `RESULT:OK` — all 6 sub-keys confirmed
  present by `query_memory` before read, byte-for-byte compare passed.
- **Negative control:** a never-written nonce read on `smc2` returns
  `RESULT:QUERY_MISS`, non-zero exit — so the positive result above is
  not a false pass against stale namespace data.
- **REVERSE direction — WRITE on `smc2` (decode) → READ on `smc1`
  (prefill):** 1,048,576 B, 256 parts. `RESULT:OK`. This exercises the
  multipart `#{j}`-suffix path heavily, which the smaller forward run
  above barely touches.

This supersedes every earlier statement anywhere in this project that the
storage tier cannot move data between nodes. The topology blocker is
**definitively gone, in both directions**, at the plugin/device layer —
not merely inferred from matching `eui64`s. It also directly sharpens
6.21: with cross-node retrieve now proven to work at the plugin/device
layer, the live vLLM engines' `store=36,864`/`retrieve=0` (see 6.21's
2026-09-17 update) can no longer be attributed to anything but LMCache's
own key-derivation scheme. Full account: HANDOFF §19.2/§19.4.
