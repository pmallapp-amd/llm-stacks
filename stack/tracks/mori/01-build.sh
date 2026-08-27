#!/usr/bin/env bash
# 01-build.sh — build vllm-mori:rocm
#
# Produces: vllm-mori:rocm
#   vLLM (ROCm, v0.23.0 base) + AMD MORI (mori.io), which is everything
#   MoRIIOConnector needs. vLLM already registers the connector itself; this
#   image only supplies the `mori` package it imports.
#
# There is no separate library image and no runtime volume — MORI is a Python
# package with a compiled core, so it installs into the vLLM image the way
# Mooncake's Transfer Engine compiles into vllm-mooncake:rocm, not the way NIXL
# is extracted out of nixl:n0.
#
# Run 00-preflight.sh FIRST. It answers, in about a minute, whether this host
# can run either MoRIIO backend at all — in particular whether the cross-process
# HIP IPC that backend=xgmi depends on works here. Building first and finding
# out afterwards costs ~40 minutes.
#
# Build time: ~35-45 min (MORI C++/HIP core + JIT kernel precompile), or ~10 min
# with MORI_FROM_PYPI=1 on a Python 3.10/3.12 base image.
#
# Override env:
#   MORI_IMAGE=<tag>       output image tag (default: vllm-mori:rocm)
#   VLLM_BASE=<img>        base image (default:
#                          rocm/vllm:rocm7.14.0_cdna_ubuntu24.04_py3.14_pytorch_2.11.0_vllm_0.23.0
#                          — deliberately the SAME base the NIXL track's
#                          vllm-nixl:rocm uses, so a MORI number and a NIXL
#                          number differ by the KV-transfer layer and not by the
#                          vLLM version, the ROCm version or the model runtime)
#   MORI_REF=<tag|branch>  MORI version to build (default: v1.2.2)
#   MORI_REPO=<url>        (default: https://github.com/ROCm/mori.git)
#   MORI_GPU_ARCHS=<arch>  gfx942 (MI300X/MI325X) | gfx950 (MI355X) | gfx1250.
#                          Default: auto-detected from this host, else gfx942.
#                          gfx90a (MI210) is NOT supported by MORI.
#   MORI_FROM_PYPI=1       install the amd_mori wheel instead of building from
#                          source (default: 0). Only works on a Python 3.10 or
#                          3.12 base — PyPI publishes no cp313/cp314 wheels as
#                          of amd-mori 1.2.2 (2026-08-14).
#   SKIP_PREFLIGHT=1       do not refuse when 00-preflight.sh has not been run
#                          (default: 0)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

MORI_IMAGE=${MORI_IMAGE:-vllm-mori:rocm}
VLLM_BASE=${VLLM_BASE:-rocm/vllm:rocm7.14.0_cdna_ubuntu24.04_py3.14_pytorch_2.11.0_vllm_0.23.0}
MORI_REF=${MORI_REF:-v1.2.2}
MORI_REPO=${MORI_REPO:-https://github.com/ROCm/mori.git}
MORI_FROM_PYPI=${MORI_FROM_PYPI:-0}
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-0}

# ── Preflight ────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || { echo "ERR: docker not on PATH"; exit 1; }

[ -f "${SCRIPT_DIR}/Dockerfile.vllm-mori" ] || {
    echo "ERR: ${SCRIPT_DIR}/Dockerfile.vllm-mori missing — incomplete checkout?"; exit 1; }

# Resolve the GPU arch to compile for BEFORE checking for the base image: an
# unsupported arch is a "this host can never run this track" answer, and it
# should not be hidden behind a fixable "docker pull the base image" message.
# MORI's setup.py would probe the local GPU, but a docker build has no
# /dev/kfd, so the target must be passed in.
if [ -z "${MORI_GPU_ARCHS:-}" ]; then
    DETECTED=""
    if command -v rocminfo >/dev/null 2>&1; then
        DETECTED=$(rocminfo 2>/dev/null | awk '/^  Name: *gfx/ {print $2}' | sort -u \
                   | grep -E '^(gfx942|gfx950|gfx1250)$' | head -1 || true)
    fi
    if [ -n "${DETECTED}" ]; then
        MORI_GPU_ARCHS="${DETECTED}"
        echo "MORI_GPU_ARCHS not set — detected ${MORI_GPU_ARCHS} on this host"
    else
        MORI_GPU_ARCHS=gfx942
        echo "MORI_GPU_ARCHS not set and no supported GPU detected — defaulting to gfx942"
        echo "  (set MORI_GPU_ARCHS explicitly if this build host differs from the run host)"
    fi
fi

case "${MORI_GPU_ARCHS}" in
    gfx942|gfx950|gfx1250) ;;
    *)
        echo "ERR: MORI_GPU_ARCHS='${MORI_GPU_ARCHS}' is not supported by MORI."
        echo "     MORI's setup.py accepts gfx942 / gfx950 / gfx1250 only."
        echo "     gfx90a (MI210) is not supported — the MORI track cannot run on"
        echo "     host <SETUP2_PD_NODE_IP>. Use an MI300X/MI325X/MI355X host."
        exit 1 ;;
esac

docker image inspect "${VLLM_BASE}" >/dev/null 2>&1 || {
    echo "ERR: base image ${VLLM_BASE} not present locally."
    echo "     Pull it first:  docker pull ${VLLM_BASE}"
    echo "     (or set VLLM_BASE=<img> to an image you already have)"
    exit 1; }

if [ "${SKIP_PREFLIGHT}" != "1" ] && [ -e /dev/kfd ]; then
    echo ""
    echo "Reminder: 00-preflight.sh checks whether either MoRIIO backend can"
    echo "work on this host — in particular the cross-process HIP IPC that"
    echo "backend=xgmi requires, which is known-broken on some kernel-5.15 hosts."
    echo "Set SKIP_PREFLIGHT=1 to silence this."
fi

echo ""
echo "01-build: ${MORI_IMAGE}"
echo "  base       : ${VLLM_BASE}"
echo "  mori       : ${MORI_REF} from ${MORI_REPO}"
echo "  gpu archs  : ${MORI_GPU_ARCHS}"
echo "  source     : $([ "${MORI_FROM_PYPI}" = "1" ] && echo 'PyPI wheel (amd_mori)' || echo 'git, built in-image')"
echo "  connector  : MoRIIOConnector (already in vLLM; nothing patched here)"
echo ""

DOCKER_BUILDKIT=1 docker build \
    -f "${SCRIPT_DIR}/Dockerfile.vllm-mori" \
    -t "${MORI_IMAGE}" \
    --build-arg "VLLM_BASE=${VLLM_BASE}" \
    --build-arg "MORI_REF=${MORI_REF}" \
    --build-arg "MORI_REPO=${MORI_REPO}" \
    --build-arg "MORI_GPU_ARCHS=${MORI_GPU_ARCHS}" \
    --build-arg "MORI_FROM_PYPI=${MORI_FROM_PYPI}" \
    "${SCRIPT_DIR}"

echo ""
echo "=== Built ${MORI_IMAGE} ==="
docker image inspect "${MORI_IMAGE}" --format '  id: {{.Id}}  size: {{.Size}}' 2>/dev/null || true
echo ""
echo "  Next: bash stack/tracks/mori/02-deploy-mori-pd.sh"
echo "        (or: TRACK=mori bash bench/llama-benchy/run.sh)"
