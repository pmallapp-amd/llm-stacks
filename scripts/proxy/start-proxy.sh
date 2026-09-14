#!/usr/bin/env bash
# start-proxy.sh — launch scripts/proxy/disagg_proxy.py under start_bg.
#
# Node:          conventionally SMC2 (decode), since PROXY_HOST defaults to
#                DECODE_HOST in config/cluster.env — but disagg_proxy.py
#                itself is host-agnostic, and this script does not
#                require_host, since a proxy fronting two remote upstreams
#                is exactly the kind of thing that's reasonable to run from
#                a third location too.
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh (needs aiohttp in
#                ${VENV}); both scripts/prefill/03-start-prefill.sh and
#                scripts/decode/03-start-decode.sh should be up (the proxy
#                degrades gracefully if prefill alone is down — see
#                disagg_proxy.py's docstring — but needs decode).
# Next step:     point an OpenAI-compatible client at
#                http://${PROXY_HOST}:${PROXY_PORT}/v1/...

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

step "Starting disagg-proxy on port ${PROXY_PORT}"
banner_config

# shellcheck source=/dev/null
source "${STACK_ROOT}/etc/env.sh"

export PREFILL_HOST PREFILL_PORT DECODE_HOST DECODE_PORT PROXY_PORT

start_bg "disagg-proxy" \
    python "${REPO_ROOT}/scripts/proxy/disagg_proxy.py"

LOGFILE="$(logfile_for "disagg-proxy")"
if wait_for_http "http://127.0.0.1:${PROXY_PORT}/status" 30; then
    ok "disagg-proxy healthy on port ${PROXY_PORT}"
    log "test with:"
    log "  curl -s http://127.0.0.1:${PROXY_PORT}/status | python3 -m json.tool"
    log "  curl -s http://127.0.0.1:${PROXY_PORT}/v1/models"
else
    err "disagg-proxy did not become healthy within 30s — last 40 log lines:"
    tail -n 40 "${LOGFILE}" >&2
    die "startup failed; see ${LOGFILE} for the full log"
fi
