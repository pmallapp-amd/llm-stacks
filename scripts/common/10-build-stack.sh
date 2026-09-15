#!/usr/bin/env bash
# 10-build-stack.sh — build UCX + NIXL + both NIXL plugins into ${STACK_ROOT}.
#
# Node:          SMC1 (prefill), SMC2 (decode); optionally SMC3 (target, for
#                plugin testing only — the target doesn't run vLLM/LMCache).
# Prerequisites: scripts/common/00-preflight.sh has been run and is green (or
#                its warnings understood); root; outbound network access to
#                github.com and the distro apt mirror.
# Next step:     scripts/common/20-build-vllm-lmcache.sh
#
# Every step below is individually skippable (--skip-*) and idempotent: it
# detects a prior successful install/build and skips with a message rather
# than redoing work or erroring on "already exists".
#
# Usage:
#   10-build-stack.sh [--skip-ucx] [--skip-nixl] [--skip-plugins] [--skip-apt]
#                      [--jobs N]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root

SKIP_APT=0
SKIP_UCX=0
SKIP_NIXL=0
SKIP_PLUGINS=0
JOBS="$(nproc)"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-apt)     SKIP_APT=1 ;;
        --skip-ucx)     SKIP_UCX=1 ;;
        --skip-nixl)    SKIP_NIXL=1 ;;
        --skip-plugins) SKIP_PLUGINS=1 ;;
        --jobs)         JOBS="$2"; shift ;;
        --jobs=*)       JOBS="${1#--jobs=}" ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

banner_config
info "STACK_ROOT=${STACK_ROOT}  jobs=${JOBS}"
mkdir -p "${STACK_ROOT}" "${STACK_ROOT}/src"

# ─────────────────────────────────────────────────────────────────────────────
# 1. apt dependencies
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_APT}" -eq 1 ]; then
    info "step 1/6: apt deps — skipped (--skip-apt)"
else
    step "1/6: apt dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        build-essential git cmake meson ninja-build pkg-config \
        python3-dev python3-venv python3-pip \
        libnuma-dev uuid-dev libssl-dev libaio-dev liburing-dev \
        autoconf automake libtool nasm \
        rdma-core libibverbs-dev librdmacm-dev ibverbs-providers \
        nvme-cli ethtool
    ok "apt deps installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. UCX (ROCm fork)
# ─────────────────────────────────────────────────────────────────────────────
# WHY the ROCm/ucx fork and not stock openucx/ucx: stock UCX's memory-type
# detection (used to decide whether a buffer needs a HIP-aware copy path)
# does not recognize ROCm/HIP pointers — it was written for CUDA's
# cudaPointerGetAttributes()-style API. The ROCm fork patches UCX's memory
# type detection (uct/rocm*, ucs/memory) to call hipPointerGetAttributes()
# instead. Without this, any UCX transfer that touches a HIP-allocated
# pointer (which is every VRAM_SEG transfer NIXL hands UCX) misclassifies
# the buffer as host memory, and either silently copies through host RAM
# (killing throughput) or segfaults dereferencing a device pointer from the
# host. This is not a performance nice-to-have, it is a correctness fork.
#
# WHY --with-verbs is built even though KV_TRANSPORT defaults to "tcp": the
# whole point of KV_TRANSPORT as a phase gate (see cluster.env) is that
# flipping tcp->rdma is a config change, not a rebuild. If verbs support
# isn't compiled in now, Phase 2 acceptance testing would require rebuilding
# UCX on both compute nodes at exactly the moment the schedule has no slack
# for a rebuild-and-retest cycle. --with-verbs costs nothing when unused
# (UCX_TLS at runtime, set by setup_ucx_env in lib.sh, decides which
# transports are actually instantiated).
if [ "${SKIP_UCX}" -eq 1 ]; then
    info "step 2/6: UCX — skipped (--skip-ucx)"
elif [ -e "${UCX_PREFIX}/lib/libucp.so" ]; then
    ok "step 2/6: UCX already installed at ${UCX_PREFIX} — skip (rm -rf to force rebuild)"
else
    step "2/6: UCX (ROCm/ucx @ ${UCX_BRANCH}) -> ${UCX_PREFIX}"
    require_cmd git autoreconf
    if [ ! -d "${UCX_SRC}/.git" ]; then
        git clone --branch "${UCX_BRANCH}" --depth 1 \
            https://github.com/ROCm/ucx.git "${UCX_SRC}"
    else
        info "UCX_SRC already cloned, reusing: ${UCX_SRC}"
    fi
    (
        cd "${UCX_SRC}"
        ./autogen.sh
        ./configure \
            --prefix="${UCX_PREFIX}" \
            --with-rocm="${ROCM_PATH}" \
            --with-verbs \
            --with-dm \
            --with-rdmacm \
            --enable-mt \
            --disable-debug \
            --disable-assertions \
            --disable-params-check
        make -j "${JOBS}"
        make install
    )
    ok "UCX installed at ${UCX_PREFIX}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. NIXL
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_NIXL}" -eq 1 ]; then
    info "step 3/6: NIXL — skipped (--skip-nixl)"
elif [ -e "${NIXL_PREFIX}/lib/x86_64-linux-gnu/libnixl.so" ]; then
    ok "step 3/6: NIXL already installed at ${NIXL_PREFIX} — skip (rm -rf to force rebuild)"
else
    step "3/6: NIXL ${NIXL_VERSION} -> ${NIXL_PREFIX}"
    require_cmd git meson ninja
    if [ ! -d "${NIXL_SRC}/.git" ]; then
        git clone --branch "${NIXL_VERSION}" --depth 1 \
            https://github.com/ai-dynamo/nixl "${NIXL_SRC}"
    else
        info "NIXL_SRC already cloned, reusing: ${NIXL_SRC}"
    fi
    (
        cd "${NIXL_SRC}"
        meson setup build \
            -Ducx_path="${UCX_PREFIX}" \
            -Ddisable_gds_backend=true \
            -Dbuild_tests=false \
            -Dbuild_examples=false \
            --prefix="${NIXL_PREFIX}" \
            --buildtype=release
        ninja -C build -j "${JOBS}"
        ninja -C build install
    )
    # Both plugins' meson.build files link against these exact paths
    # (see plugins/nvme-kv/meson.build's nixl_dep / nixl_lib_dir). If either
    # is missing, every downstream plugin build fails with a confusing
    # "file not found" deep in the linker step instead of here, at the
    # actual root cause.
    require_file "${NIXL_PREFIX}/lib/x86_64-linux-gnu/libnixl.so"
    require_file "${NIXL_PREFIX}/include/backend/backend_engine.h"
    ok "NIXL installed at ${NIXL_PREFIX} (libnixl.so + backend_engine.h verified)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. plugins/nvme-kv (SPDK_NVMe_KV)
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_PLUGINS}" -eq 1 ]; then
    info "step 4/6: plugins/nvme-kv — skipped (--skip-plugins)"
elif [ -e "${NIXL_PLUGIN_DIR}/libplugin_SPDK_NVMe_KV.so" ]; then
    ok "step 4/6: SPDK_NVMe_KV plugin already installed — skip (rm to force rebuild)"
else
    step "4/6: plugins/nvme-kv (SPDK_NVMe_KV) -> ${NIXL_PLUGIN_DIR}"

    # As of SPDK v26.05 this repo no longer builds/clones a fallback SPDK
    # tree inline here — scripts/common/05-build-spdk-initiator.sh owns
    # that (both flavors: SPDK_INITIATOR_FLAVOR=upstream clones+builds its
    # own tree at ${SPDK_SRC}; =fork expects a tree already rsynced in from
    # SMC3). This step just requires that to have already happened.
    if [ ! -f "${SPDK_SRC}/build/lib/libspdk_nvme.a" ]; then
        die "SPDK_SRC (${SPDK_SRC}) has no build/lib/libspdk_nvme.a — the" \
            " nvme-kv plugin links statically against SPDK static archives" \
            " (see plugins/nvme-kv/meson.build) that this step no longer" \
            " builds itself. Run first:" \
            $'\n''        scripts/common/05-build-spdk-initiator.sh'\
            $'\n''    (SPDK_INITIATOR_FLAVOR=upstream, the default, clones'\
            $'\n''    and builds a self-contained tree here; =fork instead'\
            $'\n''    expects a tree already rsynced in from SMC3 — see that'\
            $'\n''    script'\''s own comments for the exact command).'
    else
        info "SPDK_SRC found at ${SPDK_SRC}, reusing prebuilt tree" \
             " (built by scripts/common/05-build-spdk-initiator.sh)"
    fi

    # The "_only" split archives (libspdk_nvme_tcp_only.a etc.) are a hard
    # link-time requirement of meson.build's --whole-archive grouping; a
    # stock SPDK build layout does not produce them. Safe to re-run: each
    # make_split() inside prepare-spdk-libs.sh skips an archive that's
    # already present.
    SPDK_SRC="${SPDK_SRC}" "${REPO_ROOT}/plugins/nvme-kv/prepare-spdk-libs.sh"

    ENABLE_VRAM=true
    [ -d "${ROCM_PATH}" ] || ENABLE_VRAM=false
    ENABLE_VRAM="${NVME_KV_ENABLE_VRAM:-${ENABLE_VRAM}}"
    info "enable_vram=${ENABLE_VRAM} (ROCm present: $([ -d "${ROCM_PATH}" ] && echo yes || echo no))"

    (
        cd "${REPO_ROOT}/plugins/nvme-kv"
        rm -rf build-nvme-kv
        meson setup build-nvme-kv \
            -Dnixl_path="${NIXL_PREFIX}" \
            -Dspdk_path="${SPDK_SRC}" \
            -Drocm_path="${ROCM_PATH}" \
            -Denable_vram="${ENABLE_VRAM}" \
            --prefix="${NIXL_PREFIX}"
        ninja -C build-nvme-kv -j "${JOBS}"
        ninja -C build-nvme-kv install
    )

    _plugin_so="${NIXL_PLUGIN_DIR}/libplugin_SPDK_NVMe_KV.so"
    require_file "${_plugin_so}"

    # ── Post-build verification: NOT optional. ──────────────────────────
    # See plugins/nvme-kv/meson.build's own comment on this exact failure
    # mode: if a bare -lrte_eal resolved to librte_eal.so.26 instead of the
    # intended librte_eal.a (both live in the same -L dir; ld/meson link-arg
    # ordering is not a reliable fence), the built .so carries a DT_NEEDED on
    # librte_eal.so.26 and every other shared SPDK/DPDK lib it pulled in.
    # NIXL loads plugins via dlopen(); a missing DT_NEEDED dependency makes
    # dlopen() fail, and NIXL's plugin manager reports that as a generic
    # "unsupported backend" with ZERO indication that a shared-lib dependency
    # was the actual cause — the failure surfaces two layers away from here,
    # in LMCache, minutes into a vLLM startup, looking nothing like a link
    # problem. Catching it here, immediately after the build that caused it,
    # is the only place the diagnosis is cheap.
    info "verifying ${_plugin_so} has no stray librte_*/libspdk_* DT_NEEDED entries"
    _ldd_out="$(ldd "${_plugin_so}" 2>&1 || true)"
    if echo "${_ldd_out}" | grep -Eq 'librte_[a-z_]+\.so|libspdk_[a-z_]+\.so'; then
        err "ldd shows a shared librte_*/libspdk_* dependency — this plugin"
        err "embeds SPDK/DPDK statically and must NOT show these:"
        echo "${_ldd_out}" >&2
        die "SPDK/DPDK link-time isolation broken; see meson.build's" \
            " --whole-archive comment. Check for a stray librteX.so next to" \
            " librteX.a in ${SPDK_SRC}/dpdk/build/lib and rebuild."
    fi
    if echo "${_ldd_out}" | grep -qi 'not found'; then
        err "ldd reports missing shared libraries:"
        echo "${_ldd_out}" >&2
        die "unresolved shared-library dependency in ${_plugin_so}"
    fi
    ok "SPDK_NVMe_KV plugin clean: no librte_*/libspdk_* DT_NEEDED, no unresolved libs"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. plugins/xnvme-kv (optional — local DSC-attached KV devices)
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_PLUGINS}" -eq 1 ]; then
    info "step 5/6: plugins/xnvme-kv — skipped (--skip-plugins)"
elif [ -e "${NIXL_PLUGIN_DIR}/libplugin_XNVME_KV.so" ]; then
    ok "step 5/6: XNVME_KV plugin already installed — skip (rm to force rebuild)"
else
    step "5/6: plugins/xnvme-kv (optional)"
    XNVME_INCDIR="${XNVME_INCDIR:-}"
    XNVME_LIBDIR="${XNVME_LIBDIR:-}"
    if [ -z "${XNVME_INCDIR}" ] && command -v pkg-config >/dev/null 2>&1 \
        && pkg-config --exists xnvme 2>/dev/null; then
        XNVME_INCDIR="$(pkg-config --variable=includedir xnvme)"
        XNVME_LIBDIR="$(pkg-config --variable=libdir xnvme)"
    fi
    if [ -z "${XNVME_INCDIR}" ]; then
        for d in /usr/local/include /usr/include; do
            [ -f "${d}/libxnvme.h" ] && XNVME_INCDIR="${d}" && break
        done
    fi
    if [ -z "${XNVME_LIBDIR}" ]; then
        for d in /usr/local/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /usr/local/lib; do
            [ -e "${d}/libxnvme.so" ] && XNVME_LIBDIR="${d}" && break
        done
    fi

    if [ -z "${XNVME_INCDIR}" ] || [ -z "${XNVME_LIBDIR}" ]; then
        info "libxnvme headers/lib not found — skipping xnvme-kv plugin" \
             " (only needed for local DSC-attached KV devices, not this" \
             " cluster's remote-NVMe-oF topology). Set XNVME_INCDIR /" \
             " XNVME_LIBDIR to force-enable."
    else
        info "libxnvme found: incdir=${XNVME_INCDIR} libdir=${XNVME_LIBDIR}"
        ENABLE_VRAM=true
        [ -d "${ROCM_PATH}" ] || ENABLE_VRAM=false
        ENABLE_VRAM="${XNVME_KV_ENABLE_VRAM:-${ENABLE_VRAM}}"
        (
            cd "${REPO_ROOT}/plugins/xnvme-kv"
            rm -rf build-xnvme-kv
            meson setup build-xnvme-kv \
                -Dnixl_path="${NIXL_PREFIX}" \
                -Dxnvme_incdir="${XNVME_INCDIR}" \
                -Dxnvme_libdir="${XNVME_LIBDIR}" \
                -Drocm_path="${ROCM_PATH}" \
                -Denable_vram="${ENABLE_VRAM}" \
                --prefix="${NIXL_PREFIX}"
            ninja -C build-xnvme-kv -j "${JOBS}"
            ninja -C build-xnvme-kv install
        )
        _xnvme_plugin_so="${NIXL_PLUGIN_DIR}/libplugin_XNVME_KV.so"
        require_file "${_xnvme_plugin_so}"

        # ── Post-build verification: NOT optional, but a DIFFERENT check
        #    than SPDK_NVMe_KV's above. That check asserts ABSENCE of
        #    librte_*/libspdk_* DT_NEEDED entries, because this plugin's
        #    static archives must never leak a shared-lib dependency at all.
        #    XNVME_KV is not built that way: it legitimately links libxnvme.so
        #    DYNAMICALLY (see plugins/xnvme-kv/meson.build) — a DT_NEEDED on
        #    libxnvme.so here is CORRECT and expected, so asserting its
        #    absence would be asserting this plugin is broken. What DOES
        #    carry over from the SPDK check, unchanged, is the underlying
        #    failure mode it exists to catch: NIXL loads plugins via
        #    dlopen(), an UNRESOLVABLE DT_NEEDED (libxnvme.so not on any
        #    loader path in the deployed image, e.g. built against a
        #    dev-host libxnvme that never got shipped) makes dlopen() fail,
        #    and NIXL's plugin manager reports that as a bare "unsupported
        #    backend" with nothing pointing at libxnvme specifically. So this
        #    check asserts every DT_NEEDED entry RESOLVES (no "not found" in
        #    ldd's output) — same failure caught, opposite assertion, because
        #    "must not depend on X" and "must be able to find X" are
        #    different properties and this plugin only needs the second one.
        info "verifying ${_xnvme_plugin_so} has no unresolved DT_NEEDED entries"
        _xnvme_ldd_out="$(ldd "${_xnvme_plugin_so}" 2>&1 || true)"
        if echo "${_xnvme_ldd_out}" | grep -qi 'not found'; then
            err "ldd reports missing shared libraries:"
            echo "${_xnvme_ldd_out}" >&2
            die "unresolved shared-library dependency in ${_xnvme_plugin_so}" \
                " — most likely libxnvme.so is not on this host's loader" \
                " path (ldconfig / LD_LIBRARY_PATH). A DT_NEEDED on" \
                " libxnvme.so itself is expected here and is NOT the" \
                " problem; only an unresolved one is."
        fi
        ok "XNVME_KV plugin installed (libxnvme.so DT_NEEDED resolves)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Summary
# ─────────────────────────────────────────────────────────────────────────────
step "6/6: installed plugins in ${NIXL_PLUGIN_DIR}"
if [ -d "${NIXL_PLUGIN_DIR}" ]; then
    ls -la "${NIXL_PLUGIN_DIR}" >&2
else
    warn "${NIXL_PLUGIN_DIR} does not exist (no plugins built yet)"
fi

ok "10-build-stack.sh complete"
log "next: scripts/common/20-build-vllm-lmcache.sh"
