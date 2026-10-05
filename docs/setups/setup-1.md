# setup-1 — all-in-one vLLM + SPDK (the real-DSC MI210 pair)

**Not part of the P+D disaggregated stack this repo otherwise documents.**
setup-1 is a single compute node running vLLM `kv_both` (prefill AND decode in
one process — no disaggregation) against a key-addressed NVMe-KV storage tier,
plus an independent SPDK NVMe-KV target. The scripts live entirely under
[`../../setup-1/`](../../setup-1/) — a standalone extraction of `ROCm/rocm-aic`
plus two out-of-tree NIXL storage plugins (`setup-1/plugins/`) and a patch
series (`setup-1/patches/`). **Nothing under `setup-1/` is wired into
`scripts/`, `config/cluster.env`, or `creds/active.env`** — it has its own
`build.sh` / `deploy.sh` / `target.sh`, by design (AGENTS.md's per-setup rule
does not apply the same way here: this is a different codebase, not a
`config/cluster.env` variant). Start with `setup-1/README.md` for the full
architecture writeup (backends, modes, patch rationale, walkthroughs); this
file carries only the host-specific facts.

Values live in the gitignored `creds/setup-1.env`; this file contains no
secrets.

| Role | Host | Address | Notes |
|---|---|---|---|
| compute (`kv_both`) | `yw-dell-gen4-1` | `10.30.48.100` | 1× MI210, **real** Pensando DSC NVMe-KV function |
| target | `yw-dell-gen4-2` | `10.30.48.88` | see §2 — corrected from an earlier "Genoa, CPU-only" record |

Both: `root` / host password over SSH (password auth only; no key accepted —
see `creds/setup-1.env`, not tracked). BMCs: `.100` → `10.30.48.63`,
`.88`(target) → `10.30.48.64` (creds not captured for either). DSC card
consoles (out-of-band, via a shared telnet jump): `.100`'s card →
`telnet 10.30.15.122 2031`/`2032`; target's card →
`telnet 10.30.15.122 2034`/`2035`.

---

## 1. Compute node — `10.30.48.100` (`yw-dell-gen4-1`)

Measured 2026-10-04:

| | |
|---|---|
| GPU | 1× MI210 (`gfx90a`) — `ROCM_ARCH=gfx90a` for `setup-1/build.sh` |
| Docker | 29.6.1 |
| Real NVMe-KV function | **present and live**: `nvme-subsys0`, NQN `nqn.2019-08.com.pensando:nvm-subsystem-sn-8001-0-0`, `nvme0` at PCIe `0000:1c:00.0`, exposed as `/dev/ng0n1` (confirmed via `nvme list` — `Model: PDSNVME`). This is the `BACKEND=xnvme` device for an **everything-local** deploy; no network/target host required for it at all |
| DSC Ethernet ports | `enp25s0np0` (`0000:19:00.0`), `enp26s0np0` (`0000:1a:00.0`) — both **admin-down by default**; bringing either up gets `Link detected: yes` within ~2s, but **neither reaches the target node's DSC port at L2** (see §3) |

## 2. Target node — `10.30.48.88` (corrected from the original "`10.30.51.59`,
Genoa, CPU-only, unreachable" record — that address was stale; see AGENTS.md's
rule that a negative reachability result is evidence about an address, never a
host)

Measured 2026-10-04 — **this record corrects assumptions made before first
contact; do not trust the "Genoa, CPU-only" label**:

| | |
|---|---|
| Hostname | `yw-dell-gen4-2` (a twin of the compute node, not a Genoa box) |
| CPU | Intel Xeon Gold 6330, 112 threads |
| GPU | **has one**: AMD "Aldebaran" (`gfx90a`/MI210-family) at PCI `cc:00.0` — `amdgpu` driver **not currently loaded** (`rocm-smi` reports "Driver not initialized"). Not CPU-only; just not using its GPU right now |
| Pensando DSC card | present (`17:00.0`/`18:0x.0`/`19:00.0`/`1a:00.0`/`1b:00.0`, matches `.100`'s bridge/port layout) but **exposes no NVMe-class `[0108]` function today** — unlike `.100`, there is nothing here for `BACKEND=xnvme` to attach to locally |
| Local storage | a plain Samsung NVMe SSD at `b1:00.0` (`/dev/nvme0`-class) — not Pensando, not a KV device |
| **An SPDK `nvmf_tgt` is already running** | `/root/kv_spdk/build/bin/nvmf_tgt -m 0x3ffe`, PID **not from this session** (CPU-time at discovery implies running since ~Oct 1). RPC sock `/var/tmp/spdk.sock`. Serves NQN `nqn.2016-06.io.spdk:cnode1`, one `KVMalloc` (RAM-backed) namespace, **TCP listener on `1.1.0.2:4420` only** |
| Load average pinned at 13.00 | this is SPDK's busy-polled reactor cores, not a real load problem |

**Ownership of the running `nvmf_tgt` is unconfirmed.** It matches this
project's own `kv_spdk`/`target.sh` layout closely enough that it is plausibly
leftover from earlier work on this same host, but that was not verified before
this record was written, and an attempt to add a second listener address to it
was (correctly) blocked pending confirmation. **Do not reconfigure, restart, or
kill it without first confirming who owns it** — the usual "never kill once a
KV namespace may be live" hazard applies regardless of whose it is.

## 3. The DSC fabric between `.100` and `.88` does NOT reach the target's `1.1.0.2`

Measured 2026-10-04: `.88`'s DSC port `enp25s0` (`ionic`, `0000:19:00.0`) holds
`1.1.0.2/24`, `UP`, `LOWER_UP`. `.100`'s two DSC ports (`enp25s0np0`
`0000:19:00.0`, `enp26s0np0` `0000:1a:00.0`) both come up fine administratively
(`Link detected: yes`) but an address in `1.1.0.0/24` assigned to **either**
one gets `Destination Host Unreachable` pinging `1.1.0.2` — no ARP reply on
either port. **These two hosts are not wired back-to-back on their DSC fabric
ports** (or not on this subnet/VLAN), the same failure shape
`docs/../attic/kv-cache-ng/docs/05-LAB-SETUPS.md` §2 documents for a different
pair of hosts in this lab. Test IP additions from this session were removed
again (`ip addr del`) — the interfaces were left administratively `up` (link
state detected, address removed; harmless, trivially reversible with `ip link
set <if> down`).

**What IS confirmed reachable:** both hosts' management NICs, same `/24`
(`.100` and `.88` both `10.30.48.0/24` on `eth0`). The target's `nvmf_tgt`
would need a second listener bound to `10.30.48.88:4420` (or the existing one
re-pointed) to be reachable from `.100` over that path — not yet done; see §4.

## 4. Open items before a real two-host launch

1. **Confirm ownership of `.88`'s running `nvmf_tgt`** before touching it at
   all (RPC listener add, restart, or kill).
2. If it's ours: add a `10.30.48.88:4420` TCP listener via
   `nvmf_subsystem_add_listener` (non-disruptive, additive — does not touch the
   existing namespace or the `1.1.0.2` listener), then from `.100`:
   `nvme connect -t tcp -a 10.30.48.88 -s 4420 -n nqn.2016-06.io.spdk:cnode1`
   — expect a **new** char device (`/dev/ng1n1`, since `/dev/ng0n1` is already
   `.100`'s own local DSC function) and use that as `AIC_XNVME_DEV` for
   `setup-1/deploy.sh BACKEND=xnvme`.
3. If it's not ours, or you'd rather not depend on `.88` at all: `.100` is
   fully capable of an **all-in-one, single-host** deploy on its own —
   `setup-1/target.sh` (loopback SPDK target) + `setup-1/deploy.sh
   BACKEND=spdk MODE=mp` is the combination `setup-1/README.md`'s Status table
   marks **verified end-to-end**, or `setup-1/deploy.sh BACKEND=xnvme
   AIC_XNVME_DEV=/dev/ng0n1` drives `.100`'s own real DSC function directly,
   no second host involved at all.
4. Neither host has `setup-1/build.sh` run on it yet — no `rocm-aic:latest`
   image exists on either. First build needs internet egress (clones
   `ROCm/rocm-aic` fresh) and is the long pole before any deploy.
