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

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-kv-rpc.sh"

require_host "${TARGET_HOST}" "target"

step "Verifying KV target: ${TARGET_NAME} (${TARGET_HOST})"
banner_config

check "kv-target process running" is_running "kv-target" || true

_check_rpc_version() { rpc_json spdk_get_version >/dev/null 2>&1; }
check "spdk_tgt RPC responds (spdk_get_version)" _check_rpc_version || true

check "subsystem ${NVMF_SUBNQN} present" kv_subsystem_exists || true

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

step "SPDK version + effective transport sizing"
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
        print(f"max_io_size={t.get(\"max_io_size\")} io_unit_size={t.get(\"io_unit_size\")}")
        sys.exit(0)
sys.exit(1)
' <<<"${json}"
}
_transport_report="$(_report_transport_sizes 2>/dev/null || true)"
log "transport ${NVMF_TRTYPE} reports: ${_transport_report:-<not found>}"

# max_io_size must always match what we asked for — that part of the
# transport RPC did not change in v26.05.
_check_max_io_size() {
    local json
    json="$(rpc_json nvmf_get_transports 2>/dev/null)" || return 1
    NVMF_TRTYPE="${NVMF_TRTYPE}" NVMF_MAX_IO_SIZE="${NVMF_MAX_IO_SIZE}" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read() or "[]")
trtype = os.environ["NVMF_TRTYPE"].upper()
max_io = int(os.environ["NVMF_MAX_IO_SIZE"])
ok = any(t.get("trtype", "").upper() == trtype and t.get("max_io_size") == max_io for t in data)
sys.exit(0 if ok else 1)
' <<<"${json}"
}
check "transport ${NVMF_TRTYPE} reports max_io_size=${NVMF_MAX_IO_SIZE}" \
    _check_max_io_size || true

# io_unit_size equality is only a HARD check pre-26.05, where it is the
# thing nvmf_tcp_create() actually enforces the SGL ratio against (F3 in
# config/cluster.env). On >=26.05 io_unit_size is a deprecated no-op — SPDK
# may report it back as 0, as an unchanged passthrough of what was
# requested, or something else entirely; none of those are a "broken
# target" on that version, so this is check_soft (report + explain, never
# fail the run) once the tree is known to be >=26.05.
_check_io_unit_size() {
    local json
    json="$(rpc_json nvmf_get_transports 2>/dev/null)" || return 1
    NVMF_TRTYPE="${NVMF_TRTYPE}" NVMF_IO_UNIT_SIZE="${NVMF_IO_UNIT_SIZE}" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read() or "[]")
trtype = os.environ["NVMF_TRTYPE"].upper()
io_unit = int(os.environ["NVMF_IO_UNIT_SIZE"])
ok = any(t.get("trtype", "").upper() == trtype and t.get("io_unit_size") == io_unit for t in data)
sys.exit(0 if ok else 1)
' <<<"${json}"
}
if kv_target_spdk_is_pre_2605; then
    check "transport ${NVMF_TRTYPE} reports io_unit_size=${NVMF_IO_UNIT_SIZE}" \
        _check_io_unit_size || true
else
    info "SPDK ${_spdk_ver} (>=26.05): io_unit_size is a deprecated no-op" \
         " (F3) — NOT hard-checking it against ${NVMF_IO_UNIT_SIZE}; the" \
         " value reported above is informational only."
    check_soft "transport ${NVMF_TRTYPE} reports io_unit_size=${NVMF_IO_UNIT_SIZE} (advisory, >=26.05)" \
        _check_io_unit_size
fi

_check_port_listening() {
    ss -ltn 2>/dev/null | grep -q ":${NVMF_TRSVCID} "
}
check "TCP ${NVMF_TRSVCID} listening" _check_port_listening || true

_check_hugepages_free() {
    local free
    free="$(awk '/^HugePages_Free/{print $2}' /proc/meminfo 2>/dev/null)"
    [ -n "${free}" ] && [ "${free}" -gt 0 ]
}
check "free hugepages > 0" _check_hugepages_free || true

_check_nvme_discover() {
    command -v nvme >/dev/null 2>&1 || return 1
    nvme discover -t tcp -a "${NVMF_TRADDR}" -s "${NVMF_TRSVCID}" 2>/dev/null \
        | grep -q "${NVMF_SUBNQN}"
}
check_soft "local 'nvme discover' lists ${NVMF_SUBNQN}" _check_nvme_discover

# check_soft: the fork's exact field names for advertising the KV command
# set on a bdev/namespace are UNVERIFIED from this repo (kv_spdk is not
# vendored here — same caution as lib-kv-rpc.sh's create_kv_bdev comment).
# This probes a couple of plausible spellings across both bdev_get_bdevs
# and nvmf_get_subsystems rather than asserting one is correct; a miss here
# means "could not confirm", not "target is broken".
_check_kv_command_set_advertised() {
    local bdevs subs
    bdevs="$(rpc_json bdev_get_bdevs -b "${KV_BDEV_NAME}" 2>/dev/null)" || return 1
    subs="$(rpc_json nvmf_get_subsystems 2>/dev/null)" || return 1
    printf '%s\n%s\n' "${bdevs}" "${subs}" \
        | grep -Eiq '"(csi|command_set|cmd_set)"[[:space:]]*:[[:space:]]*"?(kv|nvme[_-]?kv)"?'
}
check_soft "namespace ${KV_BDEV_NAME} advertises KV command set (RPC field names unverified)" \
    _check_kv_command_set_advertised

step "Remote-side verification (run from SMC1 prefill / SMC2 decode)"
log "  nvme discover -t tcp -a ${NVMF_TRADDR} -s ${NVMF_TRSVCID}"
log "    # expect subnqn: ${NVMF_SUBNQN} in the output"
log "  # plugin-level check (after scripts/common/10-build-stack.sh there):"
log "  \${VENV}/bin/python3 -c \"from nixl._api import nixl_agent, nixl_agent_config; a=nixl_agent('verify', nixl_agent_config(backends=['SPDK_NVMe_KV'])); print(a.get_plugin_params('SPDK_NVMe_KV'))\""
log "    # expect trid to match: ${KV_TRID}"

checks_summary
