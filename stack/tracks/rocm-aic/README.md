# rocm-aic — build and run a full LLM stack with Qwen2.5-72B

Step-by-step procedure for the `rocm-aic` track: AMD's official
[ROCm/rocm-aic](https://github.com/ROCm/rocm-aic) stack (vLLM v0.26.0 + LMCache v0.5.3 +
NIXL v1.3.2), unmodified, with two out-of-tree NIXL storage plugins compiled in so KV cache can be
offloaded to a key-addressed storage tier.

**This file is only "how do I stand it up".** The design rationale, root-cause history and full
list of known bugs are kept in a companion document that is **not published in this repository**.

---

## Read this before you start

| | |
|---|---|
| **Model** | `Qwen/Qwen2.5-72B-Instruct` — dense, bf16, ~145 GB of weights. Needs **8×MI300X** (TP=8). It will **not** fit the single-MI210 host. |
| **Bigger models** | Qwen3-235B-FP8 and Kimi-K2.5 were run on the **ATOM** track, not this one. This stack has **no `aiter`/`flash_attn`**, so **any MLA model (DeepSeek-V2/V3, Kimi) will not run here at all.** Dense models only. |
| **Storage tier** | Two variants: `SPDK_NVMe_KV` (remote NVMe-oF/TCP target) and `XNVME_KV` (local `io_uring_cmd` device). Everything below uses the SPDK variant. |
| **Honest status** | The single-node path (`deploy-spdk.sh`) has been **run and verified**. The disaggregated P/D path (`deploy-pd-spdk.sh`) is **STAGED, NEVER RUN** — a novel combination whose `store_location` value is a static-analysis guess. Expect to debug it. See Step 5's troubleshooting. |
| **Hostnames** | Placeholders throughout (`<SETUP4_PREFILL_NODE>` etc.). Real values are in `lab-inventory.local.md` at the repo root — untracked, never committed. |

Three hosts, roles per setup:

```
<SETUP4_PREFILL_NODE>  8×MI300X   vLLM producer (prefill, STORE-only)
<SETUP4_DECODE_NODE>   8×MI300X   vLLM receiver (decode,  RETRIEVE-only)
<SETUP4_TARGET_NODE>   CPU-only   SPDK NVMe-KV target, serves both over TCP:4420
```

---

## Step 1 — Build the image (both GPU hosts, ~60-90 min)

```bash
cd stack/tracks/rocm-aic
ROCM_ARCH=gfx942 bash build.sh          # gfx942 = MI300X; gfx90a = MI210
```

This vendors rocm-aic at its pinned SHA, applies our patches, stages the plugin source into the
build context, and runs `make build`. It produces **`rocm-aic:latest`**.

**Do it in the background and don't block on it** — the image builds vLLM, LMCache, NIXL, SPDK
v26.05 *and* both plugins from source.

To iterate on patches without a full rebuild:

```bash
SKIP_BUILD=1 bash build.sh              # vendor + patch + stage only
```

Verify the plugins actually landed — a missing plugin is otherwise silent until deploy time:

```bash
docker run --rm rocm-aic:latest \
  ls /opt/nixl/lib/x86_64-linux-gnu/plugins/ | grep -E 'SPDK_NVMe_KV|XNVME_KV'
# expect: libplugin_SPDK_NVMe_KV.so and libplugin_XNVME_KV.so
```

> If you add a patch under `patches/lmcache/`, the image **must** be rebuilt — those patches are
> applied to LMCache's own tree *inside* the Docker build, not to anything on disk.

---

## Step 2 — Start the storage target (on `<SETUP4_TARGET_NODE>`)

```bash
SPDK_SRC=/root/spdk-clean \
LISTEN_ADDR=<SETUP4_TARGET_NODE_IP> \
HUGE_PAGES=256 \
bash stack/foundation/spdk-kv/start-kv-target.sh
```

`LISTEN_ADDR` **must** be the routable IP, not the default `127.0.0.1`, or the GPU hosts cannot
reach it. Confirm it's listening:

```bash
ss -lntp | grep 4420
pgrep -af nvmf_tgt      # NB: `ps -C nvmf_tgt` finds nothing — the process comm is "reactor_0"
```

That last point has fooled people into declaring a healthy target dead.

This is a RAM-backed `bdev_kvmalloc` store — **no real storage hardware in the path.** Any number
measured against it characterises the software path only.

---

## Step 3 — Smoke-test single-node first (do not skip)

Prove the image, the plugin and the target all work together with a 1.1B model before committing to
a 72B load:

```bash
HF_TOKEN=<token> \
MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
TENSOR_PARALLEL_SIZE=1 \
AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:<SETUP4_TARGET_NODE_IP> trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
bash deploy-spdk.sh                      # serves :8300

curl -s localhost:8300/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","prompt":"hello","max_tokens":16}'
```

Then confirm KV genuinely reached the target (Step 6's counter). If this fails, stop here — a 72B
run will fail the same way, 40 minutes later.

---

## Step 4 — Deploy Qwen2.5-72B, disaggregated

One `docker run` per role, on separate hosts. **`AIC_SPDK_KV_SLOT_OFFSET` must differ between the
two roles** — both instances share one namespace, and identical offsets cause silent cross-instance
key collision (fixed 2026-08-24; see the companion design document).

**On `<SETUP4_PREFILL_NODE>` (producer / prefill / STORE-only):**

```bash
HF_TOKEN=<token> \
PD_ROLE=producer \
MODEL=Qwen/Qwen2.5-72B-Instruct \
TENSOR_PARALLEL_SIZE=8 \
DTYPE=bfloat16 \
MAX_MODEL_LEN=32768 \
AIC_SPDK_KV_SLOT_OFFSET=0 \
AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:<SETUP4_TARGET_NODE_IP> trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
bash deploy-pd-spdk.sh                   # serves :8301
```

**On `<SETUP4_DECODE_NODE>` (receiver / decode / RETRIEVE-only):**

```bash
HF_TOKEN=<token> \
PD_ROLE=receiver \
MODEL=Qwen/Qwen2.5-72B-Instruct \
TENSOR_PARALLEL_SIZE=8 \
DTYPE=bfloat16 \
MAX_MODEL_LEN=32768 \
AIC_SPDK_KV_SLOT_OFFSET=2000000 \
AIC_SPDK_KV_TRID="trtype:TCP adrfam:IPv4 traddr:<SETUP4_TARGET_NODE_IP> trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0" \
bash deploy-pd-spdk.sh                   # serves :8301 on its own host
```

Each script waits up to 1200 s for `/health`, then writes a deployment record. First run also pulls
~145 GB from HuggingFace — pre-warm `HF_HOME` if you can.

Roles are enforced by vLLM's own `kv_role` gating: the producer only STOREs, the receiver only
RETRIEVEs. This is **disaggregation via a shared persistent store**, not a direct RDMA handoff.

---

## Step 5 — Front both halves with the proxy

On either host (or a third):

```bash
OPENAI_API_KEY=dummy python3 disagg_proxy_server.py \
  --host 0.0.0.0 --port 9000 \
  --prefiller-host <SETUP4_PREFILL_NODE_IP> --prefiller-port 8301 \
  --decoder-host   <SETUP4_DECODE_NODE_IP>  --decoder-port  8301
```

`OPENAI_API_KEY` must be set to *something* — it's forwarded as a Bearer token to both upstreams.

```bash
curl -s localhost:9000/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-72B-Instruct","prompt":"Explain KV cache offload.","max_tokens":128}'
```

**If the receiver errors on the location name** — the single most likely failure, because
`store_location`/`retrieve_locations` = `"SPDK_NVMe_KV"` was derived by reading
`storage_manager.py`, not from a successful run:

```bash
docker logs <receiver-container> 2>&1 | grep "Created backend:"
```

and set `LMCACHE_STORE_LOCATION` / `LMCACHE_RETRIEVE_LOCATIONS` to the name it actually registered.

---

## Step 6 — Verify KV really moved (do this before trusting any output)

An HTTP 200 proves nothing about the storage tier. On `<SETUP4_TARGET_NODE>`:

```bash
python3 ${SPDK_SRC}/scripts/rpc.py nvmf_get_stats | grep completed_nvme_io
```

Take the value before and after a request; it **must** increase. Use `nvmf_get_stats`, **not**
`bdev_get_iostat` — the latter never moves for SPDK's KV command set and will look like zero I/O
even when the path is working.

Then confirm the receiver is actually reading, not just re-prefilling:

```bash
docker logs <receiver-container> 2>&1 | grep -E "need to load: [1-9]|Retrieved"
```

---

## Step 7 — Benchmark

Through the repo's harness, so the run is gated and stamped:

```bash
PROFILE=throughput TRACK=rocm-aic-spdk BASE_URL=http://127.0.0.1:9000/v1 \
MODEL=Qwen/Qwen2.5-72B-Instruct \
bash bench/llama-benchy/run.sh
```

Every result gets a `.provenance.txt` sidecar. Check its `SERVER CONFIG:` line — `NOT RECORDED`
means the verdict covers the client only. Add a row to `results/INDEX.md` afterwards.

---

## Gotchas that have actually bitten this track

- **Deployment records are not in `/run/kv-cache-bench`** when the deploy runs as non-root. They land
  in `$XDG_RUNTIME_DIR/kv-cache-bench/`. Checking only `/run` and concluding "no record" is unsound
  — that mistake has been made twice. Check all three:
  `ls /run/kv-cache-bench/ "${XDG_RUNTIME_DIR}/kv-cache-bench/" "/tmp/kv-cache-bench-$(id -u)/"`
- **`MAX_MODEL_LEN` must be passed explicitly** if the model's native context exceeds the compose
  default; `deploy-spdk.sh` lacked this passthrough until 2026-08-26.
- **A 5-chunk store submits 3,520 descriptors at once** — 110× the safe pipeline depth. The plugin
  treated SPDK's transient `-ENOMEM` as fatal and died at 770/3,520. Fixed and validated
  2026-08-25; make sure your image includes that fix or long prompts will fail with
  `NIXL_ERR_BACKEND`.
- **A slow start is not necessarily a hang** — an unexplained ~17-minute startup stall has been seen
  once and never root-caused. `docker restart` cleared it.
- **The `XNVME_KV` variant targets real hardware** and is not published here. If you build an
  equivalent, treat the device as uninterruptible — an aborted transfer can wedge the controller
  until it is reset out of band. Treat a real device as
  uninterruptible: never `kill`, `docker stop`, or `timeout`-wrap a process holding it.

## Layout

```
build.sh                      vendor + patch + stage + make build
vendor.sh                     shallow-clone rocm-aic at the pinned SHA
patches/dockerfile/           git-apply'd to the vendored docker/Dockerfile
patches/lmcache/              copied into the vendored tree; applied inside the build
deploy-spdk.sh                single-node, remote SPDK target        (verified)
deploy-pd-spdk.sh             two-role P/D via shared store          (never run)
disagg_proxy_server.py        prefill→decode router, verbatim from vLLM
docker-compose.storage.yml    backend flags + device/volume mounts
```
