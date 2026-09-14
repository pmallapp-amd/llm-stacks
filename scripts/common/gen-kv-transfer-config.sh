#!/usr/bin/env bash
# gen-kv-transfer-config.sh — emit the --kv-transfer-config JSON value for
# one vLLM role.
#
# Node:          SMC1 (prefill) or SMC2 (decode) — generates JSON on
#                stdout, does not itself start anything.
# Prerequisites: none beyond config/cluster.env's PD_* values.
# Next step:     scripts/common/start-vllm.sh passes this straight to
#                vLLM's --kv-transfer-config.
#
# usage: gen-kv-transfer-config.sh <prefill|decode>
#
# ═══════════════════════════════════════════════════════════════════════════
# F1 — the composition (verified against the live vLLM class, not guessed)
# ═══════════════════════════════════════════════════════════════════════════
# vLLM runs MultiConnector[NixlConnector, LMCacheMPConnector]. NixlConnector
# moves KV GPU->GPU over NIXL/UCX RDMA and carries the P/D role; LMCache
# stays kv_both on BOTH sides as a reuse tier, not the P/D transport.
#
#   {"kv_connector":"MultiConnector","kv_role":"kv_both","kv_connector_extra_config":{"connectors":[
#     {"kv_connector":"NixlConnector","kv_role":"kv_producer"|"kv_consumer"},
#     {"kv_connector":"LMCacheMPConnector","kv_role":"kv_both","kv_connector_extra_config":{"lmcache.mp.host":"...","lmcache.mp.port":6556}}
#   ]}}
#
# Prefill uses kv_producer on the NixlConnector entry; decode uses
# kv_consumer. The outer kv_role is kv_both on both sides. The LMCache
# entry is kv_both on both sides.
#
# MultiConnector schema confirmed by reading the live class:
# multi_connector.py:213 _get_connector_classes_and_configs reads
# kv_connector_extra_config["connectors"] as a LIST and splats each entry
# into KVTransferConfig(**ktc), so each element takes the ordinary
# top-level connector keys.
#
# ORDER MATTERS. MultiConnector asks children to load in list order and
# the FIRST that answers wins. Default order [NixlConnector,
# LMCacheMPConnector] gives the P/D transport first refusal — correct for
# measuring the P/D hop. The reverse order (PD_LMCACHE_FIRST=1) is the
# ONLY posture in which the L2 reuse tier can win a load.
#
# Both children implement SupportsHMA (nixl/connector.py:79,
# lmcache_mp_connector.py:575), so the hybrid KV cache manager does NOT
# need disabling — verified, because MultiConnector.__init__'s assertion
# would otherwise abort startup.
#
# ═══════════════════════════════════════════════════════════════════════════
# PD_ENABLED=0 — the revert switch
# ═══════════════════════════════════════════════════════════════════════════
# Emits the LMCache-only form this repo used BEFORE this task: a single
# LMCacheConnectorV1 kv_producer/kv_consumer config, no NixlConnector, no
# MultiConnector wrapper. Byte-for-byte what scripts/common/start-vllm.sh
# used to hardcode inline — this is what makes the two-leg change
# revertible without touching any other file.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLE="${1:-}"
case "${ROLE}" in
    prefill) _NIXL_KV_ROLE="kv_producer" ;;
    decode)  _NIXL_KV_ROLE="kv_consumer" ;;
    *) die "usage: $0 <prefill|decode>" ;;
esac

require_cmd python3

CONFIG_JSON="$(PD_ENABLED="${PD_ENABLED}" PD_CONNECTOR="${PD_CONNECTOR}" \
    PD_LMCACHE_FIRST="${PD_LMCACHE_FIRST}" NIXL_KV_ROLE="${_NIXL_KV_ROLE}" \
    LMCACHE_MP_HOST="${LMCACHE_MP_HOST}" LMCACHE_MP_PORT="${LMCACHE_MP_PORT}" \
    python3 - <<'PYEOF'
import json
import os

pd_enabled = os.environ["PD_ENABLED"] == "1"
nixl_kv_role = os.environ["NIXL_KV_ROLE"]

if not pd_enabled:
    # See "PD_ENABLED=0 — the revert switch" in this script's header.
    config = {
        "kv_connector": "LMCacheConnectorV1",
        "kv_role": nixl_kv_role,
        "kv_connector_extra_config": {},
    }
    print(json.dumps(config))
    raise SystemExit(0)

pd_connector = os.environ["PD_CONNECTOR"]
lmcache_first = os.environ["PD_LMCACHE_FIRST"] == "1"

nixl_entry = {"kv_connector": "NixlConnector", "kv_role": nixl_kv_role}
lmcache_entry = {
    "kv_connector": "LMCacheMPConnector",
    "kv_role": "kv_both",
    "kv_connector_extra_config": {
        "lmcache.mp.host": os.environ["LMCACHE_MP_HOST"],
        "lmcache.mp.port": int(os.environ["LMCACHE_MP_PORT"]),
    },
}

# ORDER MATTERS — see "F1 — the composition" above. Default order puts
# NixlConnector first so it gets first refusal on every load.
connectors = [lmcache_entry, nixl_entry] if lmcache_first else [nixl_entry, lmcache_entry]

config = {
    "kv_connector": pd_connector,
    "kv_role": "kv_both",
    "kv_connector_extra_config": {"connectors": connectors},
}
print(json.dumps(config))
PYEOF
)"

# Validate before printing — a malformed config here would fail deep inside
# vLLM's argument parser with a much less specific error than this gives.
printf '%s\n' "${CONFIG_JSON}" | python3 -m json.tool >/dev/null \
    || die "generated --kv-transfer-config is not valid JSON: ${CONFIG_JSON}"

printf '%s\n' "${CONFIG_JSON}"
