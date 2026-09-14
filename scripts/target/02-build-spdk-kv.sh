#!/usr/bin/env bash
# 02-build-spdk-kv.sh — build the TARGET-side SPDK tree on SMC3: upstream
# SPDK + the two target-side NVMe-KV patches (bdev_kvmalloc, nvmf KV
# opcode routing) that have not yet merged upstream.
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/target/01-host-prep.sh (apt deps below); root not
#                required (only needed for the launch step in 03-, not for
#                building).
# Next step:     scripts/target/03-start-kv-target.sh. SMC1/SMC2 build
#                their OWN initiator-side tree via scripts/common/05-
#                build-spdk-initiator.sh (stock upstream — the NVMe-KV
#                initiator API has been upstream since v26.05, see
#                config/cluster.env's SPDK section).
#
# THERE IS NO FORK. An earlier version of this script required a
# KV_SPDK_REPO "fork URL" and treated its absence as a hard blocker; that
# was wrong. The four NVIDIA NVMe-KV patches (Ben Walker <ben@nvidia.com>)
# are upstream-BOUND patches on a public Gerrit queue
# (https://review.spdk.io/q/topic:kv), not a private tree:
#
#   0001 nvme: recognize KV namespaces   MERGED 2026-08-25 (8dc8327)
#   0002 bdev/kvmalloc                   OPEN   (Gerrit 27889, hashtag 26.09)
#   0003 nvmf: KV namespace support      OPEN   (Gerrit 28298, depends on 0002)
#   0004 nvme: KV unit tests             MERGED 2026-08-25 (b12a372)
#
# 0001/0004 already exist on any current master checkout (merged
# 2026-08-25) — applying them again would fail outright, so this script
# detects that BY CONTENT (not by assuming based on SPDK_TARGET_REF) and
# skips them cleanly. 0002/0003 are the only patches that must actually be
# carried; they are what this script exists to apply. See
# patches/spdk/README.md for full per-patch status and Change-Ids.
#
# usage: 02-build-spdk-kv.sh [--jobs N] [--force-clone]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_host "${TARGET_HOST}" "target"
require_cmd git make gcc meson ninja patch

JOBS="$(nproc)"
FORCE_CLONE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)         JOBS="$2"; shift ;;
        --jobs=*)       JOBS="${1#--jobs=}" ;;
        --force-clone)  FORCE_CLONE=1 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

step "Build SPDK (target): ${SPDK_TARGET_SRC} @ ${SPDK_TARGET_REF} (jobs=${JOBS})"
banner_config

# ─────────────────────────────────────────────────────────────────────────────
# 1. Clone (full history, not shallow — SPDK_TARGET_REF may be an arbitrary
#    SHA, and `git clone --branch` only accepts a branch/tag name) and
#    check out the pinned ref.
# ─────────────────────────────────────────────────────────────────────────────
if [ -d "${SPDK_TARGET_SRC}/.git" ] && [ "${FORCE_CLONE}" -eq 0 ]; then
    ok "tree already present at ${SPDK_TARGET_SRC} — skipping clone" \
       " (--force-clone to override)"
else
    if [ "${FORCE_CLONE}" -eq 1 ] && [ -d "${SPDK_TARGET_SRC}" ]; then
        warn "--force-clone: removing existing ${SPDK_TARGET_SRC}"
        rm -rf "${SPDK_TARGET_SRC}"
    fi
    step "Cloning ${SPDK_UPSTREAM_REPO}"
    mkdir -p "$(dirname "${SPDK_TARGET_SRC}")"
    git clone "${SPDK_UPSTREAM_REPO}" "${SPDK_TARGET_SRC}"
fi

step "Checking out ${SPDK_TARGET_REF}"
( cd "${SPDK_TARGET_SRC}" && git fetch --all --tags && git checkout "${SPDK_TARGET_REF}" )

step "git submodule update"
( cd "${SPDK_TARGET_SRC}" && git submodule update --init --recursive )
ok "submodules present (dpdk, isa-l, etc.)"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Apply patches/spdk/000{1,2,3,4}-*.patch — skipping any whose effect is
#    already present in the checked-out tree (content-detected, so this is
#    correct whether SPDK_TARGET_REF is "master" — which already has
#    0001/0004 — or an older SHA/tag that predates them).
# ─────────────────────────────────────────────────────────────────────────────
step "Applying patches from ${SPDK_PATCH_DIR}"
require_dir "${SPDK_PATCH_DIR}"

_patch_already_applied() {
    local patch_file="$1"
    case "$(basename "${patch_file}")" in
        0001-*)
            # nvme: recognize KV namespaces — adds SPDK_NVME_CSI_KV handling
            # to bdev_nvme.c. Upstream since 8dc8327 (2026-08-25).
            grep -q 'SPDK_NVME_CSI_KV' "${SPDK_TARGET_SRC}/module/bdev/nvme/bdev_nvme.c" 2>/dev/null
            ;;
        0002-*)
            # bdev/kvmalloc — a whole new module directory. NOT upstream as
            # of this writing (Gerrit 27889, open).
            [ -d "${SPDK_TARGET_SRC}/module/bdev/kvmalloc" ]
            ;;
        0003-*)
            # nvmf: KV namespace support — adds nvmf_subsystem_has_kv_iocs()
            # to lib/nvmf/ctrlr.c. NOT upstream as of this writing (Gerrit
            # 28298, open, depends on 0002).
            grep -q 'nvmf_subsystem_has_kv_iocs' "${SPDK_TARGET_SRC}/lib/nvmf/ctrlr.c" 2>/dev/null
            ;;
        0004-*)
            # nvme: KV unit tests — adds a whole new test directory.
            # Upstream since b12a372 (2026-08-25).
            [ -d "${SPDK_TARGET_SRC}/test/unit/lib/nvme/nvme_kv.c" ]
            ;;
        *)
            return 1
            ;;
    esac
}

for _patch in "${SPDK_PATCH_DIR}"/*.patch; do
    [ -e "${_patch}" ] || die "no *.patch files found in ${SPDK_PATCH_DIR}"
    _name="$(basename "${_patch}")"
    if _patch_already_applied "${_patch}"; then
        info "${_name}: already present in this tree — skip (this is" \
             " expected/harmless on SPDK_TARGET_REF=master for 0001/0004," \
             " which merged upstream 2026-08-25; see patches/spdk/README.md)"
        continue
    fi
    step "git am ${_name}"
    if ! ( cd "${SPDK_TARGET_SRC}" && git am "${_patch}" ); then
        ( cd "${SPDK_TARGET_SRC}" && git am --abort ) 2>/dev/null || true
        die "git am failed applying ${_name} to ${SPDK_TARGET_SRC}" \
            " (SPDK_TARGET_REF=${SPDK_TARGET_REF})." \
            " This patch is known to apply cleanly to v26.05 and to a" \
            " pre-0002/0003 master — if SPDK_TARGET_REF has moved far" \
            " enough that the surrounding code changed shape, this needs" \
            " a manual rebase, not a blind retry."
    fi
    ok "applied ${_name}"
done

# ─────────────────────────────────────────────────────────────────────────────
# 3. Configure + build.
# ─────────────────────────────────────────────────────────────────────────────
_configure_args=(--with-nvmf --without-shared --disable-tests
    --disable-unit-tests --disable-examples)
step "./configure ${_configure_args[*]} ..."
# WHY --without-shared matters: plugins/nvme-kv/meson.build links every
# SPDK/DPDK archive by its EXPLICIT .a path (not bare -lNAME) specifically
# because a shared-libs-enabled SPDK build can still leave its vendored
# DPDK submodule emitting BOTH librteX.a and librteX.so side by side in
# dpdk/build/lib — and a bare -lrte_eal is then free to resolve to the .so
# instead of the intended .a, since both live in the same -L directory and
# link-arg ordering alone isn't a reliable fence against it (see
# meson.build's own comment for the `ninja -v -t commands` trace that
# confirmed this). Building this tree with --without-shared removes the
# .so files at the source instead of relying on the plugin's link line to
# dodge them.
(
    cd "${SPDK_TARGET_SRC}"
    ./configure "${_configure_args[@]}"
    make -j "${JOBS}"
)
ok "SPDK build finished"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Verify the build produced everything downstream scripts need.
# ─────────────────────────────────────────────────────────────────────────────
step "Verifying build artifacts"
_required_files=(
    "build/lib/libspdk_nvme.a"
    "build/lib/libspdk_bdev_kvmalloc.a"
    "build/lib/libspdk_sock_posix.a"
    "build/bin/nvmf_tgt"
    "include/spdk/nvme_kv.h"
    "isa-l/.libs/libisal.a"
    "dpdk/build/lib/librte_eal.a"
)
_missing=()
for f in "${_required_files[@]}"; do
    [ -e "${SPDK_TARGET_SRC}/${f}" ] || _missing+=("${f}")
done
[ -d "${SPDK_TARGET_SRC}/module/bdev/kvmalloc" ] \
    || _missing+=("module/bdev/kvmalloc/ (source directory)")
if [ ${#_missing[@]} -gt 0 ]; then
    err "missing build artifacts under ${SPDK_TARGET_SRC}:"
    for f in "${_missing[@]}"; do err "  - ${f}"; done
    die "SPDK build incomplete — see missing artifacts above." \
        " If libspdk_bdev_kvmalloc.a or module/bdev/kvmalloc/ is missing," \
        " patch 0002 (Gerrit 27889) did not apply — re-run with" \
        " --force-clone or check ${SPDK_PATCH_DIR}/0002-*.patch applies" \
        " cleanly to SPDK_TARGET_REF=${SPDK_TARGET_REF} by hand."
fi
ok "all required build artifacts present (nvmf_tgt, bdev_kvmalloc, KV" \
   " command-set support)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Generate the "_only" split archives (idempotent) — used if
#    SPDK_INITIATOR_FLAVOR=fork ever reuses this exact tree; a no-op
#    otherwise.
# ─────────────────────────────────────────────────────────────────────────────
step "Generating split archives (prepare-spdk-libs.sh)"
SPDK_SRC="${SPDK_TARGET_SRC}" "${REPO_ROOT}/plugins/nvme-kv/prepare-spdk-libs.sh"
ok "split archives ready in ${SPDK_TARGET_SRC}/build/lib"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
_built_version="unknown"
if [ -f "${SPDK_TARGET_SRC}/VERSION" ]; then
    _built_version="$(cat "${SPDK_TARGET_SRC}/VERSION")"
elif [ -d "${SPDK_TARGET_SRC}/.git" ]; then
    _built_version="$(cd "${SPDK_TARGET_SRC}" && git describe --tags --always 2>/dev/null || echo unknown)"
fi
step "Summary"
ok "SPDK built at ${SPDK_TARGET_SRC} (version: ${_built_version})"
if [ "${SPDK_INITIATOR_FLAVOR}" = "fork" ]; then
    log "SPDK_INITIATOR_FLAVOR=fork: SMC1 (prefill) and SMC2 (decode) need"
    log "this SAME tree at plugin build time"
    log "(scripts/common/05-build-spdk-initiator.sh). Pull it there with:"
    log ""
    log "  rsync -az ${SSH_USER}@${TARGET_HOST}:${SPDK_TARGET_SRC}/ ${SPDK_SRC}/"
    log ""
    log "(run FROM SMC1/SMC2, against this host — matching path on both ends"
    log " because meson.build's -Dspdk_path is baked into that build's command"
    log " line, not portable to a different path without re-running meson)"
else
    log "SPDK_INITIATOR_FLAVOR=upstream (the default): SMC1 (prefill) and"
    log "SMC2 (decode) build their OWN stock SPDK ${SPDK_VERSION} tree via"
    log "scripts/common/05-build-spdk-initiator.sh and do NOT need this tree"
    log "at all."
fi
log "next: scripts/target/03-start-kv-target.sh"
