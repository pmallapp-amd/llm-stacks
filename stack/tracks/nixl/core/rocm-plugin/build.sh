#!/usr/bin/env bash
# rocm-plugin/build.sh — compile libplugin_AMD_ROCM.so inside nixl:n0.
#
# Compiles the AMD ROCm plugin against:
#   - NIXL installed in the image at /usr/local/nixl
#   - ROCm at /opt/rocm (bind-mounted from host)
#
# Output: PLUGIN_INSTALL/lib/x86_64-linux-gnu/plugins/libplugin_AMD_ROCM.so
# That directory should be added to NIXL_PLUGIN_DIR when running benchmarks.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_INSTALL=${PLUGIN_INSTALL:-${SCRIPT_DIR}/install}
ROCM_PATH=${ROCM_PATH:-/opt/rocm}

[ -d "${ROCM_PATH}" ] || { echo "ERR: ${ROCM_PATH} not found — need ROCm on host"; exit 1; }

echo "AMD ROCm plugin build:"
echo "  plugin src   : ${SCRIPT_DIR}"
echo "  rocm path    : ${ROCM_PATH}"
echo "  install dir  : ${PLUGIN_INSTALL}"

mkdir -p "${PLUGIN_INSTALL}"

docker run --rm \
    --device /dev/kfd \
    --device /dev/dri \
    --group-add video \
    --group-add render \
    -v "${ROCM_PATH}":/opt/rocm:ro \
    -v "${SCRIPT_DIR}":/src/rocm-plugin:ro \
    -v "${PLUGIN_INSTALL}":/opt/rocm-plugin \
    nixl:n0 bash -c "
        set -euo pipefail
        apt-get install -y --no-install-recommends \
            liburing-dev libelf-dev libdrm-dev libdrm-amdgpu1 2>/dev/null || true
        export PATH=/opt/rocm/bin:\${PATH}
        export LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:\${LIBRARY_PATH:-}
        export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:/usr/local/nixl/lib/x86_64-linux-gnu:\${LD_LIBRARY_PATH:-}
        mkdir -p /work/rocm-plugin-build
        meson setup /work/rocm-plugin-build /src/rocm-plugin \
            -Dnixl_path=/usr/local/nixl \
            -Drocm_path=/opt/rocm \
            --prefix=/opt/rocm-plugin \
            --buildtype=release
        ninja -C /work/rocm-plugin-build
        ninja -C /work/rocm-plugin-build install

        # ASSERT: meson+ninja can both exit 0 while installing the .so somewhere
        # other than where the caller looks for it (a --prefix/install_dir
        # mismatch), and the only symptom downstream is 'backend not found'.
        SO=/opt/rocm-plugin/lib/x86_64-linux-gnu/plugins/libplugin_AMD_ROCM.so
        [ -f \"\$SO\" ] || {
            echo \"ASSERT FAIL: \$SO was not installed\"
            find /opt/rocm-plugin -name 'libplugin_*.so' -printf '  found: %p\n' 2>/dev/null
            exit 1; }
        # Dumped to files before grepping: 'cmd | grep -q' under pipefail reports
        # a failure when grep -q short-circuits and cmd takes SIGPIPE, which is a
        # false ASSERT FAIL. See the same note in ../02-compile-bench.sh.
        nm -D --defined-only \"\$SO\" > /tmp/plugin.syms
        ldd \"\$SO\" > /tmp/plugin.ldd
        grep -q 'nixl_plugin_init' /tmp/plugin.syms || {
            echo \"ASSERT FAIL: \$SO does not export nixl_plugin_init — NIXL cannot load it\"
            exit 1; }
        grep -q 'libamdhip64' /tmp/plugin.ldd || {
            echo \"ASSERT FAIL: \$SO is not linked against libamdhip64 — it was built\"
            echo \"  without HIP, so its VRAM_SEG staging path cannot work.\"
            cat /tmp/plugin.ldd
            exit 1; }
        grep -q 'not found' /tmp/plugin.ldd && {
            echo \"ASSERT FAIL: \$SO has unresolved dependencies inside nixl:n0:\"
            grep 'not found' /tmp/plugin.ldd
            exit 1; } || true
        echo \"OK: libplugin_AMD_ROCM.so installed, exports nixl_plugin_init, links HIP\"
    "

PLUGIN_SO="${PLUGIN_INSTALL}/lib/x86_64-linux-gnu/plugins/libplugin_AMD_ROCM.so"
[ -f "${PLUGIN_SO}" ] || {
    echo "ERR: build reported success but ${PLUGIN_SO} is not on the host."
    echo "     (bind-mount of ${PLUGIN_INSTALL} did not receive the install output)"
    exit 1; }

echo "OK: ${PLUGIN_SO}"
echo ""
echo "To use with nixlbench, add to NIXL_PLUGIN_DIR:"
echo "  NIXL_PLUGIN_DIR=${PLUGIN_INSTALL}/lib/x86_64-linux-gnu/plugins"
echo ""
echo "To ship it into the vLLM runtime (nixl-libs volume), re-run:"
echo "  bash ../../vllm/06-build-vllm.sh     # picks this path up automatically"
