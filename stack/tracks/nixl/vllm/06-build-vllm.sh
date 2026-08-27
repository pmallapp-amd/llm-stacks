#!/usr/bin/env bash
# 06-build-vllm.sh — build vllm-nixl:rocm inference image (Ubuntu 24.04 stack).
#
# Layers upstream NIXL on top of a 24.04-based vLLM ROCm image, matching
# nixl:n0's Ubuntu 24.04 / Python 3.14 build (see ../core/01-build-base.sh) —
# both sides must share glibc/GLIBCXX/Python ABI, since nixl_cu12 bindings and
# plugin .so files get extracted from nixl:n0 straight into this image with no
# recompilation. Mixing a 22.04 vLLM base with a 24.04 nixl:n0 was this repo's
# single biggest source of "works sometimes" bugs (GLIBCXX_3.4.32/GLIBC_2.38
# not found) — this is the one stack now, no 22.04 variant.
#
# Output: vllm-nixl:rocm
# Also extracts nixl libs from nixl:n0 to a named volume for runtime mounting.
#
# ── What lands in the nixl-libs volume, and why it matters ────────────────────
# The volume is the ONLY channel by which anything built in nixl:n0 reaches the
# running vLLM container. Until 2026-08-14 it carried /usr/local/nixl and a set
# of system libs — but NOT UCX, and NOT the AMD_ROCM plugin. Consequences,
# both verified on <SETUP3_PREFILL_NODE> with the stack live:
#
#   * libplugin_UCX.so resolved libucp.so.0 to /lib/x86_64-linux-gnu/libucp.so.0
#     — Ubuntu's apt UCX 1.16 that happens to be in the vLLM base image — not
#     the UCX this repo carefully builds from source in nixl:base. So every
#     property of that build (version, --with-verbs, and now --with-rocm) was
#     simply absent at runtime. Building UCX --with-rocm without also shipping
#     it would have been another no-op change.
#   * libplugin_AMD_ROCM.so was never copied anywhere, so NIXL could not load
#     the AMD_ROCM backend even though rocm-plugin/build.sh had built it.
#
# Both are fixed below, and both are verified against the real image at the end
# of this script rather than assumed.
#
#   VLLM_BASE=rocm/vllm:rocm7.14.0_cdna_ubuntu24.04_py3.14_pytorch_2.11.0_vllm_0.23.0  (default)
#   NIXL_N0_IMAGE=nixl:n0   source for nixl_cu12/plugin extraction (default)
#   PYTHON_VERSION=3.14     must match NIXL_N0_IMAGE's Python (default)
#   ROCM_PLUGIN_DIR=<path>  where rocm-plugin/build.sh installed
#                           libplugin_AMD_ROCM.so (default: ../core/rocm-plugin/
#                           install/lib/x86_64-linux-gnu/plugins)
#   REQUIRE_ROCM_PLUGIN=0|1 1 = fail if that .so is missing (default: 1). Set 0
#                           only for a deliberate CPU-only build.
#   REQUIRE_UCX_ROCM=0|1    1 = fail if NIXL_N0_IMAGE's UCX lacks ROCm support
#                           (default: 1).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VLLM_BASE=${VLLM_BASE:-rocm/vllm:rocm7.14.0_cdna_ubuntu24.04_py3.14_pytorch_2.11.0_vllm_0.23.0}
NIXL_N0_IMAGE=${NIXL_N0_IMAGE:-nixl:n0}
PYTHON_VERSION=${PYTHON_VERSION:-3.14}
ROCM_PLUGIN_DIR=${ROCM_PLUGIN_DIR:-${SCRIPT_DIR}/../core/rocm-plugin/install/lib/x86_64-linux-gnu/plugins}
REQUIRE_ROCM_PLUGIN=${REQUIRE_ROCM_PLUGIN:-1}
REQUIRE_UCX_ROCM=${REQUIRE_UCX_ROCM:-1}

echo "06-build-vllm: vllm-nixl:rocm"
echo "  base       : ${VLLM_BASE}"
echo "  nixl:n0    : ${NIXL_N0_IMAGE}"
echo "  python     : ${PYTHON_VERSION}"
echo "  rocm plugin: ${ROCM_PLUGIN_DIR}"
echo "  nixl libs  : extracted from ${NIXL_N0_IMAGE} → volume nixl-libs"

# ── Preflight: refuse to build a stack that silently cannot use the GPU ───────
if [ "${REQUIRE_UCX_ROCM}" = "1" ]; then
    echo ""
    echo "=== Checking ${NIXL_N0_IMAGE}'s UCX for ROCm support ==="
    docker run --rm "${NIXL_N0_IMAGE}" bash -lc '
        ucx_info -b | grep -q -- "--with-rocm=" &&
        ucx_info -b | grep -E "^#define uct_MODULES" | grep -q rocm' || {
        echo "ERR: ${NIXL_N0_IMAGE}'s UCX was NOT built with ROCm."
        echo "     NIXL's UCX plugin takes its GPU-memory registration from UCX, so this"
        echo "     stack would be limited to kv_buffer_device=cpu and every KV transfer"
        echo "     would stage through host DRAM."
        echo "     Rebuild: bash ../core/01-build-base.sh && bash ../core/02-compile-bench.sh"
        echo "     Or set REQUIRE_UCX_ROCM=0 to build the DRAM-staged stack deliberately."
        exit 1; }
    echo "OK: ${NIXL_N0_IMAGE} UCX has ROCm support"
fi

ROCM_PLUGIN_SO="${ROCM_PLUGIN_DIR}/libplugin_AMD_ROCM.so"
if [ "${REQUIRE_ROCM_PLUGIN}" = "1" ] && [ ! -f "${ROCM_PLUGIN_SO}" ]; then
    echo "ERR: ${ROCM_PLUGIN_SO} not found."
    echo "     Build it first:  bash ../core/rocm-plugin/build.sh"
    echo "     Or set REQUIRE_ROCM_PLUGIN=0 to ship a volume without the AMD_ROCM backend."
    exit 1
fi

# Build the vllm-nixl image
docker build \
    --build-arg VLLM_BASE="${VLLM_BASE}" \
    --build-arg NIXL_N0_IMAGE="${NIXL_N0_IMAGE}" \
    --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
    -t vllm-nixl:rocm \
    -f "${SCRIPT_DIR}/Dockerfile.vllm-rocm" \
    "${SCRIPT_DIR}"

echo "OK: vllm-nixl:rocm built"

# Create a named volume with the nixl shared libs so 05-llm.sh/deploy scripts
# can mount it. NIXL_N0_IMAGE has /usr/local/nixl with libnixl.so and plugins.
# Also copies system libs (abseil 20240722 from source, plus Ubuntu 24.04's
# apt-versioned grpc/protobuf/gpr/c-ares/liburing/libaio closure) that
# VLLM_BASE's Ubuntu 24.04 doesn't ship by default — sonames determined
# empirically via ldd against vllm-nixl:rocm itself, not guessed (apt versions
# differ by OS release — don't reuse an older/newer OS's soname list).
echo ""
echo "Extracting nixl libs from ${NIXL_N0_IMAGE} -> volume nixl-libs ..."
docker volume create nixl-libs 2>/dev/null || true
ROCM_PLUGIN_MOUNT=()
[ -f "${ROCM_PLUGIN_SO}" ] && ROCM_PLUGIN_MOUNT=(-v "${ROCM_PLUGIN_DIR}":/in/rocm-plugin:ro)
docker run --rm \
    -v nixl-libs:/out \
    "${ROCM_PLUGIN_MOUNT[@]+"${ROCM_PLUGIN_MOUNT[@]}"}" \
    "${NIXL_N0_IMAGE}" \
    bash -c "
        set -euo pipefail
        rm -rf /out/lib /out/bin 2>/dev/null || true
        cp -a /usr/local/nixl/. /out/

        # ── UCX (built from source in nixl:base, --with-rocm) ────────────────
        # Goes into the SAME directory as libnixl, deliberately: that directory
        # is both \$ORIGIN/.. on libplugin_UCX.so's install_rpath and the first
        # entry of the deploy scripts' LD_LIBRARY_PATH, so the plugin picks up
        # this UCX by two independent mechanisms and cannot silently fall back
        # to the vLLM image's apt UCX 1.16 (which has no rocm module at all).
        # UCX locates its own transport modules relative to libucs.so's
        # directory, so lib/x86_64-linux-gnu/ucx/ is where they must land.
        NIXLLIB=/out/lib/x86_64-linux-gnu
        mkdir -p \"\$NIXLLIB/ucx\" /out/bin
        cp -a /usr/lib/libuc[pstm]*.so* \"\$NIXLLIB/\"
        cp -a /usr/lib/ucx/*.so* \"\$NIXLLIB/ucx/\"
        rm -f \"\$NIXLLIB\"/*.la \"\$NIXLLIB/ucx\"/*.la 2>/dev/null || true

        # UCX transport modules were linked for /usr/lib/ucx and some depend on
        # each other by soname (libuct_rdmacm.so.0 needs libuct_ib.so.0). Moved
        # to a different directory they stop finding their siblings, and the
        # only symptom is a DEBUG-level 'dlopen(...) failed' followed by that
        # transport silently not existing — precisely the class of silent
        # degradation this whole change is about. Re-point each module at its
        # own directory and the UCX core libs one level up, so the volume is
        # self-contained and needs no LD_LIBRARY_PATH cooperation from callers.
        command -v patchelf >/dev/null || { echo 'ASSERT FAIL: patchelf not in nixl:n0'; exit 1; }
        for m in \"\$NIXLLIB/ucx\"/*.so.*.*; do
            [ -f \"\$m\" ] || continue
            patchelf --set-rpath '\$ORIGIN:\$ORIGIN/..' \"\$m\"
        done
        for m in \"\$NIXLLIB/ucx\"/libuct_rdmacm.so.0 \"\$NIXLLIB/ucx\"/libuct_rocm.so.0; do
            [ -e \"\$m\" ] || { echo \"ASSERT FAIL: \$m missing from the volume\"; exit 1; }
        done
        # ucx_info travels with it: the ROCm memory domain can only be observed
        # on a host with /dev/kfd, i.e. at deploy time inside this very
        # container, so the tool that observes it has to be there too.
        cp -a /usr/bin/ucx_info /out/bin/ 2>/dev/null || true
        echo \"ucx: \$(ls \$NIXLLIB/ucx | grep -c '\.so') module files, rocm=\$(ls \$NIXLLIB/ucx | grep -c rocm)\"

        # ── AMD_ROCM plugin (built out-of-tree by core/rocm-plugin/build.sh) ──
        if [ -f /in/rocm-plugin/libplugin_AMD_ROCM.so ]; then
            cp -a /in/rocm-plugin/libplugin_AMD_ROCM.so \"\$NIXLLIB/plugins/\"
            echo 'AMD_ROCM plugin: copied into the volume'
        else
            echo 'AMD_ROCM plugin: NOT PRESENT (REQUIRE_ROCM_PLUGIN=0 build)'
        fi

        mkdir -p /out/system-libs
        rm -f /out/system-libs/* 2>/dev/null || true

        # Abseil 20240722 (built from source in Dockerfile.nixl-base, same
        # version regardless of Ubuntu release).
        cp /usr/lib/x86_64-linux-gnu/libabsl_*.so.2407.0.0 /out/system-libs/ 2>/dev/null || true
        for f in /out/system-libs/libabsl_*.so.2407.0.0; do
            ln -sf \"\$(basename \$f)\" \"\${f%.0.0}\" 2>/dev/null || true
        done

        # gRPC/protobuf/gpr/c-ares — Ubuntu 24.04 apt sonames (newer than the
        # old 22.04 image's: grpc.so.29 not .10, protobuf.so.32 not .23).
        for soname in libgrpc.so.29 libgrpc++.so.1.51 libgpr.so.29 \
                      libprotobuf.so.32 libcares.so.2 \
                      libupb.so.29 libaddress_sorting.so.29 libre2.so.10; do
            path=\$(find /usr/lib/x86_64-linux-gnu -name \"\${soname}*\" -maxdepth 1 2>/dev/null | sort | tail -1)
            [ -z \"\$path\" ] && continue
            real=\$(readlink -f \"\$path\")
            realname=\$(basename \$real)
            [ -f \"/out/system-libs/\$realname\" ] || cp \"\$real\" /out/system-libs/\"\$realname\"
            ln -sf \"\$realname\" /out/system-libs/\"\$soname\" 2>/dev/null || true
        done

        # Ubuntu 24.04's apt libgrpc-dev/libprotobuf-dev packages were built
        # against a SECOND, older abseil snapshot (20220623, apt's own — not
        # the 20240722 we build from source for NIXL itself). Copy that whole
        # closure too.
        cp /usr/lib/x86_64-linux-gnu/libabsl_*.so.20220623 /out/system-libs/ 2>/dev/null || true

        # POSIX plugin deps not in VLLM_BASE's Ubuntu 24.04 base image.
        for soname in liburing.so.2 libaio.so.1t64; do
            path=\$(find /usr/lib/x86_64-linux-gnu -name \"\${soname}*\" -maxdepth 1 2>/dev/null | sort | tail -1)
            [ -z \"\$path\" ] && continue
            real=\$(readlink -f \"\$path\")
            realname=\$(basename \$real)
            [ -f \"/out/system-libs/\$realname\" ] || cp \"\$real\" /out/system-libs/\"\$realname\"
            ln -sf \"\$realname\" /out/system-libs/\"\$soname\" 2>/dev/null || true
        done

        echo \"system-libs: \$(ls /out/system-libs | wc -l) files\"
    "
echo "OK: volume nixl-libs populated (with system-libs)"

# ── Verify the RUNTIME, not the build ────────────────────────────────────────
# Everything above happened in nixl:n0. What matters is what vllm-nixl:rocm sees
# with the volume mounted the way the deploy scripts mount it, on a host with
# GPUs — because that is where the two silent failures this script fixes lived:
# the plugin binding to the wrong UCX, and the AMD_ROCM plugin being absent.
# Failing here is the whole point; a green build with a DRAM-only runtime is
# what we are trying to make impossible.
echo ""
echo "=== Verifying vllm-nixl:rocm runtime (GPU-visible) ==="
if [ ! -e /dev/kfd ]; then
    echo "SKIP: /dev/kfd absent — cannot verify the ROCm memory domain on this host."
    echo "      Re-run this script on the GPU host before trusting the stack."
else
    docker run --rm \
        --device /dev/kfd --device /dev/dri --group-add video \
        --security-opt seccomp=unconfined \
        -v nixl-libs:/usr/local/nixl:ro \
        -e LD_LIBRARY_PATH=/usr/local/nixl/lib/x86_64-linux-gnu:/usr/local/nixl/system-libs \
        vllm-nixl:rocm bash -lc '
        set -e
        PLUGDIR=/usr/local/nixl/lib/x86_64-linux-gnu/plugins
        echo "--- plugins in the volume ---"
        ls -1 "$PLUGDIR"

        echo "--- libplugin_UCX.so binds which UCX? ---"
        UCXLIB=$(ldd "$PLUGDIR/libplugin_UCX.so" | awk "/libucp\.so/ {print \$3}")
        echo "  libucp.so.0 -> ${UCXLIB}"
        case "${UCXLIB}" in
          /usr/local/nixl/*) : ;;
          *) echo "ASSERT FAIL: libplugin_UCX.so is binding ${UCXLIB}, not the UCX shipped"
             echo "  in the nixl-libs volume. That is the vLLM base image apt UCX, which has"
             echo "  no ROCm module — GPU memory registration would silently not work."
             exit 1 ;;
        esac

        echo "--- ucx_info -b (from the volume) ---"
        /usr/local/nixl/bin/ucx_info -b | grep -E "PACKAGE_VERSION|UCX_CONFIGURE_FLAGS|^#define (uct|ucm)_MODULES"

        echo "--- ucx_info -d: ROCm memory domain / transports ---"
        /usr/local/nixl/bin/ucx_info -d > /tmp/ucxd.txt 2>&1 || true
        grep -iE "rocm" /tmp/ucxd.txt || true
        grep -qi "rocm" /tmp/ucxd.txt || {
            echo "ASSERT FAIL: ucx_info -d lists no ROCm transport on a GPU host."
            echo "  UCX cannot register VRAM here, so NixlConnector is stuck on"
            echo "  kv_buffer_device=cpu. Check that /dev/kfd is visible and that"
            echo "  libuct_rocm.so made it into the volume:"
            ls -1 /usr/local/nixl/lib/x86_64-linux-gnu/ucx/
            exit 1; }

        if [ -f "$PLUGDIR/libplugin_AMD_ROCM.so" ]; then
            echo "--- libplugin_AMD_ROCM.so loadable? ---"
            ldd "$PLUGDIR/libplugin_AMD_ROCM.so" > /tmp/amdrocm.ldd 2>&1 || true
            if grep -q "not found" /tmp/amdrocm.ldd; then
                echo "ASSERT FAIL: libplugin_AMD_ROCM.so has unresolved dependencies:"
                grep "not found" /tmp/amdrocm.ldd
                exit 1
            fi
            python3 -c "
import ctypes, sys
h = ctypes.CDLL(\"$PLUGDIR/libplugin_AMD_ROCM.so\", mode=ctypes.RTLD_GLOBAL)
h.nixl_plugin_init.restype = ctypes.c_void_p
p = h.nixl_plugin_init()
assert p, \"nixl_plugin_init() returned NULL\"
print(\"  dlopen OK, nixl_plugin_init() -> %#x\" % p)
"
        else
            echo "--- libplugin_AMD_ROCM.so: not shipped (REQUIRE_ROCM_PLUGIN=0) ---"
        fi
        echo "VERIFIED: ROCm-capable UCX and AMD_ROCM plugin are live in vllm-nixl:rocm"
    '
fi

echo ""
echo "Next: 05-llm.sh to benchmark, or 08-deploy-qwen-nixl.sh / 11-deploy-qwen-nixl-xnvme.sh to deploy"
echo "  For prefill/decode disaggregation with GPU-resident KV:"
echo "    KV_BUFFER_DEVICE=cuda bash ../../../../bench/pd-disaggregation/deploy-pd-disaggregated.sh"
echo "  Test GPU first: docker run --rm --device /dev/kfd --device /dev/dri vllm-nixl:rocm rocm-smi"
