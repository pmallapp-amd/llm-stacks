#!/usr/bin/env bash
# sync-to-remote.sh — push this repo's source tree to a benchmark host
# (one-way, local -> remote only).
#
# Usage: ./tools/sync-to-remote.sh
# REMOTE_HOST / REMOTE_DIR can be overridden via env.
#
# SSH_OPTS passes extra flags to ssh, for hosts that need a specific key or user.
# The CIRRASCALE cluster (<SETUP3_PREFILL_NODE>/<SETUP3_DECODE_NODE>/<SETUP3_TARGET_NODE>) needs this: its `Host <SETUP3_CLUSTER>*`
# ssh-config alias expands to a .prov.aus.ccs.cpe.ice.amd.com FQDN that does NOT
# resolve from here, so you must target the IP directly and name the key by hand —
# the config block never matches a bare IP and the default keys are refused:
#   REMOTE_HOST=<SETUP3_USER>@<SETUP3_DECODE_NODE_IP> REMOTE_DIR=/opt/rixl-bench \
#   SSH_OPTS="-i ~/.ssh/id_rsa_amd.com -o IdentitiesOnly=yes" ./tools/sync-to-remote.sh
#
# Since the 2026-08-13 reorg the remote mirror is a 1:1 copy of the repo root
# (stack/ bench/ validation/ tools/ docs/), NOT a bare artifacts/ directory —
# so a repo-relative path works verbatim on either side. See MIGRATION.md for
# how to clear the stale pre-reorg layout off a host that still has it.
set -euo pipefail

REMOTE_HOST=${REMOTE_HOST:-root@<SETUP2_PD_NODE_IP>}
REMOTE_DIR=${REMOTE_DIR:-/root/rixl-bench}
SSH_OPTS=${SSH_OPTS:-}
LOCAL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck disable=SC2086  # SSH_OPTS is deliberately word-split into ssh flags
SSH_CMD="ssh -o StrictHostKeyChecking=no ${SSH_OPTS}"

echo "Syncing ${LOCAL_DIR}/ -> ${REMOTE_HOST}:${REMOTE_DIR}/"
# results/ and bench-install/ only ever flow remote -> local (see sync-watch.sh's
# pull_results()) — excluded here so this one-shot push can never carry local
# result-directory bloat (e.g. nixlbench's multi-GB scratch/backing files) back
# up to the remote host. Agent/editor state and logs are local-only concerns.
rsync -avz --progress \
  -e "${SSH_CMD}" \
  --exclude "results/" \
  --exclude "bench-install/" \
  --exclude ".git/" \
  --exclude ".claude/" \
  --exclude ".codex/" \
  --exclude ".opencode/" \
  --exclude "__pycache__/" \
  --exclude "*.pyc" \
  --exclude "*.log" \
  "${LOCAL_DIR}/" \
  "${REMOTE_HOST}:${REMOTE_DIR}/"

# Re-apply execute bits (rsync preserves them, but just in case)
${SSH_CMD} "${REMOTE_HOST}" \
  "find ${REMOTE_DIR} -name '*.sh' -exec chmod +x {} +"

echo "OK: sync complete"
