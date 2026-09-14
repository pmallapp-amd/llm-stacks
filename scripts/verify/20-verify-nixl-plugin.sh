#!/usr/bin/env bash
# 20-verify-nixl-plugin.sh — prove the SPDK_NVMe_KV NIXL plugin loads and can
# actually talk to SMC3, entirely WITHOUT vLLM or LMCache in the picture.
#
# Node:          SMC1 (prefill) or SMC2 (decode) — any compute node with
#                ${VENV} built and NIXL_PLUGIN_DIR populated.
# Prerequisites: scripts/common/10-build-stack.sh (NIXL + the plugin built
#                and installed into ${NIXL_PLUGIN_DIR});
#                scripts/common/20-build-vllm-lmcache.sh (nixl python
#                bindings importable in ${VENV}); the NVMe-oF target on
#                SMC3 already listening (scripts/verify/10-verify-network.sh
#                clean on the storage leg is a good pre-check).
# Next step:     scripts/verify/30-verify-kv-roundtrip.sh — this script only
#                proves the backend CONSTRUCTS; that script proves it
#                actually stores and retrieves bytes correctly.
#
# usage: 20-verify-nixl-plugin.sh [prefill|decode]
#   role defaults to whichever of PREFILL_HOST/DECODE_HOST this host is;
#   pass explicitly when running with KV_SKIP_HOST_CHECK=1 from elsewhere.
#
# WHY this script exists as a layer BELOW LMCache: if this fails, the
# problem is unambiguously in NIXL/the plugin/SPDK/the fabric — there is no
# LMCache config, no vLLM connector wiring, no allowlist patch in the way to
# also suspect. That is deliberately narrower blast radius than
# scripts/common/25-validate-lmcache-config.sh's "live NIXL plugin
# introspection" section, which does something similar but only as one part
# of a larger check; this script is the thing to run FIRST when something
# upstream is broken and you don't yet know which layer.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

ROLE="${1:-}"
if [ -z "${ROLE}" ]; then
    _local_ips="$(hostname -I 2>/dev/null || true)"
    case " ${_local_ips} " in
        *" ${PREFILL_HOST} "*) ROLE="prefill" ;;
        *" ${DECODE_HOST} "*)  ROLE="decode" ;;
        *) die "could not infer role from local IPs (${_local_ips:-<none>})" \
               " — pass it explicitly: $0 <prefill|decode>" ;;
    esac
fi
case "${ROLE}" in
    prefill|decode) ;;
    *) die "role must be prefill|decode, got '${ROLE}'" ;;
esac

step "NIXL plugin verification: role=${ROLE} on $(hostname)"
banner_config

require_file "${STACK_ROOT}/etc/env.sh"
# shellcheck source=/dev/null
source "${STACK_ROOT}/etc/env.sh"

setup_nixl_kv_env "${ROLE}"

# ─────────────────────────────────────────────────────────────────────────────
# Plugin .so exists.
# ─────────────────────────────────────────────────────────────────────────────
step "Plugin binary present"
PLUGIN_SO="${NIXL_PLUGIN_DIR}/libplugin_SPDK_NVMe_KV.so"
check "libplugin_SPDK_NVMe_KV.so exists in NIXL_PLUGIN_DIR (${NIXL_PLUGIN_DIR})" \
    test -f "${PLUGIN_SO}" || true

# ─────────────────────────────────────────────────────────────────────────────
# ldd: no DT_NEEDED on librte_*.so / libspdk_*.so, and nothing unresolved.
#
# WHY this is a HARD check and not advisory: per
# plugins/nvme-kv/meson.build's own comment, if the SPDK/DPDK static
# archives get linked as bare -lNAME instead of by explicit .a path, ld can
# silently resolve against the .so sitting in the same -L dir instead of
# statically embedding the archive — producing a plugin .so with DT_NEEDED
# entries on librte_eal.so.26 etc. that this repo deliberately never ships
# in the final image. NIXL's dlopen() of such a plugin then fails at
# runtime (the shared lib isn't on any loader path in the deployed image)
# and NIXL reports this ONLY as a generic "unsupported backend" — there is
# NOTHING in that error message that points at a missing shared library.
# Catching it here, where `ldd` says exactly which .so is missing, is the
# difference between a five-second diagnosis and a multi-hour one.
# ─────────────────────────────────────────────────────────────────────────────
step "ldd: plugin must be self-contained (no runtime librte_*/libspdk_* deps)"
if [ -f "${PLUGIN_SO}" ]; then
    require_cmd ldd
    _ldd_out="$(ldd "${PLUGIN_SO}" 2>&1 || true)"
    printf '%s\n' "${_ldd_out}" | while IFS= read -r line; do log "  ${line}"; done
    check "ldd shows no librte_*.so dependency" \
        bash -c "! printf '%s' \"\${1}\" | grep -qE 'librte_[A-Za-z0-9_]+\.so'" _ "${_ldd_out}" || true
    check "ldd shows no libspdk_*.so dependency" \
        bash -c "! printf '%s' \"\${1}\" | grep -qE 'libspdk_[A-Za-z0-9_]+\.so'" _ "${_ldd_out}" || true
    check "ldd shows no unresolved (\"not found\") dependency" \
        bash -c "! printf '%s' \"\${1}\" | grep -q 'not found'" _ "${_ldd_out}" || true
else
    warn "skipping ldd checks — plugin binary missing (see previous check)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Python: create a nixl_agent, list plugins, fetch this plugin's params,
# and instantiate the backend for real — the moment it actually opens an
# NVMe-oF/TCP (or RDMA) connection to SMC3.
#
# NOTE ON THE NIXL PYTHON API SURFACE USED BELOW: nixl_agent / nixl_agent_config
# / get_plugin_list / get_plugin_params are already exercised successfully by
# scripts/common/25-validate-lmcache-config.sh's "live NIXL plugin
# introspection" section — VERIFIED against a real install by a prior agent.
# create_backend(name, params) is named consistently across this repo's
# comments (scripts/common/gen-lmcache-config.sh, plugins/nvme-kv/*.cpp) as
# what NIXL/LMCache calls to dlopen+construct a backend. Both are used here
# exactly as elsewhere in this repo. If a given NIXL build's python binding
# names differ, this heredoc fails with a specific AttributeError naming the
# missing call — loudly and precisely, not silently mis-verifying success.
# ─────────────────────────────────────────────────────────────────────────────
step "Python: nixl_agent plugin discovery + backend construction"
require_file "${VENV}/bin/python"

set +e
_PY_OUT="$("${VENV}/bin/python" - "${NIXL_KV_TRID}" "${KV_MAX_VALUE_SIZE}" <<'PYEOF'
import sys

trid = sys.argv[1]
expected_max_value_size = int(sys.argv[2])

try:
    from nixl._api import nixl_agent, nixl_agent_config
except Exception as exc:  # noqa: BLE001
    print(f"RESULT:IMPORT_FAIL:{type(exc).__name__}: {exc}")
    sys.exit(1)

agent = nixl_agent("kvstack-verify-20", nixl_agent_config(backends=[]))

plugins = agent.get_plugin_list()
print(f"INFO: available NIXL plugins: {plugins}")
if "SPDK_NVMe_KV" not in plugins:
    print("RESULT:PLUGIN_NOT_LISTED")
    sys.exit(1)

params = agent.get_plugin_params("SPDK_NVMe_KV")
print(f"INFO: get_plugin_params(SPDK_NVMe_KV) = {params}")
for k in ("trid", "max_value_size", "kv_slot_offset"):
    v = params.get(k) if hasattr(params, "get") else None
    print(f"INFO:   {k} = {v!r}")

reported_mvs = params.get("max_value_size") if hasattr(params, "get") else None
try:
    reported_mvs_int = int(reported_mvs)
except (TypeError, ValueError):
    reported_mvs_int = None

if reported_mvs_int != expected_max_value_size:
    print(f"RESULT:MAX_VALUE_SIZE_MISMATCH:reported={reported_mvs!r} "
          f"expected={expected_max_value_size}")
    sys.exit(1)

try:
    backend = agent.create_backend("SPDK_NVMe_KV", {"trid": trid})
except Exception as exc:  # noqa: BLE001
    print(f"RESULT:CREATE_BACKEND_FAIL:{type(exc).__name__}: {exc}")
    sys.exit(1)

if backend is None:
    print("RESULT:CREATE_BACKEND_RETURNED_NONE")
    sys.exit(1)

print("RESULT:OK")
sys.exit(0)
PYEOF
)"
_py_rc=$?
set -e

printf '%s\n' "${_PY_OUT}" | grep -E '^INFO:' | sed 's/^INFO://' | while IFS= read -r line; do log " ${line}"; done
# The plugin writes "[SPDK_NVMe_KV] TRID from env: ..." straight to stderr
# (see spdk_nvme_kv_backend.h's ErrLog helper) — that line, if present in
# the captured output, confirms NIXL_KV_TRID actually reached the plugin's
# construction path rather than the plugin silently falling back to a
# built-in default trid that happens to also "work" against nothing.
if printf '%s' "${_PY_OUT}" | grep -q '\[SPDK_NVMe_KV\]'; then
    printf '%s\n' "${_PY_OUT}" | grep '\[SPDK_NVMe_KV\]' | while IFS= read -r line; do
        log "  plugin stderr: ${line}"
    done
else
    warn "no '[SPDK_NVMe_KV]' log line captured — cannot independently" \
         " confirm the plugin actually read NIXL_KV_TRID=${NIXL_KV_TRID}" \
         " (it may log this to a fd this script didn't capture, or this" \
         " build logs less verbosely; not a hard failure on its own)."
fi

check "nixl python bindings import" \
    bash -c "! printf '%s' \"\${1}\" | grep -q 'RESULT:IMPORT_FAIL'" _ "${_PY_OUT}" || true
check "SPDK_NVMe_KV listed by get_plugin_list()" \
    bash -c "! printf '%s' \"\${1}\" | grep -q 'RESULT:PLUGIN_NOT_LISTED'" _ "${_PY_OUT}" || true
check "get_plugin_params reports max_value_size == KV_MAX_VALUE_SIZE (${KV_MAX_VALUE_SIZE})" \
    bash -c "! printf '%s' \"\${1}\" | grep -q 'RESULT:MAX_VALUE_SIZE_MISMATCH'" _ "${_PY_OUT}" || true
check "create_backend(\"SPDK_NVMe_KV\", {trid: ${NIXL_KV_TRID}}) succeeds (connects to SMC3)" \
    bash -c "printf '%s' \"\${1}\" | grep -q 'RESULT:OK'" _ "${_PY_OUT}" || true

if [ "${_py_rc}" -ne 0 ] && ! printf '%s' "${_PY_OUT}" | grep -q '^RESULT:OK$'; then
    _fail_line="$(printf '%s\n' "${_PY_OUT}" | grep '^RESULT:' | tail -1)"
    err "python check did not reach RESULT:OK — last RESULT line: ${_fail_line:-<none>}"
fi

checks_summary
