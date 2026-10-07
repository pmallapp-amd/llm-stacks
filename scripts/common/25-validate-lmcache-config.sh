#!/usr/bin/env bash
# 25-validate-lmcache-config.sh — prove an MP daemon --l2-adapter spec is
# actually accepted by the INSTALLED LMCache, not merely well-formed JSON.
#
# Node:          SMC1 (prefill), SMC2 (decode).
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh (need ${VENV} with
#                lmcache + nixl importable).
# Next step:     scripts/common/start-lmcache-daemon.sh calls this
#                automatically before launching the daemon; run standalone
#                any time to re-check a spec after an LMCache upgrade.
#
# usage: 25-validate-lmcache-config.sh --l2-adapter-json <JSON>
#
# Validates the MP daemon's --l2-adapter spec (see
# scripts/common/start-lmcache-daemon.sh) — the live, and only, LMCache
# storage-tier config surface this repo runs (MultiConnector[NixlConnector,
# LMCacheMPConnector], MP mode; see docs/TODO.md §6.23). It parses the JSON
# with the SAME installed lmcache.v1.distributed.l2_adapters.config classes
# the daemon itself uses (get_l2_adapter_config_class()/
# <ConfigClass>.from_dict()), so a typo'd key or an unregistered adapter
# "type" fails here instead of 30 seconds into a daemon start.
#
# WHY this script exists at all: LMCache ignores unknown top-level keys in
# some versions, and ALWAYS ignores unknown extra_config sub-keys (that dict
# is opaque to the dataclass — nothing type-checks its contents until the
# NIXL storage backend reads specific keys out of it at construction time).
# An adapter spec can therefore parse cleanly, start a daemon that answers
# its ZMQ health check, and serve every request — while never once touching
# the remote KV target, because a single mistyped key was silently dropped.
# That failure mode is indistinguishable from "working" at every layer
# except an actual P/D cache-hit test, which by definition you only find out
# you need after suspecting something is wrong. This script is the
# pre-flight check that removes the need to suspect.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${1:-}" = "--l2-adapter-json" ]; then
    L2_JSON="${2:-}"
    [ -n "${L2_JSON}" ] || die "usage: $0 --l2-adapter-json <JSON>"

    if [ ! -x "${VENV}/bin/python" ]; then
        die "no venv at ${VENV} — run scripts/common/20-build-vllm-lmcache.sh first"
    fi

    step "Validating --l2-adapter JSON against installed LMCache"

    "${VENV}/bin/python" - "${L2_JSON}" <<'PYEOF'
import sys

spec_json = sys.argv[1]

import json

try:
    spec = json.loads(spec_json)
except json.JSONDecodeError as exc:
    print(f"FAIL: --l2-adapter-json is not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(spec, dict):
    print(f"FAIL: --l2-adapter-json must be a JSON object, got "
          f"{type(spec).__name__}", file=sys.stderr)
    sys.exit(1)

type_name = spec.get("type")
if not type_name:
    print("FAIL: --l2-adapter-json is missing the required 'type' field",
          file=sys.stderr)
    sys.exit(1)

try:
    from lmcache.v1.distributed.l2_adapters.config import (
        get_l2_adapter_config_class,
        get_type_name_for_config,
    )
except ImportError as exc:
    print(f"FAIL: could not import lmcache.v1.distributed.l2_adapters.config "
          f"— is this an MP-capable lmcache build? ({exc})", file=sys.stderr)
    sys.exit(1)

try:
    config_cls = get_l2_adapter_config_class(type_name)
except (ValueError, ImportError) as exc:
    print(f"FAIL: adapter type {type_name!r} is not registered in this "
          f"installed lmcache: {exc}", file=sys.stderr)
    sys.exit(1)

print(f"  adapter type {type_name!r} -> {config_cls.__name__}", file=sys.stderr)

try:
    adapter_cfg = config_cls.from_dict(spec)
except (TypeError, ValueError) as exc:
    print(f"FAIL: {config_cls.__name__}.from_dict() rejected this spec: {exc}",
          file=sys.stderr)
    print(f"\n{config_cls.help()}\n", file=sys.stderr)
    sys.exit(1)

resolved_type = get_type_name_for_config(adapter_cfg)
assert resolved_type == type_name, (resolved_type, type_name)

print(
    "  PASS: parses as a valid "
    f"{type_name!r} adapter — backend={getattr(adapter_cfg, 'backend', None)!r} "
    f"pool_size={getattr(adapter_cfg, 'pool_size', None)!r} "
    f"backend_params={getattr(adapter_cfg, 'backend_params', None)!r}",
    file=sys.stderr,
)

# nixl_kv-specific check: 'namespace' is this adapter's whole isolation
# and geometry-mismatch defense (docs/design/nixl-kv-l2-adapter.md §5,
# §7 assert 3) -- NixlKvL2AdapterConfig.from_dict() already enforces
# this (so a bad namespace would have failed above), but check it again
# explicitly and visibly here: a future refactor of that adapter's
# from_dict() must not be able to silently loosen this invariant without
# this script noticing.
if type_name == "nixl_kv":
    namespace = getattr(adapter_cfg, "namespace", None)
    if not isinstance(namespace, str) or not namespace:
        print(
            "FAIL: nixl_kv config has no non-empty 'namespace' "
            "(docs/design/nixl-kv-l2-adapter.md §7 assert 3)",
            file=sys.stderr,
        )
        sys.exit(1)
    _ns_forbidden = set("@~!") & set(namespace)
    if _ns_forbidden:
        print(
            f"FAIL: nixl_kv 'namespace' {namespace!r} contains forbidden "
            f"character(s) {sorted(_ns_forbidden)!r} -- must not contain "
            "'@', '~', or '!' (docs/design/nixl-kv-l2-adapter.md §7 "
            "assert 3)",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"  nixl_kv namespace={namespace!r} (ok)", file=sys.stderr)

# Best-effort cross-check against a live NIXL agent: confirm the backend
# name is actually dlopen()-able on THIS host and echo its declared
# max_value_size (relevant to mem_split_n — see start-lmcache-daemon.sh's
# header) so a human can eyeball it. Not fatal if nixl/the plugin dir isn't
# set up in whatever environment is running this check (e.g. a laptop with
# no NIXL_PLUGIN_DIR) — this is a bonus check, not the primary one above.
if type_name in ("nixl_store", "nixl_store_dynamic", "nixl_kv"):
    backend_name = getattr(adapter_cfg, "backend", None)
    try:
        from nixl._api import nixl_agent, nixl_agent_config

        agent = nixl_agent(
            "lmcache-l2-adapter-validator", nixl_agent_config(backends=[])
        )
        plugins = agent.get_plugin_list()
        if backend_name not in plugins:
            print(
                f"FAIL: NIXL backend {backend_name!r} is not in this host's "
                f"plugin list ({plugins}) — check NIXL_PLUGIN_DIR points at "
                "the directory 10-build-stack.sh installed into.",
                file=sys.stderr,
            )
            sys.exit(1)
        params = agent.get_plugin_params(backend_name)
        print(f"  live NIXL plugin params for {backend_name!r}: {params}",
              file=sys.stderr)
    except Exception as exc:  # noqa: BLE001 - best-effort diagnostic only
        print(f"WARN: could not cross-check against a live NIXL agent: {exc}",
              file=sys.stderr)

print("PASS: --l2-adapter-json validated against installed LMCache.",
      file=sys.stderr)
PYEOF

    ok "--l2-adapter JSON validated against installed LMCache"
    exit 0
fi

die "usage: $0 --l2-adapter-json <JSON>" \
    " — the YAML-validation mode (a bare <path-to-lmcache.yaml> positional" \
    " argument) was removed: it validated the in-process" \
    " LMCacheConnectorV1 path's generated YAML, and that connector path is" \
    " not what this repo runs (this cluster always constructs" \
    " MultiConnector[NixlConnector, LMCacheMPConnector] — MP mode; see" \
    " docs/TODO.md §6.23). The live storage-tier config surface is" \
    " scripts/common/start-lmcache-daemon.sh's --l2-adapter <JSON> flag —" \
    " use this script's --l2-adapter-json mode against that spec instead."
