# patches/lmcache/ — what the vendor image already carries, and the one thing it doesn't

**Nothing in this directory is applied by this repo's scripts.** There is no
`apply-patches.sh`, and nothing in `scripts/` runs `git am`/`patch` against
these files. LMCache reaches this cluster as a prebuilt vendor container image
(`rocm-aic:mp-pd-ionic2609`), patched at **image-build time** in a sibling
build repo this repo does not have access to.

This directory is therefore a **verification contract**, not a build step: it
records which LMCache modifications the running stack depends on, how to check
a new image still has them, and what breaks if it doesn't.

## Policy (changed 2026-09-17)

> **If the vendor image ships it, we do not carry the diff.** The image is the
> source of truth; this README is the record of what that truth must contain.
>
> `0006`, `0007`, `0008` and `0009` were verified present in
> `rocm-aic:mp-pd-ionic2609` and their `.patch` files were **deleted** on that
> basis. They are still documented below, and still checked by the recipe
> below, because "the vendor ships it" is a claim with a shelf life on this
> project — see the correction record at the bottom of this file.
>
> Only a patch that is **NOT** in the image, and that we therefore have to
> apply ourselves, is carried here as a diff. Today that is exactly one:
> **`0011`**.

## Status of every LMCache modification this stack depends on

Re-measured against the running image 2026-09-17 (see the recipe below for the
exact commands and their output).

| Patch | In image? | Diff carried here? | Status on the live path | What it does | If a future image lacks it |
|---|---|---|---|---|---|
| `0006` accept `SPDK_NVMe_KV`/`XNVME_KV` in the L2 adapter (`v1/distributed/l2_adapters/nixl_store_l2_adapter.py`) | **YES** | no — deleted | **LIVE** | Adds both names to two allowlists: the `elif self.backend in [...]` branch routing a backend to `init_storage_handlers_object`/`mem_type="OBJ"`, and `_VALID_NIXL_BACKENDS` (the config-time validator). | **LOUD.** The MP daemon rejects `backend: XNVME_KV` in its `--l2-adapter` JSON — `25-validate-lmcache-config.sh` fails before the daemon spawns, or the daemon dies constructing the NIXL backend. Re-deriving it is two string literals in two lists. |
| `0007` split L2-adapter stores exceeding `max_value_size` (same file) | **YES** | no — deleted | **DORMANT** — `page_size=4096 ≤ max_value_size=32768`, so `_resolve_mem_split()` returns 1 and the `#{j}` path never executes | Adds `mem_split_n`/`_resolve_mem_split()` (queries the backend's declared `max_value_size` via `get_plugin_params()`), splits `init_mem_handlers()`/`init_storage_handlers_object()` descriptor lists, and suffixes each sub-part's storage key `#{j}`. **Origin of the `mem_split_n`/`#{j}` scheme — not upstream LMCache.** | **SILENT.** A page larger than the backend ceiling either fails outright or collapses all sub-parts onto one key and overwrites — the store returns success and only the last sub-part's bytes are retrievable. Only reachable if `--l1-align-bytes` rises above `max_value_size`. |
| `0008` accept both names in `v1/storage_backend/nixl_storage_backend.py` | **YES** | no — deleted | **UNUSED** — the in-process `LMCacheConnectorV1` path was removed from this repo (TODO 6.23) | Adds both names to `validate_nixl_backend()`, to the `mem_type="OBJ"` selection in `NixlDynamicStorageAgent.__init__`, and to the pool-selection branch. | Loud, and nothing here runs that path. Kept in the table only because `25-validate-lmcache-config.sh` introspects that function pair. |
| `0009` derive the K/V plane count instead of assuming 2 (`integration/vllm/vllm_service_factory.py`, `v1/gpu_connector/gpu_connectors.py`) | **YES** | no — deleted | **LIVE** — this stack presents a **fused** cache (`kv=1` in the daemon log's `shape_desc`) | Adds `_aic_kv_plane_count()`, asking vLLM's attention backend via `get_kv_cache_shape()` whether the cache is fused (rank-4, `2*head_size` trailing axis) or split (rank-5, leading axis 2). Carries the answer through `metadata.kv_shape` and cross-checks against the real tensors at first use. | **SILENT, AND TOTAL.** The unpatched "2 split planes" assumption has the same total byte count but a wrong per-token stride: the copy kernel stores half the tokens from wrong offsets and never writes the V plane. **Every chunk is corrupt, nothing raises.** This is the highest-consequence entry in this table. |
| `0011` gate `LMCacheMPConnector`'s load path on `num_external_tokens` (`integration/vllm/lmcache_mp_connector.py`) | **NO** | **YES — carried, and applied by us at run time** | **LIVE — applied by overlay** | One-line guard: `condition = num_external_tokens > 0 and tracker.needs_retrieve()` (image has the bare `tracker.needs_retrieve()`). | Already the case — see below. |

### `0011` is NOT in the image, and we run the composition it guards

Measured 2026-09-17: line 1141 of the image's
`lmcache/integration/vllm/lmcache_mp_connector.py` reads

```python
condition = tracker.needs_retrieve()
```

— the unpatched form. The vLLM-side sibling copy (`0010`) is unpatched too.

This matters because this cluster runs
`MultiConnector[NixlConnector, LMCacheMPConnector]`. Since vLLM #46865 a
**non-chosen** `MultiConnector` sub-connector receives the request's real
blocks with `num_external_tokens=0`. Without the guard,
`update_state_after_alloc()` decides purely on `tracker.needs_retrieve()`,
wrongly moves `PREFETCHING → WAITING_FOR_LOAD`, and creates a retrieve task
for a load that must not happen. The same `condition` then selects the
lock-release range, so only `num_vllm_hit_tokens` is freed instead of
`num_lmcache_hit_tokens` — **the difference leaks**, and `end_session()` does
not release lookup locks either.

### How `0011` is applied: a runtime overlay, derived not vendored

`scripts/common/container.sh lmcache-patch` derives the override **from the
image's own copy** and `cmd_up` bind-mounts it read-only over the installed
module. Same mechanism `container.sh` already uses for vLLM's
`nixl_utils.py` and for the repo-built `libplugin_XNVME_KV.so`.

```
container.sh lmcache-patch          # writes /opt/kvstack/lmcache-patch/
container.sh up <prefill|decode>    # mounts it; derives first if absent
```

Deriving beats vendoring a static file here: bumping `KVSTACK_IMAGE` cannot
silently reinstate a stale copy of a module LMCache is still editing. The
transform refuses to emit anything it cannot justify —

| Condition | Behaviour |
|---|---|
| image already carries the guard | copies through, logs `already patched image-side` |
| target line absent, or present more than once | **dies** — the file no longer has the shape 0011 rewrites |
| target line is not inside `update_state_after_alloc` | **dies** — `num_external_tokens` would not be in scope, so the override would raise `NameError` at request time |
| derived file lacks the guard, or is not valid Python | **dies** before mounting |

All five paths were exercised against the real module 2026-09-17 (one
success control, four deliberate failures) — `container.sh`'s own guards are
checked the same way its `nm`-based `plugin-build` check is.

**The target is resolved with `importlib.util.find_spec()`, not a filesystem
`find`.** `find / -path '*/lmcache/integration/vllm/lmcache_mp_connector.py'`
matches **three** files in this image — `dist-packages`, the `/app/LMCache`
source tree, and `/app/LMCache/build/lib.*` — and `cmd_vllm_patch`'s
`-print -quit` idiom would take whichever `find` reached first. Mounting over
a build-tree copy is a **silent no-op**: Python imports from `dist-packages`
and the guard would simply never be there. `find_spec()` returns the module
the interpreter will actually import, which is the only definition of "the
right file" that matters here. It needs no GPU (LMCache falls back to
`StubCPUDevice`).

`0011`'s own patch header documents the two-copy trap: `KVConnectorFactory`
registers `LMCacheMPConnector` against the vLLM module, but that module's
`_resolve_lmcache_mp_connector()` prefers
`lmcache.integration.vllm.lmcache_mp_connector` when LMCache is importable —
which it is. So **this** file is the live one, and `0010` alone is a no-op on
a stock deployment.

## Re-verification recipe

Copy-pasteable. Run this against any **new** image before trusting it. Each
check greps for a string that exists **only** in the patched form.

```bash
IMG=rocm-aic:mp-pd-ionic2609
L=/usr/local/lib/python3.12/dist-packages/lmcache

docker run --rm --entrypoint bash "$IMG" -lc '
L=/usr/local/lib/python3.12/dist-packages/lmcache
fail=0
chk() { # chk <label> <file> <regex-only-true-when-patched>
  if grep -qE "$3" "$2"; then echo "OK   $1"; else echo "MISS $1"; fail=1; fi
}

chk 0006a "$L/v1/distributed/l2_adapters/nixl_store_l2_adapter.py" \
    "elif self\.backend in \[.*\"XNVME_KV\"\]"
chk 0006b "$L/v1/distributed/l2_adapters/nixl_store_l2_adapter.py" \
    "^_VALID_NIXL_BACKENDS|\"XNVME_KV\","
chk 0007  "$L/v1/distributed/l2_adapters/nixl_store_l2_adapter.py" \
    "def _resolve_mem_split"
chk 0008  "$L/v1/storage_backend/nixl_storage_backend.py" \
    "XNVME_KV"
chk 0009  "$L/v1/gpu_connector/gpu_connectors.py" \
    "_aic_kv_plane_count"
chk 0011  "$L/integration/vllm/lmcache_mp_connector.py" \
    "num_external_tokens > 0 and tracker\.needs_retrieve\(\)"

exit $fail'
```

Expected against `rocm-aic:mp-pd-ionic2609` as of 2026-09-17:

```
OK   0006a
OK   0006b
OK   0007
OK   0008
OK   0009
MISS 0011      <-- expected: the IMAGE lacks it. It is applied at run time
                   by container.sh's overlay, so this recipe (which reads the
                   image) reporting MISS is correct and not a problem. To
                   check the RUNNING stack instead, see below.
```

To verify the guard is live in a **running** container — which is what
actually matters — ask Python where it imports the module from, so a mount
over the wrong copy cannot fool you:

```bash
docker exec kvstack-prefill python3 -c '
import importlib.util
p = importlib.util.find_spec("lmcache.integration.vllm.lmcache_mp_connector").origin
print("0011 guard present:", "num_external_tokens > 0 and tracker.needs_retrieve()" in open(p).read())
print("path:", p)'
# expected: 0011 guard present: True
```

> **A `MISS` on `0006`–`0009` means the image regressed.** For `0006`/`0008`
> re-add the backend names by hand (two string literals each). For `0007` and
> `0009` the diffs are **no longer in this repo** — recover them from git
> history (`git log --diff-filter=D -- patches/lmcache/`) or from the sibling
> build repo. `0009` in particular must not be run without: its absence
> corrupts every chunk silently.

## Keep `_kv_roundtrip.py` and `0007` in agreement

`0007`'s `#{j}` sub-key scheme is **hand-mirrored, not imported**, by
`scripts/verify/_kv_roundtrip.py`'s multipart handling. If a future image
changes the suffix scheme, the split arithmetic
(`ceil(page_size / max_value_size)`) or sub-part ordering, `_kv_roundtrip.py`
must change with it or the roundtrip verify silently stops testing the
property it exists to test. See `scripts/verify/30-verify-kv-roundtrip.sh`'s
header.

## Numbering gap

`0001`–`0005`, `0010`, `0012`, `0013` exist in the upstream patch series this
set was extracted from but are not LMCache patches:

- `0001`–`0004` — SPDK NVMe-KV command-set patches, see
  [`patches/spdk/README.md`](../spdk/README.md).
- `0005`, `0012`, `0013` — vLLM/Dockerfile patches, out of scope here.
- `0010` — `0011`'s sibling, the same guard applied to vLLM's *own* builtin
  `LMCacheMPConnector` copy. Also absent from the image, but it only covers
  the `LMCACHE_USE_UPSTREAM_MP` / ImportError fallback, which this deployment
  does not take.

## Provenance (sha256)

Only the diff still carried here:

```
7f0eac137c783108fe854be17c7ee19d2d2bc85ac838df4020ff68cf05afb8a1  0011-lmcache-guard-mp-connector-num-external-tokens.patch
```

Deleted 2026-09-17 after verifying the image carries them; sha256 recorded so
a copy recovered from git history or the sibling repo can be identity-checked:

```
14b8e693322422124de83f47c4aef70456fd5382c3f30889b10dbaca25a4c8bd  0006-lmcache-l2-adapter-kv-backends.patch
d6ab8d0ad3efc6bff77e185c2e11bc586db2f9231936a472dacd1911de04db39  0007-lmcache-l2-adapter-value-size-split.patch
bd8af542f1b795c644a1cd52a49da2df6a3fa1119ce3777cbdfc35a4b4712f8e  0008-lmcache-nixl-storage-backend-kv.patch
a43253d3596fcc22e500ef28bbda401f78ff9d0b96f0abae2701c11dd70edec2  0009-lmcache-fused-kv-plane-count.patch
```

## Correction record

**2026-09-17 (b) — the previous re-verification recipe produced a FALSE PASS
for `0011`, and this README asserted a result it had not actually measured.**
The old check was `grep -n 'num_external_tokens' lmcache_mp_connector.py`,
"expected: hits at lines 1103, 1117". Those two lines are the **function
signature and its docstring** — present in the *unpatched* file. The check
passed regardless of whether the patch was applied, and on that basis this
file claimed *"All five were re-checked this way … and matched the expected
output above exactly."* That claim was false: `0011` has never been in this
image. Every check in the recipe above now greps for a string that exists only
in the patched form. **Lesson (this project's §5 trap, one level up): a
verification recipe is code, and "it printed what I expected" is not the same
as "it could have printed otherwise."**

**2026-09-17 (a) — "the image accepts these backends unpatched" was false.**
An earlier pass correctly identified this repo's from-source LMCache patch
*generator* as dead code, and incorrectly concluded from "no marker string of
our own edits in the installed source" that the image needed no patch at all,
staging `git rm -r patches/lmcache/` on that premise. It was reverted before
commit. The image ships pre-patched; a conventional `.patch` applied at build
time leaves no marker string the way an in-repo generator's edits would.
**Lesson: "no marker of our tooling having run" is not evidence of "no patch"
when a different toolchain could have produced the same file.**

Note the difference between that correction and today's policy change: (a) was
deleting the record while believing the image was *unpatched*. Today's
deletion is the opposite — the image is **measured patched**, each entry keeps
a working check, and the one patch the image lacks is the one still carried.
