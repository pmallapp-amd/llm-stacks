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
# is encoded in its NAME, and each group is delivered differently:
#
#   *-spdk-*         -> staged into the build context; the Dockerfile `git am`s
#                       them onto its own SPDK checkout.
#   *-rocm-aic-*     -> `git apply`d to the vendored checkout right here.
#   *-lmcache-*      -> copied next to rocm-aic's own patches/lmcache/01..14,
#                       to be applied inside the Docker build against LMCache's
#                       tree. RENAMED to 15,16,17.. on the way: that loop applies
#                       in LEXICAL order, and "0006-..." sorts BEFORE "01-...",
#                       which would silently reorder the series.
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

for patch in "${PATCHES_DIR}"/*-rocm-aic-*.patch; do
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
for patch in "${PATCHES_DIR}"/*-lmcache-*.patch; do
    [ -e "${patch}" ] || continue
    n=$((n + 1))
    dest="${n}-$(basename "${patch}" | sed 's/^[0-9]*-lmcache-//')"
    cp "${patch}" "${VENDOR_DIR}/patches/lmcache/${dest}"
    echo "  staged:   $(basename "${patch}") -> patches/lmcache/${dest}"
done
[ "${n}" -gt 14 ] || { echo "ERR: no *-lmcache-*.patch found in ${PATCHES_DIR}" >&2; exit 1; }

# ── 3/4: stage plugin source + SPDK patches into the build context ───────────
echo "== 3/4: stage plugins/ =="
# These destination names are hardcoded in 0005-rocm-aic-dockerfile-build-plugins.patch
# (`COPY plugins/ /tmp/kv-plugins/`, then `meson setup ... nvme-kv-plugin`).
# They deliberately do not track the source directory names — rename plugins/*
# freely, but changing a destination here means editing that patch too.
PLUGIN_DEST="${VENDOR_DIR}/plugins"
rm -rf "${PLUGIN_DEST}"
mkdir -p "${PLUGIN_DEST}/spdk-host-patches"
cp -r "${PLUGINS_DIR}/nvme-kv"  "${PLUGIN_DEST}/nvme-kv-plugin"
cp -r "${PLUGINS_DIR}/xnvme-kv" "${PLUGIN_DEST}/xnvme-kv-plugin"
d=0
for patch in "${PATCHES_DIR}"/*-spdk-*.patch; do
    [ -e "${patch}" ] || continue
    # Stage with a .diff extension: the Dockerfile stage added by
    # patches/0005-rocm-aic-dockerfile-build-plugins.patch globs
    # /tmp/kv-plugins/spdk-host-patches/*.diff and hard-fails with
    # "no patches found" if the glob comes back empty. Copying these through
    # as *.patch silently produced that failure at build stage 27/33, after
    # ~40 minutes of vLLM and NIXL compilation had already succeeded.
    # git am reads the mailbox headers, not the extension, so renaming is safe.
    cp "${patch}" "${PLUGIN_DEST}/spdk-host-patches/$(basename "${patch}" .patch).diff"
    d=$((d + 1))
done
[ "${d}" -eq 4 ] || { echo "ERR: expected 4 *-spdk-*.patch in ${PATCHES_DIR}, found ${d}" >&2; exit 1; }
echo "  staged nvme-kv-plugin/, xnvme-kv-plugin/, spdk-host-patches/ (${d})"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
    echo "SKIP_BUILD=1 — vendored, patched and staged. Not building."
    exit 0
fi

# ── 4/4: build ───────────────────────────────────────────────────────────────
echo "== 4/4: make build (ROCM_ARCH=${ROCM_ARCH}) =="
make -C "${VENDOR_DIR}" build ROCM_ARCH="${ROCM_ARCH}"

echo ""
echo "Built rocm-aic:latest. Verify both plugins landed — a missing plugin is"
echo "otherwise silent until deploy time:"
echo "  docker run --rm rocm-aic:latest \\"
echo "    ls /opt/nixl/lib/x86_64-linux-gnu/plugins/ | grep -E 'SPDK_NVMe_KV|XNVME_KV'"
