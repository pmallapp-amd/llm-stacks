#!/usr/bin/env bash
# 04-verify-target.sh — verify the SMC3 NVMe-KV target is up and correctly
# configured.
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/target/03-start-kv-target.sh has been run.
# Next step:     attach initiators from SMC1 (prefill) / SMC2 (decode); this
#                script prints the exact remote-side commands to run there.
#
# Hard checks (via lib.sh's `check`) determine this script's exit code —
# non-zero if any of them failed, per checks_summary. Soft checks
# (`check_soft`) are advisory: client-side tooling that may reasonably be
# absent on a storage-only node, or genuinely optional at this phase.
#
# `check` returns non-zero on failure, which under `set -euo pipefail` would
# abort the WHOLE script at the first failing check if called bare — every
# hard check below is therefore followed by `|| true` (matching
# scripts/common/00-preflight.sh's idiom) so all checks run and
# checks_summary reports the complete picture, not just the first failure.
#
# THE SINGLE MOST IMPORTANT CHECK IN THIS FILE: max_io_qpairs_per_ctrlr.
# SPDK silently accepts the WRONG key spelling (max_qpairs_per_ctrlr) and
# keeps its default of 127 in force with no error anywhere — the target
# comes up, the subsystem looks fine, and P/D fails invisibly later (one
# role's qpair gets refused, LMCache still logs "Stored N out of N tokens",
# HTTP returns 200, zero bytes reach the device). See config/cluster.env's
# NVMF_MAX_IO_QPAIRS_PER_CTRLR comment for the full failure mode (confirmed
# 2026-09-07, rocm-aic/target.sh). This is a HARD check for exactly that
# reason.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-kv-rpc.sh"

require_host "${TARGET_HOST}" "target"

step "Verifying KV target: ${TARGET_NAME} (${TARGET_HOST})"
banner_config

check "kv-target process running" is_running "kv-target" || true

_check_rpc_version() { rpc_json spdk_get_version >/dev/null 2>&1; }
check "nvmf_tgt RPC responds (spdk_get_version)" _check_rpc_version || true

check "subsystem ${NVMF_SUBNQN} present" kv_subsystem_exists || true
check "bdev ${KV_BDEV_NAME} present" kv_bdev_exists || true

_check_ns_count_one() {
    local json count
    json="$(rpc_json nvmf_get_subsystems 2>/dev/null)" || return 1
    count="$(NVMF_SUBNQN="${NVMF_SUBNQN}" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read() or "[]")
subnqn = os.environ["NVMF_SUBNQN"]
for s in data:
    if s.get("nqn") == subnqn:
        print(len(s.get("namespaces", []) or []))
        sys.exit(0)
print(-1)
' <<<"${json}" 2>/dev/null)" || return 1
    [ "${count}" = "1" ]
}
check "subsystem ${NVMF_SUBNQN} has exactly 1 namespace" _check_ns_count_one || true

step "SPDK version + transport sizing"
_spdk_ver="$(kv_target_spdk_version)"
log "SPDK version (${SPDK_TARGET_SRC}): ${_spdk_ver}"

_report_transport_sizes() {
    local json
    json="$(rpc_json nvmf_get_transports 2>/dev/null)" || return 1
    NVMF_TRTYPE="${NVMF_TRTYPE}" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read() or "[]")
trtype = os.environ["NVMF_TRTYPE"].upper()
for t in data:
    if t.get("trtype", "").upper() == trtype:
        print(f"max_io_size={t.get(\"max_io_size\")} "
              f"io_unit_size={t.get(\"io_unit_size\")} "
              f"max_io_qpairs_per_ctrlr={t.get(\"max_io_qpairs_per_ctrlr\")}")
        sys.exit(0)
sys.exit(1)
' <<<"${json}"
}
_transport_report="$(_report_transport_sizes 2>/dev/null || true)"
log "transport ${NVMF_TRTYPE} reports: ${_transport_report:-<not found>}"

_check_field_eq() {
    local field="$1" expect="$2" json
    json="$(rpc_json nvmf_get_transports 2>/dev/null)" || return 1
    NVMF_TRTYPE="${NVMF_TRTYPE}" FIELD="${field}" EXPECT="${expect}" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read() or "[]")
trtype = os.environ["NVMF_TRTYPE"].upper()
field = os.environ["FIELD"]
expect = int(os.environ["EXPECT"])
ok = any(t.get("trtype", "").upper() == trtype and t.get(field) == expect for t in data)
sys.exit(0 if ok else 1)
' <<<"${json}"
}

# THE P/D-BLOCKING CHECK. See file header + config/cluster.env's
# NVMF_MAX_IO_QPAIRS_PER_CTRLR comment. If this fails, SPDK almost
# certainly silently ignored a wrong key spelling and kept its default of
# 127 qpairs on a single controller — P/D against this target WILL fail,
# invisibly, the moment two roles both try to attach.
check "transport ${NVMF_TRTYPE} reports max_io_qpairs_per_ctrlr=${NVMF_MAX_IO_QPAIRS_PER_CTRLR}" \
    _check_field_eq max_io_qpairs_per_ctrlr "${NVMF_MAX_IO_QPAIRS_PER_CTRLR}" || true

check "transport ${NVMF_TRTYPE} reports max_io_size=${NVMF_MAX_IO_SIZE}" \
    _check_field_eq max_io_size "${NVMF_MAX_IO_SIZE}" || true

check_soft "transport ${NVMF_TRTYPE} reports io_unit_size=${NVMF_IO_UNIT_SIZE} (informational — large_bufsize is what actually governs the SGL ceiling, see config/cluster.env)" \
    _check_field_eq io_unit_size "${NVMF_IO_UNIT_SIZE}"

_check_port_listening() {
    ss -ltn 2>/dev/null | grep -q ":${NVMF_TRSVCID} "
}
check "TCP ${NVMF_TRSVCID} listening" _check_port_listening || true

if [ "${TARGET_HUGE_PAGES}" -gt 0 ]; then
    _check_hugepages_free() {
        local free
        free="$(awk '/^HugePages_Free/{print $2}' /proc/meminfo 2>/dev/null)"
        [ -n "${free}" ] && [ "${free}" -gt 0 ]
    }
    check "free hugepages > 0 (TARGET_HUGE_PAGES=${TARGET_HUGE_PAGES})" \
        _check_hugepages_free || true
else
    info "TARGET_HUGE_PAGES=0 (default) — nvmf_tgt runs --no-huge" \
         " (malloc-backed); hugepage checks do not apply"
fi

_check_nvme_discover() {
    command -v nvme >/dev/null 2>&1 || return 1
    nvme discover -t tcp -a "${NVMF_TRADDR}" -s "${NVMF_TRSVCID}" 2>/dev/null \
        | grep -q "${NVMF_SUBNQN}"
}
check_soft "local 'nvme discover' lists ${NVMF_SUBNQN}" _check_nvme_discover

# ─────────────────────────────────────────────────────────────────────────────
# Chunk-size ceiling: does ONE LMCache chunk for the CURRENT MODEL/TP_SIZE/
# LMCACHE_CHUNK_SIZE fit within NVMF_MAX_IO_SIZE? A chunk that does not fit
# fails the STORE with NIXL_ERR_BACKEND and takes the whole vLLM server
# down. See scripts/target/05-check-chunk-ceiling.sh for the full
# derivation and the two measured points it is validated against.
# ─────────────────────────────────────────────────────────────────────────────
check "chunk-size ceiling: MODEL=${MODEL} TP_SIZE=${TP_SIZE} LMCACHE_CHUNK_SIZE=${LMCACHE_CHUNK_SIZE} fits within NVMF_MAX_IO_SIZE=${NVMF_MAX_IO_SIZE}" \
    "${REPO_ROOT}/scripts/target/05-check-chunk-ceiling.sh" || true

step "Remote-side verification (run from SMC1 prefill / SMC2 decode)"
log "  nvme discover -t tcp -a ${NVMF_TRADDR} -s ${NVMF_TRSVCID}"
log "    # expect subnqn: ${NVMF_SUBNQN} in the output"
log "  # plugin-level check (after scripts/common/10-build-stack.sh there):"
log "  \${VENV}/bin/python3 -c \"from nixl._api import nixl_agent, nixl_agent_config; a=nixl_agent('verify', nixl_agent_config(backends=['SPDK_NVMe_KV'])); print(a.get_plugin_params('SPDK_NVMe_KV'))\""
log "    # expect trid to match: ${KV_TRID}"

checks_summary
