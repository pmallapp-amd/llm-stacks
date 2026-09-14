#!/usr/bin/env bash
# 00-preflight.sh — non-destructive, read-only inventory + go/no-go.
#
# Node:          any (SMC1 prefill, SMC2 decode, SMC3 target). Must also work
#                cleanly on the GPU-less target — "no GPU" is informational
#                there, never a failure.
# Prerequisites: none (this is the very first script to run on a fresh node).
# Next step:     scripts/common/10-build-stack.sh (SMC1/SMC2, optionally SMC3)
#                or the target's own build script for SMC3.
#
# This script never installs, mutates, or starts anything. It exists so that
# "is this box ready" is answerable in one command before any build step runs
# — every check here is either informational (kernel/CPU/RAM/NIC inventory)
# or a check_soft/check advisory, never a mutation.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Preflight inventory: $(hostname) ($(date -u +%FT%TZ))"

# ─────────────────────────────────────────────────────────────────────────────
# Which node is this? (informational only — no require_host gate: this script
# is explicitly allowed, and expected, to run on a node before it's "claimed".)
# ─────────────────────────────────────────────────────────────────────────────
_local_ips="$(hostname -I 2>/dev/null || true)"
THIS_ROLE="unknown"
case " ${_local_ips} " in
    *" ${PREFILL_HOST} "*) THIS_ROLE="prefill (${PREFILL_NAME})" ;;
    *" ${DECODE_HOST} "*)  THIS_ROLE="decode (${DECODE_NAME})" ;;
    *" ${TARGET_HOST} "*)  THIS_ROLE="target (${TARGET_NAME})" ;;
esac
info "role: ${THIS_ROLE}   local IPs: ${_local_ips:-<none>}"

# ─────────────────────────────────────────────────────────────────────────────
# OS / kernel
# ─────────────────────────────────────────────────────────────────────────────
step "OS / kernel"
log "kernel:  $(uname -r)"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "distro:  ${PRETTY_NAME:-unknown}"
else
    warn "distro:  /etc/os-release not found"
fi
check "kernel is 64-bit"      test "$(uname -m)" = "x86_64" || true
check_soft "uname -r is a modern (>=5.x) kernel" \
    bash -c '[ "$(uname -r | cut -d. -f1)" -ge 5 ]'

# ─────────────────────────────────────────────────────────────────────────────
# CPU / NUMA
# ─────────────────────────────────────────────────────────────────────────────
step "CPU / NUMA layout"
if command -v lscpu >/dev/null 2>&1; then
    lscpu | grep -E '^(Architecture|CPU\(s\)|Thread|Core|Socket|NUMA node)' \
        | while IFS= read -r line; do log "  ${line}"; done
else
    warn "lscpu not found — cannot report CPU/NUMA layout"
fi
check_soft "numactl present (NUMA-aware reactor pinning)" command -v numactl

# ─────────────────────────────────────────────────────────────────────────────
# RAM
# ─────────────────────────────────────────────────────────────────────────────
step "RAM"
_mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
log "MemTotal: $((_mem_kb / 1024 / 1024)) GiB (${_mem_kb} kB)"
check "at least 32 GiB RAM present" bash -c "[ ${_mem_kb} -ge $((32 * 1024 * 1024)) ]" || true

# ─────────────────────────────────────────────────────────────────────────────
# Hugepages — required at RUN time by the SPDK-embedding NIXL plugin on BOTH
# compute nodes (they run the SPDK initiator) and by SPDK on the target.
# ─────────────────────────────────────────────────────────────────────────────
step "Hugepages (need HUGEPAGE_COUNT=${HUGEPAGE_COUNT} x 2MiB)"
_hp_total="$(awk '/^HugePages_Total/{print $2}' /proc/meminfo)"
_hp_free="$(awk '/^HugePages_Free/{print $2}'  /proc/meminfo)"
log "configured: ${_hp_total:-0}   free: ${_hp_free:-0}   wanted: ${HUGEPAGE_COUNT}"
if [ "${_hp_total:-0}" -eq 0 ]; then
    warn "no hugepages configured yet — 01-host-prep.sh will allocate them"
elif [ "${_hp_total:-0}" -lt "${HUGEPAGE_COUNT}" ]; then
    warn "hugepages PARTIALLY allocated (${_hp_total} < ${HUGEPAGE_COUNT})." \
         " A live system rarely has enough physically-contiguous 2MiB pages" \
         " to satisfy a large request after uptime fragments memory; if" \
         " 01-host-prep.sh's allocation is short, reboot BEFORE it tries, or" \
         " lower HUGEPAGE_COUNT and accept a smaller SPDK buffer pool."
else
    ok "hugepages: ${_hp_total} configured (>= ${HUGEPAGE_COUNT} wanted)"
fi
check_soft "/mnt/huge exists (hugetlbfs mountpoint)" test -d /mnt/huge

# ─────────────────────────────────────────────────────────────────────────────
# ROCm / GPUs — informational-only "no GPU" on the target.
# ─────────────────────────────────────────────────────────────────────────────
step "ROCm / GPU"
if [ -d "${ROCM_PATH}" ]; then
    _rocm_ver="unknown"
    [ -r "${ROCM_PATH}/.info/version" ] && _rocm_ver="$(cat "${ROCM_PATH}/.info/version")"
    log "ROCm found at ${ROCM_PATH}, version: ${_rocm_ver}"
    if command -v rocm-smi >/dev/null 2>&1; then
        _gpu_count="$(rocm-smi --showid 2>/dev/null | grep -cE '^GPU\[[0-9]+\]' || true)"
        log "rocm-smi reports ${_gpu_count} GPU(s)"
        check_soft "8 GPUs visible to rocm-smi (TP_SIZE=${TP_SIZE})" \
            bash -c "[ ${_gpu_count} -ge ${TP_SIZE} ]"
    else
        warn "ROCm present but rocm-smi not on PATH"
    fi
    if command -v rocminfo >/dev/null 2>&1; then
        _gfx="$(rocminfo 2>/dev/null | grep -o 'gfx[0-9a-zA-Z]*' | sort -u | tr '\n' ' ')"
        log "rocminfo gfx targets: ${_gfx:-<none found>}"
        check_soft "expected arch ${ROCM_ARCH} present in rocminfo" \
            bash -c "echo '${_gfx}' | grep -q '${ROCM_ARCH}'"
    fi
else
    log "no GPU / ROCm at ${ROCM_PATH} — informational only, expected on the" \
        " storage target (SMC3) and NOT a failure here."
fi

# ─────────────────────────────────────────────────────────────────────────────
# PCIe inventory — vendor 1dd8 covers MI300X GPUs [1dd8:5303], DSC3-2Q400 NICs
# [1dd8:5200] (SMC1/SMC2), and POLLARA-1Q400 NICs [1dd8:1002] (SMC3).
# ─────────────────────────────────────────────────────────────────────────────
step "PCIe inventory (vendor 1dd8: GPUs + data-plane NICs)"
if command -v lspci >/dev/null 2>&1; then
    _pci="$(lspci -d 1dd8: -nn 2>/dev/null || true)"
    if [ -n "${_pci}" ]; then
        printf '%s\n' "${_pci}" | while IFS= read -r line; do log "  ${line}"; done
    else
        warn "no 1dd8: devices found via lspci"
    fi
else
    warn "lspci not found — cannot inventory PCIe devices"
fi
check_soft "lspci available" command -v lspci

# ─────────────────────────────────────────────────────────────────────────────
# NICs — speed / MTU / driver for every non-loopback interface.
# ─────────────────────────────────────────────────────────────────────────────
step "NICs (speed / MTU / driver)"
for _ifpath in /sys/class/net/*; do
    _if="$(basename "${_ifpath}")"
    [ "${_if}" = "lo" ] && continue
    _mtu="$(cat "/sys/class/net/${_if}/mtu" 2>/dev/null || echo '?')"
    _speed="unknown"
    if [ -r "/sys/class/net/${_if}/speed" ]; then
        _speed="$(cat "/sys/class/net/${_if}/speed" 2>/dev/null || echo '?')Mb/s"
    fi
    _driver="unknown"
    if command -v ethtool >/dev/null 2>&1; then
        _driver="$(ethtool -i "${_if}" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')"
    fi
    log "  ${_if}: mtu=${_mtu} speed=${_speed} driver=${_driver:-unknown}"
done
check_soft "ethtool available (NIC speed/driver reporting)" command -v ethtool

# ─────────────────────────────────────────────────────────────────────────────
# RDMA device presence — advisory only in Phase 1 (KV_TRANSPORT=tcp); becomes
# load-bearing in Phase 2 (KV_TRANSPORT=rdma), checked hard by 01-host-prep.sh.
# ─────────────────────────────────────────────────────────────────────────────
step "RDMA devices"
if command -v ibv_devinfo >/dev/null 2>&1; then
    _rdma_devs="$(ibv_devinfo -l 2>/dev/null | tail -n +2 | tr -d ' \t' || true)"
    if [ -n "${_rdma_devs}" ]; then
        printf '%s\n' "${_rdma_devs}" | while IFS= read -r d; do log "  ${d}"; done
    else
        log "  none found (expected in Phase 1 / KV_TRANSPORT=tcp)"
    fi
else
    log "  ibv_devinfo not installed (rdma-core not yet installed — 10-build-stack.sh installs it)"
fi
check_soft "rdma-core userspace tools present" command -v ibv_devinfo

# ─────────────────────────────────────────────────────────────────────────────
# python3
# ─────────────────────────────────────────────────────────────────────────────
step "Python"
if command -v python3 >/dev/null 2>&1; then
    log "python3: $(python3 --version 2>&1)"
else
    warn "python3 not found (needed by 20-build-vllm-lmcache.sh)"
fi
check_soft "python3 >= 3.10" \
    bash -c 'python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)"'

# ─────────────────────────────────────────────────────────────────────────────
# Stack root + disk space
# ─────────────────────────────────────────────────────────────────────────────
step "Stack root and disk space"
if [ -d "${STACK_ROOT}" ]; then
    ok "STACK_ROOT exists: ${STACK_ROOT}"
else
    log "STACK_ROOT does not exist yet: ${STACK_ROOT} (10-build-stack.sh creates it)"
fi
_df_stack_parent="${STACK_ROOT}"
while [ ! -d "${_df_stack_parent}" ] && [ "${_df_stack_parent}" != "/" ]; do
    _df_stack_parent="$(dirname "${_df_stack_parent}")"
done
_free_stack_gb="$(df -Pk "${_df_stack_parent}" | awk 'NR==2{printf "%.1f", $4/1024/1024}')"
log "free disk at ${_df_stack_parent} (STACK_ROOT parent): ${_free_stack_gb} GiB"
check "at least 50 GiB free for ${STACK_ROOT}" \
    bash -c "[ $(printf '%.0f' "${_free_stack_gb}") -ge 50 ]" || true

_df_hf_parent="${HF_HOME}"
while [ ! -d "${_df_hf_parent}" ] && [ "${_df_hf_parent}" != "/" ]; do
    _df_hf_parent="$(dirname "${_df_hf_parent}")"
done
_free_hf_gb="$(df -Pk "${_df_hf_parent}" | awk 'NR==2{printf "%.1f", $4/1024/1024}')"
log "free disk at ${_df_hf_parent} (HF_HOME parent): ${_free_hf_gb} GiB"
check_soft "at least 100 GiB free for ${HF_HOME} (model weights)" \
    bash -c "[ $(printf '%.0f' "${_free_hf_gb}") -ge 100 ]"

# ─────────────────────────────────────────────────────────────────────────────
# Reachability of the OTHER two nodes in the cluster.
# ─────────────────────────────────────────────────────────────────────────────
step "Cluster reachability"
declare -A _peers=(
    ["prefill(${PREFILL_HOST})"]="${PREFILL_HOST} ${PREFILL_PORT}"
    ["decode(${DECODE_HOST})"]="${DECODE_HOST} ${DECODE_PORT}"
    ["target(${TARGET_HOST})"]="${TARGET_HOST} ${NVMF_TRSVCID}"
)
for _label in "${!_peers[@]}"; do
    read -r _ip _port <<< "${_peers[${_label}]}"
    [ "${_ip}" = "${TARGET_HOST}" ] && [[ "${THIS_ROLE}" == target* ]] && continue
    [ "${_ip}" = "${PREFILL_HOST}" ] && [[ "${THIS_ROLE}" == prefill* ]] && continue
    [ "${_ip}" = "${DECODE_HOST}" ] && [[ "${THIS_ROLE}" == decode* ]] && continue
    check "ping reachable: ${_label}" bash -c "ping -c1 -W2 '${_ip}' >/dev/null 2>&1" || true
    # Service port: soft. The port may legitimately not be listening yet if
    # this is being run before the corresponding service/target is started —
    # that is a "not up yet" condition, not a preflight failure. Called
    # directly (not via `bash -c`) because wait_for_port is a shell function
    # from lib.sh, not an external binary — a subshell wouldn't have it.
    check_soft "TCP port reachable: ${_label}:${_port}" \
        wait_for_port "${_ip}" "${_port}" 3
done

banner_config
checks_summary
