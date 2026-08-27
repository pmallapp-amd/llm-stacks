#!/usr/bin/env bash
# vendor.sh — shallow-clone ROCm/rocm-aic to the pinned commit into
# vendor/rocm-aic/. NOT committed to this repo (same treatment this repo
# gives large external clones like SPDK — see stack/foundation/spdk-kv/) —
# built fresh on whichever host runs build.sh, never rsynced.
#
#   ROCM_AIC_REF=<sha>   commit to pin (default: the SHA this track was
#                        researched and drafted against — bump deliberately,
#                        not casually, and re-verify patches/0001 and
#                        patches/dockerfile/0003 still apply after bumping)
#   VENDOR_DIR=<path>    clone destination (default: <this-dir>/vendor/rocm-aic)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROCM_AIC_REF=${ROCM_AIC_REF:-bb386562ccce21c12b8b577c7abcead68bc4befd}
VENDOR_DIR=${VENDOR_DIR:-${SCRIPT_DIR}/vendor/rocm-aic}

if [ -d "${VENDOR_DIR}/.git" ]; then
    current=$(git -C "${VENDOR_DIR}" rev-parse HEAD)
    if [ "${current}" = "${ROCM_AIC_REF}" ]; then
        echo "OK: ${VENDOR_DIR} already at ${ROCM_AIC_REF}"
        exit 0
    fi
    echo "NOTE: ${VENDOR_DIR} exists at ${current}, re-vendoring to ${ROCM_AIC_REF}"
    rm -rf "${VENDOR_DIR}"
fi

mkdir -p "$(dirname "${VENDOR_DIR}")"
git clone --quiet https://github.com/ROCm/rocm-aic.git "${VENDOR_DIR}"
git -C "${VENDOR_DIR}" checkout --quiet "${ROCM_AIC_REF}"

echo "OK: vendored rocm-aic @ ${ROCM_AIC_REF} into ${VENDOR_DIR}"
git -C "${VENDOR_DIR}" log -1 --format='  %H %ci %s'
