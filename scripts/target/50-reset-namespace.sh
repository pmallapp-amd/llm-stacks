#!/usr/bin/env bash
# 50-reset-namespace.sh — drain the SMC3 NVMe-KV namespace by restarting
# nvmf_tgt.
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: scripts/target/03-start-kv-target.sh already run
#                (nvmf_tgt up and configured).
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
# namespace: whenever KV_MAX_VALUE_SIZE (or NVMF_MAX_IO_SIZE /
# NVMF_LARGE_BUFSIZE) changes, drain the namespace with this script BEFORE
# anything writes under the new geometry.
#
# WHY A RESTART, NOT AN INCREMENTAL RPC TEARDOWN: an earlier version of
# this script called nvmf_subsystem_remove_listener / nvmf_delete_
# subsystem / bdev_kvmalloc_delete, then re-ran the same RPC sequence
# scripts/target/03-start-kv-target.sh used to bring the target up fresh —
# two hand-maintained RPC call sequences that had to stay in lockstep.
# scripts/target/03-start-kv-target.sh now applies the ENTIRE configuration
# via one --json file at process start (see lib-kv-rpc.sh's
# kv_target_gen_json_config), so there is no operation smaller than
# "restart the process" that still guarantees the exact same config comes
# back — and bdev_kvmalloc is RAM-backed anyway, so a restart already
# drains it as a side effect. Stopping and restarting nvmf_tgt IS the
# drain-and-recreate operation now; it just has one moving part instead of
# two RPC sequences that could silently diverge.
#
# usage: 50-reset-namespace.sh   (set KV_ASSUME_YES=1 to skip confirmation)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_root
require_host "${TARGET_HOST}" "target"

step "Reset KV namespace: ${TARGET_NAME} (${TARGET_HOST})"
banner_config

is_running "kv-target" \
    || die "kv-target is not running — nothing to reset." \
           " Start it first: scripts/target/03-start-kv-target.sh"

warn "This will RESTART nvmf_tgt and DELETE every KV object stored in" \
     " '${KV_BDEV_NAME}' (bdev_kvmalloc is RAM-backed — this data does not" \
     " survive a process restart regardless of whether you run this" \
     " script). Any prefill/decode process with an open qpair against it" \
     " will start failing I/O until the restart completes and they" \
     " reconnect."
confirm "Proceed with restarting nvmf_tgt and draining '${KV_BDEV_NAME}'?" \
    || die "aborted by operator"

step "Restarting kv-target (regenerates + re-applies config/cluster.env's" \
     " --json config against a fresh process)"
"${REPO_ROOT}/scripts/target/03-start-kv-target.sh" --restart

ok "namespace reset complete"
log "verify: scripts/target/04-verify-target.sh"
