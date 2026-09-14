#!/usr/bin/env bash
# 03-start-prefill.sh — start the prefill vLLM+LMCache server on SMC1.
#
# Node:          SMC1 (prefill), ${PREFILL_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/prefill/01-host-prep.sh,
#                scripts/common/10-build-stack.sh,
#                scripts/common/20-build-vllm-lmcache.sh — all complete.
# Next step:     scripts/decode/03-start-decode.sh, then
#                scripts/proxy/start-proxy.sh.
#
# Thin wrapper around scripts/common/start-vllm.sh: pins this node's
# identity (require_host) itself, independent of the shared body, so this
# script is safe to hand to an operator on its own without them needing to
# know start-vllm.sh takes a role argument at all.
#
# usage: 03-start-prefill.sh [--skip-validate]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_host "${PREFILL_HOST}" "prefill"

exec "${REPO_ROOT}/scripts/common/start-vllm.sh" prefill "$@"
