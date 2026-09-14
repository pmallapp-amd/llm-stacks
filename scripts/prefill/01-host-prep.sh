#!/usr/bin/env bash
# 01-host-prep.sh — prefill (SMC1) GPU-node host preparation.
#
# Node:          SMC1 (prefill), ${PREFILL_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/common/00-preflight.sh green;
#                scripts/common/10-build-stack.sh complete (needs ROCM_PATH,
#                and this script itself is what preps the box that 10- and
#                20- then build on top of — safe to run 01- before 10-/20-,
#                that is the intended order).
# Next step:     scripts/common/10-build-stack.sh (if not already done),
#                then scripts/common/20-build-vllm-lmcache.sh, then
#                scripts/prefill/03-start-prefill.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_root
require_host "${PREFILL_HOST}" "prefill"

step "Prefill host prep: ${PREFILL_NAME} (${PREFILL_HOST})"
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
    # Physically-contiguous 2MiB pages become scarce as host uptime grows and
    # memory fragments; the kernel silently grants fewer than requested
    # rather than erroring. A short-allocated hugepage pool means SPDK's
    # embedded DPDK EAL gets less memory than KV_NUM_QPAIRS x reactor buffers
    # need, and it fails at spdk_env_init() time with a message that gives
    # no hint the root cause is fragmentation, not configuration.
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
# TCP tuning (shared with decode + target)
# ─────────────────────────────────────────────────────────────────────────────
"${REPO_ROOT}/scripts/common/tune-tcp.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Data-plane interfaces. The storage leg (-> SMC3) and the compute leg
# (<-> SMC2) can legitimately be different physical NICs/routes — report
# both, do not assume they're the same interface.
# ─────────────────────────────────────────────────────────────────────────────
step "Data-plane interfaces"
_if_storage="$(iface_to "${TARGET_HOST}")"
_if_compute="$(iface_to "${DECODE_HOST}")"
log "storage leg (-> target ${TARGET_HOST}):  iface=${_if_storage:-<unknown>}"
log "compute leg (-> decode  ${DECODE_HOST}): iface=${_if_compute:-<unknown>}"
for _if in "${_if_storage}" "${_if_compute}"; do
    [ -z "${_if}" ] && continue
    _mtu="$(cat "/sys/class/net/${_if}/mtu" 2>/dev/null || echo '?')"
    _speed="unknown"
    [ -r "/sys/class/net/${_if}/speed" ] && _speed="$(cat "/sys/class/net/${_if}/speed" 2>/dev/null)Mb/s"
    _driver="$(ethtool -i "${_if}" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')"
    log "  ${_if}: mtu=${_mtu} speed=${_speed} driver=${_driver:-unknown}"
done
if [ -z "${PREFILL_DATA_IF}" ]; then
    warn "PREFILL_DATA_IF is unset in cluster.env — start-vllm.sh's" \
         " setup_ucx_env call will use UCX's own device autodetection." \
         " Pin PREFILL_DATA_IF explicitly once you know which of the above" \
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
if [ "${KV_TRANSPORT}" = "rdma" ] && [ -z "${PREFILL_RDMA_DEV}" ]; then
    die "KV_TRANSPORT=rdma but PREFILL_RDMA_DEV is unset — setup_ucx_env" \
        " will refuse to start vLLM without it (see lib.sh)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# PYTORCH_HIP_ALLOC_CONF guidance -> stack env file.
#
# WHY expandable_segments must be OFF here: vLLM's NIXL/UCX KV-transfer path
# (both the direct P<->D NixlConnector side channel and this plugin's
# VRAM_SEG registration) exports a HIP IPC handle for the KV cache tensor so
# a peer process/agent can map the same device memory. The expandable-segment
# allocator can grow or relocate the underlying virtual mapping backing an
# already-allocated tensor at any later allocation, which invalidates any
# handle already exported for it without notifying whoever imported it — the
# peer's mapping becomes silently stale, showing up as corrupted or garbage
# KV data with no error at the point of failure. This has to be set before
# vLLM's process starts allocating (it is a HIP/PyTorch allocator config
# read once at first use), which is why it's baked into
# ${STACK_ROOT}/etc/env.sh rather than left to be remembered per-launch.
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
# Managed by scripts/prefill/01-host-prep.sh (and decode's equivalent) —
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

ok "prefill host prep complete"
log "next: scripts/common/10-build-stack.sh (if not already run), then" \
    " scripts/common/20-build-vllm-lmcache.sh, then" \
    " scripts/prefill/03-start-prefill.sh"
