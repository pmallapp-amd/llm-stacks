#!/usr/bin/env bash
# 99-stop.sh — stop the decode vLLM+LMCache server on SMC2.
#
# Node:          SMC2 (decode), ${DECODE_HOST}. Refuses to run elsewhere.
# Prerequisites: none (safe to run even if vllm-decode isn't running).
# Next step:     scripts/decode/03-start-decode.sh to restart.
#
# usage: 99-stop.sh [--clean-shm]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_host "${DECODE_HOST}" "decode"

step "Stopping vllm-decode"
stop_bg "vllm-decode"

CLEAN_SHM=0
for arg in "$@"; do
    case "${arg}" in
        --clean-shm) CLEAN_SHM=1 ;;
        *) die "unknown argument: ${arg}" ;;
    esac
done

if [ "${CLEAN_SHM}" -eq 1 ]; then
    # See scripts/prefill/99-stop.sh's identical comment: stale SHM from a
    # killed (not cleanly stopped) run is a known crash-on-restart cause for
    # both LMCache's local_cpu tier and NIXL's registered-memory bookkeeping.
    step "Removing stale /dev/shm/lmcache_* and /dev/shm/nixl_* segments"
    shopt -s nullglob
    _removed=0
    for f in /dev/shm/lmcache_* /dev/shm/nixl_*; do
        rm -f "${f}" && _removed=$((_removed + 1))
    done
    shopt -u nullglob
    ok "removed ${_removed} stale SHM segment(s)"
fi

ok "vllm-decode stopped"

# The LMCache MP daemon is this node's own separate host process (started
# by scripts/decode/03-start-decode.sh via scripts/common/
# 30-start-lmcache-daemon.sh, not by vllm-decode itself) — stopping
# vllm-decode above does not touch it. --clean-shm is forwarded so a
# single flag here cleans up after BOTH processes' SHM segments, exactly
# as start-decode.sh starts both with a single command.
if [ "${CLEAN_SHM}" -eq 1 ]; then
    "${REPO_ROOT}/scripts/common/31-stop-lmcache-daemon.sh" --clean-shm
else
    "${REPO_ROOT}/scripts/common/31-stop-lmcache-daemon.sh"
fi
