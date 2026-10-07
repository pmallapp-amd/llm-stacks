#!/usr/bin/env bash
# 35-verify-nixl-kv-smoke.sh — adapter-level smoke test for
# overlays/lmcache/nixl_kv_l2_adapter.py's multi-page store/commit/load
# protocol (design doc §6), against the real DSC. Sits between
# 20-verify-nixl-plugin.sh (raw NIXL, no data roundtrip) and
# 30-verify-kv-roundtrip.sh (raw NIXL, single value) on one side, and
# 40/50-verify-*.sh (full vLLM+LMCache) on the other — this is the first
# layer that exercises the adapter's OWN page-naming/commit-object logic,
# independent of whether its LMCache registration has been confirmed yet
# (see nixl_kv_l2_adapter.py's module docstring and
# scripts/common/container.sh's adapter-check for that separate concern).
#
# Node:          SMC1 (prefill) or SMC2 (decode).
# Prerequisites: scripts/verify/30-verify-kv-roundtrip.sh clean.
# Next step:     scripts/common/container.sh adapter-check, then
#                scripts/verify/40-verify-disagg.sh.
#
# usage:
#   35-verify-nixl-kv-smoke.sh                     # write+read, one host, two processes
#   35-verify-nixl-kv-smoke.sh --write              # write only; prints --nonce to reuse
#   35-verify-nixl-kv-smoke.sh --read --nonce X     # read only; nonce MUST match the writer
#   35-verify-nixl-kv-smoke.sh [--pages N] [--role prefill|decode]
#
# --pages defaults to 3 (not 1) specifically to exercise the multi-page
# store/commit protocol — a single-page test cannot catch a page-naming
# collision (every page silently overwriting the last, the exact failure
# design doc §7-S1 warns the acceptance test's token-identity check exists
# to catch).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_nixl_kv_smoke.py"
require_file "${ENGINE}"

MODE="both"
PAGES="3"
NONCE=""
ROLE=""
for arg in "$@"; do
    case "${arg}" in
        --write) MODE="write" ;;
        --read)  MODE="read" ;;
        --pages=*) PAGES="${arg#--pages=}" ;;
        --nonce=*) NONCE="${arg#--nonce=}" ;;
        --role=*)  ROLE="${arg#--role=}" ;;
        *) die "unknown argument: ${arg} (expected --write, --read," \
               " --pages=N, --nonce=STRING, --role=prefill|decode)" ;;
    esac
done

if [ -z "${ROLE}" ]; then
    _local_ips="$(hostname -I 2>/dev/null || true)"
    case " ${_local_ips} " in
        *" ${PREFILL_HOST} "*) ROLE="prefill" ;;
        *" ${DECODE_HOST} "*)  ROLE="decode" ;;
        *) ROLE="prefill" ;;
    esac
fi

if [ "${MODE}" = "read" ] && [ -z "${NONCE}" ]; then
    die "--read requires --nonce=<value> matching the paired --write" \
        " invocation's nonce (it printed one — reuse it)."
fi
if [ -z "${NONCE}" ]; then
    NONCE="$("${VENV}/bin/python" -c 'import uuid; print(uuid.uuid4().hex)' 2>/dev/null \
        || date +%s%N)"
fi

step "nixl_kv adapter smoke test: role=${ROLE} mode=${MODE} pages=${PAGES} nonce=${NONCE}"
banner_config

require_file "${STACK_ROOT}/etc/env.sh"
# shellcheck source=/dev/null
source "${STACK_ROOT}/etc/env.sh"
setup_nixl_kv_env "${ROLE}"
require_file "${VENV}/bin/python"

[ "${KV_BACKEND}" = "XNVME_KV" ] || die "35-verify-nixl-kv-smoke.sh only" \
    " knows the XNVME_KV connect-param shape (nixl_kv_l2_adapter.py is" \
    " backend-agnostic, but this test script's --dev-uri plumbing is not)" \
    " — got KV_BACKEND=${KV_BACKEND}"

# Same geometry-fingerprint namespace start-lmcache-daemon.sh would compute,
# so a mismatch against a real daemon run would show up as a NAMESPACE
# difference here too, not just in production.
_NAMESPACE="smoke-$(printf '%s' "v1|${MODEL}|${TP_SIZE}|${LMCACHE_CHUNK_SIZE}" | sha256sum | cut -c1-12)"

_run_side() {
    local side="$1"
    "${VENV}/bin/python" "${ENGINE}" \
        --mode "${side}" \
        --nonce "${NONCE}" \
        --namespace "${_NAMESPACE}" \
        --pages "${PAGES}" \
        --dev-uri "${NIXL_XNVME_DEV}"
}

_report() {
    local side="$1" out="$2"
    printf '%s\n' "${out}" | grep -E '^INFO:' | sed 's/^INFO://' \
        | while IFS= read -r line; do log "  [${side}] ${line}"; done
    if printf '%s' "${out}" | grep -q '^RESULT:OK:'; then
        return 0
    fi
    local fail_line
    fail_line="$(printf '%s\n' "${out}" | grep '^RESULT:' | tail -1)"
    err "  [${side}] ${fail_line:-<no RESULT line — process may have crashed>}"
    return 1
}

case "${MODE}" in
    write)
        step "WRITE (this process only)"
        set +e
        _out="$(_run_side write)"
        set -e
        _report "write" "${_out}" || true
        ok "nonce for the paired --read invocation: ${NONCE}"
        log "  run on the SAME or a DIFFERENT node:"
        log "    scripts/verify/35-verify-nixl-kv-smoke.sh --read --nonce=${NONCE} --pages=${PAGES}"
        ;;
    read)
        step "READ (this process only, fresh from the writer)"
        set +e
        _out="$(_run_side read)"
        set -e
        _report "read" "${_out}" || true
        ;;
    both)
        step "WRITE then READ, as two SEPARATE OS processes on this host"
        set +e
        _wout="$(_run_side write)"
        _wrc=$?
        set -e
        _report "write" "${_wout}" || true

        if [ "${_wrc}" -ne 0 ]; then
            err "write side failed — skipping read (nothing valid to read back)"
        else
            set +e
            _rout="$(_run_side read)"
            set -e
            _report "read" "${_rout}" || true
        fi
        ;;
esac

checks_summary
