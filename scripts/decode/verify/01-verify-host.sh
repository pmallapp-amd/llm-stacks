#!/usr/bin/env bash
# 01-verify-host.sh — kernel, amdgpu module loaded and at the expected version, GPU enumeration, co-tenancy
#
# Run ON the decode node, after the corresponding bring-up step. Every
# check and the trap it guards is documented in scripts/common/lib-verify.sh.
# Exits non-zero if any check fails, so it chains in a && sequence.
ROLE=decode
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../common/lib-verify.sh"
require_host "${DECODE_HOST}" "decode"
v_host
