#!/usr/bin/env bash
# 05-llm.sh — LLM inference benchmarks.
# Runs baseline (no KV offload) and/or P/D disaggregation via NixlConnector.
#
# kv_fabric is DEPRECATED. This uses vLLM NixlConnector (direct NIXL, no daemon).
# Ref: https://docs.vllm.ai/en/stable/features/nixl_connector_usage/
#
# Results answer:
#   PD=0  — TTFT/throughput baseline with no KV transfer
#   PD=1  — TTFT/throughput with P/D disaggregation; delta = NixlConnector KV transfer cost
#
#   PD=0|1|both       run mode (default: both — baseline then P/D)
#   MODEL=<hf-name>   (default: TinyLlama/TinyLlama-1.1B-Chat-v1.0, ungated, ~2 GB)
#   NIXL_BACKEND=UCX  transport for NixlConnector (UCX | LIBFABRIC | Mooncake)
#   NUM_PROMPTS=N     (default: 200)
#   CONCURRENCY=N     (default: 16)
#   MAX_TOKENS=N      (default: 256)
#   HF_CACHE=<path>   (default: ~/.cache/huggingface)
#   HF_TOKEN=<token>  optional, for gated models
#   VLLM_IMAGE=<img>  (default: vllm/vllm-openai:v0.6.4)
#   RESULTS=<path>    output dir (default: results/$(hostname -s)/$(date +%%F)-vllm-serving)
#
#   PROFILE=<name>    bench/profiles/serving/<name>.env — supplies defaults for
#                     MODEL/NUM_PROMPTS/MAX_TOKENS/CONCURRENCY/PD. Explicit env
#                     still wins; no PROFILE = unchanged behaviour, stamped
#                     UNTUNED. `pd-handoff` is the profile for this script.
#   MAX_CONCURRENCY=N vLLM bench serve takes ONE concurrency, while the shared
#                     serving vocabulary lets CONCURRENCY be a list (for
#                     llama-benchy's sweep). Set this to pick explicitly;
#                     otherwise a list collapses to its largest value, loudly.
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
profile_load serving "${PROFILE:-}" || exit 2
export PROVENANCE_SCRIPT="${BASH_SOURCE[0]}"

RESULTS=${RESULTS:-${REPO_ROOT}/results/$(hostname -s)/$(date +%F)-vllm-serving}
HF_CACHE=${HF_CACHE:-$HOME/.cache/huggingface}
MODEL=${MODEL:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}
NIXL_BACKEND=${NIXL_BACKEND:-UCX}
NUM_PROMPTS=${NUM_PROMPTS:-200}
CONCURRENCY=${CONCURRENCY:-16}
MAX_TOKENS=${MAX_TOKENS:-256}
VLLM_IMAGE=${VLLM_IMAGE:-vllm-nixl:rocm}  # built by 06-build-vllm.sh
PD=${PD:-both}

# `vllm bench serve --max-concurrency` takes a single value; the shared serving
# profile vocabulary allows a list (llama-benchy sweeps it). Collapse to the
# largest, and say so — a silently reinterpreted parameter is the failure mode
# this whole configuration layer exists to stop.
if [ "$(echo "${CONCURRENCY}" | wc -w)" -gt 1 ]; then
    COLLAPSED=$(echo "${CONCURRENCY}" | tr ' ' '\n' | sort -n | tail -1)
    echo "NOTE: CONCURRENCY='${CONCURRENCY}' is a list; this tool runs one value."
    echo "      Using ${COLLAPSED} (the largest). Set MAX_CONCURRENCY=N to choose."
    CONCURRENCY=${MAX_CONCURRENCY:-${COLLAPSED}}
else
    CONCURRENCY=${MAX_CONCURRENCY:-${CONCURRENCY}}
fi

mkdir -p "${RESULTS}"

# ── Preflight gate ───────────────────────────────────────────────────────────
export PREFLIGHT_BACKEND="nixl (NixlConnector/${NIXL_BACKEND})" \
       PREFLIGHT_TRANSPORT="http://127.0.0.1:8000"
export MODEL CONCURRENCY NUM_PROMPTS MAX_TOKENS
preflight_gate serving || exit 1

[ -e /dev/kfd ] || { echo "ERR: /dev/kfd absent — run: modprobe amdgpu"; exit 1; }

GPU_FLAGS=(--device /dev/kfd --device /dev/dri
           --group-add video
           --network host --ipc=host
           --security-opt seccomp=unconfined)
# Mount upstream NIXL libs (from nixl-libs volume built by 06-build-vllm.sh)
# so libnixl.so is available for NixlConnector at runtime.
NIXL_FLAGS=(-v nixl-libs:/usr/local/nixl:ro)
HF_FLAGS=(-v "${HF_CACHE}":/root/.cache/huggingface
          -e HF_TOKEN="${HF_TOKEN:-}"
          -e VLLM_ROCM_USE_AITER=0 \
          -e LD_LIBRARY_PATH=/usr/local/nixl/lib/x86_64-linux-gnu:/usr/local/nixl/system-libs)

bench_serve() {
    local server=$1 port=$2
    docker run --rm --network host \
        -v "${RESULTS}":/results \
        "${VLLM_IMAGE}" \
        vllm bench serve \
            --backend vllm --model "${MODEL}" \
            --host 127.0.0.1 --port "${port}" \
            --dataset-name random \
            --random-input-len 512 --random-output-len "${MAX_TOKENS}" \
            --num-prompts "${NUM_PROMPTS}" --max-concurrency "${CONCURRENCY}" \
            --save-result --result-filename "/results/${server}.json" \
        2>&1 | tee "${RESULTS}/${server}.log" | \
        grep -E "Throughput|TTFT|P50|P99|tok" || true

    provenance_write "${RESULTS}/${server}.json" \
        "phase=${server}" \
        "model=${MODEL}" \
        "vllm_image=${VLLM_IMAGE}" \
        "nixl_backend=${NIXL_BACKEND}" \
        "port=${port}" \
        "num_prompts=${NUM_PROMPTS}" \
        "max_concurrency=${CONCURRENCY}" \
        "random_input_len=512" \
        "random_output_len=${MAX_TOKENS}" \
        "pd_mode=${PD}"
}

run_baseline() {
    echo "  baseline: single vLLM instance, no KV offload"
    local name=baseline
    docker rm -f vllm-${name} 2>/dev/null || true
    docker run -d --name "vllm-${name}" \
        "${GPU_FLAGS[@]}" "${NIXL_FLAGS[@]}" "${HF_FLAGS[@]}" \
        "${VLLM_IMAGE}" \
        python3 -m vllm.entrypoints.openai.api_server \
        --model "${MODEL}" --port 8000 --gpu-memory-utilization 0.85
    echo "  waiting for vLLM..."
    for i in $(seq 1 36); do curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1 && break; sleep 5; done
    curl -sf http://127.0.0.1:8000/health >/dev/null || { docker logs "vllm-${name}" | tail -10; docker rm -f "vllm-${name}"; return 1; }
    bench_serve "${name}" 8000
    docker rm -f "vllm-${name}" 2>/dev/null || true
    echo "  → ${RESULTS}/${name}.json"
}

run_pd() {
    echo "  P/D disaggregation: NixlConnector (kv_fabric deprecated)"
    echo "  backend: ${NIXL_BACKEND}"
    docker rm -f vllm-prefill vllm-decode 2>/dev/null || true

    # kv_buffer_device is pinned to cpu here on purpose, but the REASON changed
    # on 2026-08-14. It used to be forced: UCX was built --without-rocm, so VRAM
    # registration failed with NIXL_ERR_BACKEND ("VRAM memory is detected as host
    # by UCX"). UCX is now built --with-rocm (../core/Dockerfile.nixl-base) and
    # shipped into the nixl-libs volume, so "cuda" works.
    # This throwaway A/B benchmark keeps "cpu" so its numbers stay comparable
    # with every earlier run of this script. For the VRAM-resident KV path use
    # the persistent deploy, which makes it a parameter:
    #   KV_BUFFER_DEVICE=cuda bash ../../../../bench/pd-disaggregation/deploy-pd-disaggregated.sh
    local kv_cfg_producer='{"kv_connector":"NixlConnector","kv_role":"kv_producer","kv_buffer_device":"cpu","kv_connector_extra_config":{"hostname":"127.0.0.1","port":14579}}'
    local kv_cfg_consumer='{"kv_connector":"NixlConnector","kv_role":"kv_consumer","kv_buffer_device":"cpu","kv_connector_extra_config":{"hostname":"127.0.0.1","port":14579}}'

    # Both instances share the host network namespace (--network host), so the
    # NIXL handshake listener (VLLM_NIXL_SIDE_CHANNEL_PORT, default 5600 for
    # both) must be split or the second instance fails with
    # "Address already in use (addr='tcp://localhost:5600')".
    docker run -d --name vllm-prefill \
        "${GPU_FLAGS[@]}" "${NIXL_FLAGS[@]}" "${HF_FLAGS[@]}" \
        -e NIXL_BACKEND="${NIXL_BACKEND}" \
        -e VLLM_NIXL_SIDE_CHANNEL_PORT=5600 \
        "${VLLM_IMAGE}" \
        python3 -m vllm.entrypoints.openai.api_server \
        --model "${MODEL}" --port 8100 \
        --gpu-memory-utilization 0.40 \
        --kv-transfer-config "${kv_cfg_producer}"

    docker run -d --name vllm-decode \
        "${GPU_FLAGS[@]}" "${NIXL_FLAGS[@]}" "${HF_FLAGS[@]}" \
        -e NIXL_BACKEND="${NIXL_BACKEND}" \
        -e VLLM_NIXL_SIDE_CHANNEL_PORT=5601 \
        "${VLLM_IMAGE}" \
        python3 -m vllm.entrypoints.openai.api_server \
        --model "${MODEL}" --port 8000 \
        --gpu-memory-utilization 0.40 \
        --kv-transfer-config "${kv_cfg_consumer}"

    echo "  waiting for both instances..."
    for port in 8100 8000; do
        for i in $(seq 1 48); do curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && break; sleep 5; done
        curl -sf "http://127.0.0.1:${port}/health" >/dev/null || {
            echo "  ERR: port ${port} failed"; docker logs vllm-prefill | tail -5; docker logs vllm-decode | tail -5
            docker rm -f vllm-prefill vllm-decode; return 1; }
    done

    bench_serve "pd_nixl" 8000
    docker rm -f vllm-prefill vllm-decode 2>/dev/null || true
    echo "  → ${RESULTS}/pd_nixl.json"
}

echo "05-llm: LLM inference benchmarks (model: ${MODEL})"
echo "  TTFT/throughput comparison: baseline vs P/D disaggregation"

case "${PD}" in
    0|baseline) run_baseline ;;
    1|pd)       run_pd ;;
    both)       run_baseline; run_pd ;;
    *) echo "ERR: PD must be 0, 1, or both"; exit 1 ;;
esac

echo ""
echo "Results in ${RESULTS}/"
for f in "${RESULTS}/baseline.json" "${RESULTS}/pd_nixl.json"; do
    [ -f "$f" ] && echo "  $(basename $f)" || true
done
echo ""
echo "Headline: compare baseline.json vs pd_nixl.json TTFT p50/p99"
