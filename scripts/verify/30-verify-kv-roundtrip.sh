#!/usr/bin/env bash
# 30-verify-kv-roundtrip.sh — the single most valuable test in this tree: a
# STORE from one OS process and a RETRIEVE from a DIFFERENT one, proving
# cross-process key AGREEMENT — exactly what P/D disaggregation requires,
# and exactly what breaks when a caller's keys carry a per-process uuid4
# instead of being derived purely from content (see
# scripts/common/gen-lmcache-config.sh's "THE CONTENT-DERIVED-KEY
# CONSTRAINT" for the LMCache-side version of this same requirement).
#
# Node:          SMC1 (prefill) or SMC2 (decode). Can also run --write on
#                one and --read on the other for the strongest possible
#                proof (genuinely cross-NODE, not just cross-process).
# Prerequisites: scripts/verify/20-verify-nixl-plugin.sh clean.
# Next step:     scripts/verify/40-verify-disagg.sh — the full vLLM+LMCache
#                version of this same property.
#
# usage:
#   30-verify-kv-roundtrip.sh                     # write+read, one host, two processes
#   30-verify-kv-roundtrip.sh --write              # write only; prints --nonce to reuse
#   30-verify-kv-roundtrip.sh --read --nonce X     # read only; nonce MUST match the writer
#   30-verify-kv-roundtrip.sh [--size BYTES] [--role prefill|decode]
#
# WHY --size defaults to several multiples of KV_MAX_VALUE_SIZE: a payload
# smaller than KV_MAX_VALUE_SIZE never exercises the multipart-split code
# path at all (see patches/lmcache/README.md's "multipart-split" section
# and plugins/nvme-kv/spdk_nvme_kv_plugin.cpp's getParams() comment on why
# a ~5.7MB LMCache KV page has to be chopped into <=KV_MAX_VALUE_SIZE
# sub-transfers) — a "roundtrip test" that only ever sends one small value
# would pass even if the split/reassembly logic were completely broken.
# Six parts is enough to also catch an off-by-one in the split boundary
# arithmetic (ceil vs floor) without making the default run painfully slow.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kv_roundtrip.py"
require_file "${ENGINE}"

MODE="both"
SIZE=""
NONCE=""
ROLE=""
for arg in "$@"; do
    case "${arg}" in
        --write) MODE="write" ;;
        --read)  MODE="read" ;;
        --size=*)  SIZE="${arg#--size=}" ;;
        --nonce=*) NONCE="${arg#--nonce=}" ;;
        --role=*)  ROLE="${arg#--role=}" ;;
        *) die "unknown argument: ${arg} (expected --write, --read," \
               " --size=BYTES, --nonce=STRING, --role=prefill|decode)" ;;
    esac
done

if [ -z "${ROLE}" ]; then
    _local_ips="$(hostname -I 2>/dev/null || true)"
    case " ${_local_ips} " in
        *" ${PREFILL_HOST} "*) ROLE="prefill" ;;
        *" ${DECODE_HOST} "*)  ROLE="decode" ;;
        *) ROLE="prefill" ;;  # arbitrary but harmless: see gen-lmcache-config.sh's
                              # note that KV_SLOT_OFFSET is a no-op once metaInfo
                              # is set, which this test always does.
    esac
fi

if [ -z "${SIZE}" ]; then
    SIZE=$((KV_MAX_VALUE_SIZE * 6))
fi

if [ "${MODE}" = "read" ] && [ -z "${NONCE}" ]; then
    die "--read requires --nonce=<value> matching the paired --write" \
        " invocation's nonce (it printed one — reuse it). Without this," \
        " the two processes would derive DIFFERENT content and this test" \
        " would fail for a reason that has nothing to do with the thing" \
        " it's meant to test."
fi
if [ -z "${NONCE}" ]; then
    NONCE="$("${VENV}/bin/python" -c 'import uuid; print(uuid.uuid4().hex)' 2>/dev/null \
        || date +%s%N)"
fi

step "KV roundtrip verification: role=${ROLE} mode=${MODE} size=${SIZE} nonce=${NONCE}"
banner_config

require_file "${STACK_ROOT}/etc/env.sh"
# shellcheck source=/dev/null
source "${STACK_ROOT}/etc/env.sh"
setup_nixl_kv_env "${ROLE}"
require_file "${VENV}/bin/python"

_run_side() {
    local side="$1"
    "${VENV}/bin/python" "${ENGINE}" \
        --mode "${side}" \
        --nonce "${NONCE}" \
        --size "${SIZE}" \
        --max-value-size "${KV_MAX_VALUE_SIZE}" \
        --trid "${NIXL_KV_TRID}"
}

_report() {
    local side="$1" out="$2"
    printf '%s\n' "${out}" | grep -E '^INFO:' | sed 's/^INFO://' \
        | while IFS= read -r line; do log "  [${side}] ${line}"; done
    if printf '%s' "${out}" | grep -q '^RESULT:OK$'; then
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
        _rc=$?
        set -e
        check "write side reports RESULT:OK" bash -c "printf '%s' \"\${1}\"|grep -q '^RESULT:OK$'" _ "${_out}" || true
        _report "write" "${_out}" || true
        ok "nonce for the paired --read invocation: ${NONCE}"
        log "  run on the SAME or a DIFFERENT node:"
        log "    scripts/verify/30-verify-kv-roundtrip.sh --read --nonce=${NONCE} --size=${SIZE}"
        ;;
    read)
        step "READ (this process only, fresh from the writer)"
        set +e
        _out="$(_run_side read)"
        _rc=$?
        set -e
        check "read side reports RESULT:OK" bash -c "printf '%s' \"\${1}\"|grep -q '^RESULT:OK$'" _ "${_out}" || true
        _report "read" "${_out}" || true
        ;;
    both)
        step "WRITE then READ, as two SEPARATE OS processes on this host"
        set +e
        _wout="$(_run_side write)"
        _wrc=$?
        set -e
        check "write side reports RESULT:OK" bash -c "printf '%s' \"\${1}\"|grep -q '^RESULT:OK$'" _ "${_wout}" || true
        _report "write" "${_wout}" || true

        if [ "${_wrc}" -ne 0 ]; then
            err "write side failed — skipping read (nothing valid to read back)"
        else
            set +e
            _rout="$(_run_side read)"
            _rrc=$?
            set -e
            check "read side reports RESULT:OK" bash -c "printf '%s' \"\${1}\"|grep -q '^RESULT:OK$'" _ "${_rout}" || true
            _report "read" "${_rout}" || true
        fi
        ;;
esac

checks_summary
