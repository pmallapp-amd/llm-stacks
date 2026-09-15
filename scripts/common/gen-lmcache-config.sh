#!/usr/bin/env bash
# gen-lmcache-config.sh — emit the LMCache YAML for one role.
#
# Node:          SMC1 (prefill) or SMC2 (decode) — generates the file, does
#                not itself start anything.
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh (need LMCACHE_VERSION
#                to know what this generator is targeting).
# Next step:     scripts/common/25-validate-lmcache-config.sh <this file>
#                MUST pass before the file is trusted; scripts/common/
#                start-vllm.sh runs that validation automatically.
#
# usage: gen-lmcache-config.sh <prefill|decode> <output-path>
#
# ═══════════════════════════════════════════════════════════════════════════
# READ THIS BEFORE TOUCHING THIS FILE
# ═══════════════════════════════════════════════════════════════════════════
# LMCacheEngineConfig's accepted top-level keys, and — separately — the keys
# recognized *inside* `extra_config` by the NIXL storage backend
# (lmcache/v1/storage_backend/nixl_storage_backend.py), are both internal,
# undocumented-as-a-stable-contract, and DO change between LMCache minor
# versions. LMCache silently IGNORES an unrecognized top-level key in some
# versions and silently ignores an unrecognized extra_config sub-key in ALL
# versions (extra_config is typed as an opaque dict — nothing validates its
# contents until NixlStorageConfig.from_cache_engine_config() reads it at
# backend-construction time, deep inside LMCache, well after this YAML loads
# cleanly). That combination is exactly how you end up with a config that
# LOADS FINE, LOGS NOTHING WRONG, and never actually talks to the remote KV
# target — LMCache quietly falls back to CPU-only caching and every request
# still "works", just without any P/D cache sharing. This is precisely why
# scripts/common/25-validate-lmcache-config.sh exists: it inspects the
# INSTALLED LMCache's source to prove every key below is both recognized AND
# routed to the NIXL storage backend, rather than trusting this generator's
# assumptions. NEVER run a node with a config this generator produced without
# 25-validate-lmcache-config.sh having passed against it first.
#
# The schema below reflects LMCache v0.5.4 (this repo's pinned
# LMCACHE_VERSION, see scripts/common/20-build-vllm-lmcache.sh), verified
#2026-09 against lmcache/v1/config.py and
# lmcache/v1/storage_backend/nixl_storage_backend.py at tag v0.5.4. In
# particular:
#   - `enable_nixl_storage`, `nixl_backend`, `nixl_pool_size`,
#     `nixl_backend_params` all live UNDER `extra_config`, NOT at the
#     top level, in v0.5.4 — despite how they may look in older
#     examples/blog posts that predate this nesting.
#   - `nixl_pool_size: 0` (not a separate boolean) is what selects
#     NixlDynamicStorageBackend over NixlStaticStorageBackend. See the
#     "content-derived key" comment block below — this is the single
#     most load-bearing value in this file.
#
# ═══════════════════════════════════════════════════════════════════════════
# THE CONTENT-DERIVED-KEY CONSTRAINT (do not weaken this)
# ═══════════════════════════════════════════════════════════════════════════
# nixl_pool_size MUST be 0. LMCache's NixlStorageBackend factory
# (NixlStorageBackend.CreateNixlStorageBackend) picks:
#   pool_size == 0   -> NixlDynamicStorageBackend  (content-derived keys:
#                        NixlDynamicStorageAgent._format_object_key() hashes
#                        the CacheEngineKey — model+chunk-hash+token content —
#                        the SAME bytes on every process that sees the same
#                        prompt prefix, prefill or decode, this run or the
#                        next.)
#   pool_size  > 0   -> NixlStaticStorageBackend    (pool of PRE-ALLOCATED
#                        slot names, `obj_{slot}_{uuid4}` — a fresh random
#                        uuid4 suffix generated independently by EVERY
#                        process at startup. See NixlObjectPool.__init__ in
#                        nixl_storage_backend.py.)
# With pool_size > 0, the prefill process's object names and the decode
# process's object names for the "same" cached content share nothing but the
# `obj_{slot}_` prefix — the decode side can never guess the uuid4 the
# prefill side happened to allocate, so every lookup misses. This is not a
# hypothetical: it is the plugin-level bug this repo already found and fixed
# once (see the `queryMem()` doc comment in
# plugins/nvme-kv/spdk_nvme_kv_backend.h, "Observed 2026-09-07 as 'LMCache
# hit tokens: 0' on every decode request") for the layer BELOW this one (the
# transport had no existence-probe at all). Getting nixl_pool_size right is
# the LMCache-side half of that same fix — get either half wrong and you are
# back to hit_tokens=0 with no error anywhere.
#
# save_unfull_chunk therefore stays False (LMCache's own
# NixlDynamicStorageAgent constructor asserts `not config.save_unfull_chunk`
# when pool_size==0 — see nixl_storage_backend.py's dynamic_storage branch).
#
# ═══════════════════════════════════════════════════════════════════════════
# THE BACKEND-ALLOWLIST RISK (read this before assuming this file "works")
# ═══════════════════════════════════════════════════════════════════════════
# Whether the installed LMCache accepts XNVME_KV / SPDK_NVMe_KV as backend
# names depends on the build provenance:
#
#   FROM-SOURCE BUILD (pypi 0.5.4, this repo's default build path — see
#   scripts/common/20-build-vllm-lmcache.sh):
#   Stock LMCache v0.5.4's NixlStorageConfig.validate_nixl_backend() only
#   recognizes GDS/GDS_MT/OBJ (cpu or cuda) and POSIX/HF3FS/AZURE_BLOB/
#   DOCA_MEMOS (cpu only). "SPDK_NVMe_KV" / "XNVME_KV" are NOT in that list,
#   so a stock install raises `AssertionError: Invalid NIXL backend & device
#   combination` at backend-construction time. Separately,
#   NixlDynamicStorageAgent decides its NIXL mem_type by a SECOND hardcoded
#   name list (backend in ("OBJ","AZURE_BLOB","DOCA_MEMOS") -> OBJ, else
#   FILE); our backends fall into the FILE branch, making LMCache open real
#   POSIX files on the LOCAL filesystem — silently correct-looking, silently
#   wrong. Getting our backends working from source therefore requires BOTH
#   name lists patched, matching the pattern referenced in this repo's own
#   plugin comments (plugins/nvme-kv/spdk_nvme_kv_plugin.cpp mentions
#   "stack/tracks/lmcache/patches/0002-*.patch", "0003-*.patch"; the
#   backend-allowlist patch in patches/lmcache/ is the same family).
#
#   ROCM-AIC CONTAINER IMAGE (vendored LMCache 0.5.3):
#   The container ships a build where XNVME_KV and SPDK_NVMe_KV appear in
#   ALL THREE hardcoded tuples (lmcache/v1/storage_backend/nixl_storage_backend.py
#   :126 validate_nixl_backend, :670 mem_type selection, :1119 createPool),
#   confirmed 2026-09-15 by reading the installed source in the rocm-aic
#   image. No patch is required there.
#
# scripts/common/25-validate-lmcache-config.sh greps the INSTALLED LMCache's
# source for exactly these two name lists and FAILS LOUDLY if our backends
# are absent from either, instead of letting you discover it as a silent
# local-file fallback during a live P/D test — this check catches BOTH the
# unpatched-from-source case and any future regressions from a container
# image upgrade that drops the vendor patches.
#
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLE="${1:-}"
OUT="${2:-}"
if [ -z "${ROLE}" ] || [ -z "${OUT}" ]; then
    die "usage: $0 <prefill|decode> <output-path>"
fi
case "${ROLE}" in
    prefill) _SLOT_OFFSET="${KV_SLOT_OFFSET_PREFILL}" ;;
    decode)  _SLOT_OFFSET="${KV_SLOT_OFFSET_DECODE}"  ;;
    *) die "role must be prefill|decode, got '${ROLE}'" ;;
esac

# Every value below is overridable via an env var — nobody should have to
# edit this generator to change a config value.
_CHUNK_SIZE="${LMCACHE_CHUNK_SIZE}"
_LOCAL_CPU="${LMCACHE_LOCAL_CPU}"
_MAX_LOCAL_CPU_SIZE="${LMCACHE_MAX_LOCAL_CPU_SIZE}"

# save_unfull_chunk: see "THE CONTENT-DERIVED-KEY CONSTRAINT" above. Do not
# override this to true unless nixl_pool_size is also changed away from 0 —
# LMCache's own assertion will reject that combination anyway, but silently
# flipping this without understanding why is how someone "fixes" an
# assertion error by breaking the property that made this work.
_SAVE_UNFULL_CHUNK="${LMCACHE_SAVE_UNFULL_CHUNK:-false}"

# NIXL staging buffer: a bounce buffer NIXL/UCX moves KV pages through on
# their way to/from the SPDK_NVMe_KV plugin — sized independently of
# KV_MAX_VALUE_SIZE (that's the plugin's per-STORE/RETRIEVE ceiling; this is
# how much in-flight staging capacity the backend gets). 1 GiB default is
# generous headroom over a single ~5.7MB KV page (chunk_size=256) with room
# for several in-flight transfers; too small shows up as
# "Failed to allocate memory, consider increasing the `nixl_buffer_size`
# value" in nixl_storage_backend.py's warning, not a hang.
_NIXL_BUFFER_SIZE="${LMCACHE_NIXL_BUFFER_SIZE:-1073741824}"

# "cuda": ROCm/HIP presents its device memory API as "cuda" to torch (HIP is
# built as a CUDA-compatible shim on AMD GPUs), and LMCache's device-selection
# code (get_correct_device) only knows the "cpu"/"cuda" vocabulary — there is
# no "rocm" or "hip" value to pass here.
_NIXL_BUFFER_DEVICE="${LMCACHE_NIXL_BUFFER_DEVICE:-cuda}"

# LMCache 0.5.3 (rocm-aic container) rejects nixl_buffer_size when the buffer
# device is cpu (lmcache/v1/config.py:807-811 — the cpu path shares
# LocalCPUBackend's pinned pool sized by max_local_cpu_size, so a separate
# buffer size is meaningless there). Intercept the contradictory combination
# early so the error names the env var at generation time rather than surfacing
# as a ValueError from deep inside LMCache at engine start.
case "${_NIXL_BUFFER_DEVICE}" in
    cpu)
        if [ -n "${LMCACHE_NIXL_BUFFER_SIZE+x}" ]; then
            die "LMCACHE_NIXL_BUFFER_SIZE is set (${LMCACHE_NIXL_BUFFER_SIZE})" \
                " but LMCACHE_NIXL_BUFFER_DEVICE=cpu. LMCache 0.5.3" \
                " rejects nixl_buffer_size when nixl_buffer_device='cpu'" \
                " (lmcache/v1/config.py:807-811) because the cpu path shares" \
                " LocalCPUBackend's pinned pool sized by max_local_cpu_size." \
                " Unset LMCACHE_NIXL_BUFFER_SIZE or change" \
                " LMCACHE_NIXL_BUFFER_DEVICE to something other than cpu."
        fi
        if [ "${_MAX_LOCAL_CPU_SIZE}" -le 0 ] 2>/dev/null; then
            die "LMCACHE_NIXL_BUFFER_DEVICE=cpu requires" \
                " max_local_cpu_size > 0 (LMCache 0.5.3 asserts this at" \
                " lmcache/v1/config.py:812-815), but" \
                " LMCACHE_MAX_LOCAL_CPU_SIZE='${_MAX_LOCAL_CPU_SIZE}'." \
                " Set LMCACHE_MAX_LOCAL_CPU_SIZE to a positive integer" \
                " (GiB of host DRAM for the LocalCPUBackend pinned pool)."
        fi
        _NIXL_BUFFER_SIZE_LINE="# nixl_buffer_size omitted: nixl_buffer_device='cpu' uses"
        _NIXL_BUFFER_SIZE_LINE+=$'\n'"# LocalCPUBackend's pinned pool (max_local_cpu_size)"
        _NIXL_BUFFER_SIZE_LINE+=$'\n'"# instead of a separate staging buffer — LMCache 0.5.3"
        _NIXL_BUFFER_SIZE_LINE+=$'\n'"# rejects nixl_buffer_size in this mode"
        _NIXL_BUFFER_SIZE_LINE+=$'\n'"# (lmcache/v1/config.py:807-811)."
        ;;
    *)
        _NIXL_BUFFER_SIZE_LINE="nixl_buffer_size: ${_NIXL_BUFFER_SIZE}"
        ;;
esac

_NIXL_BACKEND="${LMCACHE_NIXL_BACKEND:-${KV_BACKEND}}"

# 0 = dynamic/content-derived storage backend. See the constraint block
# above — do not change this without changing everything else that depends
# on it.
_NIXL_POOL_SIZE="${LMCACHE_NIXL_POOL_SIZE:-0}"

# ═══════════════════════════════════════════════════════════════════════════
# nixl_backend_params — the ONE block whose keys differ per backend
# ═══════════════════════════════════════════════════════════════════════════
# Built here, before the heredoc below, because the two backends' plugins
# advertise genuinely different getParams() shapes — this is read straight
# from each plugin's own source, not guessed:
#
#   SPDK_NVMe_KV (plugins/nvme-kv/spdk_nvme_kv_plugin.cpp getParams()):
#     {trid, max_value_size, kv_slot_offset}
#
#   XNVME_KV (plugins/xnvme-kv/xnvme_kv_plugin.cpp getParams()):
#     {dev_uri, max_value_size} ONLY. There is no trid (this backend has no
#     SPDK transport-ID concept — it talks to a kernel-owned /dev/ngXnY char
#     device instead) and no kv_slot_offset: make_key() in
#     xnvme_kv_backend.h never reads a slot offset on ANY code path, unlike
#     SPDK's make_key() which at least consults it on the metaInfo-less
#     fallback. Emitting kv_slot_offset for XNVME_KV would look
#     load-bearing while silently doing nothing — worse than omitting it.
#
# Both use KV_MAX_VALUE_SIZE_EFFECTIVE (config/cluster.env), NOT the
# SPDK-specific KV_MAX_VALUE_SIZE directly, so this generator automatically
# tracks whichever backend-appropriate ceiling KV_BACKEND selected. For the
# default KV_BACKEND=SPDK_NVMe_KV, KV_MAX_VALUE_SIZE_EFFECTIVE resolves to
# the exact same value KV_MAX_VALUE_SIZE always has (524288) — this
# generator's SPDK output is unchanged by XNVME_KV existing.
case "${_NIXL_BACKEND}" in
    XNVME_KV)
        _NIXL_BACKEND_PARAMS_BLOCK="$(cat <<PARAMS
  # Parameters handed verbatim to the plugin create_backend(name, params)
  # — exactly the {dev_uri, max_value_size} pair documented in
  # plugins/xnvme-kv/xnvme_kv_plugin.cpp's getParams(). There is
  # deliberately NO trid (this backend has no SPDK transport-ID concept —
  # it talks to a kernel-owned /dev/ngXnY char device instead) and NO
  # kv_slot_offset (make_key() in xnvme_kv_backend.h never reads a slot
  # offset on ANY code path — emitting one here would look load-bearing
  # while doing nothing). scripts/common/25-validate-lmcache-config.sh
  # echoes the plugin's own get_plugin_params("${_NIXL_BACKEND}") defaults
  # back so you can diff them against what's set here.
  nixl_backend_params:
    dev_uri: "${XNVME_DEV}"
    max_value_size: "${KV_MAX_VALUE_SIZE_EFFECTIVE}"
PARAMS
)"
        ;;
    *)
        _NIXL_BACKEND_PARAMS_BLOCK="$(cat <<PARAMS
  # Parameters handed verbatim to the plugin create_backend(name, params)
  # — these three are exactly the {trid, max_value_size, kv_slot_offset}
  # triple documented in plugins/nvme-kv/spdk_nvme_kv_plugin.cpp's
  # getParams(). scripts/common/25-validate-lmcache-config.sh echoes the
  # plugin's own get_plugin_params("${_NIXL_BACKEND}") defaults back so you
  # can diff them against what's set here.
  nixl_backend_params:
    trid: "${KV_TRID}"
    max_value_size: "${KV_MAX_VALUE_SIZE_EFFECTIVE}"
    # NOTE: this offset is a NO-OP on this deployment. make_key() in
    # spdk_nvme_kv_backend.h derives the on-wire key from metaInfo whenever
    # the caller sets it (nixlBlobDesc::metaInfo), and
    # NixlDynamicStorageAgent._format_object_key() ALWAYS sets metaInfo (it
    # is the content-derived key itself) — so kv_slot_offset, which only
    # applies on the devId/addr fallback path taken by callers that never
    # set metaInfo (kv_io.py, nixlbench), never applies here. Kept
    # populated anyway for symmetry with those tools and because
    # 25-validate-lmcache-config.sh echoes it back from the plugin's real
    # get_plugin_params() so a reader can see it's consistent, not because
    # it changes this deployment's behavior.
    kv_slot_offset: "${_SLOT_OFFSET}"
PARAMS
)"
        ;;
esac

mkdir -p "$(dirname "${OUT}")"

cat > "${OUT}" <<EOF
# Generated by scripts/common/gen-lmcache-config.sh for role=${ROLE}.
# Targets LMCache ${LMCACHE_VERSION:-0.5.4 (default pin; see scripts/common/20-build-vllm-lmcache.sh)}.
#
# DO NOT HAND-EDIT — re-run the generator (all values are env-var
# overridable, see the header comment above). Before trusting this
# file, run:
#   scripts/common/25-validate-lmcache-config.sh ${OUT}
# which introspects the INSTALLED LMCache to confirm every key below is
# both recognized and actually wired to the NIXL storage backend — LMCache
# silently ignores unknown keys in extra_config in every version, so a
# clean load of this file proves nothing on its own.
#
# kv_role for this node: ${ROLE} (kv_producer/kv_consumer set on the vLLM
# --kv-transfer-config side, not here — see scripts/common/start-vllm.sh).

chunk_size: ${_CHUNK_SIZE}
local_cpu: ${_LOCAL_CPU}
max_local_cpu_size: ${_MAX_LOCAL_CPU_SIZE}
local_disk: null

# See "THE CONTENT-DERIVED-KEY CONSTRAINT" in the header comment above
# — must stay false while extra_config.nixl_pool_size is 0.
save_unfull_chunk: ${_SAVE_UNFULL_CHUNK}

# --- NIXL remote storage staging buffer (top-level fields; NOT under
#     extra_config — these two ARE real LMCacheEngineConfig dataclass
#     fields, unlike everything in the extra_config block below) ---
${_NIXL_BUFFER_SIZE_LINE}
nixl_buffer_device: "${_NIXL_BUFFER_DEVICE}"

extra_config:
  # Selects the NixlStorageBackend.CreateNixlStorageBackend NIXL code path
  # (see lmcache/v1/storage_backend/nixl_storage_backend.py). Everything
  # below this key is read ONLY by that code path, at backend-construction
  # time — a typo here fails silently at YAML-load time and loudly (or not
  # at all — see the FILE/OBJ mem_type note above) only once a request
  # actually tries to store/retrieve.
  enable_nixl_storage: true

  # The plugin name the NIXL create_backend() dlopens from ${NIXL_PLUGIN_DIR}
  # (see lib.sh setup_nixl_kv_env, which exports NIXL_PLUGIN_DIR).
  # Allowlist note: the patch at patches/lmcache/ is required for a
  # from-source LMCache build (e.g. pypi 0.5.4) whose validate_nixl_backend()
  # and mem_type-selection tuples do not include XNVME_KV or SPDK_NVMe_KV.
  # The rocm-aic container's vendored LMCache 0.5.3 carries both backends
  # natively — verified 2026-09-15 by reading the three hardcoded tuples in
  # lmcache/v1/storage_backend/nixl_storage_backend.py (:126, :670, :1119).
  nixl_backend: "${_NIXL_BACKEND}"

  # 0 = NixlDynamicStorageBackend (content-derived keys). See the
  # constraint block above. Do not set > 0.
  nixl_pool_size: ${_NIXL_POOL_SIZE}

${_NIXL_BACKEND_PARAMS_BLOCK}
EOF

ok "wrote ${OUT} (role=${ROLE}, nixl_backend=${_NIXL_BACKEND}, nixl_pool_size=${_NIXL_POOL_SIZE})"
log "next: scripts/common/25-validate-lmcache-config.sh ${OUT}"
