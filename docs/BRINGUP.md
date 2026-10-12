# Bring-up runbook

Step-by-step procedure to take this stack from a cold node to serving traffic,
and to benchmark it.

This file is **procedure only**. When something fails, go to
[`KNOWN-ISSUES.md`](KNOWN-ISSUES.md) — every failure this project has hit is
recorded there by number. Rules that constrain *how* you work on these
machines (shared hardware, destructive operations, cleanup) are in
[`../AGENTS.md`](../AGENTS.md), and per-lab identity is in
[`setups/setup-4.md`](setups/setup-4.md).

Throughout: `[SMC1]` = prefill, `[SMC2]` = decode, `[SMC3]` = KV target,
`[CONTROL]` = your workstation. Addresses and credentials come from
`creds/active.env`; nothing here hardcodes them.

Set these once per shell on each node:

```bash
REPO=/root/pmallapp/kv-stack            # the single source of truth on every node
DSTATUS="http://127.0.0.1:${LMCACHE_MP_HTTP_PORT:-8080}/status"
```

---

## Step 0 — Survey the machine before you touch it

These hosts are shared. Run this first, every session.

```bash
# [SMC1] [SMC2] — who else holds the ports we need
for P in "${LMCACHE_MP_HTTP_PORT:-8080}" "${LMCACHE_MP_PORT:-6557}" \
         "${NIXL_SIDE_CHANNEL_PORT_PREFILL:-5600}" \
         "${NIXL_SIDE_CHANNEL_PORT_DECODE:-5601}"; do
  echo "== :$P"; ss -tlnp | awk -v PAT=":$P$" '$4 ~ PAT'
done

docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
rdma resource show qp
```

Use the anchored `awk` match above, not `grep -w ":8080"`.

For any RDMA queue pair or busy GPU you find, check the owning PID's cgroup
before concluding it is yours. Take only the GPUs and NICs your setup file
allocates.

## Step 1 — Prepare each node

```bash
# [SMC1]
cd "${REPO}" && ./scripts/prefill/01-host-prep.sh

# [SMC2]
cd "${REPO}" && ./scripts/decode/01-host-prep.sh
```

This mounts hugepages, loads `amdgpu`, verifies the GPU count and arch, loads
`nvme_tcp`/`nvme_fabrics`, reports the data-plane interfaces, and checks RDMA
access and the KV device.

Run it on the host, not inside the container — it mounts hugetlbfs.

If the node has just rebooted, do **Step 9** first; host-prep assumes the
driver, the KV device and the fabric interfaces are already in place.

## Step 2 — Start the container and write the shim

```bash
# [SMC1] and [SMC2]
cd "${REPO}"
./scripts/common/container.sh up "<prefill|decode>"
./scripts/common/container.sh shim
docker exec "kvstack-<role>" bash -lc \
  'apt-get update -q && apt-get install -y -q ibverbs-utils=50.0-2ubuntu0.2'
```

Three things, all mandatory:

1. `container.sh up` does **not** run `shim`. Run it explicitly — both
   `start-vllm.sh` and `start-lmcache-daemon.sh` require it.
2. The image does not ship `ibverbs-utils`, and `require_rdma_access()` needs
   `ibv_devinfo`. Install it after every container recreate.
3. The repo is bind-mounted at the same path inside the container as outside,
   so the container's working directory is `${REPO}`.

Verify before going further:

```bash
./scripts/<role>/verify/run-all.sh --through 04
```

## Step 3 — Start the LMCache MP daemon

The role start scripts in Step 4 call this for you; run it directly only when
you want the daemon up on its own. It is idempotent.

```bash
# [SMC1] and [SMC2]
./scripts/common/container.sh exec <role> ./scripts/common/start-lmcache-daemon.sh
```

Check it:

```bash
./scripts/common/container.sh exec <role> "curl -s ${DSTATUS} | python3 -m json.tool | head -40"
```

Expect `is_healthy: true`, and under `storage_manager.l2_adapters[0]`:
`"type": "NixlKvL2Adapter"`, `"backend": "XNVME_KV"`, and a `namespace`
fingerprint.

**Both nodes must report the same namespace.** It is a geometry fingerprint
over model, TP size, chunk size, dtype, alignment and max value size — so it
changes whenever any of those change, and objects written under a different
fingerprint are unreachable. If the two nodes differ, every cross-node lookup
misses and the tier silently does nothing.

## Step 4 — Start prefill, decode and the proxy

Order matters: prefill, then decode, then the proxy.

```bash
# [SMC1]
./scripts/common/container.sh exec prefill ./scripts/prefill/03-start-prefill.sh

# [SMC2]
./scripts/common/container.sh exec decode  ./scripts/decode/03-start-decode.sh

# [SMC2] — the proxy lives on the decode host
./scripts/common/container.sh exec decode  ./scripts/proxy/start-proxy.sh
```

Each role takes roughly 60–130 s at Qwen3-8B. `start-vllm.sh` hard-gates on the
daemon being reachable rather than silently serving from local cache.

To override GPU memory for one run, prefix the command:

```bash
./scripts/common/container.sh exec decode 'GPU_MEM_UTIL=0.85 ./scripts/decode/03-start-decode.sh'
```

Check each layer independently:

```bash
curl -s http://127.0.0.1:8100/v1/models   # [SMC1] prefill
curl -s http://127.0.0.1:8200/v1/models   # [SMC2] decode
curl -s http://127.0.0.1:8000/status      # [SMC2] proxy
```

## Step 5 — Verify the node

Run the per-role ladder on each node. It stops at the first failure, because
each step rules out the layer below it.

```bash
# [SMC1] and [SMC2]
cd "${REPO}" && ./scripts/<role>/verify/run-all.sh
```

| step | proves |
|---|---|
| 01 host | kernel, `amdgpu` loaded and at the expected version, GPU enumeration, co-tenancy |
| 02 rdma | pinned RDMA devices exist and their ports are usable, `ibv_devinfo`, NIC firmware personality |
| 03 kvdev | the KV namespace resolves and is a KV namespace, not the boot drive |
| 04 container | container running, mounts point at `${REPO}`, shim and `ibverbs-utils` present |
| 05 daemon | daemon alive and not a zombie, `is_healthy`, L2 adapter and namespace |
| 06 vllm | vLLM alive and running the TP / `GPU_MEM_UTIL` geometry you configured |
| 07 serving | a real chat completion, through the proxy on decode |

Useful flags: `--through 04` before starting the stack, `--from 04` after a
container recreate, `--keep-going` to see every failure at once. Set
`EXPECT_AMDGPU=<version>` to pin the driver version as a hard check.

## Step 6 — Verify the data path between nodes

Step 5 proves each node is sane. This proves the nodes actually move KV.

Run the rungs in order, from the stated host. A later rung after an earlier
failure just reproduces the same root cause in a harder-to-read form.

| rung | script | run from | proves |
|---|---|---|---|
| 10 | `10-verify-network.sh` | any node or control | reachability, MTU, throughput |
| 20 | `20-verify-nixl-plugin.sh` | each node, in container | the NIXL plugin loads and the device answers |
| 30 | `30-verify-kv-roundtrip.sh` | each node, in container | cross-node store and retrieve, byte-exact |
| 35 | `35-verify-nixl-kv-smoke.sh` | control host | the naming scheme and commit protocol |
| 40 | `40-verify-disagg.sh` | decode node, in container | end-to-end disaggregation through the proxy |
| 50 | `50-verify-pd-direct.sh` | decode node, in container | the P→D direct NIXL leg |
| 60 | `60-verify-l2-crossnode.sh` | control host | the L2 tier across both nodes |

The acceptance signal for disaggregation is decode's `Avg prompt throughput`
at **0.0 tokens/s** with external prefix cache hit rate rising. A correct
completion at plausible latency proves nothing on its own.

## Step 7 — Benchmark

**Block level** (no vLLM, no proxy — the L2 tier on its own):

```bash
# [SMC2], in the container
./scripts/common/container.sh exec decode ./scripts/bench/l2-block-bench.py --help
```

**Engine level** (llama-benchy against the live proxy, from the control host):

```bash
# [CONTROL]
cd /home/pmallapp/share/proj/kv-cache && ./local_run_bench_reduced.sh
```

That wrapper sets the sweep shape and calls `scripts/bench/run-all.sh`, which
runs baseline → prefix-cache → concurrency and stops if baseline fails.
Results land in `${BENCHY_RESULT_DIR}` as `result.json` plus `progress.jsonl`.

Size runs before launching them: space on the KV namespace is never reclaimed
and there is no usage telemetry.

## Step 8 — Tear down

Reverse order: proxy, then vLLM, then the daemon, then the container.

```bash
# [SMC2] — the proxy has no dedicated stop script
./scripts/common/container.sh exec decode \
  'source scripts/common/lib.sh && stop_bg disagg-proxy'

# [SMC1] and [SMC2] — stops vLLM and the daemon
./scripts/common/container.sh exec <role> ./scripts/<role>/99-stop.sh

# [SMC1] and [SMC2] — only if you need the container gone
./scripts/common/container.sh down <role>
```

Do not pass `--clean-shm` or `--release-hugepages` on a shared host: both are
host-wide and hit every tenant, not just this stack.

Afterwards, confirm the resources you released are actually free — and that
every resource you never owned is still held by its owner.

## Step 9 — After a reboot

A reboot leaves a node unable to serve, and none of this is automatic. Do these
in order before Step 1.

```bash
# 1. Load the GPU driver. modprobe.blacklist=amdgpu on the kernel command line
#    suppresses autoload; it does not block an explicit load by name.
modprobe amdgpu
ls -d /sys/class/drm/card*/device/vendor | wc -l      # expect 8, not 1

# 2. Bind the DSC NVMe function so the KV device appears. It does not
#    auto-bind, and without this /dev/ng1n1 is simply absent.
lspci -d 1dd8: -k | grep -B1 -A2 'Non-Volatile'       # find the BDF
echo 0000:37:00.0 > /sys/bus/pci/drivers/nvme/bind
ls /dev/ng*                                            # expect ng0n1 AND ng1n1

# 3. Raise the fabric NICs. netplan will not bring up an admin-down link.
ip link set enp9s0 up
ip link set enp38s0 up

# 4. Assign the fabric addresses. netplan matches these NICs on MAC, but they
#    report a placeholder MAC, so the match never fires and the addresses are
#    never applied. Take the values from /etc/netplan/75-backend-pf-v4.yaml.
ip addr add 30.2.1.1/24 dev enp9s0                     # SMC2; SMC1 uses 30.1.1.1
ip addr add 30.2.2.1/24 dev enp38s0                    # SMC2; SMC1 uses 30.1.2.1
ip link set enp9s0 mtu 9000 up
ip link set enp38s0 mtu 9000 up
ip route replace 30.1.1.0/24 via 30.2.1.2 dev enp9s0   # peer's rail
ip route replace 30.1.2.0/24 via 30.2.2.2 dev enp38s0
```

Then confirm the pinned RDMA ports came up and the peer is reachable:

```bash
for d in ionic_0 ionic_1; do echo "$d: $(cat /sys/class/infiniband/$d/ports/1/state)"; done
ping -c2 -I 30.2.1.1 30.1.1.1
```

Device names and indices are not stable across reboots. Re-derive them from
`/sys/class/infiniband/*` and check the netdev behind each one rather than
trusting a name that was correct last week.

Finally, the container does not survive a reboot — redo Step 2, including the
`ibverbs-utils` install.

---

## See also

- [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md) — every failure hit so far, numbered
- [`../AGENTS.md`](../AGENTS.md) — rules for working on shared hardware
- [`HANDOFF.md`](HANDOFF.md) — invariants and session history
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — deeper diagnostics
- [`setups/setup-4.md`](setups/setup-4.md) — this lab's identity and allocation
