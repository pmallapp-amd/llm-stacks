# setup-4 — per-setup rules (the Pensando DSC lab)

Active when `creds/active.env -> setup-4.env`. Project-wide rules are in
[`AGENTS.md`](../../AGENTS.md); this file carries only what is specific to this
lab. **Values live in the gitignored `creds/setup-4.env`; this file carries the
allocation and the reasoning, and contains no secrets.**

| Role | Host | Address |
|---|---|---|
| prefill | `smc1` | `10.30.75.198` |
| decode | `smc2` | `10.30.75.204` |
| target | `volcano17` (*not* `smc3`) | `10.30.69.159` |

---

## 1. TENANCY ALLOCATION — this is a shared lab

**smc1 and smc2 are shared with other parties.** This project's allocation is
fixed and deliberately small. Anything outside it belongs to someone else, **even
when it is idle and even when `rocm-smi` shows it as visible**.

### 1.1 GPUs — GPU 0 and GPU 1 ONLY

Each node has 8× MI300X (KFD nodes 2–9). **This project may use GPU 0 and GPU 1
on smc1 and smc2, and no others.** GPUs 2–7 on both nodes are out of scope: do
not allocate them, do not benchmark on them, do not reset them, do not include
them in a TP group.

| | Allocated | PCI | Off-limits |
|---|---|---|---|
| smc1 | GPU 0, GPU 1 | `05:00.0`, `29:00.0` | GPU 2–7 |
| smc2 | GPU 0, GPU 1 | `05:00.0`, `29:00.0` | GPU 2–7 |

Enforced by `TP_SIZE`, which here is a **tenancy ceiling, not a tuning knob**.
`start-vllm.sh` builds the device list as `seq 0 .. TP_SIZE-1`, so `TP_SIZE=2`
yields exactly `HIP_VISIBLE_DEVICES=0,1` and `TP_SIZE=1` yields `0`. Either is
inside the allocation; **anything above 2 reaches into a neighbour's GPUs.**

Currently pinned at `TP_SIZE=1`. Note this is *not* a workaround for the
`ipc_wrapper.py:85` fault — that was an early theory and it is wrong (the fault
reproduces at TP=1, single-process; see `docs/BRINGUP.md` §7 item 19).

Three gaps this pin does **not** close — know them before you trust it:

1. **The container sees all 8 GPUs.** `container.sh` maps `/dev/kfd` and
   `/dev/dri` wholesale; there is no per-GPU render-node filter. Only the vLLM
   process env narrows it. Anything you launch by hand inside the container can
   still touch GPU 2–7 — set `HIP_VISIBLE_DEVICES=0,1` yourself.
2. **The LMCache MP daemon sets no GPU env at all.** It sees every GPU.
3. **`01-host-prep.sh` gates on GPUs *visible*, not *free*.** It will pass
   happily while a co-tenant holds GPU 0.

Because of (1) and (2), the GPU pin is a convention this project must uphold, not
a sandbox the tooling enforces. Check residency before and after every run.

### 1.2 RDMA — 2 rails per node, rail 1 and rail 2 ONLY

Each node has 8 RoCE devices. **This project may use 2 of them per node:
`roce_benic1p1` and `roce_benic2p1`.** Rails 3–8 are out of scope.

| Node | Allocated | Netdev / address | Off-limits |
|---|---|---|---|
| smc1 | `roce_benic1p1:1`, `roce_benic2p1:1` | `benic1p1` 30.1.1.1/24, `benic2p1` 30.1.2.1/24 | rails 3–8 |
| smc2 | `roce_benic1p1:1`, `roce_benic2p1:1` | `benic1p1` 30.2.1.1/24, `benic2p1` 30.2.2.1/24 | rails 3–8 |

Set via `PREFILL_UCX_NET_DEVICES` / `DECODE_UCX_NET_DEVICES` as a comma-separated
list; `setup_ucx_env()` passes the value to `UCX_NET_DEVICES` verbatim.
As with the GPUs, `/dev/infiniband` is mapped wholesale into the container —
all 8 devices are visible, and `UCX_NET_DEVICES` is the only thing narrowing it.

---

## 2. Measured facts that override older comments in this repo

Measured **2026-10-04**, on both nodes. Where these contradict `config/cluster.env`
or `creds/setup-4.env` comments, these win (`AGENTS.md` §4).

### 2.1 RDMA device names are `roce_benicNp1`, not `ionic_N`

The 2026-09-29 reboot renamed every device. `ionic_*` **no longer exists on either
node.** All 8 `roce_benic<N>p1` (N=1..8) are present and `PORT_ACTIVE` on both.

Any pin of the form `ionic_7:1` resolves to nothing. `require_rdma_access()` only
*warns* on a missing device name — the failure then surfaces ~95 s later as
`NIXL_ERR_BACKEND` / `EngineCore failed to start`, naming neither the device nor
the cause. **Re-derive from `/sys/class/infiniband/*` at every bring-up.**

The old `ionic_N -> benic<N+1>p1` mapping table in `config/cluster.env`, and its
claim that only `ionic_2/3/5/6` line up across hosts, are both obsolete. Device
`roce_benic<N>p1` now names the same physical rail on both hosts, symmetrically.

### 2.2 The fabric IS routed between smc1 and smc2 — RETRACTS "no route"

`creds/setup-4.env` and `config/cluster.env` both state the compute nodes have no
route to each other's fabric and that the 1 GbE management NIC (`ens51f0`) is the
only path. **That is no longer true.** Measured, symmetric, on every rail tested:

```
smc1: 30.2.1.1 via 30.1.1.2 dev benic1p1 src 30.1.1.1   # 0.12 ms RTT
smc2: 30.1.1.1 via 30.2.1.2 dev benic1p1 src 30.2.1.1
```

Rails 1, 2 and 3 all pass cross-node. GIDs are **RoCE v2**. Consequence: the
compute leg no longer has to fall back to 1 GbE management, and the split-plane
asymmetry (bulk data on `ens51f0`, side channel on a fabric NIC) that
`docs/BRINGUP.md` flags should be resolved by putting **both** legs on the fabric.

### 2.3 `UCX_IB_ROCE_SUBNET_PREFIX_LEN` must be `8`

`config/cluster.env` defaults it to `16` and nothing in the repo overrides it —
but smc1 is `30.1.N.1/24` and smc2 is `30.2.N.1/24`, and the rails are **routed
via a gateway**, not on a common subnet. At `/16` UCX's RoCE reachability check
discards the lane as "unreachable IB device address" while the fabric is healthy.
`/8` makes the check agree with the fabric. Mandatory, not tuning.

### 2.4 `*_RDMA_DEV` must be set or host-prep dies

With `KV_TRANSPORT=rdma`, `01-host-prep.sh` hard-dies unless `PREFILL_RDMA_DEV` /
`DECODE_RDMA_DEV` are set. The die message is itself misleading — `setup_ucx_env()`
reads `*_UCX_NET_DEVICES`, not `*_RDMA_DEV`. Set both; keep them consistent.

### 2.5 PRECONDITION — AI NIC firmware personality must be `pulsar`, not `hydra`

**Check this before any RDMA bring-up. It is the first thing to verify when
leg A misbehaves.**

The Pensando `vulcano` AI NICs carry a P4 program ("personality") in firmware.
A card running **`hydra` cannot create a UD queue pair**; UCX needs one for
`ud_verbs`, so the iface open fails and the whole UCX worker dies:

```
roce_benic2p1: iface ... failed to create UD QP ... failed: Invalid argument
uct_iface_open(ud_verbs/roce_benic2p1:1) failed: Input/output error
Failed to create engine: Failed to create UCX worker: Input/output error
```

vLLM then dies ~2 minutes later as `Engine core initialization failed`, naming
neither the NIC nor the firmware. **Only `pulsar` works.**

This is invisible everywhere you would naturally look. Measured 2026-10-04,
hydra and pulsar cards report **identical** `fw_ver` (`1.130.0-a-135`),
`ethtool -i firmware-version`, `devlink asic.id` (`0x5`) and `fw.soc_zephyr`.
The **only** discriminator is `eth_dbgtool`:

```bash
nicctl show card                        # card BDFs (NOT the netdev BDF)
eth_dbgtool --bdf 0000:06:00.0 -V       # -> p4_program: hydra | pulsar
```

Note the card BDF is a PCI **ancestor** of the netdev function
(`benic1p1` = `08:00.3` → `07:00.0` → card `06:00.0`); `eth_dbgtool` rejects the
netdev BDF.

Enforced in code by `require_rdma_fw_program()` (`scripts/common/lib.sh`),
called from `require_rdma_access()`, so it fails in ~3 s instead of ~2 min.
Escape hatches: `RDMA_FW_CHECK=0`, `RDMA_REQUIRED_P4_PROGRAM=<name>`.

> **State as measured 2026-10-04: all 8 cards on smc1 AND smc2 are `hydra`.**
> No rail can carry leg A until cards are flashed to `pulsar`. This — not the
> `ionic_*` rename alone — is the root of the long-standing leg A blocker.

Flashing is **destructive and shared-visible**: it takes down the co-tenant's
traffic on that port as well as ours (`docs/HANDOFF.md`). Flash only cards
proven unused, never a card carrying another tenant's QPs.

### 2.5.1 Flashing a card to `pulsar` — scoped, on a shared box

Pulsar release artifacts (control host only; `/vol` is **not** mounted on
smc1/smc2, so stage on the control host and push):

```
/vol/builds/hourly/<ver>/rudra-bundle/release-artifacts/pulsar/vulcano/
    ainic_bundle_<ver>.tar.gz          # use this one
    ainic_bundle_ualink_<ver>.tar.gz   # UALink variant — not this
```

Add the 400G breakout profile (needs `dtc`; produces a ~9.5 MB standalone fw tar
alongside a ~350 MB bundle — push only the **tar**):

```bash
python3 ~/share/scripts/vulcano/pulsar/patch-ainic-firmware-400g.py \
        ainic_bundle_<ver>.tar.gz -o <outdir>
python3 ~/share/scripts/vulcano/pulsar/patch-ainic-firmware-400g.py \
        --info <outdir>/ainic_fw_vulcano-400g.tar   # expect default -> ['1x400G-4']
```

**The script prints flashing instructions that hit all 8 cards and end in
`nicctl reset card --all`. Do not use them.** Scope every step with `--bdf`:

```bash
BDFS=0000:06:00.0,0000:23:00.0          # rails 1 and 2 ONLY — see §1.2
nicctl update card profile -i <fw>.tar -p default -b "$BDFS" -l /tmp/prof.log
nicctl update port breakout -b 0000:06:00.0 -p 1 --mode 1x400g-4
nicctl update port breakout -b 0000:23:00.0 -p 1 --mode 1x400g-4
nicctl reset card -b "$BDFS"            # NOT --all
eth_dbgtool --bdf 0000:06:00.0 -V       # confirm p4_program: pulsar
```

Card-BDF ↔ rail map (measured 2026-10-04, identical on smc1 and smc2):

| rail | netdev fn | **card BDF** | | rail | netdev fn | **card BDF** |
|---|---|---|---|---|---|---|
| benic1p1 | 08:00.3 | `0000:06:00.0` | | benic5p1 | 88:00.3 | `0000:86:00.0` |
| benic2p1 | 25:00.3 | `0000:23:00.0` | | benic6p1 | a5:00.3 | `0000:a3:00.0` |
| benic3p1 | 45:00.3 | `0000:43:00.0` | | benic7p1 | c5:00.3 | `0000:c3:00.0` |
| benic4p1 | 68:00.3 | `0000:66:00.0` | | benic8p1 | e8:00.3 | `0000:e6:00.0` |

Prove the target cards are unused first (`rdma resource show qp` empty, netdev
`tx_packets` flat, no co-tenant process bound). **Delete the staged firmware
from the nodes and the control host when the flash is done** — the bundle is
~350 MB and `/root` is shared.

#### What a flash actually does to the host — measured 2026-10-04 on smc1

Flashing cards `06:00.0` and `23:00.0` to pulsar `1.130.0-a-149`:

1. **It prints `Unsuccessful` and is still successful.** The per-image log
   (`-l /tmp/prof.log`) showed every image programmed and checksum-verified, and
   `ethtool -i` on the new netdev reports `1.130.0-a-149`. Trust the log and the
   measured firmware version, not the summary line.
2. **Device names change, in both directions.** The pulsar card relocates its
   Ethernet function to its own bus (`08:00.3` → `09:00.0`), so the netdev is
   renamed `benic1p1` → `enp9s0` and the RDMA device `roce_benic1p1` → **`ionic_0`**.
   This is why old creds pinned `ionic_7:1`: that pin dates from a pulsar era.
   Re-derive names after every flash (`AGENTS.md` §4), and expect the netdev to
   come up **DOWN with no IP** — its addressing was keyed to the old name.
3. **`nicctl` and `eth_dbgtool` are themselves personality-specific**, and
   `/usr/sbin/nicctl` is only a dispatcher. Both backends are installed:
   `/usr/sbin/nicctl-ainic-vulcano-rudra-{pulsar,hydra}`. Once the host holds
   **mixed** flavours, the dispatcher aborts with a misleading
   `no AMD NIC cards detected` / `card discovery failed` — for *every* card,
   including untouched ones. **Call the backend binary directly** on a mixed host.
4. A freshly flashed card may report `Invalid card handle` to both backends while
   still working perfectly as an RDMA device. Management-plane health and
   data-plane health are independent here; test the data plane before concluding
   the card is broken.

**The payoff, measured directly** (`ibv_create_qp` with UCX's ud_verbs geometry):

| device | personality | UD QP |
|---|---|---|
| `ionic_0`, `ionic_1` (flashed) | pulsar | **OK** |
| `roce_benic3p1` (untouched) | hydra | **FAILED** |

That is the whole blocker, isolated to one bit of firmware identity.

### 2.6 Storage leg

`/dev/ng1n1` is a **local** PCIe char device (`0000:36:00.0`, `mn=PDSNVME`,
`csi=0x1`), not a re-export of the target's namespace. `/dev/ng0n1` is the **boot
drive** — never hand it to the KV backend; `assert_kv_char_device()` exists to
stop exactly that. The target `volcano17` is shared with another party and serves
a different NQN; do not restart its `nvmf_tgt`.

---

## 3. Bring-up on setup-4, in order

Run the §1.0 co-tenancy check first, always. `container.sh shim` is a mandatory
prerequisite that `up` does not perform (`AGENTS.md` §5).

```bash
# control host
scripts/common/deploy.sh --node compute --no-creds   # --no-creds unless creds changed

# smc1 (prefill) and smc2 (decode), in ${REPO}
./scripts/common/container.sh shim
./scripts/common/container.sh up      <role>
./scripts/common/container.sh adapter-check <role>
./scripts/common/container.sh exec    <role> ./scripts/<role>/03-start-<role>.sh
# smc2 only
./scripts/common/container.sh exec decode ./scripts/proxy/start-proxy.sh
```

**Confirm the pin took, every time** — do not assume it from the config:

```bash
# exactly "0,1"
tr '\0' '\n' < /proc/$(cat /run/kvstack/vllm-<role>.pid)/environ | grep HIP_VISIBLE_DEVICES
# exactly the two allocated rails
tr '\0' '\n' < /proc/$(cat /run/kvstack/vllm-<role>.pid)/environ | grep UCX_NET_DEVICES
# QPs only on roce_benic1p1 / roce_benic2p1
rdma resource show qp
```

## 4. Teardown — mandatory, and scoped

This lab is shared; leaving the stack up holds 2 GPUs and 2 rails against other
tenants. Tear down in reverse order and verify.

```bash
kill "$(cat /run/kvstack/disagg-proxy.pid)"     # smc2 only; no stop script exists
./scripts/<role>/99-stop.sh                      # NOT --clean-shm (see below)
./scripts/common/container.sh down <role>
```

- **Do not pass `--clean-shm`** on these nodes. It runs
  `rm -f /dev/shm/lmcache_* /dev/shm/nixl_*`, a host-wide glob that deletes a
  co-tenant's segments. Remove our own segments by name if they must go.
- **Do not pass `--release-hugepages`** anywhere — host-wide.
- Verify GPU 0 and 1 are released and **GPU 2–7 are in whatever state you found
  them**. Releasing a neighbour's GPU is a failure, not a cleanup.
- Nothing reverts the host-wide mutations `01-host-prep.sh` makes (hugepages,
  `/etc/security/limits.d/99-kvstack.conf`, `/etc/sysctl.d/99-kvstack-tcp.conf`,
  firewall rules). Prefer not to re-run it when the host is already prepared.
