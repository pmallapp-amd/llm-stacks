#!/usr/bin/env bash
# deploy-pd-spdk.sh — genuine prefill/decode disaggregation through a remote
# SPDK_NVMe_KV target, built on top of the same rocm-aic:latest image
# deploy-spdk.sh uses (vLLM v0.26.0 + LMCache v0.5.3 + NIXL v1.3.2 + our
# SPDK_NVMe_KV plugin), but a DIFFERENT LMCache integration mode.
#
# WHY THIS IS A SEPARATE SCRIPT, NOT AN EXTENSION OF deploy-spdk.sh:
# deploy-spdk.sh's compose stack runs LMCache as a standalone `lmcache server`
# process (LMCacheMPConnector, multi-process mode) in a sibling container
# (aic-lmcache-spdk). That CLI (`lmcache server --help`, confirmed against the
# live image 2026-08-21) has NO --pd-role/--store-location/--retrieve-locations
# flags — there is no way to express asymmetric producer/receiver roles
# through it. This script instead runs LMCache IN-PROCESS inside vLLM itself
# (LMCacheConnectorV1, same mechanism vLLM's own bundled example at
# /app/vllm/examples/disaggregated/lmcache/disagg_prefill_lmcache_v1/ uses),
# configured via a YAML file (LMCACHE_CONFIG_FILE) that DOES expose per-role
# config. One `docker run` per role, no separate lmcache-spdk container.
#
# ARCHITECTURE — NOT "PDBackend" / enable_pd:
# LMCache v0.5.3 has two unrelated mechanisms that both smell like "the P/D
# thing":
#   1. enable_pd / pd_role / "PDBackend" (lmcache/v1/storage_backend/pd_backend.py):
#      a dedicated peer-to-peer transfer channel (default backend list
#      ["UCX"], config.nixl_backends) for direct producer->receiver GPU/host
#      memory handoff. CONFIRMED UNUSABLE for our goal: its transfer_channel
#      requires a backend with supportsRemote()==true, and
#      spdk_nvme_kv_backend.h explicitly declares
#      `supportsRemote() const override { return false; }` — SPDK_NVMe_KV
#      cannot be plugged into PDBackend's transfer channel at all.
#   2. enable_nixl_storage / store_location / retrieve_locations
#      (lmcache/v1/storage_backend/nixl_storage_backend.py): ordinary
#      persistent L1->L2 storage, the SAME mechanism deploy-spdk.sh's single
#      kv_both instance already uses for its own local caching. This is what
#      this script uses instead: two INDEPENDENT instances, each with
#      ordinary enable_nixl_storage pointed at the SAME external <SETUP4_TARGET_NODE>
#      target — producer only STOREs (kv_role=kv_producer), receiver only
#      RETRIEVEs (kv_role=kv_consumer) — vllm's own kv_role gating
#      (lmcache/integration/vllm/vllm_v1_adapter.py:1050,1141,1661) enforces
#      the asymmetry. This is disaggregation-via-shared-persistent-store,
#      not a direct RDMA handoff — a better fit for this project's actual
#      goal (measuring genuine KV movement through the storage tier)
#      than a direct P2P channel would have been anyway.
#
# REQUIRES A NEW PATCH beyond deploy-spdk.sh's: nixl_storage_backend.py (the
# in-process path) has its OWN separate OBJ-family backend whitelist,
# disjoint from the one the existing patches/lmcache/15-*.patch already
# extended (that patch only covers the MP-server L2-adapter code path in
# lmcache/v1/distributed/l2_adapters/nixl_store_l2_adapter.py — a different
# file). See patches/lmcache/17-add-spdk-xnvme-kv-storage-backend.patch
# (added alongside this script) — build.sh's existing patch-staging step
# picks up any new patches/lmcache/*.patch automatically, no build.sh changes
# needed, but the image MUST be rebuilt after this patch is added.
#
# STATUS: STAGED, NEVER RUN — same house rule as deploy-spdk.sh/
# docker-compose.storage.yml. This combination (two independent in-process
# LMCacheConnectorV1 instances sharing one remote SPDK_NVMe_KV target via
# kv_role asymmetry, no PDBackend) is novel and unverified end-to-end. The
# exact string value for store_location/retrieve_locations below
# ("SPDK_NVMe_KV") is this script's best-grounded guess from static analysis
# of storage_manager.py's backend-name registration — NOT confirmed against
# a real run. If the receiver logs "Unsupported" / a KeyError resolving that
# location name, grep its log for "Created backend: <name> (<class>)"
# (storage_manager.py's own registration log line) and correct
# LMCACHE_STORE_LOCATION/LMCACHE_RETRIEVE_LOCATIONS below to match — this is
# exactly the kind of "watch it fail, fix the actual error" bring-up this
# repo's other tracks already went through (see README's "Known gap"
# history).
#
# Prerequisites:
#   1. ./vendor.sh && ./build.sh (image must include patch 17 above)
#   2. A SPDK_NVMe_KV target reachable at AIC_SPDK_KV_TRID (<SETUP4_TARGET_NODE>)
#
# Usage: run once per role, on separate hosts:
#   PD_ROLE=producer MODEL=Qwen/Qwen2.5-72B-Instruct TENSOR_PARALLEL_SIZE=8 \
#     DTYPE=bfloat16 bash deploy-pd-spdk.sh          # on <SETUP4_PREFILL_NODE>
#   PD_ROLE=receiver MODEL=Qwen/Qwen2.5-72B-Instruct TENSOR_PARALLEL_SIZE=8 \
#     DTYPE=bfloat16 AIC_SPDK_KV_SLOT_OFFSET=2000000 bash deploy-pd-spdk.sh   # on <SETUP4_DECODE_NODE>
#
# Override env (mirrors deploy-spdk.sh where the same knob applies):
#   PD_ROLE=<producer|receiver>   required. producer=prefill/store-only,
#                                 receiver=decode/retrieve-only.
#   MODEL=<hf-name>               (default: TinyLlama/TinyLlama-1.1B-Chat-v1.0)
#   PORT=<n>                      (default: 8301 — avoids deploy-spdk.sh's 8300)
#   GPU=<csv>                     ROCR_VISIBLE_DEVICES (default: all 8, "0,1,2,3,4,5,6,7")
#   TENSOR_PARALLEL_SIZE=<n>      (default: 8)
#   DTYPE=<auto|bfloat16|float16> (default: bfloat16)
#   MAX_MODEL_LEN=<n>             (default: unset — vLLM's own model default)
#   HF_OVERRIDES=<json>           (default: unset — see
#                                  bench/pd-disaggregation/deploy-pd-disaggregated.sh's
#                                  YARN recipe if extending context beyond native)
#   ROCM_AIC_DIR=<path>           (default: ${SCRIPT_DIR}/vendor/rocm-aic)
#   HF_TOKEN=<token>              required
#   HF_HOME=<path>                (default: ~/.cache/huggingface)
#   AIC_SPDK_KV_TRID=<trid>       NVMe-oF transport ID of the <SETUP4_TARGET_NODE> target
#   AIC_SPDK_KV_POOL=<n>          (default: 2000000 — see deploy-spdk.sh's
#                                  AIC_SPDK_KV_POOL comment for why)
#   AIC_SPDK_KV_SLOT_OFFSET=<n>   per-deployment key-space offset (see the
#                                 plugin fix in ../nixl/core/nvme-kv-plugin/).
#                                 MUST differ between producer and receiver —
#                                 e.g. producer=0, receiver=AIC_SPDK_KV_POOL.
#                                 (default: 0)
#   AIC_NIXL_STAGING_GB=<n>       LocalCPUBackend pinned-pool size used as the
#                                 NIXL staging buffer (nixl_buffer_device=cpu
#                                 requires this > 0 — confirmed via a real
#                                 first-run ValueError). Not an actual L1
#                                 cache (local_cpu stays False). (default: 8)
#   COMPOSE_PROJECT=<name>        used only for the container name prefix
#                                 (default: rocm-aic-pd-spdk)
#   DEPLOY_DEGRADED=<list>        (default: "unvalidated-first-run,experimental-pd-via-shared-storage")
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../../.." && pwd)

# shellcheck source=../../../bench/lib/deployment.sh
source "${REPO_ROOT}/bench/lib/deployment.sh"

PD_ROLE=${PD_ROLE:?"ERR: PD_ROLE=producer|receiver required"}
case "${PD_ROLE}" in
    producer|receiver) ;;
    *) echo "ERR: PD_ROLE must be 'producer' or 'receiver', got '${PD_ROLE}'"; exit 1 ;;
esac

MODEL=${MODEL:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}
PORT=${PORT:-8301}
GPU=${GPU:-0,1,2,3,4,5,6,7}
TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE:-8}
DTYPE=${DTYPE:-bfloat16}
MAX_MODEL_LEN=${MAX_MODEL_LEN:-}
HF_OVERRIDES=${HF_OVERRIDES:-}
ROCM_AIC_DIR=${ROCM_AIC_DIR:-${SCRIPT_DIR}/vendor/rocm-aic}
HF_HOME=${HF_HOME:-$HOME/.cache/huggingface}
AIC_SPDK_KV_TRID=${AIC_SPDK_KV_TRID:-"trtype:TCP adrfam:IPv4 traddr:<SETUP3_TARGET_NODE_IP> trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0"}
AIC_SPDK_KV_POOL=${AIC_SPDK_KV_POOL:-2000000}
AIC_SPDK_KV_SLOT_OFFSET=${AIC_SPDK_KV_SLOT_OFFSET:-0}
# nixl_buffer_device=cpu requires max_local_cpu_size > 0 -- LocalCPUBackend's
# pinned pool doubles as the NIXL staging buffer for the storage transfer even
# though local_cpu (the L1-cache-tier flag) stays False. Not a cache size,
# just a staging pool -- a few GB is plenty. (Confirmed via a real first-run
# failure: "ValueError: nixl_buffer_device='cpu' requires max_local_cpu_size
# > 0", lmcache/v1/config.py's _validate_config.)
AIC_NIXL_STAGING_GB=${AIC_NIXL_STAGING_GB:-8}
COMPOSE_PROJECT=${COMPOSE_PROJECT:-rocm-aic-pd-spdk}
DEPLOY_DEGRADED=${DEPLOY_DEGRADED-unvalidated-first-run,experimental-pd-via-shared-storage}
IMAGE_TAG_DEFAULT="rocm-aic:latest"
IMAGE_REF="${IMAGE_REF:-${IMAGE_TAG_DEFAULT}}"

CONTAINER_NAME="aic-pd-${PD_ROLE}"
CONFIG_DIR="${ROCM_AIC_DIR}/pd-configs"
CONFIG_FILE="${CONFIG_DIR}/lmcache-${PD_ROLE}-spdk.yaml"

# ── Preflight checks ──────────────────────────────────────────────────────────
[ -e /dev/kfd ] || { echo "ERR: /dev/kfd absent — run: modprobe amdgpu"; exit 1; }
[ -n "${HF_TOKEN:-}" ] || {
    echo "ERR: HF_TOKEN not set (HuggingFace access token required)"; exit 1; }
docker image inspect "${IMAGE_REF}" >/dev/null 2>&1 || {
    echo "ERR: ${IMAGE_REF} not found — run ./build.sh first (must include"
    echo "     patches/lmcache/17-add-spdk-xnvme-kv-storage-backend.patch)"
    exit 1
}

echo "deploy-pd-spdk: rocm-aic in-process LMCacheConnectorV1, role=${PD_ROLE}"
echo "  model     : ${MODEL}"
echo "  port      : ${PORT}"
echo "  gpu       : ${GPU}"
echo "  tp        : ${TENSOR_PARALLEL_SIZE}"
echo "  trid      : ${AIC_SPDK_KV_TRID}"
echo "  slot off  : ${AIC_SPDK_KV_SLOT_OFFSET}"
echo ""

# ── Step 1: hugepages ─────────────────────────────────────────────────────────
echo "=== Step 1: hugepages ==="
NR_HUGE=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)
if [ "${NR_HUGE}" -lt 512 ]; then
    echo "  allocating 512 x 2MB hugepages..."
    echo 512 > /proc/sys/vm/nr_hugepages
fi
echo "  hugepages: $(cat /proc/sys/vm/nr_hugepages)"

# ── Step 2: prep dirs + per-role LMCache config ──────────────────────────────
echo ""
echo "=== Step 2: prep dirs + LMCache config ==="
mkdir -p "${HF_HOME}/hub" "${CONFIG_DIR}" "${ROCM_AIC_DIR}/logs/pd-${PD_ROLE}"

if [ "${PD_ROLE}" = "producer" ]; then
    ROLE_LOCATION_KEY="store_location"
    ROLE_LOCATION_VAL="NixlStorageBackend"
    KV_ROLE="kv_producer"
else
    ROLE_LOCATION_KEY="retrieve_locations"
    ROLE_LOCATION_VAL="[\"NixlStorageBackend\"]"
    KV_ROLE="kv_consumer"
fi

# CONFIRMED 2026-08-21 via a real run's log line: "Created backend:
# NixlStorageBackend (NixlStaticStorageBackend)" (storage_manager.py:1296) —
# the registered location name is the generic class-based key
# "NixlStorageBackend", NOT the specific NIXL backend type string
# ("SPDK_NVMe_KV") that first-run guess used. Both instances came up HEALTHY
# with the wrong value too (store_location resolution isn't checked at
# startup — the earlier guess would have silently no-op'd on first real
# STORE/RETRIEVE, matching this track's established "successful zero-byte
# store" failure mode — see README's Known Gap history). Grep a fresh
# container's log for "Created backend:" to re-confirm if this ever changes.
cat > "${CONFIG_FILE}" <<EOF
local_cpu: False
max_local_cpu_size: ${AIC_NIXL_STAGING_GB}
remote_serde: NULL
${ROLE_LOCATION_KEY}: ${ROLE_LOCATION_VAL}
nixl_buffer_device: "cpu"
extra_config:
  enable_nixl_storage: true
  nixl_backend: "SPDK_NVMe_KV"
  nixl_pool_size: ${AIC_SPDK_KV_POOL}
  nixl_backend_params:
    trid: "${AIC_SPDK_KV_TRID}"
    kv_slot_offset: "${AIC_SPDK_KV_SLOT_OFFSET}"
EOF
echo "  config: ${CONFIG_FILE}"
cat "${CONFIG_FILE}"

# ── Step 3: launch vLLM (LMCacheConnectorV1 in-process) ──────────────────────
echo ""
echo "=== Step 3: docker run ==="
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

CONTEXT_ARGS=()
[ -n "${MAX_MODEL_LEN}" ] && CONTEXT_ARGS+=(--max-model-len "${MAX_MODEL_LEN}")
[ -n "${HF_OVERRIDES}" ] && CONTEXT_ARGS+=(--hf-overrides "${HF_OVERRIDES}")

KV_TRANSFER_ARG="{\"kv_connector\":\"LMCacheConnectorV1\",\"kv_role\":\"${KV_ROLE}\"}"

docker run -d --name "${CONTAINER_NAME}" \
    --label "compose_project=${COMPOSE_PROJECT}" \
    --network host \
    --cap-add CAP_SYS_ADMIN --cap-add SYS_PTRACE --cap-add IPC_LOCK \
    --security-opt seccomp:unconfined \
    --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 \
    --shm-size 64gb \
    --device /dev/kfd --device /dev/dri \
    -v /dev/hugepages:/dev/hugepages \
    -v "${HF_HOME}:/root/.cache/huggingface" \
    -v "${CONFIG_FILE}:/etc/lmcache/config.yaml:ro" \
    -v "${ROCM_AIC_DIR}/logs/pd-${PD_ROLE}:/var/log/aic" \
    -e HF_TOKEN="${HF_TOKEN}" \
    -e ROCR_VISIBLE_DEVICES="${GPU}" \
    -e LMCACHE_CONFIG_FILE=/etc/lmcache/config.yaml \
    -e PYTHONHASHSEED=123 \
    -e VLLM_ENABLE_V1_MULTIPROCESSING=1 \
    -e VLLM_WORKER_MULTIPROC_METHOD=spawn \
    --entrypoint vllm \
    "${IMAGE_REF}" \
    serve "${MODEL}" \
    --port "${PORT}" \
    --tensor-parallel-size "${TENSOR_PARALLEL_SIZE}" \
    --dtype "${DTYPE}" \
    --enforce-eager \
    "${CONTEXT_ARGS[@]}" \
    --kv-transfer-config "${KV_TRANSFER_ARG}"

# ── Step 4: wait for health ───────────────────────────────────────────────────
echo ""
echo "=== Step 4: waiting for vLLM health ==="
for i in $(seq 1 120); do
    sleep 10
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && \
        { echo "  READY after $((i*10))s"; break; }
    # Liveness via `docker inspect`, not `docker ps | grep -q`: grep -q exits at the first
    # match, so docker ps dies of SIGPIPE and pipefail reports the pipeline as failed,
    # aborting a healthy deploy with a false "container exited". Observed 2026-08-26 on
    # <SETUP3_DECODE_NODE>, ~20s before the server became ready. The old form also substring-matched,
    # so an unrelated container whose name merely contained this one satisfied the check.
    [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null)" = "true" ] || {
        echo "ERR: container exited"; docker logs "${CONTAINER_NAME}" 2>&1 | tail -80; exit 1; }
    [ "${i}" = "120" ] && { echo "ERR: health timeout after 1200s"
        docker logs "${CONTAINER_NAME}" 2>&1 | tail -80
        exit 1; }
done

# ── Step 5: deployment record ─────────────────────────────────────────────────
echo ""
echo "=== Step 5: deployment record ==="
DEPLOY_RECORD_CONTAINERS="${CONTAINER_NAME}" \
DEPLOY_RECORD_DEGRADED="${DEPLOY_DEGRADED}" \
deployment_record_write "${PORT}" \
    model="${MODEL}" \
    image="${IMAGE_REF}" \
    track="rocm-aic-pd-spdk" \
    pd_role="${PD_ROLE}" \
    backend="SPDK_NVMe_KV" \
    storage_target="${AIC_SPDK_KV_TRID}" \
    category="2 (RAM-backed, RAM-backed, no real device)" \
    tensor_parallel_size="${TENSOR_PARALLEL_SIZE}" \
    gpu="${GPU}" \
    slot_offset="${AIC_SPDK_KV_SLOT_OFFSET}" \
    compose_project="${COMPOSE_PROJECT}" || true

echo ""
echo "=== Deployed ==="
echo "  container  : ${CONTAINER_NAME}"
echo "  role       : ${PD_ROLE}"
echo "  endpoint   : http://127.0.0.1:${PORT}/v1"
echo "  stack      : vLLM -> LMCacheConnectorV1 (in-process) -> NixlStorageBackend -> SPDK_NVMe_KV -> ${AIC_SPDK_KV_TRID}"
echo "  NOTE       : RAM-backed bdev_kvmalloc target — category (2), not a real-device measurement"
echo "  NOTE       : NOVEL/UNVERIFIED combination — see this script's header. Verify on <SETUP4_TARGET_NODE> via"
echo "               'python3 \${SPDK_SRC}/scripts/rpc.py nvmf_get_stats' completed_nvme_io before"
echo "               trusting any output, and check this container's log for the actual registered"
echo "               store_location/retrieve_locations backend name if requests fail."
