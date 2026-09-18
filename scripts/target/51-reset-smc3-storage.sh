#!/usr/bin/env bash
# 51-reset-smc3-storage.sh — inspect, and optionally reset, the storage on
# SMC3 when the running nvmf_tgt was NOT started by this repo.
#
# Node:          SMC3 (target), ${TARGET_HOST}. Refuses to run elsewhere.
# Prerequisites: none beyond a reachable SMC3. Deliberately works against a
#                FOREIGN nvmf_tgt, which is the case 50-reset-namespace.sh
#                cannot handle.
# Next step:     scripts/target/04-verify-target.sh, if you reset anything.
#
# ─────────────────────────────────────────────────────────────────────────────
# READ THIS FIRST — THIS SCRIPT ALMOST CERTAINLY DOES NOT DO WHAT YOU WANT
# ─────────────────────────────────────────────────────────────────────────────
# If you came here to reclaim space because the KV namespace is full, STOP.
# Measured 2026-09-18 (TODO 6.36), with the full stack live and 972 MiB
# freshly written through /dev/ng1n1:
#
#   * SMC3's bdev_get_iostat on its only namespace read
#       read=0  bytes_read=0  write=0  bytes_written=0
#     across an nvmf_tgt uptime of 1d05h. It has never served a single I/O.
#   * SMC3's listener 1.1.0.2:4420 is TCP-UNREACHABLE from both compute
#     nodes (they have no address on 1.1.0.x — TODO 6.19).
#   * /dev/ng1n1 on the compute nodes is transport=pcie at 0000:36:00.0,
#     subsystem nqn.2019-08.com.pensando:nvm-subsystem-sn-8001-0-0,
#     mn=PDSNVME. It is a LOCAL Pensando DSC function. There is no NVMe-oF
#     connection from the host at all.
#
# The KV data this project writes terminates in the Pensando DSC/DPU's own
# store. It does not reach SMC3. **Resetting SMC3 frees exactly zero bytes
# of our KV namespace**, and if the running target belongs to another party
# it destroys THEIR data for no benefit to us.
#
# What would actually drain our KV namespace is a DSC/DPU-side operation,
# or an NVMe Format against the KV namespace — neither is implemented here,
# both are dangerous on a medium shared between smc1/smc2, and the decision
# is explicitly still open (TODO 6.34's operational note, TODO 6.36).
#
# This script exists for the legitimate case: SMC3 is OURS, our subsystem is
# on it, and we want it drained. It is written to make the illegitimate case
# hard to do by accident.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS IS SEPARATE FROM 50-reset-namespace.sh
# ─────────────────────────────────────────────────────────────────────────────
# 50- gates on `is_running "kv-target"`, which checks THIS repo's PID file.
# When another party started nvmf_tgt, that file does not exist, 50- dies
# with "kv-target is not running — nothing to reset", and the operator is
# left with no tool and a strong temptation to `pkill nvmf_tgt`. That
# temptation is the whole reason this file exists: it replaces an untracked
# manual kill with something that first tells you whose data you are about
# to destroy.
#
# usage:
#   51-reset-smc3-storage.sh                      # inspect only (default)
#   51-reset-smc3-storage.sh --reset-ours         # recreate OUR bdev via RPC
#   51-reset-smc3-storage.sh --takeover           # replace a foreign target
#
#   --i-have-agreed-ownership   required by --takeover, and by --reset-ours
#                               when any foreign subsystem is present. Named
#                               to be unpleasant to type without meaning it:
#                               SMC3 is shared and has been reconfigured out
#                               from under this project more than once
#                               (TODO 6.18).
#   KV_ASSUME_YES=1             skip the interactive confirmation (does NOT
#                               substitute for --i-have-agreed-ownership).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-kv-rpc.sh"

MODE="inspect"
OWNERSHIP_AGREED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --inspect)                  MODE="inspect"; shift ;;
        --reset-ours)               MODE="reset-ours"; shift ;;
        --takeover)                 MODE="takeover"; shift ;;
        --i-have-agreed-ownership)  OWNERSHIP_AGREED=1; shift ;;
        -h|--help)                  sed -n '1,70p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

require_root
require_host "${TARGET_HOST}" "target"

step "SMC3 storage: inspect/reset (${TARGET_NAME} / ${TARGET_HOST})"
banner_config

warn "REMINDER (TODO 6.36): this project's KV data does NOT live on SMC3." \
     " It terminates in the Pensando DSC (/dev/ng1n1 is a LOCAL PCIe" \
     " function, mn=PDSNVME). Resetting SMC3 will not reclaim any of it."

# ─────────────────────────────────────────────────────────────────────────────
# Discover the RUNNING target, rather than assuming it is ours.
#
# Both the rpc.py path and the RPC socket are read from the live process,
# not from config: a foreign nvmf_tgt may have been started from a
# different SPDK tree with a different -r socket, and driving the wrong
# socket would either fail confusingly or — worse — mutate a DIFFERENT
# target than the one being inspected.
# ─────────────────────────────────────────────────────────────────────────────
# Find the target by its EXECUTABLE, not by process name or cmdline.
#
# `pgrep -x nvmf_tgt` does NOT work and its failure is dangerous: SPDK
# renames its main thread, so /proc/<pid>/comm reads "reactor_1" (measured
# on smc3 2026-09-18, pid 2804507 serving a live subsystem). `pgrep -x`
# therefore reports nothing, and an earlier draft of this script cheerfully
# printed "no nvmf_tgt is running — nothing to reset" while a foreign
# target was actively serving another party's namespace.
#
# `pgrep -f nvmf_tgt` would match, but also matches this script, any editor
# or pager with the name in its argv, and any shell running a command that
# mentions it — a false POSITIVE here points the destructive paths below at
# a pid that is not a target at all.
#
# Resolving /proc/<pid>/exe is exact: it is the kernel's own record of what
# is executing, immune to both renames and argv coincidence.
TGT_PID=""
for _p in /proc/[0-9]*; do
    _exe="$(readlink -f "${_p}/exe" 2>/dev/null || true)"
    if [ "$(basename "${_exe:-}")" = "nvmf_tgt" ]; then
        TGT_PID="$(basename "${_p}")"
        break
    fi
done
if [ -z "${TGT_PID}" ]; then
    ok "no nvmf_tgt is running on ${TARGET_HOST} — nothing to inspect or reset."
    log "to start this repo's own target: scripts/target/03-start-kv-target.sh"
    exit 0
fi

TGT_CMDLINE="$(tr '\0' ' ' < "/proc/${TGT_PID}/cmdline" 2>/dev/null || true)"
TGT_EXE="$(readlink -f "/proc/${TGT_PID}/exe" 2>/dev/null || echo unknown)"
TGT_START="$(ps -o lstart= -p "${TGT_PID}" 2>/dev/null | tr -s ' ' || echo unknown)"

# -r <sock> if present, else SPDK's default.
TGT_SOCK="$(printf '%s' "${TGT_CMDLINE}" | sed -n 's/.*-r \([^ ]*\).*/\1/p')"
[ -n "${TGT_SOCK}" ] || TGT_SOCK="/var/tmp/spdk.sock"

# rpc.py from the same tree as the running binary, falling back to ours.
TGT_TREE="$(dirname "$(dirname "${TGT_EXE}")")"   # .../build/bin/nvmf_tgt -> .../build -> ...
TGT_RPC=""
for cand in "${TGT_TREE}/scripts/rpc.py" \
            "$(dirname "${TGT_EXE}")/../../scripts/rpc.py" \
            "${SPDK_TARGET_SRC:-/root/kv_spdk}/scripts/rpc.py"; do
    [ -x "${cand}" ] && { TGT_RPC="$(readlink -f "${cand}")"; break; }
done
[ -n "${TGT_RPC}" ] || die "cannot locate an rpc.py for the running nvmf_tgt" \
    " (exe=${TGT_EXE}). Inspect by hand before doing anything destructive."

_rpc() { "${TGT_RPC}" -s "${TGT_SOCK}" "$@"; }

# Did THIS repo start it? The PID file is the only authority — a matching
# binary path proves nothing, because a foreign operator may well have
# started the same tree.
OURS_BY_PIDFILE=0
if is_running "kv-target" 2>/dev/null; then
    _our_pid="$(cat "${RUN_DIR}/kv-target.pid" 2>/dev/null || echo "")"
    [ -n "${_our_pid}" ] && [ "${_our_pid}" = "${TGT_PID}" ] && OURS_BY_PIDFILE=1
fi

step "Running target"
log "  pid          : ${TGT_PID}"
log "  started      : ${TGT_START}"
log "  exe          : ${TGT_EXE}"
log "  rpc socket   : ${TGT_SOCK}"
log "  rpc.py       : ${TGT_RPC}"
log "  started by us: $([ "${OURS_BY_PIDFILE}" -eq 1 ] && echo yes || echo 'NO — foreign or pre-existing')"

# ─────────────────────────────────────────────────────────────────────────────
# Ownership triage. Classify every subsystem as ours or foreign, by NQN.
# ─────────────────────────────────────────────────────────────────────────────
SUBSYS_JSON="$(_rpc nvmf_get_subsystems 2>/dev/null || echo '[]')"
IOSTAT_JSON="$(_rpc bdev_get_iostat 2>/dev/null || echo '{}')"

# Staged to files rather than fed on stdin: these blocks take BOTH a heredoc
# (the program) and the JSON, and two stdin redirections silently compete —
# the heredoc wins and the JSON never arrives, so every subsystem reads as
# absent and the ownership guard below would pass vacuously. A guard that
# cannot see foreign subsystems is worse than no guard.
_SUBSYS_F="$(mktemp)"; _IOSTAT_F="$(mktemp)"
trap 'rm -f "${_SUBSYS_F}" "${_IOSTAT_F}"' EXIT
printf '%s' "${SUBSYS_JSON}" > "${_SUBSYS_F}"
printf '%s' "${IOSTAT_JSON}" > "${_IOSTAT_F}"

step "Subsystems and namespaces"
FOREIGN_COUNT="$(
python3 - "${NVMF_SUBNQN}" "${_SUBSYS_F}" <<'PY'
import json, sys
ours_nqn = sys.argv[1]
try:
    with open(sys.argv[2]) as fh:
        subs = json.load(fh)
except Exception:
    subs = []
foreign = 0
for s in subs:
    nqn = s.get("nqn", "")
    if nqn.startswith("nqn.2014-08.org.nvmexpress.discovery"):
        continue
    tag = "OURS   " if nqn == ours_nqn else "FOREIGN"
    if nqn != ours_nqn:
        foreign += 1
    print(f"  [{tag}] {nqn}", file=sys.stderr)
    for ns in s.get("namespaces", []):
        print(f"            ns{ns.get('nsid')} bdev={ns.get('bdev_name')} "
              f"uuid={ns.get('uuid')}", file=sys.stderr)
    for l in s.get("listen_addresses", []):
        print(f"            listener {l.get('trtype')} "
              f"{l.get('traddr')}:{l.get('trsvcid')}", file=sys.stderr)
print(foreign)
PY
)"

step "Per-bdev I/O counters (has anything ever used this target?)"
python3 - "${_IOSTAT_F}" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    d = {}
bdevs = d.get("bdevs", [])
if not bdevs:
    print("  (no bdevs reported)")
for b in bdevs:
    r, w = b.get("num_read_ops", 0), b.get("num_write_ops", 0)
    note = "  <-- NEVER USED" if (r == 0 and w == 0) else ""
    print(f"  {b.get('name'):<16} reads={r:<12} writes={w:<12} "
          f"bytes_read={b.get('bytes_read',0):<14} "
          f"bytes_written={b.get('bytes_written',0)}{note}")
PY

log ""
log "  our configured subsystem : ${NVMF_SUBNQN}"
log "  our configured bdev      : ${KV_BDEV_NAME}"
log "  foreign subsystems present: ${FOREIGN_COUNT}"

OURS_PRESENT=0
grep -q "${NVMF_SUBNQN}" <<<"${SUBSYS_JSON}" && OURS_PRESENT=1
log "  our subsystem on this target: $([ "${OURS_PRESENT}" -eq 1 ] && echo yes || echo NO)"

if [ "${MODE}" = "inspect" ]; then
    ok "inspection complete — nothing was modified."
    log ""
    log "to act, re-run with one of:"
    log "  --reset-ours   recreate ONLY '${KV_BDEV_NAME}' via RPC (narrow, leaves"
    log "                 the process and any foreign subsystem untouched)"
    log "  --takeover     stop this nvmf_tgt and start THIS repo's target"
    log "                 (destroys every namespace it currently serves)"
    log ""
    log "and remember: neither reclaims space in the DSC-backed KV namespace"
    log "that the compute nodes actually write to (TODO 6.36)."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Guard rails. Both destructive modes go through these.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${FOREIGN_COUNT}" -gt 0 ] && [ "${OWNERSHIP_AGREED}" -ne 1 ]; then
    die "REFUSING: ${FOREIGN_COUNT} foreign subsystem(s) are being served by" \
        " this nvmf_tgt, and --i-have-agreed-ownership was not given." \
        $'\n' "  SMC3 is shared, and has been reconfigured out from under this" \
        " project more than once (TODO 6.18). Agree ownership with the other" \
        " party BEFORE destroying their namespace — do not restart another" \
        " party's target unilaterally." \
        $'\n' "  Re-run with --i-have-agreed-ownership once you have actually" \
        " agreed it."
fi

case "${MODE}" in
# ─────────────────────────────────────────────────────────────────────────────
# reset-ours: the narrow operation. Recreate only our own bdev, leaving the
# process — and therefore every other party's namespace and every existing
# NVMe-oF association — alone. Preferred whenever it applies, because a
# process restart drops the DSC/DPU peering that currently makes
# /dev/ng1n1 work, and DSC recovery is non-deterministic and slow
# (TODO 6.26).
# ─────────────────────────────────────────────────────────────────────────────
reset-ours)
    [ "${OURS_PRESENT}" -eq 1 ] || die \
        "REFUSING: our subsystem '${NVMF_SUBNQN}' is NOT on this target," \
        " so there is nothing of ours to reset. This is the state measured" \
        " 2026-09-18 (TODO 6.18). Use --takeover if you intend to replace" \
        " the running target with this repo's own — but read TODO 6.36" \
        " first, because it will not reclaim the space you are probably" \
        " chasing."

    warn "This will DELETE and recreate bdev '${KV_BDEV_NAME}', destroying" \
         " every KV object in it. Any prefill/decode with an open qpair" \
         " against it will fail I/O until it reconnects."
    confirm "Recreate '${KV_BDEV_NAME}' via RPC?" || die "aborted by operator"

    step "Detaching namespace from ${NVMF_SUBNQN}"
    _rpc nvmf_subsystem_remove_ns "${NVMF_SUBNQN}" 1 \
        || warn "remove_ns failed (already detached?) — continuing"

    step "Deleting bdev ${KV_BDEV_NAME}"
    _rpc bdev_kvmalloc_delete "${KV_BDEV_NAME}" \
        || die "bdev_kvmalloc_delete failed — target left with the namespace" \
               " detached. Re-attach by hand or use --takeover."

    # bdev_kvmalloc_create takes name/max_key_size/max_value_size and NOTHING
    # else — no num_blocks, no block_size, no total size. It is an in-memory
    # red-black tree sized by its per-key/per-value ceilings. cluster.env
    # carries a standing note that an earlier version of this repo guessed a
    # -b/-s shape for a fork whose RPC surface was never vendored; do not
    # reintroduce it. These are the same three values lib-kv-rpc.sh's
    # kv_target_gen_json_config emits, so a reset here reproduces exactly
    # what a fresh 03-start-kv-target.sh would have created.
    step "Recreating bdev ${KV_BDEV_NAME}"
    _rpc bdev_kvmalloc_create \
         -n "${KV_BDEV_NAME}" \
         --max-key-size "${KV_BDEV_MAX_KEY_SIZE}" \
         --max-value-size "${KV_BDEV_VALUE_MAX}" \
        || die "bdev_kvmalloc_create failed — the subsystem now has NO" \
               " namespace. Fix before anything tries to use it." \
               $'\n' "  Expected params: name=${KV_BDEV_NAME}" \
               " max_key_size=${KV_BDEV_MAX_KEY_SIZE}" \
               " max_value_size=${KV_BDEV_VALUE_MAX}." \
               " If this fork's rpc.py spells them differently, check" \
               " kv_target_gen_json_config in scripts/target/lib-kv-rpc.sh —" \
               " that JSON is the authority for what this build accepts."

    step "Re-attaching namespace"
    _rpc nvmf_subsystem_add_ns "${NVMF_SUBNQN}" "${KV_BDEV_NAME}" \
        || die "add_ns failed — bdev exists but is not exported."

    ok "bdev '${KV_BDEV_NAME}' recreated and re-attached"
    ;;

# ─────────────────────────────────────────────────────────────────────────────
# takeover: the blunt operation. Stop whatever is running and bring up this
# repo's target. Everything currently served disappears.
# ─────────────────────────────────────────────────────────────────────────────
takeover)
    [ "${OWNERSHIP_AGREED}" -eq 1 ] || die \
        "REFUSING: --takeover requires --i-have-agreed-ownership." \
        " It stops a running nvmf_tgt and destroys every namespace it" \
        " serves, including any that are not ours."

    warn "This will KILL pid ${TGT_PID} (${TGT_EXE}) and start this repo's" \
         " target instead. EVERY namespace it currently serves is destroyed," \
         " including ${FOREIGN_COUNT} foreign subsystem(s)."
    warn "It also drops any DSC/DPU peering that depends on this target." \
         " DSC recovery is non-deterministic and slow (TODO 6.26) — you may" \
         " lose /dev/ng1n1 on the compute nodes for a long time, or until a" \
         " rebind (BRINGUP §1.3)."
    confirm "Stop pid ${TGT_PID} and take over SMC3?" || die "aborted by operator"

    step "Recording pre-takeover state to ${LOG_DIR}/smc3-pre-takeover.json"
    ensure_dirs
    {
        printf '{"pid":%s,"exe":"%s","started":"%s","cmdline":"%s",\n' \
            "${TGT_PID}" "${TGT_EXE}" "${TGT_START}" "${TGT_CMDLINE}"
        printf '"subsystems":%s,\n"iostat":%s}\n' "${SUBSYS_JSON}" "${IOSTAT_JSON}"
    } > "${LOG_DIR}/smc3-pre-takeover.json" 2>/dev/null \
        || warn "could not write the pre-takeover record — continuing anyway"

    step "Stopping pid ${TGT_PID}"
    kill "${TGT_PID}" 2>/dev/null || true
    for _ in $(seq 1 30); do
        kill -0 "${TGT_PID}" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "${TGT_PID}" 2>/dev/null; then
        warn "pid ${TGT_PID} did not exit on SIGTERM — sending SIGKILL"
        kill -9 "${TGT_PID}" 2>/dev/null || true
        sleep 2
    fi
    kill -0 "${TGT_PID}" 2>/dev/null \
        && die "pid ${TGT_PID} is still alive — refusing to start a second target"
    ok "previous target stopped"

    step "Starting this repo's target"
    "${REPO_ROOT}/scripts/target/03-start-kv-target.sh"
    ;;
esac

step "Post-reset verification"
if "${REPO_ROOT}/scripts/target/04-verify-target.sh"; then
    ok "smc3 storage reset complete and verified"
else
    die "reset ran but 04-verify-target.sh FAILED — the target is in an" \
        " unknown state. Do not point compute nodes at it until this is" \
        " resolved."
fi

log ""
log "NOTE: per TODO 6.36 this did not reclaim any space in the DSC-backed"
log "KV namespace the compute nodes write to. If that was the goal, the"
log "operation you need is DSC/DPU-side and is still an open decision."
