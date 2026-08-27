#!/usr/bin/env bash
# 03-storage-floor.sh — KV cache storage floor benchmarks.
# Runs DRAM and/or VRAM paths against a local file via POSIX O_DIRECT.
#
# Results answer:
#   DRAM path  — raw storage bandwidth floor (~11.5 GB/s on MI210)
#   VRAM path  — GPU memory staging cost (~6.7 GB/s, 42% gap = hipMemcpy bounce)
#
#   SEG_TYPE=DRAM|VRAM|both   source memory (default: both)
#   OP=WRITE|READ|both        transfer direction (default: both)
#   ITERS=N                   iterations (default: 1000)
#   BENCH_INSTALL=<path>      nixlbench prefix (default: <this-dir>/bench-install)
#   PLUGIN_INSTALL=<path>     AMD_ROCM plugin (default: <this-dir>/rocm-plugin/install)
#   ROCM_PATH=<path>          ROCm prefix (default: /opt/rocm)
#   RESULTS=<path>            output dir (default: results/$(hostname -s)/$(date +%%F)-nixlbench-storage-floor)
#
#   PROFILE=<name>            bench/profiles/storage/<name>.env — supplies
#                             defaults for the knobs above. Explicit env still
#                             wins; no PROFILE = unchanged behaviour, run
#                             stamped UNTUNED.
#   NUM_THREADS=N             nixlbench --num_threads (default: unset)
#   PIPELINE_DEPTH=N          nixlbench --pipeline_depth (default: unset)
#   WARMUP_ITERS=N            nixlbench --warmup_iter (default: unset)
#   USE_HUGEPAGES=0|1         nixlbench --use_hugepages (default: unset)
#   CHECK_CONSISTENCY=0|1     nixlbench --check_consistency (default: unset)
#   STORAGE_ENABLE_DIRECT=0|1 O_DIRECT (default: 1 — unchanged from before)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../../../.." && pwd)

# Configuration layer — see bench/profiles/README.md. No-op without PROFILE.
# shellcheck source=../../../../bench/lib/profiles.sh
source "${REPO_ROOT}/bench/lib/profiles.sh"
# shellcheck source=../../../../bench/lib/preflight.sh
source "${REPO_ROOT}/bench/lib/preflight.sh"
# shellcheck source=../../../../bench/lib/provenance.sh
source "${REPO_ROOT}/bench/lib/provenance.sh"
profile_load storage "${PROFILE:-}" || exit 2
export PROVENANCE_SCRIPT="${BASH_SOURCE[0]}"

RESULTS=${RESULTS:-${REPO_ROOT}/results/$(hostname -s)/$(date +%F)-nixlbench-storage-floor}
BENCH_INSTALL=${BENCH_INSTALL:-${SCRIPT_DIR}/bench-install}
PLUGIN_INSTALL=${PLUGIN_INSTALL:-${SCRIPT_DIR}/rocm-plugin/install}
ROCM_PATH=${ROCM_PATH:-/opt/rocm}
SEG_TYPE=${SEG_TYPE:-both}
OP=${OP:-both}
ITERS=${ITERS:-1000}

mkdir -p "${RESULTS}"

[ -x "${BENCH_INSTALL}/bin/nixlbench" ] || {
    echo "ERR: nixlbench not found — run 02-compile-bench.sh first"; exit 1; }

ROCM_MOUNT=()
[ -d "${ROCM_PATH}" ] && ROCM_MOUNT=("-v" "${ROCM_PATH}:/opt/rocm:ro")

# Plugin dir: POSIX (in image) + AMD_ROCM (host mount, needed for VRAM)
PLUGIN_DIR_DRAM="/usr/local/nixl/lib/x86_64-linux-gnu/plugins"
PLUGIN_DIR_VRAM="${PLUGIN_DIR_DRAM}"
if [ -f "${PLUGIN_INSTALL}/lib/x86_64-linux-gnu/plugins/libplugin_AMD_ROCM.so" ]; then
    PLUGIN_DIR_VRAM="/opt/amd-rocm-plugin/lib/x86_64-linux-gnu/plugins"
fi

run_bench() {
    local seg=$1 op=$2
    local oplc=$(echo "$op" | tr '[:upper:]' '[:lower:]')
    local seglc=$(echo "$seg" | tr '[:upper:]' '[:lower:]')
    local out="${RESULTS}/storage_${seglc}_${oplc}.txt"
    echo "  ${seg} ${op} → ${out}"

    local extra_dev=()
    local extra_env=("-e" "NIXL_PLUGIN_DIR=${PLUGIN_DIR_DRAM}")
    local backend_args="--backend POSIX --posix_api_type URING"
    local backend_name="POSIX"

    if [ "${seg}" = "VRAM" ]; then
        extra_dev=("--device" "/dev/kfd" "--device" "/dev/dri"
                   "--group-add" "video" "--group-add" "render")
        extra_env=("-e" "NIXL_PLUGIN_DIR=${PLUGIN_DIR_VRAM}")
        backend_args="--backend AMD_ROCM --runtime_type ASIO"
        backend_name="AMD_ROCM"
    fi

    # ── Preflight gate (see bench/lib/preflight.sh) ──────────────────────────
    export INITIATOR_SEG="${seg}" SEG_TYPE="${seg}" ITERS="${ITERS}"
    export PREFLIGHT_BACKEND="${backend_name}" PREFLIGHT_TRANSPORT="file:${RESULTS}"
    preflight_gate storage || exit 1

    # O_DIRECT stays on by default — exactly what this script did before the
    # knob existed — but it is now recorded, and can be turned off deliberately.
    local direct=${STORAGE_ENABLE_DIRECT:-1}
    local extra_flags=" --storage_enable_direct=${direct}"
    if [ -n "${NUM_THREADS:-}" ]; then
        extra_flags="${extra_flags} --num_threads ${NUM_THREADS}"
    fi
    if [ -n "${PIPELINE_DEPTH:-}" ]; then
        extra_flags="${extra_flags} --pipeline_depth ${PIPELINE_DEPTH}"
    fi
    if [ -n "${WARMUP_ITERS:-}" ]; then
        extra_flags="${extra_flags} --warmup_iter ${WARMUP_ITERS}"
    fi
    if [ -n "${USE_HUGEPAGES:-}" ]; then
        extra_flags="${extra_flags} --use_hugepages=${USE_HUGEPAGES}"
    fi
    if [ -n "${CHECK_CONSISTENCY:-}" ]; then
        extra_flags="${extra_flags} --check_consistency=${CHECK_CONSISTENCY}"
    fi
    if [ -n "${PROGRESS_THREADS:-}" ]; then
        extra_flags="${extra_flags} --progress_threads ${PROGRESS_THREADS}"
    fi

    docker run --rm \
        "${extra_dev[@]}" \
        --security-opt seccomp=unconfined \
        --ulimit memlock=-1 \
        "${ROCM_MOUNT[@]}" \
        -v "${BENCH_INSTALL}":/opt/nixl-bench:ro \
        -v "${PLUGIN_INSTALL}":/opt/amd-rocm-plugin:ro \
        -v "${RESULTS}":/run \
        -e PATH=/opt/nixl-bench/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        -e LD_LIBRARY_PATH=/opt/rocm/lib:/usr/local/nixl/lib/x86_64-linux-gnu:/opt/nixl-bench/lib/x86_64-linux-gnu:/opt/nixl-bench/lib \
        "${extra_env[@]}" \
        nixl:n0 bash -c "
            set -euo pipefail
            nixlbench ${backend_args} \
                --filepath /run \
                --initiator_seg_type ${seg} --target_seg_type DRAM \
                --start_block_size 65536 --max_block_size 67108864 \
                --start_batch_size 1 --max_batch_size 16 \
                --num_iter ${ITERS} \
                --op_type ${op} ${extra_flags} \
                | tee /run/storage_${seglc}_${oplc}.txt
        "

    provenance_write "${out}" \
        "backend=${backend_name}" \
        "op_type=${op}" \
        "initiator_seg_type=${seg}" \
        "start_block_size=65536" \
        "max_block_size=67108864" \
        "max_batch_size=16" \
        "num_iter=${ITERS}" \
        "storage_enable_direct=${direct}" \
        "extra_nixlbench_flags=${extra_flags}" \
        "filepath=/run (bind-mounted ${RESULTS})" \
        "image=nixl:n0"
}

# Expand "both" combinations
segs=(); ops=()
case "${SEG_TYPE}" in both) segs=(DRAM VRAM) ;; *) segs=("${SEG_TYPE}") ;; esac
case "${OP}"      in both) ops=(WRITE READ)  ;; *) ops=("${OP}")        ;; esac

echo "03-storage-floor: POSIX O_DIRECT storage floor"
[ -e /dev/kfd ] || echo "  NOTE: /dev/kfd absent — VRAM runs will fail. Run: modprobe amdgpu"

for seg in "${segs[@]}"; do
    for op in "${ops[@]}"; do
        run_bench "${seg}" "${op}"
    done
done

echo ""
echo "Results in ${RESULTS}/"
# Provenance sidecars are named <result>.provenance.txt and would otherwise be
# picked up by this glob as if they were result tables.
ls "${RESULTS}"/storage_*.txt 2>/dev/null | grep -v '\.provenance\.txt$' | xargs -I{} bash -c \
    'f="{}"; printf "  %-35s  peak=%s GB/s\n" "$(basename $f)" \
     "$(grep -E "^67108864\s+1\s" "$f" | awk "{print \$3}" | head -1)"'
