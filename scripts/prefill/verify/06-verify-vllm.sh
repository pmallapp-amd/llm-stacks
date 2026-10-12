#!/usr/bin/env bash
# 06-verify-vllm.sh — vLLM alive, answering, and running the TP / GPU_MEM_UTIL geometry we configured
#
# Run ON the prefill node, after the corresponding bring-up step. Every
# check and the trap it guards is documented in scripts/common/lib-verify.sh.
# Exits non-zero if any check fails, so it chains in a && sequence.
ROLE=prefill
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../common/lib-verify.sh"
require_host "${PREFILL_HOST}" "prefill"
v_vllm
