#!/usr/bin/env bash
# apply-patches.sh — patch the INSTALLED LMCache to recognize the
# SPDK_NVMe_KV / XNVME_KV NIXL backends.
#
# Node:          SMC1 (prefill), SMC2 (decode) — anywhere ${VENV} was built
#                by scripts/common/20-build-vllm-lmcache.sh.
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh has completed
#                (need an importable `lmcache` in ${VENV}).
# Next step:     scripts/common/25-validate-lmcache-config.sh <cfg> — its
#                "NIXL backend allowlist" section should report ACCEPTED
#                for both checks after this script runs. Then
#                scripts/verify/30-verify-kv-roundtrip.sh /
#                scripts/verify/40-verify-disagg.sh for actual proof data
#                crosses the network.
#
# usage: apply-patches.sh [--dry-run | --revert] [--force]
#
# See patches/lmcache/README.md for WHY this is a generator-against-the-
# installed-tree rather than a shipped context diff, and for the honest
# VERIFIED-vs-ASSUMED accounting of what this script's heuristics rest on.
#
# The actual scan/patch logic lives in patches/lmcache/_patch_engine.py
# (tokenize + ast based, not sed) — this script's job is: find the install,
# enforce the backup/idempotency/force contract, invoke that engine, and
# archive the resulting diff.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common/lib.sh"

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${PATCH_DIR}/_patch_engine.py"
require_file "${ENGINE}"

# Must match _patch_engine.py's FILE_MARKER prefix exactly (the part before
# the file-specific detail) — used here at the bash layer purely to decide
# whether to refuse a second run; the engine re-checks per-bracket content
# independently (see its ALREADY_PATCHED_MARK), so the two checks can never
# disagree in a way that causes double-patching.
MARKER_GREP="kvstack-lmcache-patch: added SPDK_NVMe_KV, XNVME_KV"

DRY_RUN=0
REVERT=0
FORCE=0
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        --revert)  REVERT=1 ;;
        --force)   FORCE=1 ;;
        -h|--help)
            grep -E '^# usage:' -A0 "${BASH_SOURCE[0]}" >&2
            exit 0
            ;;
        *) die "unknown argument: ${arg} (expected --dry-run, --revert, --force)" ;;
    esac
done
[ "${DRY_RUN}" -eq 1 ] && [ "${REVERT}" -eq 1 ] && die "--dry-run and --revert are mutually exclusive"

if [ ! -x "${VENV}/bin/python" ]; then
    die "no venv at ${VENV} — run scripts/common/20-build-vllm-lmcache.sh first"
fi
PY="${VENV}/bin/python"

step "Locating installed LMCache package"
LMCACHE_DIR="$("${PY}" -c 'import lmcache, os; print(os.path.dirname(lmcache.__file__))' 2>/dev/null)" \
    || die "could not import lmcache in ${VENV} — run" \
           " scripts/common/20-build-vllm-lmcache.sh first"
require_dir "${LMCACHE_DIR}"
LMCACHE_VERSION_INSTALLED="$("${PY}" -c 'import lmcache; print(lmcache.__version__)' 2>/dev/null || echo unknown)"
ok "found lmcache ${LMCACHE_VERSION_INSTALLED} at ${LMCACHE_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# --revert: restore every *.orig-kvstack backup found under the install,
# regardless of --force/marker state, and stop. Does not re-apply.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${REVERT}" -eq 1 ]; then
    step "Reverting LMCache patches under ${LMCACHE_DIR}"
    _found=0
    while IFS= read -r -d '' backup; do
        target="${backup%.orig-kvstack}"
        mv -f "${backup}" "${target}"
        log "restored ${target}"
        _found=$((_found + 1))
    done < <(find "${LMCACHE_DIR}" -name '*.orig-kvstack' -print0)
    if [ "${_found}" -eq 0 ]; then
        if grep -rl "${MARKER_GREP}" "${LMCACHE_DIR}" >/dev/null 2>&1; then
            warn "no .orig-kvstack backups found, but the patch marker IS" \
                 " present in some file(s) — the patch was applied by" \
                 " something other than this script's backup mechanism," \
                 " or the backups were manually deleted. Nothing restored;" \
                 " you may need to reinstall lmcache" \
                 " (pip install --force-reinstall lmcache==${LMCACHE_VERSION_INSTALLED})."
        else
            warn "no .orig-kvstack backups found and no patch marker present" \
                 " — nothing to revert (this install was never patched)."
        fi
        exit 0
    fi
    ok "reverted ${_found} file(s)"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Refuse a second apply without --force. Detected purely by the marker
# comment the engine inserts (see MARKER_GREP above) — deliberately NOT a
# separate state file, so "is this installed LMCache patched" has exactly
# one source of truth: grep the tree itself.
# ─────────────────────────────────────────────────────────────────────────────
_already_applied=0
if grep -rl "${MARKER_GREP}" "${LMCACHE_DIR}" >/dev/null 2>&1; then
    _already_applied=1
fi

if [ "${_already_applied}" -eq 1 ] && [ "${DRY_RUN}" -eq 0 ]; then
    if [ "${FORCE}" -eq 0 ]; then
        die "LMCache at ${LMCACHE_DIR} is already patched (marker found)." \
            " Re-running would either double-insert or no-op depending on" \
            " engine idempotency you should not have to rely on — pass" \
            " --force to revert-then-reapply cleanly (e.g. after a" \
            " lmcache upgrade in place), or --revert to just undo it."
    fi
    info "--force given and already patched: reverting existing patch" \
         " before reapplying, so edits never stack."
    _reverted=0
    while IFS= read -r -d '' backup; do
        target="${backup%.orig-kvstack}"
        mv -f "${backup}" "${target}"
        _reverted=$((_reverted + 1))
    done < <(find "${LMCACHE_DIR}" -name '*.orig-kvstack' -print0)
    if [ "${_reverted}" -eq 0 ]; then
        warn "marker present but no .orig-kvstack backups found to revert" \
             " from — proceeding anyway; the engine's own per-bracket" \
             " already-patched check will skip anything already correct" \
             " and only touch what genuinely still needs it."
    else
        ok "reverted ${_reverted} file(s) prior to reapply"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Invoke the engine.
# ─────────────────────────────────────────────────────────────────────────────
DIFF_OUT="${PATCH_DIR}/applied-${LMCACHE_VERSION_INSTALLED}.diff"

if [ "${DRY_RUN}" -eq 1 ]; then
    step "DRY RUN: scanning ${LMCACHE_DIR} (nothing will be written)"
    "${PY}" "${ENGINE}" "${LMCACHE_DIR}" dry-run -
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        ok "dry run complete — see diff above for what WOULD change"
    else
        die "dry run reported a hard failure (see output above) — this" \
            " almost always means the LMCache allowlist shape has drifted;" \
            " see patches/lmcache/README.md's ASSUMED section"
    fi
    exit "${rc}"
fi

step "Applying LMCache allowlist patch to ${LMCACHE_DIR}"
set +e
"${PY}" "${ENGINE}" "${LMCACHE_DIR}" apply "${DIFF_OUT}"
rc=$?
set -e

if [ "${rc}" -ne 0 ]; then
    die "patch engine failed (see output above) — no partial state should" \
        " remain (the engine validates+writes per-file, but rolls nothing" \
        " back automatically; if in doubt run --revert then investigate)."
fi

ok "patch applied; diff recorded at ${DIFF_OUT}"
log "next: scripts/common/start-lmcache-daemon.sh"
