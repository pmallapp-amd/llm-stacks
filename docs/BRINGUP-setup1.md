# BRINGUP-setup1 — all-in-one vLLM + real-DSC MI210, step by step

Covers **setup-1** only (see [`setups/setup-1.md`](setups/setup-1.md) for the
topology/host facts this procedure assumes). Everything here runs against
`setup-1/` — the standalone rocm-aic extraction — **not** `scripts/` or
`config/cluster.env`, which belong to the unrelated P+D disaggregated stack
this repo otherwise documents.

Model: **`Qwen/Qwen2.5-3B-Instruct`** (replaces the TinyLlama smoke-test
default used during initial bring-up — see §6 for why, and what changes if
you go back to TinyLlama).

---

## 0. Topology recap

| Role | Host | Address |
|---|---|---|
| compute (`kv_both`, vLLM) | `yw-dell-gen4-1` | `10.30.48.100` |

**This is now a single-host procedure.** `yw-dell-gen4-2` (`10.30.48.88`) was
used earlier as a `.100`-reachable SPDK target behind `/dev/ng1n1`, confirmed
safe and working — but that was a stand-in, not the end goal. As of
2026-10-05 this procedure deploys only against `/dev/ng0n1`, `.100`'s own real
Pensando DSC NVMe-KV function, with no second host involved. See
`setup-1/HANDOFF.md` §0-1 for why, and for the incident that resulted
(`ng0n1` wedged on its first real store — unresolved as of this writing).

Credentials: `creds/setup-1.env` (gitignored). `root` / password auth only, no
key accepted.

Every command below is run **on the host itself** (ssh in first), not from a
control machine — `setup-1/build.sh`/`deploy.sh` expect to run locally where
Docker and the GPU live.

---

## 1. Preconditions — confirm before every session, not just the first

These do not survive a reboot of the host. Check them in order; each later
step assumes the one before it already holds.

### 1.1 Storage device (`.100`)

```bash
ssh root@10.30.48.100
nvme list-subsys
```

Expect `nvme-subsys0` with NQN `nqn.2019-08.com.pensando:nvm-subsystem-sn-8001-0-0`,
`nvme0 pcie 0000:1c:00.0`, state **`live`**. If it instead shows `dead`, stop —
that is the §3.2 wedge, it needs an out-of-band DPU-side restart before
anything below is actionable (see `setup-1/HANDOFF.md` §0). Don't retry a
deploy against a `dead` subsystem; nothing host-side clears it.

If `/dev/ng0n1` is simply **absent** (not `dead`, just not there — e.g. right
after a host reboot, before the DPU side has come up): this is a known boot
race, not a defect — retry `nvme list-subsys` after a short wait, or see the
per-boot rebind procedure in the main project's `docs/HANDOFF.md` §3.4 (same
underlying hardware class, same race).

### 1.2 GPU driver (`.100`)

```bash
rocm-smi --showid
```

If this errors `Driver not initialized (amdgpu not found in modules)` —
`amdgpu` is blacklisted on this host's kernel cmdline and must be hand-loaded
every boot (same pattern as setup-4's SMC nodes):

```bash
modprobe amdgpu
rocm-smi --showid   # expect: AMD Instinct MI210
```

### 1.3 Image built (`.100`)

```bash
docker images | grep rocm-aic
```

If `rocm-aic:latest` is absent, build it — see §2. If present, **check
whether it predates the 2026-10-05 patch surgery** (`setup-1/HANDOFF.md` §2 —
dropped `SPDK_NVMe_KV`/MP-mode patches) before trusting it's the trimmed
build; the image on `.100` as of this writing still predates that surgery.
If present and known-current, skip to §3.

---

## 2. Build the image (`.100`, one-time unless `setup-1/patches` or
`setup-1/plugins` change)

```bash
cd /root/setup-1   # setup-1/build.sh, deploy.sh, patches/, plugins/ copied here — see §7
ROCM_ARCH=gfx90a bash build.sh
```

`gfx90a` is the MI210's arch — do not use `gfx942` (that's MI300X, used on
the setup-3/setup-4 clusters this repo's main `scripts/` tree targets).

Takes roughly 15–25 minutes cold (vendors `ROCm/rocm-aic` fresh, applies
`patches/`, stages and builds the `XNVME_KV` NIXL plugin + builds the full
vLLM/LMCache/NIXL image). Rerunning is fast — the vendor checkout and Docker
layer cache are both reused when nothing changed. (Historical: before
2026-10-05 this also built an `SPDK_NVMe_KV` plugin from a from-source SPDK
checkout — dropped, see `setup-1/HANDOFF.md` §2. The image currently on
`.100` predates that change and hasn't been rebuilt since.)

**Known one-time snag:** the vendored `docker-compose.yml` expects
`/opt/pip-cache/wheels` to exist as a bind-mount source, even though nothing
needs to be in it. If `build.sh` dies with `failed to get build context
pip-wheels: stat /opt/pip-cache/wheels: no such file or directory`:

```bash
mkdir -p /opt/pip-cache/wheels
```

then re-run the `docker compose ... build` command `build.sh` printed just
before failing (not the whole script — the vendor/patch steps already ran and
don't need repeating). **Make sure `ROCM_ARCH=gfx90a` is still in the
environment of that resumed command** — it's easy to drop when copying the
failed invocation by hand, and the build will get much further before failing
opaquely on `ROCM_ARCH is not set` if you do.

Confirm when done:

```bash
docker images | grep rocm-aic   # rocm-aic:latest, ~43-44 GB
```

---

## 3. Deploy vLLM (`.100`)

```bash
cd /root/setup-1
BACKEND=xnvme \
MODE=inprocess \
GPU=0 \
TENSOR_PARALLEL_SIZE=1 \
AIC_XNVME_DEV=/dev/ng0n1 \
MODEL=Qwen/Qwen2.5-3B-Instruct \
HF_TOKEN=none \
IMAGE_REF=rocm-aic:latest \
AIC_CHUNK_SIZE=16 \
bash deploy.sh
```

**`GPU=0 TENSOR_PARALLEL_SIZE=1` are not optional here, and are not
`deploy.sh`'s defaults.** `deploy.sh`'s in-process-mode branch defaults to
`GPU=0,1,...,7` / `TENSOR_PARALLEL_SIZE=8` — written for the 8-GPU
setup-3/setup-4 nodes. `.100` has exactly one MI210. Omitting these two
produces `AssertionError: DP adjusted local rank N is out of bounds for 1
devices` for every rank past 0, and the container exits before ever touching
the storage backend (safe to retry — nothing reached NIXL/XNVME init yet at
that point).

**🔴 `AIC_CHUNK_SIZE=16` is NOT a validated value for `/dev/ng0n1`.** It was
carried over from testing against the now-retired `/dev/ng1n1` (a kernel
`nvme_tcp` path to a RAM-backed target), where it was confirmed safe. Against
the real DSC (`ng0n1`), this exact value wedged the device on its very first
real store — see `setup-1/HANDOFF.md` §0 for the full incident and why this
isn't just "pick a smaller number": the real DSC's failure mode is a
**transfer-time ceiling** (the write apparently takes longer than the
kernel's own I/O timeout), not the sector-count ceiling the old `ng1n1`
reasoning below assumed. Read HANDOFF §0 before deploying against `ng0n1`
again, and do not treat anything below this point as "the known-good
config" until that's resolved.

The paragraph that used to be here described `ng1n1`'s specific
`max_hw_sectors_kb=1024` ceiling and why `AIC_CHUNK_SIZE=16` (576 KiB/chunk)
stayed under it. That reasoning is preserved as a pattern reference in
`setup-1/HANDOFF.md` §4.3, but it's for a device this setup no longer uses —
don't apply its numbers to `ng0n1`.

`HF_TOKEN=none` is the explicit "public model, no auth needed" spelling
`deploy.sh` wants — `Qwen/Qwen2.5-3B-Instruct` is public. First run against
this model downloads ~6 GB of bf16 weights into `HF_HOME`
(`~/.cache/huggingface` by default — fine here, this is a local disk, not
NFS); subsequent runs reuse the cache.

**Redeploying over a previous model on the same port (e.g. going from
TinyLlama back to this, or vice versa) is allowed without `REPLACE=1`** —
`deploy.sh` only refuses when the existing container is serving a
*different* port than this invocation targets. It does an unconditional
`docker rm -f` of the old container first. Confirm nothing is mid-benchmark
against it before redeploying — a request in flight when the container is
removed fails, but removing an **idle** container this way is the script's
own normal, intended redeploy path, not the same hazard as a raw
`docker kill` of one it's not currently targeting.

Expect `READY after <N>s` and a one-line smoke-test completion, then:

```
containers : aic-xnvme-single
endpoint   : http://127.0.0.1:8301/v1
stack      : vLLM -> LMCacheConnectorV1 (in-process) -> NixlStorageBackend -> XNVME_KV -> /dev/ng0n1
```

### 3.1 Confirm the storage backend actually came up

```bash
docker logs aic-xnvme-single 2>&1 | grep -iE "nixl|xnvme"
```

Expect, among other lines:

```
[XNVME_KV] 1 queue(s) ready on /dev/ng0n1 (nsid=1), lookup=KV Exist
NIXL INFO    _api.py:390 Backend XNVME_KV was instantiated
LMCache INFO: Created backend: NixlStorageBackend (NixlStaticStorageBackend)
```

**Then immediately check `dmesg` and the container log for a timeout before
doing anything else** — see §3.2. The backend coming up clean does not mean a
store will succeed; the 2026-10-05 incident's smoke test passed this exact
check before wedging the device on its first real store.

### 3.2 ⚠️ Safety — read before doing anything else to this container

**Never `docker kill`/`docker stop`/`timeout`-wrap this container.** It is
always driving the real Pensando DSC NVMe-KV function — `/dev/ng0n1` is the
only device this procedure deploys against (§0). Doing so can wedge the
device's `CC.EN`/`CSTS.RDY` handshake with no clean recovery short of
restarting the DPU-side app from the device's own management console —
nothing host-side (rescan, FLR, a script re-run) clears it.

**This is not only a `docker kill` risk.** On 2026-10-05, `ng0n1` wedged from
**normal operation** — a single real store at `AIC_CHUNK_SIZE=16` (576 KiB)
took longer than the kernel's own NVMe I/O timeout, which triggered a kernel
controller reset (a layer `deploy.sh`/the plugin don't control), and that
reset is what actually failed and disabled the device. See
`setup-1/HANDOFF.md` §0 for the full timeline — **after any store, check
`dmesg` for `nvme0: ... timeout` before assuming success**, don't rely on the
container log alone.

The `docker rm -f` that `deploy.sh` itself does on a redeploy is the one
sanctioned exception to "never kill", and only against an otherwise-idle
container (see §3 above).

---

## 4. Run llama-benchy against it

```bash
# one-time, if uv isn't installed yet:
curl -fsSL https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

cd /root/rixl-bench   # setup-1/bench copied here — see §7
TRACK=rocm-aic-xnvme \
BASE_URL=http://127.0.0.1:8301/v1 \
MODEL=Qwen/Qwen2.5-3B-Instruct \
AUTO_DEPLOY=0 \
VIZ=0 \
SAVE_FORMAT=md \
DEPTH="0 4096 8192 16384" \
PP="512 1024" \
TG=256 \
CONCURRENCY="1 4 16" \
bash bench/llama-benchy/run.sh
```

`AUTO_DEPLOY=0` refuses to stand up a server itself — it only benchmarks
whatever's already serving `BASE_URL` (§3's container). `DEPTH`/`PP` here are
the tool's own defaults, not a cap — unlike the TinyLlama smoke test, which
needed `DEPTH="0 512 1024" PP="256 512"` to stay under TinyLlama's 2048-token
`max_model_len`, Qwen2.5-3B-Instruct's native context is 32768, so the full
default sweep fits comfortably on one MI210 (bf16 weights ≈6 GB, leaving most
of the 64 GB HBM2e for KV cache). Drop `SKIP_COHERENCE=1` for this model too
— that flag existed only to route around a TinyLlama-specific false-positive
in the tool's coherence check, documented in the tool's own header comment.

Results land per-run at
`/root/rixl-bench/results/yw-dell-gen4-1/<date>-llama-benchy/llama-benchy-<timestamp>.md`,
with a matching `.provenance.txt` alongside it. Nothing is overwritten
between runs.

**Read the preflight banner before trusting any number it prints.** It reads
`deploy.sh`'s own deployment record and will stamp the run `UNTUNED` with an
`ERROR: ... declares performance-degrading settings` line if that record
flags something — e.g. the very first `BACKEND=xnvme MODE=inprocess` run ever
made on this host, which `deploy.sh` itself tracks as unvalidated. A later
rerun against the same already-proven config should stamp clean.

---

## 5. Teardown (only if you're actually done)

```bash
# .100 — graceful. NOT docker kill / docker stop / timeout.
cd /root/setup-1
docker exec aic-xnvme-single kill -TERM 1   # ask the API server to shut down cleanly
# wait for it to exit on its own, then:
docker rm aic-xnvme-single
```

Leaving it running between sessions is fine and often preferable — §3's
redeploy path handles coming back to an already-up container cleanly, and
nothing elsewhere in this repo depends on `.100`'s GPU being free.

---

## 6. Why Qwen2.5-3B-Instruct instead of TinyLlama

TinyLlama-1.1B was the right choice for the very first bring-up (tiny,
already cached, 2048-token context keeps a first smoke test fast and cheap to
get wrong) but is a poor benchmark subject: its coherence-check false
positive forces `SKIP_COHERENCE=1`, and its 2048-token context caps any
`llama-benchy` sweep far below the depths (4k–16k) that actually distinguish
a KV-offload path from vLLM's own in-GPU prefix cache. Qwen2.5-3B-Instruct is
still small enough for a single MI210 (bf16 weights ≈6 GB) and small enough
to iterate on quickly, but has a real 32768-token context and no known
coherence-check issue, so §4's sweep can use the tool's own default depths
without truncation or a skipped check.

---

## 7. Where these files actually live

`build.sh`/`deploy.sh`/`patches/`/`plugins/` are copied from this worktree's
`setup-1/` to `.100:/root/setup-1/` — they are not run in place over SSH from
a control host, and nothing in `setup-1/` assumes a shared filesystem between
this machine and `.100`. Likewise `setup-1/bench/`
(`llama-benchy`/`lib`/`tracks.registry`/`profiles`, vendored from the
project's `attic/kv-cache/bench`) is copied to `.100:/root/rixl-bench/`. If
either tree changes here, re-copy it before re-running anything on the host —
there is currently no sync step that does this automatically.
