# Bring-up procedure

This is the exhaustive, sequenced operational procedure for standing up the
P/D-disaggregated KV cache cluster from bare nodes. Read
[`../README.md`](../README.md) first for topology/architecture context, and
[`ARCHITECTURE.md`](ARCHITECTURE.md) for *why* each layer exists. When a step
fails, this document points at the relevant section of
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

Every command block below is labeled with the node it runs on. `[SMC1]` =
prefill (`${PREFILL_HOST}`), `[SMC2]` = decode (`${DECODE_HOST}`), `[SMC3]` =
target (`${TARGET_HOST}`), `[any]` = any node or a jump host with network
reach. These variables come from `creds/active.env` — see the README's
"Credentials / lab setup" section.

## §0 Prerequisites

Gather before starting — nothing below can complete without these:

- **A creds file.** §1's `source creds/active.env` and every
  `${PREFILL_HOST}`-style reference below only work once one exists. Create
  it now, before doing anything else:

  ```bash
  scripts/common/init-creds.sh <N>
  ```

  See the README's "Credentials / lab setup" section for the full
  mechanism (multi-lab, `--show`, `CREDS_FILE`).
- **No fork to gather.** SMC3's target-side SPDK tree needs
  `bdev_kvmalloc` and the nvmf KV opcode routing, which are not yet
  upstream — but this repo carries them as `patches/spdk/0002-*.patch` /
  `0003-*.patch`, applied automatically by `scripts/target/02-build-spdk-kv.sh`
  on top of a stock clone of `SPDK_UPSTREAM_REPO`@`SPDK_TARGET_REF`. There is
  no `KV_SPDK_REPO`/`SPDK_TARGET_FLAVOR` variable to set and nothing to
  vendor ahead of time — see §3.2 below and `patches/spdk/README.md` for the
  per-patch Gerrit status. SMC1/SMC2 build their own stock upstream SPDK
  tree the same way, via `scripts/common/05-build-spdk-initiator.sh` (§5.1)
  — the NVMe-KV *initiator* API has been upstream since v26.05.
- **The KV storage backend.** `KV_BACKEND` (`config/cluster.env`) defaults
  to `XNVME_KV` — a kernel NVMe-oF/TCP session (`nvme connect`, §4.5 below)
  plus `libxnvme`'s `io_uring_cmd` passthru against the resulting KV
  namespace char device. `SPDK_NVMe_KV` (the userspace SPDK initiator) is
  kept fully wired as an alternative (`KV_BACKEND=SPDK_NVMe_KV`) but is no
  longer the default. Both plugins are built unconditionally by
  `scripts/common/10-build-stack.sh` regardless of which one you select —
  see §5.2.
- **`HF_TOKEN`** — a HuggingFace token; the default `MODEL`,
  `Qwen/Qwen2.5-72B-Instruct`, is gated.
- **Model choice** — confirm `MODEL`/`TP_SIZE`/`GPU_MEM_UTIL`/`MAX_MODEL_LEN`
  in `config/cluster.env` fit the 8x MI300X shard you intend to run; the
  defaults target `Qwen/Qwen2.5-72B-Instruct` at `TP_SIZE=8`
  (`MAX_MODEL_LEN=32768`, its native context — 131072 needs a YaRN
  `rope_scaling` override plus materially more KV per sequence, done
  deliberately via `VLLM_EXTRA_ARGS`, not by raising `MAX_MODEL_LEN` alone).
  **Pre-stage the download**: bf16 weights are ~145 GB, and `HF_HOME`'s
  preflight check (§2 below) only advises >= 100 GiB free, which is now
  short of what this default actually needs — download the model to
  `HF_HOME` ahead of time rather than discovering the wait (or running out
  of disk) during `scripts/prefill/03-start-prefill.sh`.
- **Network plan** — which physical interface on each node carries the
  storage leg (→ SMC3) and which carries the compute leg (SMC1↔SMC2). §2/§4
  below auto-detect and print both; you pin them into `PREFILL_DATA_IF`/
  `DECODE_DATA_IF` once known (unpinned falls back to UCX's own
  autodetection at every vLLM start, which is not guaranteed stable across a
  network hiccup — see `start-vllm.sh`'s comment).
- SSH access to all three nodes (see `creds/active.env` — `SSH_USER`, and
  the README's "Credentials / lab setup" section) and, ideally, working
  serial console access as a fallback (see §1).

## §1 Access check

`[any]` — confirm you can reach every node before touching anything.

```bash
# any node with reach to the lab
source creds/active.env

# SSH — from your jump host / laptop
ssh "${SSH_USER}@${PREFILL_HOST}" hostname   # SMC1, expect: ${PREFILL_NAME}
ssh "${SSH_USER}@${DECODE_HOST}" hostname    # SMC2, expect: ${DECODE_NAME}
ssh "${SSH_USER}@${TARGET_HOST}" hostname    # SMC3, expect: ${TARGET_NAME}
```

BMC reachability (out-of-band; used for power actions or when SSH is down):

```bash
# ping is sufficient to confirm the BMC network path is up; full BMC login
# (Redfish/IPMI/web) needs PREFILL_BMC_USER/PREFILL_BMC_PASS (and the
# DECODE_*/TARGET_* equivalents) from creds/active.env.
ping -c2 "${PREFILL_BMC}"    # SMC1 BMC
ping -c2 "${DECODE_BMC}"     # SMC2 BMC
ping -c2 "${TARGET_BMC}"     # SMC3 BMC
```

Serial console access (fallback when SSH is unavailable):

```bash
${PREFILL_CONSOLE}       # SMC1, port A
${PREFILL_CONSOLE_ALT}   # SMC1, port B
${DECODE_CONSOLE}        # SMC2, port A
${DECODE_CONSOLE_ALT}    # SMC2, port B
${TARGET_CONSOLE}        # SMC3, Pollara port A — KNOWN UNRESOLVED: connection
                         # was REFUSED the last time this was tried. Do not
                         # rely on this path being available; use SMC3's
                         # BMC (${TARGET_BMC}) instead until this is
                         # re-investigated. See README gap #5.
${TARGET_CONSOLE_ALT}    # SMC3, Pollara port B — same caveat
```

If any SSH path is down, use the console for that node; if the console is
also down (as currently expected for SMC3), use the BMC's own
KVM/console-redirect feature instead of the raw telnet port.

## §2 Preflight on all three nodes

`[SMC1]` `[SMC2]` `[SMC3]` — run the same command on all three; it is
read-only and safe to run before anything else exists.

```bash
scripts/common/00-preflight.sh
```

This never installs, mutates, or starts anything (see its own header
comment) — it is pure inventory plus advisory/hard checks. What "good"
looks like:

| Check | Good | If it's not |
|---|---|---|
| Kernel is 64-bit, `uname -r` >= 5.x | `ok`/informational | Not a hard blocker at this stage but worth fixing before continuing |
| RAM >= 32 GiB | `ok` | Hard failure — see the script's output for actual `MemTotal` |
| Hugepages | `warn` "not configured yet" is fine here — `01-host-prep.sh` allocates them | A `warn` about being **short** after `01-host-prep.sh` has already run means fragmentation; reboot (see §4/§3 below) |
| ROCm/GPU | On SMC1/SMC2: `rocm-smi` reports >= `TP_SIZE` GPUs, `rocminfo` shows `gfx942`. On SMC3: no GPU is **expected and informational**, never a failure. | Fewer GPUs than `TP_SIZE`, or wrong `gfx` target — fix before `01-host-prep.sh`, which hard-fails on this |
| PCIe inventory (`lspci -d 1dd8:`) | SMC1/SMC2: 8x `[1dd8:5303]` (GPUs) + 2x `[1dd8:5200]` (DSC3-2Q400). SMC3: 2x `[1dd8:1002]` (POLLARA-1Q400) at `64:00.0`/`84:00.0`. | Missing devices — check physical seating/BIOS enablement before continuing |
| Disk space | >= 50 GiB free for `STACK_ROOT`, `check_soft` >= 100 GiB for `HF_HOME` | Hard fail on the first, warn on the second |
| Cluster reachability | `ping` to the other two nodes succeeds; service ports are `check_soft` (fine to fail — nothing is started yet) | Ping failure is a hard fail — fix networking before proceeding |

If this script's `checks_summary` reports failures, resolve them before
continuing — every later script assumes this layer is clean, same philosophy
as the `scripts/verify/` ladder (§8).

## §3 SMC3 target bring-up

`[SMC3]` — host prep, build the target-side SPDK fork, start the target,
verify. This is the one node still built from the kv_spdk fork rather than
stock upstream SPDK — see §3.2 and
[`ARCHITECTURE.md` §7](ARCHITECTURE.md#7-spdk-upstream-initiator-forked-target)
for why.

### §3.1 Host prep

```bash
scripts/target/01-host-prep.sh
```

Installs apt deps for building kv_spdk; allocates hugepages **only if**
`TARGET_HUGE_PAGES > 0` (default: `0` — `nvmf_tgt` runs `--no-huge`,
malloc-backed DPDK EAL memory, matching `rocm-aic/target.sh`'s proven
configuration exactly, so the default here allocates **none**; do not
confuse this with `HUGEPAGE_COUNT`, which is the SMC1/SMC2 initiator-side
variable used in §4, not this node's); loads `nvme_tcp nvme_fabrics vfio_pci
uio_pci_generic`, runs `scripts/common/tune-tcp.sh`, inventories the two
POLLARA-1Q400 NICs and RDMA device presence, opens `NVMF_TRSVCID` (4420) in
whatever firewall is actually active (or says explicitly that neither
`ufw`/`firewalld` is active), sets unlimited `memlock`, and creates
`STACK_ROOT`/`LOG_DIR`/`RUN_DIR`.

Expected output: a `Summary` step reporting
`hugepages: <N>/<TARGET_HUGE_PAGES>` (`0/0` in the default configuration —
that is correct, not a failure), the storage-leg interfaces toward SMC1 and
SMC2, and `KV_TRANSPORT=tcp NVMF_TRSVCID=4420`. If you've set
`TARGET_HUGE_PAGES>0` and it reports short by more than 10%, **reboot this
host before continuing** (the script prints this warning itself) — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#hugepage-allocation-short-of-requested).

The memlock limits file it writes only takes effect in a **new** login
session — if you plan to run `03-start-kv-target.sh` in the same shell,
start a fresh shell/session first.

### §3.2 Build the target-side SPDK tree (upstream + the two open KV patches)

```bash
scripts/target/02-build-spdk-kv.sh
```

**There is no fork.** This clones stock `${SPDK_UPSTREAM_REPO}`@`${SPDK_TARGET_REF}`
(default `master`) into `${SPDK_TARGET_SRC}` — full history, not shallow,
since `SPDK_TARGET_REF` may be an arbitrary SHA — then `git submodule update
--init --recursive`, then applies `patches/spdk/000{1,2,3,4}-*.patch` from
`${SPDK_PATCH_DIR}` with `git am`. These are upstream-**bound** NVIDIA
patches on a public Gerrit queue (`https://review.spdk.io/q/topic:kv`), not
a private tree — see `config/cluster.env`'s SPDK section and
`patches/spdk/README.md` for per-patch status:

| Patch | Status |
|---|---|
| 0001 nvme: recognize KV namespaces | merged upstream 2026-08-25 |
| 0002 bdev/kvmalloc | **open** — this is the one that actually matters |
| 0003 nvmf: KV namespace support | **open**, depends on 0002 |
| 0004 nvme: KV unit tests | merged upstream 2026-08-25 |

The script detects 0001/0004 as already-present **by content** (not by
assuming based on `SPDK_TARGET_REF`) and skips them cleanly — applying an
already-merged patch would fail `git am` outright. 0002/0003 are the ones
that must actually apply for this build to produce a KV-capable target.

Then `./configure --with-nvmf --without-shared --disable-tests
--disable-unit-tests --disable-examples && make`. There is no `--with-rdma`
here (or anywhere in this repo's SPDK builds any more) — the storage leg is
NVMe-oF/**TCP only**, unconditionally, by design; see the README's Status
table and `config/cluster.env`'s `KV_TRANSPORT` comment. `--without-shared`
matters: it's what prevents DPDK's vendored build from emitting both
`librteX.a` and `librteX.so` side by side, which is the root cause behind
the plugin's silent-dlopen-failure class of bug (see `TROUBLESHOOTING.md`).

Expected output: a `Verifying build artifacts` step confirming
`libspdk_nvme.a`, `libspdk_bdev_kvmalloc.a` (its **absence** means patch 0002
did not apply — re-run with `--force-clone` or check
`${SPDK_PATCH_DIR}/0002-*.patch` applies cleanly to `SPDK_TARGET_REF`
by hand), `libspdk_sock_posix.a`, `nvmf_tgt` (**not** `spdk_tgt` — that is
not the binary a `--with-nvmf` build produces), `include/spdk/nvme_kv.h`,
`isa-l/.libs/libisal.a`, and `dpdk/build/lib/librte_eal.a` all present, then
`Generating split archives (prepare-spdk-libs.sh)` — only useful if
`SPDK_INITIATOR_FLAVOR=fork` ever reuses this exact tree on SMC1/SMC2 (see
the note after §3.4); a no-op otherwise. Finally reports the built SPDK
version.

If this fails: see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#stock-upstream-spdk-on-the-target-bdev_kvmalloc_create-rpc-not-found)
and the script's own error text.

### §3.3 Start the target

```bash
scripts/target/03-start-kv-target.sh
```

Runs `kv_target_check_sgl` first (the `NVMF_MAX_IO_SIZE`/`NVMF_LARGE_BUFSIZE`
÷ 16 arithmetic — note the denominator is `NVMF_LARGE_BUFSIZE`, the iobuf
pool's large-buffer size, **not** `NVMF_IO_UNIT_SIZE`, which no longer
governs the SGL ceiling) **before** touching the process at all, so a bad
ratio fails immediately with the arithmetic shown rather than after
`nvmf_tgt` is already up, then `kv_target_sanity_check_traddr` (warns if
`NVMF_TRADDR` isn't actually a local address on this host — a listener bound
to an address nothing can reach otherwise surfaces as a connection timeout
on SMC1/SMC2, nowhere near this script).

Generates `${STACK_ROOT}/etc/kv-target.json` — the **single source of
truth** for this launch, applied by `nvmf_tgt --json` atomically at process
start (transport, `bdev_kvmalloc`, subsystem, namespace, and listener all in
one file, regenerated deterministically from `config/cluster.env` on every
start including a `--restart`). There is no separate `rpc.py` sequence to
run or to drift out of step with `scripts/target/50-reset-namespace.sh`
any more — `rpc.py` is used only for read-only inspection, in
`scripts/target/04-verify-target.sh`. Starts `nvmf_tgt` (binary name
`nvmf_tgt`, **not** `spdk_tgt`) under `start_bg` (detached, PID-tracked,
logged to `${LOG_DIR}/kv-target.log`), waits for the RPC socket
(`${SPDK_RPC_SOCK}`, default `/var/tmp/spdk.sock`), then confirms
`spdk_get_version` responds.

Flags: `--foreground` (runs `nvmf_tgt` attached to this shell, `--json`
config still applied atomically at startup — there is no separate RPC step
to run from a second shell any more), `--restart` (stop first if already
running, then regenerate and re-apply the JSON against a fresh process).

Expected output ends with:

```
ok  kv-target up
    TRID for initiators: trtype:TCP adrfam:IPv4 traddr:${TARGET_HOST} trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0
    verify from this host: scripts/target/04-verify-target.sh
    verify from SMC1/SMC2: nvme discover -t tcp -a ${TARGET_HOST} -s 4420
```

If it fails: the most common cause is the `max_io_qpairs_per_ctrlr`/SGL
arithmetic — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#sgl-length-exceeds-max-io-size).
If `nvmf_tgt` doesn't create the RPC socket at all within 60s, check
`${LOG_DIR}/kv-target.log` for a `bdev_kvmalloc_create` rejection (patch
0002 from §3.2 not actually applied) or a hugepage/memlock failure (§3.1).

### §3.4 Verify the target

```bash
scripts/target/04-verify-target.sh
```

Hard checks: `kv-target` process running, RPC responds
(`spdk_get_version`), subsystem present with exactly 1 namespace, transport
reports the configured `max_io_size`/`max_io_qpairs_per_ctrlr` (**the single
most important check in this file** — a wrong RPC key spelling silently
keeps SPDK's default of 127 qpairs, which breaks P/D invisibly the moment
both roles attach), TCP port `NVMF_TRSVCID` listening, and — **only if**
`TARGET_HUGE_PAGES>0` — free hugepages > 0 (skipped entirely, informational,
under the default `TARGET_HUGE_PAGES=0`). Soft check: local `nvme
discover` lists the subnqn (advisory — `nvme-cli` may not be relevant on a
pure target). Ends by printing the exact commands to run from SMC1/SMC2 to
verify remotely (`nvme discover ...` and a one-liner that constructs a
`nixl_agent` and prints `get_plugin_params('SPDK_NVMe_KV')` — substitute
`XNVME_KV` if that's your `KV_BACKEND`).

All hard checks passing is the go/no-go for proceeding to §5.

### Only if `SPDK_INITIATOR_FLAVOR=fork`: rsync the SPDK tree to SMC1/SMC2

**This step does not apply to the default configuration.** As of SPDK
v26.05, `SPDK_INITIATOR_FLAVOR=upstream` (the default) means SMC1/SMC2 build
their own, self-contained, stock upstream SPDK tree in §5 via
`scripts/common/05-build-spdk-initiator.sh` — no dependency on this host's
build at all. Skip straight to §4.

If you deliberately set `SPDK_INITIATOR_FLAVOR=fork` (e.g. to rule out a
version-skew hypothesis by building the initiator from the exact same tree
as the target), `[SMC1]` and `[SMC2]`, run against SMC3 — needed before
§5's `05-build-spdk-initiator.sh` step, because `plugins/nvme-kv/meson.build`'s
`-Dspdk_path` must point at a tree with the **same path** on the building
host as it had wherever it was built (the split archives from
`prepare-spdk-libs.sh` and every header include path are resolved relative
to it):

```bash
# on SMC1
rsync -az "${SSH_USER}@${TARGET_HOST}:/opt/kvstack/src/kv_spdk/" /opt/kvstack/src/spdk/
# on SMC2 — identical command
rsync -az "${SSH_USER}@${TARGET_HOST}:/opt/kvstack/src/kv_spdk/" /opt/kvstack/src/spdk/
```

(Source path shown is the default `SPDK_TARGET_SRC`; destination is the
default `SPDK_SRC` — `05-build-spdk-initiator.sh --force-clone` is not
appropriate here, since `SPDK_INITIATOR_FLAVOR=fork` mode never clones, only
verifies and builds what's already at `SPDK_SRC`. Adjust either path if you
overrode it.)

## §4 SMC1/SMC2 host prep

`[SMC1]`:

```bash
scripts/prefill/01-host-prep.sh
```

`[SMC2]` (identical shape, decode-specific variables):

```bash
scripts/decode/01-host-prep.sh
```

Both: allocate `HUGEPAGE_COUNT` hugepages at `/proc/sys/vm/nr_hugepages`
(note: the target's script writes the per-size sysfs node instead — see its
own comment on why), **hard-fail** if fewer than `TP_SIZE` GPUs are visible
via `rocm-smi` or if `rocminfo` doesn't report `gfx942`, load
`nvme_tcp nvme_fabrics vfio_pci uio_pci_generic`, run
`scripts/common/tune-tcp.sh`, report the storage-leg (→ SMC3) and
compute-leg (↔ the other compute node) interfaces separately (they can
legitimately differ), inventory the DSC3-2Q400 NICs and RDMA device presence
(warns if `KV_TRANSPORT=rdma` but the corresponding `*_RDMA_DEV` isn't set —
see §9), sets unlimited memlock, soft-checks target reachability, and
creates `STACK_ROOT`/`LOG_DIR`/`RUN_DIR`/`HF_HOME`.

Expected output ends with `ok prefill host prep complete` /
`ok decode host prep complete`. A hard failure here (GPU count/arch) must be
fixed before continuing — vLLM's tensor-parallel launch will hang or crash
against a GPU count mismatch, per the script's own message.

If `PREFILL_DATA_IF`/`DECODE_DATA_IF` are unset, the script warns and
explains that `start-vllm.sh` will fall back to UCX's own autodetection —
pin these once you've identified the compute-leg interface from this step's
output (see §0).

## §4.5 Connect to the KV target (`nvme connect`)

`[SMC1]` and `[SMC2]`, identical shape, after §3 (target up) and §4 (this
host's `nvme_tcp`/`nvme_fabrics` kernel modules loaded) — and **before**
anything below that touches `KV_BACKEND`. Nothing in this repo's scripts
issues `nvme connect` for you: `scripts/common/lib.sh`'s
`setup_nixl_kv_env`/`resolve_xnvme_kv_dev` (called by both
`scripts/common/start-lmcache-daemon.sh` and `scripts/common/start-vllm.sh`,
§7 below) require the kernel NVMe-oF/TCP initiator session to SMC3 to
**already exist** — on `KV_BACKEND=XNVME_KV` (the default) they die with an
explicit message telling you to check `nvme list-subsys` if it doesn't.

```bash
# [SMC1]
nvme connect -t "${NVMF_TRTYPE,,}" -a "${NVMF_TRADDR}" -s "${NVMF_TRSVCID}" \
    -n "${NVMF_SUBNQN}" -q "${NVMF_HOSTNQN_PREFILL}"

# [SMC2]
nvme connect -t "${NVMF_TRTYPE,,}" -a "${NVMF_TRADDR}" -s "${NVMF_TRSVCID}" \
    -n "${NVMF_SUBNQN}" -q "${NVMF_HOSTNQN_DECODE}"
```

Confirm the controller attached:

```bash
nvme list-subsys              # expect a controller against ${NVMF_SUBNQN}
```

On `KV_BACKEND=XNVME_KV` (the default), the kernel also creates a generic
character device for the KV namespace (e.g. `/dev/ng1n1`) — **do not** go
hunting for it or hand-pin `XNVME_DEV` to a guessed path.
`scripts/common/lib.sh`'s `resolve_xnvme_kv_dev()` matches the correct
device by `${NVMF_SUBNQN}` at runtime, automatically, the next time
`setup_nixl_kv_env` runs (i.e. when you start the daemon or vLLM in §7);
this step only needs the *session* to exist. **Never** hand-pin
`XNVME_DEV=/dev/ng0n1` on SMC1/SMC2 — that index is the Micron OS boot
drive, not the KV namespace, and `config/cluster.env`'s `XNVME_DEV` comment
explains exactly what happens if a KV backend is pointed at it.

> **This connection does NOT survive a reboot of SMC1/SMC2** — there is no
> `--persistent` flag and no systemd unit wired up for it. Re-run this
> section after every compute-node reboot, before starting the daemon or
> vLLM (§7) — see
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#nvme-connect-does-not-survive-a-reboot)
> and §10's restart procedure below.

## §5 Build the stack on both compute nodes

`[SMC1]` and `[SMC2]`, independently. Two scripts, run in order.

### §5.1 Build the initiator-side SPDK tree

```bash
sudo scripts/common/05-build-spdk-initiator.sh
```

New as of SPDK v26.05. `SPDK_INITIATOR_FLAVOR=upstream` (the default) clones
`SPDK_UPSTREAM_REPO`@`SPDK_VERSION` (default `v26.05`) directly into
`${SPDK_SRC}` and builds it — self-contained, no dependency on SMC3's tree at
all, because the NVMe-KV **initiator** API this plugin needs
(`spdk_nvme_kv_store/retrieve/delete/exist/list()`) is upstream as of this
release (see `docs/ARCHITECTURE.md` §7). `SPDK_INITIATOR_FLAVOR=fork`
instead expects `${SPDK_SRC}` to already be populated by the rsync in the
"Only if `SPDK_INITIATOR_FLAVOR=fork`" note under §3.

Configures `--without-shared --with-uring --disable-tests
--disable-unit-tests --disable-examples` (no `--with-rdma` — the storage
leg is NVMe-oF/TCP only, unconditionally; see §9), builds, then **verifies
the KV API is actually present** — `nm -g "${SPDK_SRC}/build/lib/libspdk_nvme.a"`
for `spdk_nvme_kv_store`/`spdk_nvme_kv_retrieve`/`spdk_nvme_kv_exist`, plus a
grep for `KEY_DOES_NOT_EXIST` in `include/spdk/nvme_spec.h` — and dies with a
clear message (rather than letting a too-old tree fail obscurely at the
plugin's link step, minutes later) if any are missing. Finishes by running
`plugins/nvme-kv/prepare-spdk-libs.sh` to generate the "_only" split
archives §5.2's plugin build needs.

Expected final output:

```
ok  SPDK (initiator, upstream) built at /opt/kvstack/src/spdk
    next: scripts/common/10-build-stack.sh (plugin build, step 4/6, now
    expects this tree to already exist rather than building it itself)
```

If step 4 (verifying the KV API) fails, see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#building-against-pre-v2605-spdk-missing-spdk_nvme_kv_-symbols-at-link-time).

### §5.2 Build UCX + NIXL + both NIXL plugins

```bash
sudo scripts/common/10-build-stack.sh
```

(`sudo`/root required — the script calls `require_root`.) Six numbered
steps, each individually skippable (`--skip-apt`, `--skip-ucx`,
`--skip-nixl`, `--skip-plugins`) and idempotent:

1. **apt deps** — build tooling, `rdma-core`/`libibverbs-dev`/`librdmacm-dev`
   (built now so Phase 2 doesn't need a fresh apt pass later — see §9.3),
   `nvme-cli`, `ethtool`.
2. **UCX** (ROCm fork, `UCX_BRANCH=v1.19.x`) → `${UCX_PREFIX}`. Built
   `--with-verbs --with-dm --with-rdmacm` even though `KV_TRANSPORT` defaults
   to `tcp` — this is deliberate, see the script's own comment: flipping
   `KV_TRANSPORT` to `rdma` later must be a config change, not a rebuild.
   Uses the **ROCm fork**, not stock `openucx/ucx` — stock UCX's memory-type
   detection doesn't recognize HIP pointers (see the script's WHY comment).
3. **NIXL** (`NIXL_VERSION=v1.4.1`) → `${NIXL_PREFIX}`, built against the UCX
   from step 2. Verifies `libnixl.so` and `backend_engine.h` are actually
   present afterward.
4. **`plugins/nvme-kv`** (`SPDK_NVMe_KV`) → installed into
   `${NIXL_PLUGIN_DIR}`. Requires §5.1 to have already produced
   `${SPDK_SRC}/build/lib/libspdk_nvme.a` — this step no longer builds a
   fallback SPDK tree itself; if that file is missing it dies immediately
   with the exact command to run (`scripts/common/05-build-spdk-initiator.sh`).
   There is no RDMA build variant of this plugin any more — the storage leg
   is NVMe-oF/TCP only, unconditionally (see §9 and the README's Status
   table); an earlier `-Denable_rdma` meson option and its
   `libspdk_nvme_rdma_only.a` split archive have been removed entirely.
5. **`plugins/xnvme-kv`** (`XNVME_KV`) → installed into `${NIXL_PLUGIN_DIR}`.
   **Not optional any more**: `XNVME_KV` is `KV_BACKEND`'s default, so a
   missing `libxnvme` headers/lib here is a hard `die`, not a skip —
   install `libxnvme` first (`https://github.com/xnvme/xnvme`) or set
   `XNVME_INCDIR`/`XNVME_LIBDIR` explicitly if it's not on the default
   search path. (Both plugins are always built regardless of which one
   `KV_BACKEND` selects, so `SPDK_NVMe_KV` stays available as the
   alternative — see §0.)
6. **Summary** — lists `${NIXL_PLUGIN_DIR}`'s contents.

**The mandatory `ldd` self-containment check** (step 4, immediately after
building `libplugin_SPDK_NVMe_KV.so`): the script runs `ldd` on the built
plugin and **hard-fails the whole build** if it finds a DT_NEEDED on any
`librte_*.so`/`libspdk_*.so`, or any "not found" entry. This is not
optional and not advisory — see the script's own extended comment on why:
without this check, a stray shared-lib dependency surfaces two layers away,
minutes into a vLLM startup, as NIXL's generic "unsupported backend" error
with zero indication a link problem was the cause.

**What its failure looks like:**

```
FAIL  ldd shows a shared librte_*/libspdk_* dependency — this plugin
      embeds SPDK/DPDK statically and must NOT show these:
        libplugin_SPDK_NVMe_KV.so:
                libnixl.so => /opt/kvstack/nixl/lib/x86_64-linux-gnu/libnixl.so (...)
                librte_eal.so.26 => not found
FAIL  SPDK/DPDK link-time isolation broken; see meson.build's
      --whole-archive comment. Check for a stray librteX.so next to
      librteX.a in .../dpdk/build/lib and rebuild.
```

If you see this, see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#unsupported-backend-from-nixl-with-no-other-error).

Expected clean output:

```
ok  SPDK_NVMe_KV plugin clean: no librte_*/libspdk_* DT_NEEDED, no unresolved libs
ok  10-build-stack.sh complete
    next: scripts/common/20-build-vllm-lmcache.sh
```

## §6 vLLM + LMCache install, patch, config

`[SMC1]` and `[SMC2]`, independently.

### §6.1 Install

```bash
scripts/common/20-build-vllm-lmcache.sh
```

Creates `${VENV}`, installs `torch` from the ROCm wheel index
(`TORCH_INDEX_URL`, default `rocm6.2`) **before** vLLM (so vLLM's own
dependency resolution can't silently pull a CUDA-tagged torch), then pins
`vllm==${VLLM_VERSION}` (default `0.28.0`) and `lmcache==${LMCACHE_VERSION}`
(default `0.5.4`) together — these two versions are pinned as a pair
deliberately: the vLLM `KVConnector` plugin API and LMCache's own connector
implementations of it move independently, and a mismatched pair fails only
at connector-construction time, not at `pip install` time. This cluster
constructs `MultiConnector[NixlConnector, LMCacheMPConnector]` (§7.2 below),
so a version mismatch here now surfaces as a `KeyError` against
`LMCacheMPConnector` (or `MultiConnector` itself failing to resolve one of
its children) deep in `vllm.distributed.kv_transfer.kv_connector.factory`
— **not** `KeyError: 'LMCacheConnectorV1'`, which was this failure's shape
back when this repo ran LMCache's in-process single-connector mode; that
mode is gone (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#keyerror-lmcachempconnector-or-multiconnector)).
Installs `aiohttp` (used by the proxy). Installs the `nixl` → `nixl_rocm` shim package
if needed (the ROCm NIXL build installs its python bindings under
`nixl_rocm`, not the upstream name `nixl` that LMCache imports
unconditionally). Ends by writing `${STACK_ROOT}/etc/env.sh` — the
activation snippet every later script sources — which also bakes in
`PYTORCH_HIP_ALLOC_CONF=expandable_segments:False` (see
`TROUBLESHOOTING.md`'s entry on this).

Expected final output:

```
ok  vLLM + LMCache + NIXL bindings verified importable
ok  wrote /opt/kvstack/etc/env.sh
    next: scripts/common/start-lmcache-daemon.sh
```

### §6.2 Apply the LMCache backend-allowlist patch

```bash
patches/lmcache/apply-patches.sh
```

Stock LMCache's `NixlStorageConfig.validate_nixl_backend()` and
`NixlDynamicStorageAgent.__init__` both hardcode a fixed allowlist of NIXL
backend names that does not include `SPDK_NVMe_KV`/`XNVME_KV` — see
`patches/lmcache/README.md` for the full rationale. This script patches the
**installed** LMCache package in `${VENV}` (not a static `.patch` file — see
that README's "Why this ships as a generator script" section) and writes a
timestamped diff to `patches/lmcache/applied-<version>.diff`.

Flags: `--dry-run` (show what would change, write nothing), `--force`
(required to re-run after a prior successful apply — reverts then
reapplies, never stacks edits), `--revert` (restore from `.orig-kvstack`
backups).

Expected output ends with:

```
ok  patch applied; diff recorded at patches/lmcache/applied-0.5.4.diff
    next: scripts/common/25-validate-lmcache-config.sh <cfg-file>
```

If it reports `FAIL: zero "GDS"/"POSIX"/"OBJ" allowlist-shaped brackets
found` — the installed LMCache version has moved this logic; see
`patches/lmcache/README.md`'s "What is ASSUMED" section and
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#assertionerror-on-the-lmcache-nixl-backend-name).

### §6.3 Validate the LMCache storage-tier config (optional, standalone)

Config validation is normally handled automatically by
`scripts/common/start-lmcache-daemon.sh` (§7.1): it builds a `--l2-adapter`
JSON spec from `config/cluster.env` (`KV_BACKEND`/`XNVME_DEV`/`KV_TRID`) and
validates that spec **before** ever spawning the daemon. To inspect the
same check standalone — e.g. to re-verify after an LMCache upgrade, without
starting anything:

```bash
scripts/common/25-validate-lmcache-config.sh --l2-adapter-json \
  '{"type":"nixl_store","backend":"XNVME_KV","backend_params":{"dev_uri":"/dev/ng1n1"},"pool_size":2000000}'
```

This parses the JSON with the SAME installed
`lmcache.v1.distributed.l2_adapters.config` classes the daemon itself uses
(`get_l2_adapter_config_class()`/`<ConfigClass>.from_dict()`), so a typo'd
key or an unregistered adapter `type` fails here instead of 30s into a
daemon start, and it also confirms `validate_nixl_backend()`/the OBJ
mem_type check both accept `${KV_BACKEND}` (i.e. that §6.2's patch actually
took) by cross-checking against a throwaway `nixl_agent`'s live
`get_plugin_params("${KV_BACKEND}")`.

Expected final line: `PASS: --l2-adapter-json validated against installed
LMCache.` Any `FAIL` above that must be resolved before starting the daemon
— see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#assertionerror-on-the-lmcache-nixl-backend-name).

> **There is no separate LMCache config file for this cluster.** This
> cluster runs `LMCacheMPConnector` (MP mode: LMCache is a separate host
> process, §7.1 below); the KV storage tier is configured entirely by the
> `--l2-adapter <JSON>` spec above, built fresh by `start-lmcache-daemon.sh`
> every time it starts. An earlier, separate config surface — a generated
> YAML with its own `extra_config.{enable_nixl_storage,nixl_backend,
> nixl_backend_params}` block — belonged to the in-process
> `LMCacheConnectorV1` path, which this cluster never runs; that generator
> and its YAML have been removed along with the rest of that path's dead
> config (`docs/TODO.md` §6.23).

## §7 Start prefill, decode, proxy

### §7.1 Start the LMCache MP daemon (SMC1 and SMC2)

LMCache runs in **MP mode**: a separate host process (`lmcache-mp-daemon`)
on each compute node, reached over a ZMQ control channel at
`LMCACHE_MP_HOST:LMCACHE_MP_PORT` (loopback, `tcp://127.0.0.1:6557` by
default — same-host only, by design; see `config/cluster.env`'s
`LMCACHE_MP_HOST` comment). `scripts/prefill/03-start-prefill.sh` and
`scripts/decode/03-start-decode.sh` (§7.2/§7.3 below) both call this
automatically before launching vLLM — it's idempotent, so running it here
by hand first is optional, useful mainly if you want to watch its own log
separately or debug it with `--foreground`:

```bash
# [SMC1] and [SMC2] — identical shape, role auto-detected from this host's
# address (LMCACHE_DAEMON_ROLE=prefill|decode to override)
scripts/common/start-lmcache-daemon.sh
```

Requires `scripts/common/20-build-vllm-lmcache.sh` (§6.1, needs `lmcache`
importable in `${VENV}`) and — since `nvme connect` (§4.5) is what makes
`KV_BACKEND=XNVME_KV`'s device resolvable — that step to have already run.
Resolves this role's KV storage device/TRID (`setup_nixl_kv_env`, same
function `start-vllm.sh` uses), builds a `--l2-adapter` JSON spec of type
`nixl_store` (e.g. `{"type":"nixl_store","backend":"XNVME_KV","backend_params":{"dev_uri":"/dev/ng1n1"},"pool_size":2000000}`
on `KV_BACKEND=XNVME_KV`), validates that spec with
`25-validate-lmcache-config.sh --l2-adapter-json` **before** ever spawning
the daemon, then launches `lmcache.v1.multiprocess.http_server` under
`start_bg` and waits up to 30s for the ZMQ port to open.

Expected output ends with:

```
ok  lmcache-mp-daemon up, ZMQ reachable at 127.0.0.1:6557
```

If it refuses to start, see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#lmcache-mp-daemon-fails-to-start-or-vllm-refuses-to-start-because-it-cant-reach-one).
Coming up cleanly does **not** by itself prove the storage tier actually
works — confirm with a real round-trip
(`scripts/verify/30-verify-kv-roundtrip.sh`, §8) — a bad device path or an
unreachable target still starts this daemon healthy and only shows up as a
failed (or silently-empty) store/load later.

### §7.2 Prefill

`[SMC1]`:

```bash
HF_TOKEN=<token> scripts/prefill/03-start-prefill.sh
```

This is a thin wrapper that pins `require_host "${PREFILL_HOST}" "prefill"`,
calls `scripts/common/start-lmcache-daemon.sh` (§7.1 — idempotent, so this
is a convenience, not the only thing that starts it), then `exec`s
`scripts/common/start-vllm.sh prefill`. That shared script, in order:
sources `${STACK_ROOT}/etc/env.sh`, calls `setup_nixl_kv_env prefill` and
`setup_ucx_env` (from `lib.sh`), **refuses to start unless the LMCache MP
daemon is reachable at
`LMCACHE_MP_HOST:LMCACHE_MP_PORT` within 30s** (a hard gate — see the
script's comment on why a silently-absent LMCache leg, not a failure to
start, is the worst outcome here), **and refuses to start unless SMC3's
NVMe-oF port is also reachable within 30s** (same reasoning, for the
storage leg), then launches `vllm.entrypoints.openai.api_server` with
`--kv-transfer-config`:

```json
{"kv_connector":"MultiConnector","kv_role":"kv_both","kv_connector_extra_config":{"connectors":[
  {"kv_connector":"NixlConnector","kv_role":"kv_producer"},
  {"kv_connector":"LMCacheMPConnector","kv_role":"kv_both","kv_connector_extra_config":{"lmcache.mp.host":"tcp://127.0.0.1","lmcache.mp.port":6557}}
]}}
```

(`"kv_role":"kv_consumer"` on the `NixlConnector` entry for decode instead —
see §7.3.) `NixlConnector` is always `connectors[0]` and this is **not**
configurable: `MultiConnector.get_num_new_matched_tokens()` assigns the
entire load to the first child connector that reports a non-zero match, so
if `LMCacheMPConnector` were listed first, decode's local L2 tier would win
the match ahead of `NixlConnector` ever being asked, and the direct P→D
remote-prefill pull this whole architecture exists to measure would be
silently skipped whenever the L2 tier has anything at all cached — see
`scripts/common/gen-kv-transfer-config.sh`'s header comment. Under
`start_bg`, waits up to 1800s for `/health` to return 2xx.

Expected output ends with:

```
ok  vllm-prefill healthy on port 8100
    test with:
      curl -s http://127.0.0.1:8100/v1/models | python3 -m json.tool
```

1800s is a floor for an 8x MI300X TP=8 load of the default `MODEL`
(`Qwen/Qwen2.5-72B-Instruct`, ~145 GB bf16) with `--enable-prefix-caching`
graph capture, not a target — raise `VLLM_EXTRA_ARGS`/investigate if it
still hasn't come up. Confirm the weights are already on local disk under
`HF_HOME` before timing this step — a first-time download at this size will
dominate the wall clock and look indistinguishable from a hang (see §0's
note on pre-staging the download).

### §7.3 Decode

`[SMC2]`:

```bash
HF_TOKEN=<token> scripts/decode/03-start-decode.sh
```

Identical shape to §7.2 (`NixlConnector`'s `"kv_role":"kv_consumer"`, port
`DECODE_PORT`) — also starts this node's own LMCache MP daemon first. Not
strictly required that prefill be up first, but the proxy (§7.4) needs
decode.

### §7.4 Proxy

`[SMC2]` (or wherever `PROXY_HOST` points — the proxy is host-agnostic, see
its own docstring):

```bash
scripts/proxy/start-proxy.sh
```

Launches `scripts/proxy/disagg_proxy.py` under `start_bg`. Waits up to 30s
for `/status` to return 2xx.

Expected output:

```
ok  disagg-proxy healthy on port 8000
    test with:
      curl -s http://127.0.0.1:8000/status | python3 -m json.tool
      curl -s http://127.0.0.1:8000/v1/models
```

At this point the cluster is up; proceed to §8 to prove it actually works
(not just that all three processes started).

## §8 Verification ladder

`[any node with reach to all three]` for the top-level runner; individual
scripts are further constrained (see the table below and
[`../README.md`](../README.md)'s own Verification section for the summary
table).

```bash
scripts/verify/run-all.sh
```

Runs, in order, stopping at the first hard failure (later layers assume
earlier ones passed):

1. **`10-verify-network.sh`** — ICMP+TCP reachability to all relevant peers,
   local-interface MTU report **plus an active path-MTU probe**
   (`ping -M do -s 1472` and `-s 8972` — this is what catches a jumbo-frame
   mismatch that a purely local MTU check would miss), advisory
   storage-leg throughput via `iperf3` (needs a server already running on
   the peer — this script never starts one), and — **hard checks** only
   when `KV_TRANSPORT=rdma` — RDMA fabric health (`ibv_devinfo`,
   `rdma link show`, optional `ib_write_bw`/`rping` data-path probe).
   **Pass criteria:** all `check` (not `check_soft`) lines green.
2. **`20-verify-nixl-plugin.sh [prefill|decode]`** — plugin `.so` exists for
   whichever `KV_BACKEND` selects (`XNVME_KV` by default), `ldd` shows no
   `librte_*.so`/`libspdk_*.so` DT_NEEDED and nothing unresolved on the
   `SPDK_NVMe_KV` plugin specifically (hard checks — see §5's rationale;
   `XNVME_KV` legitimately links `libxnvme.so` dynamically, a different
   check shape), then in Python: `nixl_agent().get_plugin_list()` includes
   `${KV_BACKEND}`, `get_plugin_params()`'s `max_value_size` matches
   `KV_MAX_VALUE_SIZE_EFFECTIVE` (32768 on `XNVME_KV`, 524288 on
   `SPDK_NVMe_KV` — these are different numbers on purpose, see
   `config/cluster.env`), and `create_backend("${KV_BACKEND}", {...})`
   actually succeeds (i.e. connects to SMC3 on `SPDK_NVMe_KV`, or confirms
   the local `XNVME_DEV` char device on `XNVME_KV`). **Pass criteria:** all
   `check` lines green — this proves NIXL/the plugin/the fabric are fine
   with zero LMCache/vLLM involvement.
3. **`30-verify-kv-roundtrip.sh`** — the single most load-bearing test in
   this tree: a STORE from one OS process and a RETRIEVE from a
   **different** one, using `KV_MAX_VALUE_SIZE * 6` bytes by default
   specifically to exercise the multipart-split path (a payload smaller
   than `KV_MAX_VALUE_SIZE` would never touch that code at all). Modes:
   bare invocation does write+read as two processes on one host;
   `--write`/`--read --nonce=X` lets you run the writer on SMC1 and the
   reader on SMC2 for a genuinely cross-**node** proof. **Pass criteria:**
   both `RESULT:OK` — a `RESULT:QUERY_MISS` here means either the writer
   never ran, the two sides are pointed at different targets/namespaces, or
   the `queryMem()` regression from `ARCHITECTURE.md` §2.1 is back.
4. **`40-verify-disagg.sh`** — end-to-end, through the real
   proxy/vLLM/LMCache stack: sends the same long (>=2000 token), uniquely
   nonced prompt through the proxy twice, checks the decode-side LMCache
   hit-token metric increased between the two, and that the second
   request's time-to-first-token improved by at least
   `--ttft-improvement-min` (default `1.5`x — **soft**, reported either way
   since TTFT is noisy on a shared box). Also does a direct-to-decode
   liveness check bypassing the proxy. **Pass criteria:** HTTP 200 + non-empty
   body on both proxy requests (hard); hit-token increase (hard, if the
   metric name was found at all — falls back to a `warn` "coverage gap" if
   no known LMCache metric name matched anything on `/metrics`); TTFT
   improvement (soft).

On failure, `run-all.sh` and `40-verify-disagg.sh` both print the specific
log files and `grep` patterns to check next (see also
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)'s diagnostic-commands appendix).

## §8.5 Benchmark ladder

`[any node with reach to the proxy]` — once §8 passes (the cluster
functionally works), this is the next step: quantifying *how much* the
remote KV cache actually helps, over the real network path, not just that
it hits.

```bash
scripts/bench/run-all.sh
```

This repo does not duplicate that harness's documentation here — see
[`docs/BENCHMARKING.md`](BENCHMARKING.md) for what each of
`scripts/bench/{01-install-benchy,10-bench-baseline,20-bench-prefix-cache,
30-bench-concurrency,40-bench-transport-compare}.sh` measures, why
`llama-benchy` specifically, why `e2e_ttft` (not `ttfr`) is the honest
number, and how to read a negative result (§6 there points back at this
document's "LMCache hit tokens: 0" troubleshooting entry as the first thing
to rule out).

## §9 Phase 2: TCP → RDMA (compute leg only)

`KV_TRANSPORT=rdma` in `config/cluster.env` gates **only** the compute leg
— the direct P↔D `NixlConnector`/UCX side channel. **The storage leg
(NVMe-oF to SMC3) is TCP-only, unconditionally, by design, regardless of
this switch** — a previous pass added storage-tier RDMA groundwork (an
`-Denable_rdma` meson option on `plugins/nvme-kv`, an `nvme_rdma.o` split
archive) under the premise that it would eventually be needed; both have
been **removed entirely**, and `scripts/target/03-start-kv-target.sh` /
`scripts/common/05-build-spdk-initiator.sh` no longer accept any
RDMA-related build flag at all. If a storage-leg RDMA transport is ever
needed, that is new work to validate from scratch, not a flag to flip —
see the README's Status table and `config/cluster.env`'s `KV_TRANSPORT`
comment.

### §9.1 Current state — read before setting `KV_TRANSPORT=rdma`

**Proven, measured (2026-09-16):** the fabric NICs (Pensando DSC3-2Q400,
`ionic_0..7`) are **400 Gb/s** links (`ethtool` reports `Speed: 400000Mb/s`
on all 8 ports on both nodes — not the 200 Gb/s an earlier pass recorded
before this was actually measured). Static routes now exist for all 8
fabric pairs (`30.1.N.0/24 <-> 30.2.N.0/24`, both directions), and
cross-node RC `ib_write_bw` reached **41,898 MiB/s (~351 Gb/s, ~88% of
400G line rate)** at 8 MiB messages — see
`scripts/verify/10-verify-network.sh`'s RDMA-checks comment for the full
measurement and how to reproduce it (and for why
`/sys/class/net/*/statistics/rx_bytes` is **useless** for confirming this
traffic crossed at all — RoCE bypasses the kernel netdev path; use
`ethtool -S <netdev> | grep octets_rx_ok` on the **receiver**, settled a
few seconds after the transfer, instead).

**Still open — this is the actual blocker, not a build step:** UD queue-pair
creation still **fails** on this hardware (confirmed both via raw
`ibv_create_qp` and via NIXL/UCX's own connection setup). NIXL/UCX do
**not** need `rdma_cm` (which also fails here) — but `setup_ucx_env`'s RDMA
branch's `UCX_TLS_RDMA` value, `ib,rocm,self,sm` (`config/cluster.env` —
**not** the older `rc_verbs,rc_mlx5,dc,ud,self,sm`, which pins a transport
the ionic provider doesn't expose and fails outright), still pulls in UD
transports as part of "ib" (verbs-only), and those are exactly the ones
that fail to create on this hardware. Finding a transport spec that avoids
UD without reintroducing `rc`/`rc_mlx5` (also unsupported here) or silently
weakening the "must not fall back to tcp" invariant is the open item. Until
it's resolved, a full `KV_TRANSPORT=rdma` **vLLM** run has not been recorded
end-to-end against real hardware — the fabric itself is proven; the
NIXL/UCX path riding on it is not, yet.

`rocm` in `UCX_TLS_RDMA` is **not optional and not a network transport** —
it's the local memory-domain component UCX needs to recognize a ROCm/HIP
device pointer as VRAM at all; omitting it produces a misleading `VRAM
memory is detected as host by UCX` error that reads like a missing ROCm
build but isn't. See `config/cluster.env`'s `UCX_TLS_RDMA` comment for the
full failure-mode writeup.

### §9.2 Compute leg prerequisites

`[SMC1]` and `[SMC2]`:

- `10-build-stack.sh` already builds UCX `--with-verbs --with-dm
  --with-rdmacm` unconditionally (§5.2), so no rebuild is needed to flip
  `KV_TRANSPORT`.
- Set `KV_TRANSPORT=rdma` and `PREFILL_RDMA_DEV`/`DECODE_RDMA_DEV` (the
  `ibv_devinfo`/`rdma link show` device name — actual name depends on the
  DSC3 NIC's RoCE device enumeration on this host, e.g. `ionic_2`) in
  `config/cluster.env`. `01-host-prep.sh` hard-fails at prep time if
  `KV_TRANSPORT=rdma` and the corresponding `*_RDMA_DEV` is unset;
  `setup_ucx_env` hard-fails the same way at vLLM-start time as a second
  gate.
- **RoCE network prerequisites** (switch-side, not in this repo's scripts):
  PFC (Priority Flow Control) and ECN configured consistently across every
  hop between SMC1 and SMC2's DSC3-2Q400 ports; DSCP marking consistent with
  the switch's PFC-to-DSCP mapping; jumbo MTU (9000) end-to-end on this
  path, not just locally configured (see `10-verify-network.sh`'s active
  path-MTU probe — §8, item 1 — for how to confirm this, not just assume
  it from `ip link show`).
- `rdma link show` reporting the expected device(s) as `ACTIVE`.

### §9.3 Acceptance test and what proves RDMA (not a TCP fallback)

`[any]`:

```bash
scripts/verify/10-verify-network.sh   # RDMA fabric checks are HARD in rdma mode
scripts/verify/run-all.sh             # full ladder, KV_TRANSPORT=rdma
```

The property that proves RDMA is actually in use, not a silent TCP
fallback: `setup_ucx_env`'s RDMA branch **deliberately excludes `tcp`**
from `UCX_TLS` specifically so that a broken RoCE fabric fails the compute
leg loudly (vLLM/NIXL erroring out) rather than silently falling back —
see that function's comment in `scripts/common/lib.sh`. The storage leg has
no RDMA mode to compare against any more (§9 above) — `04-verify-target.sh`
will always report `NVMF_TRTYPE=TCP` there, and that is correct.

There is no committed acceptance run recording actual measured numbers for
a full `KV_TRANSPORT=rdma` vLLM deployment yet — see the README's Status
table (raw fabric proven; full run not yet recorded) and
[`docs/BENCHMARKING.md`](BENCHMARKING.md)'s §7/§8 (estimates and an empty
results log, respectively).

## §10 Teardown / restart procedures

**Stop, in reverse start order:**

```bash
# [any host running the proxy]
# (no dedicated stop script exists for the proxy in this repo's scripts/
#  tree today; stop_bg's PID-file convention still applies manually:)
kill "$(cat /run/kvstack/disagg-proxy.pid)"

# [SMC2]
scripts/decode/99-stop.sh              # add --clean-shm after a crash (SIGKILL/OOM)

# [SMC1]
scripts/prefill/99-stop.sh             # add --clean-shm after a crash

# [SMC3]
scripts/target/99-stop.sh              # add --release-hugepages to reclaim RAM,
                                        # --clean-config to drop the saved RPC config
```

`scripts/prefill/99-stop.sh`/`scripts/decode/99-stop.sh` also stop **this
node's own LMCache MP daemon** (`scripts/common/stop-lmcache-daemon.sh`,
forwarding `--clean-shm` to it) — the daemon is a separate host process
`03-start-{prefill,decode}.sh` started alongside vLLM (§7.1), not a child of
the vLLM process, so it does not stop just because `vllm-{prefill,decode}`
did; you do not need a separate command for it. `--clean-shm` removes stale
`/dev/shm/lmcache_*` and `/dev/shm/nixl_*` segments left behind by a
killed-not-stopped process — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#stale-devshmlmcache_-crashes-on-restart)
for why this matters.

**Restart, in the same order as §7** (target does not need §3.1/§3.2
re-run unless the host rebooted or the patches changed;
`scripts/prefill/03-start-prefill.sh`/`scripts/decode/03-start-decode.sh`
each start their own node's LMCache MP daemon automatically, §7.1):

```bash
# [SMC3]
scripts/target/03-start-kv-target.sh
scripts/target/04-verify-target.sh

# [SMC1] and [SMC2] — if either compute node rebooted, re-run §4.5
# (nvme connect) FIRST: the kernel NVMe-oF session does not survive a
# reboot, and start-lmcache-daemon.sh / start-vllm.sh will refuse to start
# without it on KV_BACKEND=XNVME_KV (the default).

# [SMC1]
scripts/prefill/03-start-prefill.sh

# [SMC2]
scripts/decode/03-start-decode.sh

# [SMC2 or PROXY_HOST]
scripts/proxy/start-proxy.sh
```

**Namespace reset** (required after changing `KV_MAX_VALUE_SIZE`, or any
time you suspect stale cross-geometry data — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#half-stale-corrupted-reads)):

```bash
# [SMC3]
scripts/target/50-reset-namespace.sh   # interactive confirm; KV_ASSUME_YES=1 to skip
scripts/target/04-verify-target.sh
```

This deletes every KV object currently stored (the namespace is RAM-backed —
the data does not survive regardless of whether you run this script) by
restarting `nvmf_tgt` (`scripts/target/03-start-kv-target.sh --restart`),
which regenerates and re-applies the same `--json` config
(`lib-kv-rpc.sh`'s `kv_target_gen_json_config`) from `config/cluster.env`
every time — there is no separate RPC teardown/recreate sequence any more
for the two to drift apart from.
