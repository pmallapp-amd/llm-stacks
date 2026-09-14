#!/usr/bin/env bash
# 03-start-kv-target.sh — start nvmf_tgt with the PROVEN bdev_kvmalloc KV
# namespace configuration (config/cluster.env, every value traced to
# rocm-aic/target.sh).
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/target/01-host-prep.sh, scripts/target/02-build-
#                spdk-kv.sh both complete.
# Next step:     scripts/target/04-verify-target.sh, then attach initiators
#                from SMC1 (prefill) / SMC2 (decode) — they run vLLM with
#                LMCache's SPDK_NVMe_KV NIXL backend pointed at ${KV_TRID}.
#
# WHY --json, not an rpc.py sequence: an earlier version of this script
# brought nvmf_tgt up bare and then ran nvmf_create_transport / bdev_
# kvmalloc_create / nvmf_create_subsystem / nvmf_subsystem_add_ns /
# nvmf_subsystem_add_listener as five SEPARATE RPCs, sharing that sequence
# with scripts/target/50-reset-namespace.sh so the two could not drift
# apart. A single --json config file handed to nvmf_tgt at startup removes
# that entire class of bug: the whole configuration is applied atomically
# before the process ever accepts a connection, and regenerating the same
# file from the same env is idempotent by construction — this is
# rocm-aic/target.sh's approach exactly. See scripts/target/lib-kv-rpc.sh's
# kv_target_gen_json_config() for the generator (every value in it traces
# to that file) — rpc.py is now used ONLY for read-only inspection, in
# scripts/target/04-verify-target.sh.
#
# Binary is nvmf_tgt, not spdk_tgt: rocm-aic/target.sh's own binary name.
# An earlier version of this repo guessed spdk_tgt, which is not what a
# --with-nvmf build produces — that target lives at build/bin/nvmf_tgt.
#
# usage: 03-start-kv-target.sh [--foreground] [--restart]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-kv-rpc.sh"

require_root
require_host "${TARGET_HOST}" "target"

FOREGROUND=0
RESTART=0
while [ $# -gt 0 ]; do
    case "$1" in
        --foreground)  FOREGROUND=1 ;;
        --restart)     RESTART=1 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

step "KV target start: ${TARGET_NAME} (${TARGET_HOST})"
banner_config

# Fail BEFORE touching the process at all.
kv_target_check_sgl
kv_target_sanity_check_traddr

NVMF_TGT_BIN="${SPDK_TARGET_SRC}/build/bin/nvmf_tgt"
require_file "${NVMF_TGT_BIN}"

# ─────────────────────────────────────────────────────────────────────────────
# Generate the --json config. Deterministic from config/cluster.env — safe
# to regenerate on every start, including a --restart (scripts/target/50-
# reset-namespace.sh relies on exactly this property).
# ─────────────────────────────────────────────────────────────────────────────
KV_TARGET_JSON="${STACK_ROOT}/etc/kv-target.json"
kv_target_gen_json_config "${KV_TARGET_JSON}"
ok "generated ${KV_TARGET_JSON}"

# ─────────────────────────────────────────────────────────────────────────────
# Hugepages: TARGET_HUGE_PAGES=0 (default, config/cluster.env) matches
# rocm-aic/target.sh's proven configuration exactly — nvmf_tgt runs
# --no-huge -s ${TARGET_MEM_MB} (malloc-backed DPDK EAL memory, no
# hugetlbfs dependency). Set TARGET_HUGE_PAGES>0 to instead allocate that
# many 2MiB hugepages and drop --no-huge/-s.
# ─────────────────────────────────────────────────────────────────────────────
declare -a _extra_args=()
if [ "${TARGET_HUGE_PAGES}" -gt 0 ]; then
    step "Allocating ${TARGET_HUGE_PAGES} x 2MiB huge pages"
    echo "${TARGET_HUGE_PAGES}" > /proc/sys/vm/nr_hugepages 2>/dev/null \
        || warn "could not set /proc/sys/vm/nr_hugepages — nvmf_tgt may" \
                " fail to start"
    mkdir -p /mnt/huge
else
    info "TARGET_HUGE_PAGES=0 (default) — malloc-backed, no hugetlbfs" \
         " dependency (rocm-aic/target.sh's proven configuration)"
    _extra_args+=(--no-huge -s "${TARGET_MEM_MB}")
fi

_cpumask="${SPDK_TGT_CPUMASK}"
info "nvmf_tgt cpumask=${_cpumask} (SPDK_TGT_CPUMASK)"

if [ "${RESTART}" -eq 1 ] && is_running "kv-target"; then
    step "Restart requested — stopping existing kv-target first"
    stop_bg "kv-target"
fi

export LD_LIBRARY_PATH="${SPDK_TARGET_SRC}/dpdk/build/lib:${LD_LIBRARY_PATH:-}"

if [ "${FOREGROUND}" -eq 1 ]; then
    info "running nvmf_tgt in the FOREGROUND (Ctrl-C to stop). The" \
         " entire configuration is applied from --json at startup — there" \
         " is no separate RPC step to run from a second shell anymore."
    exec "${NVMF_TGT_BIN}" \
        --json "${KV_TARGET_JSON}" \
        -m "${_cpumask}" \
        -r "${SPDK_RPC_SOCK}" \
        "${_extra_args[@]}"
fi

if is_running "kv-target"; then
    ok "kv-target already running — not restarting (use --restart to bounce it)"
else
    start_bg "kv-target" "${NVMF_TGT_BIN}" \
        --json "${KV_TARGET_JSON}" \
        -m "${_cpumask}" \
        -r "${SPDK_RPC_SOCK}" \
        "${_extra_args[@]}"
fi

step "Waiting for RPC socket ${SPDK_RPC_SOCK}"
wait_for_file "${SPDK_RPC_SOCK}" 60 \
    || die "nvmf_tgt did not create ${SPDK_RPC_SOCK} within 60s — check" \
           " $(logfile_for kv-target)"
retry 10 2 rpc_json spdk_get_version >/dev/null \
    || die "rpc.py spdk_get_version did not respond after 10 attempts —" \
           " nvmf_tgt may have failed to apply --json ${KV_TARGET_JSON};" \
           " check $(logfile_for kv-target)"
ok "nvmf_tgt RPC responding — --json config applied atomically at startup"

ok "kv-target up"
log "TRID for initiators: ${KV_TRID}"
log "verify from this host: scripts/target/04-verify-target.sh"
log "verify from SMC1/SMC2: nvme discover -t tcp -a ${NVMF_TRADDR} -s ${NVMF_TRSVCID}"
