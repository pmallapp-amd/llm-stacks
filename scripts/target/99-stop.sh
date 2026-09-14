#!/usr/bin/env bash
# 99-stop.sh — stop the SMC3 NVMe-KV target (spdk_tgt).
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: none (safe to run even if kv-target isn't running).
# Next step:     scripts/target/03-start-kv-target.sh to restart.
#
# usage: 99-stop.sh [--release-hugepages] [--clean-config]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_host "${TARGET_HOST}" "target"

RELEASE_HUGEPAGES=0
CLEAN_CONFIG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --release-hugepages) RELEASE_HUGEPAGES=1 ;;
        --clean-config)      CLEAN_CONFIG=1 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

step "Stopping kv-target"
stop_bg "kv-target"

if [ "${RELEASE_HUGEPAGES}" -eq 1 ]; then
    step "Releasing hugepages"
    # WHY opt-in, not automatic: the same 2MiB hugepage pool sized by
    # HUGEPAGE_COUNT is what scripts/target/01-host-prep.sh fought memory
    # fragmentation to allocate in the first place (see its comment on
    # partial grants). Zeroing it back to reclaim RAM for something else
    # means the NEXT scripts/target/03-start-kv-target.sh run has to re-win
    # that same fragmentation fight from scratch — worth doing only when
    # this host is being repurposed or is under real memory pressure, not
    # on every routine stop/start cycle.
    echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    ok "nr_hugepages set to 0"
else
    info "hugepages left allocated (use --release-hugepages to zero them)"
fi

if [ "${CLEAN_CONFIG}" -eq 1 ]; then
    step "Removing saved RPC config"
    rm -f "${STACK_ROOT}/etc/kv-target-config.json"
    ok "removed ${STACK_ROOT}/etc/kv-target-config.json"
fi

ok "kv-target stopped"
