#!/usr/bin/env bash
# 20-verify-nixl-plugin.sh — prove the storage-leg NIXL plugin (whichever
# KV_BACKEND selects) loads and can actually talk to SMC3, entirely WITHOUT
# vLLM or LMCache in the picture.
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
#   backend is taken from KV_BACKEND (config/cluster.env) — not a CLI flag,
#   same as everywhere else in this repo that branches on it.
#
# WHY this script exists as a layer BELOW LMCache: if this fails, the
# problem is unambiguously in NIXL/the plugin/SPDK-or-xNVMe/the fabric —
# there is no LMCache config, no vLLM connector wiring, no allowlist patch
# in the way to also suspect. That is deliberately narrower blast radius
# than scripts/common/25-validate-lmcache-config.sh's "live NIXL plugin
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

# ── Backend-specific connect param + expected max_value_size ────────────────
# See config/cluster.env's KV_BACKEND / KV_MAX_VALUE_SIZE_EFFECTIVE comments
# for why these two differ per backend, and scripts/common/lib.sh's
# setup_nixl_kv_env() for where NIXL_KV_TRID / NIXL_XNVME_DEV get exported.
case "${KV_BACKEND}" in
    SPDK_NVMe_KV)
        _CONNECT_PARAM_KEY="trid"
        _CONNECT_PARAM_VALUE="${NIXL_KV_TRID}"
        ;;
    XNVME_KV)
        _CONNECT_PARAM_KEY="dev_uri"
        _CONNECT_PARAM_VALUE="${NIXL_XNVME_DEV}"
        ;;
    *) die "KV_BACKEND must be SPDK_NVMe_KV|XNVME_KV, got '${KV_BACKEND}'" ;;
esac
_EXPECTED_MVS="${KV_MAX_VALUE_SIZE_EFFECTIVE}"

# ─────────────────────────────────────────────────────────────────────────────
# Plugin .so exists.
# ─────────────────────────────────────────────────────────────────────────────
step "Plugin binary present"
PLUGIN_SO="${NIXL_PLUGIN_DIR}/libplugin_${KV_BACKEND}.so"
check "libplugin_${KV_BACKEND}.so exists in NIXL_PLUGIN_DIR (${NIXL_PLUGIN_DIR})" \
    test -f "${PLUGIN_SO}" || true

# ─────────────────────────────────────────────────────────────────────────────
# ldd. What this checks differs by backend:
#
#   SPDK_NVMe_KV: HARD requirement of NO DT_NEEDED on librte_*.so /
#   libspdk_*.so at all — see plugins/nvme-kv/meson.build's own comment. If
#   the SPDK/DPDK static archives get linked as bare -lNAME instead of by
#   explicit .a path, ld can silently resolve against the .so sitting in
#   the same -L dir instead of statically embedding the archive — producing
#   a plugin .so with DT_NEEDED entries this repo deliberately never ships
#   in the final image. This asserts ABSENCE of those libraries.
#
#   XNVME_KV: the exact opposite shape of check applies, NOT the same one.
#   This plugin legitimately links libxnvme.so dynamically (see
#   plugins/xnvme-kv/meson.build) — a DT_NEEDED on libxnvme.so is CORRECT
#   and expected, so the SPDK "must not depend on X" rule does not apply
#   here at all. What DOES apply, identically to SPDK, is that NIXL's
#   dlopen() fails on any UNRESOLVED dependency, and NIXL reports that
#   failure ONLY as a generic "unsupported backend" with nothing pointing
#   at a missing shared library. So XNVME_KV's check instead asserts every
#   DT_NEEDED entry actually RESOLVES (no "not found" in ldd's output) —
#   same failure mode this whole check exists to catch, opposite assertion
#   because the two plugins' correct link shapes are opposite.
# ─────────────────────────────────────────────────────────────────────────────
step "ldd: plugin dependencies must resolve cleanly"
if [ -f "${PLUGIN_SO}" ]; then
    require_cmd ldd
    _ldd_out="$(ldd "${PLUGIN_SO}" 2>&1 || true)"
    printf '%s\n' "${_ldd_out}" | while IFS= read -r line; do log "  ${line}"; done
    if [ "${KV_BACKEND}" = "SPDK_NVMe_KV" ]; then
        check "ldd shows no librte_*.so dependency" \
            bash -c "! printf '%s' \"\${1}\" | grep -qE 'librte_[A-Za-z0-9_]+\.so'" _ "${_ldd_out}" || true
        check "ldd shows no libspdk_*.so dependency" \
            bash -c "! printf '%s' \"\${1}\" | grep -qE 'libspdk_[A-Za-z0-9_]+\.so'" _ "${_ldd_out}" || true
    fi
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
_PY_OUT="$("${VENV}/bin/python" - "${KV_BACKEND}" "${_CONNECT_PARAM_KEY}" \
    "${_CONNECT_PARAM_VALUE}" "${_EXPECTED_MVS}" <<'PYEOF'
import sys

backend_name = sys.argv[1]
connect_key = sys.argv[2]
connect_value = sys.argv[3]
expected_max_value_size = int(sys.argv[4])

try:
    from nixl._api import nixl_agent, nixl_agent_config
except Exception as exc:  # noqa: BLE001
    print(f"RESULT:IMPORT_FAIL:{type(exc).__name__}: {exc}")
    sys.exit(1)

agent = nixl_agent("kvstack-verify-20", nixl_agent_config(backends=[]))

plugins = agent.get_plugin_list()
print(f"INFO: available NIXL plugins: {plugins}")
if backend_name not in plugins:
    print("RESULT:PLUGIN_NOT_LISTED")
    sys.exit(1)

params = agent.get_plugin_params(backend_name)
print(f"INFO: get_plugin_params({backend_name}) = {params}")
# Echo whatever keys THIS plugin actually advertises, rather than a
# hardcoded (trid, max_value_size, kv_slot_offset) tuple that was only ever
# correct for SPDK_NVMe_KV — XNVME_KV advertises {dev_uri, max_value_size}
# instead (plugins/xnvme-kv/xnvme_kv_plugin.cpp's getParams()).
param_keys = list(params.keys()) if hasattr(params, "keys") else []
for k in param_keys:
    v = params.get(k) if hasattr(params, "get") else None
    print(f"INFO:   {k} = {v!r}")

reported_mvs = params.get("max_value_size") if hasattr(params, "get") else None
try:
    reported_mvs_int = int(reported_mvs)
except (TypeError, ValueError):
    reported_mvs_int = None

# Compare against the BACKEND-APPROPRIATE effective ceiling
# (config/cluster.env's KV_MAX_VALUE_SIZE_EFFECTIVE), not a single constant
# shared by both plugins — SPDK's transport-SGL ceiling (524288) and
# XNVME_KV's measured DSC firmware ceiling (32768) are unrelated numbers
# that happen to occupy the same getParams() slot; comparing XNVME_KV's
# reported value against the SPDK constant would be a guaranteed false
# failure, not a real check.
if reported_mvs_int != expected_max_value_size:
    print(f"RESULT:MAX_VALUE_SIZE_MISMATCH:reported={reported_mvs!r} "
          f"expected={expected_max_value_size}")
    sys.exit(1)

# create_backend() has NO return statement in nixl._api.nixl_agent — it
# ALWAYS implicitly returns None, on total success exactly as much as on
# failure (confirmed 2026-09-15 by reading its source on a live container:
# it just populates self.backends[backend]/self.backend_mems/
# self.backend_options and returns nothing). The "if backend is None: fail"
# check that used to be here was measured to ALWAYS trigger — even a
# successful connect to XNVME_KV on /dev/ng1n1 (backend genuinely opened,
# "Backend XNVME_KV was instantiated" logged, device format queried
# correctly) prints `backend: None` and would have failed this check on
# every single passing run. Success is proven by NOT raising in the try
# block below — that IS the API's only success signal — so the None-check
# is deleted rather than "fixed" into some other guess at what a truthy
# return might look like.
try:
    agent.create_backend(backend_name, {connect_key: connect_value})
except Exception as exc:  # noqa: BLE001
    print(f"RESULT:CREATE_BACKEND_FAIL:{type(exc).__name__}: {exc}")
    sys.exit(1)

print("RESULT:OK")
sys.exit(0)
PYEOF
)"
_py_rc=$?
set -e

printf '%s\n' "${_PY_OUT}" | grep -E '^INFO:' | sed 's/^INFO://' | while IFS= read -r line; do log " ${line}"; done
# The plugin writes "[${KV_BACKEND}] <connect-param> from env: ..." straight
# to stderr (see both plugins' ErrLog helper — spdk_nvme_kv_backend.h and
# xnvme_kv_backend.h use the identical "[NAME] file:line: " prefix pattern)
# — that line, if present in the captured output, confirms the connect
# param actually reached the plugin's construction path rather than the
# plugin silently falling back to a built-in default that happens to also
# "work" against nothing.
if printf '%s' "${_PY_OUT}" | grep -q "\\[${KV_BACKEND}\\]"; then
    printf '%s\n' "${_PY_OUT}" | grep "\\[${KV_BACKEND}\\]" | while IFS= read -r line; do
        log "  plugin stderr: ${line}"
    done
else
    warn "no '[${KV_BACKEND}]' log line captured — cannot independently" \
         " confirm the plugin actually read ${_CONNECT_PARAM_KEY}=${_CONNECT_PARAM_VALUE}" \
         " (it may log this to a fd this script didn't capture, or this" \
         " build logs less verbosely; not a hard failure on its own)."
fi

check "nixl python bindings import" \
    bash -c "! printf '%s' \"\${1}\" | grep -q 'RESULT:IMPORT_FAIL'" _ "${_PY_OUT}" || true
check "${KV_BACKEND} listed by get_plugin_list()" \
    bash -c "! printf '%s' \"\${1}\" | grep -q 'RESULT:PLUGIN_NOT_LISTED'" _ "${_PY_OUT}" || true
check "get_plugin_params reports max_value_size == KV_MAX_VALUE_SIZE_EFFECTIVE (${_EXPECTED_MVS})" \
    bash -c "! printf '%s' \"\${1}\" | grep -q 'RESULT:MAX_VALUE_SIZE_MISMATCH'" _ "${_PY_OUT}" || true
check "create_backend(\"${KV_BACKEND}\", {${_CONNECT_PARAM_KEY}: ${_CONNECT_PARAM_VALUE}}) succeeds (connects to SMC3)" \
    bash -c "printf '%s' \"\${1}\" | grep -q 'RESULT:OK'" _ "${_PY_OUT}" || true

if [ "${_py_rc}" -ne 0 ] && ! printf '%s' "${_PY_OUT}" | grep -q '^RESULT:OK$'; then
    _fail_line="$(printf '%s\n' "${_PY_OUT}" | grep '^RESULT:' | tail -1)"
    err "python check did not reach RESULT:OK — last RESULT line: ${_fail_line:-<none>}"
fi

checks_summary
