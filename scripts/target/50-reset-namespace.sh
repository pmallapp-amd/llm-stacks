#!/usr/bin/env bash
# 50-reset-namespace.sh — drain and recreate the SMC3 NVMe-KV namespace.
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/target/03-start-kv-target.sh already run
#                (spdk_tgt up and configured).
# Next step:     scripts/target/04-verify-target.sh.
#
# WHY THIS SCRIPT EXISTS — read before skipping the confirmation prompt:
#
# Stored KV objects carry no geometry manifest. A reader recomputes
#   n = ceil(page_size / max_value_size)
# to know how many sub-keys a page was split into (see KV_MAX_VALUE_SIZE's
# comment in config/cluster.env and make_key() in
# plugins/nvme-kv/spdk_nvme_kv_backend.h). If KV_MAX_VALUE_SIZE changes
# between when a page was WRITTEN and when it is later READ, the reader
# derives a DIFFERENT n, walks a DIFFERENT set of sub-keys under the same
# base key — and some of those sub-keys still physically exist in the
# namespace from the OLD split (same bdev, same key-derivation scheme, just
# different neighbor boundaries). The reader silently reassembles a page
# that is part new-split data and part stale old-split data. There is no
# error anywhere: every individual retrieve() succeeds, because the
# sub-key genuinely exists — it just belongs to the wrong geometry. The
# RAM-backed bdev_kvmalloc namespace has no manifest recording what
# geometry wrote what, so there is no way to detect this after the fact.
#
# The only safe fix is to never let two splits coexist in the same
# namespace: whenever KV_MAX_VALUE_SIZE changes, drain the namespace with
# this script BEFORE anything writes under the new geometry.
#
# Shares the RPC sequence with scripts/target/03-start-kv-target.sh via
# lib-kv-rpc.sh's kv_target_teardown_namespace()/kv_target_apply_config() —
# duplicating "delete everything, recreate everything" in two files that
# could then drift apart is exactly the kind of bug this script exists to
# prevent one layer up; it would be self-defeating to introduce a new one
# here.
#
# usage: 50-reset-namespace.sh   (set KV_ASSUME_YES=1 to skip confirmation)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-kv-rpc.sh"

require_root
require_host "${TARGET_HOST}" "target"

step "Reset KV namespace: ${TARGET_NAME} (${TARGET_HOST})"
banner_config

is_running "kv-target" \
    || die "kv-target is not running — nothing to reset." \
           " Start it first: scripts/target/03-start-kv-target.sh"

warn "This will DELETE the namespace '${KV_BDEV_NAME}' and every KV object" \
     " stored in it (bdev_kvmalloc is RAM-backed — this data does not" \
     " survive a bdev delete regardless of whether you run this script)." \
     " Any prefill/decode process with an open qpair against it will start" \
     " failing I/O until this script finishes recreating the namespace."
confirm "Proceed with draining and recreating '${KV_BDEV_NAME}'?" \
    || die "aborted by operator"

step "Draining namespace"
kv_target_teardown_namespace

step "Recreating namespace"
kv_target_apply_config

ok "namespace reset complete"
log "verify: scripts/target/04-verify-target.sh"
