#!/usr/bin/env bash
# 25-validate-lmcache-config.sh — prove a generated LMCache YAML is actually
# accepted by the INSTALLED LMCache, not merely well-formed YAML.
#
# Node:          SMC1 (prefill), SMC2 (decode).
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh (need ${VENV} with
#                lmcache + nixl importable).
# Next step:     scripts/common/start-vllm.sh sources this automatically
#                before launching vLLM; run standalone any time to re-check
#                a config file after an LMCache upgrade.
#
# usage: 25-validate-lmcache-config.sh <path-to-lmcache.yaml>
#
# WHY this script exists at all: LMCache ignores unknown top-level keys in
# some versions, and ALWAYS ignores unknown extra_config sub-keys (that dict
# is opaque to the dataclass — nothing type-checks its contents until the
# NIXL storage backend reads specific keys out of it at construction time).
# A config file can therefore load cleanly, start a vLLM server that answers
# health checks, and serve every request — while never once touching the
# remote KV target, because a single mistyped key inside extra_config was
# silently dropped. That failure mode is indistinguishable from "working" at
# every layer except an actual P/D cache-hit test, which by definition you
# only find out you need after suspecting something is wrong. This script
# is the pre-flight check that removes the need to suspect.
#
# Exit non-zero if:
#   - the YAML fails to parse,
#   - any top-level key is not in the installed LMCacheEngineConfig's
#     accepted set (a real, if imperfect, proxy — see NOTE below),
#   - any extra_config sub-key is not read anywhere in
#     NixlStorageConfig.from_cache_engine_config's source (introspected via
#     `inspect.getsource`, not hardcoded here — this is what makes the check
#     survive a version bump instead of silently going stale itself),
#   - the installed LMCache's NIXL backend-and-mem_type allowlists do not
#     include the configured nixl_backend (see gen-lmcache-config.sh's
#     "THE BACKEND-ALLOWLIST RISK" section for what this catches).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CFG="${1:-}"
[ -n "${CFG}" ] || die "usage: $0 <path-to-lmcache.yaml>"
require_file "${CFG}"

if [ ! -x "${VENV}/bin/python" ]; then
    die "no venv at ${VENV} — run scripts/common/20-build-vllm-lmcache.sh first"
fi

step "Validating ${CFG} against installed LMCache"

"${VENV}/bin/python" - "${CFG}" <<'PYEOF'
import inspect
import re
import sys

import yaml

cfg_path = sys.argv[1]

with open(cfg_path) as f:
    generated = yaml.safe_load(f) or {}

if not isinstance(generated, dict):
    print(f"FAIL: {cfg_path} does not parse to a YAML mapping", file=sys.stderr)
    sys.exit(1)

generated_extra = generated.get("extra_config") or {}

# ── 1. Locate the installed LMCacheEngineConfig and its accepted top-level
#      keys. Try v1 first (current), then the pre-v1 legacy location, so
#      this script degrades gracefully across an LMCache major-version
#      change instead of just crashing with an ImportError. ──────────────
try:
    from lmcache.v1.config import LMCacheEngineConfig, _CONFIG_DEFINITIONS
    config_module = "lmcache.v1.config"
except ImportError:
    try:
        from lmcache.config import LMCacheEngineConfig  # type: ignore
        _CONFIG_DEFINITIONS = None
        config_module = "lmcache.config"
    except ImportError as exc:
        print(
            "FAIL: could not import LMCacheEngineConfig from either "
            "lmcache.v1.config or lmcache.config — is lmcache installed in "
            f"this venv? ({exc})",
            file=sys.stderr,
        )
        sys.exit(1)

print(f"INFO: using {config_module}.LMCacheEngineConfig", file=sys.stderr)

if _CONFIG_DEFINITIONS is not None:
    accepted_top_level = set(_CONFIG_DEFINITIONS.keys())
else:
    # Fallback for older/newer layouts without _CONFIG_DEFINITIONS: enumerate
    # dataclass fields directly. Less precise (misses env-var aliases) but
    # never crashes the check outright.
    import dataclasses
    accepted_top_level = {f.name for f in dataclasses.fields(LMCacheEngineConfig)}

# ── 2. Top-level key diff. ────────────────────────────────────────────────
print("\n--- top-level keys ---", file=sys.stderr)
top_level_fail = False
for key in generated:
    if key in accepted_top_level:
        print(f"  ACCEPTED  {key}", file=sys.stderr)
    else:
        print(f"  IGNORED   {key}  (typo, or version drift — not a "
              f"recognized LMCacheEngineConfig field)", file=sys.stderr)
        top_level_fail = True

# ── 3. extra_config sub-key diff, via source introspection of the NIXL
#      storage backend's own config-reading function. This is the check
#      that actually matters: extra_config is an opaque dict to the
#      dataclass, so nothing above this line would ever catch a typo inside
#      it. We regex-extract every `extra_config.get("KEY"` occurrence from
#      the REAL installed source, not a hardcoded list here, so this check
#      tracks whatever LMCache version is actually installed. ─────────────
print("\n--- extra_config sub-keys (NIXL storage backend) ---", file=sys.stderr)
extra_fail = False
allowlist_fail = False
backend_module = None
try:
    from lmcache.v1.storage_backend import nixl_storage_backend as backend_module
except ImportError as exc:
    print(
        f"WARN: could not import lmcache.v1.storage_backend.nixl_storage_backend "
        f"({exc}) — skipping extra_config sub-key and backend-allowlist checks. "
        "This LMCache version may have moved/renamed the NIXL storage backend "
        "module; update this script's import path.",
        file=sys.stderr,
    )

if backend_module is not None:
    try:
        src = inspect.getsource(
            backend_module.NixlStorageConfig.from_cache_engine_config
        )
        recognized_extra_keys = set(
            re.findall(r'extra_config\.get\(\s*"([a-zA-Z0-9_]+)"', src)
        )
    except (AttributeError, OSError) as exc:
        print(f"WARN: could not introspect from_cache_engine_config: {exc}",
              file=sys.stderr)
        recognized_extra_keys = None

    if recognized_extra_keys:
        for key in generated_extra:
            if key == "nixl_backend_params":
                # Not looked up via extra_config.get("nixl_backend_params")
                # by name in every version-consistent way here; presence is
                # asserted structurally (it's a dict merged in verbatim) —
                # treat as accepted rather than flag a false negative.
                print(f"  ACCEPTED  extra_config.{key}  (structural, not a "
                      f"single extra_config.get() call)", file=sys.stderr)
                continue
            if key in recognized_extra_keys:
                print(f"  ACCEPTED  extra_config.{key}", file=sys.stderr)
            else:
                print(f"  IGNORED   extra_config.{key}  (not read anywhere "
                      f"in from_cache_engine_config — typo or version drift)",
                      file=sys.stderr)
                extra_fail = True

        for required in ("enable_nixl_storage", "nixl_backend", "nixl_pool_size"):
            if required not in generated_extra:
                print(f"  MISSING BUT REQUIRED  extra_config.{required}",
                      file=sys.stderr)
                extra_fail = True

    # ── 4. Backend-allowlist check. See gen-lmcache-config.sh's "THE
    #      BACKEND-ALLOWLIST RISK" section for what this catches: a backend
    #      name absent from either list fails LOUDLY here instead of
    #      SILENTLY writing to local disk (FILE mem_type fallback) or
    #      raising deep inside backend construction the first time a real
    #      request tries to save. ─────────────────────────────────────────
    print("\n--- NIXL backend allowlist (installed LMCache source) ---",
          file=sys.stderr)
    configured_backend = generated_extra.get("nixl_backend", "")
    try:
        validate_src = inspect.getsource(
            backend_module.NixlStorageConfig.validate_nixl_backend
        )
        # Pull every quoted identifier-shaped string out of the function
        # body — this is the backend-name allowlist regardless of how it's
        # structured (tuple membership, if/elif chain, etc.), so it survives
        # a refactor that keeps the same set of names. Deliberately NOT
        # anchored to all-caps: real backend names are mixed case
        # ("SPDK_NVMe_KV" is exactly the string this repo's plugin registers
        # under — see spdk_nvme_kv_plugin.cpp's nixl_plugin_init() — an
        # all-caps-only pattern would never match it and every check below
        # would report a false FAIL regardless of whether the installed
        # LMCache actually recognizes it).
        validate_names = set(re.findall(r'"([A-Za-z][A-Za-z0-9_]*)"', validate_src))
        if configured_backend in validate_names:
            print(f"  ACCEPTED  validate_nixl_backend() recognizes "
                  f"'{configured_backend}'", file=sys.stderr)
        else:
            print(f"  FAIL      validate_nixl_backend() does NOT recognize "
                  f"'{configured_backend}' (known names: "
                  f"{sorted(validate_names)}). This installed LMCache will "
                  f"raise AssertionError('Invalid NIXL backend & device "
                  f"combination') the first time the backend is constructed. "
                  f"This requires the LMCache backend-allowlist patch — see "
                  f"gen-lmcache-config.sh's header comment.", file=sys.stderr)
            allowlist_fail = True
    except (AttributeError, OSError) as exc:
        print(f"WARN: could not introspect validate_nixl_backend: {exc}",
              file=sys.stderr)

    try:
        agent_src = inspect.getsource(backend_module.NixlDynamicStorageAgent.__init__)
        obj_names = set(re.findall(r'"([A-Za-z][A-Za-z0-9_]*)"', agent_src))
        if configured_backend in obj_names:
            print(f"  ACCEPTED  '{configured_backend}' takes the OBJ "
                  f"mem_type path (content-derived keys, no local files)",
                  file=sys.stderr)
        else:
            print(f"  FAIL      '{configured_backend}' is NOT in the OBJ "
                  f"mem_type allowlist ({sorted(obj_names)}) — it will take "
                  f"the FILE mem_type path instead, which does real "
                  f"os.open()/os.path.join(extra_config.nixl_path, key) "
                  f"calls against the LOCAL filesystem. This would silently "
                  f"never reach SMC3 at all. Requires the same LMCache "
                  f"backend-allowlist patch as above.", file=sys.stderr)
            allowlist_fail = True
    except (AttributeError, OSError) as exc:
        print(f"WARN: could not introspect NixlDynamicStorageAgent.__init__: {exc}",
              file=sys.stderr)

# ── 5. Live plugin introspection — create a throwaway nixl_agent and echo
#      back what the ACTUAL installed plugin (not LMCache's idea of it,
#      and not this script's idea of it either) reports for its params, so
#      a human can diff it against nixl_backend_params in the YAML by eye.
#
#      Deliberately NOT a hardcoded ("trid", "max_value_size",
#      "kv_slot_offset") tuple: that was correct only for SPDK_NVMe_KV and
#      silently echoed nothing for XNVME_KV, whose getParams() advertises a
#      different pair ({dev_uri, max_value_size} — see
#      plugins/xnvme-kv/xnvme_kv_plugin.cpp). Iterating over whatever keys
#      the LIVE plugin's get_plugin_params() actually returns makes this
#      echo correct for both backends today and for any future backend
#      without editing this script again. ─────────────────────────────────
print("\n--- live NIXL plugin introspection ---", file=sys.stderr)
try:
    from nixl._api import nixl_agent, nixl_agent_config

    agent = nixl_agent("lmcache-config-validator", nixl_agent_config(backends=[]))
    plugins = agent.get_plugin_list()
    print(f"  available NIXL plugins: {plugins}", file=sys.stderr)
    backend_name = generated_extra.get("nixl_backend", "SPDK_NVMe_KV")
    if backend_name in plugins:
        params = agent.get_plugin_params(backend_name)
        print(f"  {backend_name} get_plugin_params(): {params}", file=sys.stderr)
        configured_params = generated_extra.get("nixl_backend_params", {}) or {}
        param_keys = list(params.keys()) if hasattr(params, "keys") else []
        if not param_keys:
            print(f"  WARN: get_plugin_params({backend_name}) returned no "
                  f"introspectable keys ({params!r}) — nothing to diff",
                  file=sys.stderr)
        for k in param_keys:
            configured = configured_params.get(k)
            print(f"    {k}: plugin default={params[k]!r}  "
                  f"configured={configured!r}", file=sys.stderr)
        # Flag the inverse mismatch too: a key this YAML configures that the
        # live plugin does NOT advertise at all (e.g. kv_slot_offset carried
        # over into an XNVME_KV config by copy-paste) is exactly the
        # "looks load-bearing, does nothing" trap both plugins' getParams()
        # comments warn about.
        for k in configured_params:
            if k not in param_keys:
                print(f"    {k}: configured={configured_params[k]!r}  "
                      f"NOT ADVERTISED by {backend_name}'s get_plugin_params() "
                      f"— this key is IGNORED by the plugin, not applied",
                      file=sys.stderr)
    else:
        print(f"  FAIL: '{backend_name}' not in NIXL's plugin list — check "
              f"NIXL_PLUGIN_DIR is set and points at the directory "
              f"10-build-stack.sh installed into", file=sys.stderr)
        top_level_fail = True
except Exception as exc:  # noqa: BLE001 - this is a diagnostic tool, report and continue
    print(f"WARN: live NIXL plugin introspection failed: {exc}", file=sys.stderr)

print("", file=sys.stderr)
if top_level_fail or extra_fail or allowlist_fail:
    print("FAIL: one or more generated keys are not accepted by the "
          "installed LMCache, or the NIXL backend allowlist rejects "
          f"'{generated_extra.get('nixl_backend')}'. See details above.",
          file=sys.stderr)
    sys.exit(1)

print("PASS: all generated keys are recognized by the installed LMCache.",
      file=sys.stderr)
PYEOF

ok "${CFG} validated against installed LMCache"
