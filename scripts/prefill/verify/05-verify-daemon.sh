#!/usr/bin/env bash
# 05-verify-daemon.sh — LMCache MP daemon alive and NOT a zombie, HTTP status healthy, L2 adapter and namespace
#
# Run ON the prefill node, after the corresponding bring-up step. Every
# check and the trap it guards is documented in scripts/common/lib-verify.sh.
# Exits non-zero if any check fails, so it chains in a && sequence.
ROLE=prefill
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../common/lib-verify.sh"
require_host "${PREFILL_HOST}" "prefill"
v_daemon
