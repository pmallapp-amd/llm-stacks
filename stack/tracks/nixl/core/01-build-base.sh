#!/usr/bin/env bash
# 01-build-base.sh — build nixl:base from Dockerfile.nixl-base.
# Track B: upstream NIXL (ai-dynamo/nixl) + POSIX/UCX plugins.
#
# Since 2026-08-14 this also builds UCX --with-rocm, which is what gives NIXL's
# UCX plugin (and therefore vLLM's NixlConnector) GPU-memory registration. To do
# that without installing a second copy of ROCm into the image, the script
# stages a MINIMAL ROCm sysroot out of the host's $ROCM_PATH and hands it to the
# build as a BuildKit named build context (`--build-context rocmsysroot=...`).
# rocm-plugin/build.sh bind-mounts the same $ROCM_PATH, so the two can't drift.
#
#   NIXL_REF=<branch|sha>   upstream NIXL ref (default: main)
#   UCX_REF=<branch|tag|sha> UCX ref, now actually checked out (default: master —
#                           which is what this image always really built, despite
#                           the old Dockerfile ARG claiming v1.21.x)
#   NPROC=N                 parallel jobs (default: nproc)
#   PYTHON_VERSION=<ver>    Python version for NIXL's bindings/build venv
#                           (default: 3.14, matching the Ubuntu 24.04 vLLM
#                           image's interpreter — see ../vllm/06-build-vllm.sh)
#   BASE_IMAGE_TAG=<tag>    override Dockerfile's default Ubuntu tag (24.04).
#                           Set to match a specific host's glibc (e.g. 22.04)
#                           when building for native (non-Docker) execution
#                           on that host — see 05-nixlbench-pcie-kv-host.sh.
#   ROCM_PATH=<path>        host ROCm to build UCX against (default: /opt/rocm)
#   UCX_ROCM=0|1            1 = build UCX --with-rocm (default: 1 when ROCM_PATH
#                           exists, else 0). UCX_ROCM=1 with no ROCm is a hard
#                           error rather than a silent downgrade: an image that
#                           quietly cannot register GPU memory is the exact
#                           failure this change exists to remove.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.nixl-base"
NIXL_REF=${NIXL_REF:-main}
UCX_REF=${UCX_REF:-master}
NPROC=${NPROC:-$(nproc)}
PYTHON_VERSION=${PYTHON_VERSION:-3.14}
ROCM_PATH=${ROCM_PATH:-/opt/rocm}
TAG_SUFFIX=$(echo "${NIXL_REF}" | tr '/' '-' | tr -cd 'a-zA-Z0-9.-')

if [ -z "${UCX_ROCM:-}" ]; then
    if [ -d "${ROCM_PATH}" ]; then UCX_ROCM=1; else UCX_ROCM=0; fi
fi

# ── Stage the ROCm sysroot for the UCX build ─────────────────────────────────
# Only what UCX's config/m4/rocm.m4 looks for: the ROCm headers (it wants
# hsa/hsa.h, hsa/hsa_ext_amd.h and hip/hip_runtime.h) plus the three shared
# objects the rocm UCT/UCM modules link against. ~110 MB, versus ~18 GB for the
# whole of /opt/rocm and multiple GB for an AMD apt repo install.
#
# It has to live INSIDE the docker build context (a transient .rocm-sysroot/
# next to the Dockerfile) rather than being passed as a BuildKit named build
# context: this cluster's Docker has no buildx component installed, so
# `docker build --build-context` is not available. Removed on exit, including
# on failure, so it never survives into a git status or an rsync.
ROCM_STAGE="${SCRIPT_DIR}/.rocm-sysroot"
cleanup() { rm -rf "${ROCM_STAGE}"; }
trap cleanup EXIT
rm -rf "${ROCM_STAGE}"
mkdir -p "${ROCM_STAGE}"

if [ "${UCX_ROCM}" = "1" ]; then
    [ -d "${ROCM_PATH}" ] || {
        echo "ERR: UCX_ROCM=1 but ROCM_PATH='${ROCM_PATH}' does not exist."
        echo "     Point ROCM_PATH at this host's ROCm, or set UCX_ROCM=0 to build an"
        echo "     image that CANNOT register GPU memory (NixlConnector then needs"
        echo "     kv_buffer_device=cpu and every KV transfer stages through DRAM)."
        exit 1; }
    [ -f "${ROCM_PATH}/include/hsa/hsa_ext_amd.h" ] || {
        echo "ERR: ${ROCM_PATH}/include/hsa/hsa_ext_amd.h not found — ROCM_PATH does not"
        echo "     look like a ROCm install with development headers."
        exit 1; }
    mkdir -p "${ROCM_STAGE}/include" "${ROCM_STAGE}/lib"
    cp -a "${ROCM_PATH}/include/." "${ROCM_STAGE}/include/"
    for lib in libhsa-runtime64 libamdhip64 librocprofiler-register; do
        # shellcheck disable=SC2086
        cp -a ${ROCM_PATH}/lib/${lib}.so* "${ROCM_STAGE}/lib/" 2>/dev/null || {
            echo "ERR: ${ROCM_PATH}/lib/${lib}.so* not found"; exit 1; }
    done
    ROCM_VERSION=$(cat "${ROCM_PATH}/.info/version" 2>/dev/null || echo unknown)
else
    # The Dockerfile COPYs this context unconditionally; an empty directory is
    # not a valid COPY source, so leave a marker behind.
    echo "UCX_ROCM=0 — no ROCm sysroot staged." > "${ROCM_STAGE}/.no-rocm"
    ROCM_VERSION="(none)"
fi

BUILD_ARGS=(--build-arg NIXL_REF="${NIXL_REF}" --build-arg NPROC="${NPROC}" \
            --build-arg DEFAULT_PYTHON_VERSION="${PYTHON_VERSION}" \
            --build-arg UCX_REF="${UCX_REF}" \
            --build-arg UCX_ROCM="${UCX_ROCM}")
EXTRA_TAGS=()
if [ -n "${BASE_IMAGE_TAG:-}" ]; then
    BUILD_ARGS+=(--build-arg BASE_IMAGE_TAG="${BASE_IMAGE_TAG}")
    EXTRA_TAGS+=(-t "nixl:base-${BASE_IMAGE_TAG//./}")
fi

echo "01-build-base: nixl:base"
echo "  Dockerfile     : ${DOCKERFILE}"
echo "  NIXL ref       : ${NIXL_REF}"
echo "  UCX ref        : ${UCX_REF}"
echo "  Python version : ${PYTHON_VERSION}"
echo "  BASE_IMAGE_TAG : ${BASE_IMAGE_TAG:-<Dockerfile default>}"
echo "  UCX_ROCM       : ${UCX_ROCM} (ROCm ${ROCM_VERSION} from ${ROCM_PATH})"
echo "  rocm sysroot   : ${ROCM_STAGE} ($(du -sh "${ROCM_STAGE}" 2>/dev/null | cut -f1))"
echo "  tags           : nixl:base  nixl:base-${TAG_SUFFIX}${BASE_IMAGE_TAG:+  nixl:base-${BASE_IMAGE_TAG//./}}"
echo "  nproc          : ${NPROC}"

[ -f "${DOCKERFILE}" ] || { echo "ERR: ${DOCKERFILE} not found"; exit 1; }

docker build \
    "${BUILD_ARGS[@]}" \
    -t nixl:base \
    -t "nixl:base-${TAG_SUFFIX}" \
    "${EXTRA_TAGS[@]}" \
    -f "${DOCKERFILE}" \
    "${SCRIPT_DIR}"

echo "OK: nixl:base (also nixl:base-${TAG_SUFFIX}${BASE_IMAGE_TAG:+, nixl:base-${BASE_IMAGE_TAG//./}})"

# ── Post-build verification ──────────────────────────────────────────────────
# The Dockerfile asserts on build artefacts, which a docker layer cache can
# replay from a previous build. This re-checks the tagged image that actually
# came out, so a cached/mis-tagged result cannot pass silently.
if [ "${UCX_ROCM}" = "1" ]; then
    echo ""
    echo "=== Verifying UCX ROCm support in the tagged image ==="
    docker run --rm nixl:base bash -lc '
        set -e
        ucx_info -b | grep -E "PACKAGE_VERSION|UCX_CONFIGURE_FLAGS|^#define (uct|ucm)_MODULES"
        ucx_info -b | grep -q -- "--with-rocm=" || { echo "FAIL: no --with-rocm"; exit 1; }
        ucx_info -b | grep -E "^#define uct_MODULES" | grep -q rocm || { echo "FAIL: uct_MODULES lacks rocm"; exit 1; }
        ls -1 /usr/lib/ucx/libuct_rocm.so /usr/lib/ucx/libucm_rocm.so
        echo "VERIFIED: nixl:base UCX has ROCm memory-domain support"
    '
    echo ""
    echo "NOTE: the GPU-visible check (ucx_info -d listing rocm_cpy/rocm_ipc) needs"
    echo "      /dev/kfd and therefore runs at deploy time, not here. See"
    echo "      ../vllm/06-build-vllm.sh's verification step."
fi

echo "NOTE: this moved the floating nixl:base tag. Restore with:"
echo "  docker tag nixl:base-<previous-suffix> nixl:base"
