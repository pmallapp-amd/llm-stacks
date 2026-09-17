# patches/lmcache/ — LMCache patches baked into the vendor image

**These five `.patch` files are not applied by anything in this repo.**
They document, and let a future reader re-verify, patches that were already
applied when `rocm-aic:mp-pd-ionic2609` (the vendor image this lab actually
runs) was **built**, in a sibling build repo this repo does not have access
to. This directory is provenance and a re-verification recipe, not a build
step — there is no `apply-patches.sh` here and nothing in `scripts/`
invokes `git am`/`patch` against these files.

> **Correction, 2026-09-17 — read this before trusting anything else in
> this repo about "no patch needed".** An earlier pass through this repo
> today concluded that the LMCache installed in the vendor image "already
> accepts `SPDK_NVMe_KV`/`XNVME_KV` with no patch applied" and, on that
> premise, deleted this whole directory (the `git rm` was staged, then
> reverted before commit) and rewrote several docs to say no patch step is
> needed. **That was backwards.** The image accepts those backends
> *because it was built with these five patches applied* — not because
> stock LMCache 0.5.3 does. The docs this touched (`HANDOFF.md`,
> `TODO.md`, `BRINGUP.md`, `TROUBLESHOOTING.md`, `README.md`,
> `ARCHITECTURE.md`, the `scripts/verify/*` headers) each carry their own
> dated correction pointing back here — this file is now the single
> source of truth for what is and isn't patched.

## Why conventional `.patch` files, not the old generator

An earlier version of this directory carried a different mechanism
entirely: a shell entry point (`apply-patches.sh`) plus a Python
`tokenize`/`ast`-based scan-and-patch engine (`_patch_engine.py`) that
edited an **installed-from-source** LMCache in place. That generator
targeted `scripts/common/20-build-vllm-lmcache.sh`'s from-source install
path (`/opt/kvstack/venv`), which has never completed a build and is
deprioritised (`docs/TODO.md` §6.2) — this lab runs the prebuilt vendor
image instead, which never touches that venv. **The generator remains
withdrawn** (git history holds it) for exactly that reason: it targets a
code path this deployment does not exercise.

**The patches themselves are a different matter and are load-bearing.**
They were extracted from the sibling build repo that actually produces
`rocm-aic:mp-pd-ionic2609` and are conventional unified-diff `.patch`
files consumed at **image build time**, not by any generator or runtime
step in this repo. Different mechanism (a build-time patch vs. a
deploy-time source-scanning generator), same underlying intent (widen
LMCache's hardcoded NIXL-backend allowlists and fix the bugs that surface
once `SPDK_NVMe_KV`/`XNVME_KV` are live traffic instead of dead code).

## Per-patch table

| Patch | Subject | Target file(s) | What it does | Why it's needed |
|---|---|---|---|---|
| `0006` | accept `SPDK_NVMe_KV` and `XNVME_KV` in the L2 adapter | `lmcache/v1/distributed/l2_adapters/nixl_store_l2_adapter.py` | Adds both names to **two** allowlists in this file: the `elif self.backend in [...]` branch that routes a backend to `init_storage_handlers_object`/`mem_type="OBJ"`, and `_VALID_NIXL_BACKENDS` (the config-time validator). | This is the file the **MP daemon's `nixl_store` L2 adapter** actually uses — the live path this cluster runs (`start-lmcache-daemon.sh`'s `--l2-adapter` JSON). Without it, `backend: XNVME_KV`/`SPDK_NVMe_KV` in the `--l2-adapter` spec is rejected outright at daemon startup. |
| `0007` | split L2-adapter stores that exceed `max_value_size` | same file (`nixl_store_l2_adapter.py`) | Adds `mem_split_n` / `_resolve_mem_split()` (queries the backend's declared `max_value_size` via `get_plugin_params()` and computes how many sub-descriptors one page/slot needs), splits `init_mem_handlers()`/`init_storage_handlers_object()`'s descriptor lists accordingly, and tags each sub-part's storage key with a `#{j}` suffix (`_expand_split_indices()` keeps the mem-side and storage-side sub-descriptor lists in matching order). | **This is the origin of the `mem_split_n`/`_resolve_mem_split`/`#{j}` multipart scheme — it is not upstream LMCache.** `SPDK_NVMe_KV` advertises a 512 KiB `max_value_size`; a full LMCache page is normally several MB. Without this patch there is no split at all: a page larger than the backend's ceiling either fails outright or (worse) silently collapses distinct sub-parts onto one key and overwrites — see the warning below. |
| `0008` | accept `SPDK_NVMe_KV` and `XNVME_KV` in `nixl_storage_backend` | `lmcache/v1/storage_backend/nixl_storage_backend.py` | Adds both names to `validate_nixl_backend()`'s allowlist, to the `mem_type="OBJ"` selection in `NixlDynamicStorageAgent.__init__`, and to the `create_backend`-adjacent pool-selection branch (`NixlObjectPool` vs `NixlFilePool`). | This is the **in-process** path (`LMCacheConnectorV1`/`StorageManager`/`CreateStorageBackends`), which this repo does not currently run — the MP daemon uses `0006`'s file instead. Patched anyway because it is the same LMCache install serving both code paths, and it is exactly the function pair this repo's own `scripts/common/25-validate-lmcache-config.sh` introspects. If the in-process path is ever revived, this patch is what makes it work; until then it is dormant but present. |
| `0009` | derive the K/V plane count instead of assuming 2 | `lmcache/integration/vllm/vllm_service_factory.py`, `lmcache/v1/gpu_connector/gpu_connectors.py` | Adds `_aic_kv_plane_count()`, which asks vLLM's attention backend (`get_kv_cache_shape()`) whether the KV cache is *fused* (rank-4, `2 * head_size` trailing axis) or *split* (rank-5, leading axis of 2) instead of hardcoding "2 planes". Carries the answer through `metadata.kv_shape` to the connector and cross-checks it against the real tensors at first use, raising on mismatch. | vLLM 0.26 on this stack presents a fused cache; the unpatched assumption of 2 split planes has the same total byte count (so nothing fails loudly) but a wrong per-token stride — the copy kernel silently stores half the tokens, from the wrong offsets, with the V plane never written. Every chunk on the unpatched path is corrupt without ever raising an error. |
| `0011` | gate `LMCacheMPConnector`'s load path on `num_external_tokens` | `lmcache/integration/vllm/lmcache_mp_connector.py` | One-line guard: `condition = num_external_tokens > 0 and tracker.needs_retrieve()` (previously just `tracker.needs_retrieve()`). | Since vLLM #46865, a non-chosen `MultiConnector` sub-connector receives the request's real blocks with `num_external_tokens=0`; without this guard it wrongly decides to retrieve anyway, creates a load that must not happen, and leaks lookup locks (only the vLLM-side hit tokens get freed, not the LMCache-side ones). There are two near-identical `LMCacheMPConnector` implementations in this image and the vendor's default import resolves to the one this patch touches — see the patch's own header comment for the two-copy trap. |

## Re-verification recipe

Copy-pasteable. This is how a future reader confirms a **new** image still
carries these patches before assuming anything about it.

```bash
IMG=rocm-aic:mp-pd-ionic2609
LMCACHE=/usr/local/lib/python3.12/dist-packages/lmcache

# 0006 — L2 adapter accepts SPDK_NVMe_KV / XNVME_KV
docker run --rm --entrypoint bash "$IMG" -lc \
  "sed -n '234p' $LMCACHE/v1/distributed/l2_adapters/nixl_store_l2_adapter.py; \
   sed -n '1064,1065p' $LMCACHE/v1/distributed/l2_adapters/nixl_store_l2_adapter.py"
# expected:
#   234:  elif self.backend in ["OBJ", "AZURE_BLOB", "SPDK_NVMe_KV", "XNVME_KV"]:
#   1064: "SPDK_NVMe_KV",
#   1065: "XNVME_KV",

# 0007 — mem_split_n / _resolve_mem_split exist in the same file
docker run --rm --entrypoint bash "$IMG" -lc \
  "sed -n '209p;249p' $LMCACHE/v1/distributed/l2_adapters/nixl_store_l2_adapter.py"
# expected:
#   209: self.mem_split_n = self._resolve_mem_split(l1_memory_desc.align_bytes)
#   249: def _resolve_mem_split(self, page_size: int) -> int:

# 0008 — in-process nixl_storage_backend.py also carries both names
docker run --rm --entrypoint bash "$IMG" -lc \
  "grep -n 'SPDK_NVMe_KV\|XNVME_KV' $LMCACHE/v1/storage_backend/nixl_storage_backend.py"
# expected: hits at (at least) lines 126, 670, 1119

# 0009 — provenance comments in gpu_connectors.py
docker run --rm --entrypoint bash "$IMG" -lc \
  "grep -n '# rocm-aic:' $LMCACHE/v1/gpu_connector/gpu_connectors.py"
# expected: hits at (at least) lines 184, 233-234, 269-273

# 0011 — num_external_tokens guard live in lmcache_mp_connector.py
docker run --rm --entrypoint bash "$IMG" -lc \
  "grep -n 'num_external_tokens' $LMCACHE/integration/vllm/lmcache_mp_connector.py"
# expected: hits at (at least) lines 1103, 1117
```

All five were re-checked this way against `rocm-aic:mp-pd-ionic2609` on
2026-09-17 and matched the expected output above exactly.

> **If a future image lacks `0006`:** the daemon rejects
> `backend: XNVME_KV` (or `SPDK_NVMe_KV`) outright — `--l2-adapter` config
> validation (`scripts/common/25-validate-lmcache-config.sh`) fails before
> the daemon ever spawns, or, if that check is bypassed, the daemon dies
> the first time it tries to construct the NIXL backend. Loud, not silent.
>
> **If a future image lacks `0007`:** `mem_split_n` does not exist at all.
> Any page larger than the backend's declared `max_value_size` either
> fails the transfer outright, or — if some other code path tolerates the
> oversized descriptor — silently truncates or corrupts the stored value,
> because nothing is splitting it into backend-sized sub-descriptors. This
> is a **silent** failure mode: the store can return success while only
> the last sub-part's bytes are actually retrievable. See
> `scripts/verify/30-verify-kv-roundtrip.sh`'s header comment for the full
> mechanism.

## Keep `_kv_roundtrip.py` and `0007` in agreement

`0007`'s `#{j}` sub-key scheme (one storage key per split sub-part,
suffixed `#0`, `#1`, ... — see `_expand_split_indices()` in the patch
itself) is **hand-mirrored**, not imported, by
`scripts/verify/_kv_roundtrip.py`'s multipart handling. If `0007` is ever
rebased and the suffix scheme, split-count arithmetic (`ceil(page_size /
max_value_size)`), or sub-part ordering changes, `_kv_roundtrip.py` must
change with it or the roundtrip verify script will silently stop testing
the property it exists to test — see
`scripts/verify/30-verify-kv-roundtrip.sh`'s header comment.

## Numbering gap

Patch numbers `0001`-`0005`, `0010`, `0012`, `0013` exist in the same
upstream patch set this directory was extracted from but are **not**
LMCache patches and are **not** carried here:

- `0001`-`0004` are the SPDK NVMe-KV command-set patches — see
  [`patches/spdk/README.md`](../spdk/README.md) (this repo's copy of them).
- `0005`, `0010`, `0012`, `0013` are vLLM/Dockerfile patches from the same
  build-repo patch series, out of scope for this directory. `0010` in
  particular is `0011`'s sibling — the guard applied to vLLM's *own*
  built-in `LMCacheMPConnector` copy, which this deployment does not use
  (see `0011`'s own patch header for why both copies exist and why only
  one of them is live here).

Do not copy `0001`-`0005`/`0010`/`0012`/`0013` into this directory —
they belong to different components.

## Provenance (sha256)

```
14b8e693322422124de83f47c4aef70456fd5382c3f30889b10dbaca25a4c8bd  0006-lmcache-l2-adapter-kv-backends.patch
d6ab8d0ad3efc6bff77e185c2e11bc586db2f9231936a472dacd1911de04db39  0007-lmcache-l2-adapter-value-size-split.patch
bd8af542f1b795c644a1cd52a49da2df6a3fa1119ce3777cbdfc35a4b4712f8e  0008-lmcache-nixl-storage-backend-kv.patch
a43253d3596fcc22e500ef28bbda401f78ff9d0b96f0abae2701c11dd70edec2  0009-lmcache-fused-kv-plane-count.patch
7f0eac137c783108fe854be17c7ee19d2d2bc85ac838df4020ff68cf05afb8a1  0011-lmcache-guard-mp-connector-num-external-tokens.patch
```

Verify with `sha256sum patches/lmcache/*.patch` and diff against the list
above before trusting a checkout that claims to carry these unmodified.
