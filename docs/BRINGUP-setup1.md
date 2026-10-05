# BRINGUP-setup1 — all-in-one vLLM + SPDK, step by step

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
| target (SPDK NVMe-KV) | `yw-dell-gen4-2` | `10.30.48.88` |

Credentials: `creds/setup-1.env` (gitignored). Both hosts: `root` / password
auth only, no key accepted.

Every command below is run **on the host itself** (ssh in first), not from a
control machine — `setup-1/build.sh`/`deploy.sh` expect to run locally where
Docker and the GPU live.

---

## 1. Preconditions — confirm before every session, not just the first

These do not survive a reboot of either host. Check them in order; each
later step assumes the one before it already holds.

### 1.1 Target listener (`.88`)

```bash
ssh root@10.30.48.88
/root/kv_spdk/scripts/rpc.py -s /var/tmp/spdk.sock nvmf_get_subsystems \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[1]["listen_addresses"], indent=2))'
```

Expect **two** entries: `1.1.0.2:4420` (the target's own default, unreachable
from `.100` — see `setup-1.md` §3) and `10.30.48.88:4420` (the one `.100`
actually uses). If the second one is missing — e.g. after `.88` rebooted and
`nvmf_tgt` came back fresh — re-add it (additive, does not disturb the
existing namespace or the other listener):

```bash
/root/kv_spdk/scripts/rpc.py -s /var/tmp/spdk.sock nvmf_subsystem_add_listener \
    -t tcp -a 10.30.48.88 -s 4420 nqn.2016-06.io.spdk:cnode1
```

**Do not** restart, reconfigure further, or kill this `nvmf_tgt` — it predates
this project's work on the host and its ownership, while usable, was only
ever confirmed for this one additive change.

### 1.2 Storage connection (`.100`)

```bash
ssh root@10.30.48.100
nvme list-subsys
```

Expect `nvme-subsys1` with NQN `nqn.2016-06.io.spdk:cnode1`, state `live`,
`traddr=10.30.48.88`. If it's absent (reboot, or the kernel dropped the
session):

```bash
nvme connect -t tcp -a 10.30.48.88 -s 4420 -n nqn.2016-06.io.spdk:cnode1
nvme list   # confirm a new /dev/ngXnY appears — see the note below
```

**The device index is not stable.** `/dev/ng0n1` is always `.100`'s own local,
directly-attached Pensando DSC function (`nvme-subsys0`, PCIe `0000:1c:00.0`)
— never hand that one to `AIC_XNVME_DEV`, it is a different device entirely.
The one you want is whichever new `/dev/ngXnY` just appeared under
`nvme-subsys1` — confirm with `nvme list-subsys` rather than assuming `ng1n1`.

### 1.3 GPU driver (`.100`)

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

### 1.4 Image built (`.100`)

```bash
docker images | grep rocm-aic
```

If `rocm-aic:latest` is absent, build it — see §2. If present, skip to §3.

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
`patches/`, builds SPDK + stages the two NIXL plugins + builds the full
vLLM/LMCache/NIXL image). Rerunning is fast — the vendor checkout and Docker
layer cache are both reused when nothing changed.

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
AIC_XNVME_DEV=/dev/ng1n1 \
MODEL=Qwen/Qwen2.5-3B-Instruct \
HF_TOKEN=none \
IMAGE_REF=rocm-aic:latest \
AIC_CHUNK_SIZE=16 \
bash deploy.sh
```

Replace `/dev/ng1n1` with whatever §1.2 actually showed if it differs.

**`GPU=0 TENSOR_PARALLEL_SIZE=1` are not optional here, and are not
`deploy.sh`'s defaults.** `deploy.sh`'s in-process-mode branch defaults to
`GPU=0,1,...,7` / `TENSOR_PARALLEL_SIZE=8` — written for the 8-GPU
setup-3/setup-4 nodes. `.100` has exactly one MI210. Omitting these two
produces `AssertionError: DP adjusted local rank N is out of bounds for 1
devices` for every rank past 0, and the container exits before ever touching
the storage backend (safe to retry — nothing reached NIXL/XNVME init yet at
that point).

**`AIC_CHUNK_SIZE=16` is likewise not optional for this model, and is not
`deploy.sh`'s default (unset → LMCache's own default of 256).** At the
default chunk size, Qwen2.5-3B-Instruct's KV shape makes each stored object
~9 MiB — and `nvme1`'s negotiated kernel transfer ceiling
(`/sys/class/nvme/nvme1/queue/max_hw_sectors_kb`, confirmed via
`nvme list-subsys` + that path) is **1024 KB**. Every store past that ceiling
fails, but fails **silently from LMCache's point of view**: the container log
shows `[XNVME_KV] op=store ... t=complete ok=0 sct=7 sc=234` immediately
followed by `getXferStatus: backend 'XNVME_KV' returned error status
NIXL_ERR_BACKEND`, while LMCache's own line right next to it still reads
`Stored 2048 out of total 2048 tokens` — it does not surface the failure as
one. Nothing about serving breaks (generation is unaffected; this is purely
the storage side-channel), so this is easy to miss entirely unless you grep
the container log specifically for `NIXL_ERR` after deploying. `AIC_CHUNK_SIZE=16`
keeps each object at 576 KiB, safely under the 1 MiB ceiling — confirmed by
the same log line reading `ok=1 sct=0 sc=0` afterward. See §3.3 for the
general form of this problem (`setup-1/README.md` documents the identical
failure shape on Qwen2.5-72B at TP=4, a different chunk size, same root
cause: object size vs. the governing transfer ceiling for whichever plugin
you're on).

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
stack      : vLLM -> LMCacheConnectorV1 (in-process) -> NixlStorageBackend -> XNVME_KV -> /dev/ng1n1
```

### 3.1 Confirm the storage backend actually came up

```bash
docker logs aic-xnvme-single 2>&1 | grep -iE "nixl|xnvme"
```

Expect, among other lines:

```
[XNVME_KV] 1 queue(s) ready on /dev/ng1n1 (nsid=1), lookup=KV Exist
NIXL INFO    _api.py:390 Backend XNVME_KV was instantiated
LMCache INFO: Created backend: NixlStorageBackend (NixlStaticStorageBackend)
```

### 3.2 ⚠️ Safety — read before doing anything else to this container

**Never `docker kill`/`docker stop`/`timeout`-wrap a container actually
driving the real Pensando DSC NVMe-KV function once it's up.** Doing so can
wedge the device's `CC.EN`/`CSTS.RDY` handshake with no clean recovery short
of restarting the DPU-side app from the device's own management console —
nothing host-side (rescan, FLR, a script re-run) clears it. `deploy.sh`'s own
banner prints `category: 1 (real NVMe-KV device)` for **any** `AIC_XNVME_DEV`
matching the `/dev/ngXnY` naming convention — it cannot tell from the device
path alone whether real silicon or a RAM-backed stand-in is actually behind
it, so treat that banner line as unverified and check §3.3 before deciding
how careful to be with a given container.

The `docker rm -f` that `deploy.sh` itself does on a redeploy is the one
sanctioned exception to "never kill", and only against an otherwise-idle
container (see §3 above).

### 3.3 Which device is actually behind `AIC_XNVME_DEV` — and why it changes
the blast radius

`.100` has **two** `/dev/ngXnY` devices, and they are architecturally nothing
alike:

- **`/dev/ng0n1`** — `.100`'s own real Pensando DSC function, PCIe
  `0000:1c:00.0`. The host kernel sees this as a **plain local PCIe NVMe
  controller** (`nvme-subsys0 ... nvme0 pcie 0000:1c:00.0` — `nvme.ko` over
  PCIe, no `nvme_tcp`, no fabrics module, no network stack on the host side at
  all). Whatever the DSC does internally to actually service that namespace —
  talk to onboard flash, proxy it over the DSC's own network ports to some
  backend — happens entirely inside the DPU's firmware/ASIC and is invisible
  to `.100`'s OS. **This is the device the "never kill" warning above is
  actually about.**
- **`/dev/ng1n1`** — what this procedure deploys against. There is **no DSC
  in this path at all**: `nvme connect` (§1.2) had the host's own kernel speak
  `nvme_tcp` in plain software, over the ordinary management NIC, straight to
  `.88`'s SPDK target process (`nvme-subsys1 ... nvme1 tcp
  traddr=10.30.48.88`), which is itself backed by SPDK's RAM-only
  `bdev_kvmalloc` (confirmed via `bdev_get_bdevs` on `.88` —
  `"product_name": "KVMalloc disk"`), not any Pensando silicon. Killing a
  container using *this* device cannot wedge DSC firmware, because there is
  no DSC anywhere in the data path — worst case is a dropped TCP session and
  an `nvme reconnect`.

This also explains §3's `sct=7 sc=234` failure precisely: that status comes
from the **host kernel's** `nvme_tcp` software queue
(`/sys/class/nvme/nvme1/queue/max_hw_sectors_kb`), not from any DSC hardware
limit — a constraint that is specific to `/dev/ng1n1`'s path and says nothing
about what `/dev/ng0n1`'s real ceiling is (that one is whatever the DSC's own
PCIe NVMe controller advertises, a separate and unmeasured number).

**If you redeploy against `/dev/ng0n1` instead** (the real device, no `.88`
dependency, no kernel NVMe-oF involved at all) — `BACKEND=xnvme
AIC_XNVME_DEV=/dev/ng0n1`, dropping the `nvme connect` precondition in §1.2
entirely — the "never kill" warning in §3.2 is the one that actually applies,
in full, and `AIC_CHUNK_SIZE`'s correct value would need re-deriving against
whatever that controller's own MDTS/transfer ceiling turns out to be, not the
1024 KB measured here.

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
