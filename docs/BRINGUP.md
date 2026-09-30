# Bring-up and benchmarking runbook

How to get this cluster into a state where a benchmark number means
something, and then how to run the three benchmark harnesses that exist.

Last updated 2026-09-30.

> **Current state, 2026-09-30 — read before running anything below.**
> Two blockers stand between this cluster and a served decode request, and
> §2/§4/§4A are **not runnable today**:
>
> 1. **RDMA device names changed under us.** Both nodes rebooted
>    2026-09-29 and the RoCE devices came back as `roce_benicNp1`, not
>    `ionic_N`. `creds/setup-4.env` still pins `ionic_7:1`, so UCX matches
>    no device, falls back to shm/ROCm transports that cannot do active
>    messages, and `NixlConnector` dies at construction with
>    `NIXL_ERR_BACKEND`. **New §1.4 catches this in one command** — it is
>    the check this runbook was missing.
> 2. **`ipc_wrapper.py:85` KV-cache registration OOM** (§7 item 19,
>    TROUBLESHOOTING.md, TODO 6.47) — root cause NOT established. Blocker 1
>    currently masks it: execution dies before `REGISTER_KV_CACHE` is ever
>    reached.
>
> §3 (block-level) is unaffected by both **provided no vLLM is resident on
> the node** — see §7 item 19.

> **Scope change, 2026-09-18.** This document used to be a full
> from-source bring-up guide (build SPDK, build UCX/NIXL, install vLLM).
> That path has not completed successfully in this project and is not what
> the cluster runs — the deployment unit is the vendor container image
> (HANDOFF §6.3, TODO 6.1). Those sections are **removed, not
> superseded**: recover them from git history (`git log -- docs/BRINGUP.md`)
> if the from-source path is ever revived. What remains here is the path
> that is actually exercised: bring the containerised stack up, prove the
> environment is sane, then benchmark it.
>
> **Read [HANDOFF §3](HANDOFF.md#3-how-to-resume) first** if you are
> resuming — it carries cluster state as handed over. This document assumes
> you have done that.

---

## §0 The three harnesses, and which question each one answers

Pick the harness that matches your question. They measure different layers
and are not interchangeable; the most common way to waste a day here is to
ask a KV-block question of an engine-level harness.

| Harness | Layer | Answers | Status on this cluster |
|---|---|---|---|
| **`lmcache bench l2`** (§3) | L2 adapter → NIXL → device | KV blocks stored/requested, **hit rate**, block size, **store/load MB/s**, per-key latency | ✅ **VERIFIED 2026-09-18** — numbers in §3.7, device-cross-checked; only runnable on a node with **no vLLM resident** — a bare `torch.empty(2<<20, device='cuda:0')` in the same container fails identically while vLLM decode is resident (TROUBLESHOOTING.md) |
| **llama-benchy** (§4) | HTTP / inference engine | TTFT, tokens/s, prefix-cache benefit, concurrency behaviour | ❌ **NOT RUNNABLE TODAY** — blocked by the RDMA device-pin issue (§1.4) and, once that clears, the `ipc_wrapper.py:85` KV-cache registration OOM (§7 item 19, TODO 6.47) (historically ✅ **VERIFIED 2026-09-18** — ran end to end, before either blocker existed; even that run's prefix-cache-benefit number conflated a no-context request with a long-context one, §4.4) |
| **nixlbench** (§5) | NIXL transport | raw per-backend transfer bandwidth and latency | ❌ **NOT BUILT** — source only, blocked on a missing dependency (§5.2) |

**Decision guide.**

- "How many KV blocks were stored, how many were asked for, what fraction
  hit, how big are they, how fast do they move?" → **§3.** It never touches
  vLLM, so no engine-level cache can confound it.
- "Does the user-visible latency improve, and does the cache help
  end-to-end?" → **§4**, and read §4.4 before believing the answer.
- "How fast is the transport itself, independent of LMCache?" → **§5**, once
  it is built. Until then, do not quote a transport number.

**§3 does not require vLLM, the proxy, or even prefill.** It needs only the
device, the plugin, and the adapter. If you only need block-level numbers,
skip §2 entirely — it is the fastest path to signal, and the least likely
to be invalidated by something unrelated breaking.

---

## §1 Environment sanity — do this before every session

Each check below has cost this project at least one wasted run, and each
one presents as a failure in whatever you were actually testing rather than
as itself. Run them in order; each is cheap.

Throughout, `[SMC1]` = prefill, `[SMC2]` = decode, `[SMC3]` = KV target.
Addresses come from `creds/active.env` (§6 of HANDOFF); nothing here
hardcodes them.

### §1.1 Node uptime — are the machines even stable right now

```bash
# [SMC1] and [SMC2]
uptime
```

**Expect:** an uptime comfortably longer than the step you are about to
run.

**If it is short:** `smc2` has shown 7 boots in one day, cycling every
3–13 minutes — shorter than a model load takes (TODO 6.20). Both nodes
rebooted 3 times in a single session. If a node has been up for less time
than your step needs, you will lose the run and the failure will look like
something else entirely. Wait, or pick a shorter step.

### §1.2 GPUs — `amdgpu` does not autoload here

```bash
# [SMC1] and [SMC2]
lsmod | grep -c amdgpu      # expect a non-zero count
rocm-smi                    # expect 8 GPUs, 192 GiB VRAM each
```

**If zero:** `modprobe.blacklist=amdgpu` is on the kernel cmdline on both
nodes. It suppresses **autoload only** — an explicit `modprobe amdgpu`
restores all 8 GPUs with no reboot and no GRUB edit:

```bash
modprobe amdgpu
```

`scripts/prefill/01-host-prep.sh` and `scripts/decode/01-host-prep.sh` do
this automatically every run (opt-out `AMDGPU_AUTOLOAD=0`) — the autoload
logic itself lives in `scripts/common/lib.sh`, shared by both role
scripts; there is no `scripts/common/01-host-prep.sh`. It does not
survive a reboot. Not needed at all for §3.

### §1.3 The KV device — `/dev/ng1n1` must exist

```bash
# [SMC1] and [SMC2]
ls -l /dev/ng1n1
nvme ns-descs /dev/ng1n1     # expect csi: 0x1 and eui64 e46cfefeffcdae01
```

**Expect** a **char** device (`crw-...`), and **no** `/dev/nvme1n1` beside
it. That absence is correct: `csi 1` is the KV command set, which has no
block-device semantics.

**Never point anything at `/dev/ng0n1`.** That is the OS boot drive
(`Micron_7450`, 800 GB) on both compute nodes. The vendor's own
`deploy-xnvme.sh` defaults to it. Invariant 10.

**If `/dev/ng1n1` is missing** — this is the DSC boot-time race (TODO 6.26),
not a dead card. The kernel probes the controller ~3 s after PCIe
enumeration, before the DPU-side application is ready, gets
`Device not ready; aborting initialisation, CSTS=0x0`, detaches, and
nothing re-probes it. **Do not hardcode the PCI address — discover the
NVMe-class function, whatever address it is at** (see the
**Measured 2026-09-22** note below for why). Distinguish it from real
hardware failure:

```bash
dmesg | grep -i 'CSTS=0x0'                                # the race signature
PCI=$(lspci -nn -d 1dd8: | awk '/\[0108\]/{print $1}')    # 0108 = NVMe class
setpci -s "$PCI" 00.L                                     # expect 10051dd8 — link is fine
lspci -k -s "$PCI"                                        # pds_core / ionic bind fine
```

All three healthy alongside a missing device means the DPU side is simply
not serving yet. Recovery, validated repeatedly on both nodes, no reboot:

```bash
echo -n "0000:${PCI}" > /sys/bus/pci/drivers/nvme/bind
```

**Expect** `nvme nvme1: 63/0/0 default/read/poll queues`, then
`block device for nsid 1 not supported (csi 1)` — **the second line is
expected, not an error.** Takes ~2 minutes to resolve either way.

**It is not deterministic on the first attempt.** Measured 2026-09-18: both
nodes hit the identical signature at t=6.1 s after a fresh reboot, and the
rebind failed **twice** with the same signature before succeeding on the
third attempt, ~20 minutes after boot. Expect to retry over minutes.

Per the hardware owner this race is expected behaviour on this hardware,
not a defect — treat it as a documented procedure, not an open bug.

**Measured 2026-09-22:** the NVMe function's PCI address MOVED,
`0000:36:00.0` → `0000:37:00.0`, on **both** nodes, underneath a
driver/software update — `36:00.0` is now the DSC **Management
Controller** (`[1dd8:1004]`), reading `setpci` value `10041dd8`, not
the `10051dd8` above; that value now belongs to `37:00.0`. Anyone
checking the old hardcoded address (`36:00.0`) will be misled into
thinking the card changed identity — it did not, the NVMe function
(`[1dd8:1005]`) just moved. Rebind at the discovered address restored
`/dev/ng1n1` **instantly** (0.09 s) on both nodes with identical
identity (`mn=PDSNVME`, `csi 0x1`, `eui64 e46cfefeffcdae01`). This is
exactly why the commands above resolve `$PCI` by class instead of
assuming `36:00.0` — TODO 6.26/6.44.

### §1.4 The RDMA fabric — device names are NOT stable across reboots

**This check is new (2026-09-30) and it is the cheapest one in §1.** A
reboot renamed every RoCE device on both nodes and cost a full session; the
failure surfaced three layers away, as a vLLM engine-init crash.

```bash
# [SMC1] and [SMC2]
for d in /sys/class/infiniband/*; do
  n=$(basename "$d"); nd=$(ls "$d"/device/net 2>/dev/null | head -1)
  printf '%-16s %-10s %-14s %s\n' "$n" "$nd" \
    "$(ip -4 -br addr show "$nd" 2>/dev/null | awk '{print $3}')" \
    "$(cat "$d"/ports/1/state 2>/dev/null)"
done
```

**Expect** 8 devices, every one `4: ACTIVE`. Measured 2026-09-30:

```
roce_benic1p1  benic1p1  30.2.1.1/24   4: ACTIVE     # smc2; smc1 is 30.1.N.1
...
roce_benic8p1  benic8p1  30.2.8.1/24   4: ACTIVE
```

The current naming is **1:1 and self-describing** —
`roce_benicNp1 ↔ benicNp1 ↔ 30.<1=smc1|2=smc2>.N.1`. The older `ionic_N`
names were **not**: their index-to-netdev mapping was arbitrary and
per-boot (`ionic_4 → benic1p1`, `ionic_7 → benic2p1`), which is why
`config/cluster.env`'s mapping table had to be re-measured three times.

**Now assert that what is pinned actually exists** — this is the step that
was missing:

```bash
# [CONTROL HOST]
grep -E 'UCX_NET_DEVICES|PD_SIDE_CHANNEL_HOST' creds/active.env
```

Every pinned device name **must** appear in the per-node listing above, and
`PD_SIDE_CHANNEL_HOST_DECODE` **must** be the IP belonging to the pinned
device's netdev. If either is false, stop and fix creds before starting
anything.

**Failure signature when it is wrong** (measured 2026-09-30, smc2, decode):

```
UCX  WARN  network device 'ionic_7:1' is not available, please use one or more of:
           ... 'roce_benic1p1:1'(ib), 'roce_benic2p1:1'(ib), ...
UCX  ERROR no active messages transport: self/memory - no peer failure handler,
           rocm_copy - no am bcopy, rocm_ipc - no am bcopy, cma/memory - no am bcopy
ucx_utils.cpp:537   UCX endpoint create failed: failed to create ep
nixl_agent.cpp:359  createBackend: backend 'UCX' ... NIXL_ERR_BACKEND
EngineCore failed to start.
```

Note what this looks like from above: vLLM reports
`RuntimeError: Engine core initialization failed` from
`multi_connector.py:184`, ~95 s after launch. Nothing in that top-level
message mentions a device name. The UCX `WARN` that names the actual
problem — **and lists the correct device names** — is ~6 lines earlier in
`/var/log/kvstack/vllm-decode.log`, inside the container. Always read
upward from `EngineCore failed to start`.

Two further traps this check does not cover but §7 does: a silent TCP
fallback that passes RDMA acceptance (§7 item 21), and
`UCX_IB_ROCE_SUBNET_PREFIX_LEN` needing to be 8 rather than 16 (§7 item
22) — smc1 is `30.1.N.1/24` and smc2 is `30.2.N.1/24`, i.e. **different
/24s**, so the RoCE subnet match is not automatic.

### §1.5 The target is shared — confirm who owns it

```bash
# [SMC3]
ps -ef | grep nvmf_tgt | grep -v grep
/root/kv_spdk/scripts/rpc.py nvmf_get_subsystems 2>/dev/null | grep nqn
```

`smc3` is **shared with another party** and has been reconfigured out from
under this project more than once (TODO 6.18). **Do not restart another
party's target to reclaim it — agree ownership first.**

As of 2026-09-18 the live `nvmf_tgt` serves `nqn.2016-06.io.spdk:cnode1`,
**not** our `nqn.2024-01.io.nixl:kv0`.

**RETRACTED (TODO 6.36, 6.40): `/dev/ng1n1` does NOT re-export smc3's
namespace.** The earlier claim — that each node's own Pensando DSC is
itself an NVMe-oF initiator that re-exports smc3's namespace as a local
PCIe function — was never supported by any measurement, and is
contradicted by two independent findings: smc3's target has served
**zero I/O** for our data (`bdev_get_iostat` reads all-zero across a
1d05h uptime while we wrote 972 MiB minutes earlier), and its listener
is TCP-unreachable from either compute node. `/dev/ng1n1` is
`transport=pcie` at `0000:36:00.0`, `mn=PDSNVME` — a **local** Pensando
DSC function, with no NVMe-oF connection from the host at all. There is
no local, independent, unshareable device here, but the mechanism is not
what this document previously claimed.

What genuinely is true: the medium really is shared across `smc1` and
`smc2` — rungs 30/35 store on one node and read back byte-exact on the
other, with negative controls — by some path that is **not** smc3's
`nvmf_tgt`. What actually backs it remains open; ask the hardware owner,
and do not re-derive it from the matching `eui64` (TODO 6.36).

**Consequence for benchmarking.** The **"1 GiB" namespace figure is
RETRACTED** (TODO 6.39): it was NVM-command-set block arithmetic
(`nsze × 512`) applied to a `csi 0x1` namespace that has no LBAs and no
block semantics; ~1.16 GiB has since been written through this same
namespace with zero errors. And **"no delete primitive" was imprecise**:
`libxnvme` exports `xnvme_kvs_delete`/`xnvme_kvs_list` — **our plugin
implements neither**, and device-level support for them is unverified
(HANDOFF §3.3 item 4; commit 235e08c). Re-point any citation of the old
"1 GiB / no delete" claim from TODO 6.29 to TODO 6.39/6.40/6.41, which is
where the current understanding of capacity and volatility actually
lives. Size your runs anyway (§3.6): space is still never reclaimed and
there is still no usage telemetry.

### §1.6 The container, and the overlays that make it work

```bash
# [SMC2] (and [SMC1] if you need prefill)
cd /root/kv-cache
./scripts/common/container.sh status decode
./scripts/common/container.sh up decode        # idempotent
```

What actually runs is **the image plus four bind-mount overlays**, not the
image (HANDOFF §2.1). Two are load-bearing:

| Overlay | Why it matters |
|---|---|
| repo-built `libplugin_XNVME_KV.so` | The image's own plugin has **no `queryMem` override**. Existence probing — and therefore all L2 discovery, and therefore every hit-rate number in §3 — exists *only* because of this mount. |
| `nixl_kv_l2_adapter.py` | This repo's L2 adapter. Auto-discovered by `pkgutil`; zero vendor files edited. |
| `lmcache_mp_connector.py` (patch 0011) | Verified **absent** from the image. Guards the `MultiConnector` composition this cluster runs. |
| `nixl_utils.py` | The image ships a ROCm-patched `nixl` and no `rixl`; upstream's platform test rejects a working install without this. |

Prove the adapter overlay actually took effect — a mount that silently did
not land is indistinguishable from a cache that stores and never retrieves:

```bash
./scripts/common/container.sh adapter-check decode
```

**Expect** confirmation that `nixl_kv` is registered and resolves. If it
does not, nothing in §3 will work and §4's cache numbers will be
meaningless.

### §1.7 One-shot sanity summary

```bash
# [SMC2] — everything §1 checks, in one paste
uptime
lsmod | grep -c amdgpu
ls /dev/ng1n1 && nvme ns-descs /dev/ng1n1 | grep -E 'csi|eui64'
# §1.4 — RDMA device names; every pinned name must appear here
for d in /sys/class/infiniband/*; do
  n=$(basename "$d"); nd=$(ls "$d"/device/net 2>/dev/null | head -1)
  printf '%-16s %-10s %-14s %s\n' "$n" "$nd" \
    "$(ip -4 -br addr show "$nd" 2>/dev/null | awk '{print $3}')" \
    "$(cat "$d"/ports/1/state 2>/dev/null)"
done
cd /root/kv-cache && ./scripts/common/container.sh adapter-check decode
```

```bash
# [CONTROL HOST] — the assertion §1.4 exists to make
grep -E 'UCX_NET_DEVICES|PD_SIDE_CHANNEL_HOST|KV_TRANSPORT' creds/active.env
```

**Where the logs actually are.** Both live *inside* the role container, not
on the host — `/var/log/kvstack/` on the host holds only build/download
logs and will mislead you:

```bash
docker exec kvstack-decode tail -100 /var/log/kvstack/vllm-decode.log
docker exec kvstack-decode tail -50  /var/log/kvstack/lmcache-mp-daemon.log
```

---

## §2 Start the stack — only needed for §4 (llama-benchy)

**Skip this entire section if you only need §3.** Block-level benchmarking
does not use vLLM, the MP daemon, or the proxy.

**Check `KV_TRANSPORT` before starting anything.** `config/cluster.env`
defaults it to `tcp`; `creds/setup-4.env` overrides it to `rdma` for this
cluster, so that is the value actually in effect. In RDMA mode
`start-vllm.sh` calls `require_rdma_access`, which can die on port state,
memlock limits, or a missing `/dev/infiniband` mapping — confirm §1.4
passes clean before troubleshooting anything downstream of it.

### §2.1 The LMCache MP daemon

The backend is configured **on the daemon**, not in vLLM's connector
config. There is no YAML in this path — `gen-lmcache-config.sh` was deleted
once confirmed dead (TODO 6.23). The live surface is a repeatable
`--l2-adapter '<JSON>'` flag:

```bash
# [SMC1] and [SMC2] — idempotent; the role start scripts call it for you
cd /root/kv-cache
./scripts/common/container.sh exec decode ./scripts/common/start-lmcache-daemon.sh
```

Verify:

```bash
./scripts/common/container.sh exec decode \
  "curl -s http://127.0.0.1:8080/status | python3 -m json.tool | head -40"
```

**Expect** `is_healthy: true`, and under
`storage_manager.l2_adapters[0]`: `"type": "NixlKvL2Adapter"`,
`"backend": "XNVME_KV"`, and a `namespace` fingerprint. **Both nodes must
derive the same namespace** (e.g. `d9dbd20693b2`) — it is a geometry
fingerprint over model/TP/chunk/dtype/align/max-value. If they differ, the
two nodes cannot see each other's objects and every cross-node lookup will
correctly miss.

### §2.2 Prefill, decode, proxy

```bash
# [SMC1]
./scripts/common/container.sh exec prefill ./scripts/prefill/03-start-prefill.sh
# [SMC2]
./scripts/common/container.sh exec decode  ./scripts/decode/03-start-decode.sh
# [SMC2] (proxy defaults to the decode host)
./scripts/common/container.sh exec decode  ./scripts/proxy/start-proxy.sh
```

These take **130 s per role** at Qwen3-8B/TP=1 (Measured 2026-09-21,
repeatedly, by rung 60's own instrumented bring-up — see §2.4). `start-vllm.sh`
hard-gates on the daemon being reachable and will `die` with a pointer back
to `start-lmcache-daemon.sh` rather than silently serving from local cache.

Verify each layer independently:

```bash
curl -s http://127.0.0.1:8100/v1/models   # [SMC1] prefill
curl -s http://127.0.0.1:8200/v1/models   # [SMC2] decode
curl -s http://127.0.0.1:8000/status      # [SMC2] proxy — fleet + stats JSON
```

### §2.3 Prove disaggregation actually works before benchmarking it

Do not run individual verify scripts ad hoc — use the ladder, **§2.4**,
which fixes the order and where each rung must be invoked from.

### §2.4 The verify ladder — what each rung proves, and where to run it

The canonical ordering is HANDOFF §3.3:

| rung | script | run from | proves | expected |
|---|---|---|---|---|
| 20 | `scripts/verify/20-verify-nixl-plugin.sh` | each node, in container | the NIXL plugin loads and the device answers | 6/6 per node |
| 30 | `scripts/verify/30-verify-kv-roundtrip.sh` | each node, in container | the DEVICE and NAMESPACE carry a cross-node store+retrieve | byte-exact, both directions |
| 35 | `scripts/verify/35-verify-nixl-kv-smoke.sh` | control host | the `nixl_kv` NAMING SCHEME and commit protocol, no LMCache in path | 8/8 |
| 40 | `scripts/verify/40-verify-disagg.sh` | decode node, in container | end-to-end disaggregation through the proxy | 9/9 |
| 50 | `scripts/verify/50-verify-pd-direct.sh` | **decode node, in container** | the P->D direct NIXL leg — decode does zero prefill work | 9/9 |
| 60 | `scripts/verify/60-verify-l2-crossnode.sh --no-drain` | **control host** (drives both nodes over ssh) | a COLD reader serves chunks only the writer computed | 9/11 (see below) |

Rung 60 is the **only** rung that runs from the control host and drives
both nodes over ssh; it **STOPS, RECREATES and RESTARTS** the containers on
both nodes, which destroys anything pip-installed inside them (see the
llama-benchy note in §4.1).

Rung 60's expected result is **9 of 11**, not 11/11: the 2 failures are
step 7's negative control, which is **VOID BY CONSTRUCTION** whenever
`--no-drain` is used. Measured 2026-09-21: identical 9/11 to the
2026-09-18 run (TODO 6.34). Treat 9/11 as **GREEN**; investigate only if
step 5 fails.

**Why `--no-drain` at all — the reason has changed, the flag has not.**
It used to be "we dare not drain a medium shared with another party." That
premise is gone: TODO 6.41c found steps 0/7's drain targets `smc3`'s
`nvmf_tgt`, which §1.5 already established our data never reaches, and
separately the DSC/DPU store that actually holds our data is volatile and
already empty on this uptime window (§1.5, TODO 6.41). The open work is
re-targeting the drain step — or better, asserting emptiness by probing
rather than by restarting anything — not deciding whether it is safe to
touch smc3.

Rung 50 **must be run ON the decode node**. Measured 2026-09-21 from the
control host it reports `1 of 8 checks failed — decode side channel
reachable (30.2.1.1:5601)` and refuses the authoritative verdict, because
decode's NIXL side channel is bound to a **FABRIC** address
(`PD_SIDE_CHANNEL_HOST_DECODE=30.2.1.1`) that the control host has no route
to, and because the log-based verdict needs
`/var/log/kvstack/vllm-decode.log`, which is not bind-mounted. That is a
**FALSE FAIL** on a completely healthy stack (the asymmetry TODO 1.9
flagged as "harmless today").

---

## §3 Benchmark A — LMCache L2 storage bench (KV-block level) ✅

**This is the harness for KV-block questions.** It drives the L2 adapter
through its real `submit_store_task` / `submit_lookup_and_lock_task` /
`submit_load_task` interface, using the same `--l2-adapter` JSON spec the
daemon uses — no vLLM, no proxy, no TTFT in any number it produces.

It ships with LMCache 0.5.3 as `lmcache bench l2`
(`lmcache/cli/commands/bench/l2_adapter_bench/`).

### §3.0 Why you must invoke it through a wrapper

`lmcache bench l2` **cannot drive any NIXL-backed L2 adapter as shipped**:

```
makeXferReq: local index out of range at index 0 with value 340075
nixl_rocm._bindings.nixlInvalidParamError: NIXL_ERR_INVALID_PARAM
```

`NixlStorageAgent.init_mem_handlers()` builds the L1 transfer dlist
**base-relative** (entry `i` is `buffer_ptr + i*page_size`) while
`get_memory_indices()` returns an **absolute** page number
(`raw_addr // l1_align_bytes`). They agree only when `buffer_ptr == 0`.

This is **upstream, not ours** — the untouched vendor `nixl_store` fails on
the identical line with the identical error. `scripts/bench/l2-block-bench.py`
corrects it **in the benchmark process only**, and range-checks the result
so an out-of-bounds index raises instead of silently landing on the wrong
page. The adapter file and the running daemon are untouched. Full reasoning,
including why this is deliberately *not* fixed in the adapter, is in
TODO 6.35.

### §3.1 Sanity: is the adapter reachable from a fresh process

```bash
# [SMC2]
cd /root/kv-cache
./scripts/common/container.sh exec decode \
  "python3 -c 'from lmcache.v1.distributed.l2_adapters.config import get_registered_l2_adapter_types as g; print(sorted(g()))'"
```

**Expect** `nixl_kv` (and `nixl_store`, `nixl_store_dynamic`) in the list.

**If they are missing**, the three NIXL adapters failed to import and were
silently skipped by the lazy loader. The usual cause is a **clobbered
environment** — see §7 item 4. Do **not** export `LD_LIBRARY_PATH` or
`NIXL_PLUGIN_DIR` yourself; the container already sets them correctly.

### §3.2 Smoke test — 4 keys, with round-trip verification

Always run this before a sweep. It is ~10 seconds and it catches every
setup problem that would otherwise produce a confidently wrong table.

```bash
./scripts/common/container.sh exec decode "
cd /root/kv-cache && LMCACHE_DISABLE_BANNER=1 \
python3 scripts/bench/l2-block-bench.py bench l2 \
  --l2-adapter '{\"type\":\"nixl_kv\",\"backend\":\"XNVME_KV\",\"backend_params\":{\"dev_uri\":\"/dev/ng1n1\"},\"namespace\":\"smoke\$(date +%s)\"}' \
  --l1-align-bytes 4096 --data-size-kb 16 --num-keys 4 --in-flight 1 \
  --rounds 1 --warmup-rounds 1 --lookup-max-hit-rate 1.0 --no-skip-verify"
```

**Expect all four of these:**

```
[l2-block-bench] base-relative L1 index patch INSTALLED
  [Store]  Round 1: ~41 ms, success_keys=4/4
  [Lookup] Round 1: ~0.1 ms, found=4/4
  [Load]   Round 1: ~41 ms, loaded=4/4
  [Verify] All 4 keys data verified OK.
```

**Read the timings, not just the success count.** A store of 16 pages that
completes in **0.47 ms is a failure**, not a fast device — it means every
transfer raised and was swallowed. A real store of that size is ~41 ms.
`success_keys=0/4` with a sub-millisecond duration is the signature of
§3.0's indexing bug (i.e. the wrapper did not take effect).

`--no-skip-verify` is the single most valuable flag here: it compares the
loaded bytes against the stored bytes and is the only check that a
"successful" round trip actually moved the right data.

### §3.3 Block-size sweep — bandwidth and block accounting

One namespace per sweep point, so hit/miss semantics stay clean:

```bash
./scripts/common/container.sh exec decode bash -c '
cd /root/kv-cache; export LMCACHE_DISABLE_BANNER=1
OUT=/opt/kvstack/bench/kvblock; mkdir -p $OUT
for KB in 16 64 256; do
  export NIXL_KV_METRICS_PATH=$OUT/plugin-$KB.json NIXL_KV_METRICS_INTERVAL_SEC=1
  python3 scripts/bench/l2-block-bench.py bench l2 \
    --l2-adapter "{\"type\":\"nixl_kv\",\"backend\":\"XNVME_KV\",\"backend_params\":{\"dev_uri\":\"/dev/ng1n1\"},\"namespace\":\"sweep$KB\"}" \
    --l1-align-bytes 4096 --data-size-kb $KB --num-keys 32 --in-flight 1 \
    --rounds 3 --warmup-rounds 1 --lookup-max-hit-rate 1.0 --no-skip-verify \
    --format json --output $OUT/full-$KB.json
done'
```

`--l1-align-bytes 4096` is **mandatory** and must match production. It is
the page size the adapter tiles objects into, so it sets how many device KV
operations one key becomes: `pages = data_size / 4096`, plus **one commit
object per key**.

### §3.4 Hit rate — you must use a cold reader

A lookup in the **same process** that stored the keys is served from the
adapter's in-process index and never reaches the device (~3 µs/key). That
number is real, but it is an *index* hit rate, not a *device* hit rate.

For a true device hit rate, run lookup in a **fresh process** against a
namespace a previous run populated, with both controls:

```bash
./scripts/common/container.sh exec decode bash -c '
cd /root/kv-cache; export LMCACHE_DISABLE_BANNER=1
for RATE in 1.0 0.0; do
  echo "### requested hit rate $RATE ###"
  python3 scripts/bench/l2-block-bench.py bench l2 \
    --l2-adapter "{\"type\":\"nixl_kv\",\"backend\":\"XNVME_KV\",\"backend_params\":{\"dev_uri\":\"/dev/ng1n1\"},\"namespace\":\"sweep256\"}" \
    --l1-align-bytes 4096 --data-size-kb 256 --num-keys 32 --in-flight 1 \
    --rounds 3 --warmup-rounds 1 --only lookup --lookup-max-hit-rate $RATE
done'
```

**Expect** `found=32/32` at rate 1.0 and `found=0/32` at rate 0.0. The
second is a genuine negative control: `--lookup-max-hit-rate 0.0` draws
keys from an index range guaranteed never to have been stored. **A run
without the 0.0 control is not evidence** — a lookup that returns "hit" for
everything, including things that were never written, is a bug that looks
like success.

### §3.5 Concurrency — where the bandwidth actually is

```bash
# same as §3.3 but vary these two, on a fresh namespace each time:
#   NIXL_XNVME_NUM_QUEUES=8      (device queues)
#   --in-flight 4                (concurrent submits per round)
```

### §3.6 Capacity — size runs before you launch them

The **"1 GiB" figure is RETRACTED** (TODO 6.39): it came from reading
`nsze × 512` on a `csi 0x1` namespace that has no LBAs and no block
semantics, not from any real byte budget — ~1.16 GiB has since been
written through this same namespace with zero errors. What genuinely
constrains you: there is still no usage telemetry (`NUSE` reads 0 and
does not track KV writes) and **no delete primitive in this plugin** —
`libxnvme` exports `xnvme_kvs_delete`/`xnvme_kvs_list`, but the plugin
implements neither, and device-level support for them is unverified
(HANDOFF §3.3 item 4; commit 235e08c). Re-point any old citation of this
claim from TODO 6.29 to 6.39/6.40/6.41. Space is never reclaimed within a
given uptime window, so budget before running:

```
device ops per run = (data_size_kb/4 + 1) * num_keys * (rounds + warmup_rounds)
bytes on device    = device ops * 4096
```

The §3.3 sweep costs ~11,136 pages ≈ **43.5 MiB**. A 1024 KB block size at
the same shape would cost ~32,896 pages ≈ 128 MiB.

**Pre-fix corrupt objects from earlier sessions are gone, not "still
resident."** The Pensando DSC/DPU KV store is **VOLATILE** (TODO 6.41):
every historical object re-probed after the 2026-09-21 recovery — from
both the pre-fix and post-fix generations — came back a MISS, on both
nodes. Consequence: this tier is a reuse cache **within an uptime
window**, not persistent storage. Any cold-reader or reuse-rate
measurement must record node uptime (§1.1) alongside its numbers, or the
result cannot be compared against a future run.

**Draining is no longer blocked for the reason previously stated here —
that blocker DISSOLVED (TODO 6.41c), it was not fixed.**
`50-reset-namespace.sh` still refuses to run when the live `nvmf_tgt` was
not started by this repo's scripts, but that no longer matters for
draining *our* data: §1.5 established our writes never reach smc3's
`nvmf_tgt` at all, so restarting it would not have drained anything of
ours even before this was understood. Draining our own medium means
cycling the DSC/DPU (not implemented here), or simply confirming
emptiness by probing (TODO 6.41's method) rather than restarting
anything. For the separate, legitimate case of resetting a genuinely
**foreign** target, `50-reset-namespace.sh` still cannot handle that —
`scripts/target/51-reset-smc3-storage.sh` is the tool written for it, and
it refuses to run anywhere but smc3.

### §3.7 Cross-check against the device — do not skip this

The adapter's numbers and the plugin's own device counters must reconcile,
or the table is fiction. The plugin writes counters to
`$NIXL_KV_METRICS_PATH` (schema 2, rewritten every
`NIXL_KV_METRICS_INTERVAL_SEC`):

```bash
./scripts/common/container.sh exec decode \
  "python3 -c \"
import json; d=json.load(open('/opt/kvstack/bench/kvblock/plugin-256.json'))
t=d['completions_ok']+d['completions_err']
print('store_ops=%d retrieve_ops=%d store_bytes=%d'%(d['store_ops'],d['retrieve_ops'],d['store_bytes']))
print('err=%d submit_fail=%d stalls=%d peak_in_flight=%d'%(d['completions_err'],d['submit_fail'],d['stalls'],d['peak_in_flight']))
print('mean device latency %.0f us/op'%(d['lat_us_sum']/max(1,t)))\""
```

**The identity that must hold:**

```
store_ops == (pages_per_key + 1) * num_keys * (rounds + warmup)
store_bytes == store_ops * 4096
retrieve_ops == store_ops          # load reads every page plus the commit object
completions_err == 0 and submit_fail == 0 and stalls == 0
```

**Results measured 2026-09-18** (32 keys/round, 3 rounds + 1 warmup,
align 4096, all ops 96/96, round-trip verified, all identities held):

| block | pages/key | device ops | store MB/s | load MB/s | store ms | load ms |
|---|---|---|---|---|---|---|
| 16 KB | 4 | 640 | 12.2 | 10.0 | 41.1 | 53.4 |
| 64 KB | 16 | 2176 | 40.0 | 36.5 | 55.3 | 57.9 |
| 256 KB | 64 | 8320 | 119.5 | 136.1 | 67.3 | 59.0 |

Per-key latency barely moves (1.29 → 2.10 ms) while bandwidth scales ~10x:
this regime is dominated by **per-key fixed overhead, not device
bandwidth**.

Concurrency, at 256 KB/key:

| queues | in-flight | store MB/s | load MB/s | peak_in_flight | submit_retry |
|---|---|---|---|---|---|
| 1 | 1 | 119.5 | 136.1 | 64 | 2.16 M |
| 8 | 1 | 115.4 | 109.8 | 512 | 7.15 M |
| 8 | 4 | **279.0** | **340.5** | 512 | 37.8 M |

Raising `NIXL_XNVME_NUM_QUEUES` alone buys **nothing** — the producer is
serialized. In-flight submits buy 2.3–2.5x. Note `submit_retry` is ~568
retries per completed op: the reactor busy-spins on `-EBUSY` backpressure,
and that, not the device, is where the time goes.

Cold-reader hit rate:

| requested | keys | hits | hit rate | µs/key |
|---|---|---|---|---|
| 1.0 | 96 | 96 | **1.00** | 69–90 |
| 0.0 | 96 | 0 | **0.00** | 70–88 |

Device probe (KV Exist) costs ~70–90 µs/key and **hit and miss cost the
same**. The warm in-process index serves the same lookup at ~3 µs/key, so
the commit-key index is worth ~25x on a repeat.

---

## §4 Benchmark B — llama-benchy (engine level) ❌ BLOCKED TODAY

**Not runnable today** — the full stack §4 requires (§2) does not come up:
the RDMA device-pin issue (§1.4) and the `ipc_wrapper.py:85` OOM (§7 item
19) block it before a single request lands. The 2026-09-21 numbers below
stand as history — they were measured while the stack last ran — but are
not currently reproducible.

Measures what a client sees: TTFT, tokens/s, and prefix-cache benefit, over
HTTP. **Requires the full stack from §2.**

### §4.1 Install

```bash
# [SMC2], inside the container
./scripts/common/container.sh exec decode ./scripts/bench/01-install-benchy.sh
```

Verify:

```bash
./scripts/common/container.sh exec decode "/opt/kvstack/venv/bin/llama-benchy --version"
# expect: llama-benchy 0.4.0
```

Two traps this script now handles, both verified 2026-09-18 — see §7 items
2 and 3 for the detail. If you are installing by hand instead, you must
bridge the console script yourself:

```bash
ln -sfn "$(command -v llama-benchy)" /opt/kvstack/venv/bin/llama-benchy
```

### §4.2 Sanity: the preflight is the check

`benchy_preflight` runs two independent checks and both matter. It waits
for `/v1/models`, **then sends a real 1-token POST to
`/v1/chat/completions`** — because llama-benchy drives chat completions
*exclusively*. A deployment serving only `/v1/completions` passes the first
check, passes llama-benchy's own model auto-detection, and then fails every
single shape in a long sweep with the same opaque 404, burning the whole
sweep's wall clock first.

### §4.3 Baseline — cold, no cache

```bash
./scripts/common/container.sh exec decode bash -c '
cd /root/kv-cache
export BENCHY_PP=512 BENCHY_TG=32 BENCHY_DEPTH=0 BENCHY_CONCURRENCY=1 BENCHY_RUNS=2
./scripts/bench/10-bench-baseline.sh --target=decode'
```

`10-bench-baseline.sh` accepts **both** `--target=decode` and
`--target decode`. It is only `30-bench-concurrency.sh` (§4.5) that is
`=`-only, for `--pp/--tg/--depth` — see §7 item 7.

**Expect** a run directory under `/opt/kvstack/bench/` containing
`result.json`, `result.md`, `run.env`, `progress.jsonl`, and pre/post
`/metrics` snapshots. A verified example (Qwen3-8B, TP=1, pp=512, tg=32,
depth 0, 2 runs):

```
e2e_ttft       mean=33.126 ms   std=0.350
est_ppt        mean=15.915 ms   std=0.350
tg_throughput  mean=197.513 tok/s
pp_throughput  mean=32186.266 tok/s
```

`--no-cache` is passed deliberately: `--depth 0` only means "no cached
prefix was staged", it does **not** disable vLLM's own automatic prefix
caching. `--no-cache` does.

**Measured 2026-09-21** (Qwen3-8B, TP=1, `--target=proxy`, `--no-cache`,
pp=512, tg=128, depth=0, concurrency=1, 3 runs). Configuration differs from
the 2026-09-18 numbers above: this run had **L1 forced to 1 GiB** (§4A.2),
so every chunk is being written through to the KV device during the
measurement, which the 2026-09-18 numbers were not:

| metric | mean | std |
|---|---|---|
| `e2e_ttft` | 698.812 ms | 0.586 |
| `est_ppt` | 581.512 ms | 0.586 |
| `pp_throughput` | 880.5 tok/s | 0.887 |
| `tg_throughput` | 201.5 tok/s | 0.036 |

(generation-latency probe: 117.30 ms)

### §4.4 Prefix-cache benefit — and why the number is not what it looks like

```bash
./scripts/common/container.sh exec decode \
  "cd /root/kv-cache && ./scripts/bench/20-bench-prefix-cache.sh --confirm-connector-hit"
```

> **Read this before quoting any speedup from this script.** vLLM's own
> prefix cache sits **upstream of every connector**. If it hits, no
> connector — LMCache included — is consulted at all. This script's
> depth>0 step re-sends the *same* context to the *same* decode process a
> second time, which is exactly the shape vLLM's own cache serves. A
> speedup here is therefore **not**, on its own, evidence that the KV tier
> did anything.

An honest engine-level reuse number must be **cross-instance** (decode
loading what prefill stored, never having computed that context itself) or
measured only **after genuine eviction**. This restructure is TODO 1.13 and
is **not done**. Until it is, treat this script's output as a smoke test.

`--confirm-connector-hit` must run **on the decode node, inside the
container** — it greps `${LOG_DIR}/vllm-decode.log`, and `LOG_DIR` is *not*
bind-mounted, so that file exists only inside the container (§7 item 6).

For a trustworthy corroboration, snapshot the adapter's counters around the
sweep instead of trusting the log grep:

```bash
./scripts/common/container.sh exec decode \
  "curl -s http://127.0.0.1:8080/status | python3 -c \"
import json,sys; print(json.load(sys.stdin)['storage_manager']['l2_adapters'][0])\""
```

The number is only meaningful if `l2_device_hits` **rose** while
`l2_index_hits` stayed at 0.

**Measured 2026-09-21** — sweep `BENCHY_DEPTH="0 4096"`, pp=512, tg=128,
concurrency=1, 3 runs, `--confirm-connector-hit` **PASSED**, same
L1-forced configuration as §4.3's 2026-09-21 row:

| phase | depth | est_ppt | e2e_ttft | tg tok/s |
|---|---|---|---|---|
| inference | 0 | 581.36 +/- 0.36 ms | 698.67 +/- 0.36 ms | 201.3 |
| **context load** | 4096 | **5,313.85 +/- 37.33 ms** | 5,431.17 +/- 37.33 ms | 182.2 |
| inference | 4096 | 706.15 +/- 0.17 ms | 823.47 +/- 0.17 ms | 179.6 |

> **`compare_runs.py --prefix-benefit` reports 0.823x for this run** —
> which reads as "the cache made it SLOWER". That number is an
> **ARTIFACT** of how the metric is paired: it compares inference@depth=0
> against inference@depth=4096, i.e. a request with **no context** against
> a request carrying **4,096 tokens of context**. Those are different
> workloads, so the ratio cannot express cache benefit, and a healthy tier
> will score below 1.0. The honest comparison is the context-load row
> against the inference row at the **same depth** —
> **5,313.85 / 706.15 = 7.53x**. This is a concrete, measured instance of
> exactly the defect TODO 1.13 exists to fix; do not quote the 0.823x as a
> result, and do not read it as the tier hurting.

### §4.5 Concurrency

```bash
./scripts/common/container.sh exec decode \
  "cd /root/kv-cache && ./scripts/bench/30-bench-concurrency.sh --pp=2048 --tg=128 --depth=4096"
```

Again `=`-form arguments only. Watch for backpressure in the engine logs:

```bash
grep -E 'ENOMEM|backpressure|drain_retry_queue|no forward progress' \
  /var/log/kvstack/vllm-*.log
```

### §4.6 How to read a NEGATIVE result

If warm rows come back roughly equal to or slower than cold, **do not
conclude "the remote KV cache doesn't help."** Conclude "something is
broken" and find out which:

1. `scripts/verify/40-verify-disagg.sh` — independent hit-token counter delta.
2. `scripts/verify/50-verify-pd-direct.sh` — distinguishes a NixlConnector
   direct hit from an LMCache L2 hit from vLLM's own upstream prefix cache.
3. §3 — if the block layer is healthy there but the engine shows no
   benefit, the fault is above the adapter, not in the storage tier.

### §4.7 Sizing warning

The tracked defaults (`BENCHY_PP="512 1024 2048"`, `BENCHY_TG="128 256"`,
`BENCHY_DEPTH="0 4096 8192 16384"`, `BENCHY_CONCURRENCY="1 2 4 8"`) are
**96 shapes** × 6 iterations × 2 phases — many hours. Shrink them via the
environment for anything exploratory, and note that `run-all.sh --quick`
results are explicitly **not reportable**.

---

## §4A The three KV data paths, proven end to end ❌ BLOCKED TODAY

**Not runnable today**, same reason as §4: the RDMA device-pin issue
(§1.4) and the `ipc_wrapper.py:85` OOM (§7 item 19) stop the stack before
any of these three paths can be exercised. The 2026-09-21 numbers below
stand as history but are not currently reproducible. Path 2 and Path 3
additionally depended on a namespace that has since been wiped — the
Pensando DSC/DPU KV store is volatile (TODO 6.41) — so even with the
stack up, a fresh run starts from empty, not from what is recorded here.

There are **three** distinct KV paths in this stack, and each needs its own
proof — a correct completion proves **nothing** about which of them, if
any, actually moved KV (HANDOFF §5). This section reproduces all three,
measured together on 2026-09-21.

### §4A.1 Path 1 — KV computed on prefill, moved directly to decode (P->D)

```bash
# [SMC2] — must run ON decode, see §2.4
cd /root/kv-cache
./scripts/common/container.sh exec decode ./scripts/verify/50-verify-pd-direct.sh
```

**Expect 9/9.** Measured 2026-09-21, literal output worth quoting:

```
external prefix cache hit rate: 98.1% -> 99.0% (baseline -> polled)
corroborating: decode 'Avg prompt throughput' = 0.0 tokens/s
VERDICT (request 3): served by NixlConnector DIRECT transfer
all 9 checks passed
```

The acceptance signal is a **PAIR**, and quoting only the first half of it
invites a reasonable reader to conclude the stack is dead:

| gauge | on decode | means |
|---|---|---|
| `Avg prompt throughput` | **0.0 tokens/s** | decode computed **no prefill** — the KV arrived over the P->D leg instead |
| `Avg generation throughput` | **non-zero** | decode is **emitting tokens** normally |

`Avg prompt throughput` and `Avg generation throughput` are two different
vLLM gauges. A 0.0 on the **prompt** gauge is the thing being proven; it is
**not** "no tokens were produced" — that would be a 0.0 on the
**generation** gauge, which is a failure, not a pass.

Confirm generation independently rather than trusting the gauge, because a
metric whose success value is zero cannot distinguish "working" from
"dead" on its own — HANDOFF §7.6's lesson, from the RoCE netdev counters
that read near-zero for real traffic: an instrument reading zero is not
evidence of absence until you have shown it can read non-zero:

```bash
# [SMC2] — generation counters must RISE across a run
curl -s http://127.0.0.1:8200/metrics | grep -E '^vllm:(prompt|generation)_tokens_total'
```

**Measured 2026-09-21** across the two §4 benchmark runs, from the
`metrics-decode-{pre,post}.txt` captured in each run directory: decode's
`vllm:generation_tokens_total` rose by **+617** and **+1,641** — tokens
were unambiguously generated while the prompt gauge read 0.0. Rung 60's
TOKEN IDENTITY check additionally confirms they are the **same** tokens a
recompute produces, not merely some tokens.

> **The zero is a real zero, not a dead gauge** — rung 50's own negative
> control withholds the handoff and decode's `Avg prompt throughput` jumps
> to **124.7 tokens/s** (HANDOFF §2). That is the positive control which
> makes the 0.0 admissible as evidence.
>
> **Do not** try to make this argument from `vllm:prompt_tokens_total`.
> Measured 2026-09-21, it rises by an **identical** amount on *both* nodes
> (+2,160 and +36,978) — it counts a request's prompt at both ends and
> cannot distinguish KV that was **computed** from KV that was
> **transferred**. Only the throughput gauge separates them.

### §4A.2 Path 2 — KV written down through L1 and L2 onto the KV device

**Precondition, and it comes first on purpose:** the tracked L1 default
(**4 GiB**, from `LMCACHE_MAX_LOCAL_CPU_SIZE=4` in creds) **NEVER EVICTS**
under any load this cluster can generate, so L2 is never written and this
path is never exercised. You must force it with `LMCACHE_MP_L1_SIZE_GB=1`.
And the daemon is **idempotent** — `start-lmcache-daemon.sh` silently
no-ops (exit 0) if a daemon is already up, so a changed L1 size is silently
ignored unless you stop it first.

Also: `NIXL_KV_METRICS_PATH` is **not exported by any script**. Without it
there are **no** plugin/device-level counters at all — only the L2 adapter
counters at `:8080/status`. Set it on the daemon's environment before
starting.

```bash
# [SMC1] and [SMC2] — L1 forced small so L2 is actually exercised
cd /root/kv-cache
./scripts/common/container.sh exec prefill \
  "LMCACHE_MP_L1_SIZE_GB=1 \
   NIXL_KV_METRICS_PATH=/tmp/kvmetrics-prefill.json \
   NIXL_KV_METRICS_INTERVAL_SEC=5 \
   ./scripts/common/start-lmcache-daemon.sh"
```

**Expect** `L1 size: 1 GiB  eviction policy: LRU  chunk size: 256` and a
namespace line `nixl_kv namespace='d9dbd20693b2' (ok)` — **the namespace
must be identical on both nodes** or no cross-node hit is possible.

Then drive real load through the proxy with a unique prompt per request (a
per-run nonce, so no request can reuse another's prefix), and read every
level. Measured 2026-09-21 with 14 requests of ~8,849 prompt tokens each
(14/14 OK in 166.4 s):

| Level | Surface | Reading |
|---|---|---|
| vLLM prefill | `:8100/metrics` | `prompt_tokens_total = 126,240` |
| LMCache L1 | `:8080/status` | 20 objects, 720 MiB / 1024 MiB = **70.3%**, LRU @ 0.8 watermark |
| LMCache L2 | `:8080/status` | `l2_commit_writes = 36`, `stored_object_count = 36` |
| NIXL XNVME_KV plugin | `NIXL_KV_METRICS_PATH` JSON | `store_ops = 331,812`, `store_bytes = 1,359,101,952`, `completions_err = 0`, `submit_fail = 0`, `stalls = 0` |

**The arithmetic must reconcile exactly, and that is the actual proof** —
not the fact that requests returned 200:

```
36 groups x 9,217 ops/group (9,216 pages of 4096 B + 1 commit object) = 331,812 = store_ops
331,812 x 4096                                                        = 1,359,101,952 = store_bytes = 1.266 GiB
```

> 1.266 GiB written with **zero errors** onto a freshly-wiped namespace
> independently re-confirms TODO 6.39's retraction: there never was a
> 1 GiB limit on this namespace.

Also record: mean device latency **2,540 µs**, and `submit_retry =
156,832,920` against 331,812 completed ops = **~473 retries per op** — the
reactor busy-spins on `-EBUSY` backpressure, the same signature as TODO
6.35/6.37. That, not the device, is where the time goes.

### §4A.3 Path 3 — a COLD reader gets KV back off the device

Two independent pieces of evidence, and both are worth having.

(a) On the **live serving path**, during the §4 benchmark sweep, decode's
own adapter reported: `l2_device_hits = 8`, `l2_index_hits = 0`,
`l2_probe_errors = 0`, `l2_load_aborts = 0`, with decode's **L1 holding 0
objects** — so those 8 hits could only have come from the device, for
content only prefill ever wrote.

(b) The rigorous version, which kills the writer outright:

```bash
# [CONTROL HOST]
./scripts/verify/60-verify-l2-crossnode.sh --no-drain
```

**Expect 9/11** (see §2.4). Measured 2026-09-21, step 5:

```
OK  l2_device_hits > 0 (served a key this daemon NEVER stored) (=4)
OK  l2_index_hits == 0 (not served from its own in-process index) (=0)
OK  l2_probe_errors == 0 (=0)
OK  l2_load_aborts == 0 (=0)
OK  TOKEN IDENTITY vs recompute baseline
OK  unseen nonce did NOT produce a device hit (device_hits 4 -> 4)
```

---

## §5 Benchmark C — nixlbench (transport level) ❌ NOT BUILT

### §5.1 What it would answer

Raw NIXL transfer bandwidth and latency per backend, independent of LMCache
and vLLM. It is the right tool for "is the transport itself fast", which
neither §3 nor §4 isolates — §3's numbers include the full adapter path,
and §4's include the whole engine.

### §5.2 Current status — source present, dependency missing

Measured inside `kvstack-decode`, 2026-09-18:

| Component | Status |
|---|---|
| nixlbench source | ✅ `/tmp/nixl/benchmark/nixlbench` |
| meson / ninja | ✅ 1.12.0 / 1.13.2 |
| NIXL install | ✅ `/opt/nixl` (`include/`, `lib/`) |
| ROCm | ✅ `/opt/rocm` |
| **etcd-cpp-api headers** | ❌ **MISSING** |
| **libcpprest** | ❌ **MISSING** |
| **etcd server** | ❌ **MISSING** |

nixlbench uses etcd for metadata exchange between workers, so the missing
C++ client is a hard build blocker, not a runtime nicety.

### §5.3 Build recipe (UNVERIFIED — nobody has completed this)

```bash
# inside the container. Needs network access for the dependencies.
apt-get update && apt-get install -y \
  libcpprest-dev etcd-server etcd-client nlohmann-json3-dev

# etcd-cpp-apiv3 is not packaged for Ubuntu — build from source:
git clone https://github.com/etcd-cpp-apiv3/etcd-cpp-apiv3.git /tmp/etcd-cpp
cd /tmp/etcd-cpp && mkdir build && cd build && cmake .. && make -j && make install

# then nixlbench itself — note use_rocm, this cluster is AMD not NVIDIA
cd /tmp/nixl/benchmark/nixlbench
meson setup build -Dnixl_path=/opt/nixl -Duse_rocm=true --buildtype=release
cd build && ninja
```

`-Duse_rocm=true` is **required** here; the default builds against CUDA and
this cluster has no NVIDIA GPUs.

Running it needs an etcd endpoint reachable from every participating node:

```bash
nixlbench --etcd_endpoints http://<host>:2379 --backend UCX
```

> **Do not quote a transport number from nixlbench until it has actually
> been built and run on this cluster.** This section is a recipe, not a
> result. `ib_write_bw`, RC queue pairs, cross-node (**769.34 Gb/s peak
> bidirectional**, ~96% of 400 Gb/s per direction, TODO 6.43, HANDOFF) is
> the only real fabric throughput figure this project has — superseding
> the older ~41,898 MiB/s / ~88% figure this section used to cite — and it
> measures the RDMA fabric, not the KV path.

---

## §6 Where every counter lives

| Layer | Surface | Carries |
|---|---|---|
| L2 adapter | `http://127.0.0.1:8080/status` → `storage_manager.l2_adapters[0]` | `l2_device_hits`, `l2_index_hits`, `l2_probe_misses`, `l2_keys_probed`, `l2_lookup_calls/executions`, `l2_commit_writes`, `l2_load_aborts`, `l2_probe_errors` |
| NIXL plugin | JSON file at `$NIXL_KV_METRICS_PATH` | `store_ops`, `retrieve_ops`, `store_bytes`, `retrieve_bytes`, `completions_ok/err`, `submit_retry/fail`, `stalls`, `peak_in_flight`, `lat_us_sum`, `lat_us_bucket[8]`, `retrieve_len_checked` |
| vLLM engine | `/metrics` on 8100 / 8200 | prefix-cache queries/hits, throughput |

Two traps about these counters specifically:

- **`l2_lookup_calls` is counted at the synchronous entry point, not inside
  the coroutine.** That is deliberate: counting it in the coroutine would
  make "LMCache never called lookup" and "our event loop never ran it"
  indistinguishable. A gap between `l2_lookup_calls` and
  `l2_lookup_executions` **is** the wedged-event-loop signal.
- **`nuse` does not track KV writes on this device.** It stayed `0x0` after
  256+ pages were written and read back successfully. Any check asserting
  "nuse grows" is asserting nothing. Use `l2_commit_writes`, or the
  plugin's `completions_ok`.

---

## §7 Problems encountered, and what to do about them

Everything below was hit for real on this cluster. Ordered roughly by how
likely you are to hit it.

### 1. `lmcache bench l2` fails: `local index out of range`

```
makeXferReq: local index out of range at index 0 with value 340075
nixlInvalidParamError: NIXL_ERR_INVALID_PARAM
```

**Cause:** upstream LMCache 0.5.3. `init_mem_handlers()` builds the L1
dlist base-relative; `get_memory_indices()` returns an absolute page index.
They agree only when the buffer base is 0. Confirmed upstream by A/B
against the untouched vendor `nixl_store`, which fails identically.

**Solution:** invoke via `scripts/bench/l2-block-bench.py` (§3.0), never
`lmcache bench l2` directly.

**Related open question:** production uses the same arithmetic and does not
crash only because its 4 GiB L1 makes the bad index land *in range* —
shifted, not rejected. Whether the serving path is silently mis-indexed is
**untested** (TODO 6.35). Do not "fix" the adapter on the strength of this
section alone.

### 2. Every llama-benchy sweep dies instantly: `unrecognized arguments: --warmup-runs`

**Cause:** llama-benchy 0.4.0 has **no `--warmup-runs` flag** (verified:
`--help | grep -c -- --warmup-runs` → `0`). It always runs exactly one
discarded warmup iteration; the only control is `--no-warmup`.
`lib-bench.sh` passed the non-existent flag unconditionally, so the harness
could not run at all.

**Solution:** fixed in `scripts/bench/lib-bench.sh` — `BENCHY_WARMUP_RUNS=0`
now maps to `--no-warmup`, anything else uses the built-in single warmup,
and a value >1 warns rather than silently delivering 1.

### 3. `llama-benchy not found at /opt/kvstack/venv/bin/llama-benchy` after a successful install

**Cause:** inside the container `${VENV}` is a **shim, not a virtualenv** —
`container.sh shim` creates `python`/`python3` symlinks and a no-op
`activate`, because the image carries vllm/lmcache/nixl on the *system*
interpreter. pip therefore installs console scripts to `/usr/local/bin`.

**Solution:** `01-install-benchy.sh` now bridges it automatically. By hand:
`ln -sfn "$(command -v llama-benchy)" /opt/kvstack/venv/bin/llama-benchy`.

### 4. `unknown adapter type 'nixl_kv'` (and `nixl_store` missing too)

**Cause:** you exported `LD_LIBRARY_PATH` or `NIXL_PLUGIN_DIR` and clobbered
the container's working values. `import nixl` then fails, and LMCache's
lazy adapter loader **swallows the ImportError**, silently dropping all
three NIXL adapters from the registry. The error names the adapter, not the
real cause.

**Solution:** do not set those variables. The container already has them
right. Diagnose with:

```bash
python3 -c "from nixl._api import nixl_agent; print('nixl OK')"
```

**Generalisable lesson:** if an adapter/plugin registry reports a type as
unknown, check whether its module failed to *import* before concluding it
was never installed.

### 5. Store "succeeds" in 0.47 ms with `success_keys=0/N`

**Cause:** every transfer raised and the exception was caught and logged
per-task, so the round completed almost instantly.

**Solution:** read durations, not just success counts, and always run
`--no-skip-verify` on a smoke test. A real 16-page store is ~41 ms.

### 6. `--confirm-connector-hit` cannot find `vllm-decode.log`

**Cause:** `container.sh` bind-mounts `REPO_ROOT`, `STACK_ROOT` and
`HF_HOME` — but **not** `LOG_DIR` (`/var/log/kvstack`). The log exists only
*inside* the container.

**Solution:** run that script via `container.sh exec decode`, not on the
host. Note results under `/opt/kvstack` **are** visible from both, because
`STACK_ROOT` is mounted.

### 7. `FAIL unknown argument: decode`

**Cause:** the bench scripts differ. `10-bench-baseline.sh` accepts
`--target=decode` and `--target decode`; `30-bench-concurrency.sh` accepts
**only** the `=` form for `--pp/--tg/--depth`.

**Solution:** always use `--flag=value` in `scripts/bench/`.

### 8. A "cold reader" test that is not actually cold

**Cause:** `pkill -f lmcache.v1.multiprocess.http_server` **does not kill
the MP daemon** — measured: same pid before and after, while
`pkill -f api_server` kills vLLM fine. A surviving daemon keeps L1 and the
in-process index warm, silently invalidating the test.

**Solution:** `container.sh down <role>` then `up <role>`. Recreating the
container is the only reliable way to get a genuinely cold reader — and
remember it destroys the container's `/tmp`, so re-stage anything you put
there.

### 9. `/dev/ng1n1` missing after a reboot

See §1.3. Rebind via `/sys/bus/pci/drivers/nvme/bind`, expect to retry over
several minutes, and treat `block device for nsid 1 not supported (csi 1)`
as success rather than failure.

### 10. Loud startup warning: `device advertises value_max=4096 but configured max_value_size=32768`

**This warning is expected and correct on this hardware.** The device
understates its true ceiling by 8x: 32768 stores succeed and read back
cross-node; 33792 and above fail with `sct=7 sc=234`. 32768 is the exact
measured ceiling.

**Do not** silence it by lowering the configured value, and **do not** set
`NIXL_KV_STRICT_DEVICE_CEILING=1` — that would refuse to start on exactly
the configuration measured working. Changing this value changes on-wire
object geometry, which would require a namespace drain (currently blocked).

### 11. Huge `submit_retry`, low bandwidth

Measured ~568 retries per completed op. The reactor busy-spins on `-EBUSY`
once the queue is full.

**Solution / next step:** raising `NIXL_XNVME_NUM_QUEUES` alone does **not**
help (the producer is serialized). Raising concurrent submits
(`--in-flight 4`) gives 2.3–2.5x. Reducing the retry storm is an open
optimisation target, not a solved problem.

### 12. The namespace filled up / stale objects — premises corrected, see §3.6

This item originally assumed a 1 GiB byte budget with no delete
primitive, shared with another party, and still holding pre-fix corrupt
objects. All three are corrected in §3.6: the **"1 GiB" figure is
RETRACTED** (TODO 6.39 — it was block arithmetic on a namespace with no
LBAs); the missing delete primitive is now precisely attributed
(`libxnvme` exports `xnvme_kvs_delete`/`xnvme_kvs_list`, this plugin just
implements neither — HANDOFF §3.3 item 4); and the DSC/DPU KV store is
**VOLATILE** (TODO 6.41) — nothing survives an uptime boundary, so there
are no pre-fix corrupt objects left to collide with, only whatever this
uptime window has written.

**Solution:** size runs (§3.6) and use a distinct `namespace` per run so
objects from a different geometry can never be mistaken for a new hit.
Draining is no longer gated on an ownership decision — TODO 6.41c found
the drain step targets a store our data never reached, dissolving that
premise rather than resolving it; see §3.6 for the current drain story
and `scripts/target/51-reset-smc3-storage.sh` for the separate
foreign-target case.

### 13. Everything passes but no KV moves

**A correct completion proves nothing.** Two separate defects in this
project produced perfect output at plausible latency while transferring
zero KV. Read the two engines' throughput counters, not the response text
or the HTTP status.

Specifically: `query_memory()` reports **PRESENT as `{}` — an empty, falsy
dict** — and ABSENT as `None`. Code written `if resp[i]:` scores every hit
as a miss and reproduces `retrieve_ops=0` with a brand-new root cause. Use
the identity check (`is_probe_hit`), never truthiness.

### 14. A green low-level check that proves nothing about the layer above

Rung `35` passed 8/8 while the adapter's real commit-write path was
silently broken underneath it, because `35` writes its commit object
through a *different* NIXL call sequence than the adapter does, and
structurally can never hold two overlapping OBJ registrations.

**Lesson:** compare **code paths**, not just outcomes, before trusting a
lower rung to cover a higher one.

### 15. `01-install-benchy.sh` dies with `KeyError: 'MODEL'`

```
File "<stdin>", line 4, in <module>
KeyError: 'MODEL'
```

**Cause:** the tokenizer pre-download heredoc is a separate python process
reading `os.environ["MODEL"]`; `cluster.env` sets `MODEL` without exporting
it. `HF_HOME`/`HF_TOKEN` were exported right above it, `MODEL` was not.
Because the kill lands under `set -e` **before** the CLI verification, the
install reports FAILURE while pip has actually **SUCCEEDED** — and the
tokenizer this step exists to pre-cache is left uncached, so the next timed
sweep pays for a cold HF fetch inside its own measurement.

**Solution:** fixed 2026-09-21 — `export MODEL` added. If you see this on
an older checkout, the install did work; re-run after the fix to warm the
tokenizer cache.

### 16. Rung 50 reports `decode side channel reachable (30.2.1.1:5601)` FAILED from the control host

**Cause:** decode's NIXL side channel is bound to a **FABRIC** address
(`PD_SIDE_CHANNEL_HOST_DECODE=30.2.1.1`) that the control host has no route
to, and the log-based verdict needs `/var/log/kvstack/vllm-decode.log`,
which is not bind-mounted (§2.4).

**Solution:** run rung 50 **on the decode node, in the container**. This is
a **FALSE FAIL** on an otherwise healthy stack, not a real defect.

**The context has moved, and it is worth restating precisely (§1.4).**
`30.2.1.1` is `benic1p1`, but both roles' `UCX_NET_DEVICES` are pinned to
a **different** device entirely. That means the side channel and the
actual UCX data device sit on **different fabric planes**, not merely
different subnets — TODO 1.9's original "harmless today" qualifier on
this asymmetry is now stale and should not be read as still current;
resolve which plane each is meant to be on before trusting either address
under a topology change.

### 17. `--prefix-benefit` reports a speedup below 1.0 on a healthy tier

**Cause:** `compare_runs.py --prefix-benefit` pairs inference@depth=0
against inference@depth>0 — two different workloads, not a like-for-like
cache comparison (§4.4, §4A.2).

**Solution:** do not trust the ratio; compare the context-load row against
the inference row at the **same depth** instead. See TODO 1.13.

### 18. The first llama-benchy run in a fresh container downloads a text corpus

```
Downloading book from https://www.gutenberg.org/files/1661/1661-0.txt...
Saved text to cache: /root/.cache/llama-benchy/…
```

**Cause:** llama-benchy sources its prompt corpus from Project Gutenberg
and caches it under `/root/.cache/llama-benchy`. Only
`/root/.cache/huggingface` is bind-mounted (as `HF_HOME`) — that directory
is **not**, so the corpus is re-downloaded after every `container.sh
down/up`, and the run needs egress to gutenberg.org.

**Solution:** it happens during llama-benchy's startup, before the timed
runs, so it does not land inside a measured window — but it **will** fail a
run on a host with no external egress. Re-run `01-install-benchy.sh` after
any container recreation, and expect the corpus fetch on the first sweep
afterwards.

### 19. `ipc_wrapper.py:85` KV-cache registration OOM — root cause NOT established

```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 2.00 MiB.
GPU 0 has a total capacity of 191.98 GiB of which 28.37 GiB is free.
```

**Cause:** the LMCache MP daemon fails `REGISTER_KV_CACHE` with the above
`torch.OutOfMemoryError` on a **2 MiB** allocation against **28.37 GiB
free**, on IPC import 1 of 36. vLLM decode's `EngineCore` then times out
at 300 s waiting for the daemon and its worker segfaults during HSA
teardown, inside PyTorch's **vendored** `libhsa-runtime64.so`. Root cause
is **NOT established** — seven candidate causes have been eliminated
(kernel OOM, physical HBM capacity, GPU virtual address space, an env-var
discriminator, a `dma_buf` IPC leak, container/host ROCm version skew,
and cross-process IPC handle transport as a sufficient cause on its
own), and none is confirmed.

**2026-09-29 refinement — this is not what it looks like.** The
allocator is already dead **before** the IPC import: a bare
`torch.empty(2<<20, device='cuda:0')` in the same container, with no
LMCache, no NIXL, no IPC involved at all, fails **identically** while
vLLM decode is resident. So this is **not** an IPC failure and **not**
an LMCache failure — it is something vLLM's `EngineCore` does that
leaves the GPU unable to hand out any allocation to any other process,
and every earlier "IPC" framing of this defect, including this entry's
own title, is aimed at the wrong layer.

**Solution:** none. `gpu_memory_utilization` 0.85 → 0.60 was tried and
changed nothing — this is not a headroom problem. See
TROUBLESHOOTING.md's `ipc_wrapper.py:85` entry for the full elimination
record, and TODO 6.47.

### 20. Zombie PID silently blocks a daemon restart

**Cause:** the role container's PID 1 is `sleep infinity`, which never
reaps. A dead LMCache MP daemon or a crashed vLLM worker therefore
lingers as a **zombie**, and `start-lmcache-daemon.sh`'s liveness check
uses `kill -0`, which succeeds against a defunct pid — so it reports
`already running (pid N) — not restarting` for a daemon that is
actually dead, and silently refuses to start a working one in its place.
**NOT FIXED.**

**Solution:** `container.sh down <role>` then `up <role>`. Recreating the
container is the only reliable way to clear the zombie (this is the same
underlying fact §7 item 8 depends on for a genuinely cold reader).

### 21. RDMA mode connects anyway over TCP

**Cause:** a silent TCP fallback can pass RDMA acceptance even with
`KV_TRANSPORT=rdma` set. By design `setup_ucx_env` excludes `tcp` from
`UCX_TLS` in RDMA mode (HANDOFF invariant 6), but anything that bypasses
`setup_ucx_env` — a hand-launched vLLM process, or `UCX_TLS` exported
earlier in the environment and left to override what this function
sets — reintroduces it invisibly. This is now **live-relevant**, not
theoretical: `creds/setup-4.env` sets `KV_TRANSPORT="rdma"` for this
cluster.

**Solution:** confirm nothing pre-sets `UCX_TLS` before `setup_ucx_env`
runs, and confirm which leg you are actually observing — the storage leg
is NVMe-oF/TCP unconditionally by design, and seeing TCP there is
correct, not a fallback. See TROUBLESHOOTING.md's "RDMA mode connects
anyway over TCP" entry for the full diagnostic.

### 22. `UCX_IB_ROCE_SUBNET_PREFIX_LEN` must be 8, not 16

**Cause:** prefill and decode sit in different `/24`s — smc1 is
`30.1.N.1/24`, smc2 is `30.2.N.1/24` — so UCX's RoCE local-subnet
reachability check needs to compare at `/8` to see them as the same
fabric. At the old `/16` setting UCX reports `Destination is
unreachable` on every transport and silently discards the RoCE lane,
falling back to shm/ROCm-only transports that cannot do active
messages. **A verbs-level check cannot detect this**: `ib_send_bw` over
the identical devices at the identical GID index reads a healthy
**25858 MiB/s** regardless of this setting, because `ib_send_bw` never
consults it — this is a UCX policy filter, not a fabric fault.

**Solution:** `UCX_IB_ROCE_SUBNET_PREFIX_LEN` must be `8`. See
`config/cluster.env`'s comment on this variable for the isolated,
single-variable measurement.

### 23. `NIXL_ERR_BACKEND` / `EngineCore failed to start` from a stale RDMA device pin

**Cause:** a reboot renamed every RoCE device on both nodes (§1.4), and
creds still pinned the old names. **Measured 2026-09-30:** after the
2026-09-29 reboot, devices came back as `roce_benicNp1` while creds still
pinned `ionic_7:1`. UCX matches no device, falls back to a transport that
cannot do active messages, and `NixlConnector` dies at construction with
`NIXL_ERR_BACKEND`; vLLM surfaces this as `EngineCore failed to start`
from `multi_connector.py`. See §1.4 for the check that catches this and
the full failure signature.

**The diagnostic lesson is worth keeping on its own:** the top-level
Python traceback (`RuntimeError: Engine core initialization failed`)
never names a device. The UCX `WARN` that does — and that lists the
correct device names to use instead — sits ~6 lines **above**
`EngineCore failed to start` in the container's `vllm-decode.log`.
Always read upward from that line, not just at it.

---

## §8 Teardown

```bash
# [SMC2] proxy — no dedicated stop script; stop_bg's PID-file convention applies
kill "$(cat /run/kvstack/disagg-proxy.pid)"

# [SMC1] / [SMC2]
./scripts/decode/99-stop.sh --clean-shm      # or prefill/99-stop.sh
./scripts/common/container.sh down decode
```

Nothing is left running deliberately at the end of a session — containers
carry no `--restart` policy. `99-stop.sh` **does** reliably stop the MP
daemon: both `scripts/{prefill,decode}/99-stop.sh` explicitly invoke
`scripts/common/stop-lmcache-daemon.sh` — this document previously said
otherwise, and that was wrong (the pkill footgun in §7 item 8 is a real
but separate failure mode).

Pass `--clean-shm`. A stale `/dev/shm/lmcache_*` or `/dev/shm/nixl_*`
segment left behind by a crash or the §7 item 19 OOM makes the daemon
fail identically on its next start, and `container.sh down` does not
clean `/dev/shm` for you.

---

## See also

- [HANDOFF.md](HANDOFF.md) — what is real, what is assumed, what is still
  wrong; §3 is the resume procedure.
- [TODO.md](TODO.md) — 6.35 (block-level benchmarking + the upstream
  indexing defect), 1.13 (engine-level benchmark rework), 6.15
  (cross-instance reuse).
- [BENCHMARKING.md](BENCHMARKING.md) — llama-benchy metric semantics and
  the reproducibility rule (`run.env` or it is not a result).
- [docs/design/nixl-kv-l2-adapter.md](design/nixl-kv-l2-adapter.md) — the
  adapter's naming scheme, protocol, and counters.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — failure signatures not
  specific to benchmarking.
