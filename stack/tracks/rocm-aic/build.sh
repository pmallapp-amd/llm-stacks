#!/usr/bin/env bash
# build.sh — vendor rocm-aic, apply our patches, stage our plugin source into
# its build context, then `make build`.
#
# Never touches the vendored ROCm/rocm-aic Dockerfile/compose files in place —
# every edit goes through patches/, so re-running vendor.sh (e.g. after a
# ROCM_AIC_REF bump) and re-running this script reproduces the same result.
#
#   ROCM_AIC_REF=<sha>   passed through to vendor.sh
#   ROCM_ARCH=<gfxNNNN>  required by rocm-aic's own Makefile (e.g. gfx90a for
#                        MI210 on .100, gfx942 for MI300X on <SETUP3_TARGET_NODE>)
#   VENDOR_DIR=<path>    rocm-aic checkout (default: <this-dir>/vendor/rocm-aic)
#   SKIP_BUILD=1         vendor + patch + stage only, skip `make build` (for
#                        iterating on the patches without a full rebuild)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NIXL_CORE_DIR=$(cd "${SCRIPT_DIR}/../nixl/core" && pwd)
SPDK_HOST_PATCHES_DIR=$(cd "${SCRIPT_DIR}/../../foundation/spdk-kv/patches/spdk-host" && pwd)
VENDOR_DIR=${VENDOR_DIR:-${SCRIPT_DIR}/vendor/rocm-aic}
ROCM_ARCH=${ROCM_ARCH:?ROCM_ARCH is required — e.g. gfx90a (MI210) or gfx942 (MI300X)}

echo "== 1/4: vendor rocm-aic =="
VENDOR_DIR="${VENDOR_DIR}" bash "${SCRIPT_DIR}/vendor.sh"

echo "== 2/4: apply patches/ =="
# vendor.sh only re-clones when ROCM_AIC_REF changes (see its own header), so a
# vendored checkout left over from a previous run of THIS script already has
# our patches applied. Reset any local modifications first so this step is
# idempotent — re-running build.sh against an unchanged ROCM_AIC_REF must
# reproduce the same result, not fail on "patch already applied".
git -C "${VENDOR_DIR}" checkout --quiet -- docker/Dockerfile
# `git clean` only ever removes untracked files, so this can never touch
# rocm-aic's own tracked patches/lmcache/{01..14}-*.patch — only whatever we
# staged into this directory (untracked, since it arrived via `cp`, not a
# commit) on a previous run of this script.
git -C "${VENDOR_DIR}" clean --quiet -fd -- patches/lmcache/ 2>/dev/null || true

# patches/lmcache/*.patch (our own, numbered from 15 up) targets LMCache's
# OWN tree (cloned fresh inside the Dockerfile build stage at LMCACHE_REF,
# with rocm-aic's own 14 patches pre-applied) — it is not something to
# `git apply` against this checkout. It belongs next to rocm-aic's existing
# patches/lmcache/*.patch so the Dockerfile's own apply-every-*.patch-in-
# lexical-order loop picks it up automatically at build time, purely by
# filename (copy, not git apply). Stage every patch we own, not just 15 —
# this glob used to be hardcoded to 15-*.patch and silently dropped any
# later-numbered patch (e.g. 16) added to this directory.
cp "${SCRIPT_DIR}"/patches/lmcache/*.patch "${VENDOR_DIR}/patches/lmcache/"
echo "  staged: patches/lmcache/*.patch -> vendor/rocm-aic/patches/lmcache/"

# patches/dockerfile/0003-*.patch targets docker/Dockerfile in THIS checkout
# directly, so it does get `git apply`'d here.
for patch in "${SCRIPT_DIR}"/patches/dockerfile/*.patch; do
    [ -e "${patch}" ] || continue
    if git -C "${VENDOR_DIR}" apply --check "${patch}" 2>/dev/null; then
        git -C "${VENDOR_DIR}" apply "${patch}"
        echo "  applied: $(basename "${patch}")"
    else
        echo "ERR: $(basename "${patch}") does not apply to vendored rocm-aic — rebase against current ROCM_AIC_REF" >&2
        exit 1
    fi
done

echo "== 3/4: stage plugin source into build context =="
PLUGIN_DEST="${VENDOR_DIR}/plugins"
rm -rf "${PLUGIN_DEST}"
mkdir -p "${PLUGIN_DEST}/spdk-host-patches"
cp -r "${NIXL_CORE_DIR}/nvme-kv-plugin" "${PLUGIN_DEST}/nvme-kv-plugin"
cp -r "${NIXL_CORE_DIR}/xnvme-kv-plugin" "${PLUGIN_DEST}/xnvme-kv-plugin"
cp "${SPDK_HOST_PATCHES_DIR}"/*.diff "${PLUGIN_DEST}/spdk-host-patches/"
echo "  staged nvme-kv-plugin/, xnvme-kv-plugin/, spdk-host-patches/ (4 diffs) -> ${PLUGIN_DEST}"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
    echo "SKIP_BUILD=1 — vendored, patched, and staged. Not building."
    exit 0
fi

echo "== 4/4: make build =="
make -C "${VENDOR_DIR}" build ROCM_ARCH="${ROCM_ARCH}"
