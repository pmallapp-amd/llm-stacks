#!/usr/bin/env bash
# 30-start-lmcache-daemon.sh — start the LMCache MP-mode daemon as a
# SEPARATE HOST PROCESS on THIS node.
#
# Node:          any node running vLLM with LMCacheMPConnector — SMC1
#                (prefill) or SMC2 (decode). Each node runs its OWN daemon
#                instance, reached over loopback: LMCACHE_MP_HOST is
#                tcp://127.0.0.1 BY DESIGN (config/cluster.env's
#                LMCACHE_MP_HOST comment — raw pointers cross the ZMQ
#                boundary between vLLM and the daemon and are only
#                meaningful within the SAME host's IPC namespace). There is
#                therefore no require_host gate here: this script is meant
#                to run identically, unmodified, on prefill and decode.
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh (need ${VENV} with
#                lmcache importable).
# Next step:     scripts/{prefill,decode}/03-start-*.sh call this
#                automatically (it's idempotent) before launching vLLM; run
#                it by hand first only if you want to watch its own log
#                separately, or debug it with --foreground.
#
# usage: 30-start-lmcache-daemon.sh [--foreground]
#
# ═══════════════════════════════════════════════════════════════════════════
# ENTRY POINT — verified against the INSTALLED package, not guessed
# ═══════════════════════════════════════════════════════════════════════════
# Confirmed 2026-09-16 by reading the installed lmcache 0.5.3 inside the
# rocm-aic:mp-pd-ionic2609 image (the same build this stack deploys):
#
#   $ python3 -c 'import importlib.metadata as m; \
#         print([e for e in m.entry_points().select(group="console_scripts") \
#                if "lmcache" in e.name])'
#   [EntryPoint(name='lmcache', value='lmcache.cli.main:main', ...),
#    EntryPoint(name='lmcache_controller', value='lmcache.v1.api_server.__main__:main', ...),
#    EntryPoint(name='lmcache_server', value='lmcache.v1.server.__main__:main', ...)]
#
#   `lmcache_server` (lmcache/v1/server/__main__.py -> lmcache/v1/server/
#   __init__.py) is a DIFFERENT, OLDER raw-socket remote cache server
#   (usage: "<host> <port> <storage>", plain STORE/RETRIEVE/EXIST/HEALTH
#   over a bare TCP socket) — it is NOT MP mode and is NOT what
#   LMCacheMPConnector talks to. Do not use it here.
#
#   The `lmcache` console script's `server` subcommand
#   (lmcache/cli/commands/server.py: ServerCommand.execute) composes the MP
#   server / HTTP-frontend / storage-manager / observability / coordinator
#   config objects and calls
#   lmcache.v1.multiprocess.http_server.run_http_server(...) directly — it
#   IS the MP daemon, just via one extra layer of argument-parsing
#   indirection.
#
#   That module is ALSO directly runnable
#   (`if __name__ == "__main__":` at
#   lmcache/v1/multiprocess/http_server.py:279) and this is exactly what
#   the package's OWN reference launcher, vendored in the image at
#   lmcache/lmcache_frontend/run_mp_server_with_frontend.sh, invokes:
#
#     python3 -m lmcache.v1.multiprocess.http_server \
#         --host "$MP_HOST" --port "$MP_PORT" \
#         --http-host "$HTTP_HOST" --http-port "$HTTP_PORT" \
#         --l1-size-gb "$L1_SIZE_GB" --eviction-policy "$EVICTION_POLICY" \
#         --runtime-plugin-locations "$PLUGIN" \
#         --runtime-plugin-config "$PLUGIN_CFG"
#
#   The two --runtime-plugin-* flags wire in an OPTIONAL discovery/
#   heartbeat frontend plugin (reports to a coordinator this repo doesn't
#   run) — omitted below; the server runs fully without it.
#
#   --host/--port bind the ZMQ control channel LMCacheMPConnector connects
#   to. Verified by reading both ends:
#     - server side: lmcache/v1/multiprocess/server.py does
#       `bind_url=f"tcp://{mp_config.host}:{mp_config.port}"` — i.e.
#       --host wants a BARE hostname; the server prepends "tcp://" itself.
#     - client side: lmcache/integration/vllm/lmcache_mp_connector.py reads
#       `lmcache.mp.host`/`lmcache.mp.port` out of kv_transfer_config's
#       extra_config — exactly the LMCACHE_MP_HOST/LMCACHE_MP_PORT values
#       scripts/common/gen-kv-transfer-config.sh emits there.
#   Because LMCACHE_MP_HOST carries a ZMQ URL scheme (config/cluster.env:
#   "tcp://127.0.0.1" — what the CLIENT side needs), that scheme must be
#   stripped before it's handed to --host here. See _MP_BIND_HOST below.
#   scripts/common/start-vllm.sh's own daemon-reachability gate does the
#   identical strip for the same reason.
#
#   --l1-size-gb and --eviction-policy are REQUIRED by
#   add_storage_manager_args() (lmcache/v1/distributed/config.py — no
#   default for either). LMCACHE_MAX_LOCAL_CPU_SIZE (config/cluster.env:
#   "GiB of host DRAM (L1)") is already exactly the quantity --l1-size-gb
#   wants, so it is reused here rather than adding a second variable that
#   could silently drift from it.
#
# ═══════════════════════════════════════════════════════════════════════════
# KNOWN GAP — NOT resolved by this task; flagged rather than guessed at
# ═══════════════════════════════════════════════════════════════════════════
# This starts the daemon with an L1 (in-memory) tier ONLY. Whether, or how,
# the XNVME_KV storage tier (config/cluster.env's KV_BACKEND) attaches to
# THIS daemon as an L2 tier is UNRESOLVED: this daemon's L2 tier is
# configured via repeatable `--l2-adapter <JSON>` specs
# (lmcache/v1/distributed/l2_adapters/config.py) naming a registered
# adapter TYPE ("disk", "nixl_store", "nixl_store_dynamic", ... per that
# module) — a different, NOT cross-checked, mechanism from the
# extra_config.nixl_backend="XNVME_KV" wiring
# scripts/common/gen-lmcache-config.sh generates for the OLDER in-process
# LMCacheEngineConfig YAML. That generator's own header already flags this
# exact seam as unverified for MP mode ("the exact code path the daemon
# uses to load this specific file was not traced here"). Do NOT assume the
# L2/XNVME_KV tier is active just because this script's daemon is up —
# confirm with a real cache round-trip (scripts/verify/30-verify-kv-
# roundtrip.sh) before relying on it, and resolve the --l2-adapter mapping
# as a separate, deliberate follow-up.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FOREGROUND=0
for arg in "$@"; do
    case "${arg}" in
        --foreground) FOREGROUND=1 ;;
        *) die "unknown argument: ${arg}" ;;
    esac
done

step "LMCache MP daemon start"
banner_config

if [ ! -x "${VENV}/bin/python" ]; then
    die "no venv at ${VENV} — run scripts/common/20-build-vllm-lmcache.sh first"
fi

# shellcheck source=/dev/null
source "${STACK_ROOT}/etc/env.sh"

# See "ENTRY POINT" above: --host wants a bare hostname, LMCACHE_MP_HOST
# carries the ZMQ URL scheme the CLIENT side needs.
_MP_BIND_HOST="${LMCACHE_MP_HOST#tcp://}"
[ -n "${_MP_BIND_HOST}" ] || die "LMCACHE_MP_HOST resolved to an empty" \
    " host after stripping 'tcp://' (raw value: '${LMCACHE_MP_HOST}') —" \
    " fix config/cluster.env's LMCACHE_MP_HOST."

# Not read from config/cluster.env (out of this task's scope to add
# cluster-wide variables for them): the HTTP frontend is a local
# admin/health surface, not part of the P/D data path, so a same-repo
# default here is enough. Override with the env var if 8080 collides with
# something else on a given host.
_HTTP_HOST="${LMCACHE_MP_HTTP_HOST:-0.0.0.0}"
_HTTP_PORT="${LMCACHE_MP_HTTP_PORT:-8080}"

# LMCACHE_MAX_LOCAL_CPU_SIZE is already "GiB of host DRAM (L1)" — see the
# ENTRY POINT comment above for why this is reused as-is.
_L1_SIZE_GB="${LMCACHE_MP_L1_SIZE_GB:-${LMCACHE_MAX_LOCAL_CPU_SIZE}}"
_EVICTION_POLICY="${LMCACHE_MP_EVICTION_POLICY:-LRU}"

if is_running "lmcache-mp-daemon"; then
    ok "lmcache-mp-daemon already running (pid $(cat "$(pidfile_for lmcache-mp-daemon)")) — not restarting"
    exit 0
fi

info "ZMQ control channel: ${_MP_BIND_HOST}:${LMCACHE_MP_PORT}  HTTP frontend: ${_HTTP_HOST}:${_HTTP_PORT}"
info "L1 size: ${_L1_SIZE_GB} GiB  eviction policy: ${_EVICTION_POLICY}  chunk size: ${LMCACHE_CHUNK_SIZE}"

declare -a _CMD=(
    "${VENV}/bin/python" -m lmcache.v1.multiprocess.http_server
    --host "${_MP_BIND_HOST}" --port "${LMCACHE_MP_PORT}"
    --http-host "${_HTTP_HOST}" --http-port "${_HTTP_PORT}"
    --l1-size-gb "${_L1_SIZE_GB}"
    --eviction-policy "${_EVICTION_POLICY}"
    --chunk-size "${LMCACHE_CHUNK_SIZE}"
)

if [ "${FOREGROUND}" -eq 1 ]; then
    info "running lmcache-mp-daemon in the FOREGROUND (Ctrl-C to stop)."
    exec "${_CMD[@]}"
fi

start_bg "lmcache-mp-daemon" "${_CMD[@]}"

step "Waiting for ZMQ control channel ${_MP_BIND_HOST}:${LMCACHE_MP_PORT}"
if wait_for_port "${_MP_BIND_HOST}" "${LMCACHE_MP_PORT}" 30; then
    ok "lmcache-mp-daemon up, ZMQ reachable at ${_MP_BIND_HOST}:${LMCACHE_MP_PORT}"
else
    LOGFILE="$(logfile_for "lmcache-mp-daemon")"
    err "lmcache-mp-daemon did not open ${_MP_BIND_HOST}:${LMCACHE_MP_PORT} within 30s — last 40 log lines:"
    tail -n 40 "${LOGFILE}" >&2
    die "startup failed; see ${LOGFILE} for the full log"
fi
