#!/usr/bin/env bash
# start-lmcache-daemon.sh — start the LMCache MP-mode daemon as a
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
#                to run identically, unmodified, on prefill and decode —
#                it auto-detects which one it's on for the L2 adapter spec
#                below (LMCACHE_DAEMON_ROLE overrides), rather than taking a
#                role argument.
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh (need ${VENV} with
#                lmcache importable).
# Next step:     scripts/{prefill,decode}/03-start-*.sh call this
#                automatically (it's idempotent) before launching vLLM; run
#                it by hand first only if you want to watch its own log
#                separately, or debug it with --foreground.
#
# usage: start-lmcache-daemon.sh [--foreground]
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
# L2 (KV STORAGE) TIER — RESOLVED 2026-09-16 (docs/HANDOFF.md §16; §12.1's
# "MP cannot carry the tier" conclusion is WITHDRAWN, see §16.1-§16.3)
# ═══════════════════════════════════════════════════════════════════════════
# This daemon's L2 tier attaches via a repeatable `--l2-adapter <JSON>` flag
# (lmcache/v1/distributed/l2_adapters/config.py:402-441's
# add_l2_adapters_args()/parse_args_to_l2_adapters_config(), wired into
# add_storage_manager_args() at lmcache/v1/distributed/config.py:524) — NOT
# via the extra_config.{enable_nixl_storage,nixl_backend,nixl_backend_params}
# keys the in-process LMCacheConnectorV1 YAML surface emits (removed, see
# TODO 6.23). Those keys belong to the in-process LMCacheConnectorV1/
# StorageManager path (lmcache/v1/storage_backend/nixl_storage_backend.py)
# and are silently IGNORED here — nixl_store_l2_adapter.py never reads
# extra_config at all. That in-process surface's own header carried the
# corrected statement of which surface applies where, before it was removed
# with the rest of that path (TODO 6.23); do not resurrect §12.1's withdrawn
# inference
# that MP mode cannot reach XNVME_KV/SPDK_NVMe_KV at all.
#
# We use the STATIC "nixl_store" adapter type
# (nixl_store_l2_adapter.py:1071 NixlStoreL2AdapterConfig, self-registered
# as "nixl_store" at :1167), never "nixl_store_dynamic" — the dynamic
# adapter is file-oriented (requires backend_params["file_path"], does
# os.makedirs, registers mem_type="FILE") and has nothing to do with a
# KV-keyed backend. The static adapter's _VALID_NIXL_BACKENDS (:1057-1067,
# confirmed by reading the INSTALLED lmcache 0.5.3 in
# rocm-aic:mp-pd-ionic2609) includes both "SPDK_NVMe_KV" and "XNVME_KV", and
# _FILE_BACKENDS (:1068) deliberately excludes them, so no file_path is ever
# required for either — both route through init_storage_handlers_object()
# (:397-446) with mem_type="OBJ" (:438), matching the OBJ (not FILE) routing
# HANDOFF §12.2 already established this LMCache build uses for these two
# backend names on the in-process path.
#
# JSON schema (read from NixlStoreL2AdapterConfig.from_dict(),
# nixl_store_l2_adapter.py:1125-1144, and ROUND-TRIPPED against the
# INSTALLED parser inside rocm-aic:mp-pd-ionic2609 — see this change's
# accompanying report for the exact command/output):
#   {"type":"nixl_store","backend":"<XNVME_KV|SPDK_NVMe_KV>",
#    "backend_params":{...string key/value pairs...},"pool_size":<int>0}
#
# backend_params is forwarded VERBATIM to
# nixl_agent.create_backend(backend, backend_params)
# (nixl_store_l2_adapter.py:201) — the same NIXL plugin init path
# gen-kv-transfer-config.sh's NixlConnector side and the in-process
# LMCacheConnectorV1 YAML surface (removed, see TODO 6.23) both use. Each
# plugin's C++ constructor prefers an env var
# over this dict over its own compiled-in default (verified directly in
# plugins/xnvme-kv/xnvme_kv_backend.cpp:508-520 for XNVME_KV's "dev_uri" and
# plugins/nvme-kv/spdk_nvme_kv_backend.cpp:602-611 for SPDK's "trid"), so
# calling setup_nixl_kv_env below (which exports NIXL_XNVME_DEV/NIXL_KV_TRID)
# and ALSO putting the same resolved value in backend_params is
# defense-in-depth, not two competing sources of truth.
#
# ───────────────────────────────────────────────────────────────────────────
# THE CONTENT-DERIVED-KEY CONSTRAINT — why this tier CANNOT be shared
# between nodes or across a restart. Relocated here 2026-09-16 from the
# in-process LMCacheConnectorV1 YAML surface, which was deleted along with
# the rest of that config path (TODO 6.23). It was written about the
# in-process backend's nixl_pool_size; the MP adapter this script actually
# configures turns out to behave the SAME WAY, for the same reason, and the
# note is load-bearing enough that losing it with the file would have been a
# real regression. Restated below against the MP adapter, with the evidence
# re-measured on the INSTALLED lmcache 0.5.3.
#
# The in-process backend chose between two implementations on pool_size:
#   pool_size == 0 -> NixlDynamicStorageBackend — CONTENT-derived keys
#                     (_format_object_key() hashes the CacheEngineKey:
#                     model + chunk-hash + token content, i.e. the SAME
#                     bytes in every process that sees the same prefix).
#   pool_size  > 0 -> NixlStaticStorageBackend  — a pool of PRE-ALLOCATED
#                     slot names carrying a per-process random uuid4.
#
# The MP static adapter ("nixl_store", the one this script emits) is the
# second kind, and it is NOT optional here: pool_size is validated as
# "required, >0" (nixl_store_l2_adapter.py:~1160), so there is no pool_size=0
# escape hatch to the content-derived behaviour on this path. Its object
# names are built at nixl_store_l2_adapter.py:407 as
#
#     key = f"obj_{i}_{uuid.uuid4().hex[0:4]}"
#
# — slot index plus a fresh uuid4 generated independently by EVERY daemon
# process at startup. So prefill's and decode's names for byte-identical
# cached content share nothing but the "obj_{i}_" prefix, and no amount of
# index-keeping, existence-probing or plugin work can bridge that: the
# receiver cannot guess the uuid4 the writer happened to draw. This is the
# measured root cause behind TODO 6.21 (prefill stored 238,903 objects /
# 978 MB; a restarted decode handed the identical prompt recomputed all of
# it at 0.0% external hit rate), and it is why restoring the plugin's
# queryMem() override — correct and worth keeping on its own terms — did not
# and could not change that result.
#
# Consequence to design against, not to "fix" by flipping a value: under
# this adapter the L2/KV tier is a per-daemon CAPACITY extension (spill past
# L1), never a shared cache. Cross-node KV movement is the P→D NixlConnector
# handoff's job. The content-keyed alternative is the separate
# "nixl_store_dynamic" adapter (nixl_store_dynamic_l2_adapter.py, registered
# at :871) — rejected here because it is file-oriented: it requires
# backend_params["file_path"], does os.makedirs(), and registers
# mem_type="FILE", none of which suits a KV-keyed NVMe device. Revisit only
# with a measurement.
# ───────────────────────────────────────────────────────────────────────────
#
# pool_size counts --l1-align-bytes-sized (default 4096 B — NOT overridden
# by this script) storage slots, ONE PER RAW L1 PAGE, never one per LMCache
# KV chunk (init_storage_handlers_object(), :397-446, and the
# get_memory_indices()/get_storage_indices() call chain in
# _execute_store_in_the_loop(), :880-960 — a multi-MiB LMCache chunk tiles
# into mem_size/align_bytes separate pool slots). This resolves the open
# question at HANDOFF §12.7 / tmp/TOPOLOGY-KV-DATAPATH.md §4.5 about a 10 MiB
# LMCache page against XNVME_KV's 32 KiB per-value ceiling: that tension was
# analyzed against the WRONG layer (the in-process LMCacheEngineConfig
# chunk_size). On THIS path the adapter never sees a whole chunk as one
# storage unit — only align_bytes-sized (4096 B) tiles, which stay under
# both backends' declared max_value_size. Confirmed LIVE against the
# installed plugins in rocm-aic:mp-pd-ionic2609
# (nixl_agent.get_plugin_params()): XNVME_KV declares max_value_size=32768,
# SPDK_NVMe_KV declares 524288 — both » 4096, so _resolve_mem_split()
# (:250-283) resolves mem_split_n=1 for both at this daemon's default page
# size: no adapter-level split ever engages. (XNVME_KV's own internal
# multipart splitting inside the plugin, HANDOFF §12.7's "32 KiB parts", is
# an unrelated, lower-layer mechanism and is unaffected by any of this.)
#
# LMCACHE_L2_POOL_SIZE's default (below) is the vendor's own tested value
# (rixl-bench's stack/tracks/rocm-aic/docker-compose.storage.yml, both the
# lmcache-spdk and lmcache-xnvme services) — empirically the largest pool
# that comes up in ~90s; an L1-size-matched value (5,242,880 at the default
# 20 GiB L1 / 4096 B) was still spinning at 100% CPU after 10+ minutes with
# zero forward progress. It is a tested ceiling, not a capacity-matched
# value — override LMCACHE_L2_POOL_SIZE and re-verify startup time if you
# raise it.
#
# _HYBRID_L1_SINGLE_REGION_L2_ADAPTERS (distributed/config.py:27-30) lists
# "nixl_store" as requiring a single-region L1 — but that constraint
# (validate_storage_manager_config(), distributed/config.py:283-320) only
# fires when hybrid DRAM+Device-DAX L1 overflow is ALSO configured
# (--l1-devdax-path plus a matching DAX L2 adapter). This script uses plain
# pinned-DRAM L1 only — no --l1-devdax-path, no --gds-l1-path anywhere below
# — so l1_exposes_single_memory_region() is unconditionally True here and
# the constraint never applies. Recorded so nobody adds a DAX/GDS L1 tier to
# this script without re-reading this first.
#
# Do NOT assume the L2/KV tier is actually working just because this
# script's daemon comes up healthy — confirm with a real cache round-trip
# (scripts/verify/30-verify-kv-roundtrip.sh); a bad device path or an
# unreachable target still starts this daemon cleanly and only shows up as a
# failed (or, worse, silently-empty) store/load later.

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

# ─────────────────────────────────────────────────────────────────────────────
# L2 (KV storage) adapter spec — see the "L2 (KV STORAGE) TIER" header
# comment above for the full evidence trail.
# ─────────────────────────────────────────────────────────────────────────────
# setup_nixl_kv_env (lib.sh) needs a literal prefill|decode role — not because
# the L2 adapter's behavior actually differs by role here (kv_slot_offset is
# a documented no-op under the OBJ/metaInfo path both backends take, same as
# the in-process LMCacheConnectorV1 YAML surface's own comment noted before
# that surface was removed, see TODO 6.23),
# but because the function's own signature requires it and, for XNVME_KV,
# resolving+validating XNVME_DEV by subsystem NQN (lib.sh's
# resolve_xnvme_kv_dev, including its ng0n1-boot-drive guard) is real safety
# logic this script must not reimplement. This script otherwise runs
# identically on both nodes (see the file header), so the role is detected
# from this host's addresses rather than taken as an argument — override
# with LMCACHE_DAEMON_ROLE=prefill|decode if this ever runs somewhere
# hostname -I can't resolve correctly (jump host, container netns).
_ROLE="${LMCACHE_DAEMON_ROLE:-}"
if [ -z "${_ROLE}" ]; then
    _IPS="$(hostname -I 2>/dev/null || true)"
    case " ${_IPS} " in
        *" ${PREFILL_HOST} "*) _ROLE=prefill ;;
        *" ${DECODE_HOST} "*)  _ROLE=decode ;;
        *) die "start-lmcache-daemon.sh: could not determine this" \
               " host's role — its addresses (${_IPS:-<none>}) match" \
               " neither PREFILL_HOST=${PREFILL_HOST} nor" \
               " DECODE_HOST=${DECODE_HOST}. Set" \
               " LMCACHE_DAEMON_ROLE=prefill|decode explicitly, or fix" \
               " config/cluster.env." ;;
    esac
fi

setup_nixl_kv_env "${_ROLE}"

# --l1-align-bytes is deliberately NOT overridden below — every reference
# this repo has (the vendor's own docker-compose.storage.yml, and the
# in-process LMCacheConnectorV1 YAML surface's own KV_MAX_VALUE_SIZE_EFFECTIVE
# headroom reasoning, before that surface was removed — TODO 6.23) leaves it
# at the built-in default (4096 B), and the
# "L2 (KV STORAGE) TIER" comment above shows why that default keeps
# mem_split_n=1 for both backends. LMCACHE_L2_POOL_SIZE's default is the
# vendor's own tested value — see that same comment.
_L2_POOL_SIZE="${LMCACHE_L2_POOL_SIZE:-2000000}"

case "${_ROLE}" in
    prefill) _SLOT_OFFSET="${KV_SLOT_OFFSET_PREFILL}" ;;
    decode)  _SLOT_OFFSET="${KV_SLOT_OFFSET_DECODE}"  ;;
esac

# Matches the in-process LMCacheConnectorV1 YAML surface's own KV_BACKEND
# branching (removed, see TODO 6.23) — both arms it supported are supported
# here too. backend_params keys per backend are
# exactly what each plugin's getParams() advertises (plugins/xnvme-kv/
# xnvme_kv_plugin.cpp, plugins/nvme-kv/spdk_nvme_kv_plugin.cpp) — see the
# header comment above for why setup_nixl_kv_env's env vars, not this JSON,
# are the values that actually win at the plugin if both are set.
case "${KV_BACKEND}" in
    XNVME_KV)
        [ -n "${XNVME_DEV}" ] || die "start-lmcache-daemon.sh:" \
            " KV_BACKEND=XNVME_KV but XNVME_DEV is still empty after" \
            " setup_nixl_kv_env — this should be unreachable (that function" \
            " dies on an unresolved device itself); if you see this, that" \
            " function's contract changed and this script's assumption" \
            " needs re-checking, not a workaround here."
        _L2_BACKEND_PARAMS_JSON="{\"dev_uri\":\"${XNVME_DEV}\"}"
        ;;
    SPDK_NVMe_KV)
        _L2_BACKEND_PARAMS_JSON="{\"trid\":\"${KV_TRID}\",\"kv_slot_offset\":\"${_SLOT_OFFSET}\"}"
        ;;
    *)
        die "start-lmcache-daemon.sh: KV_BACKEND must be" \
            " SPDK_NVMe_KV|XNVME_KV, got '${KV_BACKEND}' — this script only" \
            " knows the backend_params shape for those two (see plugins/" \
            "{nvme-kv,xnvme-kv}/*_plugin.cpp's getParams()); refusing to" \
            " guess a schema for an unverified backend name rather than" \
            " emit a plausible-looking --l2-adapter JSON."
        ;;
esac

_L2_ADAPTER_JSON="{\"type\":\"nixl_store\",\"backend\":\"${KV_BACKEND}\",\"backend_params\":${_L2_BACKEND_PARAMS_JSON},\"pool_size\":${_L2_POOL_SIZE}}"

# Parse the spec with the SAME installed config classes the daemon itself
# uses, before ever spawning it — a typo'd key or a bad JSON escape fails
# loudly here instead of inside the daemon subprocess's log file.
"${REPO_ROOT}/scripts/common/25-validate-lmcache-config.sh" \
    --l2-adapter-json "${_L2_ADAPTER_JSON}" \
    || die "the --l2-adapter spec this script built failed validation" \
           " (see above) — this is a bug in this script's JSON construction" \
           " or config/cluster.env's KV_BACKEND/XNVME_DEV/KV_TRID values," \
           " not something to work around."

info "ZMQ control channel: ${_MP_BIND_HOST}:${LMCACHE_MP_PORT}  HTTP frontend: ${_HTTP_HOST}:${_HTTP_PORT}"
info "L1 size: ${_L1_SIZE_GB} GiB  eviction policy: ${_EVICTION_POLICY}  chunk size: ${LMCACHE_CHUNK_SIZE}"
info "L2 (role=${_ROLE}): ${_L2_ADAPTER_JSON}"

declare -a _CMD=(
    "${VENV}/bin/python" -m lmcache.v1.multiprocess.http_server
    --host "${_MP_BIND_HOST}" --port "${LMCACHE_MP_PORT}"
    --http-host "${_HTTP_HOST}" --http-port "${_HTTP_PORT}"
    --l1-size-gb "${_L1_SIZE_GB}"
    --eviction-policy "${_EVICTION_POLICY}"
    --chunk-size "${LMCACHE_CHUNK_SIZE}"
    --l2-adapter "${_L2_ADAPTER_JSON}"
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
