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
| `MODE=mp` *(default)* | `LMCacheMPConnector` → standalone `lmcache server` container | single node, `kv_both` — [walkthrough](#walkthrough--lmcache-in-mp-mode-the-sidecar) |
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
| `BACKEND=spdk MODE=mp` (sidecar) | **Verified end-to-end 2026-09-11** — store *and* retrieve confirmed on a live stack (`Stored 1280` then `Retrieved 1280 tokens`, target `completed_nvme_io` moving). **Requires `VLLM_EXTRA_ARGS="--no-enable-prefix-caching"`**: the vendored compose hardcodes `--enable-prefix-caching`, and before 2026-09-11 `deploy.sh` dropped the override in MP mode, so retrieve never fired and every MP number measured vLLM rather than storage. |
| KV correctness | **FIXED 2026-09-09.** Every chunk written before `patches/0009` was half-empty and mis-strided — LMCache built a 2-plane split staging destination for vLLM 0.26's 1-plane fused cache. Use `rocm-aic:kv-planefix` or newer; anything older stores corrupt KV. |
| `BACKEND=spdk MODE=inprocess`, single node | **Verified 2026-09-09.** Store, restart, read back: needle recovered with `need to load: 1024`. Retrieval is 2.40x faster than recompute at c=1 (TinyLlama). |
| **P+D disaggregated, two hosts** | **Verified end-to-end, re-verified 2026-09-11** — 8/8 needles through the proxy with `need to load: 1280` on the receiver and `load: 0` on the producer, 40 stores and 40 retrieves, zero failures. **Requires `AIC_KV_POOL=0` on both roles**; the previously documented static default moves no KV at all while still returning correct answers. See walkthrough Step 5. |
| **P+D on a real model** | **Verified 2026-09-09** — `Qwen/Qwen2.5-72B-Instruct` at **TP=4**, 4/4 needles, `need to load: 1152` on the receiver. Needs **`AIC_CHUNK_SIZE=128`**: at the default 256 a chunk is 20 MiB against the device's 16 MiB single-value ceiling and the STORE kills the server with `NIXL_ERR_BACKEND`. Also needs `--disable-custom-all-reduce` — see "TP>1" below. |
| Store size ceiling | **A chunk is one object, capped at the controller's max transfer size (16 MiB here).** Per rank: `layers * chunk_size * (kv_heads/TP) * head_size * 4` bytes. Every result before 2026-09-09 was TinyLlama at 5.5 MiB and never approached it, so `patches/0007`'s multipart split has **never actually carried a chunk**. |
| `patches/0009` vs upstream | **Superseded.** The defect is upstream ([LMCache #4463]), and [LMCache #4467] fixes it more thoroughly. #4467 was **validated on MI300X 2026-09-09** — built with `patches/0009` removed, it passes both single-node store/restart/retrieve and 72B TP=4 two-host P/D. `patches/0009` ships only until #4467 merges; it is not for upstreaming. See HANDOFF OPEN-2. |
| P+D performance | **Measured, and disaggregation currently loses.** On the SPDK path a P+D pair ran 2.4–5.8x slower than a single non-disaggregated node on twice the GPUs. The cause is the KV transfer path, not the routing: it sustains ~16% of line rate (513 MB/s median on a 25 Gb/s link). Treat the verdict as **provisional** — the same work runs at 1890 MB/s through `XNVME_KV`, and nobody has re-run the P+D sweep there. See HANDOFF OPEN-1 and OPEN-10. |
| KV path bandwidth, SPDK target | **513 MB/s median** (min 450 · max 548, n=8, TinyLlama 0.0269 GB), 16.4% of a 25 Gb/s link. Modelled as `T = N_objects * 3.89 ms + bytes / 599 MB/s`, validated on a held-out chunk size to within 1%. **Always scrape this from LMCache's own per-request accounting** — off the receiver for a P/D pair, or with `kv_path_bench.sh` against a single `kv_both` instance. Never derive it by subtracting a decode probe, which is how the superseded 617 MB/s figure was produced. See walkthrough Step 9. |
| Everything else | **STAGED, NEVER RUN.** Derived from reading `ROCm/rocm-aic @ bb386562`, our own plugin/LMCache sources and `patches/` — not from an execution. |
| Model | `Qwen/Qwen2.5-72B-Instruct` is ~145 GB in bf16 — **~36 GB/rank at TP=4, which fits comfortably on four 192 GB MI300X and does not need all eight.** (An earlier revision said TP=8 and "all 8 GPUs per node"; that was circular — it assumed TP=8 and derived the GPU count from it.) It will **not** fit a single-MI210 host. The only host with a real NVMe-KV function *is* a single MI210 — so `BACKEND=xnvme` is limited to small dense models. No `aiter`/`flash_attn` here, so **no MLA model** (DeepSeek-V2/V3, Kimi) runs at all. |
| Hostnames | Placeholders throughout (`<SETUP2_PD_NODE_IP>`, `<token>`), including in script defaults. Supply real values via the environment variables each script documents. |

Treat a first invocation as bring-up, not a benchmark: watch it fail, fix the actual error, and do
not trust a number until a correctness check has passed.

---

## How the KV actually moves — two paths, one target

Everything in this repo is one of **two NIXL storage plugins**, both built from `plugins/` into the
image (never mounted as pre-built `.so`s). They are not alternatives at the fabric level: **they
reach the same SPDK NVMe-KV target over the same TCP link.** They differ only in *which initiator*
carries the NVMe KV command set. That is the whole experiment.

```
                    vLLM  →  LMCache connector  →  LMCache NixlStorageBackend  →  NIXL agent
                                                                                      │
                    ┌─────────────────────────────────────────────────────────────────┴──┐
                    ▼                                                                    ▼
      libplugin_SPDK_NVMe_KV.so                                      libplugin_XNVME_KV.so
        (plugins/nvme-kv/)                                             (plugins/xnvme-kv/)
                    │                                                                    │
      SPDK *userspace* NVMe-oF/TCP                                  xnvme → ioctl / io_uring_cmd
          initiator, in-process                                            on /dev/ng3n1
                    │                                                                    │
                    │                                                  Linux *kernel* nvme-of
                    │                                                        (nvme_tcp)
                    │                                                                    │
                    └──────────────────────► TCP :4420 ◄─────────────────────────────────┘
                                                 │
                                    SPDK NVMe-KV target (bdev_kvmalloc)
                                       NQN nqn.2024-01.io.nixl:kv0
```

| | `SPDK_NVMe_KV` | `XNVME_KV` |
|---|---|---|
| source | `plugins/nvme-kv/` | `plugins/xnvme-kv/` |
| initiator | SPDK userspace, inside the vLLM process | Linux kernel nvme-of (`nvme_tcp`) |
| configured with | a **network address** — `trid: "trtype:TCP … traddr:<target> trsvcid:4420 subnqn:…"` | a **device path** — `dev_uri: "/dev/ng3n1"` |
| host prerequisite | none beyond reachability | `nvme connect` to the target; the char device must exist |
| device mapped into container | none | `/dev/ng3n1` |
| measured retrieval | **513 MB/s** (16.4% of a 25 Gb/s link) | **1890–1966 MB/s** (~61%) |

**The naming is the trap.** `plugins/nvme-kv/` builds `libplugin_SPDK_NVMe_KV.so`, which does
**not** go through the kernel nvme driver. If you are drawing the kernel nvme-of hop, you are
drawing `XNVME_KV`.

You can see both initiators simultaneously on one host, to the same target — note which sockets
have an owning process and which do not:

```
ESTAB  <host>:58184  <target>:4420                                                  ← kernel socket (nvme_tcp)
ESTAB  <host>:48044  <target>:4420  users:(("VLLM::EngineCor",pid=…,fd=114))        ← userspace socket, SPDK plugin
```

Three consequences worth internalising before you debug anything:

- **`max_hw_sectors_kb` is a kernel queue property, so it constrains `XNVME_KV` only.** The stale
  nvme-of association that caps transfers at 1 MiB and fails reads as `sct=7 sc=234` cannot happen
  on the SPDK path, which has no kernel queue. Checking `/sys/class/nvme/...` while debugging an
  `SPDK_NVMe_KV` problem is looking at unrelated local SSDs.
- **`nvmf_get_stats` on the target sees both**, because both terminate at the same SPDK target. It
  is shared, so treat it as "did any I/O happen", not as your byte count.
- **The 3.7x gap between them is not a fabric result.** Same target, same link, same payload, same
  host — so the ceiling the SPDK path hits is a property of that initiator, not of NVMe-oF/TCP.
  `[SPDK_NVMe_KV] 1 qpair(s) ready` is the leading suspect.

One more distinction that is easy to misread from the config: **NIXL is used here as a *storage*
backend, not as LMCache's peer-to-peer PD transfer channel.** The running config has
`enable_pd: False`, `pd_role: None`, `transfer_channel: None` — all of LMCache's own PD machinery is
off. Disaggregation is done externally by `proxy.py` plus a shared storage tier, and the producer
and decoder never talk to each other. That is deliberate: it makes the storage tier the only thing
under measurement.

---

# Walkthrough — P+D disaggregated across three nodes

This is the hand-held version of Steps 1–5 below: one continuous procedure, in the order you
actually type it, with a checkpoint after every step. **Read this if you just want it running.**
Read Steps 1–5 and *Design and known issues* when something breaks.

## What you are building

```
                              ┌─────────────────┐
   your prompt ──────────────►│    proxy.py     │
                              │      :9005      │
                              └────────┬────────┘
                        1. prefill     │      2. decode
                    ┌──────────────────┘      └──────────────────┐
                    ▼                                            ▼
          ┌───────────────────┐                        ┌───────────────────┐
          │   PREFILL node    │                        │   DECODE node     │
          │   vLLM :8405      │                        │   vLLM :8405      │
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
| `rocm-aic:latest` with both plugins on both vLLM hosts | Step 2 of this walkthrough |
| Model weights cached on **both** vLLM hosts | `du -sh "$HF_HOME"/hub/models--*` |
| Docker access as your normal user (**not** via `sudo` on an NFS home) | `docker ps` works unprivileged |
| **≥512 hugepages already allocated** on both vLLM hosts | `cat /proc/sys/vm/nr_hugepages` |

### Allocate hugepages first — this is the one thing that needs root

`BACKEND=spdk` uses SPDK's DPDK path, which needs hugepages. `deploy.sh` tries to allocate them
itself, and **that write is not guarded**: under `set -euo pipefail` it runs

```bash
echo 512 > /proc/sys/vm/nr_hugepages
```

with no `sudo` and no fallback. So on a host with fewer than 512 already allocated, **a non-root
deploy aborts there** — which is exactly the deploy this page tells you to run. Do it once, up
front, and the deploy skips the branch entirely:

```bash
for H in $PREFILL $DECODE; do ssh $H 'sudo sysctl -w vm.nr_hugepages=512'; done
```

**Raise it to 4096 before any TP>1 run** — each rank builds its own SPDK instance, and `deploy.sh`
only ever raises to 512 and never lowers. `BACKEND=xnvme` needs none of this; `io_uring_cmd` does
not use hugepages.

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

### Give it an immutable tag before you deploy anything

`build.sh` produces **`rocm-aic:latest`** and nothing else. `:latest` is a moving label — it is
reassigned by the next build on that host, and two hosts that both say `:latest` routinely hold
different content. The rest of this walkthrough deploys `rocm-aic:kv-planefix`, so pin it.

**Check the content before you pin it.** The name `kv-planefix` asserts that the image carries
`patches/0009`, the fused-KV-plane fix — and an image without it stores **silently corrupt KV**
while passing every other check on this page: plugins present, md5s matching across hosts, needles
recovered, `need to load` non-zero. Tagging blindly would manufacture exactly that false confidence,
so gate the tag on a marker the patch introduces:

```bash
for H in $PREFILL $DECODE; do ssh $H '
  n=$(docker run --rm --entrypoint bash rocm-aic:latest -c \
        "grep -c _aic_kv_plane_count /usr/local/lib/python3.12/dist-packages/lmcache/integration/vllm/vllm_service_factory.py 2>/dev/null")
  if [ "${n:-0}" -gt 0 ]; then docker tag rocm-aic:latest rocm-aic:kv-planefix && echo "$(hostname): tagged (0009 present)"
  else echo "$(hostname): REFUSED — :latest does not carry patches/0009"; fi'; done
```

**Expect** `tagged (0009 present)` from both. A count of `0` means the image predates the fix — 
rebuild rather than tagging it. (Verified to discriminate: a current build reports `2`, a
three-week-old `:latest` reports `0`.)

`kv-planefix` is the name used throughout this page because that build is the first one carrying the
fused-KV-plane fix (`patches/0009`); anything older stores corrupt KV. If you built from a tree that
also has the `XNVME_KV` `queryMem` work, tag it `rocm-aic:kv-querymem` and substitute that
throughout. The name does not matter — **pinning to something that will not move does.**

### Then confirm both hosts run the same image *by content*

Moving an image with `docker save | ssh docker load` gives byte-identical content a **different
image ID**, so comparing IDs across the two hosts tells you nothing and comparing tags tells you
less — a tag is a label someone can move. Compare the plugin itself, on both hosts:

```bash
for H in $PREFILL $DECODE; do ssh $H 'docker run --rm --entrypoint bash rocm-aic:kv-planefix -c "
  md5sum /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_SPDK_NVMe_KV.so"'; done
```

**Expect:** the same md5 twice.

If you are on the `XNVME_KV` path, also check that the `queryMem` override is actually compiled in,
because its absence is silent and looks exactly like an empty cache:

```bash
docker run --rm --entrypoint bash rocm-aic:kv-querymem -c \
  'nm -D /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_XNVME_KV.so | grep queryMem'
```

**Expect** two symbols, and the `nixlXnvmeKvEngine` one must be a **defined `T`**, not a weak `W`.
`W` alone means you have the base-class stub: NIXL answers `NIXL_ERR_NOT_SUPPORTED`, LMCache
concludes the cache is empty on every request, and writes land unreachable — while every request
still returns a correct answer.

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

`SPDK_SRC` has no universally correct value — `target.sh` probes `/root/spdk-clean` then
`/root/kv_spdk` and exits with `ERR: nvmf_tgt not found` if neither is there. If your SPDK build
lives anywhere else (a user home is common on a shared cluster), **pass `SPDK_SRC` explicitly.**

### Check the qpair budget before adding initiators to a shared target

Every initiator that attaches consumes io qpairs from a **per-controller budget set once, at target
start**, by `max_io_qpairs_per_ctrlr` in `target.sh`. Exceeding it does not produce an
out-of-resources message. It produces `CQ transport error -6` and `NIXL_ERR_BACKEND` on the client
**while LMCache logs `Stored N out of N tokens` and the request returns HTTP 200** — a silent
zero-byte store. On a shared target, check before you add a role, a node, or a second stack:

```bash
python3 <spdk>/scripts/rpc.py nvmf_subsystem_get_controllers nqn.2024-01.io.nixl:kv0 |
  python3 -c "import sys,json;d=json.load(sys.stdin);t=sum(c.get('num_io_qpairs',0) for c in d);\
print('controllers=%d total_io_qpairs=%d' % (len(d), t))"
```

**The two initiator types cost wildly different amounts, and this is the part that surprises people:**

| initiator | qpairs per attachment |
|---|---|
| `SPDK_NVMe_KV` (userspace, one per vLLM/LMCache process) | **~2** |
| kernel nvme-of (`nvme connect`, the `XNVME_KV` path) | **~1 per CPU core** — 193 observed on a 192-core host |

So a dozen SPDK instances cost ~24 qpairs, and a *single* `nvme connect` can cost 193. A measured
example: 14 controllers totalling **410 of a 512 budget**, of which two kernel connections accounted
for 386. That leaves room for many more SPDK instances and **not one more kernel connection**. Cap
it with `nvme connect -i <n>` if you are adding hosts, or raise `max_io_qpairs_per_ctrlr` — but the
latter means restarting the target, which is destructive on a RAM-backed store.

## Step 5 — Deploy the prefill node

```bash
ssh $PREFILL
cd ~/rocm-aic

# $TARGET was set in your LOCAL shell — it does not exist here. Re-set it.
TARGET=10.0.0.3

HF_HOME=/var/tmp/hf HF_TOKEN=none IMAGE_REF=rocm-aic:kv-planefix \
  MODE=inprocess PD_ROLE=producer INSTANCE=pdprod PORT=8405 \
  MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 MAX_MODEL_LEN=2048 \
  TENSOR_PARALLEL_SIZE=1 GPU=0 \
  AIC_KV_POOL=0 \
  VLLM_EXTRA_ARGS="--no-enable-prefix-caching" \
  AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:$TARGET trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh
```

**Expect:** a `deploy: rocm-aic inprocess / SPDK_NVMe_KV` banner, then a health check that passes
within about two minutes. The container is named `aic-spdk-pdprod`.

Five things in that command line are load-bearing and are the ones people leave out:

- **No `sudo`.** Earlier revisions of this page had it. On a cluster with an NFS home, `root_squash`
  maps root to `nobody` and the deploy dies on its own `mkdir` — see *When it goes wrong*. The only
  thing that needs root is hugepages, done once up front. (If your account is not in the `docker`
  group on one node you may have no choice but to `sudo` there; if so, stage the repo somewhere
  host-local like `/var/tmp/rocm-aic-pd` first so the `sudo` never touches NFS.)
- **`INSTANCE=` and `PORT=` together, always.** `INSTANCE` defaults to `PD_ROLE`, and `deploy.sh`
  does an unconditional `docker rm -f` on the matching container. So the natural "same command,
  bigger model" second invocation is the one that silently destroys your first deployment. Either
  variable alone is guarded; neither is not.
- **`VLLM_EXTRA_ARGS="--no-enable-prefix-caching"`.** vLLM's own prefix cache is on by default and
  the GPU KV cache here is millions of tokens, so vLLM answers every repeat itself and LMCache is
  never consulted. Without this flag a "KV offload benchmark" measures nothing about storage, and no
  realistic amount of filler traffic will evict a cache that size.
- **`IMAGE_REF` pinned to an explicit tag.** Not `:latest`. See Step 2 above — the two hosts must
  run the same *content*, and `:latest` moves.
- **`AIC_KV_POOL=0`**, which gets its own box immediately below because it is the setting that fails
  silently and correctly. It is in this list too so that skimming the list is not how you miss it.

`deploy.sh` writes its bind-mounted LMCache config and logs to `AIC_RUNTIME_DIR`
(`/var/tmp/aic-$(id -u)`), which **must be host-local**. It used to write them under the vendored
checkout — i.e. into an NFS home shared by every node — so two hosts resolved to one inode and a
deploy on either rewrote the config mounted into the other's *running* container. `deploy.sh` now
refuses a shared filesystem outright. The symptom of the old bug, if you meet it on an older tree,
is `cat /etc/lmcache/config.yaml` inside a container returning **`Stale file handle`**.

> ### `AIC_KV_POOL=0` is mandatory for P/D, and this page used to say otherwise
>
> Verified end-to-end 2026-09-09. `AIC_KV_POOL=0` selects `NixlDynamicStorageBackend`, whose
> object names are **content-derived**, so the receiver on another host derives the *same* key for
> the same tokens and the handoff works.
>
> **`deploy.sh` now defaults it to `0` whenever `PD_ROLE` is set, and hard-refuses a non-zero value**
> with `ERR: PD_ROLE=... needs AIC_KV_POOL=0`. So you can no longer fall into this by omission — it
> is written explicitly in the commands above only because the setting is the single most important
> one on the page. To deliberately measure the no-handoff case, pass `AIC_ALLOW_STATIC_PD=1`, which
> downgrades the refusal to a warning.
>
> The non-zero value (`2000000`) selects `NixlStaticStorageBackend`, whose names carry a
> **per-process `uuid4`** (`nixl_storage_backend.py:383`). The receiver therefore cannot derive the
> producer's keys, and **no KV is transferred at all**. This was measured, not inferred: with the
> static backend the receiver reports
>
> ```
> Total tokens 1089, Inference Engine computed tokens: 0, LMCache hit tokens: 0, need to load: 0
> ```
>
> — it silently re-prefills the whole prompt. **The answer still comes back correct**, which is
> exactly what makes this dangerous: the deployment looks healthy and disaggregation is doing
> nothing. Earlier revisions of this walkthrough prescribed the static default, so a P/D pair built
> from them was never actually moving KV.

Three arguments people get wrong:

- **`MAX_MODEL_LEN=2048`** — required for TinyLlama. The default is 32768, which exceeds
  TinyLlama's `max_position_embeddings`, and vLLM refuses to start. Do **not** reach for
  `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`: it silences the check instead of fixing it, and TinyLlama uses
  RoPE, so positions past 2048 produce `nan` — a server that runs and is quietly wrong.
- **`HF_TOKEN`** — always required. `HF_TOKEN=none` is the explicit way to say "public model,
  already cached", so that fact is recorded rather than smuggled in as a fake token.
- **`AIC_SPDK_KV_SLOT_OFFSET`** — do **not** set it. It is inert on this path; see the box in the
  next step for why, and for the two stale sources that claim otherwise.

## Step 6 — Deploy the decode node

Same command, three things changed: the role, the instance name, and the host.

```bash
ssh $DECODE
cd ~/rocm-aic

TARGET=10.0.0.3      # again: the interactive shell on this host has none of your local variables

HF_HOME=/var/tmp/hf HF_TOKEN=none IMAGE_REF=rocm-aic:kv-planefix \
  MODE=inprocess PD_ROLE=receiver INSTANCE=pdrecv PORT=8405 \
  MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 MAX_MODEL_LEN=2048 \
  TENSOR_PARALLEL_SIZE=1 GPU=0 \
  AIC_KV_POOL=0 \
  VLLM_EXTRA_ARGS="--no-enable-prefix-caching" \
  AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:$TARGET trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh
```

**The two `GPU=` values need not match.** Use any free card on each host; `ROCR_VISIBLE_DEVICES`
renumbers, so the container sees `cuda:0` either way and nothing about the pair depends on the index
agreeing. It is the *sole* isolation mechanism here — `--device /dev/dri` exposes every render node,
so do not also set `HIP_VISIBLE_DEVICES`. If you intend to run the 72B example below on the same
hosts, keep this pair off GPUs 2–5, which that example claims.

> **Ignore `AIC_SPDK_KV_SLOT_OFFSET` on this path — it is inert, in either direction.** Earlier
> revisions told you the two roles must differ (producer `0` / receiver `2000000`); a later revision
> told you they must match. **Neither matters.** `make_key()` derives the key from the caller's
> `metaInfo` and ignores `devId` entirely whenever `metaInfo` is set, which LMCache always does in
> OBJ mode (`plugins/nvme-kv/spdk_nvme_kv_backend.h`, `make_key`).
>
> This is settled by observation rather than by reading: the verified pair runs with
> `kv_slot_offset: "0"` on the producer and `kv_slot_offset: "1000000"` on the receiver — they were
> deployed months apart and nobody kept them in step — and it hands off KV perfectly. Different
> offsets, same key space, 8/8 needles. So do not set it, and do not spend time on it. It still
> matters for `metaInfo`-less callers such as `kv_io.py` and `nixlbench`, which is why the knob
> exists at all.
>
> **Note two stale sources that will tell you otherwise.** `deploy.sh`'s own header still says the
> offset *"MUST differ between producer and receiver … identical offsets cause silent cross-instance
> key collision"*, and it defaults to `0` unconditionally for both roles rather than per-role. Both
> the header and the warning predate the `metaInfo` key path. The observation above is the evidence;
> the header has not been corrected yet.
>
> The things that genuinely *are* part of the key are `MODEL`, `TENSOR_PARALLEL_SIZE` and
> `AIC_CHUNK_SIZE`. Those must match.

Both roles must also use the same `MODEL`, the same `TENSOR_PARALLEL_SIZE` and the same
`AIC_CHUNK_SIZE`. All three are part of the cache key, so a mismatch is a **key miss**: the receiver
derives keys the producer never wrote, reports `need to load: 0` and silently re-prefills. That is
the same signature as the static-backend illusion above, so pin all three explicitly on both roles
rather than diagnosing it as a storage bug.

### Running a real model — the two flags it needs

Verified 2026-09-09 with `Qwen/Qwen2.5-72B-Instruct` at TP=4 on GPUs 2-5 of each node, alongside the
TinyLlama pair left running as a control:

```bash
# on BOTH nodes, changing only PD_ROLE and INSTANCE
HF_HOME=/var/tmp/hf HF_TOKEN=none IMAGE_REF=rocm-aic:kv-planefix \
  MODE=inprocess PD_ROLE=producer INSTANCE=producer72 PORT=8401 \
  MODEL=Qwen/Qwen2.5-72B-Instruct MAX_MODEL_LEN=32768 \
  TENSOR_PARALLEL_SIZE=4 GPU=2,3,4,5 \
  AIC_KV_POOL=0 AIC_CHUNK_SIZE=128 \
  VLLM_EXTRA_ARGS="--no-enable-prefix-caching --gpu-memory-utilization 0.6 --disable-custom-all-reduce" \
  AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:$TARGET trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh
```

- **`AIC_CHUNK_SIZE=128` is mandatory here.** One chunk is one stored object and the device caps a
  single value at its max transfer size — 16 MiB, logged at startup as `effective=16777216`. Per
  rank a chunk is `layers * chunk_size * (kv_heads/TP) * head_size * 2(K,V) * 2(bf16)`; for this
  model at TP=4 and `chunk_size` 256 that is `80 * 256 * 2 * 128 * 4` = **20 MiB, which does not
  fit**. The store fails with `nixlBackendError: NIXL_ERR_BACKEND` and **takes the vLLM server
  down** — both roles come up healthy first, so it only appears on the first real request. `128`
  halves it to 10 MiB. Raising TP also lowers it, so the ceiling constrains
  `(model, TP, chunk_size)` jointly.
- **`--disable-custom-all-reduce` is required for any TP>1 on this image.** Without it the server
  **hangs at init** rather than crashing: all ranks load and allocate KV, then the EngineCore
  repeats `No available shared memory broadcast block found in 60 seconds` until `wait_for_health`
  times out, which reads as a slow model. With it, READY in 460 s.

**Rehearse any TP>1 change with TinyLlama first** — `INSTANCE=tp4probe PORT=8304
TENSOR_PARALLEL_SIZE=4 GPU=2,3,4,5` on weights already on disk reproduces the all-reduce hang in
about three minutes. Hitting it first on a 145 GB model costs a 20-minute load per attempt and looks
like a model problem.

### Using the whole host — TP=8, and why it is the *better* chunk configuration

To put every GPU on the node behind one vLLM, raise TP to 8 and hand it all eight cards. The
interesting part is not the extra throughput — it is that **TP=8 makes the storage path cheaper**,
because per-rank chunk bytes fall as TP rises:

| TP | `chunk_size` | per-rank chunk | fits 16 MiB? |
|---|---|---|---|
| 4 | 128 | 10 MiB | yes — the TP=4 config above |
| 4 | 256 | 20 MiB | **no** |
| 8 | 256 | **10 MiB** | **yes** |
| 8 | 512 | 20 MiB | no |

So at TP=8 you can run `chunk_size 256` — LMCache's default, and **twice** the TP=4 config's 128.
That halves the object count for the same bytes, and objects cost ~3.89 ms each on this path
(`T = N_objects * 3.89 ms + bytes / 599 MB/s`). Chunk size is a *performance* knob, not only a
ceiling knob, so this is a real gain rather than bookkeeping.

```bash
# on BOTH nodes, changing only PD_ROLE and INSTANCE
HF_HOME=/var/tmp/hf HF_TOKEN=none IMAGE_REF=rocm-aic:kv-planefix \
  MODE=inprocess PD_ROLE=producer INSTANCE=prod72tp8 PORT=8411 \
  MODEL=Qwen/Qwen2.5-72B-Instruct MAX_MODEL_LEN=32768 \
  TENSOR_PARALLEL_SIZE=8 GPU=0,1,2,3,4,5,6,7 \
  AIC_KV_POOL=0 AIC_CHUNK_SIZE=256 \
  AIC_ENFORCE_EAGER=0 \
  VLLM_EXTRA_ARGS="--no-enable-prefix-caching --gpu-memory-utilization 0.85 --disable-custom-all-reduce" \
  AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:$TARGET trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh
```

Four things this needs that the TinyLlama path does not:

- **The node must be empty.** `GPU=0,1,2,3,4,5,6,7` claims every card, and vLLM computes
  `gpu_memory_utilization` against **total** rather than free memory — so a single leftover
  container makes it exit with `Free memory on device ... is less than desired` rather than
  starving its neighbour. Check with `rocm-smi --showmemuse` and expect `0` everywhere.
- **Hugepages at 4096**, not 512. Each rank builds its own SPDK instance. `deploy.sh` only ever
  raises to 512, so do it yourself: `sudo sysctl -w vm.nr_hugepages=4096`.
- **Weights on *both* hosts.** P/D requires byte-identical weights on each side; a 136 GB model
  staged on only one node cannot do P/D at all. Check before deploying, not after a 20-minute load:
  `du -sh $HF_HOME/hub/models--*` on both.
- **`--disable-custom-all-reduce`**, as above — and note the caveat below.

> **TP>1 has never once come up on the prefill node**, and that is an open bug rather than a config
> problem. Qwen3-8B at TP=4 there hung at init for seven minutes with
> `No available shared memory broadcast block found in 60 seconds` **with `--disable-custom-all-reduce`
> confirmed on the run line**, while the identical flag was sufficient on the decode node. Budget
> this as an investigation, not a deployment. If you only need one big instance rather than a pair,
> run it on the decode node, which is where every TP=4 result on this branch was produced.

**Data and expert parallelism are not wired.** `deploy.sh` and the vendored compose expose only
`--tensor-parallel-size`; there is no `--data-parallel-size` or expert-parallel knob in either. EP
would need an MoE model in any case — `Qwen3-235B-A22B` is the staged candidate, but it is on the
prefill node only, so it cannot form a P/D pair as staged. Add flags via `VLLM_EXTRA_ARGS` if you
want to experiment, and note that in **MP mode** one LMCache sidecar serves all ranks, so DP
replicas contend on a single storage client.

Staging the weights: download **inside the image** (`--entrypoint hf ... download <repo>`, no
`--local-dir` — vLLM needs the `hub/models--*/{blobs,snapshots}` layout), and copy node-to-node with
`rsync -aH --rsync-path="sudo rsync"`, since `/var/tmp/hf/hub` is root-owned by that download. `-H`
matters: `-L` dereferences the `snapshots/`→`blobs/` symlinks and doubles the transfer.

## Step 7 — Front the pair with the proxy

Run this anywhere that can reach both vLLM nodes:

```bash
OPENAI_API_KEY=dummy python3 proxy.py \
  --host 0.0.0.0 --port 9005 \
  --prefiller-host $PREFILL --prefiller-port 8405 \
  --decoder-host   $DECODE  --decoder-port  8405
```

**If that fails with `ModuleNotFoundError: httpx` or `fastapi`**, the host's system python is not
the place to run it — which is the normal case on these GPU nodes. Run it in the image you already
have instead, with `proxy.py` bind-mounted and host networking:

```bash
docker run -d --name aic-pd-proxy --network host \
  -v "$PWD/proxy.py:/proxy.py:ro" \
  --entrypoint python3 rocm-aic:kv-planefix \
  /proxy.py --host 0.0.0.0 --port 9005 \
    --prefiller-host 127.0.0.1 --prefiller-port 8405 \
    --decoder-host   $DECODE   --decoder-port  8405
```

Note `proxy.py` serves **only** `/v1/completions` and `/v1/chat/completions`. `GET /v1/models`
returns `404` and that is not a fault — check liveness by driving a completion, not by probing
`/v1/models`.

> **Do not kill it with `pkill -f "proxy.py --host"`.** Over SSH that pattern matches your own
> command string and kills your shell. Match `"[p]roxy"`, or kill by PID — and note that `$!` after
> a `bash -c ... &` records the *wrapper* PID, not python's.

`OPENAI_API_KEY` must be set to *something* — it is forwarded as a Bearer token to both upstreams.

**Expect:** a real answer from the pair:

```bash
curl -s http://127.0.0.1:9005/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","prompt":"The capital of France is","max_tokens":16}'
```

> ### Both of these boxes used to say "use the static backend" — they were wrong, and are gone
>
> Two long warnings lived here: *"the READ PATH is now the blocker"* (2026-09-08) and *"P/D cache
> reuse does not work with `SPDK_NVMe_KV`"* (2026-09-07). Both are **superseded**, and both told you
> to run `AIC_KV_POOL` at its static default — which is precisely the setting that moves no KV while
> returning correct answers. Following them produced the illusion this page now spends Step 8
> teaching you to detect.
>
> What actually happened. The *lookup* failure was real and was fixed by implementing `queryMem()`
> in `plugins/nvme-kv/`. The *read returns wrong data* failure was also real, but it was never a
> granularity mismatch in the dynamic backend as that box guessed — it was the fused-KV-plane bug:
> LMCache built a 2-plane split staging destination for vLLM 0.26's 1-plane fused cache, so every
> chunk written was half-empty and mis-strided. Fixed by `patches/0009`, and upstream by
> [LMCache #4467]. Anything older than `rocm-aic:kv-planefix` still stores corrupt KV.
>
> So: **`AIC_KV_POOL=0` on both roles, dynamic backend, on an image at `kv-planefix` or newer.**
> That combination is verified end-to-end and is what Steps 5 and 6 prescribe.

## Step 8 — Prove the KV cache actually moved

**Do not skip this.** An HTTP 200 proves nothing about the storage tier. This stack's signature
failure is a silent zero-byte store that reports success — you get valid-looking answers, correct
text, and no KV traffic whatsoever.

### First, send traffic that can actually be stored

**Step 7's `curl` will not do**, and running the checks below against it will make a perfectly
healthy deployment reproduce the exact failure signature this step is about to teach you. `The
capital of France is` is about six tokens; **prompts shorter than `chunk_size` (256 by default) are
never stored at all**, so no object is written, no counter moves, and no `need to load` line appears.
That curl proves the pair is *routing*. It cannot prove anything about storage.

Drive `needle_test.py` first — it builds prompts well past `chunk_size` with a distinct needle per
request, which is the smallest thing that exercises store and retrieve:

```bash
python3 needle_test.py --port 9005 --model TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
  --seed-base $(date +%s) --count 8 --repeats 34
```

**Expect:** `8/8 needles recovered`. Now the checks below have something to look at.

> **If you want the `completed_nvme_io` delta, take the baseline BEFORE the run above** — the next
> subsection reads that counter, and by the time you get there the traffic has already happened.
> Grab it first, or just re-run the needle test after reading the baseline; it is a few seconds.

### On the **target** host, before and after that run:

```bash
python3 /root/spdk-clean/scripts/rpc.py nvmf_get_stats | grep completed_nvme_io
```

**Expect:** the number is strictly larger afterwards. If it did not move, no KV was stored,
and any benchmark you run is measuring plain vLLM.

> Use `nvmf_get_stats`, **not** `bdev_get_iostat`. The latter never moves for SPDK's KV command
> set and will read as zero I/O even when everything is working correctly.

Then confirm the decode side is really *reading* rather than quietly re-prefilling:

```bash
ssh $PREFILL 'docker logs aic-spdk-pdprod 2>&1 | grep -E "Created backend:|need to load"'
ssh $DECODE  'docker logs aic-spdk-pdrecv 2>&1 | grep -E "Created backend:|need to load"'
```

**This is the check that decides whether you have disaggregation or an expensive illusion.** A
working pair looks like this — the producer stores, the receiver loads:

```
producer: Created backend: NixlStorageBackend (NixlDynamicStorageBackend)
producer: Total tokens 1419, ... computed tokens: 0, hit tokens: 0,    need to load: 0
receiver: Created backend: NixlStorageBackend (NixlDynamicStorageBackend)
receiver: Total tokens 1419, ... computed tokens: 0, hit tokens: 1280, need to load: 1280
```

**Read both lines, not just the receiver's.** They fail in different ways and each catches something
the other cannot:

| line | what a bad value means |
|---|---|
| receiver `need to load: 0` | **No KV crossed** — it re-prefilled. The answer is still correct, so the output cannot tell you. Usually `NixlStaticStorageBackend` on one side (Step 5), or a mismatched `MODEL`/`TP`/`AIC_CHUNK_SIZE`. |
| producer `need to load:` **non-zero** | **Your seeds are stale** — this prompt was already stored by an earlier run. The receiver is then reading KV that some *earlier* run wrote, so the store→retrieve round trip never happens and the producer is timed serving a cache instead of prefilling. |

That second row is the one that looks fine and is not. Both headline checks stay green through it:
the needle test still returns 8/8 and the receiver still reports `need to load: 1280`. It was hit
2026-09-11 with a round-numbered `--seed-base` that collided with a previous run — the producer
served the first four of eight requests out of the cache, with real device reads, and nothing else
in the output moved. **The producer log must be all `load: 0` before any P/D number means what you
think it means.**

Derive the seed base from the clock rather than picking a round one:

```bash
python3 needle_test.py --port 9005 --model TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
  --seed-base $(date +%s) --count 8 --repeats 34
```

If the decode side errors on a location name, set `LMCACHE_STORE_LOCATION` /
`LMCACHE_RETRIEVE_LOCATIONS` to exactly what `Created backend:` printed, rather than guessing.

### Only on the `XNVME_KV` backend — check `max_hw_sectors_kb` before blaming the plugin

**This does not apply to the SPDK path above.** `SPDK_NVMe_KV` carries its own userspace NVMe-oF/TCP
initiator inside the vLLM process and never touches the kernel `nvme` driver, so no kernel-side
transfer cap is in play and `/sys/class/nvme` describes only whatever local SSDs the host happens to
have. Skip this unless you are running the `XNVME_KV` backend, which *does* go through a kernel
nvme-of association that you established with `nvme connect`.

On that path, if the receiver finds every key and then **fails every read** — `sct=7 sc=234`, and
LMCache logging `The cache block is in the storage, but it can't be retrieved` — the cause is
almost certainly kernel-side rather than in the plugin. Resolve the KV controller by subsystem NQN
first, because it takes whatever index is free, which already differs between hosts and moves across
reboots:

```bash
for c in /sys/class/nvme/nvme*; do
  [ "$(cat "$c/subsysnqn" 2>/dev/null)" = "nqn.2024-01.io.nixl:kv0" ] && echo "${c##*/}"
done
```

Then read the cap on that controller, on **both** hosts:

```bash
cat /sys/class/nvme/nvme3/*/queue/max_hw_sectors_kb     # substitute the name you just resolved
```

**Expect 16384 on both.** An older or differently-established association can negotiate a smaller
maximum transfer (1024 was observed on one host), and **nothing about it looks wrong** — same NQN,
same MDTS, healthy controller, clean `nvme list-subsys`. It surfaces only as a vendor-specific
completion status on values above the cap. `nvme disconnect` + `nvme connect` on the low host fixes
it. This is one `cat`, and it is the difference between a config problem and a day of reading C++.

### `needle_test.py` — driving the correctness half

`needle_test.py` (repo root) sends N long needle prompts through the proxy and reports whether each
needle came back:

```bash
python3 needle_test.py --port 9005 --model TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
  --seed-base $(date +%s) --count 8 --repeats 34
```

It builds prompts past `chunk_size` with a distinct needle per request, and prints the `Total tokens`
to match against the log lines above.

- **`--seed-base` must be fresh on every run**, and `$(date +%s)` is how you guarantee it. The
  backend is persistent, so a repeat run measures retrieval in its own STORE phase. It varies the
  **beginning** of the prompt, because chunk keys are prefix-derived — varying `--repeats` alone
  only rekeys the final chunk. A round number you have used before is the easy way to get this
  wrong, and the producer log is how you find out (Step 8).
- **It deliberately does not report pass/fail on its own.** It ends by printing the receiver
  log-scrape command, because correctness cannot distinguish a working pair from the illusion —
  both answer correctly. The needle result is necessary, not sufficient.

Finally, the correctness check that gates every number: **the same prompt, twice, across a
restart, must produce identical output.**

## Step 9 — Benchmark

Only now. Point any OpenAI-compatible load generator at the proxy on port 9005 — not at either
vLLM node directly, or you bypass the disaggregation entirely.

```bash
PROFILE=throughput TRACK=rocm-aic-spdk BASE_URL=http://127.0.0.1:9005/v1 \
MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 bash bench/llama-benchy/run.sh
```

> **`bench/llama-benchy/` is not in this extraction** — it lives in the full `kv-cache` tree (see
> *Layout* below). On this branch, use `pd_bench.py` for latency/throughput and `kv_path_bench.sh`
> for the KV path, and treat the line above as the shape of the invocation rather than something
> you can paste.

### To measure the KV path itself, scrape it — do not subtract

The number most people actually want is the bandwidth of the KV transfer, and there is exactly one
trustworthy way to get it here. LMCache logs it per request, on the **receiver**:

```
size: 1.4678 gb, cost 3085.1074 ms, throughput: 0.4758 GB/s
```

For a **two-host P/D pair**, scrape it off the receiver after a `needle_test.py` run:

```bash
ssh $DECODE 'docker logs aic-spdk-pdrecv 2>&1 |
  grep -oE "size: [0-9.]+ gb, cost [0-9.]+ ms, throughput: [0-9.]+ GB/s" | tail -8'
```

`kv_path_bench.sh` automates the same scrape and additionally fails loudly with
`NO RETRIEVALS LOGGED` rather than reporting a fast path when it actually got a miss — but it is
built for a **single co-located `kv_both` instance, not a P/D pair.** It posts to
`http://127.0.0.1:$PORT` and reads `docker logs` locally, so it cannot straddle two hosts: the
producer and the container it must scrape are on different machines. Its own warmup request is the
STORE, which a `retrieve_locations`-only receiver will never perform. Use it like this, against one
instance deployed with both store and retrieve locations:

```bash
# <container> <port> <model> <label> [nreq] [prompt_tokens]
bash kv_path_bench.sh aic-spdk-obj8b 8403 Qwen/Qwen3-8B obj8b 5 10743
```

**Set the last argument.** It defaults to `8192` prompt tokens, which a TinyLlama deployment at
`MAX_MODEL_LEN=2048` rejects with an unhandled `HTTPError: 400`.

**Do not derive bandwidth by subtracting a short-prompt "decode probe" from a long-prompt request.**
That method produced this branch's since-retired 617 MB/s figure. Measured directly, the probe's own
spread was **182%** (1.42–16.29 s over five samples) — the floor being subtracted was noisier than
the quantity being measured — and it reported 140 MB/s for a path simultaneously running at 476.
Treat any figure on this branch dated before 2026-09-10 with that in mind.

Two knobs change the answer and are easy to vary by accident:

- **`AIC_CHUNK_SIZE` is a performance knob, not only a ceiling knob.** Chunk 16 runs the path at
  288 MB/s where chunk 64 runs it at 474 — each object costs ~3.89 ms. Always run the largest chunk
  that fits under 16 MiB, and never compare two runs that used different values.
- **`AIC_ENFORCE_EAGER=0` is worth 5.2x on request latency** (19.4 s → 3.72 s on the 8B rig) and
  does nothing to the KV path. Leaving it at the default `1` buries the storage tier: with it on the
  KV load is 16% of a request, with it off it is 83%. That is a large part of why the P+D and
  reuse verdicts originally read as ties. Change it per experiment, not as a default — every number
  recorded before the knob existed was taken at `1`.

`deploy.sh` writes the server half of the provenance record, so the result's `.provenance.txt`
should carry a populated `SERVER CONFIG:` line. It will read `degraded=unvalidated-first-run` until
you clear `DEPLOY_DEGRADED=` on a deploy whose walkthrough Step 8 genuinely passed. Leave it set until then.

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
| Answers are fine, receiver says `need to load: 0` | No KV crossed. `AIC_KV_POOL` not `0` on both roles, or `MODEL`/`TP`/`AIC_CHUNK_SIZE` mismatched between them |
| Answers are fine, **producer** says `need to load:` non-zero | Stale `--seed-base` — the run is not measuring a store→retrieve round trip. Step 8 |
| Receiver finds keys then fails every read, `sct=7 sc=234` | **`XNVME_KV` only** — `max_hw_sectors_kb` below 16384 on that host, a stale nvme-of association. Step 8 |
| Store dies with `NIXL_ERR_BACKEND` and takes vLLM down | One chunk exceeds the device's 16 MiB single-value ceiling — lower `AIC_CHUNK_SIZE` or raise TP |
| `CQ transport error -6` + `NIXL_ERR_BACKEND`, but LMCache logs `Stored N out of N` and returns 200 | Silent zero-byte store. Either the target's qpair budget is exhausted (walkthrough Step 4) or `max_io_size` is below one chunk — both are target-side, and only the target's own log says which |
| `docker compose: command not found` / no `docker-compose.yml` | MP mode only — needs compose v2 and `SKIP_BUILD=1 bash build.sh` to have vendored the tree |
| TP>1 server hangs at init, `No available shared memory broadcast block` | Missing `--disable-custom-all-reduce` |
| `Stale file handle` from `cat /etc/lmcache/config.yaml` in a container | `AIC_RUNTIME_DIR` landed on a shared NFS path and another node's deploy rewrote it |
| Your SSH session dies when stopping the proxy | `pkill -f "proxy.py --host"` matched your own command string — match `"[p]roxy"` |
| `ModuleNotFoundError: httpx`/`fastapi` running `proxy.py` | Host python lacks them; run the proxy containerised — Step 7 |
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

Same tag is not the same image — and **the image ID is not the test.** Compare the plugin the KV I/O
actually goes through, from inside the image, on both hosts:

```bash
docker run --rm --entrypoint md5sum rocm-aic:kv-planefix \
  /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_SPDK_NVMe_KV.so
```

If they differ, build once and copy the image rather than building on each host:

```bash
docker save rocm-aic:kv-planefix | ssh <other-node> docker load
```

**Expect the two IDs to differ after that copy, and do not treat it as a fault.** `save`/`load`
assigns a fresh ID to byte-identical content, which is exactly why the md5 above — not
`docker image inspect --format '{{.Id}}'` — is the check. An earlier revision of this section told
you to compare IDs and then prescribed the very command that makes them disagree.

Two independently-built plugins sharing one KV namespace is not a configuration you can trust a
benchmark from.

---

# Walkthrough — LMCache in MP mode (the sidecar)

The walkthrough above is **in-process** mode, because that is the only mode that can express P/D.
MP mode is the other integration, it is `deploy.sh`'s **default**, and it is a genuinely different
thing rather than a flag on the same thing.

**Use MP mode when** you want LMCache as a standalone service — its own process, own lifecycle,
own memory budget — shared by a vLLM that talks to it over `LMCacheMPConnector`. That is closer to
how LMCache is deployed in production, and it isolates LMCache crashes from the model server.

**You cannot do P/D with it.** `lmcache server --help` has no `--pd-role`, `--store-location` or
`--retrieve-locations`, so the sidecar CLI cannot express an asymmetric producer/receiver pair at
all. Only the in-process YAML can. `deploy.sh` **refuses** `PD_ROLE` with `MODE=mp` rather than
silently degrading into something that returns correct answers while moving no KV.

## What MP mode builds

Two containers, brought up by `docker compose` rather than a single `docker run`:

```
                     ┌──────────────────────────┐        ┌────────────────────────────┐
   your prompt ─────►│   aic-vllm-gpu<N>        │        │  aic-lmcache-spdk          │
                     │   vLLM  :8300            │───────►│  `lmcache server`  :6556   │
                     │   LMCacheMPConnector     │  tcp   │  NixlStorageAgent          │
                     └──────────────────────────┘        └─────────────┬──────────────┘
                                                                       │  SPDK_NVMe_KV
                                                                       ▼
                                                           SPDK NVMe-KV target :4420
```

| | value |
|---|---|
| compose project | `rocm-aic-spdk` (`rocm-aic-${BACKEND}`) |
| compose profile | `storage-spdk` (`storage-${BACKEND}`) |
| vLLM container | `aic-vllm-gpu<N>`, default port **8300** |
| LMCache container | `aic-lmcache-spdk`, port **6556** (xnvme: `aic-lmcache-xnvme`, **6557**) |
| connector | `LMCacheMPConnector`, `kv_role: kv_both` |

vLLM is started with `VLLM_IPC_MODE=service:lmcache-spdk` and `VLLM_PID_MODE=service:lmcache-spdk`,
so it **joins the LMCache container's IPC and PID namespaces** — the sidecar service is declared
`ipc: shareable` for exactly this. Two consequences: vLLM can only join *one* such service at a
time (so `storage-spdk` and `storage-xnvme` are mutually exclusive in a single stack), and the two
containers are **not independently restartable**. Bring them up and down together, through compose.

## Choosing a host

MP mode is single-node, so unlike P/D you get to pick. Check these five things — the first is
usually the only one that discriminates, and the last two are the ones people forget:

```bash
rocm-smi --showmemuse | grep "VRAM%" | awk '{printf "%s=%s ", $1, $NF}'   # need one free card
docker compose version                                                    # need v2 (the plugin)
cat /proc/sys/vm/nr_hugepages                                             # SPDK initiator wants these
ls vendor/rocm-aic/docker/docker-compose.yml                              # SKIP_BUILD=1 build.sh done?
ss -lnt | grep -E ':(8300|6556) '                                         # both must be free
```

MP mode brings up a **compose project**, not a lone container, so it needs `docker compose` v2 and
the vendored checkout's `docker-compose.yml` — neither of which the in-process path requires. A host
that happily runs in-process deployments can still fail here for exactly those two reasons.

**Prefer the host with a genuinely idle GPU**, and prefer a card that has been idle for a while over
one that just freed up — a card released minutes ago is often about to be reclaimed by whoever
released it.

> **Run MP mode on one host only** if your cluster shares a home directory. See the teardown note
> at the end of this section: the compose overrides and logs are written into the vendored tree, so
> two nodes running MP against a shared home write to the same inode.

## Deploy

Prerequisites are the same as Steps 1–4 of the walkthrough above: GPUs free, image present, the
vendored checkout staged (`SKIP_BUILD=1 bash build.sh`), and the target running. Confirm the
target's qpair budget has headroom too (P+D walkthrough Step 4) — the sidecar adds one more SPDK
initiator.

```bash
HF_HOME=/var/tmp/hf HF_TOKEN=none IMAGE_REF=rocm-aic:kv-planefix \
  MODE=mp BACKEND=spdk \
  MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 MAX_MODEL_LEN=2048 \
  TENSOR_PARALLEL_SIZE=1 GPU=0 PORT=8300 \
  LMCACHE_L1_SIZE_GB=20 \
  VLLM_EXTRA_ARGS="--no-enable-prefix-caching" \
  AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:$TARGET trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh
```

`MODE=mp` is the default and can be omitted; it is written out here because the difference between
the two modes is the entire point of this section.

**Expect:** a `deploy: rocm-aic mp / SPDK_NVMe_KV` banner, `=== docker compose up (--profile
storage-spdk) ===`, then `=== waiting for vLLM health ===` passing within about five minutes. If
health fails, `deploy.sh` dumps the **LMCache** container's last 60 log lines, not vLLM's — that is
deliberate, because in this mode the usual cause is the sidecar failing to bring up its NIXL
backend, and vLLM's own log only shows a connector that cannot reach its server.

### Knobs that exist only in this mode

| variable | default | what it does |
|---|---|---|
| `LMCACHE_L1_SIZE_GB` | `20` | The sidecar's L1 (host memory) budget. In-process mode has no equivalent — it uses `max_local_cpu_size` in the YAML instead. |
| `AIC_SPDK_PLUGIN_SO` | unset | Bind-mount a locally-built `.so` over the image's baked-in plugin. Useful for iterating on the plugin without a 60–90 min rebuild. |
| `COMPOSE_PROJECT` | `rocm-aic-${BACKEND}` | Lets you run two MP stacks side by side. |
| `LMCACHE_SPDK_PORT` / `LMCACHE_XNVME_PORT` | `6556` / `6557` | The sidecar's listen port. |

`AIC_SPDK_PLUGIN_SO` is validated as a **regular file**, not merely "exists" — because Docker turns
a bind mount of a nonexistent host path into an **empty directory**, which would silently shadow the
image's plugin and surface only as NIXL's generic "backend not found". If you pass a directory or a
typo'd path, `deploy.sh` stops rather than handing you that debugging session.

### MP mode on the whole host

MP mode takes `TENSOR_PARALLEL_SIZE` and `GPU` exactly as the in-process path does, so the TP=8
configuration from *Running a real model* applies unchanged — same `--disable-custom-all-reduce`,
same 4096 hugepages, same "node must be empty" requirement, and the same win that TP=8 admits
`AIC_CHUNK_SIZE=256` where TP=4 needs 128:

```bash
HF_HOME=/var/tmp/hf HF_TOKEN=none IMAGE_REF=rocm-aic:kv-planefix \
  MODE=mp BACKEND=spdk \
  MODEL=Qwen/Qwen2.5-72B-Instruct MAX_MODEL_LEN=32768 \
  TENSOR_PARALLEL_SIZE=8 GPU=0,1,2,3,4,5,6,7 PORT=8300 \
  LMCACHE_L1_SIZE_GB=64 \
  AIC_CHUNK_SIZE=256 \
  VLLM_EXTRA_ARGS="--no-enable-prefix-caching --gpu-memory-utilization 0.85 --disable-custom-all-reduce" \
  AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:$TARGET trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
  bash deploy.sh
```

The vLLM container is named for the **first** GPU in the list, so this is `aic-vllm-gpu0` — the name
does not enumerate the set. Raise `LMCACHE_L1_SIZE_GB` for a 72B working set; the sidecar's L1 is
host memory and these nodes have ~2.8 TB free.

**One sidecar serves all eight ranks.** That is the structural difference from in-process mode,
where every rank carries its own LMCache and its own SPDK initiator. It cuts the target-side qpair
cost from eight initiators to one, and it makes the sidecar a single point of contention — so a
TP=8 MP number and a TP=8 in-process number are not the same experiment, and should not be compared
as though they were.

## ⚠️ Pass `--no-enable-prefix-caching`, or MP mode measures vLLM instead of storage

The vendored `docker-compose.yml` **hardcodes `--enable-prefix-caching`** (line 410) and then
appends `${VLLM_EXTRA_ARGS:-}` after it (line 420), so a later `--no-enable-prefix-caching` wins —
but only if it reaches compose. **Until 2026-09-11 `deploy.sh` dropped `VLLM_EXTRA_ARGS` in MP
mode**, expanding it in the in-process branch only. That is now fixed; on an older `deploy.sh` the
variable is silently ignored here and there is no way to turn the prefix cache off.

Measured 2026-09-11 on a live MP stack, replaying an identical set of prompts:

| | first run (cold) | replay (same seeds) |
|---|---|---|
| needles | 4/4 | 4/4 |
| sidecar LMCache activity | `Stored 1280 tokens` ×4 | **none** |
| vLLM `Prefix cache hit rate` | 0.0% | **39.6%** |
| `External prefix cache hit rate` | 0.0% | **0.0%** |

So the **STORE path works** — the sidecar stores and the SPDK backend does real I/O, including
visible `-ENOMEM` backpressure — while the **RETRIEVE path is never exercised**, because vLLM
answers the repeat from its own prefix cache before LMCache is consulted. `External prefix cache hit
rate: 0.0%` is the tell: that counter is LMCache's, and it never moves.

So **always pass it explicitly** in MP mode:

```bash
VLLM_EXTRA_ARGS="--no-enable-prefix-caching" ... bash deploy.sh
```

On an older `deploy.sh` that lacks the forward, work around it at the compose layer instead:

```bash
cd vendor/rocm-aic/docker
VLLM_EXTRA_ARGS="--no-enable-prefix-caching" docker compose -p rocm-aic-spdk \
  --profile storage-spdk up -d --force-recreate vllm
```

**Treat any MP-mode retrieve or bandwidth number taken without this as measuring vLLM, not
storage.** The in-process path is unaffected — it passes `VLLM_EXTRA_ARGS` correctly.

## Verify

The vLLM health gate proves the model server is up. It does **not** prove the sidecar reached
storage. Check both containers exist and that the sidecar built its backend:

```bash
docker compose -p rocm-aic-spdk ps
docker logs aic-lmcache-spdk 2>&1 | grep -E "SPDK_NVMe_KV|Created backend|qpair"
```

**Expect** the same plugin lines the in-process mode prints — `[SPDK_NVMe_KV] probing <target>`,
`attached KV namespace nsid=1`, `N qpair(s) ready` — but **in the LMCache container's log, not
vLLM's.** That relocation is the single most common reason people think MP mode is broken: they
grep the vLLM log, find no `SPDK_NVMe_KV` lines, and conclude the plugin did not load.

Then drive real traffic and confirm KV actually moved, exactly as in Step 8 — prompts shorter than
`chunk_size` are still never stored. **Wait a few seconds before scraping**: LMCache's store is
asynchronous, so a log grepped the instant the HTTP response returns can show nothing at all and
look exactly like a dead path:

```bash
python3 needle_test.py --port 8300 --model TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
  --seed-base $(date +%s) --count 4 --repeats 34
docker logs aic-lmcache-spdk 2>&1 | grep -E "need to load|Retrieved .* out of"
```

Since this is `kv_both` on a single node, the producer/receiver asymmetry does not apply: the same
instance stores and retrieves. With `--no-enable-prefix-caching` in place, **replaying the same
prompts is enough** to force a retrieve — vLLM no longer answers them itself.

**Verified end-to-end 2026-09-11** (TinyLlama, TP=1, SPDK target). Two passes over identical seeds:

| | pass 1 (cold) | pass 2 (replay) |
|---|---|---|
| needles | 4/4 | 4/4 |
| sidecar | `Stored 1280 tokens` ×4 | **`Retrieved 1280 tokens` ×4** |
| target `completed_nvme_io` | increased across the run (59,619 → 87,780) | |

> **The sidecar's L1 masks the device on repeat reads.** Those four retrieves took 0.187 s, then
> 0.001 s, 0.001 s, 0.004 s — only the first is a device read; the rest are hits in the sidecar's
> host-memory L1 (`LMCACHE_L1_SIZE_GB`, 20 GB by default). Do not read them as device latency. To
> measure the storage path in MP mode, shrink L1 or restart the sidecar between passes. In-process
> mode has no such tier — it runs `local_cpu: False`.

## Tear down

Because it is a compose project, `docker rm -f` leaves the other half running and the next deploy
inherits a half-dead stack:

```bash
docker compose -p rocm-aic-spdk --profile storage-spdk down -t 30
```

> **Give it more than Docker's default 10 s stop timeout.** The sidecar's graceful shutdown walks a
> list of LMCache `PeriodicThread`s and does not finish in 10 s, so a plain `down` SIGKILLs it
> (`ExitCode=137`) and compose reports the confusing
> `Error while Stopping ... tried to kill container, but did not receive an exit event`. The
> container *has* exited by then — `docker inspect` shows `Status=exited` — and a second `down`
> cleans it up, but the first run looks like a hung container. Observed 2026-09-11. Use:
>
> ```bash
> docker compose -p rocm-aic-spdk --profile storage-spdk down -t 30
> ```

> **MP mode writes its logs into the vendored checkout** (`${ROCM_AIC_DIR}/logs/vllm` and
> `logs/lmcache-spdk`), *not* into `AIC_RUNTIME_DIR`. On a cluster with a shared NFS home that means
> two nodes running MP mode write to the same path. In-process mode was moved to a host-local
> `AIC_RUNTIME_DIR` precisely to fix this; the MP path predates that change and has not been
> migrated. If you run MP on more than one node against a shared home, set `ROCM_AIC_DIR` per host.

---

# Reference — the underlying commands

The two walkthroughs above are the guided paths. This section is the flat reference for the same
machinery: every stage, every knob, both backends, without the hand-holding.

**Its stages are lettered (A–E) deliberately** — the walkthroughs use numbered Steps, and when both
used numbers a cross-reference like "see Step 4" was ambiguous between two different things. A
numbered *Step* always means the walkthrough; a lettered *Stage* always means this section.

## Stage A — Build the image (~60–90 min)

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

## Stage B — Start a storage target

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

## Stage C — Deploy

Prove the stack on the loopback SPDK target before pointing anything at the real device. It is the
cheap, hardware-independent way to catch build and integration bugs, and it cannot wedge anything.

The MP-mode invocation below is the terse form; the full procedure, with what it builds, how to
verify the sidecar reached storage, and how to tear it down, is *Walkthrough — LMCache in MP mode*
above.

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
# AIC_KV_POOL=0 on BOTH roles is mandatory: it selects the dynamic backend,
# whose object names are content-derived, so the receiver derives the same key
# the producer stored under. The default static backend names carry a
# per-process uuid4, so the receiver silently re-prefills and NO KV moves —
# and the answers still come back correct, so nothing looks wrong. Verified
# end-to-end 2026-09-09. Do NOT set AIC_SPDK_KV_SLOT_OFFSET: it is INERT on the
# metaInfo key path, in either direction — the verified pair runs 0 on one role
# and 1000000 on the other and hands off fine. It does not partition the key
# space. See the slot-offset box in walkthrough Step 6.
#
# AIC_CHUNK_SIZE=128 and --disable-custom-all-reduce are BOTH required for this
# model at TP=4 — see "Running a real model" in walkthrough Step 6. INSTANCE/PORT keep the
# pair clear of any TinyLlama deployment already on the host.
MODE=inprocess PD_ROLE=producer INSTANCE=producer72 PORT=8401 AIC_KV_POOL=0 \
  AIC_CHUNK_SIZE=128 TENSOR_PARALLEL_SIZE=4 GPU=2,3,4,5 \
  VLLM_EXTRA_ARGS="--no-enable-prefix-caching --disable-custom-all-reduce" \
  MODEL=Qwen/Qwen2.5-72B-Instruct HF_TOKEN=<token> bash deploy.sh
MODE=inprocess PD_ROLE=receiver INSTANCE=receiver72 PORT=8401 AIC_KV_POOL=0 \
  AIC_CHUNK_SIZE=128 TENSOR_PARALLEL_SIZE=4 GPU=2,3,4,5 \
  VLLM_EXTRA_ARGS="--no-enable-prefix-caching --disable-custom-all-reduce" \
  MODEL=Qwen/Qwen2.5-72B-Instruct HF_TOKEN=<token> bash deploy.sh
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
  --host 0.0.0.0 --port 9001 \
  --prefiller-host <prefill-ip> --prefiller-port 8401 \
  --decoder-host   <decode-ip>  --decoder-port  8401
```

**The ports must match the pair you actually deployed.** The `--prefiller-port`/`--decoder-port`
above are `8401` because that is the `PORT=` used by the P/D example directly above; the walkthrough
earlier in this file uses `8405` and a proxy on `9005`. There is no canonical value — an earlier
revision of this block said `9000`/`8301`, which matched neither.

`OPENAI_API_KEY` must be set to *something* — it is forwarded as a Bearer token to both upstreams.
If the host's python lacks `httpx`/`fastapi`, run the proxy containerised instead — see Step 7 of
the P+D walkthrough.

## Stage D — Verify KV actually moved

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

## Stage E — Benchmark

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
leave it set until Stage D genuinely passes.

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
needle_test.py                needle prompts through the proxy; the correctness half of
                              Step 8. Prints the receiver log-scrape rather than a
                              pass/fail, because correctness alone cannot detect the
                              no-KV-moved illusion
patches/                      one flat, git am-able series; destination encoded in the name
  0001..0004-spdk-*.patch     KV-command-set diffs, staged into the build
  0005-rocm-aic-*.patch       git-apply'd to the vendored docker/Dockerfile
  0006..0009-lmcache-*.patch  copied into the vendored tree, applied inside the build
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

> **Closed bugs and session-by-session archaeology have been moved out of this file.** Five
> STORE/RETRIEVE defects were root-caused across the 2026-08-18 → 08-25 sessions — `pool_size` sized
> for chunks rather than pages, a RETRIEVE "gap" that was a test artifact, cross-instance key
> collision on a shared namespace, and `-ENOMEM` treated as fatal in the async submit path. All are
> fixed. The evidence trail, the dated status snapshots and the honest caveats on each validation
> now live in **`SESSION-HISTORY.local.md`** (untracked, local). Read it only when you need to know
> *why* something is the way it is; nothing in it is needed to run the stack.

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

[LMCache #4463]: https://github.com/LMCache/LMCache/issues/4463
[LMCache #4467]: https://github.com/LMCache/LMCache/pull/4467
