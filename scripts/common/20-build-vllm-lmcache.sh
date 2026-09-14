#!/usr/bin/env bash
# 20-build-vllm-lmcache.sh — venv with vLLM + LMCache + NIXL python bindings.
#
# Node:          SMC1 (prefill), SMC2 (decode).
# Prerequisites: scripts/common/10-build-stack.sh has completed (NIXL_PREFIX
#                populated, plugins installed).
# Next step:     scripts/common/gen-lmcache-config.sh, then
#                scripts/prefill/03-start-prefill.sh /
#                scripts/decode/03-start-decode.sh.
#
# Idempotent: re-running reuses ${VENV} if present and only (re)installs
# packages whose pinned version differs from what's already there (pip's own
# no-op-on-match behavior handles that).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Pinned versions.
#
# WHY this exact pairing is the default (rather than "latest"): the vLLM
# KVConnector plugin API and LMCache's LMCacheConnectorV1 implementation of it
# move independently and the wire contract between them is NOT
# version-stable. A mismatched pair fails at the worst possible time — after
# both packages install cleanly and vLLM starts constructing its connector —
# with `KeyError: 'LMCacheConnectorV1'` deep in vLLM's connector factory
# (vllm.distributed.kv_transfer.kv_connector.factory), because the installed
# vLLM's connector registry was built against a different LMCache connector
# class name/location than what got installed. There is no error at pip
# install time to catch this; it only shows up when the server tries to
# start. Pin exact versions and change them together, never independently.
VLLM_VERSION="${VLLM_VERSION:-0.28.0}"
LMCACHE_VERSION="${LMCACHE_VERSION:-0.5.4}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/rocm6.2}"

step "Building vLLM ${VLLM_VERSION} + LMCache ${LMCACHE_VERSION} venv at ${VENV}"
info "TORCH_INDEX_URL=${TORCH_INDEX_URL}"

require_cmd python3

if [ ! -x "${VENV}/bin/python" ]; then
    python3 -m venv "${VENV}"
    ok "created venv: ${VENV}"
else
    info "venv already exists: ${VENV} (reusing)"
fi

# shellcheck source=/dev/null
source "${VENV}/bin/activate"
python -m pip install --upgrade pip wheel

# ─────────────────────────────────────────────────────────────────────────────
# torch (ROCm) + vLLM + LMCache
# ─────────────────────────────────────────────────────────────────────────────
# torch is installed from the ROCm wheel index FIRST and separately, not left
# to vllm's own dependency resolution, because vllm[rocm]'s transitive torch
# pin frequently drifts behind the ROCm wheel index's latest build and pip's
# resolver has no way to know a CUDA-tagged "torch==X" on PyPI is wrong for
# this host; pinning the ROCm wheel explicitly here is what keeps torch's
# HIP backend the one actually loaded.
python -m pip install --index-url "${TORCH_INDEX_URL}" torch

python -m pip install "vllm==${VLLM_VERSION}"
python -m pip install "lmcache==${LMCACHE_VERSION}"

# aiohttp for scripts/proxy/disagg_proxy.py — chosen over fastapi+httpx
# because it's a single dependency that serves as BOTH the async HTTP
# server and the upstream client, and its StreamResponse primitive is what
# makes unbuffered SSE pass-through (see disagg_proxy.py) straightforward.
python -m pip install aiohttp

log "installed versions:"
python -c "import torch; print('  torch      :', torch.__version__)"
python -c "import vllm; print('  vllm       :', vllm.__version__)"
python -c "import lmcache; print('  lmcache    :', lmcache.__version__)"

# ─────────────────────────────────────────────────────────────────────────────
# NIXL python bindings
# ─────────────────────────────────────────────────────────────────────────────
# The ROCm build of NIXL (installed by 10-build-stack.sh's meson install step)
# ships its python bindings under site-packages as `nixl_rocm`, not `nixl` —
# an upstream naming quirk of the ROCm meson build. LMCache's storage backend
# (lmcache/v1/storage_backend/nixl_storage_backend.py) does
# `from nixl._api import nixl_agent`, hardcoding the upstream package name.
# Without a shim, that import fails at LMCache import time with
# `ModuleNotFoundError: No module named 'nixl'`, even though the bindings are
# present and importable as `nixl_rocm`.
NIXL_PY_DIR="${NIXL_PREFIX}/lib/python3/dist-packages"
export PYTHONPATH="${NIXL_PY_DIR}:${PYTHONPATH:-}"

if python -c "import nixl" >/dev/null 2>&1; then
    ok "nixl importable directly (no shim needed)"
elif python -c "import nixl_rocm" >/dev/null 2>&1; then
    info "found nixl_rocm, not nixl — installing the nixl -> nixl_rocm shim package"
    _site="$("${VENV}/bin/python" -c 'import site; print(site.getsitepackages()[0])')"
    _shim_dir="${_site}/nixl"
    mkdir -p "${_shim_dir}"
    cat > "${_shim_dir}/__init__.py" <<'EOF'
# Shim package: the ROCm NIXL meson build installs its python bindings under
# the name "nixl_rocm" instead of upstream's "nixl". LMCache imports
# `from nixl._api import nixl_agent` unconditionally (it targets upstream
# NIXL), so without this shim every LMCache NIXL storage/PD code path fails
# at import time with ModuleNotFoundError, before any of our config even
# gets read. Generated by scripts/common/20-build-vllm-lmcache.sh — do not
# hand-edit; re-run that script to regenerate after a NIXL rebuild.
import sys

import nixl_rocm as _nixl_rocm
from nixl_rocm import _api, _bindings, _utils, logging  # noqa: F401

sys.modules[__name__ + "._api"] = _api
sys.modules[__name__ + "._bindings"] = _bindings
sys.modules[__name__ + "._utils"] = _utils
sys.modules[__name__ + ".logging"] = logging
EOF
    ok "shim installed at ${_shim_dir}/__init__.py"
else
    die "neither 'nixl' nor 'nixl_rocm' is importable with" \
        " PYTHONPATH=${NIXL_PY_DIR}. Check that 10-build-stack.sh's NIXL" \
        " meson install actually installed python bindings (meson option" \
        " -Dpython=enabled, or equivalent for this NIXL_VERSION), and that" \
        " ${NIXL_PY_DIR} matches the venv's python3 minor version."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Final verification
# ─────────────────────────────────────────────────────────────────────────────
step "Verifying nixl / lmcache / vllm import chain"
python -c "from nixl._api import nixl_agent; print('nixl ok')"
python -c "import lmcache, vllm; print(lmcache.__version__, vllm.__version__)"
ok "vLLM + LMCache + NIXL bindings verified importable"

# ─────────────────────────────────────────────────────────────────────────────
# Activation snippet
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${STACK_ROOT}/etc"
cat > "${STACK_ROOT}/etc/env.sh" <<EOF
# Generated by scripts/common/20-build-vllm-lmcache.sh — do not hand-edit.
# Source this before running any prefill/decode script:
#   source ${STACK_ROOT}/etc/env.sh

source "${VENV}/bin/activate"

export NIXL_PLUGIN_DIR="${NIXL_PLUGIN_DIR}"
export PYTHONPATH="${NIXL_PY_DIR}:\${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${NIXL_PREFIX}/lib/x86_64-linux-gnu:${UCX_PREFIX}/lib:${ROCM_PATH}/lib:\${LD_LIBRARY_PATH:-}"

# expandable_segments breaks HIP IPC export of vLLM's KV tensors when NIXL
# hands out a raw device pointer for VRAM_SEG registration — the allocator
# can move/resize the backing segment under the exported IPC handle, which
# invalidates a peer's already-imported mapping without either side being
# told. Disabled here at the environment-file level (not just in
# 03-start-prefill.sh/03-start-decode.sh) so it applies to any tooling that
# sources this file, including ad hoc debugging sessions and nixlbench.
export PYTORCH_HIP_ALLOC_CONF="expandable_segments:False"
EOF
ok "wrote ${STACK_ROOT}/etc/env.sh"

log "next: scripts/common/gen-lmcache-config.sh <prefill|decode> <output-path>"
