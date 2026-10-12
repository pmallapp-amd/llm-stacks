# CLAUDE.md — Claude-specific configuration for this repo

**The project rules live in [`AGENTS.md`](AGENTS.md), and they are canonical.**
Read it before touching any host. Do not fork or restate its rules here — this
file carries only what is specific to running Claude against this repo.

The hardware is shared and has been reconfigured out from under this project
more than once. `AGENTS.md` §1 and §2 are not advisory.

---

## Model roles

| role | model | used for |
|---|---|---|
| **Orchestrator** | **Opus 5** | The main session. Plans, decides, touches shared hardware, and owns every destructive or irreversible step. |
| **Subagent** | **Sonnet 5** | Delegated work: measurement sweeps, log mining, code and doc reading, bounded investigations that report findings back. |

Spawn subagents with the model set explicitly:

```
Agent(subagent_type="general-purpose", model="sonnet", ...)
```

The orchestrator stays on Opus because the judgement calls in this project are
the expensive part — co-tenancy, teardown order, and deciding whether a
measurement actually proves what it appears to prove.

### What a subagent must not do

Subagents inherit the shared-hardware rules and are further restricted. A
subagent may **not**, without the orchestrator doing it:

- reboot, power-cycle, or reload a kernel module on any node
- flash NIC firmware, or run any `nicctl` subcommand without an explicit `--bdf`
- `rm -rf` outside a named scratch directory, or `docker rm -f` any container
- stop or restart prefill, decode, the daemon, or the proxy
- change `creds/`, netplan, GRUB, or any apt/DKMS state
- run anything host-wide destructive: `pkill`, `--clean-shm`,
  `--release-hugepages`, `nr_hugepages`

Measuring, reading, scraping counters and running the existing benchmark
scripts are all fine. When a subagent needs one of the above, it reports back
and the orchestrator does it.

### Reporting contract

A subagent's final text is its return value. It should report what it
**measured**, separated from what it **inferred**, and say plainly when a
number is missing or a method was unavailable — a confident wrong number costs
more here than a gap. When a measurement contradicts a comment in this repo,
the measurement wins; say what you measured.

---

## Orientation

- Procedure: [`docs/BRINGUP.md`](docs/BRINGUP.md) — numbered steps, nothing else
- Failures: [`docs/KNOWN-ISSUES.md`](docs/KNOWN-ISSUES.md) — 24 numbered entries
- This lab's identity and allocation: [`docs/setups/setup-4.md`](docs/setups/setup-4.md)
- Per-node sanity: `scripts/{prefill,decode}/verify/run-all.sh`
- Cross-node data path: `scripts/verify/` rungs 10–60

The source of truth on every node is `/root/pmallapp/kv-stack`. Reach the nodes
with `kv_ssh <prefill|decode|target>` after sourcing `scripts/common/lib.sh`.
