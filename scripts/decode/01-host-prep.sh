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
# amdgpu autoload override (see ensure_amdgpu_loaded() in lib.sh) — MUST run
# before the ROCm/GPU verification below. This node boots with
# modprobe.blacklist=amdgpu on its kernel cmdline (2026-09-14), which blocks
# only AUTOload, not an explicit `modprobe amdgpu` by name — so this loads it
# every run, and the rocminfo `die` right after this step is the fallback for
# when that genuinely didn't work.
# ─────────────────────────────────────────────────────────────────────────────
ensure_amdgpu_loaded

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
# advisory in Phase 1). Also reports the ionic_* -> PCI-device mapping so an
# operator can pin DECODE_UCX_NET_DEVICES to the CORRECT physical port on
# THIS host — F3: the device index is not guaranteed to line up the same
# way on SMC2 as it does on SMC1 (e.g. ionic_2 can be a different physical
# port on each). Only ionic_0/ionic_1 are confirmed to line up.
step "DSC3-2Q400 NICs [1dd8:5200], RDMA devices, and ionic_* -> PCI mapping"
lspci -d 1dd8:5200 -nn 2>/dev/null | while IFS= read -r line; do log "  ${line}"; done
if command -v ibv_devinfo >/dev/null 2>&1; then
    ibv_devinfo -l 2>/dev/null | tail -n +2 | while IFS= read -r d; do log "  rdma dev: ${d}"; done
fi
if [ -d /sys/class/infiniband ]; then
    for _ibdev in /sys/class/infiniband/*; do
        [ -e "${_ibdev}" ] || continue
        _ibname="$(basename "${_ibdev}")"
        _ibpci="$(basename "$(readlink -f "${_ibdev}/device" 2>/dev/null || true)" 2>/dev/null || true)"
        log "  ${_ibname} -> pci=${_ibpci:-<unknown>}"
    done
    warn "F3 (verified 2026-09-11): cross-check the pci= addresses above" \
         " against this host's physical cabling before trusting" \
         " DECODE_UCX_NET_DEVICES='${DECODE_UCX_NET_DEVICES}' in" \
         " config/cluster.env — the same ionic_N NAME can be a different" \
         " physical port on SMC1, so a value copied verbatim from" \
         " prefill's report is not safe to assume correct here."
else
    info "/sys/class/infiniband absent — nothing to map yet (fine for" \
         " KV_TRANSPORT=tcp; required before Phase 2)."
fi
if [ "${KV_TRANSPORT}" = "rdma" ] && [ -z "${DECODE_RDMA_DEV}" ]; then
    die "KV_TRANSPORT=rdma but DECODE_RDMA_DEV is unset — setup_ucx_env" \
        " will refuse to start vLLM without it (see lib.sh)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# RDMA device ACCESS (F4) — distinct from device PRESENCE above. Node files
# existing is not the same as this process being able to open them. Hard
# gate in RDMA mode (reuses lib.sh's require_rdma_access, the same
# preflight start-vllm.sh runs before every launch); advisory-only in TCP
# mode, since Phase 1 doesn't need RDMA access yet but a problem here WILL
# block Phase 2 later, so it's worth surfacing now rather than at cutover.
# ─────────────────────────────────────────────────────────────────────────────
step "RDMA device access (required in RDMA mode, advisory in TCP mode — F4)"
if [ "${KV_TRANSPORT}" = "rdma" ]; then
    require_rdma_access "${DECODE_UCX_NET_DEVICES}"
else
    shopt -s nullglob
    _uverbs_nodes=(/dev/infiniband/uverbs*)
    shopt -u nullglob
    if [ "${#_uverbs_nodes[@]}" -eq 0 ]; then
        info "no /dev/infiniband/uverbs* nodes yet (advisory — not needed" \
             " until KV_TRANSPORT=rdma)"
    else
        _uverbs_opened=0
        for _uv in "${_uverbs_nodes[@]}"; do
            if { exec 3<>"${_uv}"; } 2>/dev/null; then
                exec 3>&- 2>/dev/null || true
                _uverbs_opened=1
                break
            fi
        done
        if [ "${_uverbs_opened}" -eq 1 ]; then
            ok "uverbs node(s) present and openable: ${_uverbs_nodes[*]}"
        else
            warn "uverbs node(s) present but NOT openable (EPERM) —" \
                 " harmless under KV_TRANSPORT=tcp today, but per F4 this" \
                 " WILL block KV_TRANSPORT=rdma later, and it presents as" \
                 " a ~90-second HANG (vLLM's EngineCore compiles for ~60s" \
                 " before it ever reaches the connector), not an" \
                 " immediate, obvious error. Fix device permissions" \
                 " (device cgroup rule, udev rule, group membership) before" \
                 " Phase 2 cutover."
        fi
    fi
    if command -v ibv_devinfo >/dev/null 2>&1; then
        _devinfo_soft="$(ibv_devinfo 2>/dev/null || true)"
        if printf '%s\n' "${_devinfo_soft}" | grep -q 'state:.*PORT_ACTIVE'; then
            ok "ibv_devinfo: at least one port PORT_ACTIVE"
        else
            warn "ibv_devinfo: no port reports PORT_ACTIVE (advisory in TCP mode)"
        fi
    else
        warn "ibv_devinfo not installed — cannot report RDMA port state (advisory)"
    fi
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

_memlock_now="$(ulimit -l)"
if [ "${_memlock_now}" = "unlimited" ]; then
    ok "THIS session's memlock is already unlimited — F4's preflight" \
       " (require_rdma_access, run by start-vllm.sh in RDMA mode) will pass"
else
    warn "THIS session's memlock is still '${_memlock_now}', not unlimited" \
         " — ${LIMITS_FILE} was just written but limits only apply to a" \
         " NEW login session. Log out/in (or start a fresh shell) before" \
         " running scripts/common/start-vllm.sh in RDMA mode, or its" \
         " require_rdma_access preflight will refuse to start."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Firewall — open the NIXL side-channel port to the peer (prefill) node.
# Same pattern as scripts/target/01-host-prep.sh's NVMe-oF port opening: act
# only if a host firewall is actually enforcing anything, and say so
# plainly if neither ufw nor firewalld is active rather than guessing at
# iptables rules. Without this, the side-channel handshake (F2) can fail
# exactly the way an unreachable loopback default does — silently, until
# the peer actually tries to connect.
# ─────────────────────────────────────────────────────────────────────────────
step "Firewall (${NIXL_SIDE_CHANNEL_PORT_DECODE}/tcp, NIXL side channel <- ${PREFILL_NAME})"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow "${NIXL_SIDE_CHANNEL_PORT_DECODE}/tcp" comment "NIXL side channel (kvstack, decode)"
    ok "ufw: opened ${NIXL_SIDE_CHANNEL_PORT_DECODE}/tcp"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${NIXL_SIDE_CHANNEL_PORT_DECODE}/tcp"
    firewall-cmd --reload
    ok "firewalld: opened ${NIXL_SIDE_CHANNEL_PORT_DECODE}/tcp"
else
    info "neither ufw nor firewalld is active — no firewall changes made" \
         " (if some other mechanism blocks" \
         " ${NIXL_SIDE_CHANNEL_PORT_DECODE}/tcp, e.g. raw iptables/nftables" \
         " rules or an upstream security group, open it there manually)"
fi

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
