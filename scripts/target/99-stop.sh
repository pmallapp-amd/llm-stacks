#!/usr/bin/env bash
# 99-stop.sh — stop the SMC3 NVMe-KV target (nvmf_tgt).
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
    if [ "${TARGET_HUGE_PAGES}" -gt 0 ]; then
        step "Releasing hugepages"
        # Same sysfs node scripts/target/03-start-kv-target.sh writes to
        # when TARGET_HUGE_PAGES>0 (rocm-aic/target.sh's mechanism:
        # /proc/sys/vm/nr_hugepages, not the per-size hugetlbfs sysfs node
        # scripts/target/01-host-prep.sh uses for the initiator-style
        # allocation path).
        echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
        ok "nr_hugepages set to 0"
    else
        info "TARGET_HUGE_PAGES=0 — kv-target never allocated hugepages" \
             " (it runs --no-huge); nothing to release"
    fi
else
    info "hugepages left allocated (use --release-hugepages to zero them," \
         " only meaningful if TARGET_HUGE_PAGES>0)"
fi

if [ "${CLEAN_CONFIG}" -eq 1 ]; then
    step "Removing generated --json config"
    rm -f "${STACK_ROOT}/etc/kv-target.json"
    ok "removed ${STACK_ROOT}/etc/kv-target.json"
fi

ok "kv-target stopped"
