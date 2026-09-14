#!/usr/bin/env bash
# run-all.sh — run the applicable scripts/verify/*.sh scripts for whichever
# node this is, in order, stopping at the first hard failure.
#
# Node:          any (SMC1 prefill, SMC2 decode, SMC3 target), or a jump
#                host with reach to all three (in which case only the
#                network-layer and end-to-end checks apply — see the
#                per-role table below).
# Prerequisites: whatever each individual script needs; run in order is the
#                point — 10- before 20- before 30- before 40- because each
#                is written to rule out the layer below it before trusting
#                the layer above.
# Next step:     none — this is the top-level entry point for "is the
#                cluster actually working".
#
# usage: run-all.sh [--skip-throughput] [--skip-rdma]
#   (flags are forwarded to 10-verify-network.sh; the other scripts take no
#   flags this wrapper needs to know about — they infer role/host from
#   cluster.env the same way this script does.)
#
# WHY stop at the first hard failure rather than run everything and
# collect a big report: every later script in this chain assumes the
# earlier ones passed (20- assumes the network is fine; 30- assumes the
# plugin loads; 40- assumes raw NIXL roundtrips work). Running 40- after
# 20- failed would just produce a second, harder-to-read failure report
# for the SAME root cause — worse, not better, information.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK_ARGS=()
for arg in "$@"; do
    case "${arg}" in
        --skip-throughput|--skip-rdma) NETWORK_ARGS+=("${arg}") ;;
        *) die "unknown argument: ${arg} (expected --skip-throughput, --skip-rdma)" ;;
    esac
done

step "run-all: detecting role for $(hostname)"
_local_ips="$(hostname -I 2>/dev/null || true)"
THIS_ROLE="unknown"
case " ${_local_ips} " in
    *" ${PREFILL_HOST} "*) THIS_ROLE="prefill" ;;
    *" ${DECODE_HOST} "*)  THIS_ROLE="decode" ;;
    *" ${TARGET_HOST} "*)  THIS_ROLE="target" ;;
esac
info "role: ${THIS_ROLE}   local IPs: ${_local_ips:-<none>}"

# ─────────────────────────────────────────────────────────────────────────────
# Per-role script list. 10- (network) applies everywhere. 20-/30- (NIXL
# plugin / KV roundtrip) only make sense on a compute node — they need
# ${VENV} and NIXL_PLUGIN_DIR, neither of which exist on the storage
# target. 40- (full disaggregation) needs only network reach to the proxy
# and both vLLM servers, so it applies from ANY host including a jump
# host with THIS_ROLE=unknown — it is the one check that's meaningful
# regardless of which box is running it.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPTS=()
case "${THIS_ROLE}" in
    prefill|decode)
        SCRIPTS+=("10-verify-network.sh")
        SCRIPTS+=("20-verify-nixl-plugin.sh")
        SCRIPTS+=("30-verify-kv-roundtrip.sh")
        SCRIPTS+=("40-verify-disagg.sh")
        ;;
    target)
        SCRIPTS+=("10-verify-network.sh")
        info "skipping 20-/30- on the target: they require \${VENV} +" \
             " NIXL_PLUGIN_DIR, which only exist on a compute node" \
             " (SMC1/SMC2). Run those from prefill or decode instead."
        SCRIPTS+=("40-verify-disagg.sh")
        ;;
    unknown)
        info "role unknown (not one of PREFILL_HOST/DECODE_HOST/TARGET_HOST)" \
             " — running only the checks meaningful from an arbitrary host:" \
             " network reachability and the full end-to-end disaggregation" \
             " proof. Run 20-/30- directly on SMC1 or SMC2 for the" \
             " plugin-level and roundtrip-level checks."
        SCRIPTS+=("10-verify-network.sh")
        SCRIPTS+=("40-verify-disagg.sh")
        ;;
esac

declare -a RESULTS=()
declare -a TIMES=()
_overall_rc=0

for _script in "${SCRIPTS[@]}"; do
    step "run-all: ${_script}"
    _args=()
    [ "${_script}" = "10-verify-network.sh" ] && _args=("${NETWORK_ARGS[@]}")

    _start="$(date +%s)"
    if bash "${VERIFY_DIR}/${_script}" "${_args[@]}"; then
        _rc=0
    else
        _rc=$?
    fi
    _elapsed=$(( $(date +%s) - _start ))
    TIMES+=("${_elapsed}")

    if [ "${_rc}" -eq 0 ]; then
        RESULTS+=("PASS")
        ok "${_script} PASSED (${_elapsed}s)"
    else
        RESULTS+=("FAIL")
        err "${_script} FAILED (${_elapsed}s, exit ${_rc}) — stopping here;" \
            " later checks assume this one passed and would just produce" \
            " a confusing secondary failure."
        _overall_rc=1
        break
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Final summary table. Includes scripts that were SKIPPED (never reached
# because an earlier one failed, or not applicable to this role) so the
# operator can see the full picture, not just what happened to run.
# ─────────────────────────────────────────────────────────────────────────────
step "Summary"
printf '%-32s %-8s %s\n' "SCRIPT" "RESULT" "TIME" >&2
_i=0
for _script in "${SCRIPTS[@]}"; do
    if [ "${_i}" -lt "${#RESULTS[@]}" ]; then
        printf '%-32s %-8s %ss\n' "${_script}" "${RESULTS[${_i}]}" "${TIMES[${_i}]}" >&2
    else
        printf '%-32s %-8s %s\n' "${_script}" "SKIPPED" "-" >&2
    fi
    _i=$((_i + 1))
done

# Scripts intentionally not applicable to this role (informational row).
case "${THIS_ROLE}" in
    target)
        printf '%-32s %-8s %s\n' "20-verify-nixl-plugin.sh" "N/A" "compute-node only" >&2
        printf '%-32s %-8s %s\n' "30-verify-kv-roundtrip.sh" "N/A" "compute-node only" >&2
        ;;
    unknown)
        printf '%-32s %-8s %s\n' "20-verify-nixl-plugin.sh" "N/A" "run on SMC1/SMC2 directly" >&2
        printf '%-32s %-8s %s\n' "30-verify-kv-roundtrip.sh" "N/A" "run on SMC1/SMC2 directly" >&2
        ;;
esac

if [ "${_overall_rc}" -eq 0 ]; then
    ok "run-all: all applicable checks passed"
else
    err "run-all: stopped at the first failure — see the FAIL row above" \
        " and that script's own output for details"
fi
exit "${_overall_rc}"
