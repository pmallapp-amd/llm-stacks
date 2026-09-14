#!/usr/bin/env bash
# lib.sh — shared helpers for every script in this repo.
#
# Sourcing this also sources config/cluster.env, so a script needs exactly one
# line of preamble:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
#
# Intentionally dependency-free: bash, coreutils, and whatever the individual
# require_cmd calls demand. No jq, no python, nothing that needs installing
# before the host-prep script that installs things has run.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_LIB_DIR}/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../../config/cluster.env
source "${REPO_ROOT}/config/cluster.env"

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
if [ -t 2 ]; then
    _C_RST=$'\033[0m'; _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'
    _C_YEL=$'\033[33m'; _C_BLU=$'\033[34m'; _C_DIM=$'\033[2m'
else
    _C_RST=""; _C_RED=""; _C_GRN=""; _C_YEL=""; _C_BLU=""; _C_DIM=""
fi

_ts() { date +'%H:%M:%S'; }

log()  { printf '%s[%s]%s %s\n'        "${_C_DIM}" "$(_ts)" "${_C_RST}" "$*" >&2; }
info() { printf '%s[%s]%s %s==>%s %s\n' "${_C_DIM}" "$(_ts)" "${_C_RST}" "${_C_BLU}" "${_C_RST}" "$*" >&2; }
ok()   { printf '%s[%s]%s %s OK %s %s\n' "${_C_DIM}" "$(_ts)" "${_C_RST}" "${_C_GRN}" "${_C_RST}" "$*" >&2; }
warn() { printf '%s[%s]%s %sWARN%s %s\n' "${_C_DIM}" "$(_ts)" "${_C_RST}" "${_C_YEL}" "${_C_RST}" "$*" >&2; }
err()  { printf '%s[%s]%s %sFAIL%s %s\n' "${_C_DIM}" "$(_ts)" "${_C_RST}" "${_C_RED}" "${_C_RST}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Banner for the top of each numbered step script.
step() {
    printf '\n%s────────────────────────────────────────────────────────────%s\n' "${_C_BLU}" "${_C_RST}" >&2
    printf '%s  %s%s\n' "${_C_BLU}" "$*" "${_C_RST}" >&2
    printf '%s────────────────────────────────────────────────────────────%s\n' "${_C_BLU}" "${_C_RST}" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# Guards
# ─────────────────────────────────────────────────────────────────────────────
require_cmd() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ ${#missing[@]} -eq 0 ] || die "missing required command(s): ${missing[*]}"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo -E $0 $*)"
}

require_file() { [ -f "$1" ] || die "required file not found: $1"; }
require_dir()  { [ -d "$1" ] || die "required directory not found: $1"; }

# Refuse to run a node script on the wrong node. Compares every local IPv4
# against the expected address. Override with KV_SKIP_HOST_CHECK=1 (useful when
# driving a node through a jump host or inside a container with host netns).
require_host() {
    local expect="$1" role="$2"
    [ "${KV_SKIP_HOST_CHECK:-0}" = "1" ] && { warn "host check skipped (KV_SKIP_HOST_CHECK=1)"; return 0; }
    local ips
    ips="$(hostname -I 2>/dev/null || true)"
    case " ${ips} " in
        *" ${expect} "*) return 0 ;;
    esac
    die "this is the ${role} script and must run on ${expect}; this host has: ${ips:-<none>}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Waiting / retrying
# ─────────────────────────────────────────────────────────────────────────────
# retry <attempts> <sleep_sec> <cmd...>
retry() {
    local n="$1" s="$2"; shift 2
    local i=1
    while true; do
        if "$@"; then return 0; fi
        [ "$i" -ge "$n" ] && return 1
        log "attempt ${i}/${n} failed; retrying in ${s}s: $*"
        sleep "$s"; i=$((i + 1))
    done
}

# wait_for_port <host> <port> [timeout_sec]
wait_for_port() {
    local host="$1" port="$2" timeout="${3:-120}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
            exec 3>&- 2>/dev/null || true
            return 0
        fi
        sleep 1
    done
    return 1
}

# wait_for_http <url> [timeout_sec] — waits for any 2xx.
wait_for_http() {
    local url="$1" timeout="${2:-600}"
    local deadline=$(( $(date +%s) + timeout ))
    require_cmd curl
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS -o /dev/null --max-time 5 "${url}" 2>/dev/null; then return 0; fi
        sleep 2
    done
    return 1
}

# wait_for_file <path> [timeout_sec]
wait_for_file() {
    local path="$1" timeout="${2:-60}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ -e "${path}" ] && return 0
        sleep 1
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Process / PID-file management
# ─────────────────────────────────────────────────────────────────────────────
pidfile_for() { printf '%s/%s.pid' "${RUN_DIR}" "$1"; }
logfile_for() { printf '%s/%s.log' "${LOG_DIR}" "$1"; }

ensure_dirs() { mkdir -p "${RUN_DIR}" "${LOG_DIR}"; }

# start_bg <name> <cmd...> — launch detached, record pid, tee to a logfile.
start_bg() {
    local name="$1"; shift
    ensure_dirs
    local pf lf
    pf="$(pidfile_for "${name}")"; lf="$(logfile_for "${name}")"
    if is_running "${name}"; then
        die "${name} already running (pid $(cat "${pf}")); stop it first"
    fi
    info "starting ${name} -> ${lf}"
    setsid "$@" >>"${lf}" 2>&1 &
    echo $! >"${pf}"
    sleep 1
    is_running "${name}" || { err "${name} died immediately; last 40 lines:"; tail -n 40 "${lf}" >&2; return 1; }
    ok "${name} started (pid $(cat "${pf}"))"
}

is_running() {
    local pf; pf="$(pidfile_for "$1")"
    [ -f "${pf}" ] || return 1
    local pid; pid="$(cat "${pf}" 2>/dev/null || true)"
    [ -n "${pid}" ] || return 1
    kill -0 "${pid}" 2>/dev/null
}

# stop_bg <name> [grace_sec] — SIGTERM, then SIGKILL the whole process group.
stop_bg() {
    local name="$1" grace="${2:-20}"
    local pf; pf="$(pidfile_for "${name}")"
    if ! is_running "${name}"; then
        log "${name} not running"; rm -f "${pf}"; return 0
    fi
    local pid; pid="$(cat "${pf}")"
    info "stopping ${name} (pid ${pid})"
    kill -TERM "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    local deadline=$(( $(date +%s) + grace ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        kill -0 "${pid}" 2>/dev/null || { rm -f "${pf}"; ok "${name} stopped"; return 0; }
        sleep 1
    done
    warn "${name} did not exit in ${grace}s; SIGKILL"
    kill -KILL "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
    rm -f "${pf}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Networking helpers
# ─────────────────────────────────────────────────────────────────────────────
# Interface that carries traffic to <ip>, per the routing table.
iface_to() {
    local target="$1"
    ip -o route get "${target}" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

# Source IP the kernel would use to reach <ip>.
srcip_to() {
    local target="$1"
    ip -o route get "${target}" 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -1
}

# ─────────────────────────────────────────────────────────────────────────────
# UCX / NIXL transport selection
# ─────────────────────────────────────────────────────────────────────────────
# Exports UCX_TLS / UCX_NET_DEVICES appropriate to KV_TRANSPORT for the direct
# P<->D NIXL leg. Call this before launching a vLLM instance.
#
#   tcp   force TCP so a half-configured RoCE fabric cannot silently be used
#         (or silently fail over) during bring-up. Determinism beats speed here.
#   rdma  RC verbs over the RoCE-capable device. Deliberately does NOT include
#         tcp in the list: acceptance must FAIL LOUDLY rather than fall back.
setup_ucx_env() {
    local rdma_dev="${1:-}" net_dev="${2:-}"
    case "${KV_TRANSPORT}" in
        tcp)
            export UCX_TLS="tcp,self,sm"
            [ -n "${net_dev}" ] && export UCX_NET_DEVICES="${net_dev}"
            log "UCX: TCP mode (UCX_TLS=${UCX_TLS} UCX_NET_DEVICES=${UCX_NET_DEVICES:-all})"
            ;;
        rdma)
            [ -n "${rdma_dev}" ] || die "KV_TRANSPORT=rdma but no RDMA device given (set *_RDMA_DEV in config/cluster.env)"
            export UCX_TLS="rc_verbs,rc_mlx5,dc,ud,self,sm"
            export UCX_NET_DEVICES="${rdma_dev}"
            # No TCP in UCX_TLS on purpose: see function comment.
            log "UCX: RDMA mode (UCX_TLS=${UCX_TLS} UCX_NET_DEVICES=${UCX_NET_DEVICES})"
            ;;
        *) die "invalid KV_TRANSPORT='${KV_TRANSPORT}' (expected tcp|rdma)" ;;
    esac
}

# Exports the NIXL_KV_* environment the SPDK_NVMe_KV plugin reads.
# <role> is prefill|decode and only selects the key-space slot offset.
setup_nixl_kv_env() {
    local role="$1"
    export NIXL_PLUGIN_DIR
    export NIXL_KV_TRID="${KV_TRID}"
    export NIXL_KV_NUM_QPAIRS="${KV_NUM_QPAIRS}"
    export NIXL_KV_QUERY_TIMEOUT_MS="${KV_QUERY_TIMEOUT_MS}"
    export NIXL_KV_ENOMEM_TIMEOUT_SEC="${KV_ENOMEM_TIMEOUT_SEC}"
    export NIXL_KV_BACKPRESSURE_LOG_SEC="${KV_BACKPRESSURE_LOG_SEC}"
    export NIXL_KV_METRICS_INTERVAL_SEC="${NIXL_METRICS_INTERVAL_SEC}"
    # Left UNSET on purpose. Setting it to 1 makes the plugin adopt the device's
    # reported value ceiling instead of the validated constant, which silently
    # changes on-wire object geometry and lets a reader reassemble a half-stale
    # page from sub-keys written under the old split. See the getParams() comment
    # in plugins/nvme-kv/spdk_nvme_kv_plugin.cpp.
    unset NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE
    case "${role}" in
        prefill) export NIXL_KV_SLOT_OFFSET="${KV_SLOT_OFFSET_PREFILL}" ;;
        decode)  export NIXL_KV_SLOT_OFFSET="${KV_SLOT_OFFSET_DECODE}"  ;;
        *) die "setup_nixl_kv_env: role must be prefill|decode, got '${role}'" ;;
    esac
    export LD_LIBRARY_PATH="${NIXL_PREFIX}/lib/x86_64-linux-gnu:${UCX_PREFIX}/lib:${ROCM_PATH}/lib:${LD_LIBRARY_PATH:-}"
    log "NIXL_KV_TRID=${NIXL_KV_TRID}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Verification result accounting — used by scripts/verify/*
# ─────────────────────────────────────────────────────────────────────────────
_CHECKS_PASS=0
_CHECKS_FAIL=0
_FAILED_NAMES=()

# check <name> <cmd...> — runs cmd, records pass/fail, never aborts the script.
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "${name}"; _CHECKS_PASS=$((_CHECKS_PASS + 1)); return 0
    fi
    err "${name}"; _CHECKS_FAIL=$((_CHECKS_FAIL + 1)); _FAILED_NAMES+=("${name}"); return 1
}

# Non-fatal advisory check: reports but does not count toward failure.
check_soft() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${name}"; else warn "${name} (advisory)"; fi
}

checks_summary() {
    printf '\n' >&2
    if [ "${_CHECKS_FAIL}" -eq 0 ]; then
        ok "all ${_CHECKS_PASS} checks passed"
        return 0
    fi
    err "${_CHECKS_FAIL} of $((_CHECKS_PASS + _CHECKS_FAIL)) checks failed:"
    local n; for n in "${_FAILED_NAMES[@]}"; do printf '       - %s\n' "${n}" >&2; done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Misc
# ─────────────────────────────────────────────────────────────────────────────
confirm() {
    [ "${KV_ASSUME_YES:-0}" = "1" ] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

banner_config() {
    cat >&2 <<EOF
${_C_DIM}
  transport : ${KV_TRANSPORT}   (${NVMF_TRTYPE})
  prefill   : ${PREFILL_HOST}:${PREFILL_PORT}
  decode    : ${DECODE_HOST}:${DECODE_PORT}
  target    : ${TARGET_HOST}:${NVMF_TRSVCID}  subnqn=${NVMF_SUBNQN}
  model     : ${MODEL}  (TP=${TP_SIZE})
  trid      : ${KV_TRID}
${_C_RST}
EOF
}
