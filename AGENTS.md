# AGENTS.md — project rules for the kv-cache stack

Canonical, vendor-neutral rules file for this repo. Tool permissions live in
`opencode.json`; this file carries the rules a permission list cannot express.

Per-setup rules live in `docs/setups/setup-<N>.md`. **Read the one matching
`creds/active.env` before touching any host.** Today that is
[`docs/setups/setup-4.md`](docs/setups/setup-4.md).

Do not fork the existing invariant lists. They remain authoritative:

- `docs/HANDOFF.md` §4 — the 11 numbered invariants
- `docs/HANDOFF.md` §5 — traps that have actually bitten
- `docs/BRINGUP.md` §1 — conventions, and §7 — known-issue register

---

## 1. The hardware is SHARED. This is the rule that generates the others.

Every compute node in this project is co-tenanted with other parties, and the
hardware has been reconfigured out from under this project more than once
(`docs/HANDOFF.md` §3.5). Two consequences, both non-negotiable:

**1.1 — Survey before you touch.** Run the co-tenancy check (`docs/BRINGUP.md`
§1.0) before any bring-up: listening ports, `docker ps`, `rdma resource show qp`,
and GPU residency. A neighbour's vLLM appears under `comm VLLM::EngineCor` on the
very device your creds pin — check the owning pid's cgroup before concluding a
resource is yours.

**1.2 — Take only your allocation, and name it.** Never let a default decide how
much hardware you claim. The per-setup rules file states exactly which GPUs and
which RDMA devices this project may use. Anything outside that allocation is
another tenant's, whether or not it looks idle.

> `rocm-smi` reporting a GPU as visible does **not** mean it is free.
> `scripts/{prefill,decode}/01-host-prep.sh` gates on GPUs *visible*, not *free* —
> a co-tenant already holding GPU 0 passes that gate cleanly.

## 2. Never run a host-wide destructive operation on a shared box

These are all reachable from existing scripts. Each one hits every tenant, not
just us. Do not run them without an explicit, stated reason:

| Operation | Where it hides | Blast radius |
|---|---|---|
| `rm -f /dev/shm/lmcache_* /dev/shm/nixl_*` | `99-stop.sh --clean-shm`, `stop-lmcache-daemon.sh` | Deletes a co-tenant's segments |
| `echo 0 > /proc/sys/vm/nr_hugepages` | `target/99-stop.sh --release-hugepages` | Zeroes every tenant's hugepage pool |
| `echo <N> > /proc/sys/vm/nr_hugepages` | `01-host-prep.sh` | Host-wide 16 GiB reservation |
| `pkill -f <pattern>` | ad-hoc debugging | Kills by name across all tenants |
| `docker rm -f` outside `kvstack-*` | ad-hoc | Destroys a foreign container |
| restarting a foreign `nvmf_tgt` | `target/5*-reset-*.sh` | Serves another party's data |
| `60-verify-l2-crossnode.sh` | rung 60 | Recreates containers on **both** nodes over ssh |
| `nicctl update card profile` with no `--bdf` | AI NIC flash | Reflashes **all 8** NICs, including co-tenants' |
| `nicctl reset card --all` | AI NIC flash | Decommissions every NIC on the box |

### 2.1 Firmware flashing is the most destructive thing in this repo

`patch-ainic-firmware-400g.py` prints instructions that flash **all 8 cards**
and finish with `nicctl reset card --all`. **Do not paste them.** Every
`nicctl` subcommand used here (`update card profile`, `update port breakout`,
`reset card`) accepts `--bdf <bdf1,bdf2>` — always scope to the cards in your
allocation, named explicitly.

Before flashing any card, prove it is unused: no QPs in `rdma resource show qp`,
no traffic on its netdev, and no co-tenant process bound to it. Reflashing a
port drops the co-tenant's traffic on that port as well as ours.

Note `nicctl`/`eth_dbgtool` take the **card** BDF (e.g. `0000:06:00.0`), which is
a PCI *ancestor* of the netdev function (`0000:08:00.3`). Passing the netdev BDF
is rejected — but passing the *wrong card's* BDF is not.

**Scope every kill and every removal by PID file or exact container name.** Use
`stop_bg` (PID-file + process-group scoped), never `pkill`. Use
`docker rm -f kvstack-<role>`, never a pattern.

## 3. Clean up what you start, and only what you start

A bring-up on shared hardware is not finished when it serves traffic; it is
finished when the box is returned to the state you found it in.

- Tear down in reverse order: proxy → vLLM → LMCache daemon → container.
- Confirm afterwards that the resources you released are actually free, and that
  every resource you never owned is **still in use by its owner** — releasing
  someone else's GPU is a failure, not a cleanup.
- `pkill -f lmcache...http_server` does **not** kill the MP daemon (measured).
  A surviving daemon silently invalidates every later cold-read test.
- **Delete staged build/firmware artifacts when you are done with them.** A
  firmware bundle is ~350 MB and the nodes' root filesystems are shared. Stage
  under a named scratch dir, and remove it in the same session that created it —
  by explicit path, never a glob.
- Zombie PIDs defeat `stop-lmcache-daemon.sh`: container PID 1 is `sleep infinity`
  and never reaps, so `kill -0` succeeds against a defunct pid and the daemon
  reports "already running — not restarting" when it is dead
  (`docs/BRINGUP.md` §7 item 20). Verify death; do not trust the message.

## 4. Measure, don't trust the recorded state

Device names, routes and namespaces in this repo have all gone stale at least
once — a reboot renamed every RDMA device from `ionic_N` to `roce_benicNp1` and
silently broke a pin that had been correct for weeks.

- Re-derive RDMA device names from `/sys/class/infiniband/*` at bring-up.
- Re-derive the KV device by NQN (`resolve_xnvme_kv_dev`), never a literal path.
- When a measurement contradicts a comment in this repo, **the measurement wins** —
  fix the comment in the same change, and say what you measured.
- A correct completion proves nothing (`docs/HANDOFF.md` §5). Verify the path you
  claim to have exercised was the path actually taken.

## 5. Preconditions — verify these before a bring-up, not after it fails

Each of these has cost hours by failing late and misattributed. Check them first.

| Precondition | How | Enforced by |
|---|---|---|
| RDMA device names are current | `/sys/class/infiniband/*` | — (re-derive by hand) |
| **AI NIC firmware personality is `pulsar`, not `hydra`** | `eth_dbgtool --bdf <card> -V` | `require_rdma_fw_program()` |
| Every pinned device in the list exists | `ibv_devinfo` | `require_rdma_access()` |
| KV device is the KV namespace, not the boot drive | `nvme ns-descs` → `csi: 0x1` | `assert_kv_char_device()` |
| GPUs in our allocation are actually free | GPU residency, owning pid's cgroup | — (manual) |

**The firmware one is the trap.** A `hydra` card cannot create a UD queue pair,
so UCX fails to build a worker and vLLM dies ~2 minutes later as "Engine core
initialization failed" — naming neither the NIC nor the firmware. `fw_ver`,
`ethtool -i`, `devlink asic.id` and `fw.soc_zephyr` are **identical** on hydra
and pulsar cards; `eth_dbgtool`'s `p4_program` is the only discriminator. Note
it takes the **card** BDF, which is a PCI ancestor of the netdev function.

Flashing firmware is destructive on shared hardware — it drops the co-tenant's
traffic on that port too. Flash only cards proven unused.

## 6. Bring-up order is load-bearing

- `container.sh up` does **not** run `container.sh shim`, but `start-vllm.sh` and
  `start-lmcache-daemon.sh` both require it. Run `shim` first. It is a mandatory,
  non-automatic prerequisite that neither the README nor BRINGUP §2 lists.
- The verify ladder's rung order **and run-from host** are both load-bearing
  (`docs/BRINGUP.md`:521-529). Rung 50 from the control host is a false FAIL.
- The `MultiConnector` child order in `gen-kv-transfer-config.sh` is fixed. Do not
  reorder it.

## 6. Secrets

`creds/` is gitignored and carries root passwords for every node. `deploy.sh`
pushes it **by default** — use `--no-creds` unless the remote genuinely needs it.
Never move a credential value into a tracked file; tracked files get the *shape*
and the *reasoning*, `creds/setup-N.env` gets the values.
