#!/usr/bin/env bash
# 01-host-prep.sh — target (SMC3) storage-node host preparation.
#
# Node:          SMC3 (target), ${TARGET_HOST} / target. No GPU.
#                2x POLLARA-1Q400 [1dd8:1002] @ 64:00.0, 84:00.0. Refuses to
#                run elsewhere.
# Prerequisites: outbound network access to the distro apt mirror; root.
# Next step:     scripts/target/02-build-spdk-kv.sh, then
#                scripts/target/03-start-kv-target.sh.
#
# Unlike scripts/prefill|decode/01-host-prep.sh (GPU nodes, ROCm gate), this
# node has no GPU to verify — its job is: apt deps for building kv_spdk,
# hugepages, TCP tuning, data-plane NIC inventory (storage leg only — this
# node has no compute-leg UCX side channel), firewall, memlock, directories.
#
# usage: 01-host-prep.sh [--skip-apt]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_root
require_host "${TARGET_HOST}" "target"

SKIP_APT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-apt) SKIP_APT=1 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

step "Target host prep: ${TARGET_NAME} (${TARGET_HOST})"
banner_config

# ─────────────────────────────────────────────────────────────────────────────
# 1. apt dependencies — everything scripts/target/02-build-spdk-kv.sh needs
#    to configure/build kv_spdk from source, plus nvme-cli/ethtool/pciutils
#    for the verification and NIC-inventory steps below.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_APT}" -eq 1 ]; then
    info "apt deps — skipped (--skip-apt)"
else
    step "apt dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        build-essential git meson ninja-build python3-pyelftools python3-pip \
        pkg-config libnuma-dev uuid-dev libssl-dev libaio-dev libiscsi-dev \
        liburing-dev nasm autoconf automake libtool help2man \
        nvme-cli ethtool pciutils
    ok "apt deps installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Hugepages — SPDK's embedded DPDK EAL pins its DMA-capable memory pool
#    out of this pool at spdk_env_init() time (scripts/target/03-start-kv-
#    target.sh). Written to the per-size sysfs node (not /proc/sys/vm/
#    nr_hugepages) so this script's request is unambiguous about which page
#    size it wants, regardless of what other hugepage sizes this host might
#    also have configured.
# ─────────────────────────────────────────────────────────────────────────────
step "Hugepages (HUGEPAGE_COUNT=${HUGEPAGE_COUNT} x 2MiB)"
HP_SYSFS="/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
require_file "${HP_SYSFS}"
echo "${HUGEPAGE_COUNT}" > "${HP_SYSFS}"
_hp_actual="$(cat "${HP_SYSFS}")"
if [ "${_hp_actual}" -lt "${HUGEPAGE_COUNT}" ]; then
    # Physically-contiguous 2MiB pages become scarce as host uptime grows
    # and memory fragments; the kernel silently grants fewer than requested
    # rather than erroring. A short-allocated pool means spdk_tgt's DPDK EAL
    # gets less memory than its reactor/qpair buffers need and fails at
    # spdk_env_init() time with a message that gives no hint the root cause
    # is fragmentation, not configuration.
    _pct_short=$(( (HUGEPAGE_COUNT - _hp_actual) * 100 / HUGEPAGE_COUNT ))
    warn "requested ${HUGEPAGE_COUNT} hugepages, kernel granted ${_hp_actual}" \
         " (short by ${_pct_short}%)."
    if [ "${_pct_short}" -gt 10 ]; then
        warn "SHORT BY MORE THAN 10% — this host's memory is significantly" \
             " fragmented. REBOOT this host before running this again to" \
             " get a fresh, unfragmented pool; spdk_tgt is likely to fail" \
             " to start with only ${_hp_actual} hugepages."
    fi
else
    ok "hugepages: ${_hp_actual} allocated"
fi

step "hugetlbfs mount at /mnt/huge"
mkdir -p /mnt/huge
if ! mountpoint -q /mnt/huge 2>/dev/null; then
    mount -t hugetlbfs nodev /mnt/huge
    ok "mounted hugetlbfs at /mnt/huge"
else
    info "/mnt/huge already mounted"
fi
if grep -qE '^\S+\s+/mnt/huge\s+hugetlbfs\s' /etc/fstab 2>/dev/null; then
    info "/mnt/huge already in /etc/fstab"
else
    echo "nodev /mnt/huge hugetlbfs defaults 0 0" >> /etc/fstab
    ok "added /mnt/huge to /etc/fstab (survives reboot)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Kernel modules
# ─────────────────────────────────────────────────────────────────────────────
step "Kernel modules: nvme_tcp nvme_fabrics vfio_pci uio_pci_generic"
for mod in nvme_tcp nvme_fabrics vfio_pci uio_pci_generic; do
    if lsmod | grep -q "^${mod} "; then
        info "${mod} already loaded"
    elif modprobe "${mod}" 2>/dev/null; then
        ok "loaded ${mod}"
    else
        warn "modprobe ${mod} failed (non-fatal — builtin into the kernel," \
             " or not needed on this transport/hardware combination)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# 4. TCP tuning (shared with prefill + decode)
# ─────────────────────────────────────────────────────────────────────────────
"${REPO_ROOT}/scripts/common/tune-tcp.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Data-plane interface — this node only carries the storage leg (NVMe-oF
#    to both SMC1 AND SMC2); there is no compute-leg UCX side channel here.
#    Report both routes and warn if they differ (same physical NIC serving
#    both initiators is the common case on a 2-port Pollara card, but not
#    guaranteed by topology alone).
# ─────────────────────────────────────────────────────────────────────────────
step "Data-plane interfaces (storage leg: -> prefill, -> decode)"
_if_prefill="$(iface_to "${PREFILL_HOST}")"
_if_decode="$(iface_to "${DECODE_HOST}")"
log "-> prefill (${PREFILL_HOST}): iface=${_if_prefill:-<unknown>}"
log "-> decode  (${DECODE_HOST}): iface=${_if_decode:-<unknown>}"
if [ -n "${_if_prefill}" ] && [ -n "${_if_decode}" ] && [ "${_if_prefill}" != "${_if_decode}" ]; then
    warn "prefill and decode routes go out DIFFERENT interfaces" \
         " (${_if_prefill} vs ${_if_decode}). Both are valid NVMe-oF/TCP" \
         " initiators against the same target — just confirm this is" \
         " intentional (e.g. two physical links deliberately split across" \
         " the two consumers) and not a routing misconfiguration."
fi
for _if in "${_if_prefill}" "${_if_decode}"; do
    [ -z "${_if}" ] && continue
    _mtu="$(cat "/sys/class/net/${_if}/mtu" 2>/dev/null || echo '?')"
    _speed="unknown"
    [ -r "/sys/class/net/${_if}/speed" ] && _speed="$(cat "/sys/class/net/${_if}/speed" 2>/dev/null)Mb/s"
    _driver="$(ethtool -i "${_if}" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')"
    log "  ${_if}: mtu=${_mtu} speed=${_speed} driver=${_driver:-unknown}"
    if [ "${_mtu}" != "9000" ] && [ "${_mtu}" != "?" ]; then
        # NOT applied automatically: this is the interface an existing SSH
        # session to this host may be running over. Flipping its MTU out
        # from under a live session can hang or drop that session (and any
        # in-flight NVMe-oF/TCP connection on it) with no clean rollback
        # path from inside the same session. The operator must apply this
        # deliberately, from a console or a connection that does not depend
        # on the interface being changed.
        info "  recommend MTU 9000 on ${_if} for NVMe-oF/TCP jumbo frames" \
             " (currently ${_mtu}). NOT applied automatically. Exact command:"
        info "    ip link set dev ${_if} mtu 9000"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# 6. POLLARA-1Q400 NICs [1dd8:1002] @ 64:00.0, 84:00.0 + RDMA presence
#    (Phase 2 prerequisite; advisory in Phase 1 / KV_TRANSPORT=tcp).
# ─────────────────────────────────────────────────────────────────────────────
step "POLLARA-1Q400 NICs [1dd8:1002] and RDMA device presence"
_pci="$(lspci -d 1dd8:1002 -nn 2>/dev/null || true)"
if [ -n "${_pci}" ]; then
    printf '%s\n' "${_pci}" | while IFS= read -r line; do log "  ${line}"; done
else
    warn "no 1dd8:1002 devices found via lspci — expected 2x POLLARA-1Q400" \
         " at 64:00.0 and 84:00.0 on this node"
fi
if [ -d /sys/class/infiniband ] && [ -n "$(ls -A /sys/class/infiniband 2>/dev/null)" ]; then
    ok "/sys/class/infiniband non-empty: $(find /sys/class/infiniband -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"
else
    info "/sys/class/infiniband is empty or absent — fine for" \
         " KV_TRANSPORT=tcp (current: ${KV_TRANSPORT}); required before" \
         " Phase 2 (KV_TRANSPORT=rdma) can bring the target transport up."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Firewall — open the NVMe-oF/TCP service port if a host firewall is
#    actually enforcing anything; do nothing (and say so) if neither
#    ufw nor firewalld is active, rather than guessing at iptables rules.
# ─────────────────────────────────────────────────────────────────────────────
step "Firewall (${NVMF_TRSVCID}/tcp)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow "${NVMF_TRSVCID}/tcp" comment "NVMe-oF/TCP kv-target (kvstack)"
    ok "ufw: opened ${NVMF_TRSVCID}/tcp"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${NVMF_TRSVCID}/tcp"
    firewall-cmd --reload
    ok "firewalld: opened ${NVMF_TRSVCID}/tcp"
else
    info "neither ufw nor firewalld is active — no firewall changes made" \
         " (if some other mechanism blocks ${NVMF_TRSVCID}/tcp, e.g. raw" \
         " iptables/nftables rules or an upstream security group, open it" \
         " there manually)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. memlock limits — SPDK's DPDK EAL mlock()s its hugepage pool at
#    spdk_env_init() time; the default 64KB soft limit makes spdk_tgt fail
#    to start with a message that does not mention memlock at all. Also
#    required for ibv_reg_mr() once KV_TRANSPORT=rdma (Phase 2).
# ─────────────────────────────────────────────────────────────────────────────
step "memlock limits"
LIMITS_FILE="/etc/security/limits.d/99-kvstack.conf"
cat > "${LIMITS_FILE}" <<'EOF'
# Managed by scripts/target/01-host-prep.sh — do not hand-edit, re-run the
# script.
#
# unlimited memlock: SPDK's embedded DPDK EAL pins its hugepage pool with
# mlock(); the default 64KB soft limit means spdk_env_init() fails to lock
# down its DMA-capable memory immediately at spdk_tgt startup, surfacing as
# an opaque EAL init failure with no mention of memlock anywhere in it. In
# Phase 2 (KV_TRANSPORT=rdma) the same unlimited memlock is ALSO required
# for ibv_reg_mr() to pin arbitrary amounts of memory for RDMA.
* soft memlock unlimited
* hard memlock unlimited
EOF
ok "wrote ${LIMITS_FILE} (takes effect on next login/session; a running" \
   " shell used to launch spdk_tgt must be a NEW session after this)"

# ─────────────────────────────────────────────────────────────────────────────
# 9. Directories
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${STACK_ROOT}" "${STACK_ROOT}/etc" "${LOG_DIR}" "${RUN_DIR}"
ok "directories present: ${STACK_ROOT} ${STACK_ROOT}/etc ${LOG_DIR} ${RUN_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
step "Summary"
log "hugepages: ${_hp_actual}/${HUGEPAGE_COUNT}"
log "storage-leg interfaces: prefill=${_if_prefill:-?} decode=${_if_decode:-?}"
log "KV_TRANSPORT=${KV_TRANSPORT}  NVMF_TRSVCID=${NVMF_TRSVCID}"
ok "target host prep complete"
log "next: scripts/target/02-build-spdk-kv.sh"
