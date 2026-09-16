#!/usr/bin/env bash
# gen-kv-transfer-config.sh — emit the --kv-transfer-config JSON value for
# one vLLM role.
#
# Node:          SMC1 (prefill) or SMC2 (decode) — generates JSON on
#                stdout, does not itself start anything.
# Prerequisites: none beyond config/cluster.env's LMCACHE_MP_HOST/_PORT.
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
#     {"kv_connector":"LMCacheMPConnector","kv_role":"kv_both","kv_connector_extra_config":{"lmcache.mp.host":"...","lmcache.mp.port":6557}}
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
# Both children implement SupportsHMA (nixl/connector.py:79,
# lmcache_mp_connector.py:575), so the hybrid KV cache manager does NOT
# need disabling — verified, because MultiConnector.__init__'s assertion
# would otherwise abort startup.
#
# ═══════════════════════════════════════════════════════════════════════════
# THE ORDER IS FIXED — NixlConnector MUST be child[0], not configurable
# ═══════════════════════════════════════════════════════════════════════════
# This repo used to expose PD_ENABLED/PD_CONNECTOR/PD_LMCACHE_FIRST as
# variables selecting among alternative architectures (LMCache-only vs
# MultiConnector, and which child goes first). There is now exactly ONE
# supported architecture, so those variables are GONE (see
# config/cluster.env's "Compute leg (P->D)" section) and this generator
# always emits the same shape below. The order specifically can never be
# made configurable again, because it is not a style choice:
#
# MultiConnector.get_num_new_matched_tokens() (multi_connector.py:387-400)
# walks its child connectors in list order and assigns the ENTIRE load to
# the FIRST child that reports a non-zero match — it does not merge or
# prefer a "better" match across children, it just takes the first
# nonzero one and stops. If LMCacheMPConnector were listed before
# NixlConnector, then on the decode side any request whose prefix is
# already in the local L2 (XNVME_KV) tier would have its match satisfied
# by LMCache FIRST, and NixlConnector would never even be asked — the
# direct P->D remote-prefill pull this whole two-leg architecture exists
# to measure would be silently skipped every time the L2 tier has
# anything at all cached, which is most of the time. NixlConnector MUST
# be child[0] for the direct P->D leg to ever fire on decode. This was
# HANDOFF §12.1's one surviving finding, reaffirmed again in §16.9 — do
# not reintroduce a switch to flip this.
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

CONFIG_JSON="$(NIXL_KV_ROLE="${_NIXL_KV_ROLE}" \
    LMCACHE_MP_HOST="${LMCACHE_MP_HOST}" LMCACHE_MP_PORT="${LMCACHE_MP_PORT}" \
    python3 - <<'PYEOF'
import json
import os

nixl_kv_role = os.environ["NIXL_KV_ROLE"]

# ORDER IS FIXED — see "THE ORDER IS FIXED" above. NixlConnector MUST be
# child[0] so it gets first refusal on every load; there is no longer a
# variable that can flip this.
nixl_entry = {"kv_connector": "NixlConnector", "kv_role": nixl_kv_role}
lmcache_entry = {
    "kv_connector": "LMCacheMPConnector",
    "kv_role": "kv_both",
    "kv_connector_extra_config": {
        "lmcache.mp.host": os.environ["LMCACHE_MP_HOST"],
        "lmcache.mp.port": int(os.environ["LMCACHE_MP_PORT"]),
    },
}

config = {
    "kv_connector": "MultiConnector",
    "kv_role": "kv_both",
    "kv_connector_extra_config": {"connectors": [nixl_entry, lmcache_entry]},
}
print(json.dumps(config))
PYEOF
)"

# Validate before printing — a malformed config here would fail deep inside
# vLLM's argument parser with a much less specific error than this gives.
printf '%s\n' "${CONFIG_JSON}" | python3 -m json.tool >/dev/null \
    || die "generated --kv-transfer-config is not valid JSON: ${CONFIG_JSON}"

printf '%s\n' "${CONFIG_JSON}"
