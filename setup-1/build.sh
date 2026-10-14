#!/usr/bin/env bash
# build.sh — vendor ROCm/rocm-aic at a pinned commit, apply patches/, stage
# plugins/ into its build context, and build the image. Produces rocm-aic:latest.
#
#   ROCM_ARCH=<gfxNNNN>   required. gfx90a = MI210, gfx942 = MI300X.
#   ROCM_AIC_REF=<sha>    commit to pin. Bump deliberately, not casually, and
#                         re-verify every patch still applies afterwards.
#   VENDOR_DIR=<path>     checkout location (default <this-dir>/vendor/rocm-aic)
#   SKIP_BUILD=1          vendor + patch + stage only, no image build
#
# The vendored tree is never edited in place — every change goes through
# patches/, so re-running this script reproduces the same result rather than
# failing on "patch already applied".
#
# patches/ is a single flat, `git am`-able series. Which tree each patch targets
# is encoded in its NAME, in the token immediately after the 4-digit number, and
# each group is delivered differently.
#
# The globs below are ANCHORED to that position (`[0-9][0-9][0-9][0-9]-lmcache-*`
# rather than `*-lmcache-*`) because a tree name can legitimately appear later in
# a description too: 0010-vllm-guard-lmcache-mp-connector matched BOTH the vllm
# and the lmcache glob, which staged one patch into two trees and then hard-failed
# the build when it could not apply to the second. Keep them anchored, and do not
# rely on descriptions avoiding the words lmcache/vllm/rocm-aic.
#
#   *-rocm-aic-*     -> `git apply`d to the vendored checkout right here.
#   *-lmcache-*      -> copied next to rocm-aic's own patches/lmcache/01..14,
#                       to be applied inside the Docker build against LMCache's
#                       tree. RENAMED to 15,16,17.. on the way: that loop applies
#                       in LEXICAL order, and "0006-..." sorts BEFORE "01-...",
#                       which would silently reorder the series.
#   *-vllm-*         -> same deal against rocm-aic's patches/vllm/01..03, renamed
#                       to 04,05,.. The Dockerfile `git apply`s these from
#                       /app/vllm, so their diffs are rooted at a/vllm/...
#                       (NOT a/ -- the vLLM checkout lives one level down).
#
# A *-spdk-* bucket (staged for the Dockerfile to `git am` onto its own SPDK
# checkout) used to exist for the SPDK_NVMe_KV plugin. Dropped 2026-10-05 along
# with that plugin -- setup-1 only ever deploys XNVME_KV against a local
# NVMe-KV device node now. See HANDOFF.md.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCHES_DIR="${SCRIPT_DIR}/patches"
PLUGINS_DIR="${SCRIPT_DIR}/plugins"
VENDOR_DIR=${VENDOR_DIR:-${SCRIPT_DIR}/vendor/rocm-aic}
ROCM_AIC_REF=${ROCM_AIC_REF:-bb386562ccce21c12b8b577c7abcead68bc4befd}
ROCM_ARCH=${ROCM_ARCH:?ROCM_ARCH is required — gfx90a (MI210) or gfx942 (MI300X)}

# ── 1/4: vendor ──────────────────────────────────────────────────────────────
echo "== 1/4: vendor rocm-aic @ ${ROCM_AIC_REF} =="
if [ -d "${VENDOR_DIR}/.git" ]; then
    current=$(git -C "${VENDOR_DIR}" rev-parse HEAD)
    if [ "${current}" = "${ROCM_AIC_REF}" ]; then
        echo "  already at ${ROCM_AIC_REF}"
    else
        echo "  at ${current}, re-vendoring"
        rm -rf "${VENDOR_DIR}"
    fi
fi
if [ ! -d "${VENDOR_DIR}/.git" ]; then
    mkdir -p "$(dirname "${VENDOR_DIR}")"
    git clone --quiet https://github.com/ROCm/rocm-aic.git "${VENDOR_DIR}"
    git -C "${VENDOR_DIR}" checkout --quiet "${ROCM_AIC_REF}"
fi
git -C "${VENDOR_DIR}" log -1 --format='  %H %ci %s'

# ── 2/4: apply patches ───────────────────────────────────────────────────────
echo "== 2/4: apply patches/ =="
# Idempotence: undo whatever a previous run of this script did, so re-running
# against an unchanged ROCM_AIC_REF reproduces the same result. `git clean` only
# ever removes UNTRACKED files, so it can never touch rocm-aic's own tracked
# patches/lmcache/01..14 — only the ones we copied in.
git -C "${VENDOR_DIR}" checkout --quiet -- docker/Dockerfile
git -C "${VENDOR_DIR}" clean --quiet -fd -- patches/lmcache/ 2>/dev/null || true
git -C "${VENDOR_DIR}" clean --quiet -fd -- patches/vllm/ 2>/dev/null || true

for patch in "${PATCHES_DIR}"/[0-9][0-9][0-9][0-9]-rocm-aic-*.patch; do
    [ -e "${patch}" ] || continue
    if git -C "${VENDOR_DIR}" apply --check "${patch}" 2>/dev/null; then
        git -C "${VENDOR_DIR}" apply "${patch}"
        echo "  applied:  $(basename "${patch}")"
    else
        echo "ERR: $(basename "${patch}") does not apply to rocm-aic @ ${ROCM_AIC_REF}." >&2
        echo "     Rebase it against that commit rather than editing the vendored tree." >&2
        exit 1
    fi
done

n=14
for patch in "${PATCHES_DIR}"/[0-9][0-9][0-9][0-9]-lmcache-*.patch; do
    [ -e "${patch}" ] || continue
    n=$((n + 1))
    dest="${n}-$(basename "${patch}" | sed 's/^[0-9]*-lmcache-//')"
    cp "${patch}" "${VENDOR_DIR}/patches/lmcache/${dest}"
    echo "  staged:   $(basename "${patch}") -> patches/lmcache/${dest}"
done
[ "${n}" -gt 14 ] || { echo "ERR: no *-lmcache-*.patch found in ${PATCHES_DIR}" >&2; exit 1; }

# rocm-aic ships patches/vllm/01..03; ours continue from 04. Zero-padded so the
# Dockerfile's lexical glob keeps them after 03 rather than sorting "10" < "03".
n=3
for patch in "${PATCHES_DIR}"/[0-9][0-9][0-9][0-9]-vllm-*.patch; do
    [ -e "${patch}" ] || continue
    n=$((n + 1))
    dest="$(printf '%02d' "${n}")-$(basename "${patch}" | sed 's/^[0-9]*-vllm-//')"
    cp "${patch}" "${VENDOR_DIR}/patches/vllm/${dest}"
    echo "  staged:   $(basename "${patch}") -> patches/vllm/${dest}"
done

# ── 3/4: stage plugin source into the build context ──────────────────────────
echo "== 3/4: stage plugins/ =="
# This destination name is hardcoded in 0005-rocm-aic-dockerfile-build-plugins.patch
# (`COPY plugins/ /tmp/kv-plugins/`, then `meson setup ... xnvme-kv-plugin`).
# It deliberately does not track the source directory name — rename plugins/*
# freely, but changing the destination here means editing that patch too.
#
# nvme-kv/ (SPDK_NVMe_KV plugin source) still lives under plugins/ but is no
# longer staged or built — dropped 2026-10-05 along with the SPDK Dockerfile
# stage and the *-spdk-*.patch series. See HANDOFF.md.
PLUGIN_DEST="${VENDOR_DIR}/plugins"
rm -rf "${PLUGIN_DEST}"
mkdir -p "${PLUGIN_DEST}"
cp -r "${PLUGINS_DIR}/xnvme-kv" "${PLUGIN_DEST}/xnvme-kv-plugin"
echo "  staged xnvme-kv-plugin/"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
    echo "SKIP_BUILD=1 — vendored, patched and staged. Not building."
    exit 0
fi

# ── 4/4: build ───────────────────────────────────────────────────────────────
echo "== 4/4: make build (ROCM_ARCH=${ROCM_ARCH}) =="
make -C "${VENDOR_DIR}" build ROCM_ARCH="${ROCM_ARCH}"

echo ""
echo "Built rocm-aic:latest. Verify the plugin landed — a missing plugin is"
echo "otherwise silent until deploy time:"
echo "  docker run --rm rocm-aic:latest \\"
echo "    ls /opt/nixl/lib/x86_64-linux-gnu/plugins/ | grep XNVME_KV"
