#!/usr/bin/env bash
# 05-build-spdk-initiator.sh — clone (if needed) and build the INITIATOR-side
# SPDK tree on SMC1/SMC2.
#
# Node:          SMC1 (prefill) or SMC2 (decode). Runs on either — this
#                script does not require_host, same as 10-build-stack.sh
#                (both compute nodes need this identically).
# Prerequisites: scripts/common/00-preflight.sh green; root; outbound
#                network access to github.com and the distro apt mirror
#                (unless SPDK_INITIATOR_FLAVOR=fork, in which case the tree
#                must already be rsynced in from SMC3 — see below).
# Next step:     scripts/common/10-build-stack.sh, which now REQUIRES this
#                to have already run (step 4/6, the plugin build, needs
#                ${SPDK_SRC}/build/lib/libspdk_nvme.a to exist).
#
# WHY THIS SCRIPT IS NEW: before SPDK v26.05, the initiator (this script)
# and the target (scripts/target/02-build-spdk-kv.sh) had to share the SAME
# kv_spdk fork tree, because that was the only tree with
# include/spdk/nvme_kv.h at all. As of v26.05, NVIDIA's NVMe-KV INITIATOR
# API (spdk_nvme_kv_store/retrieve/delete/exist/list()) is upstream — see
# config/cluster.env's SPDK section — so the initiator no longer needs the
# fork, and building it here means SMC1/SMC2 do not depend on an rsync from
# SMC3 at all in the (now-default) common case.
#
# SPDK_INITIATOR_FLAVOR selects where ${SPDK_SRC} comes from:
#   upstream  (default) clone ${SPDK_UPSTREAM_REPO} @ ${SPDK_VERSION} here
#             directly. Self-contained; no dependency on SMC3.
#   fork      expects ${SPDK_SRC} to already be populated — rsynced down
#             from SMC3's ${SPDK_TARGET_SRC} by an operator who deliberately
#             wants the initiator built from the exact same tree as the
#             target (e.g. to rule out a version-skew hypothesis). This
#             script does NOT clone anything in that mode; it only verifies
#             what's already there and builds it.
#
# usage: 05-build-spdk-initiator.sh [--jobs N] [--force-clone] [--skip-apt]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root

JOBS="$(nproc)"
FORCE_CLONE=0
SKIP_APT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)         JOBS="$2"; shift ;;
        --jobs=*)       JOBS="${1#--jobs=}" ;;
        --force-clone)  FORCE_CLONE=1 ;;
        --skip-apt)     SKIP_APT=1 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

case "${SPDK_INITIATOR_FLAVOR}" in
    upstream|fork) ;;
    *) die "SPDK_INITIATOR_FLAVOR must be upstream|fork, got '${SPDK_INITIATOR_FLAVOR}'" ;;
esac

step "Build SPDK (initiator): ${SPDK_SRC} (flavor=${SPDK_INITIATOR_FLAVOR} jobs=${JOBS})"
banner_config

# ─────────────────────────────────────────────────────────────────────────────
# 1. apt dependencies. Same SPDK build deps as scripts/target/01-host-prep.sh
#    installs on SMC3, since this script configures/builds the same upstream
#    tree the same way. librdmacm-dev/libibverbs-dev are installed
#    unconditionally — this tree no longer configures --with-rdma itself
#    (see step 3 below: the storage leg, NVMe-oF to SMC3, is TCP only by
#    design), but 10-build-stack.sh needs them regardless for UCX's
#    --with-verbs (the compute-leg RDMA path, KV_TRANSPORT=rdma).
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_APT}" -eq 1 ]; then
    info "apt deps — skipped (--skip-apt)"
else
    step "apt dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        build-essential git meson ninja-build python3-pyelftools python3-pip \
        pkg-config libnuma-dev uuid-dev libssl-dev libaio-dev liburing-dev \
        nasm autoconf automake libtool help2man binutils \
        rdma-core libibverbs-dev librdmacm-dev
    ok "apt deps installed"
fi

require_cmd git make gcc meson ninja nm

# ─────────────────────────────────────────────────────────────────────────────
# 2. Obtain the tree.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SPDK_INITIATOR_FLAVOR}" = "fork" ]; then
    # This script does not clone in fork mode: the whole point of choosing
    # fork here is that the operator wants the EXACT tree SMC3 built, not a
    # fresh independent clone that could drift from it (different pinned
    # submodule commit, different local patches, etc). See
    # scripts/target/02-build-spdk-kv.sh's summary step for the rsync
    # command it prints when SPDK_INITIATOR_FLAVOR=fork.
    [ -f "${SPDK_SRC}/include/spdk/nvme_kv.h" ] \
        || die "SPDK_INITIATOR_FLAVOR=fork but ${SPDK_SRC} has no" \
               " include/spdk/nvme_kv.h — nothing to build. This mode" \
               " expects the tree to already be rsynced in from SMC3:" \
               $'\n'"    rsync -az ${SSH_USER}@${TARGET_HOST}:${SPDK_TARGET_SRC}/ ${SPDK_SRC}/" \
               $'\n''    (run FROM this host, against SMC3 — matching path'\
               $'\n''    because meson.build bakes -Dspdk_path in at build'\
               $'\n''    time). Or switch to the default:'\
               $'\n''        SPDK_INITIATOR_FLAVOR=upstream'\
               $'\n''    which clones and builds a self-contained tree here.'
    ok "fork tree present at ${SPDK_SRC} (rsynced) — building in place"
else
    if [ -f "${SPDK_SRC}/include/spdk/nvme_kv.h" ] && [ "${FORCE_CLONE}" -eq 0 ]; then
        ok "upstream tree already present at ${SPDK_SRC} —" \
           " skipping clone (--force-clone to override)"
    else
        if [ "${FORCE_CLONE}" -eq 1 ] && [ -d "${SPDK_SRC}" ]; then
            warn "--force-clone: removing existing ${SPDK_SRC}"
            rm -rf "${SPDK_SRC}"
        fi
        step "Cloning ${SPDK_UPSTREAM_REPO} @ ${SPDK_VERSION}"
        mkdir -p "$(dirname "${SPDK_SRC}")"
        git clone --branch "${SPDK_VERSION}" --depth 1 \
            "${SPDK_UPSTREAM_REPO}" "${SPDK_SRC}"
    fi
fi

if [ -d "${SPDK_SRC}/.git" ]; then
    step "git submodule update"
    ( cd "${SPDK_SRC}" && git submodule update --init --recursive )
    ok "submodules present (dpdk, isa-l, etc.)"
else
    info "${SPDK_SRC} is not a git checkout (fork tree rsynced as plain" \
         " files) — assuming submodules were already initialized by" \
         " whoever built it on SMC3; skipping git submodule update."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Configure + build.
# ─────────────────────────────────────────────────────────────────────────────
# --with-nvmf is target-side functionality (the nvmf_tgt RPC surface and
# transport listener code) that this initiator role has no use for. It is
# left as an OPT-IN flag (default off) purely to keep this tree comparable
# to the target's if an operator wants to diff configure summaries or debug
# a version-skew question — building it costs a little compile time and
# nothing at runtime, since nothing here ever calls into it.
SPDK_INITIATOR_WITH_NVMF="${SPDK_INITIATOR_WITH_NVMF:-0}"
_configure_args=(--without-shared --with-uring
    --disable-tests --disable-unit-tests --disable-examples)
[ "${SPDK_INITIATOR_WITH_NVMF}" = "1" ] && _configure_args+=(--with-nvmf)
# No --with-rdma here: the storage leg (NVMe-oF, this SPDK tree's only use
# on SMC1/SMC2) is TCP only by design — see config/cluster.env's "NVMe-oF
# target" section. An earlier version of this script configured
# --with-rdma unconditionally under SPDK_WITH_RDMA=1 to keep a Phase-2
# relink option open; that variable and this branch have been removed
# along with the rest of the storage-leg RDMA scaffolding
# (plugins/nvme-kv/meson.build's -Denable_rdma, prepare-spdk-libs.sh's
# libspdk_nvme_rdma_only.a split) since rocm-aic/target.sh, the PROVEN
# configuration this repo now follows, never exercises NVMe-oF/RDMA. The
# compute-leg RDMA path (KV_TRANSPORT=rdma, UCX over RoCE) is unrelated and
# untouched — it does not depend on this SPDK tree's configure flags at all.
step "./configure ${_configure_args[*]} ..."
# WHY --without-shared matters: see plugins/nvme-kv/meson.build's own
# comment (also duplicated in scripts/target/02-build-spdk-kv.sh) — a
# shared-libs-enabled SPDK/DPDK build can leave a bare -lrte_eal free to
# resolve to a .so instead of the intended .a at plugin link time, which
# breaks the "no SPDK/DPDK runtime component ships" contract silently.
(
    cd "${SPDK_SRC}"
    ./configure "${_configure_args[@]}"
    make -j "${JOBS}"
)
ok "SPDK (initiator, ${SPDK_INITIATOR_FLAVOR}) build finished"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Verify the KV API is ACTUALLY present. This is the whole point of
#    moving the initiator to v26.05: a tree that predates the NVMe-KV
#    patches landing upstream will configure and build cleanly and only
#    fail here, at the plugin's compile/link step, deep into
#    10-build-stack.sh — catching it here instead, right after the build
#    that would produce it, is the only place the diagnosis is cheap.
# ─────────────────────────────────────────────────────────────────────────────
step "Verifying NVMe-KV initiator API is present"
_kv_missing=()
[ -f "${SPDK_SRC}/include/spdk/nvme_kv.h" ] \
    || _kv_missing+=("include/spdk/nvme_kv.h")

require_file "${SPDK_SRC}/build/lib/libspdk_nvme.a"
for _sym in spdk_nvme_kv_store spdk_nvme_kv_retrieve spdk_nvme_kv_exist; do
    nm -g "${SPDK_SRC}/build/lib/libspdk_nvme.a" 2>/dev/null | grep -q " ${_sym}$" \
        || _kv_missing+=("symbol:${_sym} (nm -g libspdk_nvme.a)")
done

# The exact enum member name for the KV_KEY_DOES_NOT_EXIST status code is
# asserted from the research brief, not vendored/verified in this repo —
# grep for the substring rather than an exact enum line, so a harmless
# formatting difference upstream doesn't cause a false negative here.
grep -q 'KEY_DOES_NOT_EXIST' "${SPDK_SRC}/include/spdk/nvme_spec.h" 2>/dev/null \
    || _kv_missing+=("enum member matching KEY_DOES_NOT_EXIST (include/spdk/nvme_spec.h)")

if [ ${#_kv_missing[@]} -gt 0 ]; then
    _found_version="unknown"
    [ -f "${SPDK_SRC}/VERSION" ] && _found_version="$(cat "${SPDK_SRC}/VERSION")"
    err "NVMe-KV initiator API surface is INCOMPLETE in ${SPDK_SRC}:"
    for m in "${_kv_missing[@]}"; do err "  - missing: ${m}"; done
    die "this tree (version found: ${_found_version}) either predates" \
        " SPDK v26.05 or predates the NVMe-KV patches being upstreamed" \
        " into it — the initiator API" \
        " (spdk_nvme_kv_store/retrieve/delete/exist/list()) is only present" \
        " from v26.05 onward. Set SPDK_VERSION=v26.05 (or later) and" \
        " re-run with --force-clone, or if SPDK_INITIATOR_FLAVOR=fork," \
        " check that the rsynced tree is what it's expected to be."
fi
ok "NVMe-KV initiator API present: nvme_kv.h + spdk_nvme_kv_{store,retrieve,exist}() + KEY_DOES_NOT_EXIST status"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Generate the "_only" split archives the plugin's meson.build links
#    with --whole-archive: tcp, pcie and sock_posix. These isolate the
#    transport self-registration constructors so they survive a static link
#    that would otherwise drop them as unreferenced.
#    There is no rdma split: the storage leg is NVMe-oF/TCP by design.
# ─────────────────────────────────────────────────────────────────────────────
step "Generating split archives (prepare-spdk-libs.sh)"
SPDK_SRC="${SPDK_SRC}" "${REPO_ROOT}/plugins/nvme-kv/prepare-spdk-libs.sh"
ok "split archives ready in ${SPDK_SRC}/build/lib"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
step "Summary"
ok "SPDK (initiator, ${SPDK_INITIATOR_FLAVOR}) built at ${SPDK_SRC}"
log "SPDK_INITIATOR_WITH_NVMF=${SPDK_INITIATOR_WITH_NVMF}"
log "next: scripts/common/10-build-stack.sh (plugin build, step 4/6, now"
log "expects this tree to already exist rather than building it itself)"
