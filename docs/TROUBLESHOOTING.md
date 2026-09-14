# Troubleshooting

Symptom-driven. Find the log line or observed behavior below; each entry
gives the cause and the fix. Cross-references: [`../README.md`](../README.md)
for topology/config, [`ARCHITECTURE.md`](ARCHITECTURE.md) for design
rationale, [`BRINGUP.md`](BRINGUP.md) for the step that normally catches
this before it reaches this list.

---

### "unsupported backend" from NIXL with no other error

**Symptom:** NIXL logs something like `unsupported backend: SPDK_NVMe_KV`
(or the equivalent for `XNVME_KV`) and nothing else — no mention of a
missing shared library, no linker error, nothing pointing at the actual
cause.

**Cause:** `dlopen()` of the plugin `.so` failed silently. NIXL's plugin
manager reports any `dlopen()` failure this way, with zero information
about *why* it failed. The near-universal cause on this repo's plugins is a
DT_NEEDED entry on a `librte_*.so`/`libspdk_*.so` that the deployed
environment doesn't actually ship — see `plugins/nvme-kv/meson.build`'s own
extended comment on exactly how this happens (a bare `-lrte_eal` resolving
to the `.so` sitting next to the intended `.a` in the same `-L` directory,
because SPDK's vendored DPDK submodule can emit both even when SPDK itself
is configured `--without-shared`).

**Fix:**
```bash
# [SMC1 or SMC2]
ldd "${NIXL_PLUGIN_DIR}/libplugin_SPDK_NVMe_KV.so" | grep -E 'librte_|libspdk_'
```
Any hit here is the bug. Rebuild SPDK itself with `--without-shared`
(`scripts/common/05-build-spdk-initiator.sh` on SMC1/SMC2 and
`scripts/target/02-build-spdk-kv.sh` on SMC3 both already do this) and re-run
`scripts/common/10-build-stack.sh` step 4, which now includes a **hard,
build-blocking** `ldd` check for exactly this (see its own comment — this
check did not always exist, and its absence is why this failure mode used
to surface two layers away). `scripts/verify/20-verify-nixl-plugin.sh` also
re-checks this independently, so it should never reach a live vLLM run
undetected going forward.

---

### `libplugin_SPDK_NVMe_KV.so` not built / not found

**Symptom:** `scripts/verify/20-verify-nixl-plugin.sh`'s first check
(`libplugin_SPDK_NVMe_KV.so exists in NIXL_PLUGIN_DIR`) fails, or
`scripts/common/25-validate-lmcache-config.sh`'s live plugin introspection
reports `'SPDK_NVMe_KV' not in NIXL's plugin list`.

**Cause:** either it was never built (`scripts/common/10-build-stack.sh`
step 4 skipped or failed), or `NIXL_PLUGIN_DIR` at runtime doesn't match
where it was installed.

**Fix:**
```bash
# [SMC1 or SMC2]
echo "${NIXL_PLUGIN_DIR}"                 # should be ${NIXL_PREFIX}/lib/x86_64-linux-gnu/plugins
ls -la "${NIXL_PLUGIN_DIR}"               # confirm the .so is actually there
```
If missing, re-run `sudo scripts/common/10-build-stack.sh` (step 4 requires
`scripts/common/05-build-spdk-initiator.sh` to have already built
`${SPDK_SRC}` — see `BRINGUP.md` §5.1/§5.2). If
present but not found at runtime, confirm `NIXL_PLUGIN_DIR` is exported
before the process starts — `scripts/common/lib.sh`'s `setup_nixl_kv_env`
exports it, and `${STACK_ROOT}/etc/env.sh` (written by
`20-build-vllm-lmcache.sh`) also sets it; check the installed meson
`--prefix` (`${NIXL_PREFIX}`) actually matches `NIXL_PLUGIN_DIR`'s prefix in
`config/cluster.env` if you've customized either.

---

### "LMCache hit tokens: 0" on every decode request

**Symptom:** decode's logs report zero LMCache hit tokens on every request,
even for a prompt that was previously stored via prefill (or via a prior
identical request).

**Cause:** one of two independent things, both documented in detail
elsewhere in this repo — check both:

1. **The LMCache config is using the wrong storage-backend mode.**
   `nixl_pool_size` must be `0` (selects `NixlDynamicStorageBackend`,
   content-derived keys). If it's greater than 0, LMCache uses
   `NixlStaticStorageBackend`, whose object names are
   `obj_{slot}_{uuid4}` — a fresh random `uuid4` per process — so prefill's
   and decode's names for "the same" content share nothing and every lookup
   misses. See `scripts/common/gen-lmcache-config.sh`'s "THE
   CONTENT-DERIVED-KEY CONSTRAINT" section.
2. **The plugin's existence-probe support is missing.** Without
   `queryMem()`, NIXL's base class answers `NIXL_ERR_NOT_SUPPORTED` for
   every lookup, which LMCache treats as a miss. This was the cluster's
   original, canonical incident (2026-09-07) — see
   `plugins/nvme-kv/spdk_nvme_kv_backend.h`'s `queryMem()` comment and
   `ARCHITECTURE.md` §2.1. This repo's committed plugin *has* `queryMem()`
   implemented; if you're seeing this symptom against the committed code,
   suspect cause 1 first, then confirm the running plugin binary actually
   matches this source (a stale `.so` from before `queryMem()` was added
   would reproduce this exactly).

**Fix:**
```bash
# [SMC1 or SMC2] — confirm nixl_pool_size
grep nixl_pool_size "${STACK_ROOT}/etc/lmcache-decode.yaml"   # must be: nixl_pool_size: 0

# confirm queryMem support end to end
scripts/verify/30-verify-kv-roundtrip.sh --write
scripts/verify/30-verify-kv-roundtrip.sh --read --nonce=<printed-nonce>
```
A `RESULT:QUERY_MISS` from the read side, when the write side reported
`RESULT:OK`, means the existence probe is not confirming a key that
genuinely exists — check `KV_TRID` matches on both sides and that
`plugins/nvme-kv`'s built `.so` is current.

---

### AssertionError on the LMCache NIXL backend name

**Symptom:** `AssertionError: Invalid NIXL backend & device combination` the
first time the NIXL storage backend is constructed.

**Cause:** the LMCache backend-allowlist patch
(`patches/lmcache/apply-patches.sh`) was not applied to the installed
LMCache — stock LMCache's `validate_nixl_backend()` does not recognize
`SPDK_NVMe_KV`/`XNVME_KV` at all (see `patches/lmcache/README.md`).

**Fix:**
```bash
# [SMC1 or SMC2]
patches/lmcache/apply-patches.sh --dry-run     # see what would change
patches/lmcache/apply-patches.sh               # apply
scripts/common/25-validate-lmcache-config.sh "${STACK_ROOT}/etc/lmcache-prefill.yaml"
```
The validator's "NIXL backend allowlist (installed LMCache source)" section
must show `ACCEPTED` for both `validate_nixl_backend()` and the OBJ
mem_type check. If `apply-patches.sh` itself reports
`FAIL: zero "GDS"/"POSIX"/"OBJ" allowlist-shaped brackets found`, the
installed LMCache version has moved this logic to a different shape/location
than this patch engine expects — see `patches/lmcache/README.md`'s "What is
ASSUMED" section for exactly which parts of the patch are unverified against
a real source tree.

---

### Cache silently local, nothing crosses the network

**Symptom:** the server starts, answers `/health`, serves every request —
and a live P/D cache-hit test comes back suspiciously empty, with **no
error anywhere in the logs**.

**Cause:** almost always the *other* half of the previous entry's bug —
`NixlDynamicStorageAgent.__init__`'s second hardcoded name list decides the
NIXL `mem_type` for a backend, separately from `validate_nixl_backend()`. If
a version/code-path skips the first assertion but `SPDK_NVMe_KV` still isn't
in *this* list, LMCache silently takes the `FILE` mem_type path instead of
`OBJ`: real `os.open()`/`os.path.join(extra_config.nixl_path, key)` calls
against the **local filesystem** of whichever node ran the store. Nothing
anywhere logs an error, because as far as LMCache is concerned this
succeeded. See `patches/lmcache/README.md`'s "Silent, dangerous failure"
paragraph.

**Fix:** same as the previous entry (apply/re-verify the patch). To
**prove** traffic is or isn't actually crossing the network rather than
trusting the config alone:
```bash
# [SMC1 or SMC2] — is there an open TCP connection to the target at all?
ss -tnp | grep ":4420"                      # NVMF_TRSVCID; should show an ESTABLISHED socket

# [SMC3] — target-side stats: does it see any I/O at all? (SPDK_TARGET_SRC,
# not SPDK_SRC — that's the SMC1/SMC2 initiator tree, a different SPDK
# build entirely as of v26.05, see ARCHITECTURE.md §7)
scripts/target/lib-kv-rpc.sh   # (sourced by 03-/50-; rpc_json is the function to reuse)
"${SPDK_TARGET_SRC}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" bdev_get_bdevs -b kv0  # look for nonzero I/O counters if the RPC exposes them

# nvme-cli view from the initiator
nvme list-subsys                            # confirm the NVMe-oF controller is actually attached
```
If `ss` shows no established socket to `${TARGET_HOST}:${NVMF_TRSVCID}` at
all while vLLM is serving traffic, the NIXL storage backend never
constructed a working connection — go back to §6 of `BRINGUP.md` and
re-validate the config.

---

### "SGL length exceeds max io size"

**Symptom:** the SMC3 target logs (or an initiator-side transfer failure)
mentions `SGL length ... exceeds max io size`.

**Cause:** a single value handed to the plugin exceeds
`KV_MAX_VALUE_SIZE`'s relationship to the target's `max_io_size`/
`io_unit_size`. `KV_MAX_VALUE_SIZE` (default `524288`) is **not** a device
limit — `bdev_kvmalloc` allows values up to `KV_BDEV_VALUE_MAX` (64 MiB).
On SPDK pre-v26.05, it is the NVMe-oF/TCP transport's SGL ceiling:
`nvmf_tcp_create()` rejects any `max_io_size` where
`max_io_size / io_unit_size > SPDK_NVMF_MAX_SGL_ENTRIES (16)`. This repo's
target is configured `NVMF_MAX_IO_SIZE=1048576`,
`NVMF_IO_UNIT_SIZE=131072` (exactly 8 SGL entries — half the 16-entry
budget), and `KV_MAX_VALUE_SIZE=524288` leaves headroom under that for
NVMe/TCP PDU framing overhead. On `>=26.05` `io_unit_size` is a deprecated
no-op and this specific ratio is no longer necessarily the governing rule
(see the next-but-one entry and `ARCHITECTURE.md` §7) — but the symptom and
`KV_MAX_VALUE_SIZE`'s validated default are unchanged either way. If
LMCache's multipart split is bypassed (e.g. a raw `kv_io.py`/`nixlbench`
call sending an unsplit KV page whole), the target rejects it outright with
this message.

**Fix:** confirm the caller is actually going through LMCache's
multipart-split path (see `ARCHITECTURE.md` §2, step 4) rather than sending
a raw oversized descriptor. If you've changed `KV_MAX_VALUE_SIZE` yourself,
confirm the arithmetic still holds:
```bash
# NVMF_MAX_IO_SIZE / NVMF_IO_UNIT_SIZE must be <= 16
python3 -c "print(${NVMF_MAX_IO_SIZE} / ${NVMF_IO_UNIT_SIZE})"
```
`scripts/target/lib-kv-rpc.sh`'s `kv_target_check_sgl()` runs this exact
check before the target ever attempts `nvmf_create_transport`, so a bad
ratio should already have been caught at target-start time — see the next
entry.

---

### Target won't start after raising `max_io_size`

**Symptom:** `scripts/target/03-start-kv-target.sh` dies immediately with
`SGL entries N > 16` before `spdk_tgt` is even started.

**Cause:** this is the same `/16` SGL rule as above, caught proactively.
`NVMF_MAX_IO_SIZE` was raised without also raising `NVMF_IO_UNIT_SIZE`
proportionally (or vice versa). This is only a hard `die()` on SPDK
**pre-v26.05** (`scripts/target/lib-kv-rpc.sh`'s `kv_target_check_sgl()` —
see the next entry for the `>=26.05` case, which only `warn()`s).

**Fix:** either lower `NVMF_MAX_IO_SIZE` or raise `NVMF_IO_UNIT_SIZE` in
`config/cluster.env` so `NVMF_MAX_IO_SIZE / NVMF_IO_UNIT_SIZE <= 16`, then
re-run. If you also change `KV_MAX_VALUE_SIZE` as part of this, drain the
namespace first — see the "Half-stale / corrupted reads" entry below.

---

### Building against pre-v26.05 SPDK: missing `spdk_nvme_kv_*` symbols at link time

**Symptom:** `scripts/common/05-build-spdk-initiator.sh` dies at its
"Verifying NVMe-KV initiator API is present" step with one or more of:
`missing: include/spdk/nvme_kv.h`, `missing: symbol:spdk_nvme_kv_store`,
`missing: symbol:spdk_nvme_kv_retrieve`, `missing: symbol:spdk_nvme_kv_exist`,
or `missing: enum member matching KEY_DOES_NOT_EXIST`. Equivalently, if this
check were somehow bypassed, `plugins/nvme-kv`'s meson/ninja build would
instead fail at the link step with undefined references to
`spdk_nvme_kv_store`/`spdk_nvme_kv_retrieve`/etc., or fail even earlier at
`#include <spdk/nvme_kv.h>` not being found.

**Cause:** the NVMe Key-Value command-set **initiator** API
(`include/spdk/nvme_kv.h`, `spdk_nvme_kv_{store,retrieve,delete,exist,list}()`,
the `enum spdk_nvme_kv_opcode`/status-code additions in `nvme_spec.h`) only
landed upstream in SPDK **v26.05** (released 2026-05-29). A tree cloned at
an older tag/branch — or `SPDK_VERSION` overridden to something earlier —
builds and configures cleanly and only fails here, which is the entire
point of this check: catching it immediately after the build that would
produce the missing symbols, rather than minutes later at the plugin's own
link step.

**Fix:**
```bash
# [SMC1 or SMC2] — confirm what's actually in the built archive
nm -g "${SPDK_SRC}/build/lib/libspdk_nvme.a" | grep spdk_nvme_kv_store
grep -c KEY_DOES_NOT_EXIST "${SPDK_SRC}/include/spdk/nvme_spec.h"
cat "${SPDK_SRC}/VERSION"
```
If `nm` finds nothing, confirm `SPDK_VERSION=v26.05` (or later) in
`config/cluster.env`, then force a fresh clone:
```bash
sudo scripts/common/05-build-spdk-initiator.sh --force-clone
```
If `SPDK_INITIATOR_FLAVOR=fork` is set instead, the rsynced tree from SMC3
is what needs updating (SMC3's `SPDK_TARGET_FLAVOR=fork` tree is independent
of `SPDK_VERSION` entirely, since it's the kv_spdk fork, not upstream — see
`docs/ARCHITECTURE.md` §7 for why the two trees can legitimately be at
different versions).

---

### Stock upstream SPDK on the target: `bdev_kvmalloc_create` RPC not found

**Symptom:** `scripts/target/02-build-spdk-kv.sh`'s "Verifying build
artifacts" step reports `libspdk_bdev_kvmalloc.a` missing, or — if that
check were bypassed — `scripts/target/03-start-kv-target.sh` dies with
`bdev_kvmalloc_create` unrecognized by `rpc.py`, or `04-verify-target.sh`
reports no `SPDK_NVMe_KV`-command-set namespace despite the subsystem
existing.

**Cause:** `SPDK_TARGET_FLAVOR=upstream` was set (or `KV_SPDK_REPO` pointed
at something that isn't actually the kv_spdk fork). As of SPDK v26.05 the
NVMe-KV **initiator** API is upstream, but the **target** side is not:
there is no `bdev_kvmalloc` (or any KV bdev) module anywhere under
`module/bdev/`, and `lib/nvmf/ctrlr_bdev.c` still dispatches only NVM
command-set opcodes (READ/WRITE/FLUSH/DSM/WRITE_ZEROES) — no KV opcode
routing exists to reach. A stock v26.05 `spdk_tgt` builds fine and simply
cannot serve a KV namespace; this is expected behavior for that flavor, not
a broken build — see `docs/ARCHITECTURE.md` §7.

**Fix:** set `SPDK_TARGET_FLAVOR=fork` (the default) and supply
`KV_SPDK_REPO`/`KV_SPDK_REF` pointing at the actual kv_spdk fork:
```bash
# [SMC3]
KV_SPDK_REPO=<fork-url> KV_SPDK_REF=<ref> scripts/target/02-build-spdk-kv.sh --force-clone
```
Confirm afterward: `ls "${SPDK_TARGET_SRC}/build/lib/libspdk_bdev_kvmalloc.a"`
must exist. If it still doesn't after a clean clone of the URL you believe
is the fork, that URL isn't the fork — this repo cannot verify `KV_SPDK_REPO`
independently (it isn't vendored here — see README gap #2).

---

### `nvmf_create_transport` rejecting or ignoring `io_unit_size` on >=26.05

**Symptom:** on a target built from SPDK `>=26.05`, `nvmf_create_transport`
either rejects `-u "${NVMF_IO_UNIT_SIZE}"` outright, or accepts it but
`04-verify-target.sh`'s `io_unit_size` check (a `check_soft`, not `check`,
on this version) reports the transport's reported `io_unit_size` doesn't
match what was requested.

**Cause:** SPDK v26.05 deprecated `io_unit_size` (and `buf-cache-size`,
`num-shared-buffers`) in `nvmf_create_transport` to no-ops — the transport
now sizes its buffers from the iobuf pool instead
(`--iobuf-small-cache-size`/`--iobuf-large-cache-size`, driven by
`NVMF_IOBUF_SMALL_CACHE_SIZE`/`NVMF_IOBUF_LARGE_CACHE_SIZE` in
`config/cluster.env`). `scripts/target/lib-kv-rpc.sh`'s
`kv_target_build_transport_args()` probes `rpc.py nvmf_create_transport
--help` for those two flags before passing them (this repo does not vendor
kv_spdk, so its exact RPC surface on a given build isn't verified
statically) — if the fork's RPC surface names them differently, or doesn't
expose them at all, this is silently skipped, which itself is not a
failure but does mean the iobuf sizing may not be what you expect.

**Fix:** this is informational, not a hard failure, on `>=26.05` — the
`/16` SGL ratio (`kv_target_check_sgl()`) and any residual `io_unit_size`
behavior are both no longer a reliable predictor of transport-creation
success on this version. If `nvmf_create_transport` genuinely fails:
```bash
# [SMC3] — see what this specific tree's RPC actually accepts
"${SPDK_TARGET_SRC}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" nvmf_create_transport --help
```
and adjust `NVMF_IOBUF_SMALL_CACHE_SIZE`/`NVMF_IOBUF_LARGE_CACHE_SIZE`, or
fall back to setting `NVMF_MAX_IO_SIZE`/`NVMF_IO_UNIT_SIZE` more
conservatively, based on what that `--help` output actually documents for
this build. This does **not** change `KV_MAX_VALUE_SIZE`'s validated
default (524288) — see `docs/ARCHITECTURE.md` §7.

---

### RDMA plugin build (`-Denable_rdma=true`) fails because the initiator's SPDK tree wasn't built `--with-rdma`

**Symptom:** `meson setup build-nvme-kv -Denable_rdma=true ...` configures
successfully but `ninja -C build-nvme-kv` fails at the link step with an
undefined reference somewhere in the RDMA transport, or with `ar`/`ld`
unable to find `libspdk_nvme_rdma_only.a`.

**Cause:** `plugins/nvme-kv/prepare-spdk-libs.sh` only produces
`libspdk_nvme_rdma_only.a` if `nvme_rdma.o` is actually present inside
`libspdk_nvme.a` — which only happens if the SPDK tree at `${SPDK_SRC}` was
configured `--with-rdma` (`SPDK_WITH_RDMA=1` in `config/cluster.env`, the
default, when `scripts/common/05-build-spdk-initiator.sh` built it). A tree
built with `SPDK_WITH_RDMA=0` (or built before this option existed) simply
has no `nvme_rdma.o` to split out; `prepare-spdk-libs.sh` detects this with
`ar t | grep` and skips cleanly (prints "skipped — nvme_rdma.o not in
libspdk_nvme.a"), which is correct behavior for that tree — but it means
`-Denable_rdma=true` against that same tree has nothing to link.

**Fix:**
```bash
# [SMC1 or SMC2] — does this tree actually have the object?
ar t "${SPDK_SRC}/build/lib/libspdk_nvme.a" | grep nvme_rdma
ls "${SPDK_SRC}/build/lib/libspdk_nvme_rdma_only.a"   # should exist
```
If either is missing, confirm `SPDK_WITH_RDMA=1` and re-run
`scripts/common/05-build-spdk-initiator.sh --force-clone` (a plain re-run
without `--force-clone` will reuse the existing, non-RDMA `./configure`
output — the tree must be reconfigured, which for SPDK means rebuilding
from a clean checkout). Then re-run `plugins/nvme-kv/prepare-spdk-libs.sh`
(or just re-run the plugin's meson/ninja build, which invokes it) and
confirm `libspdk_nvme_rdma_only.a` now exists before retrying
`-Denable_rdma=true`.

---

### `hipErrorInvalidDevicePointer` / KV-cache registration failure

**Symptom:** vLLM fails during KV-cache tensor registration with the GPU
runtime reporting an invalid device pointer, or the NIXL/UCX VRAM_SEG
registration path throws around the same point in startup. (This is a
general ROCm/HIP allocator failure mode, not literal text this repo's
scripts have printed — flagged here because the fix is a specific, easy to
miss environment variable this repo already sets, and un-setting it, or
running any ad-hoc tooling that bypasses `${STACK_ROOT}/etc/env.sh`, will
reintroduce it.)

**Cause:** the HIP/PyTorch expandable-segments allocator can grow or
relocate the underlying virtual mapping backing an already-allocated tensor
at a later allocation. NIXL's VRAM_SEG registration path exports a HIP IPC
handle for the KV cache tensor so a peer process/agent can map the same
device memory; if the allocator moves the mapping after that export, the
peer's imported mapping silently goes stale.

**Fix:** confirm `PYTORCH_HIP_ALLOC_CONF=expandable_segments:False` is
actually in effect for the running process — it's baked into
`${STACK_ROOT}/etc/env.sh` (`scripts/common/20-build-vllm-lmcache.sh`) and
re-exported by `scripts/common/start-vllm.sh`, so any launch path that
bypasses both (a hand-rolled `python -m vllm...` invocation, for instance)
will not have it set:
```bash
# [SMC1 or SMC2]
grep PYTORCH_HIP_ALLOC_CONF /proc/$(cat /run/kvstack/vllm-prefill.pid)/environ 2>/dev/null | tr '\0' '\n'
```

---

### `-ENOMEM` backpressure log storms and the enomem deadline

**Symptom:** repeated log lines about the submission queue being full
(`-ENOMEM`) and items being deferred.

**Cause:** this is **expected, benign backpressure**, not an error by
itself — SPDK's submission queue is momentarily full and the plugin retries
after the next round of completions drains it (see `ARCHITECTURE.md` §5.1).
The one-shot notice on first occurrence and the periodic throttled report
(`NIXL_KV_BACKPRESSURE_LOG_SEC`, default 60s) are both designed to be
visible without flooding the log.

**When it means a dead device, not benign backpressure:** if a *specific*
deferred item's age exceeds `NIXL_KV_ENOMEM_TIMEOUT_SEC` (default 30s,
`KV_ENOMEM_TIMEOUT_SEC` in `config/cluster.env`), the plugin fails that item
outright rather than retrying it again — this is the signal that the device
has stopped draining, not that it's momentarily busy. If you see the
storm continue past that deadline **and never resolve into completions**,
that is a dead/wedged device, not backpressure — check the target's health
(`scripts/target/04-verify-target.sh`) and hugepage/queue-depth headroom on
SMC3.

---

### Transfers hang, `checkXfer` returns `NIXL_IN_PROG` forever

**Symptom:** a STORE or RETRIEVE never completes; `checkXfer()` (or
whatever's spinning on it — `nixlbench`'s `waitXfer()`, LMCache's own
lookup timeout) never sees `NIXL_SUCCESS`/`NIXL_ERR_*`.

**Cause:** almost always a deferred item that dropped off the retry queue's
radar, or a device that stalled with work still outstanding and the
`-ENOMEM` deadline (previous entry) either disabled (`KV_ENOMEM_TIMEOUT_SEC=0`)
or not yet reached.

**Fix:** confirm `NIXL_KV_ENOMEM_TIMEOUT_SEC` is set to a sane nonzero value
(default is; only relevant if you've overridden it). If the deadline is
correctly configured and this still hangs indefinitely, the device itself
may be wedged in a way the deadline doesn't cover (e.g. `checkXfer` was
never actually reached because `postXfer` itself blocked) — check
`${LOG_DIR}/kv-target.log` on SMC3 for the target-side view of the same
transfer, and `${LOG_DIR}/vllm-<role>.log` for `NIXL_KV_DEBUG_XFER`
diagnostics if you set that env var (see the plugin's
`spdk_nvme_kv_backend.cpp` — it's inert unless set to a positive count).

---

### Half-stale / corrupted reads

**Symptom:** a RETRIEVE succeeds (no error from any layer) but the returned
bytes are wrong — either garbage, or a mix of old and new content.

**Cause:** `KV_MAX_VALUE_SIZE` was changed on a namespace that already had
data written under the *previous* value, without draining first. Nothing
records, alongside a stored object, what `max_value_size` it was split
under; a reader always recomputes `n = ceil(page_size / max_value_size)`
from the **current** configured value. If that value differs from what the
writer used, the reader derives a different set of sub-keys — some of which
still physically exist from the old split — and reassembles a page that is
part new-split data and part stale old-split data, with every individual
sub-read reporting success (the sub-key genuinely exists; it just belongs
to the wrong geometry). See `scripts/target/50-reset-namespace.sh`'s own
extended comment for the full mechanics.

**Fix:**
```bash
# [SMC3] — drain and recreate the namespace BEFORE writing anything under the new geometry
scripts/target/50-reset-namespace.sh
scripts/target/04-verify-target.sh
```
Going forward: **any** change to `KV_MAX_VALUE_SIZE` requires this reset
first. There is currently no geometry manifest that would let this be
detected automatically instead of prevented procedurally — see README gap
#7.

---

### Duplicate-key STORE rejections or read-back corruption with two deployments

**Symptom:** STOREs rejected as duplicate keys on a target that refuses
overwrite, or silent read-back corruption on one that allows it, when more
than one deployment (e.g. two independent P/D clusters, or a producer and a
receiver in a benchmark tool) share the same NVMe-KV namespace.

**Cause:** this only affects callers on the `metaInfo`-**less** key path
(`kv_io.py`, `nixlbench` — anything that never sets `nixlBlobDesc::metaInfo`).
That path derives the on-wire key from `devId`/`addr`, and `devId` is a
storage-pool slot index each caller's `NixlObjPool` allocates independently
starting from 0 — two independent deployments collide on their early slot
indices. LMCache's actual production path on this cluster always sets
`metaInfo` (content-derived keys — see `ARCHITECTURE.md` §3) and is **not**
affected by this.

**Fix:** give each deployment/tool a disjoint `KV_SLOT_OFFSET_PREFILL`/
`KV_SLOT_OFFSET_DECODE` (`config/cluster.env`) — e.g. deployment A uses
offsets `0`/`1048576` (the defaults), deployment B uses a disjoint pair.
This has no effect on LMCache's own OBJ-mode traffic (see
`gen-lmcache-config.sh`'s note that `kv_slot_offset` is a no-op once
`metaInfo` is set) — it's only load-bearing for tools on the devId/addr
path.

---

### Hugepage allocation short of requested

**Symptom:** `01-host-prep.sh` (any node) reports
`requested N hugepages, kernel granted M` with `M < N`, or
`00-preflight.sh` reports the same as a warning.

**Cause:** physically-contiguous 2 MiB pages become scarce as host uptime
fragments memory; the kernel silently grants fewer than requested rather
than erroring on the allocation itself. A short-allocated pool means
`spdk_env_init()` (embedded in every SPDK-based process — the target and
the initiator plugin both) gets less DMA-capable memory than it needs and
fails to start with a message that gives no hint the actual cause is
fragmentation.

**Fix:** if short by more than ~10%, **reboot the host** before re-running
the host-prep script — this is the only reliable way to get a fresh,
unfragmented pool. If a reboot isn't available, lower `HUGEPAGE_COUNT` in
`config/cluster.env` and accept a smaller SPDK buffer pool (may reduce
`KV_NUM_QPAIRS` headroom).

---

### NVMe-oF/TCP stalls only on large transfers

**Symptom:** small requests (health checks, NVMe-oF connect/keepalive, UCX
handshake) all work fine; anything KV-page-sized stalls or hangs partway
through, with no error anywhere.

**Cause:** a jumbo-frame MTU mismatch somewhere along the physical path
(one hop still at 1500 while the endpoints are configured for 9000). Small
packets sail through untouched; only payloads that actually need the full
9000-byte MTU get black-holed at the mismatched hop (common when a firewall
or switch silently drops oversized frames instead of returning ICMP
"fragmentation needed").

**Fix:**
```bash
# [any] — active path-MTU probe, not just local interface config
scripts/verify/10-verify-network.sh
```
Look at its "MTU: local interface + active path-MTU probe" section — a
`WARN` there (path MTU ~1500 despite a 9000-configured local interface)
means some hop in between (a switch, a bond member, a VLAN) needs its MTU
fixed too; fixing only the two endpoints is not sufficient.

---

### Model load appears hung

**Symptom:** `scripts/prefill/03-start-prefill.sh` /
`scripts/decode/03-start-decode.sh` sit at "waiting for health" for a long
time.

**Cause:** likely not actually hung — an 8x MI300X TP=8 load of the default
`MODEL` (`Qwen/Qwen2.5-72B-Instruct`, ~145 GB bf16) with
`--enable-prefix-caching` (weight sharding, warmup, HIP-graph capture) can
legitimately take many minutes. `scripts/common/start-vllm.sh`'s
`wait_for_http` call uses an 1800s timeout specifically because this is a
**floor**, not a target. If the weights weren't already on local disk under
`HF_HOME`, the first-time HuggingFace download at this size dominates the
wall clock and looks indistinguishable from a hang — see `BRINGUP.md` §0's
note on pre-staging it.

**Fix:** tail the actual log before assuming it's stuck:
```bash
# [SMC1 or SMC2]
tail -f "${LOG_DIR}/vllm-prefill.log"     # or vllm-decode.log
```
If it's still making progress (downloading/loading shards, capturing
graphs) and hasn't hit 1800s, let it continue. If `MODEL` is larger still
(or a download from cold each time), or `GPU_MEM_UTIL` forces extra graph
re-capture passes, raise the timeout by editing `start-vllm.sh`'s
`wait_for_http` call or `VLLM_EXTRA_ARGS` as appropriate.

---

### Stale `/dev/shm/lmcache_*` crashes on restart

**Symptom:** a freshly-started `vllm-prefill`/`vllm-decode` process crashes
during its own init, right after a previous run of the same role was
SIGKILLed, OOM-killed, or otherwise crashed (rather than cleanly stopped).

**Cause:** LMCache's `local_cpu` tier and NIXL's registered-memory
bookkeeping both use `/dev/shm` segments as backing store for pinned host
buffers. A killed-not-stopped process can leave these behind; the new
process may try to reuse a segment whose size/generation no longer matches
what it expects.

**Fix:**
```bash
# [SMC1 or SMC2]
scripts/prefill/99-stop.sh --clean-shm      # or scripts/decode/99-stop.sh --clean-shm
```
Removes stale `/dev/shm/lmcache_*` and `/dev/shm/nixl_*` segments. Safe to
run any time the corresponding role isn't running (or right after stopping
it, before the next start).

---

### `KeyError: 'LMCacheConnectorV1'`

**Symptom:** vLLM raises `KeyError: 'LMCacheConnectorV1'` deep inside
`vllm.distributed.kv_transfer.kv_connector.factory`, after both packages
installed cleanly and vLLM starts constructing its connector.

**Cause:** a version mismatch between the installed `vllm` and `lmcache`
packages. The vLLM `KVConnector` plugin API and LMCache's
`LMCacheConnectorV1` implementation of it move independently; there is no
error at `pip install` time to catch a mismatched pair, only at connector
construction time.

**Fix:** re-install the pinned pair together, never independently:
```bash
# [SMC1 or SMC2]
VLLM_VERSION=0.28.0 LMCACHE_VERSION=0.5.4 scripts/common/20-build-vllm-lmcache.sh
```
If you need different versions than the defaults, change `VLLM_VERSION`/
`LMCACHE_VERSION` together and re-run on **both** SMC1 and SMC2 — a mismatch
between what SMC1 and SMC2 have installed is just as much a problem as a
mismatch within one node.

---

### RDMA mode connects anyway over TCP

**Symptom:** `KV_TRANSPORT=rdma` is set, but the compute-leg connection
appears to still be using TCP instead of failing or using RDMA verbs.

**Cause:** this should not happen by design —
`scripts/common/lib.sh`'s `setup_ucx_env` **deliberately excludes** `tcp`
from `UCX_TLS` in RDMA mode (`UCX_TLS="rc_verbs,rc_mlx5,dc,ud,self,sm"`,
no `tcp`) specifically so that a broken or half-configured RoCE fabric
fails loudly instead of silently falling back. If you're observing a TCP
fallback anyway, either something is bypassing `setup_ucx_env` entirely
(a hand-launched vLLM process, or `UCX_TLS` exported earlier in the
environment overriding what this function sets), or you're actually
looking at the **storage leg**, not the compute leg — the storage leg's
initiator-side RDMA support does not exist yet at all (see `BRINGUP.md`
§9.1); if `KV_TRANSPORT=rdma` but the plugin was never rebuilt with an RDMA
transport object, `create_backend()` should fail outright rather than
connect over TCP, because the TRID string passed to it says
`trtype:RDMA` and there is no downgrade path — a "successful" connection in
that state would itself be worth investigating as a bug.

**Fix:** confirm nothing pre-sets `UCX_TLS` before `setup_ucx_env` runs;
confirm which leg you're actually observing (`ss -tnp` toward
`${TARGET_HOST}:${NVMF_TRSVCID}` is the storage leg;
`${NIXL_SIDE_CHANNEL_PORT}` between SMC1 and SMC2 is the compute leg).

---

## Diagnostic commands appendix

**Log files** (`${LOG_DIR}`, default `/var/log/kvstack`):

| File | Node | grep for |
|---|---|---|
| `vllm-prefill.log` | SMC1 | `SPDK_NVMe_KV`, `NIXL_ERR`, `unsupported backend`, `Traceback` |
| `vllm-decode.log` | SMC2 | `SPDK_NVMe_KV`, `hit tokens`, `NIXL_ERR`, `unsupported backend` |
| `kv-target.log` | SMC3 | `SPDK_NVMe_KV`, `NIXL_ERR`, `SGL length`, `ENOMEM` |
| `disagg-proxy.log` | wherever the proxy runs | request IDs (`X-Request-Id`) to correlate a client request across prefill/decode logs |

```bash
grep -E 'SPDK_NVMe_KV|NIXL_ERR|unsupported backend|hit tokens' \
    /var/log/kvstack/vllm-decode.log | tail -50
```

**`rpc.py` inspection (SMC3 — `SPDK_TARGET_SRC`, the target's own fork tree,
not `SPDK_SRC`, which is the SMC1/SMC2 initiator tree as of SPDK v26.05):**

```bash
"${SPDK_TARGET_SRC}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" spdk_get_version
"${SPDK_TARGET_SRC}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" nvmf_get_transports
"${SPDK_TARGET_SRC}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" nvmf_get_subsystems
"${SPDK_TARGET_SRC}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" bdev_get_bdevs
```
(`scripts/target/lib-kv-rpc.sh`'s `rpc_json()` is a one-line wrapper around
the same invocation — source it from a shell that's already sourced
`scripts/common/lib.sh` to reuse it directly.)

**Socket/connection state:**

```bash
ss -tnp | grep ":${NVMF_TRSVCID}"          # NVMe-oF/TCP connections (initiator or target side)
ss -tnp | grep ":${NIXL_SIDE_CHANNEL_PORT}" # compute-leg NIXL/UCX side channel
nvme list-subsys                            # [SMC1/SMC2] confirm NVMe-oF controller attachment
nvme discover -t tcp -a "${NVMF_TRADDR}" -s "${NVMF_TRSVCID}"   # [SMC1/SMC2]
```

**NIXL plugin introspection (Python, from `${VENV}`):**

```bash
"${VENV}/bin/python" -c "
from nixl._api import nixl_agent, nixl_agent_config
a = nixl_agent('diag', nixl_agent_config(backends=[]))
print(a.get_plugin_list())
print(a.get_plugin_params('SPDK_NVMe_KV'))
"
```

**GPU state (SMC1/SMC2):**

```bash
rocm-smi --showid
rocm-smi --showmeminfo vram
rocminfo | grep -i gfx
```

**RDMA fabric state (Phase 2):**

```bash
ibv_devinfo
rdma link show
```
