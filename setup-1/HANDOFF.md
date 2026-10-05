# Handoff — setup-1 (all-in-one vLLM + SPDK, real-DSC MI210 pair)

State of the setup-1 bring-up, for whoever picks this up next. Last updated
2026-10-05.

Read [`../docs/setups/setup-1.md`](../docs/setups/setup-1.md) for the host
inventory/topology and [`../docs/BRINGUP-setup1.md`](../docs/BRINGUP-setup1.md)
for the step-by-step procedure — this file is the "what's actually true right
now, and what to watch out for" complement to both, not a replacement.

**Not part of the P+D disaggregated stack the rest of this repo documents.**
Nothing here touches `scripts/`, `config/cluster.env`, or `creds/active.env`.

---

## 1. Current state (2026-10-05, end of session)

A container is **live right now** on `.100` (`10.30.48.100`):

| | |
|---|---|
| container | `aic-xnvme-single` |
| endpoint | `http://127.0.0.1:8301/v1` (and `http://10.30.48.100:8301/v1` externally) |
| model | `Qwen/Qwen2.5-3B-Instruct` |
| stack | vLLM 0.26.0 → `LMCacheConnectorV1` (in-process) → `NixlStorageBackend` → `XNVME_KV` → `/dev/ng1n1` |
| GPU | MI210, `GPU=0`, `TENSOR_PARALLEL_SIZE=1` |
| chunk size | `AIC_CHUNK_SIZE=16` (see §3 — **not** the default) |
| KV storage, confirmed working | yes — forced-store test shows `ok=1 sct=0 sc=0` in the container log |

`.88`'s target (`10.30.48.88`, pre-existing `nvmf_tgt`, confirmed in-session
as safe to use) has an **additive** listener on `10.30.48.88:4420` alongside
its original `1.1.0.2:4420` one. `.100` is connected via kernel `nvme_tcp`
(`nvme-subsys1`, `/dev/ng1n1`). Image `rocm-aic:latest` (43.6 GB) is built on
`.100`.

**This is a real, working deployment — not a dry run.** Treat `aic-xnvme-single`
as something to extend, not something to casually `docker rm -f` and
re-create, unless you're intentionally redeploying (which is a sanctioned,
normal operation — see `BRINGUP-setup1.md` §3).

---

## 2. How to resume

```bash
ssh root@10.30.48.100   # root/docker, see ../creds/setup-1.env
docker ps --filter name=aic-xnvme-single
curl -s http://127.0.0.1:8301/health
```

If the container is gone (host rebooted, etc.) — redo
`docs/BRINGUP-setup1.md` §1 (preconditions: `.88` listener, `.100`'s
`nvme connect`, `amdgpu` modprobe) **in order**, then §3 (deploy) with
`AIC_CHUNK_SIZE=16` included. Nothing here survives a reboot of either host —
§1 is a checklist, not a one-time setup.

---

## 3. Known-good config — don't rediscover these the hard way

This exact combination of overrides was arrived at by hitting each default's
failure mode once this session. All of them are **non-default** for
`deploy.sh`, which was written for the 8-GPU setup-3/setup-4 nodes, not a
single-MI210 box:

```bash
BACKEND=xnvme
MODE=inprocess
GPU=0                              # default: 0,1,...,7 — wrong, only 1 GPU here
TENSOR_PARALLEL_SIZE=1             # default: 8 — same reason
AIC_XNVME_DEV=/dev/ng1n1           # the .88-backed device, NOT /dev/ng0n1 (see §4.4)
AIC_CHUNK_SIZE=16                  # default: 256 (LMCache's) — overflows nvme1's
                                    # 1 MiB kernel transfer ceiling for anything
                                    # bigger than TinyLlama; see §4.3
MODEL=Qwen/Qwen2.5-3B-Instruct
HF_TOKEN=none                      # public model, explicit "no auth" spelling
IMAGE_REF=rocm-aic:latest
```

If you change the **model**, re-check `AIC_CHUNK_SIZE` — it's a function of
the model's KV shape (layers × kv_heads × head_size), not a universal
constant. §4.3 has the arithmetic.

---

## 4. Traps hit this session — don't re-discover these

### 4.1 `deploy.sh` in-process mode defaults to an 8-GPU host

`GPU=0,1,...,7` / `TENSOR_PARALLEL_SIZE=8` are the unconditional defaults in
the in-process branch, regardless of `PD_ROLE`. Omitting the overrides in §3
produces `AssertionError: DP adjusted local rank N is out of bounds for 1
devices` for ranks 1–7 — happens during GPU worker init, before NIXL/storage
is ever touched, so it's safe to just retry with the right env.

### 4.2 `build.sh`'s compose step needs `/opt/pip-cache/wheels` to exist

Even though nothing needs to be in it. Symptom: `failed to get build context
pip-wheels: stat /opt/pip-cache/wheels: no such file or directory`. Fix:
`mkdir -p /opt/pip-cache/wheels`, then re-run the `docker compose ... build`
command `build.sh` printed — **with `ROCM_ARCH` still exported**, or it fails
later and more confusingly on `ROCM_ARCH is not set` (this cost one full
extra build cycle in-session: dropped `ROCM_ARCH` copying the resumed command
by hand).

### 4.3 Silent KV-store failures: `sct=7 sc=234` / `NIXL_ERR_BACKEND`

At LMCache's default `chunk_size=256`, Qwen2.5-3B-Instruct's KV chunks are
~9 MiB. `.100`'s `nvme1` (the kernel `nvme_tcp` connection to `.88`) has a
negotiated `max_hw_sectors_kb` of **1024** (1 MiB) —
`/sys/class/nvme/nvme1/queue/max_hw_sectors_kb`. Every store past that
ceiling fails, and **fails silently as far as LMCache's own log line is
concerned** — `[XNVME_KV] op=store ... t=complete ok=0 sct=7 sc=234` and
`getXferStatus: ... NIXL_ERR_BACKEND` appear right next to a LMCache line
still claiming `Stored 2048 out of total 2048 tokens`. Generation is
unaffected (this is purely the storage side-channel), so **this does not
show up as a user-visible failure at all** — the only way to catch it is
grepping the container log for `NIXL_ERR` after deploying, which is not
something `deploy.sh`'s own health check does.

Fix: `AIC_CHUNK_SIZE=16` → 576 KiB/chunk, confirmed via the same log line
reading `ok=1 sct=0 sc=0` afterward. The general rule, from `setup-1/README.md`'s
own description of the same bug class on Qwen2.5-72B at TP=4 (different chunk
size, same root cause): chunk byte size is
`layers * chunk_size * (kv_heads/TP) * head_size * 4`, and it must stay under
whichever ceiling governs your path — the kernel's `max_hw_sectors_kb` for
`XNVME_KV` over a kernel NVMe-oF connection, or the SPDK target's own
`max_io_size`/SGL-entries product for `SPDK_NVMe_KV`. These are **different
ceilings on different paths** — don't carry a validated chunk size from one
backend to the other without re-checking.

### 4.4 `/dev/ng0n1` and `/dev/ng1n1` are not interchangeable, at all

`.100` has two `/dev/ngXnY` devices and they are architecturally unrelated:

- **`/dev/ng0n1`** — the real local Pensando DSC function, PCIe `0000:1c:00.0`.
  Plain local PCIe NVMe from the kernel's point of view (`nvme.ko`, no
  `nvme_tcp`, no network stack visible to the host at all). **This is the
  device the "never `docker kill`" hazard is about** — wedging its
  `CC.EN`/`CSTS.RDY` handshake needs a DPU-console restart to clear, nothing
  host-side works.
- **`/dev/ng1n1`** — what this deployment actually uses. No DSC anywhere in
  this path: plain kernel `nvme_tcp` software fabric, over the ordinary
  management NIC, to `.88`'s SPDK target, which is itself RAM-backed
  (`bdev_kvmalloc`, confirmed via `bdev_get_bdevs` — `"product_name": "KVMalloc
  disk"`). Killing a container using *this* device cannot wedge DSC firmware
  — there's no DSC in the data path at all. Worst case is a dropped TCP
  session.

`deploy.sh`'s own banner prints `category: 1 (real NVMe-KV device)` for
**either** device — it only pattern-matches the `/dev/ngXnY` path, it doesn't
know what's actually behind it. Don't trust that line; know which device
you're pointed at instead.

### 4.5 `.88`'s `nvmf_tgt` predates this session

A live `nvmf_tgt` (`/root/kv_spdk/build/bin/nvmf_tgt`, `kv_spdk` tree) was
already running on `.88` before this session touched anything, serving
`nqn.2016-06.io.spdk:cnode1` with a single `KVMalloc` namespace, listening
only on `1.1.0.2:4420` (a DSC-fabric address `.100` cannot reach — the two
hosts' DSC ports are not wired together, confirmed by bringing both of
`.100`'s DSC ports up and getting `Destination Host Unreachable` pinging
`.88`'s side). Its ownership was confirmed conversationally this session
before an **additive** listener on `10.30.48.88:4420` was added via RPC — the
original `1.1.0.2:4420` listener and its one namespace were never touched.
**Treat this target as shared infrastructure, not something this project
provisioned** — don't restart `nvmf_tgt` itself, don't remove the listener,
and re-verify the additive listener is still there after any reboot of `.88`
(§1.1 of `BRINGUP-setup1.md`).

---

## 5. Not done yet

- **The Qwen2.5-3B llama-benchy sweep on record predates the
  `AIC_CHUNK_SIZE` fix.** `/root/rixl-bench/results/yw-dell-gen4-1/2026-10-05-llama-benchy/llama-benchy-20261005-122401.md`
  was run against a deployment where every KV store was silently failing
  (§4.3) — its throughput/latency numbers are still valid (generation never
  depended on storage succeeding), but it says nothing about the KV-offload
  path, because that path was broken for the entire run. A sweep against the
  current, chunk-size-fixed deployment has **not** been run.
- **No RETRIEVE correctness check.** Nothing in this session proved a
  RETRIEVE actually loads from storage rather than vLLM re-prefilling from
  its own GPU prefix cache — `deploy.sh`'s own "ALSO" line (grep the log for
  `need to load: [1-9]` or `Retrieved`, with `--no-enable-prefix-caching` on
  the request path) was never followed through. Store-side correctness is
  confirmed (§4.3's fix); retrieve-side is not.
- **`/dev/ng0n1` (the real DSC) has never been deployed against in this
  session.** Everything above used `/dev/ng1n1` (`.88`-backed, RAM
  underneath). A `BACKEND=xnvme AIC_XNVME_DEV=/dev/ng0n1` deploy against the
  real local device — the actual category-(1) end-goal hardware — is
  untried, would need `AIC_CHUNK_SIZE` re-derived against that controller's
  own (unmeasured) transfer ceiling, not the 1024 KB measured for `ng1n1`,
  and **would** carry the real "never kill" hazard for real this time (§4.4).
- **The Genoa/`.59` address in the original ask was stale** — corrected to
  `.88` early in-session (see `docs/setups/setup-1.md` §2) — but the
  possibility that the *original* `.59` host exists somewhere else on the
  network, separate from `.88`, was never chased down. If that host turns up
  later, it is not the same machine as anything referenced in this handoff.

---

## 6. Repo map

| What | Where |
|---|---|
| Scripts (vendored from `rocm-aic`) | `setup-1/{build,deploy,target}.sh`, `setup-1/{patches,plugins}/` |
| Benchmark harness (vendored from `attic/kv-cache/bench`) | copied to `.100:/root/rixl-bench/` — **not** checked into this worktree under `setup-1/` (see below) |
| Topology/host facts | `docs/setups/setup-1.md` |
| Step-by-step procedure | `docs/BRINGUP-setup1.md` |
| This file | `setup-1/HANDOFF.md` |
| Credentials | `creds/setup-1.env` (gitignored — SSH creds, BMC IPs, DSC console telnet endpoints) |
| On `.100` | `/root/setup-1/` (scripts, copied from this worktree's `setup-1/`), `/root/rixl-bench/` (bench harness), `rocm-aic:latest` (docker image), `aic-xnvme-single` (running container) |
| On `.88` | nothing deployed by this project — only the additive RPC listener (§4.5) |

**`setup-1/bench/` is not in this worktree.** It was copied directly from
`attic/kv-cache/bench` to `.100:/root/rixl-bench/` for convenience during this
session and was not added to this repo's tracked tree. If you want it
versioned here too, that's a deliberate follow-up, not something this handoff
assumes already happened.
