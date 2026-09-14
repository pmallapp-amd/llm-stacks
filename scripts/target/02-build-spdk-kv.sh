#!/usr/bin/env bash
# 02-build-spdk-kv.sh — clone (if needed) and build the TARGET-side SPDK
# tree on SMC3.
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/target/01-host-prep.sh (apt deps for the SPDK
#                configure/make below, including librdmacm-dev and
#                libibverbs-dev when SPDK_WITH_RDMA=1); root not required
#                (only needed for the RPC-configure step in 03-, not for
#                building).
# Next step:     scripts/target/03-start-kv-target.sh. SMC1/SMC2 build their
#                OWN initiator-side tree via scripts/common/05-build-spdk-
#                initiator.sh — as of SPDK v26.05 they no longer need this
#                one at all (see SPDK_TARGET_FLAVOR below). The rsync hint
#                this script used to print unconditionally now only fires
#                when an operator deliberately sets SPDK_INITIATOR_FLAVOR=fork.
#
# SPDK_TARGET_FLAVOR selects what gets built into ${SPDK_TARGET_SRC}:
#   fork      (default) KV_SPDK_REPO/KV_SPDK_REF — SPDK + NVIDIA's
#             out-of-tree bdev_kvmalloc module and nvmf KV opcode routing.
#             Required: as of v26.05 neither has landed upstream (below).
#   upstream  ${SPDK_UPSTREAM_REPO} @ ${SPDK_VERSION}, no patches. Builds
#             fine but CANNOT serve a KV namespace: the INITIATOR API
#             (spdk_nvme_kv_store/retrieve/delete/exist/list(),
#             include/spdk/nvme_kv.h) went upstream in v26.05, but
#             bdev_kvmalloc and lib/nvmf/ctrlr_bdev.c's KV opcode dispatch
#             did NOT. This flavour exists so an operator can prove that to
#             themselves (or stage an out-of-tree bdev build against a stock
#             tree) — the artifact check in step 3 below deliberately still
#             fails on it, on purpose, explaining exactly this.
#
# usage: 02-build-spdk-kv.sh [--jobs N] [--force-clone]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_host "${TARGET_HOST}" "target"
require_cmd git make gcc meson ninja

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

step "Build SPDK (target): ${SPDK_TARGET_SRC} (flavor=${SPDK_TARGET_FLAVOR} jobs=${JOBS})"
banner_config

# ─────────────────────────────────────────────────────────────────────────────
# 1. Clone / verify the tree. Branches on SPDK_TARGET_FLAVOR (fork|upstream).
# ─────────────────────────────────────────────────────────────────────────────
case "${SPDK_TARGET_FLAVOR}" in
    fork|upstream) ;;
    *) die "SPDK_TARGET_FLAVOR must be fork|upstream, got '${SPDK_TARGET_FLAVOR}'" ;;
esac

_have_kv_header=0
[ -f "${SPDK_TARGET_SRC}/include/spdk/nvme_kv.h" ] && _have_kv_header=1

if [ "${SPDK_TARGET_FLAVOR}" = "upstream" ]; then
    # See the top-of-file "SPDK_TARGET_FLAVOR" comment: this branch builds a
    # STOCK tree that step 3's artifact check deliberately fails on — it
    # cannot serve a KV namespace (bdev_kvmalloc + nvmf KV opcode routing
    # have not landed upstream). The clone still needs to happen so that
    # failure is reachable and self-explanatory instead of this script
    # dying earlier with "nothing to clone".
    if [ -d "${SPDK_TARGET_SRC}/.git" ] && [ "${FORCE_CLONE}" -eq 0 ]; then
        ok "upstream tree already present at ${SPDK_TARGET_SRC} —" \
           " skipping clone (--force-clone to override)"
    else
        if [ "${FORCE_CLONE}" -eq 1 ] && [ -d "${SPDK_TARGET_SRC}" ]; then
            warn "--force-clone: removing existing ${SPDK_TARGET_SRC}"
            rm -rf "${SPDK_TARGET_SRC}"
        fi
        step "Cloning ${SPDK_UPSTREAM_REPO} @ ${SPDK_VERSION}"
        mkdir -p "$(dirname "${SPDK_TARGET_SRC}")"
        git clone --branch "${SPDK_VERSION}" --depth 1 \
            "${SPDK_UPSTREAM_REPO}" "${SPDK_TARGET_SRC}"
    fi
elif [ "${_have_kv_header}" -eq 1 ] && [ "${FORCE_CLONE}" -eq 0 ]; then
    ok "kv_spdk tree already present at ${SPDK_TARGET_SRC} (nvme_kv.h found) —" \
       " skipping clone (--force-clone to override)"
elif [ -z "${KV_SPDK_REPO:-}" ]; then
    # This is the load-bearing check for the whole build: without a fork
    # URL AND without an already-correct tree, there is nothing to build
    # against. Stock upstream SPDK (github.com/spdk/spdk) — even at v26.05,
    # where the INITIATOR-side nvme_kv API is now upstream — still has
    # neither bdev_kvmalloc nor nvmf KV opcode routing: cloning it here
    # would build successfully and produce a spdk_tgt that silently cannot
    # serve an NVMe-KV namespace at all, failing three scripts downstream
    # (03-, 04-, and every plugin build on SMC1/SMC2) with no clue this was
    # the cause.
    die "SPDK_TARGET_SRC (${SPDK_TARGET_SRC}) has no include/spdk/nvme_kv.h," \
        " and KV_SPDK_REPO is unset — nothing to clone." \
        $'\n''    Stock upstream SPDK (even v26.05) has neither bdev_kvmalloc'\
        $'\n''    nor nvmf KV opcode routing: this target needs the kv_spdk'\
        $'\n''    fork. Point at it:'\
        $'\n'"        KV_SPDK_REPO=<url> KV_SPDK_REF=<ref> $0"\
        $'\n''    or place an already-built/cloned kv_spdk tree at'\
        $'\n'"        ${SPDK_TARGET_SRC}"\
        $'\n''    (e.g. rsync one down from wherever it was built before), or'\
        $'\n''    explicitly set SPDK_TARGET_FLAVOR=upstream to build a stock'\
        $'\n''    tree anyway (it WILL fail the step-3 artifact check — that'\
        $'\n''    is the point; see the top-of-file comment).'
else
    step "Cloning kv_spdk from ${KV_SPDK_REPO}${KV_SPDK_REF:+ @ ${KV_SPDK_REF}}"
    if [ "${FORCE_CLONE}" -eq 1 ] && [ -d "${SPDK_TARGET_SRC}" ]; then
        warn "--force-clone: removing existing ${SPDK_TARGET_SRC}"
        rm -rf "${SPDK_TARGET_SRC}"
    fi
    if [ ! -d "${SPDK_TARGET_SRC}/.git" ]; then
        mkdir -p "$(dirname "${SPDK_TARGET_SRC}")"
        git clone "${KV_SPDK_REPO}" "${SPDK_TARGET_SRC}"
    else
        info "${SPDK_TARGET_SRC} already cloned, reusing; fetching latest refs"
        (cd "${SPDK_TARGET_SRC}" && git fetch --all)
    fi
    if [ -n "${KV_SPDK_REF:-}" ]; then
        (cd "${SPDK_TARGET_SRC}" && git checkout "${KV_SPDK_REF}")
    fi
    [ -f "${SPDK_TARGET_SRC}/include/spdk/nvme_kv.h" ] \
        || die "cloned ${KV_SPDK_REPO} but include/spdk/nvme_kv.h is still" \
               " missing — this does not look like the kv_spdk fork" \
               " (wrong repo/ref, or the patches were reverted upstream)."
    ok "kv_spdk tree ready at ${SPDK_TARGET_SRC}"
fi

step "git submodule update"
( cd "${SPDK_TARGET_SRC}" && git submodule update --init --recursive )
ok "submodules present (dpdk, isa-l, etc.)"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Configure + build.
# ─────────────────────────────────────────────────────────────────────────────
_configure_args=(--without-shared --with-nvmf --with-uring
    --disable-tests --disable-unit-tests --disable-examples)
if [ "${SPDK_WITH_RDMA}" = "1" ]; then
    # F4: RDMA (verbs provider by default) needs librdmacm-dev +
    # libibverbs-dev at configure/link time (01-host-prep.sh installs
    # them) and produces lib/nvmf/rdma.c's nvmf_rdma transport plus
    # nvme_rdma.o inside libspdk_nvme.a. --with-rdma=mlx5_dv would
    # additionally need libmlx5 — not requested here, since this cluster's
    # target-side NICs are POLLARA, not Mellanox, so the plain verbs
    # provider is what applies; set SPDK_RDMA_PROVIDER if that ever changes.
    _configure_args+=(--with-rdma="${SPDK_RDMA_PROVIDER:-verbs}")
fi
step "./configure ${_configure_args[*]} ..."
# WHY --without-shared matters: plugins/nvme-kv/meson.build links every
# SPDK/DPDK archive by its EXPLICIT .a path (not bare -lNAME) specifically
# because a shared-libs-enabled SPDK build can still leave its vendored
# DPDK submodule emitting BOTH librteX.a and librteX.so side by side in
# dpdk/build/lib — and a bare -lrte_eal is then free to resolve to the .so
# instead of the intended .a, since both live in the same -L directory and
# link-arg ordering alone isn't a reliable fence against it (see
# meson.build's own comment for the `ninja -v -t commands` trace that
# confirmed this). The resulting plugin .so carries a DT_NEEDED on
# librte_eal.so etc. that this repo never ships — NIXL's dlopen() of the
# plugin then fails silently and is reported as merely "unsupported
# backend", nowhere near the actual shared-lib root cause. Building this
# tree with --without-shared removes the .so files at the source instead
# of relying on the plugin's link line to dodge them.
(
    cd "${SPDK_TARGET_SRC}"
    ./configure "${_configure_args[@]}"
    make -j "${JOBS}"
)
ok "SPDK (${SPDK_TARGET_FLAVOR}) build finished"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Verify the build produced everything the plugin's meson.build and this
#    target's own scripts need. build/bin/spdk_tgt + libspdk_bdev_kvmalloc.a
#    are the load-bearing ones for the TARGET role. include/spdk/nvme_kv.h
#    is now ALSO satisfied by stock upstream v26.05 (F1) — by itself it no
#    longer proves this is the fork; only libspdk_bdev_kvmalloc.a does (F2:
#    fork-only, nothing upstream provides it as of v26.05).
# ─────────────────────────────────────────────────────────────────────────────
step "Verifying build artifacts"
_required_files=(
    "build/lib/libspdk_nvme.a"
    "build/lib/libspdk_bdev_kvmalloc.a"
    "build/lib/libspdk_sock_posix.a"
    "build/bin/spdk_tgt"
    "include/spdk/nvme_kv.h"
    "isa-l/.libs/libisal.a"
    "dpdk/build/lib/librte_eal.a"
)
_missing=()
for f in "${_required_files[@]}"; do
    [ -e "${SPDK_TARGET_SRC}/${f}" ] || _missing+=("${f}")
done
if [ ${#_missing[@]} -gt 0 ]; then
    err "missing build artifacts under ${SPDK_TARGET_SRC}:"
    for f in "${_missing[@]}"; do err "  - ${f}"; done
    if printf '%s\n' "${_missing[@]}" | grep -q libspdk_bdev_kvmalloc.a; then
        if [ "${SPDK_TARGET_FLAVOR}" = "upstream" ]; then
            err "libspdk_bdev_kvmalloc.a is missing because SPDK_TARGET_FLAVOR=upstream"
            err "was requested: as of SPDK v26.05 the NVMe-KV INITIATOR API"
            err "(spdk_nvme_kv_store/retrieve/delete/exist/list(),"
            err "include/spdk/nvme_kv.h) is upstream, but the TARGET side is"
            err "NOT — there is no bdev_kvmalloc module anywhere under"
            err "module/bdev/, and lib/nvmf/ctrlr_bdev.c still dispatches only"
            err "NVM command-set opcodes (READ/WRITE/FLUSH/DSM/WRITE_ZEROES),"
            err "with no KV opcode routing. A stock v26.05 tree therefore"
            err "CANNOT serve a KV namespace, full stop — this is expected"
            err "behavior for this flavor, not a broken build. Either supply"
            err "the fork (KV_SPDK_REPO/KV_SPDK_REF, SPDK_TARGET_FLAVOR=fork,"
            err "the default) or build an out-of-tree KV bdev module"
            err "against this stock tree yourself."
        else
            err "libspdk_bdev_kvmalloc.a is missing: this means the WRONG SPDK"
            err "fork was built (stock upstream SPDK does not have this bdev"
            err "module at all — it only exists in kv_spdk). Check KV_SPDK_REPO"
            err "/ KV_SPDK_REF and rebuild."
        fi
    fi
    die "SPDK build incomplete — see missing artifacts above"
fi
ok "all required build artifacts present"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Generate the "_only" split archives (idempotent). Also doubles as a
#    second, independent proof the fork is correct: prepare-spdk-libs.sh
#    extracts specific named object files (nvme_tcp.o, nvme_pcie.o, ...)
#    that only exist if libspdk_nvme.a was actually built with those
#    transports compiled in.
# ─────────────────────────────────────────────────────────────────────────────
step "Generating split archives (prepare-spdk-libs.sh)"
SPDK_SRC="${SPDK_TARGET_SRC}" "${REPO_ROOT}/plugins/nvme-kv/prepare-spdk-libs.sh"
ok "split archives ready in ${SPDK_TARGET_SRC}/build/lib"

# ─────────────────────────────────────────────────────────────────────────────
# Detect + report the actual SPDK version built. This tree and SMC1/SMC2's
# own initiator tree (scripts/common/05-build-spdk-initiator.sh) are
# INDEPENDENT — but if SPDK_INITIATOR_FLAVOR=upstream (the default) is in
# play, it's worth flagging loudly here if this fork tree's base predates
# v26.05, since diagnosing "which tree has what API" gets confusing
# otherwise, especially if an operator later reuses KV_SPDK_REF as a pin
# for something else.
# ─────────────────────────────────────────────────────────────────────────────
_built_version="unknown"
if [ -f "${SPDK_TARGET_SRC}/VERSION" ]; then
    _built_version="$(cat "${SPDK_TARGET_SRC}/VERSION")"
elif [ -d "${SPDK_TARGET_SRC}/.git" ]; then
    _built_version="$(cd "${SPDK_TARGET_SRC}" && git describe --tags --always 2>/dev/null || echo unknown)"
fi
info "SPDK version built (${SPDK_TARGET_SRC}): ${_built_version}"
if [ "${SPDK_INITIATOR_FLAVOR}" = "upstream" ]; then
    case "${_built_version}" in
        v26.0[5-9]*|v26.1*|v2[7-9].*|v[3-9]*)
            ;;
        *)
            warn "this tree's version (${_built_version}) looks OLDER than" \
                 " v26.05, while SPDK_INITIATOR_FLAVOR=upstream is in play" \
                 " for SMC1/SMC2. This target tree is unrelated to what the" \
                 " initiators build for themselves, but the NVMe-KV" \
                 " initiator API (spdk_nvme_kv_store() etc.) only landed" \
                 " upstream in v26.05 — anything older than that is missing" \
                 " it, so double-check ${SPDK_UPSTREAM_REPO}@${SPDK_VERSION}" \
                 " is what SMC1/SMC2 actually end up building."
            ;;
    esac
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
step "Summary"
ok "SPDK (${SPDK_TARGET_FLAVOR}) built at ${SPDK_TARGET_SRC}"
if [ "${SPDK_INITIATOR_FLAVOR}" = "fork" ]; then
    log "SPDK_INITIATOR_FLAVOR=fork: SMC1 (prefill) and SMC2 (decode) need"
    log "this SAME tree at plugin build time"
    log "(scripts/common/05-build-spdk-initiator.sh). Pull it there with:"
    log ""
    log "  rsync -az ${SSH_USER}@${TARGET_HOST}:${SPDK_TARGET_SRC}/ ${SPDK_SRC}/"
    log ""
    log "(run FROM smc1/smc2, against this host — matching path on both ends"
    log " because meson.build's -Dspdk_path is baked into that build's command"
    log " line, not portable to a different path without re-running meson)"
else
    log "SPDK_INITIATOR_FLAVOR=upstream (the default): SMC1 (prefill) and"
    log "SMC2 (decode) build their OWN stock SPDK ${SPDK_VERSION} tree via"
    log "scripts/common/05-build-spdk-initiator.sh and do NOT need this tree"
    log "at all — the NVMe-KV initiator API is upstream as of v26.05 (F1)."
    log "The rsync hint above only applies if an operator deliberately sets"
    log "SPDK_INITIATOR_FLAVOR=fork."
fi
log "next: scripts/target/03-start-kv-target.sh"
