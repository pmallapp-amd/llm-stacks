#!/usr/bin/env bash
# deploy-spdk.sh — bring up rocm-aic-spdk: AMD's official rocm-aic stack
# (vLLM v0.26.0 + LMCache v0.5.3 + NIXL v1.3.2), unmodified, with our own
# SPDK_NVMe_KV NIXL plugin (../nixl/core/nvme-kv-plugin/) compiled into its image
# and wired in as an extra `lmcache-spdk` compose service (see
# ./docker-compose.storage.yml) pointed at the RAM-backed bdev_kvmalloc SPDK
# TCP target on host <SETUP3_TARGET_NODE> (CIRRASCALE cluster, <SETUP3_TARGET_NODE_IP>:4420 — see this
# repo's memory handoff_2026_08_18_3node_storage_target).
#
# STATUS: staged, never run. This script has not been executed against a running
# rocm-aic image because the image doesn't exist yet — build.sh (a sibling script,
# not yet run either) vendors rocm-aic, applies the LMCache l2-adapter patch
# (patches/lmcache/15-*.patch) and the Dockerfile plugin-build patch
# (patches/dockerfile/0003-*.patch, owned by a parallel task), then `make build`s
# the image. Every path/flag/env-var below was derived from reading
# ROCm/rocm-aic @ bb386562 (2026-08-14), this repo's own plugin/LMCache sources, and
# the sibling patch/README already written for this track — not from a real run.
# Treat the first invocation as bring-up, not a benchmark: watch it fail, fix the
# actual error, don't assume the numbers mean anything until a correctness check
# (see stack/tracks/lmcache/README.md's "Known bug" section — this rocm-aic LMCache
# fork is a DIFFERENT L2-adapter architecture than that track's, so re-check RETRIEVE
# behavior here rather than assuming the same bug transfers over) has passed.
#
# Category (2): <SETUP3_TARGET_NODE> has no real real NVMe-KV device
# PCIe function (those devices are configured as Ethernet/RDMA NICs,
# 1dd8:1002, not the KV command-set NVMe function) — this is a workaround for
# hardware unavailability, never a device measurement. See ./deploy-xnvme.sh for the
# real-device variant, and stack/tracks/rocm-aic/README.md's build order (verify this
# one clean before using that one against real hardware).
#
# Contract (bench/tracks.registry's header): accepts MODEL=/PORT=, serves an
# OpenAI-compatible API + /health at http://127.0.0.1:${PORT}/v1, exits nonzero
# with a clear message on a missing prerequisite, safe to re-run against an
# already-healthy endpoint.
#
# Prerequisites (run in order — none have been run yet):
#   1. bash ./vendor.sh                    — clone rocm-aic to the pinned commit
#   2. bash ./build.sh                     — apply patches/, `make build` the image
#      (needs stack/foundation/spdk-kv/'s 4 spdk-host patches + a source SPDK build,
#      and ../nixl/core/nvme-kv-plugin/ — see build.sh's own header once written)
#   3. A SPDK_NVMe_KV target reachable at AIC_SPDK_KV_TRID below — start one with
#      LISTEN_ADDR=<routable-ip> bash ../../foundation/spdk-kv/start-kv-target.sh
#      on <SETUP3_TARGET_NODE> (or wherever), or reuse the one from
#      handoff_2026_08_18_3node_storage_target if it's still up.
#
# Override env:
#   MODEL=<hf-name>            (default: TinyLlama/TinyLlama-1.1B-Chat-v1.0 — same
#                                 fast-iteration default every other track in this
#                                 repo uses for a first correctness pass, not
#                                 rocm-aic's own inline docker-compose.yml fallback
#                                 of openai/gpt-oss-120b, which is a 120B model and
#                                 a poor choice for an unvalidated bring-up)
#   PORT=<n>                   (default: 8300 — avoids colliding with every other
#                                 track's live port: 8000/8001/8100/8200/9000/9100)
#   GPU=<n>                    ROCR_VISIBLE_DEVICES for both vllm and lmcache-spdk
#                                 (default: 0)
#   TENSOR_PARALLEL_SIZE=<n>   (default: 1)
#   ROCM_AIC_DIR=<path>        vendored rocm-aic checkout (default:
#                                 ${SCRIPT_DIR}/vendor/rocm-aic — see vendor.sh)
#   ROCM_ARCH=<gfxNNNN>        (default: auto-detected by rocm-aic's own Makefile
#                                 logic; pass through explicitly if detection fails)
#   HF_TOKEN=<token>           HuggingFace access token (required)
#   HF_HOME=<path>             (default: ~/.cache/huggingface)
#   AIC_SPDK_KV_TRID=<trid>    NVMe-oF transport ID of the SPDK target (default:
#                                 <SETUP3_TARGET_NODE>'s TCP listener — see
#                                 docker-compose.storage.yml's header)
#   LMCACHE_L1_SIZE_GB=<n>     (default: 20)
#   MAX_MODEL_LEN=<n>          vLLM --max-model-len, forwarded to the vendored
#                                 compose file as VLM_MAX_MODEL_LEN (default:
#                                 unset — compose then applies its own 32768).
#                                 READ THIS BEFORE USING THE DEFAULT MODEL: that
#                                 compose default is sized for large models and
#                                 COLLIDES with this script's own default model.
#                                 TinyLlama has max_position_embeddings=2048, so
#                                 vLLM refuses to start with a pydantic
#                                 ValidationError ("User-specified max_model_len
#                                 (32768) is greater than the derived
#                                 max_model_len"). Pass MAX_MODEL_LEN=2048 for
#                                 TinyLlama. Do NOT reach for
#                                 VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 instead: it
#                                 silences the check rather than fixing it, and
#                                 TinyLlama uses RoPE, so positions past 2048
#                                 produce nan — a server that runs and is wrong,
#                                 which is worse than one that refuses to start.
#                                 (This knob existed in the sibling
#                                 deploy-pd-spdk.sh but was missing here; that
#                                 asymmetry was the actual gap.)
#   COMPOSE_PROJECT=<name>     (default: rocm-aic-spdk — keeps this stack's
#                                 containers/networks separate from a plain `make up`
#                                 or the rocm-aic-xnvme variant run on the same host)
#   DEPLOY_DEGRADED=<list>     comma-separated degraded-config markers passed to
#                                 deployment_record_write (default:
#                                 "unvalidated-first-run" — see the note below;
#                                 set to empty once a clean, correctness-checked run
#                                 is confirmed and you want subsequent benchmark
#                                 stamps to stop flagging it)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../../.." && pwd)

# shellcheck source=../../../bench/lib/deployment.sh
source "${REPO_ROOT}/bench/lib/deployment.sh"

MODEL=${MODEL:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}
PORT=${PORT:-8300}
GPU=${GPU:-0}
TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE:-1}
ROCM_AIC_DIR=${ROCM_AIC_DIR:-${SCRIPT_DIR}/vendor/rocm-aic}
HF_HOME=${HF_HOME:-$HOME/.cache/huggingface}
AIC_SPDK_KV_TRID=${AIC_SPDK_KV_TRID:-"trtype:TCP adrfam:IPv4 traddr:<SETUP3_TARGET_NODE_IP> trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0"}
LMCACHE_L1_SIZE_GB=${LMCACHE_L1_SIZE_GB:-20}
# Forwarded to the vendored compose file's VLM_MAX_MODEL_LEN. Left unset by
# default so compose's own default still governs for callers who want it; see
# the header for why that default breaks this script's default model.
MAX_MODEL_LEN=${MAX_MODEL_LEN:-}
# NixlObjPool (OBJ-family backends: SPDK_NVMe_KV/XNVME_KV) registers ONE
# storage object per raw L1 page (l1_align_bytes -- empirically 4096 B for
# TinyLlama's fp8 KV layout, confirmed 2026-08-18), not one per KV chunk, so
# a pool sized for "one slot per chunk" (this repo's old static default of
# 64) exhausts on the first multi-page store, and NixlStorageAgent's own
# "nothing to store" fast-path reports that as a *successful* zero-byte
# store with no warning -- see README's "Known gap" section.
# 2,000,000 does NOT scale with LMCACHE_L1_SIZE_GB (matching L1's default
# 20 GiB at 4096 B/page would need 5,242,880) -- init_storage_handlers_object()
# registering that many NIXL OBJ descriptors was empirically confirmed
# (2026-08-18) to blow up non-linearly: 2,000,000 came up healthy in ~90s
# and confirmed real STORE traffic on <SETUP3_TARGET_NODE>; 5,242,880 was still spinning
# at 100%+ CPU with zero forward progress after 10+ minutes. Treat this as
# a tested ceiling, not a capacity-matched value -- override AIC_SPDK_KV_POOL
# directly (and re-verify startup time) if you raise it or your model's
# l1_align_bytes differs from the 4096 B assumption here.
AIC_SPDK_KV_POOL=${AIC_SPDK_KV_POOL:-2000000}
COMPOSE_PROJECT=${COMPOSE_PROJECT:-rocm-aic-spdk}
# See header: not a real "degraded performance" flag in the usual sense (no RCCL
# workaround, no host-staging) — repurposed per this track's own bring-up
# instructions to flag "this deployment has not been correctness-validated yet"
# in the same DEGRADED slot the preflight gate already knows how to surface.
DEPLOY_DEGRADED=${DEPLOY_DEGRADED-unvalidated-first-run}
IMAGE_TAG_DEFAULT="rocm-aic:latest"

STORAGE_COMPOSE="${SCRIPT_DIR}/docker-compose.storage.yml"
PLUGIN_COMPOSE="${SCRIPT_DIR}/docker-compose.plugin-override.yml"
CONTAINER_VLLM="aic-vllm-gpu${GPU}"
CONTAINER_LMCACHE="aic-lmcache-spdk"

# AIC_SPDK_PLUGIN_SO — optional: run a locally-built SPDK_NVMe_KV plugin instead
# of the image's baked-in copy. Unset (the default) means the image's own plugin
# is used and nothing about the compose invocation changes.
#
# Validated as a REGULAR FILE, not merely "exists": docker turns a bind mount of
# a nonexistent host path into an empty directory, which would shadow the image's
# plugin and surface only as NIXL's generic "backend not found". Refusing here is
# the difference between a clear error and a debugging session.
AIC_SPDK_PLUGIN_SO=${AIC_SPDK_PLUGIN_SO:-}
PLUGIN_COMPOSE_ARGS=()
if [ -n "${AIC_SPDK_PLUGIN_SO}" ]; then
    [ -e "${AIC_SPDK_PLUGIN_SO}" ] || {
        echo "ERR: AIC_SPDK_PLUGIN_SO=${AIC_SPDK_PLUGIN_SO} does not exist."
        echo "     Refusing: docker would bind-mount this as an empty DIRECTORY over"
        echo "     the image's plugin, and the only symptom would be NIXL reporting"
        echo "     'backend not found'."
        exit 1; }
    [ -f "${AIC_SPDK_PLUGIN_SO}" ] || {
        echo "ERR: AIC_SPDK_PLUGIN_SO=${AIC_SPDK_PLUGIN_SO} is not a regular file."
        echo "     It must be the .so itself, not the directory containing it."
        exit 1; }
    # Absolute path: compose resolves relative bind sources against the compose
    # file's directory (the vendored rocm-aic/docker tree), not the caller's cwd.
    case "${AIC_SPDK_PLUGIN_SO}" in
        /*) : ;;
        *) AIC_SPDK_PLUGIN_SO=$(cd "$(dirname "${AIC_SPDK_PLUGIN_SO}")" && pwd)/$(basename "${AIC_SPDK_PLUGIN_SO}") ;;
    esac
    [ -f "${PLUGIN_COMPOSE}" ] || {
        echo "ERR: ${PLUGIN_COMPOSE} not found (should ship with this repo)"; exit 1; }
    PLUGIN_COMPOSE_ARGS=(-f "${PLUGIN_COMPOSE}")
fi

# ── Preflight checks ──────────────────────────────────────────────────────────
[ -e /dev/kfd ] || { echo "ERR: /dev/kfd absent — run: modprobe amdgpu"; exit 1; }
[ -d "${ROCM_AIC_DIR}/docker" ] || {
    echo "ERR: ${ROCM_AIC_DIR}/docker not found — run ./vendor.sh first"; exit 1; }
[ -f "${STORAGE_COMPOSE}" ] || {
    echo "ERR: ${STORAGE_COMPOSE} not found (should ship with this repo)"; exit 1; }
# HF_TOKEN guards against a gated model failing to download halfway through
# bring-up. It is genuinely required for gated weights — but the default model
# here (TinyLlama) is public, and on a host where it is already in the HF cache
# no authenticated call happens at all. `HF_TOKEN=none` is the explicit way to
# say that, so the situation is recorded in the deployment record rather than
# smuggled in as a fake-looking token string.
[ -n "${HF_TOKEN:-}" ] || {
    echo "ERR: HF_TOKEN not set (HuggingFace access token required)."
    echo "     If the model is public and already cached on this host, pass"
    echo "     HF_TOKEN=none to state that explicitly."
    exit 1; }
if [ "${HF_TOKEN}" = "none" ]; then
    echo "NOTE: HF_TOKEN=none — no HuggingFace auth. Requires ${MODEL} to be"
    echo "      public or already present in ${HF_HOME}; a gated or uncached"
    echo "      model will fail during weight load, not here."
fi
docker image inspect "${IMAGE_REF:-${IMAGE_TAG_DEFAULT}}" >/dev/null 2>&1 || {
    echo "ERR: ${IMAGE_REF:-${IMAGE_TAG_DEFAULT}} not found — run ./build.sh first"
    echo "     (this builds rocm-aic + our SPDK_NVMe_KV plugin compiled in; see"
    echo "     stack/tracks/rocm-aic/README.md's build order)"
    exit 1
}

echo "deploy-spdk: rocm-aic + LMCache l2-adapter (SPDK_NVMe_KV, RAM-backed, category (2))"
echo "  model     : ${MODEL}"
echo "  port      : ${PORT}"
echo "  gpu       : ${GPU}"
echo "  tp        : ${TENSOR_PARALLEL_SIZE}"
echo "  max_len   : ${MAX_MODEL_LEN:-<compose default 32768>}"
echo "  trid      : ${AIC_SPDK_KV_TRID}"
echo "  rocm-aic  : ${ROCM_AIC_DIR}"
if [ -n "${AIC_SPDK_PLUGIN_SO}" ]; then
    echo "  plugin    : ${AIC_SPDK_PLUGIN_SO}"
    echo "              sha256 $(sha256sum "${AIC_SPDK_PLUGIN_SO}" | cut -d' ' -f1)"
    echo "              (OVERRIDE — mounted over the image's own copy, read-only)"
else
    echo "  plugin    : image built-in (no AIC_SPDK_PLUGIN_SO override)"
fi
echo ""

# ── Step 1: hugepages ─────────────────────────────────────────────────────────
echo "=== Step 1: hugepages ==="
NR_HUGE=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)
if [ "${NR_HUGE}" -lt 512 ]; then
    echo "  allocating 512 x 2MB hugepages..."
    echo 512 > /proc/sys/vm/nr_hugepages
fi
echo "  hugepages: $(cat /proc/sys/vm/nr_hugepages)"

# ── Step 2: host dirs the base compose file's bind mounts expect to exist ────
echo ""
echo "=== Step 2: prep dirs ==="
mkdir -p "${HF_HOME}/hub" "${HF_HOME}/datasets" "${HF_HOME}/vllm" \
    "${HF_HOME}/vllm_config" "${HF_HOME}/torch" "${HF_HOME}/torch_inductor" \
    "${ROCM_AIC_DIR}/logs/vllm" "${ROCM_AIC_DIR}/logs/lmcache-spdk"
echo "  HF_HOME    : ${HF_HOME}"
echo "  logs       : ${ROCM_AIC_DIR}/logs/{vllm,lmcache-spdk}"

# ── Step 3: bring up rocm-aic + lmcache-spdk via compose ─────────────────────
echo ""
echo "=== Step 3: docker compose up (--profile storage-spdk) ==="

# KV_TRANSFER_ARG must point vLLM's LMCacheMPConnector at THIS deployment's
# container name + port, not the Makefile's own default JSON (which hardcodes
# aic-lmcache:6555 — the base `lmcache` service this track deliberately bypasses).
LMCACHE_SPDK_PORT_VAL="${LMCACHE_SPDK_PORT:-6556}"
KV_TRANSFER_ARG_VAL="--kv-transfer-config '{\"kv_connector\":\"LMCacheMPConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"lmcache.mp.host\":\"tcp://${CONTAINER_LMCACHE}\",\"lmcache.mp.port\":${LMCACHE_SPDK_PORT_VAL}}}'"

(
    cd "${ROCM_AIC_DIR}/docker"
    HF_TOKEN="${HF_TOKEN}" HF_HOME="${HF_HOME}" \
    VLLM_MODEL="${MODEL}" GPU="${GPU}" PORT="${PORT}" \
    TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE}" \
    LMCACHE_L1_SIZE_GB="${LMCACHE_L1_SIZE_GB}" \
    LMCACHE_SPDK_PORT="${LMCACHE_SPDK_PORT_VAL}" \
    VLM_MAX_MODEL_LEN="${MAX_MODEL_LEN}" \
    AIC_SPDK_KV_TRID="${AIC_SPDK_KV_TRID}" \
    AIC_SPDK_KV_POOL="${AIC_SPDK_KV_POOL}" \
    AIC_SPDK_PLUGIN_SO="${AIC_SPDK_PLUGIN_SO}" \
    VLLM_IPC_MODE="service:${CONTAINER_LMCACHE#aic-}" \
    VLLM_PID_MODE="service:${CONTAINER_LMCACHE#aic-}" \
    KV_TRANSFER_ARG="${KV_TRANSFER_ARG_VAL}" \
    LOG="${ROCM_AIC_DIR}/logs" \
    docker compose -p "${COMPOSE_PROJECT}" \
        -f docker-compose.yml \
        -f "${STORAGE_COMPOSE}" \
        "${PLUGIN_COMPOSE_ARGS[@]}" \
        --profile storage-spdk up -d
)

# ── Step 4: wait for health ───────────────────────────────────────────────────
echo ""
echo "=== Step 4: waiting for vLLM health ==="
for i in $(seq 1 60); do
    sleep 5
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && \
        { echo "  READY after $((i*5))s"; break; }
    # Liveness via `docker inspect`, not `docker ps | grep -q`: grep -q exits at the first
    # match, so docker ps dies of SIGPIPE and pipefail reports the pipeline as failed,
    # aborting a healthy deploy with a false "container exited". Observed 2026-08-26 on
    # <SETUP3_DECODE_NODE>, ~20s before the server became ready. The old form also substring-matched,
    # so an unrelated container whose name merely contained this one satisfied the check.
    [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_VLLM}" 2>/dev/null)" = "true" ] || {
        echo "ERR: container exited"; docker logs "${CONTAINER_VLLM}" 2>&1 | tail -60; exit 1; }
    [ "${i}" = "60" ] && { echo "ERR: health timeout after 300s"
        docker logs "${CONTAINER_VLLM}" 2>&1 | tail -60
        docker logs "${CONTAINER_LMCACHE}" 2>&1 | tail -60
        exit 1; }
done

# ── Step 5: smoke test ────────────────────────────────────────────────────────
echo ""
echo "=== Step 5: smoke test ==="
RESP=$(curl -sf "http://127.0.0.1:${PORT}/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",
         \"prompt\":\"The rocm-aic stack routes KV-cache offload through\",
         \"max_tokens\":40,\"temperature\":0}")
echo "${RESP}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['text'])" \
    2>/dev/null || echo "${RESP}"

# ── Step 6: deployment record (server-side provenance) ───────────────────────
echo ""
echo "=== Step 6: deployment record ==="
DEPLOY_RECORD_CONTAINERS="${CONTAINER_VLLM} ${CONTAINER_LMCACHE}" \
DEPLOY_RECORD_DEGRADED="${DEPLOY_DEGRADED}" \
deployment_record_write "${PORT}" \
    model="${MODEL}" \
    image="${IMAGE_REF:-${IMAGE_TAG_DEFAULT}}" \
    track="rocm-aic-spdk" \
    backend="SPDK_NVMe_KV" \
    storage_target="${AIC_SPDK_KV_TRID}" \
    category="2 (RAM-backed, RAM-backed, no real device)" \
    tensor_parallel_size="${TENSOR_PARALLEL_SIZE}" \
    gpu="${GPU}" \
    lmcache_l1_size_gb="${LMCACHE_L1_SIZE_GB}" \
    kv_pool_size="${AIC_SPDK_KV_POOL}" \
    max_model_len="${MAX_MODEL_LEN:-32768 (compose default)}" \
    plugin_so="${AIC_SPDK_PLUGIN_SO:-image-builtin}" \
    plugin_sha256="$([ -n "${AIC_SPDK_PLUGIN_SO}" ] && sha256sum "${AIC_SPDK_PLUGIN_SO}" | cut -d' ' -f1 || echo "n/a (image built-in)")" \
    compose_project="${COMPOSE_PROJECT}" || true

echo ""
echo "=== Deployed ==="
echo "  containers : ${CONTAINER_VLLM}, ${CONTAINER_LMCACHE} (compose project ${COMPOSE_PROJECT})"
echo "  endpoint   : http://127.0.0.1:${PORT}/v1"
echo "  stack      : vLLM -> LMCacheMPConnector -> NixlStorageAgent l2-adapter -> SPDK_NVMe_KV -> ${AIC_SPDK_KV_TRID}"
echo "  NOTE       : RAM-backed bdev_kvmalloc target — category (2), not a real-device measurement"
echo "  NOTE       : STAGED/first-run — verify STORE via the target host's own"
echo "               'python3 \${SPDK_SRC}/scripts/rpc.py nvmf_get_stats' completed_nvme_io"
echo "               counter (NOT bdev_get_iostat) before trusting any number off this deploy,"
echo "               and explicitly check whether RETRIEVE fires (grep this container's log for"
echo "               'need to load: [1-9]' or a 'Retrieved' line) — this rocm-aic LMCache fork is"
echo "               a different l2-adapter architecture than stack/tracks/lmcache/'s, so its"
echo "               known RETRIEVE bug is not assumed to carry over, only worth re-checking."
