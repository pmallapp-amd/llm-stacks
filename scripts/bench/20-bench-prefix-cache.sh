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
# usage: 20-bench-prefix-cache.sh (no flags — always targets the proxy;
#   depth>0 requires the FULL disaggregated path, priming through the
#   proxy, to mean anything. Pointing this at prefill or decode directly
#   would skip the very hop under test.)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-bench.sh"

[ "$#" -eq 0 ] || die "20-bench-prefix-cache.sh takes no arguments" \
    " (it always targets the proxy — see this script's header comment" \
    " for why depth>0 is meaningless against prefill or decode alone)"

BASE_URL="http://${PROXY_HOST}:${PROXY_PORT}/v1"

step "Prefix-cache benefit sweep against proxy: ${BASE_URL}"
log "  depth sweep: ${BENCHY_DEPTH}"
banner_config
ensure_dirs

benchy_preflight "${BASE_URL}"

# shellcheck disable=SC2086
# Intentional word-split of BENCHY_DEPTH — see lib-bench.sh's benchy_run
# comment; the same reasoning applies to this direct pass-through call.
RUNDIR="$(benchy_run "prefix-cache" "${BASE_URL}" \
    --enable-prefix-caching \
    --depth ${BENCHY_DEPTH})"

ok "prefix-cache sweep complete: ${RUNDIR}"
log "next: python3 $(dirname "${BASH_SOURCE[0]}")/compare_runs.py --prefix-benefit ${RUNDIR}/result.json"

# Printed on stdout, deliberately the ONLY stdout output of this script —
# see 10-bench-baseline.sh's identical trailing comment for why.
printf '%s\n' "${RUNDIR}"
