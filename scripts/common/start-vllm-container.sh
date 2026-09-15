#!/usr/bin/env bash
# start-vllm-container.sh — launch vLLM inside the rocm-aic container image.
#
# This is the CONTAINER equivalent of start-vllm.sh (the from-source
# launcher): same job (bring up one role's vLLM server with the P/D direct
# NIXL leg wired in), different runtime. It does NOT share start-vllm.sh's
# LMCache/storage-leg machinery (gen-lmcache-config.sh,
# 25-validate-lmcache-config.sh, setup_nixl_kv_env, the NVMe-oF target
# reachability gate) — the invocation this script reproduces runs a plain
# NixlConnector with kv_buffer_device=cpu, no LMCache composition, no
# storage-leg NIXL plugin. If this cluster later needs the container path to
# ALSO carry the storage-leg reuse tier, that is new work on top of this
# file, not something quietly assumed here.
#
# Reproduces, faithfully, the exact `docker run` invocation proven working on
# live hardware as of 2026-09-15 (SMC1 prefill / SMC2 decode), parameterising
# only the role-dependent bits: container name, port, kv_role, the NIXL side
# channel's host/port, and this host's own routable IP.
#
# Node:          SMC1 (prefill) or SMC2 (decode), selected by $1. This script
#                does not itself pin the host (no require_host) — mirrors
#                start-vllm.sh, which leaves that to its caller
#                (scripts/{prefill,decode}/03-start-*.sh); a future
#                container-mode wrapper script is expected to do the same.
# Prerequisites: docker; VLLM_IMAGE (default rocm-aic:latest) already loaded
#                locally; the model weights already downloaded under
#                HF_HOST_DIR; scripts/common/patch-vllm-nixl-pkg.sh already
#                run once for VLLM_IMAGE (see the guard below for why).
# Next step:     scripts/verify/50-verify-pd-direct.sh once both roles are
#                up — see the note at the end of this script for why a 200
#                from /health is not proof KV is actually transferring.
#
# usage: start-vllm-container.sh <prefill|decode>

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLE="${1:-}"
case "${ROLE}" in
    prefill) PORT="${PREFILL_PORT}"; KV_ROLE="kv_producer" ;;
    decode)  PORT="${DECODE_PORT}";  KV_ROLE="kv_consumer" ;;
    *) die "start-vllm-container.sh: role must be prefill|decode, got" \
           " '${ROLE:-<empty>}' (usage: start-vllm-container.sh <prefill|decode>)" ;;
esac

CONTAINER_NAME="vllm-pd-${ROLE}"

step "Starting vLLM container (role=${ROLE}, kv_role=${KV_ROLE}, port=${PORT}, container=${CONTAINER_NAME})"
banner_config

require_cmd docker python3 curl

# ─────────────────────────────────────────────────────────────────────────────
# amdgpu autoload override — see ensure_amdgpu_loaded()'s comment in lib.sh.
# Both compute nodes boot with modprobe.blacklist=amdgpu on the kernel
# cmdline, and that flag only suppresses AUTOload; it does not survive a
# reboot on its own, so a GPU node that rebooted since its last run has zero
# usable GPUs until something explicitly modprobes amdgpu. `docker run
# --device /dev/kfd` on a host where amdgpu never got reloaded would just
# fail deep inside the container with a device-not-found error instead of
# the specific, actionable message ensure_amdgpu_loaded gives.
# ─────────────────────────────────────────────────────────────────────────────
ensure_amdgpu_loaded

# ─────────────────────────────────────────────────────────────────────────────
# UCX transport selection for the compute-leg (P<->D) NIXL side channel.
#
# LOAD-BEARING, not advisory. setup_ucx_env now `die`s outright if it cannot
# resolve a compute-leg interface for this role, specifically because the
# previous behavior — falling through to UCX's own autodetection when
# UCX_NET_DEVICES was left unset — makes UCX advertise the FIRST TCP-capable
# device it enumerates in its worker address. On this cluster that is a
# fabric NIC (30.1.1.1) that the peer node has no route to. That failure
# does not surface here, on this host, at launch: it surfaces on the OTHER
# host, in loadRemoteMD(), as NIXL_ERR_BACKEND, only after ~133s blocked in
# connect(). Passing the resolved UCX_NET_DEVICES/UCX_TLS into the container
# explicitly via -e (below), rather than letting the containerized UCX guess
# on its own, is what prevents that two-minute stall-then-500. Full
# writeup: setup_ucx_env()'s comment in lib.sh.
# ─────────────────────────────────────────────────────────────────────────────
setup_ucx_env "${ROLE}"

# ─────────────────────────────────────────────────────────────────────────────
# NIXL side channel (F2) + this host's own routable IP.
#
# setup_pd_env resolves and validates VLLM_NIXL_SIDE_CHANNEL_HOST (refusing
# loopback/empty rather than letting vLLM fall back to its own loopback
# default — see that function's comment in lib.sh for why that failure is
# otherwise invisible until the PEER tries to connect, long after this
# container looked healthy) and VLLM_NIXL_SIDE_CHANNEL_PORT (cluster.env's
# NIXL_SIDE_CHANNEL_PORT_PREFILL/_DECODE, 5600/5601). The resolved host is
# reused below as OWN_IP for kv-transfer-config's
# kv_connector_extra_config.hostname: the side channel and the connector's
# handoff-metadata listener are two different ports on the SAME address, so
# there is exactly one place that needs to answer "which IP is this host, as
# seen by the peer" and this is it.
# ─────────────────────────────────────────────────────────────────────────────
setup_pd_env "${ROLE}"
OWN_IP="${VLLM_NIXL_SIDE_CHANNEL_HOST}"

# NixlConnector's own handoff-metadata listener port (kv_connector_extra_
# config.port below). Distinct from the NIXL side-channel port above
# (5600/5601, per role, cluster.env) — this is a second, separate listener
# the connector itself opens. Hardcoded because cluster.env has no
# equivalent variable for it yet, and because the proven invocation uses
# the SAME value (14579) on both roles, unlike the side-channel port which
# is per-role.
NIXL_KV_CONNECTOR_PORT="${NIXL_KV_CONNECTOR_PORT:-14579}"

# ─────────────────────────────────────────────────────────────────────────────
# Guard: the image must already be present locally.
#
# `docker run` on a missing image tries to pull it, which on a host with no
# registry configured for a private tag like rocm-aic:latest either fails
# with a generic "not found" deep inside docker's own error path, or — worse
# — silently resolves to an unrelated public image sharing the same tag if
# one happens to exist reachable. Checking `docker image inspect` first
# turns that into one specific, actionable message before anything else in
# this script runs.
# ─────────────────────────────────────────────────────────────────────────────
VLLM_IMAGE="${VLLM_IMAGE:-rocm-aic:latest}"
docker image inspect "${VLLM_IMAGE}" >/dev/null 2>&1 \
    || die "image '${VLLM_IMAGE}' not found locally (docker image inspect" \
           " failed). Build or load it first — do not rely on 'docker run'" \
           " to pull it; there is no guarantee a bare pull would fetch the" \
           " right image rather than fail outright or silently resolve to" \
           " an unrelated public image with the same tag. Override with" \
           " VLLM_IMAGE if the image is tagged differently on this host."

# ─────────────────────────────────────────────────────────────────────────────
# Guard: the model weights must already be on disk.
#
# HF_HOST_DIR is bind-mounted whole (read-only) as /hf inside the container;
# MODEL_DIR_NAME is the snapshot subdirectory --model resolves against
# inside that mount, derived from cluster.env's MODEL by stripping the
# "org/" prefix (Qwen/Qwen2.5-72B-Instruct -> Qwen2.5-72B-Instruct) to match
# how an operator's download actually lays weights out on disk. If the
# subdirectory doesn't exist, the bind mount itself still succeeds (mounting
# the PARENT directory always works) and the missing model only surfaces
# once vLLM tries to load it, deep inside the container, after camera-ready
# startup logging has already scrolled past. Checking on the host first
# turns that into an immediate, specific failure.
# ─────────────────────────────────────────────────────────────────────────────
HF_HOST_DIR="${HF_HOST_DIR:-/var/tmp/hf}"
MODEL_DIR_NAME="${MODEL_DIR_NAME:-${MODEL##*/}}"
MODEL_HOST_PATH="${MODEL_HOST_PATH:-${HF_HOST_DIR}/${MODEL_DIR_NAME}}"
MODEL_CONTAINER_PATH="/hf/${MODEL_DIR_NAME}"

[ -d "${MODEL_HOST_PATH}" ] \
    || die "model directory '${MODEL_HOST_PATH}' does not exist on this" \
           " host. Download the weights there first, or override" \
           " HF_HOST_DIR/MODEL_DIR_NAME/MODEL_HOST_PATH to point at where" \
           " they actually live. Refusing to start: the bind mount" \
           " (-v ${HF_HOST_DIR}:/hf:ro) would still succeed with this" \
           " subdirectory missing, and the failure would only surface deep" \
           " inside the container when vLLM tries to load '${MODEL_CONTAINER_PATH}'."

# ─────────────────────────────────────────────────────────────────────────────
# Guard: the NIXL package-selection patch must already be generated.
#
# vLLM picks its NIXL python package by PLATFORM, not by what is actually
# installed: on ROCm it hardcodes a dependency on a package named `rixl`.
# The rocm-aic image instead ships `nixl` (built with the ROCm patches) —
# a working, ROCm-correct install that vLLM's platform check refuses to
# even look for. Without the patch, the worker fails with "NIXL is not
# available" only AFTER weights have already loaded, which on an 8x MI300X
# TP=8 launch is a slow and confusing way to discover a missing import.
# scripts/common/patch-vllm-nixl-pkg.sh generates the patched file by
# extracting nixl_utils.py from VLLM_IMAGE, rewriting its package-selection
# logic to probe for whichever package is actually installed, and verifying
# the result compiles — see that script's header for the full case for why
# it patches at launch rather than vendoring a copy. This guard only checks
# the patch exists; it does not regenerate it, so a patch generated against
# an OLDER build of VLLM_IMAGE is not automatically caught here — re-run
# patch-vllm-nixl-pkg.sh after rebuilding/repulling the image.
# ─────────────────────────────────────────────────────────────────────────────
NIXL_PATCH_FILE="${NIXL_PATCH_FILE:-/opt/kvstack/vllm-patch/nixl_utils.py}"
NIXL_PATCH_CONTAINER_PATH="/usr/local/lib/python3.12/dist-packages/vllm/distributed/nixl_utils.py"

[ -f "${NIXL_PATCH_FILE}" ] \
    || die "NIXL package-selection patch not found at '${NIXL_PATCH_FILE}'." \
           " Generate it first:" \
           " scripts/common/patch-vllm-nixl-pkg.sh ${VLLM_IMAGE}" \
           " Without it, vLLM on ROCm hardcodes a dependency on a package" \
           " named 'rixl' instead of looking for the 'nixl' package this" \
           " image actually ships, and the worker fails with 'NIXL is not" \
           " available' only after weights have already loaded — see that" \
           " script's header comment for the full explanation."

# ─────────────────────────────────────────────────────────────────────────────
# kv-transfer-config — plain NixlConnector, no MultiConnector/LMCache
# composition (see this script's header for why: that is
# gen-kv-transfer-config.sh's job for the from-source launcher, and this
# script deliberately does not share it). kv_buffer_device=cpu matches the
# proven invocation; hostname/port here are the connector's OWN
# handoff-metadata listener, distinct from the NIXL side channel above.
# ─────────────────────────────────────────────────────────────────────────────
KV_TRANSFER_CONFIG="$(KV_ROLE="${KV_ROLE}" OWN_IP="${OWN_IP}" \
    NIXL_KV_CONNECTOR_PORT="${NIXL_KV_CONNECTOR_PORT}" python3 -c '
import json, os
config = {
    "kv_connector": "NixlConnector",
    "kv_role": os.environ["KV_ROLE"],
    "kv_buffer_device": "cpu",
    "kv_connector_extra_config": {
        "hostname": os.environ["OWN_IP"],
        "port": int(os.environ["NIXL_KV_CONNECTOR_PORT"]),
    },
}
print(json.dumps(config))
')"
printf '%s\n' "${KV_TRANSFER_CONFIG}" | python3 -m json.tool >/dev/null \
    || die "generated --kv-transfer-config is not valid JSON: ${KV_TRANSFER_CONFIG}"

# Model weight dtype — hardcoded, not a cluster.env variable: MAX_MODEL_LEN,
# TP_SIZE, GPU_MEM_UTIL, SERVED_MODEL_NAME below all come from cluster.env,
# but cluster.env has no MODEL_DTYPE knob (KV_CACHE_DTYPE is a different
# thing — it governs the KV cache tensors, not the model weights this flag
# sizes). bfloat16 matches the proven invocation and this model's native
# precision.
DTYPE="${VLLM_DTYPE:-bfloat16}"

log "image=${VLLM_IMAGE} model=${MODEL_CONTAINER_PATH} served_model_name=${SERVED_MODEL_NAME}"
log "tp_size=${TP_SIZE} max_model_len=${MAX_MODEL_LEN} gpu_mem_util=${GPU_MEM_UTIL} dtype=${DTYPE}"
log "kv-transfer-config: ${KV_TRANSFER_CONFIG}"
log "NIXL side channel: ${VLLM_NIXL_SIDE_CHANNEL_HOST}:${VLLM_NIXL_SIDE_CHANNEL_PORT}"
log "UCX: UCX_NET_DEVICES=${UCX_NET_DEVICES} UCX_TLS=${UCX_TLS}"

# ─────────────────────────────────────────────────────────────────────────────
# Remove any pre-existing container of the same name first. `docker run
# --name` on a name already in use (even a stopped/exited container) fails
# outright rather than replacing it, which would abort this script AFTER
# all the guards above already passed — remove it up front instead.
# ─────────────────────────────────────────────────────────────────────────────
if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    info "removing pre-existing container '${CONTAINER_NAME}'"
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# Launch. This is the exact invocation proven working on live hardware
# 2026-09-15, with only the role-dependent bits above substituted in.
#
# NIXL_BACKEND=UCX selects the transport NIXL uses for the direct GPU-to-GPU
# transfer this connector performs — do not confuse with cluster.env's
# KV_BACKEND, which selects the unrelated storage-leg plugin
# (SPDK_NVMe_KV|XNVME_KV) that this script's invocation does not use at all.
#
# VLLM_ROCM_USE_AITER=0 here, NOT =1: start-vllm.sh (the from-source
# launcher) sets AITER=1, but that is a different runtime with a different
# build of the AITER kernels. This is not a typo — 0 is what the proven
# container invocation uses, and the two launchers are not required to
# agree on this setting.
#
# PYTORCH_HIP_ALLOC_CONF=expandable_segments:False is docs/HANDOFF.md §7
# invariant 3: without it, vLLM's KV tensors cannot be exported over HIP
# IPC and registration fails.
# ─────────────────────────────────────────────────────────────────────────────
DOCKER_ARGS=(
    run -d --name "${CONTAINER_NAME}"
    --device /dev/kfd --device /dev/dri --group-add video
    --network host --ipc=host --security-opt seccomp=unconfined
    --cap-add SYS_ADMIN --cap-add IPC_LOCK
    -v "${HF_HOST_DIR}:/hf:ro"
    -v "${NIXL_PATCH_FILE}:${NIXL_PATCH_CONTAINER_PATH}:ro"
    -e "TOKENIZERS_PARALLELISM=false"
    -e "PYTORCH_HIP_ALLOC_CONF=expandable_segments:False"
    -e "NCCL_CUMEM_ENABLE=${NCCL_CUMEM_ENABLE}"
    -e "NIXL_BACKEND=UCX"
    -e "VLLM_ROCM_USE_AITER=0"
    -e "VLLM_NIXL_SIDE_CHANNEL_HOST=${VLLM_NIXL_SIDE_CHANNEL_HOST}"
    -e "VLLM_NIXL_SIDE_CHANNEL_PORT=${VLLM_NIXL_SIDE_CHANNEL_PORT}"
    -e "UCX_NET_DEVICES=${UCX_NET_DEVICES}"
    -e "UCX_TLS=${UCX_TLS}"
    "${VLLM_IMAGE}"
    --model "${MODEL_CONTAINER_PATH}"
    --served-model-name "${SERVED_MODEL_NAME}"
    --port "${PORT}" --host 0.0.0.0
    --tensor-parallel-size "${TP_SIZE}" --dtype "${DTYPE}"
    --max-model-len "${MAX_MODEL_LEN}" --gpu-memory-utilization "${GPU_MEM_UTIL}"
    --kv-transfer-config "${KV_TRANSFER_CONFIG}"
)
docker "${DOCKER_ARGS[@]}" >/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# Wait for the engine to answer /health. Model load on 8x MI300X (TP=8,
# weight sharding + warmup + HIP-graph capture) routinely takes many
# minutes — 1800s is a floor, matching start-vllm.sh's own timeout, not a
# target; raise it if MODEL is larger or GPU_MEM_UTIL forces extra
# re-capture passes.
# ─────────────────────────────────────────────────────────────────────────────
if wait_for_http "http://127.0.0.1:${PORT}/health" 1800; then
    ok "vllm-${ROLE} container healthy on port ${PORT}"
else
    err "vllm-${ROLE} container did not become healthy within 1800s —" \
        " last 40 lines of 'docker logs ${CONTAINER_NAME}':"
    docker logs --tail 40 "${CONTAINER_NAME}" >&2 2>&1 || true
    die "startup failed; see the log lines above, or run" \
        " 'docker logs ${CONTAINER_NAME}' for the full log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# /health returning 200 proves the engine is serving. It does NOT prove KV
# is transferring between prefill and decode — a NixlConnector that never
# successfully wires up the direct leg still serves every request
# correctly, just by recomputing everything, and looks identical to a
# correctly wired deployment right up until someone checks the metrics.
# Run scripts/verify/50-verify-pd-direct.sh next. The acceptance signal
# there: decode's "Avg prompt throughput" collapsing toward 0 while
# prefill's does not, and decode's "External prefix cache hit rate" being
# non-zero — both must hold, not just one.
# ─────────────────────────────────────────────────────────────────────────────
log "test with:"
log "  curl -s http://127.0.0.1:${PORT}/v1/models | python3 -m json.tool"
log "next: scripts/verify/50-verify-pd-direct.sh — a 200 from /health only" \
    " proves the engine serves, not that KV is transferring."
