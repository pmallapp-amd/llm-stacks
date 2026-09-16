#!/usr/bin/env bash
# 05-check-chunk-ceiling.sh — correctness guard: does ONE LMCache chunk fit
# in ONE NVMe-oF transfer?
#
# Node:          any. Pure arithmetic against config/cluster.env — no
#                require_host, so it can be run from SMC1/SMC2 while
#                iterating on MODEL/TP_SIZE/LMCACHE_CHUNK_SIZE, and is also
#                called from SMC3's scripts/target/04-verify-target.sh.
# Prerequisites: none.
#
# WHY THIS EXISTS: LMCache stores ONE chunk as ONE NIXL object, and a
# single object's bytes are capped by the NVMe-oF transport's max_io_size
# (NVMF_MAX_IO_SIZE, config/cluster.env — 16 MiB in the proven
# configuration). A chunk larger than that fails the STORE with
# NIXL_ERR_BACKEND, which takes the WHOLE vLLM server down rather than
# degrading (see plugins/nvme-kv/spdk_nvme_kv_backend.h) — this is a
# pre-flight correctness gate, not an optimization knob.
#
# Per-rank bytes for one chunk:
#     layers * chunk_size * (kv_heads / TP) * head_dim * 2 (K,V) * 2 (bf16)
#
# Validated against two measured points from rocm-aic/target.sh:
#   TinyLlama-1.1B  TP=1 chunk=256 -> 5.5 MiB  (fits)
#   Qwen2.5-72B     TP=4 chunk=256 -> 20 MiB   (does NOT fit, measured 2026-09-09)
# This repo's default is Qwen2.5-72B at TP=8, chunk=256 -> 10 MiB, which
# fits — but with little headroom (well under half the 16 MiB ceiling is
# still unused, but a drop to TP=4 with the SAME chunk size — a change an
# operator could make for an unrelated reason — blows straight through it).
# Re-run this check whenever MODEL, TP_SIZE, or LMCACHE_CHUNK_SIZE change.
#
# CRITICAL: chunk_size is part of the cache key (see the in-process
# LMCacheConnectorV1 YAML surface's chunk_size field, removed along with
# the rest of that path — TODO 6.23 — and make_key() in
# plugins/nvme-kv/spdk_nvme_kv_backend.h) — BOTH P/D
# roles MUST use the SAME LMCACHE_CHUNK_SIZE, or the receiver derives a
# DIFFERENT key and silently re-prefills instead of hitting the remote
# cache. This script only validates one side's arithmetic; it does not (and
# cannot, from one host) confirm the other role agrees.
#
# Model geometry cannot be read from config.json offline, so it lives in a
# small table below. Qwen2.5-72B-Instruct (this repo's default MODEL) is
# pre-filled per the task spec; TinyLlama-1.1B is pre-filled too — it is
# one of the two measured data points above, and reproduces the "5.5 MiB"
# figure from rocm-aic/target.sh exactly, which is useful for exercising
# this script itself. Any OTHER model requires an explicit override:
#     KV_MODEL_LAYERS=<n> KV_MODEL_KV_HEADS=<n> KV_MODEL_HEAD_DIM=<n> \
#         scripts/target/05-check-chunk-ceiling.sh
#
# usage: 05-check-chunk-ceiling.sh

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

_layers=""
_kv_heads=""
_head_dim=""
case "${MODEL}" in
    "Qwen/Qwen2.5-72B-Instruct"|"Qwen/Qwen2.5-72B-Instruct-AWQ")
        # hidden_size=8192 num_attention_heads=64 num_key_value_heads=8
        # num_hidden_layers=80 -> head_dim = 8192/64 = 128. Cross-checked
        # against both measured points in the header comment:
        #   TP=8 -> 80*256*1*128*2*2 = 10,485,760 bytes (10 MiB, matches)
        #   TP=4 -> 80*256*2*128*2*2 = 20,971,520 bytes (20 MiB, matches)
        _layers=80 _kv_heads=8 _head_dim=128
        ;;
    "TinyLlama/TinyLlama-1.1B-Chat-v1.0"|"TinyLlama-1.1B")
        # hidden_size=2048 num_attention_heads=32 num_key_value_heads=4
        # num_hidden_layers=22 -> head_dim = 2048/32 = 64. Cross-checked:
        #   TP=1 -> 22*256*4*64*2*2 = 5,767,168 bytes (5.5 MiB — matches
        #   rocm-aic/target.sh's measured value exactly).
        _layers=22 _kv_heads=4 _head_dim=64
        ;;
esac

_layers="${KV_MODEL_LAYERS:-${_layers}}"
_kv_heads="${KV_MODEL_KV_HEADS:-${_kv_heads}}"
_head_dim="${KV_MODEL_HEAD_DIM:-${_head_dim}}"

if [ -z "${_layers}" ] || [ -z "${_kv_heads}" ] || [ -z "${_head_dim}" ]; then
    die "MODEL='${MODEL}' has no pre-filled geometry entry, and" \
        " KV_MODEL_LAYERS/KV_MODEL_KV_HEADS/KV_MODEL_HEAD_DIM are not all" \
        " set. This script cannot read config.json offline — supply the" \
        " three overrides explicitly, e.g.:" \
        "   KV_MODEL_LAYERS=80 KV_MODEL_KV_HEADS=8 KV_MODEL_HEAD_DIM=128 $0"
fi

if [ "${TP_SIZE}" -ge "${_kv_heads}" ]; then
    # TP >= kv_heads: GQA replicates kv heads across ranks; each rank still
    # carries (at least) one full local copy.
    _kv_heads_per_rank=1
else
    if [ "$(( _kv_heads % TP_SIZE ))" -ne 0 ]; then
        warn "kv_heads(${_kv_heads}) is not evenly divisible by" \
             " TP_SIZE(${TP_SIZE}) — using floor division; the real" \
             " per-rank head count may be uneven across ranks in a way" \
             " this arithmetic does not model."
    fi
    _kv_heads_per_rank=$(( _kv_heads / TP_SIZE ))
fi

_bytes_per_chunk=$(( _layers * LMCACHE_CHUNK_SIZE * _kv_heads_per_rank * _head_dim * 2 * 2 ))
_mib=$(( _bytes_per_chunk / 1048576 ))

step "Chunk-size ceiling check"
log "MODEL=${MODEL}  TP_SIZE=${TP_SIZE}  LMCACHE_CHUNK_SIZE=${LMCACHE_CHUNK_SIZE}"
log "geometry: layers=${_layers} kv_heads=${_kv_heads} (per-rank=${_kv_heads_per_rank}) head_dim=${_head_dim}"
log "one chunk, one NIXL object, per rank: ${_bytes_per_chunk} bytes (~${_mib} MiB)"
log "NVMF_MAX_IO_SIZE ceiling: ${NVMF_MAX_IO_SIZE} bytes (~$(( NVMF_MAX_IO_SIZE / 1048576 )) MiB)"

if [ "${_bytes_per_chunk}" -gt "${NVMF_MAX_IO_SIZE}" ]; then
    die "chunk does NOT fit: ${_bytes_per_chunk} bytes > NVMF_MAX_IO_SIZE=" \
        "${NVMF_MAX_IO_SIZE} bytes. A STORE of this size fails with" \
        " NIXL_ERR_BACKEND and takes the WHOLE vLLM server down (see" \
        " plugins/nvme-kv/spdk_nvme_kv_backend.h). Lower LMCACHE_CHUNK_SIZE," \
        " raise TP_SIZE, or raise NVMF_MAX_IO_SIZE (+ NVMF_LARGE_BUFSIZE —" \
        " see scripts/target/lib-kv-rpc.sh's kv_target_check_sgl) in" \
        " config/cluster.env — and remember chunk_size is part of the" \
        " cache key: BOTH P/D roles must use the SAME LMCACHE_CHUNK_SIZE" \
        " or the receiver silently re-prefills instead of hitting the" \
        " remote cache."
fi

_headroom_pct=$(( (NVMF_MAX_IO_SIZE - _bytes_per_chunk) * 100 / NVMF_MAX_IO_SIZE ))
if [ "${_headroom_pct}" -lt 50 ]; then
    warn "chunk fits (${_bytes_per_chunk} / ${NVMF_MAX_IO_SIZE} bytes," \
         " ${_headroom_pct}% headroom) but with LITTLE margin — a change" \
         " to TP_SIZE, LMCACHE_CHUNK_SIZE, or MODEL that shrinks the" \
         " denominator or grows the numerator can blow this ceiling" \
         " without warning until this check is re-run."
else
    ok "chunk fits: ${_bytes_per_chunk} bytes <= NVMF_MAX_IO_SIZE=${NVMF_MAX_IO_SIZE}" \
       " (${_headroom_pct}% headroom)"
fi
