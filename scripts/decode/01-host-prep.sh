#!/usr/bin/env bash
# 01-host-prep.sh — decode (SMC2) GPU-node host preparation.
#
# Node:          SMC2 (decode), ${DECODE_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/common/00-preflight.sh green;
#                scripts/common/10-build-stack.sh complete (needs ROCM_PATH,
#                and this script itself is what preps the box that 10- and
#                20- then build on top of — safe to run 01- before 10-/20-,
#                that is the intended order).
# Next step:     scripts/common/10-build-stack.sh (if not already done),
#                then scripts/common/20-build-vllm-lmcache.sh, then
#                scripts/decode/03-start-decode.sh.
#
# Mirrors scripts/prefill/01-host-prep.sh exactly except for role-specific
# hostnames/variables (DECODE_* instead of PREFILL_*) and which peer is the
# "compute leg" (prefill, not decode). Kept as a separate file rather than a
# shared function because require_host must pin the RIGHT host per script —
# see lib.sh's require_host doc comment on why this check exists at all.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_root
require_host "${DECODE_HOST}" "decode"

step "Decode host prep: ${DECODE_NAME} (${DECODE_HOST})"
banner_config

# ─────────────────────────────────────────────────────────────────────────────
# Hugepages
# ─────────────────────────────────────────────────────────────────────────────
step "Hugepages (HUGEPAGE_COUNT=${HUGEPAGE_COUNT})"
mkdir -p /mnt/huge
if ! mountpoint -q /mnt/huge 2>/dev/null; then
    mount -t hugetlbfs nodev /mnt/huge
    ok "mounted hugetlbfs at /mnt/huge"
else
    info "/mnt/huge already mounted"
fi

echo "${HUGEPAGE_COUNT}" > /proc/sys/vm/nr_hugepages
_hp_actual="$(awk '/^HugePages_Total/{print $2}' /proc/meminfo)"
if [ "${_hp_actual}" -lt "${HUGEPAGE_COUNT}" ]; then
    # See scripts/prefill/01-host-prep.sh's identical comment: physically-
    # contiguous 2MiB pages become scarce as uptime fragments memory, and the
    # kernel silently grants fewer than requested.
    warn "requested ${HUGEPAGE_COUNT} hugepages, kernel granted ${_hp_actual}." \
         " This host's memory is fragmented (common after uptime). Reboot" \
         " BEFORE running this again to get a fresh, unfragmented pool, or" \
         " accept the smaller pool by lowering HUGEPAGE_COUNT to match."
else
    ok "hugepages: ${_hp_actual} allocated"
fi

# ─────────────────────────────────────────────────────────────────────────────
# ROCm / GPU verification — hard gate, this node needs TP_SIZE working GPUs.
# ─────────────────────────────────────────────────────────────────────────────
step "ROCm / GPU verification (need >= TP_SIZE=${TP_SIZE} GPUs, arch ${ROCM_ARCH})"
require_cmd rocm-smi rocminfo
_gpu_count="$(rocm-smi --showid 2>/dev/null | grep -cE '^GPU\[[0-9]+\]' || true)"
log "rocm-smi reports ${_gpu_count} GPU(s)"
[ "${_gpu_count}" -ge "${TP_SIZE}" ] \
    || die "only ${_gpu_count} GPUs visible, need >= TP_SIZE=${TP_SIZE}." \
           " vLLM's tensor-parallel launch will hang or crash trying to" \
           " shard across GPUs that don't exist; fix this before continuing."
_gfx="$(rocminfo 2>/dev/null | grep -o 'gfx[0-9a-zA-Z]*' | sort -u | tr '\n' ' ')"
log "rocminfo gfx targets: ${_gfx}"
echo "${_gfx}" | grep -q "${ROCM_ARCH}" \
    || die "expected arch ${ROCM_ARCH} not found in rocminfo output (${_gfx})." \
           " The nvme-kv plugin's VRAM_SEG staging path and vLLM's HIP" \
           " kernels are compiled/dispatched assuming this arch."
ok "GPU check passed: ${_gpu_count} GPUs, arch ${ROCM_ARCH} present"

# ─────────────────────────────────────────────────────────────────────────────
# Kernel modules
# ─────────────────────────────────────────────────────────────────────────────
step "Kernel modules: nvme_tcp nvme_fabrics vfio_pci uio_pci_generic"
for mod in nvme_tcp nvme_fabrics vfio_pci uio_pci_generic; do
    if lsmod | grep -q "^${mod} "; then
        info "${mod} already loaded"
    elif modprobe "${mod}"; then
        ok "loaded ${mod}"
    else
        warn "modprobe ${mod} failed (non-fatal; needed for nvme-oF/TCP and/or PCIe passthrough)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# TCP tuning (shared with prefill + target)
# ─────────────────────────────────────────────────────────────────────────────
"${REPO_ROOT}/scripts/common/tune-tcp.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Data-plane interfaces. The storage leg (-> SMC3) and the compute leg
# (<-> SMC1) can legitimately be different physical NICs/routes — report
# both, do not assume they're the same interface.
# ─────────────────────────────────────────────────────────────────────────────
step "Data-plane interfaces"
_if_storage="$(iface_to "${TARGET_HOST}")"
_if_compute="$(iface_to "${PREFILL_HOST}")"
log "storage leg (-> target ${TARGET_HOST}):  iface=${_if_storage:-<unknown>}"
log "compute leg (-> prefill ${PREFILL_HOST}): iface=${_if_compute:-<unknown>}"
for _if in "${_if_storage}" "${_if_compute}"; do
    [ -z "${_if}" ] && continue
    _mtu="$(cat "/sys/class/net/${_if}/mtu" 2>/dev/null || echo '?')"
    _speed="unknown"
    [ -r "/sys/class/net/${_if}/speed" ] && _speed="$(cat "/sys/class/net/${_if}/speed" 2>/dev/null)Mb/s"
    _driver="$(ethtool -i "${_if}" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')"
    log "  ${_if}: mtu=${_mtu} speed=${_speed} driver=${_driver:-unknown}"
done
if [ -z "${DECODE_DATA_IF}" ]; then
    warn "DECODE_DATA_IF is unset in cluster.env — start-vllm.sh's" \
         " setup_ucx_env call will use UCX's own device autodetection." \
         " Pin DECODE_DATA_IF explicitly once you know which of the above" \
         " ifaces should carry the P<->D UCX side channel (usually" \
         " ${_if_compute:-<compute leg iface>})."
fi

# DSC3-2Q400 NICs [1dd8:5200] + RDMA device presence (Phase 2 prerequisite;
# advisory in Phase 1).
step "DSC3-2Q400 NICs [1dd8:5200] and RDMA devices"
lspci -d 1dd8:5200 -nn 2>/dev/null | while IFS= read -r line; do log "  ${line}"; done
if command -v ibv_devinfo >/dev/null 2>&1; then
    ibv_devinfo -l 2>/dev/null | tail -n +2 | while IFS= read -r d; do log "  rdma dev: ${d}"; done
fi
if [ "${KV_TRANSPORT}" = "rdma" ] && [ -z "${DECODE_RDMA_DEV}" ]; then
    die "KV_TRANSPORT=rdma but DECODE_RDMA_DEV is unset — setup_ucx_env" \
        " will refuse to start vLLM without it (see lib.sh)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# PYTORCH_HIP_ALLOC_CONF guidance -> stack env file.
# See scripts/prefill/01-host-prep.sh's identical comment for WHY:
# expandable_segments breaks HIP IPC export of vLLM's KV tensors.
# ─────────────────────────────────────────────────────────────────────────────
step "PYTORCH_HIP_ALLOC_CONF"
mkdir -p "${STACK_ROOT}/etc"
if [ -f "${STACK_ROOT}/etc/env.sh" ] && grep -q PYTORCH_HIP_ALLOC_CONF "${STACK_ROOT}/etc/env.sh"; then
    ok "PYTORCH_HIP_ALLOC_CONF already set in ${STACK_ROOT}/etc/env.sh"
else
    info "${STACK_ROOT}/etc/env.sh does not exist yet (created by" \
         " 20-build-vllm-lmcache.sh, which already bakes this in) —" \
         " nothing to do here yet; re-run this check after that script."
fi

# ─────────────────────────────────────────────────────────────────────────────
# memlock limits — required for RDMA memory registration (Phase 2) and for
# SPDK's hugepage pinning (both phases: the plugin embeds SPDK's DPDK EAL
# regardless of KV_TRANSPORT).
# ─────────────────────────────────────────────────────────────────────────────
step "memlock limits"
LIMITS_FILE="/etc/security/limits.d/99-kvstack.conf"
cat > "${LIMITS_FILE}" <<'EOF'
# Managed by scripts/decode/01-host-prep.sh (and prefill's equivalent) —
# do not hand-edit, re-run the script.
#
# unlimited memlock: SPDK (embedded in the nvme-kv plugin) pins its hugepage
# pool with mlock(); the default 64KB soft limit means spdk_env_init() fails
# to lock down its DMA-capable memory immediately at plugin construction,
# which surfaces to NIXL as the plugin's create_backend() throwing, which
# NIXL then just logs as a generic backend-init failure. In Phase 2
# (KV_TRANSPORT=rdma) the same unlimited memlock is ALSO required for
# ibv_reg_mr() to pin arbitrary amounts of userspace memory for RDMA.
* soft memlock unlimited
* hard memlock unlimited
EOF
ok "wrote ${LIMITS_FILE} (takes effect on next login/session; a running" \
   " shell used to launch vLLM must be a NEW session after this)"

# ─────────────────────────────────────────────────────────────────────────────
# Target reachability (soft — target may not be started yet)
# ─────────────────────────────────────────────────────────────────────────────
step "Target reachability (soft check — target may not be up yet)"
if wait_for_port "${TARGET_HOST}" "${NVMF_TRSVCID}" 5; then
    ok "target ${TARGET_HOST}:${NVMF_TRSVCID} reachable"
else
    warn "target ${TARGET_HOST}:${NVMF_TRSVCID} not reachable yet — fine if" \
         " SMC3 hasn't started its NVMe-oF target; start-vllm.sh will" \
         " refuse to launch vLLM until this is up."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Directories
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${STACK_ROOT}" "${LOG_DIR}" "${RUN_DIR}" "${HF_HOME}"
ok "directories present: ${STACK_ROOT} ${LOG_DIR} ${RUN_DIR} ${HF_HOME}"

ok "decode host prep complete"
log "next: scripts/common/10-build-stack.sh (if not already run), then" \
    " scripts/common/20-build-vllm-lmcache.sh, then" \
    " scripts/decode/03-start-decode.sh"
