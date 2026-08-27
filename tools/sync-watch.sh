#!/usr/bin/env bash
# sync-watch.sh — bidirectional sync daemon between this repo and a remote host.
# Local → remote: scripts, Dockerfiles, patches (push on change)
# Remote → local: results/ (pull periodically)
#
# Since the 2026-08-13 reorg the remote mirror is a 1:1 copy of the repo root
# and results/ is a single canonical tree (results/<host>/<date>-<tool>/), so
# the pull below is one rule covering every track and every benchmark rather
# than the old NIXL-specific path.
#
# Runs in the foreground; Ctrl-C to stop.
# Usage: bash tools/sync-watch.sh [INTERVAL_SECONDS]
set -euo pipefail

REMOTE_HOST="root@<SETUP2_PD_NODE_IP>"
REMOTE_PASS="docker"
REMOTE_DIR="/root/rixl-bench"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL=${1:-10}

SSH="sshpass -p ${REMOTE_PASS} ssh -o StrictHostKeyChecking=no"
RSYNC="sshpass -p ${REMOTE_PASS} rsync -az --checksum \
  -e 'ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=yes'"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Compute a fast checksum of all source files (exclude results/ and build artifacts)
local_checksum() {
    find "${LOCAL_DIR}" \
        -not -path "*/results/*" \
        -not -path "*/bench-install/*" \
        -not -path "*/__pycache__/*" \
        -not -path "*/.git/*" \
        -not -path "*/.claude/*" \
        -not -path "*/.codex/*" \
        -not -name "*.pyc" \
        -not -name "*.log" \
        -type f \
        -exec md5sum {} \; 2>/dev/null | sort | md5sum | cut -d' ' -f1
}

push() {
    sshpass -p "${REMOTE_PASS}" rsync -az --checksum \
        -e "ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=yes" \
        --exclude "results/" \
        --exclude "bench-install/" \
        --exclude ".git/" \
        --exclude ".claude/" \
        --exclude ".codex/" \
        --exclude "*.pyc" \
        --exclude "__pycache__/" \
        --exclude "*.log" \
        "${LOCAL_DIR}/" \
        "${REMOTE_HOST}:${REMOTE_DIR}/" \
        && sshpass -p "${REMOTE_PASS}" ssh -o StrictHostKeyChecking=no "${REMOTE_HOST}" \
            "find ${REMOTE_DIR} -name '*.sh' -exec chmod +x {} +"
}

pull_results() {
    # Only sync consolidated result data (.txt/.json/.log/.md tables and
    # summaries) — never the whole results/ tree. nixlbench creates multi-GB
    # scratch/backing files in the same directory it is told to write results
    # to (e.g. *_test_file_initiator_0, sized to --total_buffer_size, default
    # 8GB) — a wholesale rsync drags those down too (confirmed: bloated this
    # repo to 33GB on 2026-08-03). The --include/--exclude below skips
    # everything except the small text files, on both sides of the tree.
    # (.md was missing before the reorg, which is why llama-benchy results had
    # to be pulled by hand.)
    sshpass -p "${REMOTE_PASS}" rsync -az --checksum \
        -e "ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=yes" \
        --include "*/" \
        --include "*.txt" --include "*.json" --include "*.log" --include "*.md" \
        --exclude "*" \
        --prune-empty-dirs \
        "${REMOTE_HOST}:${REMOTE_DIR}/results/" \
        "${LOCAL_DIR}/results/" 2>/dev/null || true
}

log "Sync watch started"
log "  local : ${LOCAL_DIR}"
log "  remote: ${REMOTE_HOST}:${REMOTE_DIR}"
log "  poll interval: ${INTERVAL}s"
log "  Ctrl-C to stop"
echo ""

# Initial full push + pull
log "Initial sync..."
push && log "  pushed"
pull_results && log "  pulled results"

LAST_CHECKSUM=$(local_checksum)
PULL_COUNTER=0
PULL_EVERY=6  # pull results every 6 × INTERVAL seconds

while true; do
    sleep "${INTERVAL}"

    # Check for local changes
    CURRENT_CHECKSUM=$(local_checksum)
    if [ "${CURRENT_CHECKSUM}" != "${LAST_CHECKSUM}" ]; then
        log "Local change detected — pushing..."
        if push; then
            log "  pushed OK"
            LAST_CHECKSUM="${CURRENT_CHECKSUM}"
        else
            log "  push FAILED (will retry)"
        fi
    fi

    # Pull results periodically
    PULL_COUNTER=$((PULL_COUNTER + 1))
    if [ "${PULL_COUNTER}" -ge "${PULL_EVERY}" ]; then
        PULL_COUNTER=0
        BEFORE=$(find "${LOCAL_DIR}/results/" -type f 2>/dev/null | wc -l)
        pull_results
        AFTER=$(find "${LOCAL_DIR}/results/" -type f 2>/dev/null | wc -l)
        if [ "${AFTER}" -gt "${BEFORE}" ]; then
            log "  pulled $((AFTER - BEFORE)) new result file(s)"
        fi
    fi
done
