#!/usr/bin/env bash
# start-vllm.sh — shared body for launching the vLLM+LMCache server on either
# role. Not meant to be invoked directly by an operator — exec'd by
# scripts/prefill/03-start-prefill.sh and scripts/decode/03-start-decode.sh,
# each of which pins its own required host first.
#
# Node:          SMC1 (prefill) or SMC2 (decode), selected by $1.
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh; the LMCache MP
#                daemon already running on THIS node (scripts/common/
#                start-lmcache-daemon.sh); SMC3's NVMe-oF target already
#                listening on NVMF_TRSVCID. This script refuses to start
#                unless BOTH are reachable — see the wait_for_port gates
#                below.
# Next step:     scripts/proxy/start-proxy.sh once both roles are up.
#
# usage: start-vllm.sh <prefill|decode> [--skip-validate]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLE="${1:-}"
shift || true
SKIP_VALIDATE=0
for arg in "$@"; do
    case "${arg}" in
        --skip-validate) SKIP_VALIDATE=1 ;;
        *) die "unknown argument: ${arg}" ;;
    esac
done

case "${ROLE}" in
    prefill)
        PORT="${PREFILL_PORT}"
        KV_ROLE="kv_producer"
        ;;
    decode)
        PORT="${DECODE_PORT}"
        KV_ROLE="kv_consumer"
        ;;
    *) die "start-vllm.sh: role must be prefill|decode, got '${ROLE}'" ;;
esac

step "Starting vLLM (role=${ROLE}, kv_role=${KV_ROLE}, port=${PORT})"
banner_config

# shellcheck source=/dev/null
source "${STACK_ROOT}/etc/env.sh"

setup_nixl_kv_env "${ROLE}"

# The data-plane NIC (TCP mode) / UCX device (RDMA mode) for the P<->D side
# channel are per-role, per-node values pinned in cluster.env
# (PREFILL_DATA_IF/DECODE_DATA_IF for TCP,
# PREFILL_UCX_NET_DEVICES/DECODE_UCX_NET_DEVICES for RDMA — F3) — they
# cannot be safely re-autodetected here on every start, because a route to
# a specific peer can change if the host briefly has an alternate path
# (e.g. through a management NIC) during a network hiccup. setup_ucx_env
# looks these up itself, keyed by role.
setup_ucx_env "${ROLE}"

# NIXL side channel (F2): resolve/validate VLLM_NIXL_SIDE_CHANNEL_HOST/_PORT,
# refusing loopback/empty outright — see setup_pd_env()'s comment in lib.sh
# for why that failure mode is otherwise invisible until the PEER connects.
setup_pd_env "${ROLE}"

# RDMA device access preflight (F4): a no-op (logged) in TCP mode. In RDMA
# mode this is a HARD gate — without it, a permission problem on
# /dev/infiniband/uverbs* presents as vLLM hanging for ~90s (EngineCore
# compiling) before failing, rather than failing here, at t=0, with a
# specific cause.
require_rdma_access "${UCX_NET_DEVICES:-}"

# ─────────────────────────────────────────────────────────────────────────────
# Generate + validate the LMCache config for this role.
# ─────────────────────────────────────────────────────────────────────────────
LMCACHE_CFG="${STACK_ROOT}/etc/lmcache-${ROLE}.yaml"
"${REPO_ROOT}/scripts/common/gen-lmcache-config.sh" "${ROLE}" "${LMCACHE_CFG}"

if [ "${SKIP_VALIDATE}" -eq 1 ]; then
    warn "LMCache config validation SKIPPED (--skip-validate) — you are" \
         " trusting gen-lmcache-config.sh's assumptions with no proof the" \
         " installed LMCache actually accepts them. Only use this for" \
         " debugging the validator itself."
else
    "${REPO_ROOT}/scripts/common/25-validate-lmcache-config.sh" "${LMCACHE_CFG}" \
        || die "LMCache config validation failed for ${LMCACHE_CFG}." \
               " Fix the reported keys/backend-allowlist issue, or pass" \
               " --skip-validate to override (NOT recommended — see this" \
               " script's header comment on what that trades away)."
fi
export LMCACHE_CONFIG_FILE="${LMCACHE_CFG}"

# ─────────────────────────────────────────────────────────────────────────────
# Refuse to start unless the LMCache MP daemon is actually reachable.
#
# WHY this is a hard gate, not a warning: LMCacheMPConnector talks to the
# MP daemon over a ZMQ control channel at LMCACHE_MP_HOST:LMCACHE_MP_PORT
# (config/cluster.env) — a SEPARATE HOST PROCESS that nothing else in this
# stack spawns or checks for (HANDOFF §12.1: "MP mode needs a daemon and
# nothing spawns it"). If that daemon isn't up, vLLM does NOT fail to
# start: LMCacheMPConnector is one of two children inside MultiConnector,
# so the server starts fine, answers /health, and serves every request —
# just with the LMCache leg of the KV path silently absent. That failure
# mode is indistinguishable from "working" until someone benchmarks
# cross-node cache hit rate and finds the LMCache tier never engaged.
# Refusing to start is the only failure mode that can't be mistaken for
# success. LMCACHE_MP_HOST carries a ZMQ URL scheme (e.g. "tcp://
# 127.0.0.1") because that's what the client side needs; wait_for_port
# wants a bare host, so the scheme is stripped here the same way
# scripts/common/start-lmcache-daemon.sh strips it for the server's
# --host flag.
# ─────────────────────────────────────────────────────────────────────────────
_LMCACHE_MP_BIND_HOST="${LMCACHE_MP_HOST#tcp://}"
[ -n "${_LMCACHE_MP_BIND_HOST}" ] || die "LMCACHE_MP_HOST resolved to an" \
    " empty host after stripping 'tcp://' (raw value:" \
    " '${LMCACHE_MP_HOST}') — fix config/cluster.env's LMCACHE_MP_HOST."
info "checking LMCache MP daemon reachability: ${_LMCACHE_MP_BIND_HOST}:${LMCACHE_MP_PORT}"
if ! wait_for_port "${_LMCACHE_MP_BIND_HOST}" "${LMCACHE_MP_PORT}" 30; then
    die "LMCache MP daemon ${_LMCACHE_MP_BIND_HOST}:${LMCACHE_MP_PORT} is" \
        " not reachable after 30s. Refusing to start: a silently-absent" \
        " LMCache leg is the worst failure mode here (see this script's" \
        " comment above) because the server would otherwise start" \
        " successfully and LOOK like it works. Start the daemon first:" \
        " scripts/common/start-lmcache-daemon.sh"
fi
ok "LMCache MP daemon reachable"

# ─────────────────────────────────────────────────────────────────────────────
# Refuse to start unless the KV storage tier ALSO has a live path to the
# backing store. What "live path" means is backend-dependent — see the
# per-backend case below.
#
# WHY this is a hard gate, not a warning: LMCache's NIXL storage backend is
# one of several storage tiers (local_cpu is another, and it's on by
# default — see LMCACHE_LOCAL_CPU). If SMC3 is unreachable, LMCache does NOT
# fail to start; it just never successfully constructs the NIXL backend
# path, and every store/retrieve silently falls back to whatever local tiers
# ARE configured. A vLLM server that starts fine, answers /health, and
# serves every request perfectly looks IDENTICAL to a correctly wired P/D
# deployment right up until someone benchmarks cross-node cache hit rate and
# finds it's always zero. Refusing to start is the only failure mode that
# can't be mistaken for success. This gate is IN ADDITION to the LMCache MP
# daemon gate above, not instead of it — both are required: the daemon must
# be up on THIS host AND the KV tier must have a path to the store, since a
# healthy daemon says nothing about whether the store is reachable. Note
# that path is NOT always "over the network from this host" — under
# XNVME_KV it is a local char device and the network hop belongs to the
# DSC; the case below is what encodes that difference.
# ─────────────────────────────────────────────────────────────────────────────
# WHICH reachability check is correct depends on WHO opens the NVMe-oF
# connection, and that differs by backend. Corrected 2026-09-16 after
# measuring the live path (docs/HANDOFF.md §16.8's "local DSC" option is
# what this lab actually runs):
#
#   SPDK_NVMe_KV — the HOST is the NVMe-oF initiator. It dials
#     ${NVMF_TRADDR}:${NVMF_TRSVCID} itself through the SPDK initiator, so a
#     TCP connect from this host is exactly the right liveness probe.
#
#   XNVME_KV — the host is NOT an initiator at all. The Pensando DSC is.
#     The host's only contact with the KV store is the local PCIe char
#     device the DSC presents (${XNVME_DEV}, csi=0x1); the DSC opens and
#     maintains the NVMe-oF/TCP session to the target from its OWN address
#     on the storage fabric, which the host has no route to. Measured on
#     this lab: the target's SPDK listens on 1.1.0.2:4420 and its
#     established peers are the two DSCs (1.1.0.1, 1.1.0.3) — never a host
#     address. A TCP probe from here therefore tests a path that is not
#     supposed to exist, and fails on a perfectly healthy deployment.
#     The device node is the correct host-visible proxy for "the KV tier
#     has somewhere to go"; the DSC-to-target session is the DSC's
#     responsibility and is not observable from this side.
case "${KV_BACKEND}" in
    XNVME_KV)
        info "checking DSC-presented KV device: ${XNVME_DEV}"
        [ -c "${XNVME_DEV}" ] || die "KV device ${XNVME_DEV} is not a char" \
            " device on this node. Refusing to start: a silent fallback to" \
            " local-only caching is the worst failure mode here (see this" \
            " script's comment above). Note this backend does NOT dial the" \
            " target from this host — the DSC does — so a missing device" \
            " node here means the DSC is not presenting its KV namespace," \
            " not that the target is down."
        ok "KV device ${XNVME_DEV} present"
        ;;
    *)
        info "checking NVMe-oF target reachability: ${NVMF_TRADDR}:${NVMF_TRSVCID}"
        if ! wait_for_port "${NVMF_TRADDR}" "${NVMF_TRSVCID}" 30; then
            die "NVMe-oF target ${NVMF_TRADDR}:${NVMF_TRSVCID} is not" \
                " reachable after 30s. Refusing to start: a silent fallback" \
                " to local-only caching is the worst failure mode here (see" \
                " this script's comment above) because the server would" \
                " otherwise start successfully and LOOK like it works." \
                " Start the target first: scripts/target/03-start-kv-target.sh"
        fi
        ok "target reachable"
        ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# vLLM process environment.
# ─────────────────────────────────────────────────────────────────────────────
export VLLM_USE_V1=1
export VLLM_ROCM_USE_AITER=1
export PYTORCH_HIP_ALLOC_CONF="expandable_segments:False"
_HIP_IDS="$(seq -s, 0 $((TP_SIZE - 1)))"
export HIP_VISIBLE_DEVICES="${_HIP_IDS}"
export VLLM_ATTENTION_BACKEND
export HF_HOME
export HF_TOKEN

KV_TRANSFER_CONFIG="$("${REPO_ROOT}/scripts/common/gen-kv-transfer-config.sh" "${ROLE}")"

log "kv-transfer-config: ${KV_TRANSFER_CONFIG}"
log "NIXL side channel: ${VLLM_NIXL_SIDE_CHANNEL_HOST}:${VLLM_NIXL_SIDE_CHANNEL_PORT}"
log "LMCache MP daemon: ${LMCACHE_MP_HOST}:${LMCACHE_MP_PORT}"

# ─────────────────────────────────────────────────────────────────────────────
# Launch.
# ─────────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2086
start_bg "vllm-${ROLE}" \
    python -m vllm.entrypoints.openai.api_server \
        --model "${MODEL}" \
        --served-model-name "${SERVED_MODEL_NAME}" \
        --host 0.0.0.0 \
        --port "${PORT}" \
        --tensor-parallel-size "${TP_SIZE}" \
        --gpu-memory-utilization "${GPU_MEM_UTIL}" \
        --max-model-len "${MAX_MODEL_LEN}" \
        --block-size "${BLOCK_SIZE}" \
        --kv-cache-dtype "${KV_CACHE_DTYPE}" \
        --enable-prefix-caching \
        --trust-remote-code \
        --kv-transfer-config "${KV_TRANSFER_CONFIG}" \
        ${VLLM_EXTRA_ARGS:-}

# Model load on 8x MI300X (TP=8, weight sharding + warmup + CUDA/HIP-graph
# capture with --enable-prefix-caching) routinely takes many minutes — 1800s
# is a floor, not a target; raise it if MODEL is larger than an 8B-class
# model or GPU_MEM_UTIL forces extra graph re-capture passes.
LOGFILE="$(logfile_for "vllm-${ROLE}")"
if wait_for_http "http://127.0.0.1:${PORT}/health" 1800; then
    ok "vllm-${ROLE} healthy on port ${PORT}"
    log "test with:"
    log "  curl -s http://127.0.0.1:${PORT}/v1/models | python3 -m json.tool"
else
    err "vllm-${ROLE} did not become healthy within 1800s — last 60 log lines:"
    tail -n 60 "${LOGFILE}" >&2
    die "startup failed; see ${LOGFILE} for the full log"
fi
