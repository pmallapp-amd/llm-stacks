#!/usr/bin/env bash
# 10-bench-baseline.sh — cold-start baseline, cache deliberately bypassed.
#
# Node:          anywhere with network reach to the target endpoint
#                (proxy by default, or --target prefill|decode directly).
# Prerequisites: scripts/bench/01-install-benchy.sh; the endpoint under
#                test is up (scripts/proxy/start-proxy.sh and/or
#                scripts/prefill/03-start-prefill.sh /
#                scripts/decode/03-start-decode.sh).
# Next step:     scripts/bench/20-bench-prefix-cache.sh — that script's
#                whole result is meaningless without this one: it reports
#                a warm-vs-cold DELTA, and this baseline is the "cold"
#                side of every such delta.
#
# usage: 10-bench-baseline.sh [--target prefill|decode|proxy]
#
# WHY this is its own script rather than depth=0 rows embedded inside
# 20-bench-prefix-cache.sh: --no-cache is a distinct, stronger guarantee
# than --depth 0. --depth 0 means "no cached prefix was staged for this
# shape"; it does NOT guarantee vLLM's own automatic prefix caching
# (--enable-prefix-caching is a llama-benchy flag, but vLLM ALSO has its
# own server-side prefix cache that can still produce a partial hit on
# overlapping prompt content across the sweep) is disabled. --no-cache is
# llama-benchy's explicit instruction to defeat that too. Without a run
# that forces both caches off, there is no honest denominator: every later
# "X% faster warm" claim is a comparison against a number that might
# ALSO have been partially cached.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-bench.sh"

TARGET="proxy"
for arg in "$@"; do
    case "${arg}" in
        --target=*) TARGET="${arg#--target=}" ;;
        --target) shift; TARGET="${1:-}" ;;
        *) die "unknown argument: ${arg} (expected --target=prefill|decode|proxy)" ;;
    esac
done

case "${TARGET}" in
    proxy)   BASE_URL="http://${PROXY_HOST}:${PROXY_PORT}/v1" ;;
    prefill) BASE_URL="http://${PREFILL_HOST}:${PREFILL_PORT}/v1" ;;
    decode)  BASE_URL="http://${DECODE_HOST}:${DECODE_PORT}/v1" ;;
    *) die "invalid --target='${TARGET}' (expected prefill|decode|proxy)" ;;
esac

step "Baseline benchmark (cold, --no-cache) against ${TARGET}: ${BASE_URL}"
banner_config
ensure_dirs

benchy_preflight "${BASE_URL}"

RUNDIR="$(benchy_run "baseline-${TARGET}" "${BASE_URL}" \
    --no-cache \
    --depth 0)"

ok "baseline complete: ${RUNDIR}"
log "  result.json / result.md / progress.jsonl / run.env are all under that directory"
log "next: scripts/bench/20-bench-prefix-cache.sh"

# Printed on stdout, deliberately the ONLY stdout output of this script
# (everything else above goes through log/info/ok/warn, which write to
# stderr) — this is what lets scripts/bench/run-all.sh capture the run
# directory path via command substitution without scraping log text.
printf '%s\n' "${RUNDIR}"
