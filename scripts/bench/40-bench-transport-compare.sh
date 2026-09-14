#!/usr/bin/env bash
# 40-bench-transport-compare.sh — TCP-vs-RDMA comparison. THE
# acceptance-criteria measurement (config/cluster.env's "Transport
# selection — THE phase gate" section: Phase 1 is TCP, Phase 2 is RDMA,
# and flipping KV_TRANSPORT is the single switch acceptance turns on).
#
# Node:          anywhere with network reach to the proxy.
# Prerequisites: scripts/bench/01-install-benchy.sh; scripts/bench/
#                20-bench-prefix-cache.sh already run at least once under
#                the CURRENT KV_TRANSPORT (ideally under BOTH transports,
#                one at a time — see below).
# Next step:     none — this is the acceptance-gate comparison itself.
#
# usage: 40-bench-transport-compare.sh
#
# WHAT THIS SCRIPT DOES NOT DO, ON PURPOSE: it does NOT restart anything.
# Flipping KV_TRANSPORT requires restarting the NVMe-oF target on SMC3 AND
# both vLLM servers on SMC1/SMC2 (the transport is selected at process
# startup via KV_TRID — see config/cluster.env's NVMF_TRTYPE derivation —
# not something a running plugin can hot-swap). Restarting three
# production-shaped services is an operator decision this harness has no
# business making unattended, especially since RDMA also has prerequisites
# beyond the env var flip (docs/BRINGUP.md §9: the SPDK plugin as
# committed links no RDMA transport object without additional build
# input) that this script cannot verify from here.
#
# THE OPERATOR PROCEDURE THIS SCRIPT PRINTS AND WAITS FOR:
#   1. Run this script once under the CURRENT transport (it records a run
#      tagged with that transport and exits).
#   2. Edit config/cluster.env: set KV_TRANSPORT=rdma (or back to tcp).
#   3. Restart, IN ORDER: the target (SMC3), then prefill (SMC1), then
#      decode (SMC2). See docs/BRINGUP.md for the restart sequence.
#   4. Re-run scripts/bench/20-bench-prefix-cache.sh under the new
#      transport.
#   5. Re-run THIS script. If a prior run tagged with the OTHER transport
#      is found under ${BENCHY_RESULT_DIR}, it is compared automatically.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-bench.sh"

[ "$#" -eq 0 ] || die "40-bench-transport-compare.sh takes no arguments"

BASE_URL="http://${PROXY_HOST}:${PROXY_PORT}/v1"

step "Transport comparison — current KV_TRANSPORT=${KV_TRANSPORT}"
banner_config
ensure_dirs

benchy_preflight "${BASE_URL}"

LABEL="transport-${KV_TRANSPORT}"
# shellcheck disable=SC2086
# Intentional word-split of BENCHY_DEPTH — see lib-bench.sh's benchy_run
# comment.
RUNDIR="$(benchy_run "${LABEL}" "${BASE_URL}" \
    --enable-prefix-caching \
    --depth ${BENCHY_DEPTH})"

ok "recorded run under transport=${KV_TRANSPORT}: ${RUNDIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Look for a prior run tagged with the OTHER transport. Directory naming
# convention is <timestamp>-<label> where label is transport-tcp or
# transport-rdma (set above) — a simple glob is sufficient, no index file
# needed since ${BENCHY_RESULT_DIR} is not expected to hold enough runs to
# make that painful.
# ─────────────────────────────────────────────────────────────────────────────
OTHER_TRANSPORT="tcp"
[ "${KV_TRANSPORT}" = "tcp" ] && OTHER_TRANSPORT="rdma"

OTHER_RUNDIR=""
for d in "${BENCHY_RESULT_DIR}"/*"-transport-${OTHER_TRANSPORT}"; do
    [ -d "${d}" ] || continue
    OTHER_RUNDIR="${d}"
done

if [ -z "${OTHER_RUNDIR}" ]; then
    step "No prior transport=${OTHER_TRANSPORT} run found under ${BENCHY_RESULT_DIR}"
    log "To complete the comparison:"
    log "  1. Edit config/cluster.env: set KV_TRANSPORT=${OTHER_TRANSPORT}"
    log "  2. Restart, IN ORDER: target (SMC3) -> prefill (SMC1) -> decode (SMC2)"
    log "     (see docs/BRINGUP.md for the exact restart commands)"
    log "  3. Re-run scripts/bench/20-bench-prefix-cache.sh to confirm the" \
        " new transport is actually up and caching"
    log "  4. Re-run this script (scripts/bench/40-bench-transport-compare.sh)" \
        " — it will find this run (${RUNDIR}) automatically and compare."
    exit 0
fi

step "Found prior transport=${OTHER_TRANSPORT} run: ${OTHER_RUNDIR}"
log "comparing (baseline = ${OTHER_TRANSPORT}, since it ran first chronologically" \
    " is not assumed — --baseline is set explicitly to the OTHER run below)"

BASELINE_JSON="${OTHER_RUNDIR}/result.json"
CURRENT_JSON="${RUNDIR}/result.json"

python3 "$(dirname "${BASH_SOURCE[0]}")/compare_runs.py" \
    --format md \
    --baseline 0 \
    "${BASELINE_JSON}" "${CURRENT_JSON}"

ok "transport comparison complete (tcp vs rdma)"
