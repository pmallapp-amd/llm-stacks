#!/usr/bin/env bash
# stop-lmcache-daemon.sh — stop the LMCache MP-mode daemon on THIS node.
#
# Node:          any node running scripts/common/start-lmcache-daemon.sh
#                (SMC1 prefill or SMC2 decode) — no require_host gate, see
#                that script's header for why (loopback-only, per-host).
# Prerequisites: none (safe to run even if lmcache-mp-daemon isn't running).
# Next step:     scripts/common/start-lmcache-daemon.sh to restart.
#
# usage: stop-lmcache-daemon.sh [--clean-shm] [--grace-sec N]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLEAN_SHM=0
GRACE_SEC=20
while [ $# -gt 0 ]; do
    case "$1" in
        --clean-shm) CLEAN_SHM=1 ;;
        --grace-sec)
            shift
            GRACE_SEC="${1:-}"
            [ -n "${GRACE_SEC}" ] || die "--grace-sec requires a value"
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

step "Stopping lmcache-mp-daemon"
stop_bg "lmcache-mp-daemon" "${GRACE_SEC}"

if [ "${CLEAN_SHM}" -eq 1 ]; then
    # Same hazard scripts/prefill/99-stop.sh and scripts/decode/99-stop.sh
    # document for the vLLM side: a killed-not-stopped process (SIGKILL,
    # OOM, crash) can leave /dev/shm/lmcache_* segments behind (this
    # daemon's --shm-name defaults to auto-allocate — see
    # scripts/common/start-lmcache-daemon.sh), and a restart that
    # reuses a stale segment whose size/generation no longer matches can
    # crash the NEW process during its own init.
    step "Removing stale /dev/shm/lmcache_* segments"
    shopt -s nullglob
    _removed=0
    for f in /dev/shm/lmcache_*; do
        rm -f "${f}" && _removed=$((_removed + 1))
    done
    shopt -u nullglob
    ok "removed ${_removed} stale SHM segment(s)"
fi

ok "lmcache-mp-daemon stopped"
