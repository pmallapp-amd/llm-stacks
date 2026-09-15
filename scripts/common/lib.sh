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
# setup_ucx_env <prefill|decode> — exports UCX_TLS and its RDMA-mode
# dependents appropriate to KV_TRANSPORT for the direct P<->D NIXL leg. Call
# this before launching a vLLM instance.
#
#   tcp   force TCP so a half-configured RoCE fabric cannot silently be used
#         (or silently fail over) during bring-up. Determinism beats speed here.
#   rdma  verbs-only over the RoCE-capable ionic device. Deliberately does
#         NOT include tcp in the list: acceptance must FAIL LOUDLY rather
#         than fall back.
#
# WHY the RDMA branch below is NOT "rc_verbs,rc_mlx5,dc,ud,self,sm" (this
# repo's OLD value, wrong on two counts, corrected 2026-09-14):
#
#   1. "rc" not reachable on this fabric. The ionic (Pensando) provider
#      exposes ud/ud_verbs to UCX but NOT rc_verbs — pinning "rc" (or the
#      mlx5-specific "rc_mlx5") fails outright on this hardware. "ib"
#      (UCX_TLS_RDMA's actual value, config/cluster.env) means verbs-only:
#      it matches whatever the device actually offers instead of pinning a
#      transport that doesn't exist here, and because it is still
#      verbs-only, it retains the "cannot silently degrade to TCP" property
#      the acceptance criterion needs — pinning "rc" achieved that same
#      property but only by accident of also being wrong.
#   2. "rocm" IS NOT OPTIONAL and IS NOT a network transport. With "ib"
#      alone, UCX loads no ROCm memory domain, so its memory-type detection
#      cannot recognize a HIP/ROCm device pointer as VRAM — it reports VRAM
#      as host memory, and NIXL's registerMem() then fails:
#        ucx_utils.cpp:576 VRAM memory is detected as host by UCX. UCX is
#          likely not configured with CUDA/ROCm support.
#        nixl_agent.cpp:468 registerMem: registration failed
#      That message is MISLEADING: the installed UCX build DOES have ROCm
#      support (HAVE_ROCM 1, uct_MODULES ":ib:rdmacm:rocm:cma", rocm_cpy/
#      rocm_ipc both enumerate in `ucx_info -d`) — it was CONFIGURED OUT by
#      UCX_TLS omitting "rocm". rocm_cpy/rocm_ipc are LOCAL memory-domain
#      components, not network transports, so adding them back cannot
#      reintroduce the TCP fallback pinning "ib" exists to prevent.
#      Recorded as BLOCKER 7, 2026-09-11.
#
# UCX_IB_ROCE_LOCAL_SUBNET=y + UCX_IB_ROCE_SUBNET_PREFIX_LEN=16 are
# MANDATORY, not tuning: every DSC3 fabric link is a /31 point-to-point, so
# prefill and decode sit in DIFFERENT IP subnets, and UCX's RoCE
# reachability check derives its compare length from the netmask by
# default — rejecting a perfectly routable peer with "unreachable IB
# device address" unless the check is told to compare at /16 instead.
#
# UCX_NET_DEVICES is looked up PER ROLE (PREFILL_UCX_NET_DEVICES /
# DECODE_UCX_NET_DEVICES), not assumed symmetric: the device index does not
# map to the same fabric plane on both hosts (e.g. ionic_2 can be a
# different physical port on SMC1 than on SMC2) — only ionic_0/ionic_1 are
# confirmed to line up. See scripts/{prefill,decode}/01-host-prep.sh for
# the per-host device/port report.
setup_ucx_env() {
    local role="${1:-}"
    local ucx_net_dev tcp_net_dev
    case "${role}" in
        prefill) ucx_net_dev="${PREFILL_UCX_NET_DEVICES}"; tcp_net_dev="${PREFILL_DATA_IF}" ;;
        decode)  ucx_net_dev="${DECODE_UCX_NET_DEVICES}";  tcp_net_dev="${DECODE_DATA_IF}"  ;;
        *) die "setup_ucx_env: role must be prefill|decode, got '${role}'" ;;
    esac

    case "${KV_TRANSPORT}" in
        tcp)
            export UCX_TLS="${UCX_TLS_TCP}"
            # Not load-bearing in TCP mode; drop the EXPORT attribute (not
            # the variable itself — `unset` would also erase cluster.env's
            # own default, breaking a LATER setup_ucx_env call for the
            # OTHER mode in the same shell/session, e.g. a verify script
            # that calls this more than once) so a stale RDMA-mode export
            # from an earlier call can't leak into a TCP-mode child process.
            export -n UCX_IB_GID_INDEX UCX_IB_ROCE_LOCAL_SUBNET \
                      UCX_IB_ROCE_SUBNET_PREFIX_LEN NCCL_CUMEM_ENABLE 2>/dev/null || true
            if [ -n "${tcp_net_dev}" ]; then
                export UCX_NET_DEVICES="${tcp_net_dev}"
            else
                # UCX_NET_DEVICES (unlike the RoCE knobs above) has no
                # cluster.env default of its own — this function is the
                # only place that ever sets it — so unsetting it outright
                # is safe here.
                unset UCX_NET_DEVICES 2>/dev/null || true
            fi
            log "UCX: TCP mode (UCX_TLS=${UCX_TLS} UCX_NET_DEVICES=${UCX_NET_DEVICES:-<auto>})"
            ;;
        rdma)
            [ -n "${ucx_net_dev}" ] || die "KV_TRANSPORT=rdma but no UCX_NET_DEVICES resolved for" \
                " role=${role} (set PREFILL_UCX_NET_DEVICES/DECODE_UCX_NET_DEVICES in" \
                " config/cluster.env)"
            export UCX_TLS="${UCX_TLS_RDMA}"
            export UCX_NET_DEVICES="${ucx_net_dev}"
            export UCX_IB_GID_INDEX
            export UCX_IB_ROCE_LOCAL_SUBNET
            export UCX_IB_ROCE_SUBNET_PREFIX_LEN
            export NCCL_CUMEM_ENABLE
            # No TCP in UCX_TLS on purpose: see function comment above.
            log "UCX: RDMA mode (UCX_TLS=${UCX_TLS} UCX_NET_DEVICES=${UCX_NET_DEVICES}" \
                " UCX_IB_GID_INDEX=${UCX_IB_GID_INDEX}" \
                " UCX_IB_ROCE_LOCAL_SUBNET=${UCX_IB_ROCE_LOCAL_SUBNET}" \
                " UCX_IB_ROCE_SUBNET_PREFIX_LEN=${UCX_IB_ROCE_SUBNET_PREFIX_LEN}" \
                " NCCL_CUMEM_ENABLE=${NCCL_CUMEM_ENABLE})"
            ;;
        *) die "invalid KV_TRANSPORT='${KV_TRANSPORT}' (expected tcp|rdma)" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# amdgpu autoload override — see docs/HANDOFF.md §2 and TODO 0.4.
#
# Both compute nodes boot with `modprobe.blacklist=amdgpu` on the kernel
# command line. Measured 2026-09-14: that flag suppresses AUTOLOAD only —
# alias/`-b` resolution, the path udev/hotplug use (`modprobe -n -v -b
# amdgpu` does nothing) — it does NOT block an explicit `modprobe amdgpu` by
# module name (`modprobe -n -v amdgpu` resolves the full 8-module chain and
# exits 0). There is no `install amdgpu /bin/false`-style hard block anywhere
# under /etc|/lib|/run/modprobe.d; the kernel cmdline is the only source.
# Because the blacklist only stops AUTOload, this does NOT survive a reboot:
# every boot, amdgpu comes back unloaded until something explicitly
# modprobes it — which is exactly what this function does, every run.
#
# ensure_amdgpu_loaded — idempotent, safe to call twice in a row:
#   - already loaded (lsmod)          -> ok, no-op.
#   - not loaded, AMDGPU_AUTOLOAD=0    -> warn and return; the caller's own
#     hard GPU gate (e.g. the rocminfo check in 01-host-prep.sh) is the
#     fallback that actually fails the script if amdgpu stays unloaded.
#   - not loaded, AMDGPU_AUTOLOAD=1 (default) -> modprobe amdgpu, then
#     VERIFY THE RESULT rather than trusting modprobe's exit code (this
#     repo's §7 invariants are all about not trusting a success code that
#     didn't actually do the thing): /dev/kfd must exist AND rocminfo must
#     report at least TP_SIZE gfx agents. `die` with a diagnostic otherwise.
#
# AMDGPU_AUTOLOAD defaults to 1 (override the blacklist) rather than 0,
# because a compute node silently serving with zero usable GPUs is worse
# than a LOGGED, defeatable override of what may be deliberate lab policy.
# Set AMDGPU_AUTOLOAD=0 to keep that policy in force and require an operator
# to run `modprobe amdgpu` by hand before host-prep will proceed.
# ─────────────────────────────────────────────────────────────────────────────
ensure_amdgpu_loaded() {
    step "amdgpu kernel module"

    # Capture lsmod's output into a variable FIRST, then grep a herestring —
    # do NOT do `lsmod | grep -q ...` directly. amdgpu (most recently
    # loaded) sorts near the TOP of lsmod's listing, so `grep -q` matches
    # and closes its end of the pipe almost immediately; lsmod's next
    # write() into the now-closed pipe then dies with SIGPIPE (exit 141),
    # and under this file's `set -o pipefail`, THAT becomes the exit status
    # of the whole `if lsmod | grep -q ...` test — a spurious "not loaded"
    # even though it plainly is. Measured on this lab's compute nodes: this
    # is not theoretical, it reproduces every time. Same species of bug as
    # TODO 2.13's `rocminfo | grep` pipefail failure, opposite direction
    # (there the FIRST command failed; here it's the SECOND command's early
    # exit that kills the first). A herestring isn't a live pipe between
    # two processes, so there is nothing left running to receive SIGPIPE.
    local _lsmod_out
    _lsmod_out="$(lsmod)"
    if grep -q '^amdgpu ' <<<"${_lsmod_out}"; then
        ok "amdgpu already loaded"
        return 0
    fi

    local _bl_pattern='modprobe\.blacklist=([[:alnum:],_-]*,)?amdgpu([,[:space:]]|$)'
    if grep -qE "${_bl_pattern}" /proc/cmdline 2>/dev/null; then
        warn "amdgpu is NOT loaded, and modprobe.blacklist=amdgpu IS present" \
             " on /proc/cmdline. That flag only suppresses AUTOLOAD" \
             " (alias/'-b' resolution — what udev uses); it does NOT block" \
             " an explicit 'modprobe amdgpu' by name (verified 2026-09-14:" \
             " 'modprobe -n -v -b amdgpu' does nothing, 'modprobe -n -v" \
             " amdgpu' resolves the full 8-module chain and exits 0). This" \
             " host cannot serve as a GPU node with amdgpu unloaded, so" \
             " this script overrides the blacklist by loading it" \
             " explicitly — and because the blacklist itself is left" \
             " untouched, this override must happen again after EVERY" \
             " reboot; that is why it lives here, in host-prep, rather" \
             " than as a one-time fix."
    else
        info "amdgpu is not loaded (no modprobe.blacklist=amdgpu on" \
             " /proc/cmdline — looks like a plain first load, not a" \
             " deliberate block)"
    fi

    if [ "${AMDGPU_AUTOLOAD:-1}" != "1" ]; then
        warn "AMDGPU_AUTOLOAD=0 — refusing to modprobe amdgpu on this" \
             " host's behalf. A boot-time blacklist may be deliberate lab" \
             " policy, so the override above is opt-out, not forced: load" \
             " it yourself ('modprobe amdgpu') and re-run, or unset" \
             " AMDGPU_AUTOLOAD to let this script do it. Either way, this" \
             " script will not silently serve with zero GPUs — whatever" \
             " GPU verification step runs right after this one will" \
             " hard-fail if amdgpu still isn't loaded."
        return 0
    fi

    info "loading amdgpu (modprobe amdgpu)"
    modprobe amdgpu 2>&1 | while IFS= read -r _mp_line; do log "  ${_mp_line}"; done || true

    # Verify the RESULT, not modprobe's exit code — see the function comment.
    local _gfx_count=0
    if [ -e /dev/kfd ] && command -v rocminfo >/dev/null 2>&1; then
        local _rocminfo_out
        _rocminfo_out="$(rocminfo 2>/dev/null || true)"
        _gfx_count="$(printf '%s\n' "${_rocminfo_out}" \
            | grep -cE 'Name:[[:space:]]+gfx[0-9a-zA-Z]*' || true)"
    fi

    if [ -e /dev/kfd ] && [ "${_gfx_count}" -ge "${TP_SIZE}" ]; then
        ok "amdgpu loaded: /dev/kfd present, rocminfo reports ${_gfx_count}" \
           " gfx agent(s) (>= TP_SIZE=${TP_SIZE})"
        return 0
    fi

    die "amdgpu still not usable after 'modprobe amdgpu'" \
        " (/dev/kfd $([ -e /dev/kfd ] && echo present || echo ABSENT)," \
        " rocminfo gfx agents=${_gfx_count}, need >= TP_SIZE=${TP_SIZE})." \
        " Likely causes: (1) a HARD block — an 'install amdgpu /bin/false'" \
        " style override under /etc/modprobe.d, /lib/modprobe.d or" \
        " /run/modprobe.d (none were present on 2026-09-14, but re-check:" \
        " grep -r amdgpu /etc/modprobe.d /lib/modprobe.d /run/modprobe.d);" \
        " (2) the amdgpu DKMS module is missing/mismatched for THIS" \
        " running kernel (dkms status | grep amdgpu; uname -r); (3) PCIe" \
        " BARs not (re)assigned by firmware for these GPUs (dmesg for" \
        " 'BAR ... no space' around the amdgpu probe — pci=realloc=off on" \
        " this cmdline means the kernel will not fix that itself on its" \
        " own); (4) the GPU's PCI device is bound to vfio-pci instead of" \
        " amdgpu (lspci -k -d 1002:74a1, check 'Kernel driver in use')." \
        " Check dmesg for the actual amdgpu probe failure first: dmesg |" \
        " grep -i amdgpu | tail -50."
}

# ─────────────────────────────────────────────────────────────────────────────
# NIXL side channel (F2) — the out-of-band handshake letting the two vLLM
# engines exchange memory descriptors BEFORE any RDMA happens. NOT the data
# path itself (that's UCX over the fabric, setup_ucx_env above) — but it
# must be reachable from the peer host, or the whole direct P<->D leg
# silently never fires.
#
# setup_pd_env <prefill|decode> — resolves and validates
# VLLM_NIXL_SIDE_CHANNEL_HOST/_PORT and exports them.
#
# WHY this refuses loopback/empty rather than letting vLLM fall back to its
# own default: vLLM's default VLLM_NIXL_SIDE_CHANNEL_HOST is a loopback
# address, which only fails once the PEER tries to connect to it — i.e.
# deep into a run, long after startup looked healthy (the local engine
# starts fine, binds its side channel on loopback, and only the SECOND
# engine's connect attempt reveals the address was never externally
# reachable). Refusing outright, at launch time, turns that into an
# immediate, unambiguous failure instead of a "why did the handoff never
# happen" investigation later.
# ─────────────────────────────────────────────────────────────────────────────
setup_pd_env() {
    local role="$1"
    local host_override port
    case "${role}" in
        prefill) host_override="${PD_SIDE_CHANNEL_HOST_PREFILL}"; port="${NIXL_SIDE_CHANNEL_PORT_PREFILL}" ;;
        decode)  host_override="${PD_SIDE_CHANNEL_HOST_DECODE}";  port="${NIXL_SIDE_CHANNEL_PORT_DECODE}"  ;;
        *) die "setup_pd_env: role must be prefill|decode, got '${role}'" ;;
    esac

    local host="${host_override}"
    if [ -z "${host}" ]; then
        host="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi

    case "${host}" in
        ""|127.*|0.0.0.0|localhost)
            die "resolved NIXL side-channel host for role=${role} is" \
                " loopback/empty ('${host}') — refusing to start. vLLM's" \
                " own default here is a loopback address that fails only" \
                " once the PEER engine tries to connect to it, long after" \
                " this process looked healthy (F2). Pin" \
                " PD_SIDE_CHANNEL_HOST_${role^^} in config/cluster.env" \
                " explicitly if \`hostname -I\` on this host doesn't return" \
                " the address the peer should use, or fix routing/hostname" \
                " config so it does."
            ;;
    esac

    export VLLM_NIXL_SIDE_CHANNEL_HOST="${host}"
    export VLLM_NIXL_SIDE_CHANNEL_PORT="${port}"
    log "NIXL side channel (role=${role}): ${VLLM_NIXL_SIDE_CHANNEL_HOST}:${VLLM_NIXL_SIDE_CHANNEL_PORT}"
}

# ─────────────────────────────────────────────────────────────────────────────
# RDMA device access preflight (F4) — presence of /dev/infiniband/uverbs*
# nodes is NOT the same as permission to open them.
#
# Measured 2026-09-11: with nodes present but unopenable, open() returns
# EPERM, ibverbs enumerates nothing, UCX reports "network device 'ionic_0:1'
# is not available" / "no usable transports", and NIXL fails createBackend
# with NIXL_ERR_BACKEND.
#
# THIS PRESENTS AS A HANG, not an obvious error: vLLM's EngineCore burns
# ~100% CPU compiling for roughly 60 seconds BEFORE it ever reaches the
# connector, so the real error only surfaces at t~90s. An earlier session
# misread that startup CPU burn as the process simply being slow and
# stopped watching before the real failure printed — this preflight exists
# so that failure happens at t=0, with a specific cause, instead of at
# t~90s looking like a stall.
#
# require_rdma_access [net_dev] — no-op (logged) unless KV_TRANSPORT=rdma.
# Call this AFTER setup_ucx_env so UCX_NET_DEVICES is already resolved if
# the caller wants to pass it through for the ibv_devinfo cross-check.
# ─────────────────────────────────────────────────────────────────────────────
require_rdma_access() {
    local net_dev="${1:-}"
    if [ "${KV_TRANSPORT}" != "rdma" ]; then
        log "require_rdma_access: skipped (KV_TRANSPORT=${KV_TRANSPORT})"
        return 0
    fi

    step "RDMA device access preflight (F4 — see require_rdma_access() in lib.sh)"

    shopt -s nullglob
    local _nodes=(/dev/infiniband/uverbs*)
    shopt -u nullglob
    [ "${#_nodes[@]}" -gt 0 ] || die "no /dev/infiniband/uverbs* device nodes present." \
        " KV_TRANSPORT=rdma requires them; without them ibverbs enumerates" \
        " nothing, UCX reports 'network device ... is not available' /" \
        " 'no usable transports', and NIXL fails createBackend with" \
        " NIXL_ERR_BACKEND. NOTE: vLLM's EngineCore burns ~100% CPU" \
        " compiling for ~60s BEFORE it ever reaches the connector, so this" \
        " failure PRESENTS AS A HANG and would only have surfaced at" \
        " t~90s if this preflight hadn't caught it first (measured" \
        " 2026-09-11)."

    local _opened=0 _n
    for _n in "${_nodes[@]}"; do
        if { exec 3<>"${_n}"; } 2>/dev/null; then
            exec 3>&- 2>/dev/null || true
            _opened=1
            break
        fi
    done
    [ "${_opened}" -eq 1 ] || die "found ${#_nodes[@]} /dev/infiniband/uverbs* node(s)" \
        " (${_nodes[*]}) but none could be OPENED (EPERM) — node presence is" \
        " NOT the same as permission to use them. Measured 2026-09-11: this" \
        " exact symptom (nodes present, unopenable) makes ibverbs enumerate" \
        " nothing, UCX report 'no usable transports', and NIXL fail" \
        " createBackend with NIXL_ERR_BACKEND — and because vLLM's" \
        " EngineCore spends ~60s compiling before it ever reaches the" \
        " connector, this PRESENTS AS A ~90-SECOND HANG, not an immediate" \
        " error. Grant read/write on these nodes (device cgroup rule, udev" \
        " rule, or group membership + IPC_LOCK capability) before retrying."

    local _memlock
    _memlock="$(ulimit -l)"
    [ "${_memlock}" = "unlimited" ] || die "memlock limit is '${_memlock}', not" \
        " unlimited — RDMA memory registration (ibv_reg_mr()) needs to pin" \
        " arbitrary amounts of userspace memory. scripts/{prefill,decode}/" \
        "01-host-prep.sh writes /etc/security/limits.d/99-kvstack.conf with" \
        " unlimited memlock, but that only takes effect in a NEW login" \
        " session — this shell (or whatever launched it) predates that" \
        " write, or the limits file is missing/wrong. Start a fresh" \
        " session and retry."

    require_cmd ibv_devinfo
    local _devinfo
    _devinfo="$(ibv_devinfo 2>/dev/null || true)"
    if printf '%s\n' "${_devinfo}" | grep -q 'state:.*PORT_ACTIVE'; then
        ok "ibv_devinfo reports at least one port PORT_ACTIVE"
    else
        die "no RDMA port reports PORT_ACTIVE in ibv_devinfo output —" \
            " KV_TRANSPORT=rdma cannot proceed without an active fabric" \
            " link. Full ibv_devinfo output:"$'\n'"${_devinfo}"
    fi
    if [ -n "${net_dev}" ]; then
        local _dev_name="${net_dev%%:*}"
        if printf '%s\n' "${_devinfo}" | grep -q "${_dev_name}"; then
            ok "configured UCX_NET_DEVICES device '${_dev_name}' present in ibv_devinfo"
        else
            warn "configured UCX_NET_DEVICES device '${_dev_name}' (from" \
                 " '${net_dev}') not seen in ibv_devinfo output — double" \
                 " check PREFILL_UCX_NET_DEVICES/DECODE_UCX_NET_DEVICES" \
                 " against THIS host's actual device name (F3: the device" \
                 " index is not guaranteed symmetric across hosts)."
        fi
    fi

    ok "RDMA device access preflight passed"
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
  compute leg (P->D): PD_ENABLED=${PD_ENABLED} PD_CONNECTOR=${PD_CONNECTOR} PD_LMCACHE_FIRST=${PD_LMCACHE_FIRST}
  nixl side channel : prefill=${NIXL_SIDE_CHANNEL_PORT_PREFILL} decode=${NIXL_SIDE_CHANNEL_PORT_DECODE}
${_C_RST}
EOF
}
