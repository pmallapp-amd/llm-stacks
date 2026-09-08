# vllm-lmcache-nixl-xnvme

One stack: **vLLM v0.26.0 + LMCache v0.5.3 + NIXL v1.3.2** — AMD's official
[ROCm/rocm-aic](https://github.com/ROCm/rocm-aic) image, unmodified — with two out-of-tree NIXL
storage plugins compiled in so KV cache can be offloaded to a key-addressed storage tier.

**Two storage backends**, both key-addressed, both driven by the same LMCache NIXL storage path:

| Backend | Transport | Target | Category |
|---|---|---|---|
| `XNVME_KV` | `io_uring_cmd` | a **local** NVMe-KV device node (`/dev/ng0n1`) | **(1)** the end-goal hardware |
| `SPDK_NVMe_KV` | NVMe-oF / TCP | an **independent** SPDK NVMe-KV target, on this host or another | (2) RAM-backed in practice |

The SPDK target is a genuine independent server — `target.sh` runs it — and is a first-class
backing store for LMCache, not a lesser variant. What makes it category (2) is only that the target
we run is RAM-backed (`bdev_kvmalloc`), so a number measured against it characterises the software
path, never a storage device.

**Three configurations**, all from one `deploy.sh`:

| Invocation | LMCache integration | Shape |
|---|---|---|
| `MODE=mp` *(default)* | `LMCacheMPConnector` → standalone `lmcache server` container | single node, `kv_both` |
| `MODE=inprocess` | `LMCacheConnectorV1` inside vLLM | single node, `kv_both` |
| `MODE=inprocess PD_ROLE=producer\|receiver` | `LMCacheConnectorV1` inside vLLM | **P+D disaggregated**, one host per role |

MP mode and in-process mode are genuinely different LMCache integrations sharing one image, not one
mode with a flag: `lmcache server --help` has no `--pd-role` / `--store-location` /
`--retrieve-locations`, so P/D asymmetry is only expressible through the in-process YAML. `deploy.sh`
keeps that boundary explicit and refuses `PD_ROLE` with `MODE=mp` rather than silently degrading.

> ### ⚠️ Safety — `BACKEND=xnvme` drives a real device
>
> Once a container is exercising the NVMe-KV device, **never kill it** — not `SIGKILL`, not
> `docker kill`, not even a graceful `docker stop` — and never wrap it in `timeout`. Any of those
> reliably wedges the device's `CC.EN`/`CSTS.RDY` handshake: every subsequent probe, from any
> process, any host driver, Docker or native, hangs at ~100% CPU forever with no further log output.
> **Nothing host-side clears it** — no rescan, no FLR, no `setup.sh` re-run. The only known recovery
> is restarting the DPU-side `pds_dp_app` from the device's own management console. Let runs finish
> or fail on their own.
>
> `BACKEND=spdk` against a loopback target has none of this hazard, which is why it is the default
> and why you should prove the stack there first.

## Status — read before trusting any output

| | |
|---|---|
| `BACKEND=spdk MODE=mp` | **Built and deployed** (2026-08-19). STORE was confirmed to silently fail past a size ceiling; fixed and validated 2026-08-25. |
| Everything else | **STAGED, NEVER RUN.** Derived from reading `ROCm/rocm-aic @ bb386562`, our own plugin/LMCache sources and `patches/` — not from an execution. |
| Model | `Qwen/Qwen2.5-72B-Instruct` needs 8×MI300X (TP=8) and will **not** fit a single-MI210 host. The only host with a real NVMe-KV function *is* a single MI210 — so `BACKEND=xnvme` is limited to small dense models. No `aiter`/`flash_attn` here, so **no MLA model** (DeepSeek-V2/V3, Kimi) runs at all. |
| Hostnames | Placeholders throughout (`<SETUP2_PD_NODE_IP>`, `<token>`), including in script defaults. Supply real values via the environment variables each script documents. |

Treat a first invocation as bring-up, not a benchmark: watch it fail, fix the actual error, and do
not trust a number until a correctness check has passed.

---

# Walkthrough — P+D disaggregated across three nodes

This is the hand-held version of Steps 1–5 below: one continuous procedure, in the order you
actually type it, with a checkpoint after every step. **Read this if you just want it running.**
Read Steps 1–5 and *Design and known issues* when something breaks.

## What you are building

```
                              ┌─────────────────┐
   your prompt ──────────────►│    proxy.py     │
                              │      :9000      │
                              └────────┬────────┘
                        1. prefill     │      2. decode
                    ┌──────────────────┘      └──────────────────┐
                    ▼                                            ▼
          ┌───────────────────┐                        ┌───────────────────┐
          │   PREFILL node    │                        │   DECODE node     │
          │   vLLM :8301      │                        │   vLLM :8301      │
          │   kv_producer     │                        │   kv_consumer     │
          └─────────┬─────────┘                        └─────────▲─────────┘
                    │  writes KV cache                           │ reads KV cache
                    │                                            │
                    └──────────────►┌───────────────────┐◄───────┘
                                    │   TARGET node     │
                                    │  SPDK NVMe-KV     │
                                    │      :4420        │
                                    └───────────────────┘
```

Three hosts. The **prefill** node reads your prompt and computes its KV cache, then writes that
cache to the storage target. The **decode** node fetches the KV cache back — instead of recomputing
it — and generates the answer. The **proxy** sends every request to prefill first, then to decode.

The two vLLM nodes never talk to each other. All KV movement goes through the target. That is the
whole point: it makes the storage tier the thing being measured.

## Before you start

| You need | How to check |
|---|---|
| Three hosts that can reach each other over TCP | `ping` between them; target port 4420 must be open |
| An AMD GPU on both vLLM hosts | `ls /dev/kfd` returns a path |
| `rocm-aic:latest` with both plugins on both vLLM hosts | Step 2 below |
| Model weights cached on **both** vLLM hosts | `du -sh "$HF_HOME"/hub/models--*` |
| Docker, plus root or passwordless `sudo` | `sudo -n true` |

Put the three addresses in shell variables so the rest of this page pastes verbatim:

```bash
PREFILL=10.0.0.1      # computes prompts, writes KV
DECODE=10.0.0.2       # generates tokens, reads KV
TARGET=10.0.0.3       # runs the SPDK NVMe-KV store
```

A note on where models live: `deploy.sh` defaults `HF_HOME` to `~/.cache/huggingface`. On a cluster
with an NFS home directory that is usually the wrong place — it is small and slow. Point `HF_HOME`
at local disk (e.g. `/var/tmp/hf`) and make sure the weights are there on **both** vLLM hosts.
Prefill and decode must serve byte-identical weights, or the KV cache one writes is meaningless to
the other.

## Step 1 — Free the GPUs

Skip this if your hosts are idle. Otherwise, check what is running and how much GPU memory is
already taken:

```bash
ssh $PREFILL 'docker ps; rocm-smi --showmemuse | grep VRAM%'
ssh $DECODE  'docker ps; rocm-smi --showmemuse | grep VRAM%'
```

**Expect:** every GPU you intend to use reading `0`.

Before stopping anyone else's container, save enough state to rebuild it, then stop it:

```bash
ssh $PREFILL 'mkdir -p ~/recovery && for c in $(docker ps --format "{{.Names}}"); do
                 docker inspect "$c" > ~/recovery/"$c".json; done'
ssh $PREFILL 'docker stop -t 60 <container> ...'
```

> **Check for a mapped NVMe device first.** A container with a real NVMe-KV device passed into it
> must be treated as radioactive — see the safety box at the top of this file. Check before you
> stop anything:
>
> ```bash
> docker inspect -f '{{json .HostConfig.Devices}}' <container> | grep -o '/dev/ng[0-9a-z]*'
> ```
>
> Empty output means no device is mapped and the container is safe to stop.

## Step 2 — Confirm the image has both plugins

On **both** vLLM hosts:

```bash
docker run --rm --entrypoint ls rocm-aic:latest \
  /opt/nixl/lib/x86_64-linux-gnu/plugins/ | grep -E 'SPDK_NVMe_KV|XNVME_KV'
```

**Expect:** two lines — `libplugin_SPDK_NVMe_KV.so` and `libplugin_XNVME_KV.so`.

**If it prints nothing:** the image was built without the plugins. Build it with
`ROCM_ARCH=gfx942 bash build.sh` (`gfx942` = MI300X, `gfx90a` = MI210). That takes 60–90 minutes,
so start it now and come back.

## Step 3 — Vendor the rocm-aic checkout

`deploy.sh` refuses to run without a vendored checkout next to it, even in in-process mode. This
step only clones and patches — it does **not** rebuild the image:

```bash
ROCM_ARCH=gfx942 SKIP_BUILD=1 bash build.sh    # gfx942 = MI300X; gfx90a = MI210
```

**Expect:** four stages, ending in
`SKIP_BUILD=1 — vendored, patched and staged. Not building.`

`ROCM_ARCH` is required **even with `SKIP_BUILD=1`**, though nothing is compiled — `build.sh`
validates it before it decides whether to build.

If your home directory is shared across the cluster (NFS), do this **once** and every node sees it.
Otherwise repeat it on both vLLM hosts.

## Step 4 — Start the storage target

On the target host:

```bash
SPDK_SRC=/root/spdk-clean LISTEN_ADDR=$TARGET HUGE_PAGES=256 bash target.sh
```

**Expect:**

```bash
ss -lntp | grep 4420        # LISTEN ... <TARGET>:4420
```

**`LISTEN_ADDR` must be the routable IP.** The default is `127.0.0.1`, and a target bound to
loopback is invisible to the other two nodes — the deploy will fail later with a connection error
that looks like a plugin bug.

> `ps -C nvmf_tgt` finds nothing even when the target is perfectly healthy — SPDK renames the
> process to `reactor_0`. Use `pgrep -af nvmf_tgt` instead. This has fooled people into declaring a
> working target dead.

## Step 5 — Deploy the prefill node

```bash
ssh $PREFILL
cd ~/rocm-aic

sudo HF_HOME=/var/tmp/hf HF_TOKEN=none \
  MODE=inprocess PD_ROLE=producer \
  MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 MAX_MODEL_LEN=2048 \
  TENSOR_PARALLEL_SIZE=1 GPU=0 \
  AIC_SPDK_KV_SLOT_OFFSET=0 \
  AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:$TARGET trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh
```

**Expect:** a `deploy: rocm-aic inprocess / SPDK_NVMe_KV` banner, then a health check that passes
within about two minutes. The container is named `aic-spdk-producer`.

Three arguments people get wrong:

- **`MAX_MODEL_LEN=2048`** — required for TinyLlama. The default is 32768, which exceeds
  TinyLlama's `max_position_embeddings`, and vLLM refuses to start. Do **not** reach for
  `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`: it silences the check instead of fixing it, and TinyLlama uses
  RoPE, so positions past 2048 produce `nan` — a server that runs and is quietly wrong.
- **`HF_TOKEN`** — always required. `HF_TOKEN=none` is the explicit way to say "public model,
  already cached", so that fact is recorded rather than smuggled in as a fake token.
- **`AIC_SPDK_KV_SLOT_OFFSET`** — see the next step.

## Step 6 — Deploy the decode node

Same command, three things changed: the role, the slot offset, and the host.

```bash
ssh $DECODE
cd ~/rocm-aic

sudo HF_HOME=/var/tmp/hf HF_TOKEN=none \
  MODE=inprocess PD_ROLE=receiver \
  MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 MAX_MODEL_LEN=2048 \
  TENSOR_PARALLEL_SIZE=1 GPU=0 \
  AIC_SPDK_KV_SLOT_OFFSET=2000000 \
  AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:$TARGET trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh
```

> **`AIC_SPDK_KV_SLOT_OFFSET` must differ between the two roles.** Both instances share one
> namespace on one target. Identical offsets mean they write to the same keys, silently corrupting
> each other's cache — no error, just wrong answers. Producer `0` / receiver `2000000` matches the
> default pool size of 2,000,000, so the two key ranges sit end to end without overlapping.

Both roles must also use the same `MODEL` and the same `TENSOR_PARALLEL_SIZE`. The KV chunk layout
depends on the TP degree, so a mismatch makes the stored cache unreadable to the other side.

## Step 7 — Front the pair with the proxy

Run this anywhere that can reach both vLLM nodes:

```bash
OPENAI_API_KEY=dummy python3 proxy.py \
  --host 0.0.0.0 --port 9000 \
  --prefiller-host $PREFILL --prefiller-port 8301 \
  --decoder-host   $DECODE  --decoder-port  8301
```

`OPENAI_API_KEY` must be set to *something* — it is forwarded as a Bearer token to both upstreams.

**Expect:** a real answer from the pair:

```bash
curl -s http://127.0.0.1:9000/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","prompt":"The capital of France is","max_tokens":16}'
```

> ### ⚠️ P/D cache reuse does not work with `SPDK_NVMe_KV` — verified 2026-09-07
>
> Everything below will run. The prefill node **stores** correctly, the decode node serves correct
> answers, and `completed_nvme_io` moves. But the decode node will **never get a cache hit**:
>
> ```
> LMCache INFO: Total tokens 1262, Inference Engine computed tokens: 0,
>               LMCache hit tokens: 0, need to load: 0
> ```
>
> The cause is in the key derivation, not in any setting you can change. LMCache's NIXL storage
> backend names each object with a **per-process random suffix**
> (`nixl_storage_backend.py`: `key = f"obj_{i}_{uuid.uuid4().hex[0:4]}"`), bound at
> `registerMem()` time. `make_key()` hashes that name. Two processes therefore derive *different*
> keys for the same logical slot, so the receiver cannot address anything the producer wrote.
> `plugins/nvme-kv/spdk_nvme_kv_backend.h` says so outright: the metaInfo path
> *"cannot support restart survival or cross-process sharing."*
>
> **`AIC_SPDK_KV_SLOT_OFFSET` is not the lever.** It is documented below as the thing that keeps the
> two roles apart, but it is *superseded* on this path — `make_key()` derives from metaInfo and
> ignores `devId` entirely when metaInfo is set, which LMCache OBJ mode always does. Setting both
> roles to the same offset does not produce hits either; the `uuid4` still differs.
>
> So this topology currently measures **P/D routing overhead with a working STORE and a
> never-hitting RETRIEVE**, not KV reuse. Making it real requires a content-derived key (e.g. from
> LMCache's chunk hash) instead of a per-process UUID — a plugin change, not a config change.
>
> Single-node (`MODE=inprocess`, no `PD_ROLE`) is unaffected: one process, one UUID, so store and
> retrieve agree and cache hits are real.

## Step 8 — Prove the KV cache actually moved

**Do not skip this.** An HTTP 200 proves nothing about the storage tier. This stack's signature
failure is a silent zero-byte store that reports success — you get valid-looking answers, correct
text, and no KV traffic whatsoever.

On the **target** host, before and after a request:

```bash
python3 /root/spdk-clean/scripts/rpc.py nvmf_get_stats | grep completed_nvme_io
```

**Expect:** the number is strictly larger afterwards. If it did not move, no KV was stored,
and any benchmark you run is measuring plain vLLM.

> Use `nvmf_get_stats`, **not** `bdev_get_iostat`. The latter never moves for SPDK's KV command
> set and will read as zero I/O even when everything is working correctly.

Then confirm the decode side is really *reading* rather than quietly re-prefilling:

```bash
ssh $PREFILL 'docker logs aic-spdk-producer 2>&1 | grep -E "Created backend:|Stored"'
ssh $DECODE  'docker logs aic-spdk-receiver 2>&1 | grep -E "Created backend:|Retrieved|need to load: [1-9]"'
```

If the decode side errors on a location name, set `LMCACHE_STORE_LOCATION` /
`LMCACHE_RETRIEVE_LOCATIONS` to exactly what `Created backend:` printed, rather than guessing.

Finally, the correctness check that gates every number: **the same prompt, twice, across a
restart, must produce identical output.**

## Step 9 — Benchmark

Only now. Point any OpenAI-compatible load generator at the proxy on port 9000 — not at either
vLLM node directly, or you bypass the disaggregation entirely.

```bash
PROFILE=throughput TRACK=rocm-aic-spdk BASE_URL=http://127.0.0.1:9000/v1 \
MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 bash bench/llama-benchy/run.sh
```

`deploy.sh` writes the server half of the provenance record, so the result's `.provenance.txt`
should carry a populated `SERVER CONFIG:` line. It will read `degraded=unvalidated-first-run` until
you clear `DEPLOY_DEGRADED=` on a deploy whose Step 8 genuinely passed. Leave it set until then.

Deployment records are **not** in `/run/kv-cache-bench` when the deploy ran as non-root. Check all
three locations before concluding one is missing — that mistake has been made twice:

```bash
ls /run/kv-cache-bench/ "${XDG_RUNTIME_DIR}/kv-cache-bench/" "/tmp/kv-cache-bench-$(id -u)/"
```

## When it goes wrong

| Symptom | Cause |
|---|---|
| `ERR: <dir>/docker not found` | Step 3 not done on this host |
| `ERR: HF_TOKEN not set` | Pass `HF_TOKEN=none` for a cached public model |
| `ROCM_ARCH is required` from `build.sh` | Set it even with `SKIP_BUILD=1` — it is validated before the build decision |
| `mkdir: cannot create directory ...: Permission denied` under `sudo` | NFS `root_squash`. See below |
| `AssertionError: Invalid NIXL backend & device combination` | The image predates patch 0008. See below |
| vLLM exits with a pydantic `ValidationError` on startup | `MAX_MODEL_LEN` exceeds the model's `max_position_embeddings` |
| Connection refused reaching the target | `LISTEN_ADDR` was left at `127.0.0.1` in Step 4 |
| Answers are fine, `completed_nvme_io` never moves | Silent zero-byte store — the failure this stack is known for |
| Answers are subtly wrong across a restart | Both roles used the same `AIC_SPDK_KV_SLOT_OFFSET` |
| `ps -C nvmf_tgt` shows nothing | Not a fault — the process is named `reactor_0` |

### Do not run `deploy.sh` under `sudo` on an NFS home

`sudo` is not the problem; NFS `root_squash` is. It maps root to `nobody`, so a `sudo`'d
`deploy.sh` loses write access to its own directory and dies at:

```
mkdir: cannot create directory '<repo>/vendor/rocm-aic/pd-configs': Permission denied
```

Run it as your normal user. The only thing it needs root for is allocating hugepages, so do that
once, up front:

```bash
sudo sh -c 'echo 512 > /proc/sys/vm/nr_hugepages'
```

`deploy.sh` skips the allocation when `nr_hugepages` is already ≥ 512.

### `Invalid NIXL backend & device combination` — the image is missing patch 0008

The symptom is nasty because **vLLM still serves and `/health` still returns 200**. Only LMCache's
storage backend failed, so you get correct-looking answers with no KV tier at all:

```
AssertionError: Invalid NIXL backend & device combination
LMCache ERROR: Failed during post_init
```

The image's `validate_nixl_backend()` accepts only `GDS`, `GDS_MT`, `OBJ`, `AIS_MT`. Patch 0008 is
what adds `SPDK_NVMe_KV` and `XNVME_KV`. Check the image directly:

```bash
docker run --rm --entrypoint grep rocm-aic:latest -c SPDK_NVMe_KV \
  /usr/local/lib/python3.12/dist-packages/lmcache/v1/storage_backend/nixl_storage_backend.py
# 3 = patched, 0 = not patched
```

**The plugin `.so` files being present does NOT mean the LMCache patches are.** They are built by
different parts of the Dockerfile, and an image can easily have one without the other. Always
confirm both:

```bash
docker run --rm --entrypoint ls rocm-aic:latest /opt/nixl/lib/x86_64-linux-gnu/plugins/
```

### Both P/D nodes must run the *same* image

Same tag is not the same image. Compare IDs, and the plugin the KV I/O actually goes through:

```bash
docker image inspect rocm-aic:latest --format '{{.Id}}'
docker run --rm --entrypoint md5sum rocm-aic:latest \
  /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_SPDK_NVMe_KV.so
```

If they differ, build once and copy the image rather than building on each host:

```bash
docker save rocm-aic:latest | ssh <other-node> docker load
```

Two independently-built plugins sharing one KV namespace is not a configuration you can trust a
benchmark from.

---

## Step 1 — Build the image (~60–90 min)

```bash
ROCM_ARCH=gfx90a bash build.sh       # gfx90a = MI210; gfx942 = MI300X
                                     # build.sh vendors ROCm/rocm-aic at the pinned SHA itself
ROCM_ARCH=gfx90a SKIP_BUILD=1 bash build.sh   # vendor + patch + stage only, no image build
                                     # ROCM_ARCH is required even when not building
```

`build.sh` vendors, applies `patches/`, stages the plugin sources into the build context, and runs
`make build`, producing **`rocm-aic:latest`**. The Dockerfile patch builds SPDK v26.05 (with the four
KV-command-set diffs) and libxnvme v0.7.5 standalone, then compiles both plugins against the image's
own NIXL at `/opt/nixl` — you never build a plugin separately.

Run it in the background and don't block on it. Then verify both plugins landed; a missing plugin is
otherwise silent until deploy time:

```bash
docker run --rm rocm-aic:latest \
  ls /opt/nixl/lib/x86_64-linux-gnu/plugins/ | grep -E 'SPDK_NVMe_KV|XNVME_KV'
# expect: libplugin_SPDK_NVMe_KV.so and libplugin_XNVME_KV.so
```

Iterate on patches without a full rebuild with `SKIP_BUILD=1 bash build.sh`. **Any change under
`patches/lmcache-*` requires a full rebuild** — those apply to LMCache's own tree *inside* the Docker
build, not to anything on disk.

## Step 2 — Start a storage target

### `BACKEND=spdk` — the independent SPDK NVMe-KV target

Run it wherever you like; the GPU host reaches it over TCP:4420.

```bash
SPDK_SRC=/root/spdk-clean LISTEN_ADDR=<routable-ip> HUGE_PAGES=256 \
  bash target.sh

ss -lntp | grep 4420
pgrep -af nvmf_tgt    # NB: `ps -C nvmf_tgt` finds nothing — the process comm is "reactor_0"
```

`LISTEN_ADDR` **must** be the routable IP, not the default `127.0.0.1`, or remote GPU hosts cannot
reach it. That `pgrep` point has fooled people into declaring a healthy target dead.

### `BACKEND=xnvme` — the local NVMe-KV device

The device must be on the **kernel `nvme` driver**, which is the opposite of the raw-PCIe nixlbench
path's `vfio-pci` bind. Do not run SPDK's `setup.sh` here.

```bash
lspci -k -s 0000:1c:00.0 | grep -i 'driver in use'   # want: nvme
ls -l /dev/ng0n1                                      # the char device xNVMe opens
```

If it reports `vfio-pci`, rebind — checking first that nothing holds it, per the safety rule:

```bash
lsof /dev/vfio/3 ; docker ps -a       # must be empty of device users
echo 0000:1c:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind
echo 0000:1c:00.0 > /sys/bus/pci/drivers/nvme/bind
```

A reboot resets driver bindings — re-check every session.

## Step 3 — Deploy

Prove the stack on the loopback SPDK target before pointing anything at the real device. It is the
cheap, hardware-independent way to catch build and integration bugs, and it cannot wedge anything.

```bash
# MP mode, SPDK target — the default, and the verified path
HF_TOKEN=<token> MAX_MODEL_LEN=2048 \
AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:<target-ip> trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh                                        # serves :8300
```

```bash
# in-process, single node
MODE=inprocess HF_TOKEN=<token> MAX_MODEL_LEN=2048 TENSOR_PARALLEL_SIZE=1 GPU=0 \
  bash deploy.sh                                        # serves :8301
```

```bash
# P+D disaggregated — one host per role, both against the SAME target.
# AIC_SPDK_KV_SLOT_OFFSET MUST differ between the roles: they share one
# namespace, and identical offsets cause silent cross-instance key collision.
MODE=inprocess PD_ROLE=producer AIC_SPDK_KV_SLOT_OFFSET=0 \
  MODEL=Qwen/Qwen2.5-72B-Instruct TENSOR_PARALLEL_SIZE=8 HF_TOKEN=<token> bash deploy.sh
MODE=inprocess PD_ROLE=receiver AIC_SPDK_KV_SLOT_OFFSET=2000000 \
  MODEL=Qwen/Qwen2.5-72B-Instruct TENSOR_PARALLEL_SIZE=8 HF_TOKEN=<token> bash deploy.sh
```

```bash
# the real device — only after the above is clean
BACKEND=xnvme AIC_XNVME_DEV=/dev/ng0n1 HF_TOKEN=<token> MAX_MODEL_LEN=2048 \
  bash deploy.sh                                        # serves :8301
```

`deploy.sh --help`-style documentation lives in its own header: every knob, its default, and why.
Read that before guessing flags. Note `MAX_MODEL_LEN=2048` for TinyLlama — compose's default of
32768 exceeds its `max_position_embeddings` and vLLM refuses to start.

### Front a P/D pair with the proxy

```bash
OPENAI_API_KEY=dummy python3 proxy.py \
  --host 0.0.0.0 --port 9000 \
  --prefiller-host <prefill-ip> --prefiller-port 8301 \
  --decoder-host   <decode-ip>  --decoder-port  8301
```

`OPENAI_API_KEY` must be set to *something* — it is forwarded as a Bearer token to both upstreams.

## Step 4 — Verify KV actually moved

An HTTP 200 proves nothing about the storage tier, and this stack's characteristic failure is a
**silent zero-byte store that reports success**. Verify per backend:

```bash
# BACKEND=spdk — on the target host. MUST increase across a request.
python3 ${SPDK_SRC}/scripts/rpc.py nvmf_get_stats | grep completed_nvme_io
```

Use `nvmf_get_stats`, **not** `bdev_get_iostat` — the latter never moves for SPDK's KV command set
and will look like zero I/O even when the path is working.

```bash
# BACKEND=xnvme — nvmf_get_stats does NOT apply; there is no NVMe-oF target in
# this path. Use NIXL telemetry (container-internal; the service publishes no host port).
docker exec aic-lmcache-xnvme curl -s localhost:19092/metrics | grep -i -E 'xnvme|nixl_.*(bytes|xfer)'
```

Then, for either backend, confirm RETRIEVE is really reading rather than re-prefilling, and check
which location name LMCache actually registered:

```bash
docker logs <container> 2>&1 | grep -E 'Created backend:|Stored|need to load: [1-9]|Retrieved'
```

If a retrieve side errors on the location name, set `LMCACHE_STORE_LOCATION` /
`LMCACHE_RETRIEVE_LOCATIONS` to what `Created backend:` prints rather than assuming.

Correctness before any number: the same prompt twice across a restart must produce identical output.

## Step 5 — Benchmark

Any OpenAI-compatible load generator works against the endpoint. This repo's own gated/stamped
harness (`bench/llama-benchy/`) lives in the full `kv-cache` tree and is **not** part of this
extraction; run it from there pointed at the endpoint deployed here:

```bash
PROFILE=throughput TRACK=rocm-aic-xnvme BASE_URL=http://127.0.0.1:8301/v1 \
MODEL=<model> bash bench/llama-benchy/run.sh
```

`deploy.sh` writes the server half of the provenance itself (the recorder is inlined), so the result's
`.provenance.txt` should carry a populated `SERVER CONFIG:` line. It will show
`degraded=unvalidated-first-run` until you clear `DEPLOY_DEGRADED=` on a correctness-checked deploy —
leave it set until Step 4 genuinely passes.

**Deployment records are not in `/run/kv-cache-bench`** when the deploy runs as non-root; they land
in `$XDG_RUNTIME_DIR/kv-cache-bench/`. Checking only `/run` and concluding "no record" is unsound —
that mistake has been made twice. Check all three:

```bash
ls /run/kv-cache-bench/ "${XDG_RUNTIME_DIR}/kv-cache-bench/" "/tmp/kv-cache-bench-$(id -u)/"
```

## Layout

```
README.md                     this file — walkthrough, procedure, design and known issues
LICENSE
deploy.sh                     all three modes, both backends. Inlines the provenance
                              recorder and generates the compose overrides at run time
build.sh                      vendor rocm-aic, patch, stage, make build
                              (SKIP_BUILD=1 to vendor without building)
target.sh                     the independent SPDK NVMe-KV target
proxy.py                      prefill→decode router, verbatim from vLLM
patches/                      one flat, git am-able series; destination encoded in the name
  0001..0004-spdk-*.patch     KV-command-set diffs, staged into the build
  0005-rocm-aic-*.patch       git-apply'd to the vendored docker/Dockerfile
  0006..0008-lmcache-*.patch  copied into the vendored tree, applied inside the build
plugins/
  nvme-kv/                    SPDK_NVMe_KV backend source
  xnvme-kv/                   XNVME_KV backend source
vendor/rocm-aic/              created by build.sh; never committed
```

`build.sh` **renames** the three `lmcache` patches to `15`/`16`/`17` when staging them. The
Dockerfile applies `patches/lmcache/*` in *lexical* order alongside rocm-aic's own `01`–`14`, and
`0006-` sorts before `01-` — which would silently reorder the series.

`patches/` is flat, with the destination encoded as a filename prefix. `build.sh` **strips** the
prefix when staging, so the vendored tree sees the filenames it expects — this matters for
`lmcache-*`, which must land as `15/16/17` to sort correctly against rocm-aic's own `01`–`14` in the
Dockerfile's lexical apply loop.

---

## Design and known issues

> Written inside the `kv-cache` benchmarking tree, so it links outward to files that
> are not part of this extraction (`CLAUDE.md`, `results/`, `bench/README.md`,
> `docs/analysis/`). The prose stands on its own; the hyperlinks do not resolve here.
> On-branch equivalents: the plugin sources are `plugins/{nvme-kv,xnvme-kv}/`, the
> SPDK KV diffs are `patches/000{1..4}-spdk-*.patch`.

**Status (updated 2026-08-25, second revision that day): `rocm-aic-spdk`'s *`pool_size`* STORE bug
(sub-section 1) is fixed and confirmed landing real I/O on `<SETUP3_TARGET_NODE>`, and the *separate* `-ENOMEM`
STORE failure that was blocking the serving path (sub-section 5) is now **fixed in source and
validated** — the L2 STORE path completes end-to-end.** The earlier wording of this paragraph said
sub-section 5 "blocks the serving path today"; that is **superseded and corrected** as of the
validation run below. Read to the end of this paragraph before acting on any single clause.
Fixed on both CIRRASCALE hosts (`<SETUP3_DECODE_NODE>` GPU 4 port 8300, `<SETUP3_PREFILL_NODE>` GPU 5 port
8301). The originally-predicted root cause (an unsplit value size overflowing the backend's
`max_value_size`) turned out to be **wrong for this model/config** — the real cause was a
drastically undersized `pool_size` default (see "Known gap" below for the full story). The
RETRIEVE-path "gap" found while verifying that fix turned out **not to be a real connector bug** —
traced end-to-end and confirmed L1 lookup+hit works correctly; the original symptom was a test
artifact (see sub-section 2). The **cross-instance key collision is now fixed and verified**:
`SPDK_NVMe_KV` keys off the descriptor's `metaInfo` instead of `(devId, addr)`, and a two-instance
run against one shared namespace goes from 8/8 silently-corrupted read-backs on the old derivation
to 0/8 on the new one (see sub-section 3). **That fix was necessary but NOT sufficient, and this
file's earlier claim that it was "the last blocker" to a genuine end-to-end L2 RETRIEVE test is
falsified.** The RETRIEVE test was attempted on 2026-08-25 on `<SETUP3_DECODE_NODE>` and **could not run**: the
L2 STORE it depends on failed first with `NIXL_ERR_BACKEND`, from a separate plugin defect —
`do_kv_io_async()` treated SPDK's transient, retryable `-ENOMEM` as a permanent failure, and the
serving path submits 3,520 descriptors at once against a documented safe pipeline depth of 32 (see
sub-section 5). Evidence, including the source-level confirmation and a zero-drift device-side
counter:
[`results/setup3-decode-node/2026-08-25-rocm-aic-l2-store/`](../../../results/setup3-decode-node/2026-08-25-rocm-aic-l2-store/).
**That defect is now fixed and the fix is validated (OBSERVED).** Re-running the identical prompt
with only the plugin changed, the store that previously died after 770 of 3,520 descriptors
completed **all 3,520**, with zero `NIXL_ERR_BACKEND`, and the retry path provably engaged rather
than being avoided:
[`results/setup3-decode-node/2026-08-25-rocm-aic-l2-store-enomem-fix/`](../../../results/setup3-decode-node/2026-08-25-rocm-aic-l2-store-enomem-fix/).
That validation is **category (2) on a RAM-backed target — it is not a DSC result**, it carries no
performance numbers, and it has **no server-side deployment record** (the deploy script aborted at
its health gate), which downgrades it per [`bench/README.md`](../../../bench/README.md).
**The L2 RETRIEVE test is now the next thing to attempt, and it STILL HAS NOT RUN** — nothing in
this repo yet demonstrates a genuine L2 hit end-to-end, and the fix above removes a blocker to
attempting it rather than attempting it. The likely next obstacle is the still-open **gap 4**
(sub-section 4): a retrieve test needs a real L1 miss, `/cache/clear` must **never** be used (it
corrupts in-flight ops) and `/reset_prefix_cache` deliberately leaves LMCache's L1 intact, so the
remaining lever is forcing a small `LMCACHE_L1_SIZE_GB` — which crashes
`NixlStorageAgent.init_mem_handlers` with `NIXL_ERR_NOT_FOUND` and has not been investigated.
`rocm-aic-xnvme` (the real-DSC
variant) is **still staged, never built or run** — follow the same build order, `rocm-aic-spdk`
first, before touching `.100`'s DSC, same posture as
[`stack/tracks/mori/README.md`](../mori/README.md) for that variant specifically.

A fourth KV-transfer path alongside NIXL, Mooncake and LMCache — except this one is not "our"
stack at all. [`ROCm/rocm-aic`](https://github.com/ROCm/rocm-aic) is AMD's own official
vLLM+LMCache+NIXL disaggregated-KV-cache inference stack, MIT-licensed, "early-access... not
recommended for production." Rather than re-derive that integration ourselves, this track uses it
**as-is** — same Dockerfile, same compose file, same Makefile — and adds exactly one thing: our two
existing NIXL storage backend plugins (`SPDK_NVMe_KV`, `XNVME_KV`, source of truth at
[`plugins/nvme-kv-plugin/`](plugins/nvme-kv-plugin/) and
[`plugins/xnvme-kv-plugin/`](plugins/xnvme-kv-plugin/) — **never forked**, only compiled
into rocm-aic's own build stage) so rocm-aic's LMCache can spill KV to the same two storage tiers
the rest of this repo already exercises.

Full research/design history: memory `project_rocm_aic_track_plan.md` (approved plan, 2026-08-18).

**Wider context for the gaps below.** Sub-sections 1-5 are this track's own bug list. They are also
instances of a general pattern that spans every track in this repo — silent success reporting,
absent flow control, non-content-addressed keys, no storage-tier eviction, and a read path that has
never fired. That cross-track assessment, and what a production-quality KV-offload path would
actually require, is
[`docs/analysis/kv-offload-production-readiness.md`](../../../docs/analysis/kv-offload-production-readiness.md);
the sequenced plan to close it is
[`docs/analysis/kv-offload-gap-closure-plan.md`](../../../docs/analysis/kv-offload-gap-closure-plan.md).
Gap 4 below is milestone **M1**'s critical path; the `pool_size`/page-granularity story in
sub-section 1 is milestone **M2**; the `metaInfo` key derivation in sub-section 3 is milestone **M3**.

### Pin

```
ROCM_AIC_REF = bb386562ccce21c12b8b577c7abcead68bc4befd   (2026-08-14)
```
Same-day pins baked into that commit's `docker/Dockerfile`: `ROCM_VERSION=7.14.0`
(`rocm/dev-ubuntu-24.04:7.14.0-full`), `VLLM_REF=v0.26.0`, `NIXL_REF=v1.3.2`,
`LMCACHE_REF=v0.5.3`, `HSA_SNOOP_REF=v1.0.0`. Same ROCm release our own `vllm-nixl:rocm` image
already uses. Bump `ROCM_AIC_REF` deliberately (`build.sh`'s `ROCM_AIC_REF=` var), not casually —
every patch under `patches/` was hand-verified against this exact commit and may not apply cleanly
against a newer one.

### Why patch LMCache, not NIXL, for the backend names

rocm-aic's LMCache runs as a standalone `lmcache server` (MP architecture,
`lmcache/v1/distributed/l2_adapters/nixl_store_l2_adapter.py`, `NixlStorageAgent` class), driven by
a CLI `--l2-adapter` JSON flag — a different, newer code path than the classic
`NixlStaticStorageBackend` YAML-config path our other `stack/tracks/lmcache/` track already patches.
This file independently allowlists backend names (twice: two module-level tuples, plus two more
inline lists inside `NixlStorageAgent.__init__`) before routing to
`init_storage_handlers_object(...)` — the exact OBJ_SEG / key-addressed path our two plugins already
implement. `patches/lmcache/15-add-spdk-xnvme-kv-l2-adapter-backends.patch` adds our two names to
all four lists, mirroring the shape of rocm-aic's own
`patches/lmcache/07-lmcache-nixl-ais-mt-l2-adapter.patch` (which does the identical thing for their
own `AIS_MT` backend). The NIXL plugin `.so`s themselves need zero source changes — `backend_engine.h`
(every virtual our plugins override) is byte-identical between NIXL v1.3.2 and upstream `main`.

### Why compile the plugins inside rocm-aic's own build stage, not mount pre-built `.so`s

Source-level API compatibility with NIXL v1.3.2 is confirmed (see above). ABI (compiled-artifact)
compatibility of our *existing* `.so`s — built against `nixl:n0`'s Ubuntu 24.04 / Python 3.14 image
— is unverified against rocm-aic's own base image, toolchain and NIXL build. Rather than gamble on
that, `patches/dockerfile/0003-build-plugins.patch` adds a build step to `docker/Dockerfile` itself,
right after its NIXL build (section 6, before the runtime-env section 7): build SPDK v26.05 + this
repo's 4 KV command-set patches
([`../../foundation/spdk-kv/patches/spdk-host/`](../../foundation/spdk-kv/patches/spdk-host/))
from source, then compile both plugins against that SPDK and the already-built NIXL at `/opt/nixl`,
installing both `.so`s into `/opt/nixl/lib/x86_64-linux-gnu/plugins/` — the same directory
`NIXL_PLUGIN_DIR` already points at, before that directory becomes part of the runtime image. Same
toolchain, same base image, zero cross-image ABI question.

Only the 4 `spdk-host` patches are applied here — not the larger 71-patch `spdk-<USER>` series
used elsewhere in this repo, matching the approved plan's scope (nothing in rocm-aic's LMCache
integration needs that series' extra surface).

### Known gaps: the STORE path, root-caused across several sessions (STORE now unblocked)

**2026-08-18 session**: predicted from static analysis that `NixlStorageAgent` registers one
storage object per full L1 chunk page with no split against the backend's `max_value_size`, and
that this silently no-ops STORE (`_execute_store_in_the_loop`'s blanket `except Exception`).
**2026-08-19 session**: confirmed the silent-failure symptom live on both `<SETUP3_DECODE_NODE>` and `<SETUP3_PREFILL_NODE>`
(`<SETUP3_TARGET_NODE>`'s `completed_nvme_io` counter unchanged despite LMCache logging `"Stored N tokens"`), then
implemented and shipped the predicted fix (`patches/lmcache/16-store-l2-adapter-value-size-split.patch`
— ports `stack/tracks/lmcache/patches/0002`'s `mem_split_n`/`_expand_split_indices` pattern to this
class's different single-page-per-key layout) — **but verifying it revealed the size-split theory
was not the actual root cause for this model/config**, and surfaced two further, separate gaps.
Read all five sub-sections below before touching this code again — the heading counted three when
it was written, and sub-sections 4 and 5 were added later. ~~**Sub-section 5 is the one that is
still open, and it is the one currently blocking the serving path**~~ — **superseded 2026-08-25**:
sub-section 5 is now fixed and validated. **Sub-sections 1-3 and 5 are fixed and are kept in full as
the evidence their fixes were built from; sub-section 4 is the only one still open**, and it is now
the likely obstacle to the L2 RETRIEVE test rather than a bystander.

#### 1. The real root cause: `pool_size` sized for chunks, not pages (FIXED)

Instrumenting `_resolve_mem_split()` with an unconditional log line
(`nixl_store backend %s: page_size=%d, declared max_value_size=%r`) revealed
**`l1_memory_desc.align_bytes` is 4096 B for TinyLlama's fp8 KV layout** — a raw memory page, not a
multi-MiB KV chunk as the file-based backends' own docstring guard (`file_size` guidance,
"8388608 for a 7B fp8 model with chunk_size=256") implied for this OBJ path too. At 4096 B, `page_size
(4096) < max_value_size (524288)`, so the size-split patch above is a correct no-op for this
config — it never fires, and STORE was *still* silently failing with it in place.

The actual cause: `init_storage_handlers_object()` registers **one storage object per L1 page**
(no `file_size`/`pages_per_file` grouping like the file-based backends get), so `pool_size` means
"total number of 4096 B pages the L2 tier can hold" — not "number of KV chunks" as
`docker-compose.storage.yml`'s `AIC_SPDK_KV_POOL` default of **64** assumed. A single 256-token KV
chunk (~2.75 MiB at this model's `cache_size_per_token=11264`) needs **~700 pages** — 11x the
entire pool. `NixlObjPool.batched_allocate()` requires all requested indices atomically and returns
`[]` on the very first key when the pool is this undersized; `_execute_store_in_the_loop` then hits
its "nothing to store" fast path and reports `L2StoreResult(True, 0)` — a **successful zero-byte
store**, with no warning logged, matching the LMCache-level `"Stored N tokens"` message that never
actually checks `bytes_transferred`. Confirmed via LMCache's own `/status` HTTP endpoint
(`docker exec aic-lmcache-spdk curl -s localhost:8080/status`): `pool_free_slots` stayed at the
pool's full capacity across "successful" stores.

**Fix**: `docker-compose.storage.yml`'s `AIC_SPDK_KV_POOL`/`AIC_XNVME_KV_POOL` defaults raised from
64 to 2,000,000, and `deploy-spdk.sh`/`deploy-xnvme.sh` now set the same value explicitly (passed
through to compose). **2,000,000 is an empirically-tested ceiling, not a value derived from
`LMCACHE_L1_SIZE_GB`** — registering NIXL OBJ descriptors was confirmed to blow up non-linearly:
2,000,000 came up healthy in ~90s, but 5,242,880 (the value that *would* match `LMCACHE_L1_SIZE_GB`'s
20 GiB default 1:1 at 4096 B/page) was still spinning at 100%+ CPU with zero forward log progress
after 10+ minutes and had to be aborted. Raising this further needs its own startup-time
verification, not just capacity math. **Confirmed fixed** on both hosts via `<SETUP3_TARGET_NODE>`'s
`completed_nvme_io`: <SETUP3_PREFILL_NODE> +790, <SETUP3_DECODE_NODE> +1531 (partial — see gap 3) across independent test
requests after redeploying with the corrected default.

The size-split patch (16) is **kept** — it's a real, correct defensive fix for any future
model/config where `l1_align_bytes` genuinely exceeds `max_value_size` (e.g. a larger model or a
smaller `XNVME_KV` ceiling of 32768 B), it's inert (returns `mem_split_n=1`) for every config
tested so far, and ripping it out to "simplify" would just mean re-discovering it later.

#### 2. RETRIEVE lookup: RESOLVED — not a real bug, was a test-methodology artifact (2026-08-19b)

**Closed.** Follow-up investigation traced the lookup path end-to-end through the vendored LMCache
v0.5.3 source and proved the mechanism works: `get_num_new_matched_tokens`
(`lmcache/integration/vllm/lmcache_mp_connector.py:1030`) unconditionally issues a `LOOKUP` RPC
(`vllm_multi_process_adapter.py:669`) for every new vLLM request, which reaches
`StorageManager.submit_prefetch_task()` → `PrefetchController.submit_prefetch_request()`. Storing a
fresh 836-token prompt, calling `POST /reset_prefix_cache` on vLLM (leaving LMCache's own L1
untouched), then resending the identical prompt produced a clean hit:
```
Prefetch request completed (L1+L2): 3/3 retained keys (3 L1, 0 L2) in 0.6 ms (prefetch_request_id=-1)
Retrieved 768 tokens in 0.023 seconds
```
vLLM's own `External prefix cache hit rate` metric flipped from 0.0% to 3.6% on the same resend.
So lookup → L1 hit → RETRIEVE is correct on this path.

**Why the original session saw all-zero counters even so**: `lookup_phase_count`/`load_phase_count`
(`prefetch_controller.py`) are **transient in-flight gauges, not cumulative totals** — they revert
to 0 within milliseconds of a request completing, so polling `/status` *after* the fact will read 0
whether or not a lookup just happened. Don't use them as a hit/miss signal; watch for the
`"Prefetch request completed"` log line instead.

**The real trigger for the original symptom**: the original test used `POST /cache/clear`
(not `/reset_prefix_cache`) to empty L1 before resending. `cache_api.py`'s clear handler ignores
the request body's `force` field and always calls the engine's **forced** clear path
(`L1Manager.clear(force=True)`, which self-documents: *"may corrupt in-flight store/prefetch
operations — use with caution"*). Reproduced deterministically twice: store → `POST /cache/clear`
→ `POST /reset_prefix_cache` → resend identical content → no `"Prefetch request completed"` log at
all, straight to a silent recompute + re-STORE. This is an upstream LMCache HTTP-API bug (already
flagged by a `# TODO(cache-control)` comment in AMD's own vendored source, not something this
repo's patches touch), not a bug in the connector's lookup logic. **Practical fix for future RETRIEVE
testing: use `POST /reset_prefix_cache` alone to force a re-lookup, never `/cache/clear`, until
upstream wires `force` through properly.**

A second, unrelated, harmless dead-code bug was found in the same trace:
`vllm_multi_process_adapter.py`'s `_ensure_heartbeat_started()` guards on `self._heartbeats is not
None`, but `self._heartbeats` is initialized to `{}` in `__init__` — so the guard is true on the
very first call and heartbeat threads never start. Fails open (`_health_events` are pre-`set()`),
so harmless today, but means this adapter can never detect a genuinely dead LMCache server. Neither
bug is in this repo's own patch set; both are candidates for an upstream report rather than a local
patch.

#### 3. Cross-instance key collision: two independent agents, one shared namespace (FIXED 2026-08-24, VERIFIED 2026-08-25)

> **Status 2026-08-25.** Built, deployed and verified. `SPDK_NVMe_KV`'s `make_key()` now derives the
> on-wire key from the descriptor's `metaInfo` when the caller sets one, falling back to
> `devId`/`addr` otherwise — the same derivation `XNVME_KV` already used. That removes the pool-slot
> aliasing described below at its root, and makes `kv_slot_offset` redundant on that path.
>
> **Corrected 2026-08-25: this fix was necessary but NOT sufficient, and it was NOT "the last
> blocker".** Both this banner's original framing and the narrative below called the collision the
> sole remaining obstacle to a genuine end-to-end L2 RETRIEVE test. That test was attempted on
> `<SETUP3_DECODE_NODE>` on 2026-08-25 and could not run — L2 STORE fails first with `NIXL_ERR_BACKEND`, from the
> separate, still-unfixed `-ENOMEM` defect in **sub-section 5**, which sits behind this one. Read
> sub-section 5 before treating this section as clearing the path. Note also that the verification
> recorded here was a synthetic two-instance test, not a serving run: **change C's correctness under
> real serving load is still not established**, because the 2026-08-25 store never completed and no
> key was ever durably written.
>
> **What the key actually is — read this before building anything on top of it.** Earlier drafts of
> this section (and of the plan behind it) called the new key *content-addressed / stable across
> processes*. **That is wrong.** Verified 2026-08-25 against the real LMCache 0.5.3 source extracted
> from `rocm-aic:latest` (`/app/LMCache`): both NIXL paths name device-side objects by pool slot plus
> a **per-process random UUID** — `f"obj_{i}_{uuid.uuid4().hex[0:4]}"` in
> `init_storage_handlers_object()`
> (`lmcache/v1/distributed/l2_adapters/nixl_store_l2_adapter.py`) and in `NixlObjectPool.__init__`
> (`lmcache/v1/storage_backend/nixl_storage_backend.py`), with the multipart patches appending
> `#{j}` so the on-wire name is `obj_{slot}_{rand}#{part}`. The LMCache chunk key never reaches the
> device. Registration is init-only — the plugins capture `metaInfo` at `registerMem()` and
> `postXfer()` reads it back off `metadataP` — so the object name is bound to the slot at process
> startup and cannot vary per chunk. These are **instance-unique slot names, not content-derived
> ones**. They fix the collision precisely *because* the random suffix differs per process; they do
> **not** enable restart survival, a cross-process existence oracle, or content sharing between
> deployments, and no amount of tuning at this layer will make them do so (a genuinely
> content-addressed scheme would need per-store deregister/re-register of the slot's storage
> descriptor, or a NIXL API change letting a transfer descriptor carry its own object name).
>
> **How it was verified — and the matched control that makes the result mean something.** The plugin
> was compiled against `rocm-aic:latest`'s own NIXL at `/opt/nixl`, so it is ABI-matched to the image
> it runs in, then driven from `<SETUP3_PREFILL_NODE>` by `validation/plugin-keys/spdk-cross-instance.py` (which
> reproduces LMCache's `NixlObjPool` registration shape exactly) against the RAM-backed
> `bdev_kvmalloc` target on `<SETUP3_TARGET_NODE>`:
>
> - **Old derivation** (`--legacy-keys`, which blanks `metaInfo` to force the `devId`/`addr` fallback
>   out of the *same* binary): instance A stored tag=11 into slots 0-7, instance B stored tag=22 into
>   the same slots, and A then read back **tag 22 on all eight slots — 8/8 silent corruption**. Every
>   store and every read reported success.
> - **New derivation**, with the identical temporal interleaving (A stores, B stores during A's
>   12-second pause, A then verifies): **0/8 mismatches**. A read back its own bytes, and all eight
>   of B's stores succeeded.
>
> The control is the point — a clean run in the default mode says nothing unless the same binary
> against the same target fails when forced back onto the old derivation.
>
> **The collision corrupted silently here, where the 2026-08-19 runs saw it fail loudly.** The
> narrative below records `NIXL_ERR_BACKEND` store failures (~30/30) as *the* observable, on the
> grounds that SPDK's KV command set rejects a STORE to an existing key. Against the target used for
> this verification it does not: `bdev_kvmalloc` permits overwrite, so the second writer's STORE
> succeeds and the first writer silently reads back the second writer's data — no error anywhere,
> which is how 8/8 wrong values came back reported as success. **Two observables, one root cause** —
> a loud duplicate-key rejection and silent cross-tenant corruption are the same collision presenting
> differently depending on what the backing store does with an existing key. So do not read "stores
> are succeeding" as "no collision", and do not treat §3 below as contradicted by this: it is the
> same bug wearing the other face.
>
> **The fix covers both halves of what this section used to describe** — the concurrent-deployment
> collision *and* the "stale keys left behind by an earlier session" collision. A per-process
> `uuid4()` suffix is exactly the per-deployment key salt the old text said was still needed: a fresh
> container's key space is disjoint from any previous run's as well as from any concurrent peer's.
>
> **Wiping the storage namespace is still worth doing, but it is now tidiness, not a correctness
> prerequisite.** The derivation changed, so everything stored under the old `(slot, offset)` scheme
> is unreachable landfill; on `<SETUP3_TARGET_NODE>` that means restarting the RAM-backed `nvmf_tgt` — safe there,
> the never-interrupt rule applies only to the real Pensando DSC. Skipping it costs memory on the
> target, not correctness.
>
> **What this is not.** Every run above was against a RAM-backed `bdev_kvmalloc` target over
> NVMe-oF/TCP on hosts with **no Pensando DSC** — category (2) per
> [`CLAUDE.md`](../../../CLAUDE.md), and a loopback number is never a result about the DSC. What is
> proven is the key derivation and the collision behaviour, which are host-independent properties of
> the plugin; nothing here is a statement about DSC throughput, latency, or firmware behaviour. The
> `XNVME_KV` path shares the derivation but was **not** retested on 2026-08-25.
>
> `validation/plugin-keys/test-key-derivation.sh` (no hardware, ~1s) additionally asserts both
> plugins derive byte-identical keys and that the case below no longer collides. Full context:
> `~/.claude/plans/hazy-kindling-moth.md`.

The rest of this section is the original 2026-08-19 investigation, kept because it is the evidence
the fix was built from — read it as history, not as current state.

Verifying the pool-size fix on `<SETUP3_DECODE_NODE>` with **fresh content never stored anywhere before** still
produced `NIXL_ERR_BACKEND` store failures (2 of 2 store tasks in one test), even though
`<SETUP3_TARGET_NODE>`'s `completed_nvme_io` kept moving (+1531) — i.e. partial success within a failed batch.

**Follow-up (2026-08-19b, during the RETRIEVE-gap investigation above): on a freshly-restarted
`<SETUP3_DECODE_NODE>` this is now *total*, not partial** — every one of ~30 STORE attempts in that session
failed with `NIXL_ERR_BACKEND` (`stored_object_count` stuck at 0, `pool_free_slots` stuck at the
full 2,000,000 throughout), while `<SETUP3_TARGET_NODE>`'s `completed_nvme_io` kept climbing regardless (6829 →
12672+, confirmed via `sudo python3 /home/<SETUP3_USER>/spdk-clean/scripts/rpc.py nvmf_get_stats`) —
i.e. wire-level I/O keeps completing, but every batch still fails the higher-level duplicate-key
check. This means the collision isn't only a concurrent-two-host problem: it also fires against
**stale keys left behind by any earlier session**, because the `nvmf_tgt` process on `<SETUP3_TARGET_NODE>`
backing `bdev_kvmalloc` is a long-lived native process (confirmed running continuously since
07:24, never restarted across container redeploys) — its KV namespace is never wiped, so a fresh
container's pool-slot-0-relative keys collide with whatever a previous run already wrote there.
At the time, this was believed to be **the sole remaining blocker to testing a genuine L2 RETRIEVE
(`prefetch_request_id != -1`) end-to-end** — gap 2 above was already closed, and this was what was
left. (**Corrected 2026-08-25**: that belief was wrong. Sub-section 5 records a second, independent
blocker — `-ENOMEM` treated as fatal — that stops L2 STORE from the serving path entirely.) A namespace wipe (restart `nvmf_tgt` — safe on this RAM-backed host per
[[feedback_dsc_no_flr]], which only applies to the real Pensando DSC) would have ruled out the
stale-key half but not the structural collision risk for multi-deployment runs; the durable fix was
judged to be a per-deployment slot-range offset or key salt, which is in effect what the `metaInfo`
derivation turned out to give for free (see the banner).
Root cause: the SPDK_NVMe_KV plugin's `make_key()` derived the on-wire KV key purely from
`(devId, addr)` of the transfer descriptor (confirmed via
`plugins/nvme-kv-plugin/src/spdk_nvme_kv_backend.cpp`'s `registerMem()` comment) —
`devId` is the storage pool slot index, allocated by each `NixlObjPool` starting from 0,
independently, per `NixlStorageAgent` instance. `<SETUP3_DECODE_NODE>`'s "prefill" and `<SETUP3_PREFILL_NODE>`'s "decode"
deployments are **two separate processes, each with their own pool starting at slot 0, both writing
to the same physical `<SETUP3_TARGET_NODE>` KV namespace** — so their early slot allocations collided on the same
on-wire keys. Against the target as configured for these 2026-08-19 runs, SPDK's KV command set
rejected a STORE to an already-existing key; against the one used for the 2026-08-25 verification
the same collision overwrote silently instead (see the banner). This was a structural multi-tenancy
gap: nothing in this track
partitioned the shared namespace across independent deployments. The plausible fixes considered at
the time (a per-deployment slot-range offset env var, or salting `addr`/`devId` with a per-agent
identifier) were superseded by the `metaInfo` derivation, which inherits LMCache's per-process
`uuid4()` object-name suffix and so partitions the namespace per deployment with no explicit
slot-range bookkeeping at all. **Running more than one `rocm-aic-spdk` deployment against the same
storage target was, until that fix, a way to intermittently drop stores or silently corrupt each
other's values**; a single deployment against `<SETUP3_TARGET_NODE>` was always unaffected.

#### 4. Known unrelated issue, not investigated (carried over from 2026-08-19)

Forcing a small `LMCACHE_L1_SIZE_GB` (e.g. `0.05`) to get a cleaner RETRIEVE-miss test crashes
`NixlStorageAgent.init_mem_handlers` with `NIXL_ERR_NOT_FOUND` from `prepXferDlist` on `<SETUP3_DECODE_NODE>`.
Untouched, not yet understood, likely unrelated to gaps 1-3 above.

#### 5. L2 STORE from the serving path: `-ENOMEM` treated as fatal (FIXED + VALIDATED 2026-08-25)

~~**This is what actually blocks the L2 RETRIEVE test today**~~ — **superseded**: the defect below
was fixed in source and validated the same day. The bug description and root cause are kept in full,
unedited, because this repo keeps superseded narrative as evidence; **"The fix" and "What validated
it" at the end of this sub-section are the current state.** The defect sat behind gap 3, not in
front of it. Two records, both category (2):

- the failure and its root-causing —
  [`results/setup3-decode-node/2026-08-25-rocm-aic-l2-store/`](../../../results/setup3-decode-node/2026-08-25-rocm-aic-l2-store/)
- the fix and its validation —
  [`results/setup3-decode-node/2026-08-25-rocm-aic-l2-store-enomem-fix/`](../../../results/setup3-decode-node/2026-08-25-rocm-aic-l2-store-enomem-fix/)

Category (2) throughout, in both runs: RAM-backed `bdev_kvmalloc` over NVMe-oF/TCP on `<SETUP3_TARGET_NODE>`,
**no Pensando DSC anywhere in the path**, so nothing here — including the validation — is a
statement about the DSC.

**Symptom (OBSERVED).** Driving the `rocm-aic-spdk` deployment on `<SETUP3_DECODE_NODE>` (`aic-vllm-gpu4` port
8300 + `aic-lmcache-spdk`) with a deterministic 1456-token prompt — 1456 / 256 = 5 complete
offload-eligible chunks — LMCache admits 5 objects / 14,417,920 B into L1, logs `Stored 1280 tokens
in 0.029 seconds`, and then **67 ms later** `getXferStatus` returns `NIXL_ERR_BACKEND` and all five
`ObjectKey`s fail together, none partially. `stored_object_count` stayed 0 and `pool_free_slots`
stayed at the full 2,000,000. That `Stored N tokens` line reflects **L1 admission only, not L2
durability** — the same trap as sub-section 1's zero-byte store; do not quote it as evidence of
offload.

**Not the silent zero-byte store of sub-section 1 (OBSERVED).** `<SETUP3_TARGET_NODE>`'s `completed_nvme_io` went
**24934 → 25704, delta +770**, against a baseline sampled three times at ~8 s intervals that read
24934 every time — zero background drift, so the delta is fully attributable to this store. The
plugin is not no-op'ing: it starts a genuine transfer, moves real data over a real transport, and
then hard-fails partway. The failure is also **loud**, not silent. Distinguishing this from the
sub-section 1 signature is the point of that run. The fixed plugin was confirmed to be the one
actually loaded (sha256 `5b057cb5…`, 3805488 bytes, verified *inside the running container* and
distinct from the image's stale 3935440-byte 2026-08-18 copy), so this is not an artifact of running
the wrong binary; change C was active and change D inert
(`NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` deliberately unset).

**Root cause (CONFIRMED IN SOURCE, not inferred from behaviour).** `postXfer()` dispatches every
descriptor immediately, with no depth limiting:

```
    spdk_thread_send_msg(thr, do_kv_io_async, work);   // once per descriptor
```

and `do_kv_io_async()`
([`plugins/nvme-kv-plugin/src/spdk_nvme_kv_backend.cpp`](plugins/nvme-kv-plugin/src/spdk_nvme_kv_backend.cpp)
line 186) does:

```
    if (rc != 0) kv_complete_cb(work, false);
```

Any nonzero return from `spdk_nvme_kv_store` is treated as a permanent failure — **including
`-ENOMEM`, which is SPDK's normal, transient, retryable "submission queue full"**. Grepping the
whole file for `ENOMEM` / `EAGAIN` / retry / backpressure / `in_flight` / `queue_full` returns
nothing: there is no flow control and no retry anywhere on this path.

**The arithmetic closes exactly:**

```
  bytes per chunk        : 256 tokens x 11264 B/token = 2,883,584
  page size (l1_align)   : 4,096
  descriptors per chunk  : 704
  5 chunks               : 3,520 descriptors submitted essentially at once
  completed before fail  : 770  (21.9%)

  documented SAFE pipeline depth for this backend : 32
  what the serving path actually submits          : 3,520  -> 110x over
```

**Why this is structural, not a tuning problem.** The defect itself was already known and documented
— the `kv-cache-bench-ops` skill (Section 6, step 3) and `bench/lib/preflight.sh` (which treats
`PIPELINE_DEPTH > 32` on `SPDK_NVMe_KV` as FATAL) both record it. What is new here is that it had
only ever been characterised as a **tuning limit in synthetic `nixlbench` sweeps** — something you
avoid by not turning the knob up. **The real serving path has no such knob.** LMCache's chunk
geometry (256 tokens at 4096 B/page) structurally dictates 3,520 concurrent ops, and nothing in this
stack can dial that down. So it is not a tuning caveat on this path but a hard blocker that no
amount of configuration avoids.

~~**`XNVME_KV` is LIKELY affected too — but this is an INFERENCE, not a measurement.** It was **not**
retested on 2026-08-25, before or after the fix. It shares the same `do_kv_io_async` structure, which
makes the identical defect very likely, but nothing was measured and no claim about it should be made
on this evidence. **Concrete follow-up (INFERENCE-driven, not evidence-driven): `XNVME_KV` should
receive the same five-part change described below.** It is **not fixed and not tested**; that
statement comes from reading the code, not from running it. This matters more than it looks, because
`XNVME_KV` is the category-(1) path — the one that actually talks to the real DSC — so the serving
path on the end-goal hardware is presumed to still carry this defect.~~ — **that inference was
WRONG; corrected 2026-08-26 immediately below.**

**Correction (2026-08-26): the `XNVME_KV` inference above is FALSE, and reading the source says so
plainly (CONFIRMED IN SOURCE, not measured).** `XNVME_KV` has no `do_kv_io_async` and has handled
this exact failure class correctly since **2026-08-03**. In
[`plugins/xnvme-kv-plugin/src/xnvme_kv_backend.cpp`](plugins/xnvme-kv-plugin/src/xnvme_kv_backend.cpp),
`submit_one()` returns `SubmitResult::kRetry` for `-EBUSY`/`-EAGAIN`/`-ENOMEM` instead of failing the
work item; `reactor_loop()` then pushes that item back onto the **front** of its local backlog, breaks
out of the submit pass, calls `xnvme_queue_poke()` to reap completions, and retries on the next
iteration. Ctx-pool exhaustion (`xnvme_queue_get_cmd_ctx()` returning `NULL`) takes the same back-off
path. The comment at `submit_one()` names the `SPDK_NVMe_KV` `do_kv_io_async()` bug explicitly, as the
known-bad counterexample it was written to avoid. So `XNVME_KV` never needed the five-part fix
above — the SPDK fix effectively reinvented `XNVME_KV`'s design. The structural-similarity claim was
never checked against the file; it should have been.

**Two DIFFERENT, real gaps did exist in `XNVME_KV`, were found on 2026-08-26 while checking the above,
and are now fixed in source. Both fixes COMPILE CLEAN and have NEVER BEEN RUN** (status at the end of
this sub-section).

- **Gap 1 — the retry loop was unbounded.** If the device stopped completing, work was re-queued
  forever, `req->pending` never reached 0, and `checkXfer()` returned `NIXL_IN_PROG` for all time: a
  permanent hang, not an error. This matters far more here than on the SPDK path, because `XNVME_KV`
  is the route to the **real Pensando DSC**, whose single documented failure mode is exactly "stops
  completing and never recovers" (see [`../../../CLAUDE.md`](../../../CLAUDE.md)'s safety section).
  **Fix:** a stall check in `reactor_loop()` — if NO forward progress (no submission accepted, no
  completion reaped) occurs for `NIXL_XNVME_STALL_TIMEOUT_SEC` (default 30 s; 0 disables) while work
  is outstanding, it reports loudly and fails the queued backlog. New `QueueWorker` fields
  `last_progress_ns`, `in_flight`, `stall_reported`.
- **Gap 2 — queued work was dropped at shutdown.** `reactor_loop()` exited and called
  `xnvme_queue_drain()`, which only completes **in-flight** ops; items still in the local backlog and
  in `qw->mbox` were silently abandoned. Each holds a decrement of `req->pending`, so a shutdown with
  work still queued left callers blocked forever. **Fix:** a new `fail_queued_work()` fails both
  queues instead of dropping them, called at shutdown and when the stall check trips.

**Three limits of the stall check, stated plainly rather than glossed:**

1. It can only fail **queued (unsubmitted)** work. In-flight ops are still owned by xNVMe — their
   `cmd_ctx` may yet complete, and completing them from the reactor would race
   `completion_trampoline` into a double free of the same work item. **A wedge that occurs AFTER
   submission therefore still hangs the caller.** What the check buys is a loud, named diagnosis
   instead of silence. That is a property of the wedge, not a shortcoming that could be honestly
   fixed here.
2. It deliberately attempts **no device recovery** — no reset, no FLR, no re-init. Per
   [`../../../CLAUDE.md`](../../../CLAUDE.md), host-side attempts to clear a wedged DSC make it
   strictly worse; only an out-of-band DPU-side restart recovers it. Turning a permanent hang into a
   reported failure is the whole goal.
3. The `in_flight` counter and the idle-refresh rule exist to prevent **false positives**: an idle
   queue must not trip the check the moment work next arrives, and a device that is merely saturated
   keeps completing, which keeps refreshing the clock.

**Also fixed: [`plugins/xnvme-kv-plugin/build.sh`](plugins/xnvme-kv-plugin/build.sh) could
not build against `rocm-aic` at all.** It hardcoded `-Dnixl_path=/usr/local/nixl` (the sibling
`nvme-kv-plugin/build.sh` had gained a `NIXL_PATH` knob; this one never did) and could only
bind-mount xNVMe from the **host**, while the CIRRASCALE hosts have no host-side xNVMe and
`rocm-aic:latest` ships xnvme 0.7.5. Added `NIXL_PATH` and `XNVME_FROM_IMAGE=1`. Same
"sibling scripts drifted apart" pattern as the `MAX_MODEL_LEN` gap fixed earlier the same day.

**Validation status: COMPILED CLEAN, NEVER RUN (OBSERVED for the build only).** Built inside
`rocm-aic:latest` on `<SETUP3_DECODE_NODE>` with `XNVME_FROM_IMAGE=1 NIXL_PATH=/opt/nixl`; exit 0. Artifact sha256
`b858b7cc5be840ba638a86798a3e7458a438de2f35d85972f5d2db542c52d048`, 122984 bytes (the pre-change
in-image plugin is 93672 bytes, dated 2026-08-18, and greps 0 for the new stall string). `strings`
confirms the stall diagnostic and `NIXL_XNVME_STALL_TIMEOUT_SEC` are in the binary; `ldd` resolves all
27 dependencies with zero "not found", including the image's own `libxnvme.so.0`. Zero compiler
warnings at the project's own settings (an extra `-Wextra` pass showed only pre-existing
upstream-header noise plus one pre-existing unused parameter in `prepXfer`). **There was NO RUNTIME
TESTING WHATSOEVER: the stall path has never executed, neither gap's fix has been exercised against
hardware, and `<SETUP2_PD_NODE_IP>` was not touched.** Runtime validation needs the real DSC there. Compiling
is not working — category (1) hardware remains unvalidated for this change.

~~**Fix direction.** Make `-ENOMEM` retryable in `do_kv_io_async()` rather than fatal … Until then
the `rocm-aic-spdk` serving path cannot store to L2 at all, and the L2 RETRIEVE test cannot be
attempted.~~ — **superseded 2026-08-25 by the fix below.**

**What the failing run did NOT establish.** Nothing about **change C's correctness under serving
load** — the store never completed, so no key was ever durably written, and that run must not be
cited as evidence that the `metaInfo` derivation works end-to-end. Nothing about RETRIEVE, L1-vs-L2
hit behaviour, prefetch, or the `/reset_prefix_cache` methodology (phase 3 was never run: with
`stored_object_count = 0` there was nothing in L2 to retrieve). Nothing about the DSC. And no
throughput, latency or serving performance of any kind — there are no performance numbers in that
directory and none should be derived from it.

---

##### The fix (landed 2026-08-25)

Source changes to
[`plugins/nvme-kv-plugin/src/spdk_nvme_kv_backend.h`](plugins/nvme-kv-plugin/src/spdk_nvme_kv_backend.h)
and
[`plugins/nvme-kv-plugin/src/spdk_nvme_kv_backend.cpp`](plugins/nvme-kv-plugin/src/spdk_nvme_kv_backend.cpp)
(which also still carry changes C and D from the 2026-08-24/25 work). Five parts:

1. **`-ENOMEM`/`-EAGAIN` on submission defers instead of failing.** The work item goes onto a
   per-reactor retry queue rather than straight to `kv_complete_cb(work, false)`. **Both signs of
   the errno are accepted**, so the fix cannot silently fail to engage if SPDK's sign convention
   differs from what was assumed.
2. **The retry queue is drained in the reactor loop AFTER
   `spdk_nvme_qpair_process_completions()`, and that ordering IS the mechanism.** Processing
   completions is precisely what frees the submission slots a deferred op is waiting on; draining
   before would retry into a still-full queue and make no progress. Retries are deliberately **not**
   re-posted via `spdk_thread_send_msg()` — that re-enters the message ring, which
   `spdk_thread_poll()` may drain within the same iteration, starving the completion processing that
   makes progress possible in the first place.
3. **A deadline, default 30 s, tunable via `NIXL_KV_ENOMEM_TIMEOUT_SEC`**, so a genuinely stalled
   device fails instead of leaving the transfer pending forever. **This path never triggered in the
   validation run and is therefore UNTESTED.**
4. **Items still deferred at engine shutdown are FAILED, not dropped.** Each deferred item holds a
   decrement of `req->pending`; dropping one would hang a caller inside `checkXfer()`/`waitXfer()`.
5. **`spdk_thread_send_msg()`'s return value is now checked.** Ignoring it — the prior behaviour —
   turned a full message ring into a leak: the item was never delivered, `req->pending` was never
   decremented, and the caller blocked forever. A reported error is strictly better than a silent
   hang.

Note that the fix is flow control by **deferral**, not by the in-flight *cap* in `postXfer()` that
the superseded "fix direction" above proposed. `postXfer()` still dispatches all 3,520 descriptors;
the backend now absorbs the resulting backpressure rather than dying on it.

##### What validated it (OBSERVED)

Full record and exact counter samples:
[`results/setup3-decode-node/2026-08-25-rocm-aic-l2-store-enomem-fix/`](../../../results/setup3-decode-node/2026-08-25-rocm-aic-l2-store-enomem-fix/).
Byte-identical prompt to the failing run (sha256 `5be4c8ce…`, 7290 B, 1456 tokens), same host, same
deployment shape — **only the plugin changed**, and the plugin under test (sha256 `2760a3f5…`,
3818936 bytes) was verified by `sha256sum` *inside the running container* and confirmed distinct
from the previous build (`5b057cb5…`, 3805488 bytes).

**The retry path demonstrably engaged.** The one-shot notice fired:

```
  [SPDK_NVMe_KV] submission queue full (-ENOMEM); deferring and retrying after
  completions drain. This is normal backpressure under a deep batch, not an error.
```

This is what makes the run meaningful — a run that simply never hit backpressure would have proven
nothing. (The aggregate `submission backpressure: N op(s) deferred` line is printed only from
`stop_spdk_reactor()` at engine teardown, which had not happened when the logs were read, so **the
count of deferred ops is unknown** — only that deferral happened at least once.)

**The store completed, and three independently derived numbers agree to the unit:**

```
  descriptors expected (5 chunks x 704 pages) : 3,520
  LMCache pool_free_slots  2,000,000 -> 1,996,480 : -3,520
  <SETUP3_TARGET_NODE> completed_nvme_io  25705 -> 29225       : +3,520
    (baseline sampled twice ~8 s apart, 25705 both times — zero drift, target otherwise idle)

  NIXL_ERR_BACKEND occurrences : 0   (previously 1)
  store task failures          : 0
  stored_object_count          : 0 -> 5
  store controller             : drained to 0 pending / 0 in-flight
  allocator                    : 5 active allocations, 13.75 MB, no leak
```

Compare the pre-fix run on the same input: **+770 of 3,520, then a hard failure.**

##### Honest caveats on the validation

- **Category (2), RAM-backed target only.** `bdev_kvmalloc` over NVMe-oF/TCP. This validates the
  fix's concurrency **logic**; it says nothing about the real DSC's `-ENOMEM` rate or drain latency,
  and the 30 s deadline path was never exercised.
- **No server-side deployment record exists for this run.** The deploy script aborted at its health
  gate, so `deployment_record_write` never ran; per [`bench/README.md`](../../../bench/README.md)
  that downgrades anything measured against the deployment. The correctness observations rest on
  counters read directly from LMCache and from the SPDK target rather than on the record, but the
  gap is real.
- **An unexplained ~17-minute vLLM startup hang occurred, and the fix is NOT exonerated for it
  (OBSERVED symptom, UNRESOLVED cause).** On the first start after container recreate,
  `aic-vllm-gpu4` hung with one thread pinned at 100% CPU, byte-identical `VmRSS` across samples
  (zero forward progress), no inductor compilation active, GPU at 0%, and no TCP connection ever
  opened to the LMCache container; a single `docker restart` cleared it and the server was healthy in
  40 s. Two things point away from the plugin — the vLLM container does not `dlopen` it, and the
  pre-fix deployment shows a circumstantially similar 8.5-minute gap between its lmcache and vllm
  container creation timestamps — but **the discriminating experiment (redeploy with the old
  `5b057cb5…` plugin) was NOT run**. n=1 either way. Open question, not dismissed.
- **No performance claim.** `Stored 1280 tokens in 0.030 seconds` is a log line from a single
  unrepeated request, **not a throughput figure** — the same trap the failing run records at 0.029 s.
- **Nothing about sustained or concurrent load**, and therefore still nothing about change C's key
  derivation under it. One request, one process.
- **The L2 RETRIEVE test still has not run.** This removes a blocker to attempting it; it does not
  attempt it.

### Two backends, two categories (read [the repo's end goal](../../../CLAUDE.md) first)

| Track name | Backend | Target | Category |
|---|---|---|---|
| `rocm-aic-spdk` | `SPDK_NVMe_KV` | RAM-backed `bdev_kvmalloc` SPDK TCP target on `<SETUP3_TARGET_NODE>` (CIRRASCALE, no real DSC) | **(2)** — workaround for hardware unavailability |
| `rocm-aic-xnvme` | `XNVME_KV` | Real Pensando DSC NVMe-KV device on `<SETUP2_PD_NODE_IP>` (PCIe `0000:1c:00.0`) | **(1)** — the actual end-goal hardware |

A `rocm-aic-spdk` number is never a result about the DSC. Verify `rocm-aic-spdk` end-to-end first —
it's the cheaper, hardware-independent path to catching build/integration bugs — before touching
the real device with `rocm-aic-xnvme`. When running against `.100`, the DSC safety rule applies in
full: **never kill, stop, or `timeout`-wrap anything that touches the DSC** — see
[`../../../CLAUDE.md`](../../../CLAUDE.md)'s safety section and the `kv-cache-bench-ops` skill.

### Layout

Flattened to the repository root on this branch:

```
DESIGN-AND-KNOWN-ISSUES.md   — this file
README.md                    — the SPDK_NVMe_KV build-and-run procedure
README-XNVME.md              — the XNVME_KV procedure (real device)
build.sh                     — clone rocm-aic to the pinned commit, stage plugins, patch, `make build`
                               (SKIP_BUILD=1 vendors without building)
target.sh                    — RAM-backed SPDK NVMe-KV loopback target
patches/
  lmcache/
    15-add-spdk-xnvme-kv-l2-adapter-backends.patch   — the 4-list-edit LMCache patch (see above)
    16-store-l2-adapter-value-size-split.patch
    17-add-spdk-xnvme-kv-storage-backend.patch
  dockerfile/
    0003-build-plugins.patch                          — adds the plugin-build stage to docker/Dockerfile
  spdk-host/                                          — 4 KV-command-set diffs, staged into the build
nixl-plugins/
  nvme-kv-plugin/              — SPDK_NVMe_KV backend source
  xnvme-kv-plugin/             — XNVME_KV backend source
lib/deployment.sh            — server-side provenance record; every deploy script sources it
docker-compose.storage.yml   — compose override: --l2-adapter flags + device/volume mounts for
                                each backend
deploy-spdk.sh               — bring up rocm-aic-spdk against <SETUP3_TARGET_NODE>'s SPDK target
deploy-pd-spdk.sh            — two-role P/D via the shared store
deploy-xnvme.sh              — bring up rocm-aic-xnvme against the real DSC on <SETUP2_PD_NODE_IP>
```

### Build/test order (de-risk cheapest first — do not skip ahead)

1. `SKIP_BUILD=1 bash build.sh` — pin the commit, confirm the SHA.
2. `git apply --check` both patches against fresh checkouts before wiring them into the real build
   (LMCache v0.5.3 + rocm-aic's own 14 patches applied first, in order, for `15-*.patch`; a bare
   `docker/Dockerfile` for `0003-build-plugins.patch`) — this repo already got bitten once by a
   corrupt hand-authored patch on a different track (see memory
   `project_3node_storage_target_plan.md`), so always generate patches from a real diff, never by
   hand-editing hunk headers.
3. `docker build --target build` the plugin-compile stage standalone before the full image, for
   fast iteration on the SPDK-from-source step in particular (it is the slowest new addition).
4. Full `make build` — substantial (vLLM from source + LMCache + NIXL + our plugins + SPDK from
   source). Background it, don't block on it.
5. `bash deploy-spdk.sh` against `<SETUP3_TARGET_NODE>` first. Verify STORE via `<SETUP3_TARGET_NODE>`'s `nvmf_get_stats`
   `completed_nvme_io` counter (**not** `bdev_get_iostat`, which never moves for SPDK's KV command
   set — confirmed elsewhere in this repo). Explicitly check whether RETRIEVE fires
   (`need to load: [1-9]` / a "Retrieved" log line) — this is a different LMCache architecture than
   the one where this repo's other LMCache track found RETRIEVE to be broken, so it's genuinely
   worth re-checking rather than assuming the same bug.
6. Only after `rocm-aic-spdk` is verified, `bash deploy-xnvme.sh` against the real DSC on `.100`.

### Register in `bench/tracks.registry`

`rocm-aic-spdk` and `rocm-aic-xnvme` — see that file for the exact entries.
