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
- **`KV_SPDK_REPO`** — the git URL (and, if not `main`/default branch,
  `KV_SPDK_REF`) for the kv_spdk fork, needed **only for the SMC3 target**
  (`SPDK_TARGET_FLAVOR=fork`, the default — as of SPDK v26.05 the NVMe-KV
  *initiator* API is upstream, but `bdev_kvmalloc` and the nvmf KV opcode
  routing the target needs are not; see `docs/ARCHITECTURE.md` §7). Not
  vendored in this repo — see README gap #2 and
  `scripts/target/02-build-spdk-kv.sh`'s own error message if this is
  missing. SMC1/SMC2 do **not** need this — they build a stock upstream SPDK
  tree via `scripts/common/05-build-spdk-initiator.sh`.
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

Installs apt deps for building kv_spdk, allocates `HUGEPAGE_COUNT` (default
8192 × 2 MiB = 16 GiB) hugepages at the sysfs node (not
`/proc/sys/vm/nr_hugepages`), loads `nvme_tcp nvme_fabrics vfio_pci
uio_pci_generic`, runs `scripts/common/tune-tcp.sh`, inventories the two
POLLARA-1Q400 NICs and RDMA device presence, opens `NVMF_TRSVCID` (4420) in
whatever firewall is actually active (or says explicitly that neither
`ufw`/`firewalld` is active), sets unlimited `memlock`, and creates
`STACK_ROOT`/`LOG_DIR`/`RUN_DIR`.

Expected output: a `Summary` step reporting
`hugepages: <N>/8192`, the storage-leg interfaces toward SMC1 and SMC2, and
`KV_TRANSPORT=tcp NVMF_TRSVCID=4420`. If hugepages report short by more than
10%, **reboot this host before continuing** (the script prints this warning
itself) — see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#hugepage-allocation-short-of-requested).

The memlock limits file it writes only takes effect in a **new** login
session — if you plan to run `03-start-kv-target.sh` in the same shell,
start a fresh shell/session first.

### §3.2 Build the target-side SPDK tree (the fork)

```bash
KV_SPDK_REPO=<fork-url> [KV_SPDK_REF=<ref>] scripts/target/02-build-spdk-kv.sh
```

`SPDK_TARGET_FLAVOR=fork` (the default) is **required** here: as of SPDK
v26.05 the NVMe-KV *initiator* API is upstream, but `bdev_kvmalloc` and
`lib/nvmf/ctrlr_bdev.c`'s KV opcode routing are not (see
[`ARCHITECTURE.md` §7](ARCHITECTURE.md#7-spdk-upstream-initiator-forked-target))
— a stock tree cannot serve a KV namespace, full stop. (Setting
`SPDK_TARGET_FLAVOR=upstream` builds a stock `${SPDK_UPSTREAM_REPO}`@`${SPDK_VERSION}`
tree instead; the script still runs, but step 3 below deliberately fails its
own artifact check on it — useful only to prove the "not upstream" claim to
yourself, not a real bring-up path.)

Clones `KV_SPDK_REPO`@`KV_SPDK_REF` (if `SPDK_TARGET_SRC` doesn't already
have `include/spdk/nvme_kv.h`), `git submodule update --init --recursive`,
then `./configure --without-shared --with-nvmf --with-uring --disable-tests
--disable-unit-tests --disable-examples` (plus `--with-rdma=${SPDK_RDMA_PROVIDER:-verbs}`
when `SPDK_WITH_RDMA=1`, the default — see §9.2) `&& make`.
`--without-shared` matters: it's what prevents DPDK's vendored build from
emitting both `librteX.a` and `librteX.so` side by side, which is the root
cause behind the plugin's silent-dlopen-failure class of bug (see
`TROUBLESHOOTING.md`).

Expected output: a `Verifying build artifacts` step confirming
`libspdk_nvme.a`, `libspdk_bdev_kvmalloc.a` (its **absence** specifically
means either the wrong SPDK fork was built, or `SPDK_TARGET_FLAVOR=upstream`
was requested deliberately — stock upstream SPDK has no `bdev_kvmalloc`
module at all, on any version), `libspdk_sock_posix.a`, `spdk_tgt`,
`include/spdk/nvme_kv.h`, `isa-l/.libs/libisal.a`, and
`dpdk/build/lib/librte_eal.a` all present, then
`Generating split archives (prepare-spdk-libs.sh)` producing
`libspdk_nvme_tcp_only.a`, `libspdk_nvme_pcie_only.a`,
`libspdk_sock_posix_only.a` (and `libspdk_nvme_rdma_only.a` if `nvme_rdma.o`
is present — see §9.2) in `${SPDK_TARGET_SRC}/build/lib`. Finally reports
the built SPDK version and, if `SPDK_INITIATOR_FLAVOR=upstream`, warns if
this target tree looks older than v26.05 (the two trees are independent, but
worth flagging so version-skew questions aren't confusing later).

If this fails: see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#stock-upstream-spdk-on-the-target-bdev_kvmalloc_create-rpc-not-found)
and the script's own error text (it explains the `libspdk_bdev_kvmalloc.a`
missing case specifically, including the `SPDK_TARGET_FLAVOR=upstream` case).

### §3.3 Start the target

```bash
scripts/target/03-start-kv-target.sh
```

Runs `kv_target_check_sgl` first (the `NVMF_MAX_IO_SIZE`/`NVMF_IO_UNIT_SIZE`
÷ 16 arithmetic — see §9.2/Configuration) **before** touching the process at
all, so a bad ratio fails immediately with the arithmetic shown rather than
after `spdk_tgt` is already up. On SPDK pre-v26.05 a bad ratio is a hard
`die()`; on `>=26.05` (the default here) it's a `warn()` instead, since
`io_unit_size` is a deprecated no-op on that version and the ratio may no
longer be the real ceiling — see
[`ARCHITECTURE.md` §7](ARCHITECTURE.md#7-spdk-upstream-initiator-forked-target).
Starts `spdk_tgt` under `start_bg` (detached, PID-tracked, logged to
`${LOG_DIR}/kv-target.log`), waits for the RPC socket (`${SPDK_RPC_SOCK}`,
default `/var/tmp/spdk.sock`), then applies the RPC sequence
(`lib-kv-rpc.sh`'s `kv_target_apply_config`): create the `NVMF_TRTYPE`
transport (passing `--iobuf-small-cache-size`/`--iobuf-large-cache-size`
from `NVMF_IOBUF_SMALL_CACHE_SIZE`/`NVMF_IOBUF_LARGE_CACHE_SIZE` on
`>=26.05`, probed against `nvmf_create_transport --help` first since the
fork's exact RPC surface isn't vendored here), create the `bdev_kvmalloc`
namespace (`KV_BDEV_NAME`, `KV_BDEV_SIZE_GB`), create the subsystem
(`NVMF_SUBNQN`), attach the namespace, attach the listener
(`NVMF_TRADDR:NVMF_TRSVCID`).

Flags: `--foreground` (runs `spdk_tgt` attached, Ctrl-C to stop — RPC config
does NOT run automatically in this mode), `--restart` (stop first if
already running), `--skip-config` (start the process but leave RPC state
untouched — useful after a crash where the config was already applied and
should not be re-applied).

Expected output ends with:

```
ok  kv-target up
    TRID for initiators: trtype:TCP adrfam:IPv4 traddr:${TARGET_HOST} trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0
    verify from this host: scripts/target/04-verify-target.sh
    verify from SMC1/SMC2: nvme discover -t tcp -a ${TARGET_HOST} -s 4420
```

If it fails: check `bdev_kvmalloc_create`'s exact RPC argument names first —
`lib-kv-rpc.sh`'s `create_kv_bdev()` tries one plausible argument form and,
on failure, prints `rpc.py`'s own `--help` for the command and tells you to
set `KV_BDEV_CREATE_ARGS` to override (this repo does not vendor kv_spdk, so
its exact RPC surface cannot be verified ahead of time — see README gap #2).
See also [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#sgl-length-exceeds-max-io-size).

### §3.4 Verify the target

```bash
scripts/target/04-verify-target.sh
```

Hard checks: `kv-target` process running, RPC responds
(`spdk_get_version`), subsystem present with exactly 1 namespace, transport
reports the configured `max_io_size`/`io_unit_size`, TCP port
`NVMF_TRSVCID` listening, free hugepages > 0. Soft check: local `nvme
discover` lists the subnqn (advisory — `nvme-cli` may not be relevant on a
pure target). Ends by printing the exact commands to run from SMC1/SMC2 to
verify remotely (`nvme discover ...` and a one-liner that constructs a
`nixl_agent` and prints `get_plugin_params('SPDK_NVMe_KV')`).

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

Configures `--without-shared --with-uring` (plus `--with-rdma=${SPDK_RDMA_PROVIDER:-verbs}`
when `SPDK_WITH_RDMA=1`, the default — see §9.1), builds, then **verifies the
KV API is actually present** — `nm -g "${SPDK_SRC}/build/lib/libspdk_nvme.a"`
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
   Builds with `-Denable_rdma=false` (the default — see §9.1; this is a
   plugin-level meson option, not exposed by this script directly).
5. **`plugins/xnvme-kv`** (`XNVME_KV`, optional) — skipped automatically if
   `libxnvme` headers/libs aren't found (expected on this cluster; it isn't
   the storage-leg backend here — see `ARCHITECTURE.md` §6). Set
   `XNVME_INCDIR`/`XNVME_LIBDIR` to force-enable.
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
deliberately; see the script's comment on the
`KeyError: 'LMCacheConnectorV1'` failure mode this avoids. Installs
`aiohttp` (used by the proxy). Installs the `nixl` → `nixl_rocm` shim package
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
    next: scripts/common/gen-lmcache-config.sh <prefill|decode> <output-path>
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

### §6.3 Generate + validate the config

Config generation itself is normally handled automatically by
`scripts/common/start-vllm.sh` (§7), but you can run it standalone to
inspect the file before starting anything:

```bash
scripts/common/gen-lmcache-config.sh prefill /opt/kvstack/etc/lmcache-prefill.yaml
scripts/common/25-validate-lmcache-config.sh /opt/kvstack/etc/lmcache-prefill.yaml
```

`gen-lmcache-config.sh` writes `nixl_pool_size: 0` (selects LMCache's
content-derived-key `NixlDynamicStorageBackend` — see
`ARCHITECTURE.md` §3; **never** change this away from 0 on this cluster),
`nixl_backend: "SPDK_NVMe_KV"`, and `nixl_backend_params` (`trid`,
`max_value_size`, `kv_slot_offset`) sourced straight from `config/cluster.env`.

`25-validate-lmcache-config.sh` introspects the **installed** LMCache's
actual source (via `inspect.getsource`, not a hardcoded assumption) to prove
every key in the generated YAML is both recognized and routed to the NIXL
storage backend, and that `validate_nixl_backend()`/the OBJ mem_type check
both now accept `SPDK_NVMe_KV` (i.e. that §6.2's patch actually took). It
also constructs a throwaway `nixl_agent` and echoes back the **live**
plugin's `get_plugin_params("SPDK_NVMe_KV")` so you can eyeball it against
what's in the YAML.

Expected final line: `PASS: all generated keys are recognized by the
installed LMCache.` Any `FAIL`/`IGNORED` line above that must be resolved
before starting vLLM — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#assertionerror-on-the-lmcache-nixl-backend-name).

## §7 Start prefill, decode, proxy

### §7.1 Prefill

`[SMC1]`:

```bash
HF_TOKEN=<token> scripts/prefill/03-start-prefill.sh
```

This is a thin wrapper that pins `require_host "${PREFILL_HOST}" "prefill"`
and `exec`s `scripts/common/start-vllm.sh prefill`. That shared script, in
order: sources `${STACK_ROOT}/etc/env.sh`, calls `setup_nixl_kv_env prefill`
and `setup_ucx_env` (from `lib.sh`), generates + validates the LMCache
config for this role (pass `--skip-validate` only for debugging the
validator itself — **not recommended**, see the script's own warning),
**refuses to start if SMC3's NVMe-oF port isn't reachable within 30s** (a
hard gate, not a warning — see the script's comment on why a silent
local-only fallback is the worst failure mode here), then launches
`vllm.entrypoints.openai.api_server` with `--kv-transfer-config
{"kv_connector":"LMCacheConnectorV1","kv_role":"kv_producer",...}` under
`start_bg`, and waits up to 1800s for `/health` to return 2xx.

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

### §7.2 Decode

`[SMC2]`:

```bash
HF_TOKEN=<token> scripts/decode/03-start-decode.sh
```

Identical shape to §7.1 (`kv_role=kv_consumer`, port `DECODE_PORT`). Not
strictly required that prefill be up first, but the proxy (§7.3) needs
decode.

### §7.3 Proxy

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
2. **`20-verify-nixl-plugin.sh [prefill|decode]`** — plugin `.so` exists,
   `ldd` shows no `librte_*.so`/`libspdk_*.so` DT_NEEDED and nothing
   unresolved (hard checks — see §5's rationale), then in Python:
   `nixl_agent().get_plugin_list()` includes `SPDK_NVMe_KV`,
   `get_plugin_params()`'s `max_value_size` matches `KV_MAX_VALUE_SIZE`, and
   `create_backend("SPDK_NVMe_KV", {"trid": ...})` actually succeeds (i.e.
   connects to SMC3). **Pass criteria:** all `check` lines green — this
   proves NIXL/the plugin/SPDK/the fabric are fine with zero LMCache/vLLM
   involvement.
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

## §9 Phase 2: TCP → RDMA

`KV_TRANSPORT=rdma` in `config/cluster.env` is the single switch, but it is
**not** a drop-in flip yet — read this whole section before setting it.

### §9.1 Initiator-side: current state

**What is implemented:** `plugins/nvme-kv/prepare-spdk-libs.sh` splits
`nvme_rdma.o` out of `libspdk_nvme.a` into `libspdk_nvme_rdma_only.a`
whenever that object is present (`ar t "${LIB_DIR}/libspdk_nvme.a" | grep
'^nvme_rdma\.o$'`) — a clean no-op, not a failure, on a tree that wasn't
configured `--with-rdma`. `nvme_rdma.o` only exists if the initiator's SPDK
tree (`scripts/common/05-build-spdk-initiator.sh`) was built with
`SPDK_WITH_RDMA=1` (the default in `config/cluster.env`, `--with-rdma=verbs`
unless `SPDK_RDMA_PROVIDER` overrides it). `plugins/nvme-kv/meson.build` has
an opt-in `-Denable_rdma` option (`meson_options.txt`, default `false`) that,
when set `true`, adds `libspdk_nvme_rdma_only.a` to the same
`--whole-archive` group TCP/PCIe/posix are already in (so its
`SPDK_NVME_TRANSPORT_REGISTER` constructor for the RDMA transport actually
runs) and appends `-lrdmacm -libverbs` to the link line. `-Denable_rdma=false`
(the default `10-build-stack.sh` uses) produces a byte-equivalent link line
to before this option existed — this was a deliberate constraint on the
implementation, not an accident.

**What remains — this has never been exercised end to end:**

1. Rebuild the plugin with RDMA linked in:

   ```bash
   # [SMC1] and [SMC2]
   cd plugins/nvme-kv
   rm -rf build-nvme-kv
   meson setup build-nvme-kv \
       -Dnixl_path="${NIXL_PREFIX}" -Dspdk_path="${SPDK_SRC}" \
       -Drocm_path="${ROCM_PATH}" -Denable_vram=true -Denable_rdma=true \
       --prefix="${NIXL_PREFIX}"
   ninja -C build-nvme-kv -j "$(nproc)" && ninja -C build-nvme-kv install
   ```

   (`10-build-stack.sh` itself does not expose a `--enable-rdma` flag today
   — this is a manual rebuild until/unless that's added.) Confirm
   `libspdk_nvme_rdma_only.a` actually exists in `${SPDK_SRC}/build/lib`
   first (§5.1's `05-build-spdk-initiator.sh` produces it only if
   `SPDK_WITH_RDMA=1` was in effect when that tree was built); if it's
   missing, see
   [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#rdma-plugin-build--denable_rdmatrue-fails-because-the-initiators-spdk-tree-wasnt-built---with-rdma).
2. Re-run the mandatory `ldd` self-containment check by hand against the
   freshly built `.so` (the same check `10-build-stack.sh` step 4 runs
   automatically) — an RDMA-linked build pulls in `libibverbs.so`/`librdmacm.so`
   as genuine shared runtime dependencies, which is expected and fine; only
   a stray `librte_*.so`/`libspdk_*.so` DT_NEEDED is the bug this check
   exists to catch.
3. Set `KV_TRANSPORT=rdma`, bring up the target per §9.2, and confirm
   `create_backend("SPDK_NVMe_KV", {"trid": "trtype:RDMA ..."})` in
   `scripts/verify/20-verify-nixl-plugin.sh` actually succeeds rather than
   failing outright (see §9.4 for why a failure here, not a silent TCP
   connection, is the expected behavior of an RDMA-unlinked plugin).
4. A live RoCE fabric between SMC1/SMC2 and SMC3 to actually carry the
   traffic — see §9.3's RoCE prerequisites, which apply to the storage leg
   too, not just the compute leg.
5. A passing `scripts/verify/run-all.sh` and, ideally,
   `scripts/bench/40-bench-transport-compare.sh` (see
   [`docs/BENCHMARKING.md`](BENCHMARKING.md)) recorded against real
   hardware — nothing in this repo has run any of the above yet.

Until step 3+ above is actually done, `scripts/target/03-start-kv-target.sh`
still prints this exact caveat if you set `KV_TRANSPORT=rdma` and start the
target: it brings the target up on RDMA regardless, but warns that the
initiators cannot attach unless they were rebuilt with `-Denable_rdma=true`
against a `--with-rdma`-configured SPDK tree.

### §9.2 Target side

`[SMC3]` — once §9.1's initiator work is done (or if you're validating the
target side alone first): the target's SPDK fork tree (§3.2) was already
configured `--with-rdma=${SPDK_RDMA_PROVIDER:-verbs}` if `SPDK_WITH_RDMA=1`
(the default) was set at build time — no rebuild needed here, unlike the
initiator side. Set `KV_TRANSPORT=rdma` in `config/cluster.env` (this flips
`NVMF_TRTYPE` to `RDMA` automatically — see that file's comment), confirm
`/sys/class/infiniband` is non-empty (`scripts/target/01-host-prep.sh`'s
step 6 reports this), then:

```bash
scripts/target/03-start-kv-target.sh --restart
```

`lib-kv-rpc.sh`'s `kv_target_apply_config` issues
`nvmf_create_transport -t RDMA ...` instead of `-t TCP` — same RPC sequence,
different `NVMF_TRTYPE`. Verify with `scripts/target/04-verify-target.sh` as
in §3.4 (its transport-size check adapts to whatever `NVMF_TRTYPE` is
configured).

### §9.3 Compute leg

`[SMC1]` and `[SMC2]` — this leg (the direct NIXL/UCX side channel) is
**closer to ready** than the storage leg: `scripts/common/lib.sh`'s
`setup_ucx_env` already implements the RDMA branch
(`UCX_TLS="rc_verbs,rc_mlx5,dc,ud,self,sm"`, deliberately **excluding**
`tcp`), and `10-build-stack.sh` already builds UCX `--with-verbs`. What's
still required:

- Set `KV_TRANSPORT=rdma` and `PREFILL_RDMA_DEV`/`DECODE_RDMA_DEV` (the
  `ibv_devinfo`/`rdma link show` device name, e.g. `rocep1s0` — actual name
  depends on the DSC3 NIC's RoCE device enumeration on this host) in
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

### §9.4 Acceptance test and what proves RDMA (not a TCP fallback)

`[any]`:

```bash
scripts/verify/10-verify-network.sh   # RDMA fabric checks are HARD in rdma mode
scripts/verify/run-all.sh             # full ladder, KV_TRANSPORT=rdma
```

The number that proves RDMA is actually in use, not a silent TCP fallback:
`setup_ucx_env`'s RDMA branch **deliberately excludes `tcp`** from
`UCX_TLS` specifically so that a broken RoCE fabric fails the compute leg
loudly (vLLM/NIXLErroring out) rather than silently falling back to TCP —
see that function's comment in `scripts/common/lib.sh`. For the storage
leg, `scripts/target/04-verify-target.sh`'s transport check
(`nvmf_get_transports` reporting `"trtype": "RDMA"`) plus a successful
`scripts/verify/20-verify-nixl-plugin.sh` run with `NVMF_TRTYPE=RDMA` baked
into `KV_TRID` is the storage-leg equivalent: if the initiator plugin
was **not** rebuilt with `-Denable_rdma=true` (the default, and the current
state of every build this repo has actually run — §9.1),
`create_backend()` fails outright rather than silently connecting over TCP,
because the TRID string itself says `trtype:RDMA` and the plugin has no
fallback path that downgrades a requested transport. Once rebuilt with RDMA
linked in, the same principle still holds: a broken RoCE fabric should fail
`create_backend()`, not silently downgrade to TCP — this has not yet been
observed against real hardware either way.

There is no committed acceptance run recording actual measured numbers for
this cluster yet — see the README's Status section and
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

`--clean-shm` (prefill/decode) removes stale `/dev/shm/lmcache_*` and
`/dev/shm/nixl_*` segments left behind by a killed-not-stopped process —
see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#stale-devshmlmcache_-crashes-on-restart)
for why this matters.

**Restart, in the same order as §7** (target does not need §3.1/§3.2
re-run unless the host rebooted or kv_spdk changed):

```bash
# [SMC3]
scripts/target/03-start-kv-target.sh
scripts/target/04-verify-target.sh

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
the data does not survive regardless of whether you run this script) and
recreates it via the same RPC sequence `03-start-kv-target.sh` uses
(`lib-kv-rpc.sh`), so the two can never configure the namespace differently.
