#!/usr/bin/env bash
# 01-pull.sh — fetch the ATOM image and prove the stack is actually assembled.
#
# There is deliberately no build step in this track. ATOM's tested base is
# Python 3.12 / ROCm 7.0.2 / torch 2.8, while this repo's NIXL and MORI images
# are Python 3.14 / ROCm 7.14 / torch 2.11. CLAUDE.md documents what happens
# when those are mixed (GLIBCXX / ABI failures at plugin load), so ATOM gets
# AMD's prebuilt image rather than being ported into ours. The cost is that this
# track does NOT share a base image with the others — say so in any write-up
# that compares them.
#
# The probe below matters more than the pull. ATOM activates silently through
# entry_points, so "the image pulled" tells you nothing about whether ATOM,
# AITER and the MoRIIO connector are all present and reachable. Each is checked
# separately, because each can be absent independently.
#
# Override env:
#   ATOM_IMAGE=<img>   (default: rocm/atom-dev:vllm-latest)
#   PROBE_ONLY=1       skip the pull, just re-run the capability probe
set -euo pipefail

ATOM_IMAGE=${ATOM_IMAGE:-rocm/atom-dev:vllm-latest}
PROBE_ONLY=${PROBE_ONLY:-0}

if [ "${PROBE_ONLY}" != "1" ]; then
    echo "=== Pulling ${ATOM_IMAGE} ==="
    docker pull "${ATOM_IMAGE}"
    echo
fi

echo "=== Capability probe ==="
echo "  image: ${ATOM_IMAGE}"
echo "  id   : $(docker image inspect --format '{{.Id}}' "${ATOM_IMAGE}" 2>/dev/null || echo unknown)"
echo

# The probe MUST have GPU access. Without /dev/kfd + /dev/dri, rocminfo fails,
# which cascades: aiter refuses to import ("Get GPU arch from rocminfo failed"),
# every atom.models.* import raises RuntimeError, and vLLM falls back to
# UnspecifiedPlatform. All of that looks exactly like "ATOM and AITER are
# missing" when in fact only the devices were. Attaching the GPUs is what makes
# the answers mean anything.
#
# Group IDs are passed numerically on purpose: `--group-add render` aborts the
# container outright on Ubuntu 24.04 images (this cost a false-negative
# preflight result on the MORI track), so resolve the GIDs on the host instead.
_gids=()
for g in render video; do
    _gid=$(getent group "$g" 2>/dev/null | cut -d: -f3)
    [ -n "${_gid}" ] && _gids+=(--group-add "${_gid}")
done

docker run --rm \
    --device /dev/kfd --device /dev/dri \
    "${_gids[@]+"${_gids[@]}"}" \
    --security-opt seccomp=unconfined \
    --entrypoint python3 "${ATOM_IMAGE}" -c '
import importlib, sys

def line(label, value):
    print(f"  {label:<34} {value}")

# --- vLLM -------------------------------------------------------------------
try:
    import vllm
    line("vLLM version", vllm.__version__)
except Exception as e:
    line("vLLM", f"MISSING ({e})"); sys.exit(1)

# --- MoRIIOConnector --------------------------------------------------------
# Without this the two-node P/D half of the stack is impossible in this image.
try:
    from vllm.distributed.kv_transfer.kv_connector.factory import KVConnectorFactory as F
    reg = sorted(F._registry)
    line("MoRIIOConnector registered", "MoRIIOConnector" in reg)
    line("  connectors available", ", ".join(reg)[:140])
except Exception as e:
    line("KV connector registry", f"UNREADABLE ({e})")

# --- ATOM plugin ------------------------------------------------------------
# ATOM hooks in via entry_points; importing it is not the same as vLLM having
# resolved it as the platform, so report both.
try:
    import atom
    line("atom package", getattr(atom, "__version__", "present"))
except Exception as e:
    line("atom package", f"MISSING ({e})")

try:
    from vllm.platforms import current_platform
    line("vLLM current_platform", type(current_platform).__name__)
except Exception as e:
    line("vLLM current_platform", f"UNREADABLE ({e})")

# --- AITER ------------------------------------------------------------------
# AITER is what ATOM is built on, but it is also a separate vLLM integration.
# Confirm the library is really importable rather than inferring it from ATOM.
try:
    import aiter
    line("aiter package", getattr(aiter, "__version__", "present"))
except Exception as e:
    line("aiter package", f"MISSING ({e})")

# --- ATOM model coverage ----------------------------------------------------
# The question is NOT "does vLLM support this architecture" — vLLM 0.27 supports
# most of these natively. The question is "does ATOM OWN it", i.e. did the
# plugin replace the registry entry. An arch vLLM supports but ATOM has not
# overridden runs on stock vLLM: it serves fine, and ATOM is simply not in the
# path. So resolve each arch to its implementing MODULE and look for "atom".
try:
    from vllm.model_executor.models.registry import ModelRegistry
    archs = set(ModelRegistry.get_supported_archs())
    models = getattr(ModelRegistry, "models", {})
    for a in ("KimiK25ForConditionalGeneration", "KimiK3ForConditionalGeneration",
              "DeepseekV3ForCausalLM", "Qwen3MoeForCausalLM", "Qwen3ForCausalLM",
              "GptOssForCausalLM", "Glm4MoeForCausalLM", "MixtralForCausalLM"):
        if a not in archs:
            line(f"  arch {a}", "NOT SUPPORTED AT ALL")
            continue
        mod = "?"
        try:
            info = models.get(a)
            mod = (getattr(info, "module_name", None)
                   or getattr(getattr(info, "cls", None), "__module__", None)
                   or str(info))
        except Exception:
            pass
        owner = "ATOM" if "atom" in str(mod).lower() else "stock vLLM"
        line(f"  arch {a}", f"{owner}   [{str(mod)[:58]}]")
except Exception as e:
    line("ModelRegistry", f"UNREADABLE ({e})")

# --- ATOM native model modules ---------------------------------------------
for m in ("atom.models.kimi_k25", "atom.models.deepseek_v2", "atom.models.qwen3_moe"):
    try:
        importlib.import_module(m); line(f"  {m}", "importable")
    except Exception as e:
        line(f"  {m}", f"no ({type(e).__name__})")
'

echo
echo "Interpreting this — READ BEFORE CONCLUDING ANYTHING:"
echo "  * The arch ownership above is measured at IMPORT time, and it is EXPECTED"
echo "    to say 'stock vLLM' for everything. ATOM's model overrides are installed"
echo "    by the vllm.general_plugins entry point (register_model), which does not"
echo "    run until ENGINE INIT. So this probe CANNOT tell you whether ATOM owns a"
echo "    model, and 'stock vLLM' here is not evidence that it does not."
echo "    Verified 2026-08-21: this probe reported stock vLLM for every arch while"
echo "    a real engine start logged ATOM registering overrides for all of them."
echo "  * Same caveat for current_platform: it reads RocmPlatform here."
echo "  * What this probe DOES establish: the vLLM version, that the atom and aiter"
echo "    packages import, that atom.models.* are present, and — the one that"
echo "    actually gates this track — that MoRIIOConnector is registered."
echo
echo "To settle ATOM ownership, start an engine and read its log:"
echo "    docker logs <container> | grep -E '^\\[atom'"
echo "  You want lines of the form:"
echo "    [atom] Register model <Arch> to vLLM with atom.plugin.vllm...:ATOM..."
echo "  An architecture absent from THAT list is the real silent-fallback case."
