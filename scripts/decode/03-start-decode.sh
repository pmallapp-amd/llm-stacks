#!/usr/bin/env bash
# 03-start-decode.sh — start the decode vLLM+LMCache server on SMC2.
#
# Node:          SMC2 (decode), ${DECODE_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/decode/01-host-prep.sh,
#                scripts/common/10-build-stack.sh,
#                scripts/common/20-build-vllm-lmcache.sh — all complete;
#                scripts/prefill/03-start-prefill.sh should be up first
#                (not strictly required, but the proxy expects both).
# Next step:     scripts/proxy/start-proxy.sh.
#
# Thin wrapper around scripts/common/start-vllm.sh: pins this node's
# identity (require_host) itself, independent of the shared body, so this
# script is safe to hand to an operator on its own without them needing to
# know start-vllm.sh takes a role argument at all.
#
# usage: 03-start-decode.sh [--skip-validate]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_host "${DECODE_HOST}" "decode"

exec "${REPO_ROOT}/scripts/common/start-vllm.sh" decode "$@"
