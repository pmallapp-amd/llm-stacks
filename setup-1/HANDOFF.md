# Handoff — setup-1 (all-in-one vLLM + SPDK, real-DSC MI210 pair)

State of the setup-1 bring-up, for whoever picks this up next. Last updated
2026-10-05 (late session).

Read [`../docs/setups/setup-1.md`](../docs/setups/setup-1.md) for the host
inventory/topology and [`../docs/BRINGUP-setup1.md`](../docs/BRINGUP-setup1.md)
for the step-by-step procedure — this file is the "what's actually true right
now, and what to watch out for" complement to both, not a replacement.

**Not part of the P+D disaggregated stack the rest of this repo documents.**
Nothing here touches `scripts/`, `config/cluster.env`, or `creds/active.env`.

---

## 0. 🔴 `/dev/ng0n1` (the real DSC) is currently DEAD — recovery not attempted

**Read this before touching `.100` at all.** Late in the 2026-10-05 session,
setup-1 was deliberately switched from `/dev/ng1n1` (a kernel `nvme_tcp`
software path to `.88`'s RAM-backed SPDK target — see §4.4's old entry, now
historical) to `/dev/ng0n1` — `.100`'s own real Pensando DSC NVMe-KV function,
the actual category-(1) end-goal hardware. The **very first real store**
against it wedged the device:

```
13:18:26  nvme0: I/O tag 320/321 timeout, aborting req_op:DRV_OUT size:589824   (576 KiB — AIC_CHUNK_SIZE=16)
13:18:56  nvme0: I/O tag 320 timeout, reset controller
13:22:05  nvme0: Device not ready; aborting reset, CSTS=0x1    (repeats at 13:24:13, 13:26:21)
13:26:21  nvme0: Disabling device after reset failure: -19
```

`nvme list-subsys` now shows `nvme0 pcie 0000:1c:00.0 dead`. The container's
own plugin log caught it in real time:

```
[XNVME_KV] ...xnvme_kv_backend.cpp:407: queue made no forward progress for 30s: 0 op(s) queued, 2 in flight.
The device has stopped completing I/O; this is NOT the transient queue-full condition. No device
reset is attempted: on the Pensando DSC only an out-of-band DPU-side restart recovers this, and
host-side resets make it worse.
```

So: the plugin itself refuses to reset on purpose, but the **kernel's own**
NVMe timeout handler doesn't know that and reset it anyway — and that reset is
what actually wedged it. This is the same failure class the P+D disaggregated
stack's own `docs/HANDOFF.md` hit on smc1/smc2 (both "followed sustained write
load"), except here it took a single 576 KiB store, not sustained load.

**Recovery has NOT been attempted.** `creds/setup-1.env` lists
`COMPUTE_DSC_CONSOLE="telnet 10.30.15.122 2031"` (alt `2032`) but that's a bare
address — no login, no command sequence is documented anywhere in this repo
for *this* console, and the project's own precedent for this exact failure
(`docs/HANDOFF.md` §0, TODO 6.22) says it needs **the hardware owner**, not a
host-side script. Guessing at commands on a DPU firmware console with no way
to verify them first is not something to do unsupervised. **Whoever has that
access needs to restart the DPU-side app before anything below involving
`ng0n1` is actionable again.**

The container (`aic-xnvme-single`) is still `docker ps` `Up` and
`/health` still returns `200` — generation is unaffected (GPU-only), but KV
offload via `ng0n1` is dead until the DPU side is restarted.

**Before trying again once it's back:** `AIC_CHUNK_SIZE=16` (576 KiB/chunk)
was carried over unchanged from the `ng1n1` config on the assumption that
`ng0n1`'s larger queue limits (`max_hw_sectors_kb=2048`,
`max_sectors_kb=1280`, both measured higher than `ng1n1`'s) meant it was
*more* headroom, not less. That assumption was wrong — the real DSC's
**failure mode isn't a sector-count ceiling, it's a transfer-time ceiling**:
whatever the DSC does internally to service a 576 KiB write apparently takes
longer than the kernel's own I/O timeout (the default is 30s, and the
timeout-to-reset gap above is consistent with that). This is a fundamentally
different constraint than §4.3's old `max_hw_sectors_kb` story, which was
about `ng1n1`'s kernel queue only. Don't reuse that section's arithmetic here
— it answers a question the real DSC isn't asking. **Nothing in this repo
has yet measured what single-value size (if any) `ng0n1` can actually
service before a kernel-level timeout fires.** That has to be determined
empirically, in small steps, once the device is back — and whether it's
viable to raise the kernel's own nvme I/O timeout (`io_timeout`,
`/sys/class/nvme/nvme0/...`) before testing again is an open question, not
yet investigated.

---

## 1. Current state (2026-10-05, end of session)

A container is **live right now** on `.100` (`10.30.48.100`), serving
generation but with KV-offload storage dead per §0:

| | |
|---|---|
| container | `aic-xnvme-single` |
| endpoint | `http://127.0.0.1:8301/v1` (and `http://10.30.48.100:8301/v1` externally) |
| model | `Qwen/Qwen2.5-3B-Instruct` |
| stack | vLLM 0.26.0 → `LMCacheConnectorV1` (in-process) → `NixlStorageBackend` → `XNVME_KV` → `/dev/ng0n1` |
| GPU | MI210, `GPU=0`, `TENSOR_PARALLEL_SIZE=1` |
| chunk size | `AIC_CHUNK_SIZE=16` — carried over from the `ng1n1` config; **not validated against ng0n1**, see §0 |
| KV storage | **dead** — see §0. Device disabled by the kernel after the first real store |

**`/dev/ng1n1` and the `.88` target dependency have been fully retired from
this setup.** Earlier in this session, setup-1 ran against `/dev/ng1n1` — a
kernel `nvme_tcp` connection to `.88`'s RAM-backed (`bdev_kvmalloc`) SPDK
target, confirmed safe to kill, confirmed working (`ok=1 sct=0 sc=0` stores) —
but that was explicitly a stand-in, not the end goal. This session switched
the deployment, the build (`patches/`, `build.sh`), and these docs over to
`/dev/ng0n1` only:

- `.88`'s SPDK target, its additive `10.30.48.88:4420` listener, and `.100`'s
  `nvme connect` to it are **no longer part of this setup**. `.88` is
  untouched (the listener it already had is still there, harmless, just
  unused) — see `docs/setups/setup-1.md` §2 for what's still true about that
  host if this setup ever goes back to it.
- The `SPDK_NVMe_KV` NIXL plugin, the from-source SPDK build, and the 4
  `*-spdk-*.patch` KV-command-set patches are **removed from the build
  entirely** (not just undeployed) — see §2.

---

## 2. Patches/build.sh surgery (2026-10-05)

`setup-1/patches/` dropped from 13 files to 4. Removed:

| Patch | Why removed |
|---|---|
| `0001-0004-spdk-*.patch` | SPDK KV-command-set diffs — only needed to build `target.sh`/`SPDK_NVMe_KV`, which this setup no longer uses at all |
| `0006-lmcache-l2-adapter-kv-backends.patch`, `0007-lmcache-l2-adapter-value-size-split.patch` | `MODE=mp`-only (`nixl_store_l2_adapter.py`, the standalone `lmcache server` path) — setup-1 only ever runs `MODE=inprocess` |
| `0010/0011-*-guard-mp-connector-num-external-tokens.patch` | `LMCacheMPConnector`-specific, same `MODE=mp`-only reasoning |
| `0012-rocm-aic-dockerfile-ionic-provider-and-router.patch` | RDMA (`libionic1`) + `vllm-router`, both exclusively for the MP-mode P/D architecture. Removing this also **drops the `AINIC_DEB_REPO` hard dependency** from `build.sh` — one fewer thing a future rebuild needs present on the host |

Kept and edited:

- **`0005-rocm-aic-dockerfile-build-plugins.patch`** — rewritten to build only
  the `XNVME_KV` plugin (libxnvme + Abseil), with the `SPDK_NVMe_KV` build
  block (from-source SPDK checkout, `prepare-spdk-libs.sh`, the
  `spdk-host-patches/*.diff` staging and its hard-fail check) removed
  entirely. **Validated by round-trip**: applied the original patch to a
  fresh `rocm-aic@bb386562` checkout, hand-edited the resulting
  `docker/Dockerfile`, regenerated the patch via `git diff` (so line counts
  are derived, not hand-computed), then confirmed the new patch re-applies
  cleanly to a pristine checkout.
- **`0008-lmcache-nixl-storage-backend-kv.patch`** — trimmed the dead
  `SPDK_NVMe_KV` entries out of its three backend-allowlist edits; `XNVME_KV`
  entries untouched.

Kept, unedited (both are backend/mode-agnostic):

- `0009-lmcache-fused-kv-plane-count.patch` — the KV-plane correctness fix,
  "every backend on this path was corrupt" before this.
- `0013-vllm-do-not-assert-on-late-transfer-completion.patch` — general vLLM
  scheduler robustness fix for async KV-transfer completions; not MP-mode- or
  SPDK-specific, reproduced on a P/D pair but applies to the vLLM core
  regardless of mode, kept defensively.

`build.sh` updated to match: no more `spdk-host-patches/` staging, no more
`d -eq 4` hard-fail check, no more `nvme-kv-plugin` copy, and the whole
"3b/4: stage the ionic userspace verbs provider" block (and its
`AINIC_DEB_REPO` requirement) is gone. `plugins/nvme-kv/` (the `SPDK_NVMe_KV`
plugin source) is left on disk, untouched, just no longer staged or built —
it's source of truth per `setup-1/README.md`, not ours to delete outright.

**Full pipeline validated with `SKIP_BUILD=1` against a fresh vendor checkout**
(vendor + patch + stage, no Docker build) — applied cleanly, staged
`xnvme-kv-plugin/` only, no leftover `nvme-kv-plugin`/`spdk-host-patches`/
`libionic`/`vllm-router`/`ainic` references anywhere in the resulting
`docker/Dockerfile`. **Not yet validated with an actual `make build`** — that
takes 15-25 minutes and wasn't run this session; the existing `rocm-aic:latest`
image on `.100` predates this patch surgery (built from the old 13-patch
series) and is what `aic-xnvme-single` is still running. A future rebuild on
`.100` is the first real test of the trimmed Dockerfile under Docker itself,
not just `git apply --check`.

`setup-1/README.md` still documents the old 3-backend-and-mode-inclusive
picture (SPDK_NVMe_KV, MP mode, ionic/RDMA) — that's the general rocm-aic
track writeup, not setup-1-specific, and was not rewritten this session. Treat
its SPDK_NVMe_KV/MP-mode sections as describing a configuration this setup no
longer builds, not as a factual description of what's in `rocm-aic:latest`
going forward.

---

## 3. How to resume

```bash
ssh root@10.30.48.100   # root/docker, see ../creds/setup-1.env
docker ps --filter name=aic-xnvme-single
curl -s http://127.0.0.1:8301/health
```

**Before doing anything with the device:** confirm `/dev/ng0n1` is actually
back (`nvme list-subsys` should show `nvme0 ... live`, not `dead`) — that
requires the DPU-side restart in §0, which has not happened as of this
writing. Don't retry a deploy against a device subsystem still showing
`dead`; nothing host-side will fix it and repeated attempts don't help.

Once it's confirmed live: redeploy per `docs/BRINGUP-setup1.md` §3, but
**do not reuse `AIC_CHUNK_SIZE=16` blindly** — see §0's last paragraph. Start
smaller than 576 KiB and work up, watching `dmesg` for I/O timeouts after
every single store, not just the aggregate smoke test result.

---

## 4. Traps hit this session — don't re-discover these

### 4.1 `deploy.sh` in-process mode defaults to an 8-GPU host

`GPU=0,1,...,7` / `TENSOR_PARALLEL_SIZE=8` are the unconditional defaults in
the in-process branch, regardless of `PD_ROLE`. Omitting `GPU=0
TENSOR_PARALLEL_SIZE=1` produces `AssertionError: DP adjusted local rank N is
out of bounds for 1 devices` for ranks 1–7 — happens during GPU worker init,
before NIXL/storage is ever touched, so it's safe to just retry with the
right env.

### 4.2 `build.sh`'s compose step needs `/opt/pip-cache/wheels` to exist

Even though nothing needs to be in it. Symptom: `failed to get build context
pip-wheels: stat /opt/pip-cache/wheels: no such file or directory`. Fix:
`mkdir -p /opt/pip-cache/wheels`, then re-run the `docker compose ... build`
command `build.sh` printed — **with `ROCM_ARCH` still exported**, or it fails
later and more confusingly on `ROCM_ARCH is not set`.

### 4.3 (historical) `ng1n1`'s kernel queue ceiling — does NOT apply to `ng0n1`

This entire section described `/dev/ng1n1`'s (the retired `.88`-backed kernel
`nvme_tcp` path) `max_hw_sectors_kb=1024` ceiling and the `AIC_CHUNK_SIZE=16`
fix for it. **Kept only as a pattern reference** — the general shape
(chunk byte size = `layers * chunk_size * (kv_heads/TP) * head_size * 4`,
checked against whichever ceiling governs your path) is still correct
methodology, but the specific numbers were for a device this setup no longer
uses, and §0 shows `ng0n1`'s actual failure mode isn't even the same kind of
ceiling (transfer-time, not sector-count). Do not carry `AIC_CHUNK_SIZE=16`
forward as "the validated value" — it was validated for `ng1n1` only, and
§0's incident is exactly what happened when that assumption was carried to
`ng0n1` unchecked.

### 4.4 `/dev/ng0n1` and `/dev/ng1n1` were never interchangeable — now moot

`ng1n1` is retired (§1), so this is historical: `ng0n1` was always `.100`'s
real local Pensando DSC function (PCIe `0000:1c:00.0`), confirmed via
`nvme list-subsys` (`nvme-subsys0`, NQN `nqn.2019-08.com.pensando:...`) and
`nvme id-ctrl` (`Model: PDSNVME`). `ng1n1` was a kernel `nvme_tcp` path to
`.88`'s RAM-backed SPDK target, confirmed via the same tools (`nvme-subsys1`,
NQN `nqn.2016-06.io.spdk:cnode1`, `bdev_get_bdevs` → `"product_name": "KVMalloc
disk"` on `.88`). `deploy.sh`'s own banner prints `category: 1 (real NVMe-KV
device)` for **either** device path — it only pattern-matches `/dev/ngXnY`,
it doesn't know what's actually behind it. This distinction is why §0's
incident was foreseeable in hindsight (the hazard always applied in full to
`ng0n1`) but wasn't foreseen in practice (the chunk size that was safe on
`ng1n1` was carried over without re-validating against a structurally
different failure mode).

### 4.5 (historical) `.88`'s `nvmf_tgt` predates this session — no longer relevant

`.88`'s target is untouched and still shared infrastructure (see
`docs/setups/setup-1.md` §2) but is no longer part of this setup's deploy
path at all (§1). Kept here only so a future reader doesn't go looking for a
`.88` dependency that isn't there anymore.

---

## 5. Not done yet

- **🔴 Get `/dev/ng0n1` back.** Nothing below is actionable until the DPU-side
  app is restarted — see §0. This needs the hardware owner.
- **Determine `ng0n1`'s actual safe transfer size**, empirically, once it's
  back — §0's last paragraph. `AIC_CHUNK_SIZE=16` is not known-good for this
  device; it was only ever validated for the now-retired `ng1n1`.
- **Rebuild `rocm-aic:latest` from the trimmed patch series** (§2) and confirm
  it still produces a working `XNVME_KV`-only image under an actual
  `make build` — only `SKIP_BUILD=1` (vendor+patch+stage) has been validated
  so far, not the Docker build itself. The image currently running on `.100`
  predates this patch surgery.
- **The Qwen2.5-3B llama-benchy sweep on record predates all of this.**
  `/root/rixl-bench/results/yw-dell-gen4-1/2026-10-05-llama-benchy/llama-benchy-20261005-122401.md`
  was run against the `ng1n1` deployment before even that chunk-size fix
  landed — every KV store in it was silently failing. Its throughput/latency
  numbers are still valid for generation (which never depended on storage
  succeeding), but say nothing about the KV-offload path. No sweep has been
  run against a working KV-offload path on either device this session.
- **No RETRIEVE correctness check**, on either device. Nothing in this
  session proved a RETRIEVE actually loads from storage rather than vLLM
  re-prefilling from its own GPU prefix cache — `deploy.sh`'s own "ALSO" line
  (grep the log for `need to load: [1-9]` or `Retrieved`, with
  `--no-enable-prefix-caching` on the request path) was never followed
  through, on `ng1n1` or `ng0n1`.
- **`setup-1/README.md` is stale** relative to this session's patch surgery
  (§2) — its SPDK_NVMe_KV/MP-mode sections describe a configuration this
  track no longer builds. Not rewritten this session; flagged for whoever
  next has reason to touch that file.

---

## 6. Repo map

| What | Where |
|---|---|
| Scripts (vendored from `rocm-aic`) | `setup-1/{build,deploy,target}.sh`, `setup-1/{patches,plugins}/` — `target.sh` and `plugins/nvme-kv/` are now dead weight for this setup (§1-2) but left in place |
| Benchmark harness (vendored from `attic/kv-cache/bench`) | copied to `.100:/root/rixl-bench/` — **not** checked into this worktree under `setup-1/` (see below) |
| Topology/host facts | `docs/setups/setup-1.md` |
| Step-by-step procedure | `docs/BRINGUP-setup1.md` |
| This file | `setup-1/HANDOFF.md` |
| Credentials | `creds/setup-1.env` (gitignored — SSH creds, BMC IPs, DSC console telnet endpoints — **no console login/command docs**, see §0) |
| On `.100` | `/root/setup-1/` (scripts, copied from this worktree's `setup-1/` — **predates §2's patch surgery**, not yet re-copied), `/root/rixl-bench/` (bench harness), `rocm-aic:latest` (docker image — also predates §2), `aic-xnvme-single` (running container, KV storage dead per §0) |
| On `.88` | nothing deployed by this project — only the additive RPC listener from earlier in this session, now unused by this setup (§1) |

**`setup-1/bench/` is not in this worktree.** It was copied directly from
`attic/kv-cache/bench` to `.100:/root/rixl-bench/` for convenience during an
earlier session and was not added to this repo's tracked tree. If you want it
versioned here too, that's a deliberate follow-up, not something this handoff
assumes already happened.
