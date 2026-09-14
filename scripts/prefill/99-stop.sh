#!/usr/bin/env bash
# 99-stop.sh — stop the prefill vLLM+LMCache server on SMC1.
#
# Node:          SMC1 (prefill), ${PREFILL_HOST}. Refuses to run elsewhere.
# Prerequisites: none (safe to run even if vllm-prefill isn't running).
# Next step:     scripts/prefill/03-start-prefill.sh to restart.
#
# usage: 99-stop.sh [--clean-shm]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_host "${PREFILL_HOST}" "prefill"

step "Stopping vllm-prefill"
stop_bg "vllm-prefill"

CLEAN_SHM=0
for arg in "$@"; do
    case "${arg}" in
        --clean-shm) CLEAN_SHM=1 ;;
        *) die "unknown argument: ${arg}" ;;
    esac
done

if [ "${CLEAN_SHM}" -eq 1 ]; then
    # WHY this matters: LMCache's local_cpu tier and NIXL's registered-memory
    # bookkeeping both use /dev/shm segments as backing store for pinned
    # host buffers. A killed-not-stopped process (SIGKILL, OOM, crash) can
    # leave these behind; on restart, LMCache/NIXL may try to reuse a segment
    # whose size or generation no longer matches what the new process
    # expects, which has been observed to crash the NEW process during its
    # own init — a stale-SHM crash-on-restart that looks like a fresh bug
    # each time because the actual cause (leftover state from the PREVIOUS
    # run) isn't in this run's logs at all.
    step "Removing stale /dev/shm/lmcache_* and /dev/shm/nixl_* segments"
    shopt -s nullglob
    _removed=0
    for f in /dev/shm/lmcache_* /dev/shm/nixl_*; do
        rm -f "${f}" && _removed=$((_removed + 1))
    done
    shopt -u nullglob
    ok "removed ${_removed} stale SHM segment(s)"
fi

ok "vllm-prefill stopped"
