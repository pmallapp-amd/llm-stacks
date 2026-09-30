#!/usr/bin/env bash
# nvme-connect-kv.sh — establish this host's kernel NVMe-oF session to the KV
# namespace, idempotently.
#
# Runs on:      a COMPUTE node (prefill or decode). Root.
# Prerequisite: the KV target is up and listening on
#               ${NVMF_TRADDR}:${NVMF_TRSVCID}.
# Next step:    scripts/{prefill,decode}/01-host-prep.sh
#
#   scripts/common/nvme-connect-kv.sh              # connect if not already
#   scripts/common/nvme-connect-kv.sh --reconnect  # tear down first, then connect
#   scripts/common/nvme-connect-kv.sh --persist    # also survive reboot
#   scripts/common/nvme-connect-kv.sh --status     # report only, change nothing
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS
# ─────────────────────────────────────────────────────────────────────────────
# Where the KV namespace lives is not the same on every lab this repo runs on:
#
#   * A locally-presented KV function (a Pensando DSC — setup 4). The card is
#     the NVMe-oF initiator; the host just sees a PCIe char device. Nothing
#     needs connecting from here, and this script correctly does nothing.
#
#   * A REMOTE namespace reached by the LINUX KERNEL nvme-of driver (setup 3).
#     Here the host IS the initiator, and `nvme connect` is a load-bearing,
#     per-boot step that nothing in this repo used to perform — a grep for
#     "nvme connect" across scripts/ returned zero hits. The device existed
#     only because someone typed the command by hand, with parameters nobody
#     recorded, and it does not survive a reboot. The failure that produces is
#     badly misleading: setup_nixl_kv_env() dies saying XNVME_DEV could not be
#     resolved, which reads like a configuration error rather than "the fabric
#     session this host depends on is simply not up".
#
# This script closes that gap WITHOUT assuming which shape a given lab is. It
# asks the target (via `nvme discover`) whether this host is supposed to be an
# initiator for ${NVMF_SUBNQN}, and only acts if the answer is yes. On setup 4
# it therefore exits 0 having changed nothing.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONNECT=0
PERSIST=0
STATUS_ONLY=0
ALREADY_LIVE=0
_dev=""

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --reconnect) RECONNECT=1 ;;
        --persist)   PERSIST=1 ;;
        --status)    STATUS_ONLY=1 ;;
        -h|--help)   usage 0 ;;
        *)           die "unknown flag: $1 (try --help)" ;;
    esac
    shift
done

# ── report helper ────────────────────────────────────────────────────────────
report_session() {
    local dev="$1"
    log "  device    : ${dev}"
    log "  transport : $(kv_ctrl_field "${dev}" transport || echo '?')"
    log "  state     : $(kv_ctrl_field "${dev}" state     || echo '?')"
    log "  subsysnqn : $(kv_ctrl_field "${dev}" subsysnqn || echo '?')"
    log "  address   : $(kv_ctrl_field "${dev}" address   || echo 'n/a (local function)')"
}

step "KV namespace session (${KV_BACKEND})"

# ── 1. Backend gate ──────────────────────────────────────────────────────────
# Only XNVME_KV talks to a /dev/ngXnY char device. SPDK_NVMe_KV opens its own
# userspace NVMe-oF connection from inside the plugin and needs no kernel
# session at all.
if [ "${KV_BACKEND}" != "XNVME_KV" ]; then
    ok "KV_BACKEND=${KV_BACKEND} does not use a kernel NVMe-oF session —" \
       " nothing to do."
    exit 0
fi

# ── 2. Already connected? ────────────────────────────────────────────────────
_existing=""
if _existing="$(resolve_xnvme_kv_dev "${NVMF_SUBNQN}")"; then
    _tr="$(kv_ctrl_field "${_existing}" transport || echo '?')"
    _st="$(kv_ctrl_field "${_existing}" state     || echo '?')"

    if [ "${STATUS_ONLY}" = "1" ]; then
        ok "KV namespace present"
        report_session "${_existing}"
        exit 0
    fi

    # A locally-presented function is not ours to connect or disconnect. Say
    # so explicitly rather than falling through into nvme-of logic.
    if [ "${_tr}" = "pcie" ]; then
        ok "KV namespace is a LOCAL PCIe function (${_existing}) — this host" \
           " is not an NVMe-oF initiator for it. Nothing to connect."
        report_session "${_existing}"
        exit 0
    fi

    if [ "${RECONNECT}" != "1" ]; then
        if [ "${_st}" = "live" ]; then
            ok "KV session already established and live — nothing to connect."
            report_session "${_existing}"
            # Fall through ONLY to run the persistence block; connecting again
            # would add a SECOND controller for the same subsystem, which
            # resolve_xnvme_kv_dev() then refuses to disambiguate.
            ALREADY_LIVE=1
            _dev="${_existing}"
            [ "${PERSIST}" = "1" ] || exit 0
        else
            warn "KV device ${_existing} exists but controller state is" \
                 " '${_st}', not 'live'. Leaving it alone: the kernel may be" \
                 " mid-reconnect and will recover on its own. Re-run with" \
                 " --reconnect to force a clean re-establish."
            report_session "${_existing}"
            exit 0
        fi
    fi
else
    [ "${STATUS_ONLY}" != "1" ] || {
        warn "No char device claims NVMF_SUBNQN='${NVMF_SUBNQN}' on this host."
        exit 0
    }
fi

require_root

if [ "${ALREADY_LIVE}" = "1" ]; then
    info "session is already live; skipping discover/connect and going" \
         " straight to persistence"
fi

if [ "${ALREADY_LIVE}" != "1" ]; then

# ── 3. Modules ───────────────────────────────────────────────────────────────
# host-prep does this too, but this script must stand alone: it runs BEFORE
# host-prep in the documented order, precisely because host-prep dies without
# a KV device.
for m in nvme_tcp nvme_fabrics; do
    modprobe "${m}" 2>/dev/null || warn "modprobe ${m} failed — continuing;" \
        " it may be built in."
done

# ── 4. Ask the target whether we are meant to be an initiator ────────────────
# THIS IS THE DISCRIMINATOR that keeps the script setup-agnostic, and it runs
# BEFORE any disconnect. We never tear down a working session unless the
# target is provably answering and offering the subsystem we want — otherwise
# a --reconnect against a dead target would leave the host with no KV device
# at all, which is strictly worse than the inherited session it replaced.
info "discovering ${NVMF_SUBNQN} at ${NVMF_TRADDR}:${NVMF_TRSVCID}"

# If a session to this exact subsystem already exists, we ALREADY KNOW this
# host is an initiator — the discover below is then only a target-liveness
# check, and its failure must not be read as "not an initiator".
#
# This distinction is not hypothetical. `nvme discover` needs to create a
# transient discovery controller, and the kernel rejects that with a bare
# `Failed to write to /dev/nvme-fabrics: Invalid argument` when the hostnqn it
# would use conflicts with an existing controller to the same target. So a
# host whose live session was connected under a DIFFERENT --hostnqn (easy to
# do by accident) fails discovery while being demonstrably reachable. Without
# this branch the script would then silently do nothing and report success,
# which is the worst of both worlds.
_disc=""
_disc_rc=0
_disc="$(nvme discover -t "${NVMF_TRTYPE,,}" -a "${NVMF_TRADDR}" \
                       -s "${NVMF_TRSVCID}" 2>&1)" || _disc_rc=$?

if [ "${_disc_rc}" != "0" ] || ! grep -qF "${NVMF_SUBNQN}" <<<"${_disc}"; then
    if [ -n "${_existing}" ]; then
        warn "nvme discover did not confirm ${NVMF_SUBNQN}, but a session to" \
             " it is already established on this host — so this host IS an" \
             " initiator and the discovery failure is incidental (commonly a" \
             " hostnqn conflict with the existing controller). Proceeding on" \
             " the strength of the live session."
        log "discover output: ${_disc}"
        # Confirm the TARGET is actually up before we tear anything down,
        # since discover can no longer be our liveness proof.
        wait_for_port "${NVMF_TRADDR}" "${NVMF_TRSVCID}" 15 || die \
            "target ${NVMF_TRADDR}:${NVMF_TRSVCID} is not accepting" \
            " connections. Refusing to disconnect a working session when" \
            " there is nothing to reconnect to."
    elif [ "${_disc_rc}" != "0" ]; then
        warn "nvme discover against ${NVMF_TRADDR}:${NVMF_TRSVCID} failed and" \
             " no session exists. This host is probably NOT an NVMe-oF" \
             " initiator for the KV namespace — on a lab where a local PCIe" \
             " function presents it, that is expected and correct. Doing" \
             " nothing."
        log "discover output: ${_disc}"
        exit 0
    fi
fi

# Discovery SUCCEEDED but named a different subsystem — that is a
# configuration error, not a topology difference, so fail loudly. (The
# discovery-failed cases are all handled above.)
if [ "${_disc_rc}" = "0" ] && ! grep -qF "${NVMF_SUBNQN}" <<<"${_disc}" \
   && [ -z "${_existing}" ]; then
    warn "The target at ${NVMF_TRADDR}:${NVMF_TRSVCID} answered discovery but" \
         " does NOT offer subsystem '${NVMF_SUBNQN}'. Refusing to connect to" \
         " something else. Subsystems it does offer:"
    grep -E 'subnqn|trsvcid|traddr' <<<"${_disc}" | sed 's/^/    /' >&2
    die "no matching subsystem at the configured target"
fi
[ "${_disc_rc}" = "0" ] && ok "target offers ${NVMF_SUBNQN}"

# ── 5. Disconnect, if asked ──────────────────────────────────────────────────
# Only reached once discovery has PROVEN the target is up and serving the
# subsystem, so the reconnect below has somewhere to land.
if [ -n "${_existing}" ] && [ "${RECONNECT}" = "1" ]; then
    warn "Disconnecting the existing session to re-establish it with this" \
         " repo's own parameters. Anything currently holding ${_existing}" \
         " open will see its I/O fail."
    nvme disconnect -n "${NVMF_SUBNQN}" || warn "nvme disconnect returned" \
        " non-zero — continuing to the connect attempt anyway."
    # Give the kernel a moment to retire the controller before re-adding it,
    # so resolve_xnvme_kv_dev() below cannot match the dying one.
    for _ in $(seq 1 20); do
        resolve_xnvme_kv_dev "${NVMF_SUBNQN}" >/dev/null 2>&1 || break
        sleep 0.5
    done
fi

# ── 6. Connect ───────────────────────────────────────────────────────────────
# --reconnect-delay / --ctrl-loss-tmo are named EXPLICITLY rather than left to
# the kernel's defaults so the numbers are ours and recorded. They also bound
# how long the plugin can see zero forward progress during a legitimate
# reconnect, which is why XNVME_STALL_TIMEOUT_SEC must exceed them — see
# config/cluster.env's note on that variable.
_hostnqn=""
case "$(hostname -I 2>/dev/null)" in
    *"${PREFILL_HOST}"*) _hostnqn="${NVMF_HOSTNQN_PREFILL:-}" ;;
    *"${DECODE_HOST}"*)  _hostnqn="${NVMF_HOSTNQN_DECODE:-}"  ;;
esac

_args=(-t "${NVMF_TRTYPE,,}" -a "${NVMF_TRADDR}" -s "${NVMF_TRSVCID}"
       -n "${NVMF_SUBNQN}" --reconnect-delay=10 --ctrl-loss-tmo=600)
[ -n "${_hostnqn}" ] && _args+=(--hostnqn="${_hostnqn}")

info "nvme connect ${_args[*]}"
if ! nvme connect "${_args[@]}"; then
    die "nvme connect to ${NVMF_SUBNQN} failed. The target answered discovery," \
        " so this is a connect-side problem — check dmesg for the kernel's" \
        " reason, and confirm nothing else already holds an exclusive session."
fi

# ── 7. Confirm, and explain what a healthy result looks like ─────────────────
_dev=""
for _ in $(seq 1 20); do
    _dev="$(resolve_xnvme_kv_dev "${NVMF_SUBNQN}")" && break
    sleep 0.5
done

if [ -z "${_dev}" ]; then
    die "nvme connect reported success but no KV char device appeared for" \
        " NQN '${NVMF_SUBNQN}'." \
        " READ THIS BEFORE 'FIXING' IT: a KV namespace is csi=1, and the" \
        " kernel CANNOT build a block device for a non-NVM command set. So" \
        " 'block device for nsid 1 not supported (csi 1)' in dmesg is" \
        " EXPECTED, and the ABSENCE of /dev/nvmeXnY beside the char node is" \
        " CORRECT — do not go looking for a block device or pin one." \
        " What this error means is that no /dev/ngXnY appeared at all." \
        " Check dmesg, and check the namespace really is csi=1 on the target."
fi

assert_kv_char_device "${_dev}"

_st="$(kv_ctrl_field "${_dev}" state || echo '?')"
[ "${_st}" = "live" ] || die "KV device ${_dev} appeared but controller state" \
    " is '${_st}', not 'live'. Refusing to report success on a session that" \
    " is not actually carrying I/O."

ok "KV session established"
report_session "${_dev}"

fi  # end: ALREADY_LIVE != 1

# ── 8. Persistence (opt-in) ──────────────────────────────────────────────────
# Opt-in because writing /etc/nvme on a shared host is a mutation, and this
# repo's rule is that mutations are explicit rather than incidental.
if [ "${PERSIST}" = "1" ]; then
    step "Making the session survive reboot"
    mkdir -p /etc/nvme
    _line="-t ${NVMF_TRTYPE,,} -a ${NVMF_TRADDR} -s ${NVMF_TRSVCID}"
    if [ -f /etc/nvme/discovery.conf ] && grep -qF -- "${_line}" /etc/nvme/discovery.conf; then
        ok "/etc/nvme/discovery.conf already carries this target"
    else
        printf '%s\n' "${_line}" >> /etc/nvme/discovery.conf
        ok "appended to /etc/nvme/discovery.conf: ${_line}"
    fi

    if systemctl list-unit-files nvmf-autoconnect.service >/dev/null 2>&1; then
        systemctl enable nvmf-autoconnect.service >/dev/null 2>&1 \
            && ok "enabled nvmf-autoconnect.service" \
            || warn "could not enable nvmf-autoconnect.service — the" \
                    " discovery.conf entry is in place, but reconnect on boot" \
                    " is not guaranteed. Verify by rebooting."
    else
        warn "nvmf-autoconnect.service is not present on this host. The" \
             " discovery.conf entry alone may not reconnect on boot —" \
             " THE ONLY REAL TEST IS A REBOOT. Re-run with --status" \
             " afterwards to confirm."
    fi
fi
