# LMCache patches — SPDK_NVMe_KV / XNVME_KV backend allowlist

## Why this exists

Stock LMCache (this repo pins `LMCACHE_VERSION=0.5.4`, see
`scripts/common/20-build-vllm-lmcache.sh`) hardcodes two separate allowlists
of NIXL backend names inside
`lmcache/v1/storage_backend/nixl_storage_backend.py`:

1. **`NixlStorageConfig.validate_nixl_backend()`** — asserts the configured
   `nixl_backend` is one of a fixed set of upstream-known names (observed in
   this codebase's own introspection as roughly `GDS`/`GDS_MT`/`OBJ` (cpu or
   cuda) and `POSIX`/`HF3FS`/`AZURE_BLOB`/`DOCA_MEMOS` (cpu only) — see
   `scripts/common/gen-lmcache-config.sh`'s "THE BACKEND-ALLOWLIST RISK"
   section, which is where this project's own prior investigation of this
   exact function is recorded). `SPDK_NVMe_KV` and `XNVME_KV` are not in
   that list.
2. **`NixlDynamicStorageAgent.__init__`** — separately decides the NIXL
   `mem_type` to use for a backend by a second hardcoded name check
   (`backend in ("OBJ", "AZURE_BLOB", "DOCA_MEMOS")` -> `OBJ` mem_type,
   else -> `FILE` mem_type). `SPDK_NVMe_KV`/`XNVME_KV` fall into the `FILE`
   branch there too.

Unpatched, a deployment configured with `nixl_backend: "SPDK_NVMe_KV"` (see
`scripts/common/gen-lmcache-config.sh`) hits one of two failure modes:

- **Loud failure**: `validate_nixl_backend()` raises
  `AssertionError: Invalid NIXL backend & device combination` the first time
  the NIXL storage backend is constructed, before a single byte reaches the
  plugin. Annoying, but at least honest.
- **Silent, dangerous failure**: if a version/code-path skips or has already
  passed the first check, `NixlDynamicStorageAgent.__init__` puts
  `SPDK_NVMe_KV`/`XNVME_KV` on the `FILE` mem_type path. LMCache then does
  real `os.open()`/`os.path.join(extra_config.nixl_path, key)` calls against
  the **local filesystem** of whichever node ran the store — never touching
  SMC3 at all. The server starts, answers `/health`, serves every request,
  and nothing anywhere logs an error. The only way this class of bug is
  ever caught is a live P/D cache-hit test that comes back suspiciously
  empty (see `plugins/nvme-kv/spdk_nvme_kv_backend.h`'s `queryMem()` comment
  for the twin transport-layer version of this exact failure mode, and
  `scripts/verify/30-verify-kv-roundtrip.sh` / `40-verify-disagg.sh` in this
  repo for the tests that catch it).

Both name lists live in the SAME source function pair that
`scripts/common/25-validate-lmcache-config.sh` already introspects (via
`inspect.getsource`) to *detect* this problem. This patch is what actually
*fixes* it, so that validator passes for real instead of reporting the
condition it was written to catch.

### The second, independent reason: the multipart-split / `max_value_size` mismatch

The SPDK_NVMe_KV plugin advertises `max_value_size = 524288` (512 KiB) via
its NIXL `getParams()` callback (`plugins/nvme-kv/spdk_nvme_kv_plugin.cpp`).
That number is **not** a device limit — it is derived from the NVMe-oF/TCP
transport's SGL ceiling (`nvmf_tcp_create()` rejects `max_io_size` above
roughly `max_io_size / io_unit_size(131072) > SPDK_NVMF_MAX_SGL_ENTRIES(16)`,
i.e. ~2 MiB, and this repo's target is configured for `max_io_size=1048576`
— see `config/cluster.env`'s `NVMF_MAX_IO_SIZE`/`NVMF_IO_UNIT_SIZE` comments)
with headroom left for NVMe/TCP PDU framing overhead.

A single LMCache KV page, however, is typically several MB —
`chunk_size=256` tokens (`LMCACHE_CHUNK_SIZE` in `config/cluster.env`)
works out to roughly **5.7 MB** for common 8B-class models. Handed to the
plugin as one descriptor, the target rejects it outright with
`"SGL length ... exceeds max io size"`
(`plugins/nvme-kv/spdk_nvme_kv_plugin.cpp`'s comment on this exact failure,
found 2026-08-18 wiring up the storage target). LMCache's own upstream NIXL
storage backend has no built-in awareness that a single backend might want
a value ceiling smaller than the page it's handed — it has to be told to
split. That is the second half of what this patch family provides: ensuring
the OBJ-mode code path in the installed LMCache actually reads
`max_value_size` (rather than assuming its own OBJ-pool backends, whose
`max_value_size` are effectively unbounded, e.g. object storage or a local
POSIX filesystem) and chops a value larger than it into
`ceil(page_size / max_value_size)` sub-transfers before handing them to
`create_backend()`-constructed backend's `postXfer()`.

Older comments in `plugins/nvme-kv/spdk_nvme_kv_plugin.cpp` and
`plugins/xnvme-kv/xnvme_kv_plugin.cpp` refer to this same patch family by
number under a different, now-stale path prefix:
`stack/tracks/lmcache/patches/0002-*.patch` /
`0003-*.patch`. That prefix reflects an earlier monorepo layout this repo
was extracted from. **This directory (`patches/lmcache/`) is the current,
canonical location** — the numbered-patch comments elsewhere in this repo
have not been rewritten (out of scope for this change) but describe the
same underlying fix.

## Exactly what version this targets

```
LMCACHE_VERSION=0.5.4   (default; see scripts/common/20-build-vllm-lmcache.sh)
```

`apply-patches.sh` reads the version straight out of the **installed**
package (`python -c "import lmcache; print(lmcache.__version__)"`) rather
than assuming 0.5.4 — if you've bumped `LMCACHE_VERSION` and rebuilt the
venv, this patch targets whatever actually got installed, and says so in
its output and in the `applied-<version>.diff` filename.

## Why this ships as a generator script, not a `.patch` file

A traditional unified-diff `.patch` file is fragile against ANY drift in
the installed LMCache source — a single reflowed line, renamed variable, or
patch-version bump (0.5.4 -> 0.5.5) and `patch`/`git apply` either fails
outright (safe, but blocks bring-up) or, worse, applies to the wrong
context silently. Given how undocumented and internal these two functions
are (see `scripts/common/25-validate-lmcache-config.sh`'s own header
comment on this), a context diff shipped once and never re-verified is
exactly the kind of thing that looks correct and is quietly wrong.

`apply-patches.sh` instead:
- locates the **installed** LMCache tree in `${VENV}` at apply time,
- scans it (via Python's `tokenize`/`ast`, not `sed`/regex-on-whole-file)
  for the actual allowlist site(s) as they exist in what's installed RIGHT
  NOW,
- fails loudly if it finds none (the assumption above has gone stale — see
  "What is ASSUMED" below),
- and prints + saves a unified diff of exactly what it did, so a human
  reviews the real, current transformation instead of trusting a diff
  written against a source tree nobody here re-diffed.

## How to apply

```
scripts/common/20-build-vllm-lmcache.sh          # installs LMCache into ${VENV} first
patches/lmcache/apply-patches.sh                  # applies, backs up, prints diff
scripts/common/25-validate-lmcache-config.sh <cfg-file>   # confirms it took
```

Flags:
- `--dry-run` — show what WOULD change, write nothing, exit 0.
- `--force` — required to re-run after a prior successful apply (reverts the
  prior apply from its `.orig-kvstack` backups first, then re-applies
  fresh — never stacks edits on top of edits).
- `--revert` — restore every patched file from its `.orig-kvstack` backup
  and stop (does not re-apply).

## How to verify it took

Three independent checks, cheapest first:

1. `patches/lmcache/apply-patches.sh --dry-run` reports "already applied,
   0 new edits" instead of finding fresh candidates.
2. `scripts/common/25-validate-lmcache-config.sh <lmcache.yaml>` — its
   "NIXL backend allowlist (installed LMCache source)" section must print
   `ACCEPTED` for both `validate_nixl_backend()` and the OBJ mem_type
   check, not `FAIL`.
3. `scripts/verify/30-verify-kv-roundtrip.sh` and
   `scripts/verify/40-verify-disagg.sh` — the only checks that prove data
   actually crosses the network instead of merely proving the config is
   internally consistent.

## What is VERIFIED vs. what is ASSUMED

This project has **no ability to fetch or diff the real upstream LMCache
0.5.4 source tree from this environment** (no installed `lmcache` package,
no network fetch of PyPI/GitHub performed as part of writing this patch).
Being honest about that boundary is the entire point of this section.

**VERIFIED** (grounded in files that already exist in this repo, written by
a prior agent who — per this repo's own comments — DID have the installed
source in front of them):
- The module path: `lmcache.v1.storage_backend.nixl_storage_backend`
  (imported successfully by `scripts/common/25-validate-lmcache-config.sh`
  against a real install; that script degrades to a `WARN` rather than
  crashing if the import fails, which is itself evidence the path was
  confirmed to work at least once).
- The two function names: `NixlStorageConfig.validate_nixl_backend` and
  `NixlDynamicStorageAgent.__init__`. Both are `inspect.getsource()`'d by
  `25-validate-lmcache-config.sh` today — meaning both exist and are
  introspectable in whatever LMCache version was installed when that script
  was written.
- The failure message text `AssertionError: Invalid NIXL backend & device
  combination`, quoted verbatim in `scripts/common/gen-lmcache-config.sh`.
  This specific wording implies the real assertion is checking a
  **(backend, device) pair**, not a bare backend name — i.e. the allowlist
  is plausibly a collection of 2-tuples (`("GDS", "cuda")`,
  `("POSIX", "cpu")`, ...), not a flat set of strings. `apply-patches.sh`
  handles BOTH shapes (flat string collection, and collection-of-tuples
  keyed on the first element) for exactly this reason — see its
  `_patch_file()` docstring.
- `nixl_backend_params` (`trid`, `max_value_size`, `kv_slot_offset`) is read
  structurally (not via individual `extra_config.get("nixl_backend_params")`
  calls) per `25-validate-lmcache-config.sh`'s comment — i.e. LMCache passes
  this dict through to `create_backend()` more or less verbatim. This is
  why the multipart-split half of this fix targets consumption of
  `max_value_size` inside the OBJ dynamic-storage code path rather than
  `nixl_backend_params` itself.
- The plugin-side contract this patch has to satisfy:
  `plugins/nvme-kv/spdk_nvme_kv_backend.h` documents `getSupportedMems()`
  returning `{DRAM_SEG, VRAM_SEG, FILE_SEG, OBJ_SEG}` and states plainly:
  *"OBJ_SEG alongside FILE_SEG: LMCache's key-addressed storage pool
  (NixlObjectPool) uses OBJ_SEG descriptors, handled identically to FILE_SEG
  in registerMem()/prepXfer() below."* That is the exact behavior this
  patch's mem-type-dispatch fix needs LMCache to produce for
  `SPDK_NVMe_KV`/`XNVME_KV`: treat them exactly like `OBJ` is already
  treated, nothing more exotic.

**ASSUMED** (best-effort, and the reason `apply-patches.sh` refuses to
succeed silently if these assumptions don't hold against what's actually
installed):
- The EXACT literal syntax of the two allowlists in the installed 0.5.4
  source (flat tuple vs. set-of-tuples vs. something else entirely).
  `apply-patches.sh`'s scanner is written to handle the shapes described
  above but this has not been confirmed against real upstream source in
  this environment.
- That both allowlists live in files whose path contains the substring
  `nixl` (case-insensitive). This matches the one confirmed module path
  above; if a future LMCache version moves this logic to a differently
  named file, `apply-patches.sh` will find zero candidates and refuse to
  proceed (see its "FAIL LOUDLY on zero sites" behavior) rather than
  silently doing nothing.
- That extending the allowlist(s) alone is sufficient — i.e. that no OTHER
  code path elsewhere in LMCache (a third hardcoded list, a schema
  validator, a CLI arg choices=[...]) also gates on backend name. The
  scanner searches the WHOLE nixl-path-matching subtree, not just the two
  named functions, specifically to reduce this risk, but "the whole
  installed tree, searched today" is still a weaker guarantee than a
  diff against a known-good upstream tag.
- The NIXL python API surface used by `scripts/verify/20-verify-nixl-plugin.sh`
  and `scripts/verify/30-verify-kv-roundtrip.sh` (`nixl_agent`,
  `nixl_agent_config`, `create_backend`, `register_memory`,
  `get_reg_descs`/`get_xfer_descs`, `initialize_xfer`, `transfer`,
  `check_xfer_state`, `release_xfer_handle`, and a `query_memory`-shaped
  call for the `queryMem()` existence probe) is modeled on the public NIXL
  project's conventions and on the two calls this repo's own
  `25-validate-lmcache-config.sh` already uses successfully
  (`get_plugin_list`, `get_plugin_params`) — extended by inference for the
  calls that script doesn't happen to exercise. Those verify scripts print
  the exact `AttributeError`/exception if a given call doesn't exist on the
  installed NIXL build, rather than masking it, so a wrong guess fails
  loudly and specifically instead of silently passing.

If you have the ability to install the real `lmcache==0.5.4` wheel and
diff it yourself, doing so and replacing this file's ASSUMED section with
VERIFIED facts (and, ideally, a captured `applied-0.5.4.diff` committed
alongside this README) is strictly better than trusting this document.
That diff is exactly what running `patches/lmcache/apply-patches.sh` on a
real node produces.
