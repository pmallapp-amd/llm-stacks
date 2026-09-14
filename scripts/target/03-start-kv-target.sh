#!/usr/bin/env bash
# 03-start-kv-target.sh — start spdk_tgt and configure the NVMe-KV namespace
# on SMC3.
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/target/01-host-prep.sh, scripts/target/02-build-
#                spdk-kv.sh both complete.
# Next step:     scripts/target/04-verify-target.sh, then attach initiators
#                from SMC1 (prefill) and SMC2 (decode) — they run vLLM with
#                LMCache's SPDK_NVMe_KV NIXL backend pointed at ${KV_TRID}.
#
# The RPC configuration sequence (transport/bdev/subsystem/ns/listener) is
# shared with scripts/target/50-reset-namespace.sh via lib-kv-rpc.sh, so
# "fresh start" and "drain and recreate" cannot drift into two different
# configurations of the same target.
#
# usage: 03-start-kv-target.sh [--foreground] [--restart] [--skip-config]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-kv-rpc.sh"

require_root
require_host "${TARGET_HOST}" "target"

FOREGROUND=0
RESTART=0
SKIP_CONFIG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --foreground)  FOREGROUND=1 ;;
        --restart)     RESTART=1 ;;
        --skip-config) SKIP_CONFIG=1 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

step "KV target start: ${TARGET_NAME} (${TARGET_HOST})"
banner_config

# Fail BEFORE touching the process at all — see lib-kv-rpc.sh's comment on
# why this check has to happen ahead of nvmf_create_transport, not after.
kv_target_check_sgl

if [ "${KV_TRANSPORT}" = "rdma" ]; then
    step "RDMA transport requested — Phase 2 prerequisites"
    if [ -d /sys/class/infiniband ] && [ -n "$(ls -A /sys/class/infiniband 2>/dev/null)" ]; then
        ok "/sys/class/infiniband non-empty: $(find /sys/class/infiniband -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"
    else
        warn "/sys/class/infiniband is empty or absent — no RDMA-capable" \
             " device visible to the kernel on this host." \
             " nvmf_create_transport -t RDMA will fail without one."
    fi
    # This does NOT block the target from coming up on RDMA — it only warns
    # that the initiator side needs an explicit opt-in rebuild, so an
    # operator who flips KV_TRANSPORT=rdma expecting the WHOLE path to work
    # isn't left guessing why SMC1/SMC2 still fail to attach after this
    # script reports success.
    warn "KV_TRANSPORT=rdma: the TARGET side can still come up on RDMA, but" \
         " the INITIATOR side (the SPDK_NVMe_KV NIXL plugin on SMC1/SMC2) is" \
         " RDMA-capable only if it was built with -Denable_rdma=true —" \
         " that option defaults to FALSE (see plugins/nvme-kv/meson.build /" \
         " meson_options.txt). It needs: the initiator's own SPDK tree" \
         " configured --with-rdma (SPDK_WITH_RDMA=1, scripts/common/05-" \
         " build-spdk-initiator.sh), prepare-spdk-libs.sh's" \
         " libspdk_nvme_rdma_only.a split actually produced (only happens" \
         " if nvme_rdma.o exists in that tree's libspdk_nvme.a), and the" \
         " plugin meson-configured with -Denable_rdma=true + rebuilt. This" \
         " script will still bring the target up on RDMA regardless; the" \
         " initiators will not be able to attach until all of the above is" \
         " actually true, which this script cannot verify from SMC3."
fi

SPDK_TGT_BIN="${SPDK_TARGET_SRC}/build/bin/spdk_tgt"
require_file "${SPDK_TGT_BIN}"

# ─────────────────────────────────────────────────────────────────────────────
# CPU mask: honor an explicit override, else derive from nproc. Default
# 0x3C (cores 2-5) leaves cores 0-1 for the kernel/IRQs/everything else on
# this box, which has no GPU workload competing for cores.
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${SPDK_TGT_CPUMASK:-}" ]; then
    _cpumask="${SPDK_TGT_CPUMASK}"
else
    _nproc="$(nproc)"
    if [ "${_nproc}" -ge 6 ]; then
        _cpumask="0x3C"
    else
        _mask=0
        _i=1
        while [ "${_i}" -lt "${_nproc}" ]; do
            _mask=$(( _mask | (1 << _i) ))
            _i=$(( _i + 1 ))
        done
        [ "${_mask}" -eq 0 ] && _mask=1
        _cpumask="$(printf '0x%X' "${_mask}")"
    fi
fi
info "spdk_tgt cpumask=${_cpumask} (nproc=$(nproc))"

if [ "${RESTART}" -eq 1 ] && is_running "kv-target"; then
    step "Restart requested — stopping existing kv-target first"
    stop_bg "kv-target"
fi

mkdir -p /mnt/huge

if [ "${FOREGROUND}" -eq 1 ]; then
    info "running spdk_tgt in the FOREGROUND (Ctrl-C to stop)." \
         " RPC configuration will NOT run automatically in this mode —" \
         " from a second shell, either re-run this script without" \
         " --foreground (it will see kv-target is not tracked as running" \
         " and simply attempt the RPC sequence against the running" \
         " process's socket) or call the RPC steps by hand via" \
         " ${SPDK_TARGET_SRC}/scripts/rpc.py -s ${SPDK_RPC_SOCK} ..."
    exec "${SPDK_TGT_BIN}" -m "${_cpumask}" -r "${SPDK_RPC_SOCK}" --huge-dir /mnt/huge
fi

if is_running "kv-target"; then
    ok "kv-target already running — not restarting (use --restart to bounce it)"
else
    start_bg "kv-target" "${SPDK_TGT_BIN}" -m "${_cpumask}" -r "${SPDK_RPC_SOCK}" --huge-dir /mnt/huge
fi

step "Waiting for RPC socket ${SPDK_RPC_SOCK}"
wait_for_file "${SPDK_RPC_SOCK}" 60 \
    || die "spdk_tgt did not create ${SPDK_RPC_SOCK} within 60s — check" \
           " $(logfile_for kv-target)"
retry 10 2 rpc_json spdk_get_version >/dev/null \
    || die "rpc.py spdk_get_version did not respond after 10 attempts —" \
           " spdk_tgt may have failed to initialize; check" \
           " $(logfile_for kv-target)"
ok "spdk_tgt RPC responding"

if [ "${SKIP_CONFIG}" -eq 1 ]; then
    info "--skip-config: leaving RPC configuration untouched"
else
    kv_target_apply_config
fi

ok "kv-target up"
log "TRID for initiators: ${KV_TRID}"
log "verify from this host: scripts/target/04-verify-target.sh"
log "verify from SMC1/SMC2: nvme discover -t tcp -a ${NVMF_TRADDR} -s ${NVMF_TRSVCID}"
