#!/usr/bin/env bash
# 20-bench-prefix-cache.sh — THE headline benchmark: does the remote KV
# cache on SMC3 actually deliver a prefill-latency win.
#
# Node:          anywhere with network reach to the proxy.
# Prerequisites: scripts/bench/01-install-benchy.sh;
#                scripts/bench/10-bench-baseline.sh already run (its
#                result is the cold denominator this script's warm numbers
#                are compared against); the full P/D stack up (proxy +
#                prefill + decode).
# Next step:     scripts/bench/compare_runs.py --prefix-benefit on this
#                run's result.json — that is the single number answering
#                "did the remote KV cache help".
#
# WHAT THIS MEASURES, PRECISELY:
#
# --enable-prefix-caching with --depth > 0 makes llama-benchy run a
# two-step protocol PER SHAPE (see config/cluster.env's BENCHY_DEPTH
# comment and the top-level task's "VERIFIED llama-benchy facts"):
#
#   1. Context Load  — sends the depth-N context as a system message with
#      a minimal probe. This forces the PROXY to run its priming request
#      to the PREFILL node (scripts/proxy/disagg_proxy.py's
#      _prime_prefill()), which runs the full forward pass over that
#      context and stores the resulting KV chunks into the shared LMCache
#      NIXL namespace on SMC3. Reported as `ctx_pp @ d{N}` / `ctx_tg @
#      d{N}` — this row IS the prefill node populating the remote tier.
#
#   2. Inference     — sends the SAME context as system message plus the
#      real prompt as user message. The proxy's priming step runs again
#      (same content -> same content-derived key -> LMCache lookup should
#      now HIT instead of recomputing), then decode's own real request
#      also looks up the same key. Reported as `pp{n} @ d{N}` / `tg{n} @
#      d{N}` — this row IS the decode node retrieving what step 1 stored.
#
# THE COMPARISON THAT ANSWERS THE QUESTION: this script's `pp{n} @ d{N}`
# rows (warm) against 10-bench-baseline.sh's `pp{n}` row at depth 0, cache
# disabled (cold), for the SAME prompt_size/response_size/concurrency. The
# gap between them IS the disaggregated-cache benefit. compare_runs.py
# --prefix-benefit computes this automatically from a single result.json
# that contains both depth==0 and depth>0 rows (this script's OWN sweep
# includes depth=0 as the first element of BENCHY_DEPTH by default — see
# config/cluster.env — specifically so a single result.json is
# self-contained for that comparison; 10-bench-baseline.sh's separate
# --no-cache run remains the STRONGER cross-check, since it also defeats
# vLLM's own server-side prefix cache, which this script's depth=0 rows do
# not).
#
# ═══════════════════════════════════════════════════════════════════════════
# F5 — THE MEASUREMENT TRAP THIS SCRIPT IS EXPOSED TO (read before trusting
# any speedup number this script reports)
# ═══════════════════════════════════════════════════════════════════════════
# vLLM's OWN prefix cache sits UPSTREAM of the connector layer (LMCache /
# NixlConnector). If it hits, NO connector is consulted at all. With a
# large GPU KV cache (this cluster's default GPU_MEM_UTIL leaves the
# overwhelming majority of 192GB/GPU HBM3 for KV — see config/cluster.env's
# model comment), a same-instance "warm" repeat sent back to the SAME
# decode process can be served entirely out of vLLM's own cache, making
# the disaggregated-cache tier look like it delivered the win when it was
# never consulted. This is exactly the shape of this script's own
# depth>0 "Inference" step: it re-sends the SAME context to the SAME
# proxy -> decode path a second time.
#
# A speedup number from this script is THEREFORE NOT, on its own, proof
# the connector tier did anything. An honest reuse number is either
# CROSS-INSTANCE (decode loading what prefill stored, never having run
# that context itself) or measured only AFTER the GPU cache has genuinely
# been evicted — and even then, confirm it with a non-zero "need to load:"
# and a non-zero "External prefix cache hit rate" in decode's own log, not
# with the presence of --enable-prefix-caching or a plausible-looking
# number. This confound invalidated every earlier retrieve measurement on
# the reference project this repo's compute leg is modeled on.
#
# Use --confirm-connector-hit (below) to have this script check for that
# log evidence itself, immediately after the sweep, and fail loudly if it
# is absent — see docs/BENCHMARKING.md's own F5 section for the full
# writeup and scripts/verify/50-verify-pd-direct.sh for the single-request,
# unambiguous version of the same check.
# ═══════════════════════════════════════════════════════════════════════════
#
# usage: 20-bench-prefix-cache.sh [--confirm-connector-hit]
#   (no other flags — always targets the proxy; depth>0 requires the FULL
#   disaggregated path, priming through the proxy, to mean anything.
#   Pointing this at prefill or decode directly would skip the very hop
#   under test.)
#
#   --confirm-connector-hit   after the sweep, grep ${LOG_DIR}/vllm-decode.log
#                             for connector evidence (F5) and die loudly if
#                             none is found. REQUIRES running this script ON
#                             the decode node (SMC2) — the log is not
#                             fetched remotely.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-bench.sh"

CONFIRM_CONNECTOR_HIT=0
for arg in "$@"; do
    case "${arg}" in
        --confirm-connector-hit) CONFIRM_CONNECTOR_HIT=1 ;;
        *) die "unknown argument: ${arg} (expected --confirm-connector-hit;" \
               " see this script's header comment for why it takes no" \
               " other flags)" ;;
    esac
done

BASE_URL="http://${PROXY_HOST}:${PROXY_PORT}/v1"

step "Prefix-cache benefit sweep against proxy: ${BASE_URL}"
log "  depth sweep: ${BENCHY_DEPTH}"
banner_config
ensure_dirs

_decode_log="$(logfile_for "vllm-decode")"
_decode_log_lines_before=0
if [ "${CONFIRM_CONNECTOR_HIT}" -eq 1 ]; then
    [ -f "${_decode_log}" ] || die "--confirm-connector-hit requires" \
        " ${_decode_log} to exist locally — run this flag ON the decode" \
        " node (SMC2), not from a jump host/laptop. Grepping the log is" \
        " the only reliable way to rule out the F5 confound (vLLM's own" \
        " upstream prefix cache serving every repeat with no connector" \
        " ever consulted); see this script's F5 header comment."
    _decode_log_lines_before="$(wc -l < "${_decode_log}")"
fi

benchy_preflight "${BASE_URL}"

# shellcheck disable=SC2086
# Intentional word-split of BENCHY_DEPTH — see lib-bench.sh's benchy_run
# comment; the same reasoning applies to this direct pass-through call.
RUNDIR="$(benchy_run "prefix-cache" "${BASE_URL}" \
    --enable-prefix-caching \
    --depth ${BENCHY_DEPTH})"

ok "prefix-cache sweep complete: ${RUNDIR}"
log "next: python3 $(dirname "${BASH_SOURCE[0]}")/compare_runs.py --prefix-benefit ${RUNDIR}/result.json"

if [ "${CONFIRM_CONNECTOR_HIT}" -eq 1 ]; then
    step "Confirming a connector was actually consulted during this sweep (F5)"
    _decode_new_log="$(tail -n "+$((_decode_log_lines_before + 1))" "${_decode_log}")"
    if printf '%s\n' "${_decode_new_log}" | grep -qE 'need to load: *[1-9][0-9]*' || \
       printf '%s\n' "${_decode_new_log}" | grep -qE 'External prefix cache hit rate' || \
       printf '%s\n' "${_decode_new_log}" | grep -qiE 'lmcache.*(hit|retriev).*[1-9]'; then
        ok "connector activity found in ${_decode_log} for this sweep —" \
           " the warm rows above reflect a real connector hit, not just" \
           " vLLM's own upstream prefix cache serving every repeat"
    else
        err "no connector activity ('need to load:', 'External prefix" \
            " cache hit rate', or an lmcache hit/retrieve log line with a" \
            " nonzero count) found in ${_decode_log} for this sweep."
        die "connector-hit confirmation FAILED (F5): every repeat in this" \
            " sweep was most likely served by vLLM's OWN upstream prefix" \
            " cache, which sits ABOVE the connector layer — LMCache and" \
            " NixlConnector were never consulted, and this run's speedup" \
            " number is MEANINGLESS as a measurement of the disaggregated" \
            " cache. See docs/BENCHMARKING.md's F5 section."
    fi
fi

# Printed on stdout, deliberately the ONLY stdout output of this script —
# see 10-bench-baseline.sh's identical trailing comment for why.
printf '%s\n' "${RUNDIR}"
