#!/usr/bin/env bash
# 30-bench-concurrency.sh — concurrency sweep at a fixed shape, prefix
# caching ON, to find where the remote KV tier saturates.
#
# Node:          anywhere with network reach to the proxy.
# Prerequisites: scripts/bench/01-install-benchy.sh; full P/D stack up.
#                Strongly recommended: scripts/bench/20-bench-prefix-cache.sh
#                already run, so you know prefix caching is delivering a
#                benefit at concurrency=1 before looking for where it stops.
# Next step:     none — read ${LOG_DIR} for backpressure evidence per this
#                script's own header comment, and compare_runs.py across
#                this run's concurrency rows to see where t/s (total)
#                stops scaling with concurrency.
#
# usage: 30-bench-concurrency.sh [--pp N] [--tg N] [--depth N]
#   Fixed shape defaults to the LARGEST value in each of BENCHY_PP/
#   BENCHY_TG/BENCHY_DEPTH (config/cluster.env) — the sweep's own
#   heaviest-case shape — since saturation is a function of how much KV
#   the remote tier has to move per request; the smallest shape in the
#   sweep is the least likely to ever saturate anything.
#
# WHY THIS MATTERS (KV_BACKEND=SPDK_NVMe_KV): the SPDK initiator on
# prefill/decode runs ${KV_NUM_QPAIRS} qpairs against the SMC3 target
# (config/cluster.env). Each in-flight KV store/retrieve consumes one
# qpair slot for its duration. Concurrency BEYOND that qpair count is
# exactly where the plugin's own backpressure handling engages — see
# plugins/nvme-kv/spdk_nvme_kv_backend.h's drain_retry_queue() and
# maybe_report_backpressure() — because SPDK's nvmf initiator returns
# -ENOMEM when it cannot get a free qpair/request slot immediately, and the
# plugin's own retry queue is what absorbs that rather than failing the
# request outright.
#
# WHY THIS MATTERS (KV_BACKEND=XNVME_KV): the XNVME_KV plugin on
# prefill/decode opens ${XNVME_NUM_QUEUES} independent I/O queues (one
# xnvme_dev + one xnvme_queue + one reactor pthread each — see
# plugins/xnvme-kv/xnvme_kv_backend.h's QueueWorker) against the LOCAL
# Pensando DSC char device (config/cluster.env's XNVME_DEV). Each
# in-flight KV store/retrieve consumes one queue's ctx-pool slot for its
# duration. Concurrency BEYOND what those queues can absorb is exactly
# where the plugin's own backpressure handling engages — see
# xnvme_kv_backend.cpp's reactor_loop()/submit_one(): the device returning
# -EBUSY/-EAGAIN/-ENOMEM means "queue/device temporarily full", and the
# work item is put back and retried rather than the request failing
# outright. (A DIFFERENT failure mode entirely — the queue making
# literally zero forward progress for ${XNVME_STALL_TIMEOUT_SEC}s — is the
# device-wedged case documented on XNVME_STALL_TIMEOUT_SEC in
# config/cluster.env; that is not what saturation looks like and would
# show as a hard error, not a latency climb.)
#
# Below saturation (either backend), the retry path never engages and
# request latency should be flat as concurrency rises. AT or above it,
# expect e2e_ttft/est_ppt to start climbing super-linearly with
# concurrency: that inflection point IS the tier's saturation point.
#
# GREP PATTERN TO WATCH (in ${LOG_DIR}, on prefill/decode, while this runs):
#   grep -E 'ENOMEM|backpressure|drain_retry_queue|no forward progress' ${LOG_DIR}/vllm-prefill.log ${LOG_DIR}/vllm-decode.log
# A clean run at the concurrency levels in BENCHY_CONCURRENCY that never
# matches this pattern is itself informational: it means this sweep never
# reached saturation, and BENCHY_CONCURRENCY should be raised to actually
# find the knee.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-bench.sh"

_max_of() {
    # _max_of "512 1024 2048" -> 2048 (space-separated list of integers)
    printf '%s\n' "$1" | tr ' ' '\n' | sort -n | tail -1
}

FIXED_PP="$(_max_of "${BENCHY_PP}")"
FIXED_TG="$(_max_of "${BENCHY_TG}")"
FIXED_DEPTH="$(_max_of "${BENCHY_DEPTH}")"

for arg in "$@"; do
    case "${arg}" in
        --pp=*) FIXED_PP="${arg#--pp=}" ;;
        --tg=*) FIXED_TG="${arg#--tg=}" ;;
        --depth=*) FIXED_DEPTH="${arg#--depth=}" ;;
        *) die "unknown argument: ${arg} (expected --pp=N, --tg=N, --depth=N)" ;;
    esac
done

BASE_URL="http://${PROXY_HOST}:${PROXY_PORT}/v1"

step "Concurrency saturation sweep against proxy: ${BASE_URL}"
log "  fixed shape: pp=${FIXED_PP} tg=${FIXED_TG} depth=${FIXED_DEPTH}"
log "  concurrency sweep: ${BENCHY_CONCURRENCY}"
case "${KV_BACKEND}" in
    SPDK_NVMe_KV)
        log "  KV_NUM_QPAIRS=${KV_NUM_QPAIRS} — watch for backpressure once" \
            " concurrency exceeds this (see this script's header comment)"
        ;;
    XNVME_KV)
        log "  XNVME_NUM_QUEUES=${XNVME_NUM_QUEUES} — watch for backpressure once" \
            " concurrency exceeds this (see this script's header comment)"
        ;;
esac
banner_config
ensure_dirs

benchy_preflight "${BASE_URL}"

# shellcheck disable=SC2086
# Intentional word-split of BENCHY_CONCURRENCY — see lib-bench.sh's
# benchy_run comment; --pp/--tg/--depth here are single scalars (already
# unquoted-safe) but concurrency remains the multi-value sweep axis.
RUNDIR="$(benchy_run "concurrency" "${BASE_URL}" \
    --enable-prefix-caching \
    --pp "${FIXED_PP}" \
    --tg "${FIXED_TG}" \
    --depth "${FIXED_DEPTH}" \
    --concurrency ${BENCHY_CONCURRENCY} \
    --save-total-throughput-timeseries)"

ok "concurrency sweep complete: ${RUNDIR}"
log "  now check for backpressure log lines during the run window:"
log "  grep -E 'ENOMEM|backpressure|drain_retry_queue|no forward progress' ${LOG_DIR}/vllm-prefill.log ${LOG_DIR}/vllm-decode.log"
