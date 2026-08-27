#!/usr/bin/env bash
# Asymmetric-P2P P/D deploy on a single host.
# Finding (2026-08-17): at most ONE concurrent multi-process GPU group may hold
# HIP IPC/P2P handles. The second one to request them dies in
# hipIpcGetMemHandle -> invalid argument. But a group that never requests them
# (NCCL_P2P_DISABLE=1) does NOT consume the slot, so the OTHER group keeps full XGMI.
# So: give the degraded half to PREFILL (collectives once per prompt) and the
# fast half to DECODE (collectives ~80x per forward, every token).
# PREFILL MUST START FIRST — it is the one that forgoes P2P.
set -uo pipefail

M=${MODEL:-Qwen/Qwen2.5-72B-Instruct}
COMMON=(--network host --ipc host
        --device /dev/kfd --device /dev/dri --group-add video
        --security-opt seccomp=unconfined --security-opt label=disable
        -v nixl-libs:/usr/local/nixl:ro
        -v /opt/rixl-bench/hf-cache:/root/.cache/huggingface
        -e LD_LIBRARY_PATH=/usr/local/nixl/lib/x86_64-linux-gnu:/usr/local/nixl/system-libs
        -e NIXL_BACKEND=UCX
        -e NIXL_PLUGIN_DIR=/usr/local/nixl/lib/x86_64-linux-gnu/plugins
        -e PYTHONPATH=/opt/python/lib/python3.14/site-packages/_rocm_sdk_core/share/amd_smi:)
KVP='{"kv_connector":"NixlConnector","kv_role":"kv_producer","kv_buffer_device":"cpu","kv_connector_extra_config":{"hostname":"127.0.0.1","port":14579}}'
KVC='{"kv_connector":"NixlConnector","kv_role":"kv_consumer","kv_buffer_device":"cpu","kv_connector_extra_config":{"hostname":"127.0.0.1","port":14579}}'

docker rm -f vllm-pd-prefill-xgmi vllm-pd-decode-xgmi >/dev/null 2>&1

wait_health() { # name port label
  for i in $(seq 1 60); do
    curl -sf -m3 "http://127.0.0.1:$2/health" >/dev/null 2>&1 && { echo "$3 HEALTHY t+$((i*10))s"; return 0; }
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" != "true" ] && {
      echo "$3 DIED t+$((i*10))s"
      docker logs "$1" 2>&1 | grep -iE "hipIpc|NCCL WARN|custom_all_reduce|RuntimeError" | head -5
      return 1; }
    sleep 10
  done; echo "$3 TIMEOUT"; return 1
}

# ---- PREFILL: degraded half, starts first, forgoes P2P ----
docker run -d --name vllm-pd-prefill-xgmi "${COMMON[@]}" \
  -e VLLM_ROCM_USE_AITER=0 -e NCCL_P2P_DISABLE=1 -e VLLM_NIXL_SIDE_CHANNEL_PORT=5600 \
  -e HIP_VISIBLE_DEVICES=0,1,2,3 -e NCCL_DEBUG=WARN \
  vllm-nixl:rocm python3 -m vllm.entrypoints.openai.api_server \
    --model "$M" --port 8100 --gpu-memory-utilization 0.90 --tensor-parallel-size 4 \
    --enforce-eager --dtype bfloat16 --disable-custom-all-reduce \
    --kv-transfer-config "$KVP" >/dev/null
echo "prefill launched (GPUs 0-3): NCCL_P2P_DISABLE=1, custom-AR OFF  [degraded half]"
wait_health vllm-pd-prefill-xgmi 8100 PREFILL || exit 1

# ---- DECODE: privileged half, full XGMI P2P + custom all-reduce ----
docker run -d --name vllm-pd-decode-xgmi "${COMMON[@]}" \
  -e VLLM_ROCM_USE_AITER=0 -e VLLM_NIXL_SIDE_CHANNEL_PORT=5601 \
  -e HIP_VISIBLE_DEVICES=4,5,6,7 -e NCCL_DEBUG=WARN \
  vllm-nixl:rocm python3 -m vllm.entrypoints.openai.api_server \
    --model "$M" --port 8000 --gpu-memory-utilization 0.90 --tensor-parallel-size 4 \
    --enforce-eager --dtype bfloat16 \
    --kv-transfer-config "$KVC" >/dev/null
echo "decode launched (GPUs 4-7): P2P ENABLED, custom-AR ENABLED  [XGMI half]"
wait_health vllm-pd-decode-xgmi 8000 DECODE || exit 1

echo "=== BOTH UP: prefill degraded + decode on full XGMI ==="
