#!/usr/bin/env bash
# deploy.sh — put this repo onto the three bare nodes, and optionally run
# something there afterward.
#
# Node:          control host / workstation — anywhere with ssh reach to all
#                three nodes. NOT one of prefill/decode/target itself; this
#                is the thing that gets THEM ready, not a script that runs on
#                them.
# Prerequisites: creds/active.env populated (scripts/common/init-creds.sh)
#                with PREFILL_HOST/DECODE_HOST/TARGET_HOST resolving to real
#                addresses, not the tracked .invalid placeholders. Password
#                auth (the only kind that currently works in this lab — see
#                SECURITY POSTURE below) additionally needs `sshpass` on the
#                CONTROL host. Nothing needs installing on the remote nodes
#                beyond what's already there (git + coreutils; rsync is
#                probed for, never assumed — see "Transfer" below).
# Next step:     scripts/common/00-preflight.sh on each node — or drive it
#                straight from here:
#                  scripts/common/deploy.sh --run scripts/common/00-preflight.sh
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS
# ─────────────────────────────────────────────────────────────────────────────
# There is no shared filesystem across the three nodes, no NFS, and as of
# this writing the repo is not present on any of them — /opt/kvstack (this
# repo's STACK_ROOT) does not exist either. Every remaining bring-up step in
# docs/TODO.md §2 assumes the repo already IS on the node it names. Before
# this script, nothing in the repo could put it there: there was no ssh
# helper anywhere. This script is that mechanism, and only that mechanism —
# it does not build anything, does not start anything, and does not decide
# what runs next; --run/-- exist so an operator CAN chain a next step, but
# the default behaviour with no flags is "sync the repo and stop".
#
# ─────────────────────────────────────────────────────────────────────────────
# SECURITY POSTURE — read before pointing this at a lab you care about
# ─────────────────────────────────────────────────────────────────────────────
# Pushing creds/ to three machines (the DEFAULT):
#   Every remote script under scripts/ sources config/cluster.env, which
#   sources creds/active.env — without it, a remote script degrades to the
#   tracked .invalid placeholders and refuses to start (by design, see
#   cluster.env's own comment). So creds/ ships by default, because a repo
#   copy without it is close to useless for anything past this script. That
#   is a real tradeoff, not an oversight: it puts root passwords for ALL
#   THREE nodes onto ALL THREE nodes, so compromise of any one becomes
#   compromise of the credentials to the other two as well. Pass --no-creds
#   and provision creds another way (e.g. a per-node creds file that only
#   contains that node's own values) when that blast radius is unacceptable.
#   Every time creds/ actually gets pushed, this script logs a warn() line
#   naming the destination host, specifically so that fact is never buried
#   in otherwise-routine output.
#
# sshpass vs key auth:
#   Key-based auth is tried FIRST and is always preferred when it works.
#   Typing a password over `sshpass` is the weaker mechanism by construction
#   — the whole point of --install-key is to make this a one-time bridge:
#   authenticate once with a password, drop a public key, and every
#   subsequent run in this lab no longer needs sshpass at all. When a
#   password path IS used, the password is threaded through `sshpass -e`,
#   which reads it from the SSHPASS environment variable — deliberately
#   NEVER `sshpass -p` and NEVER a bare ssh command-line argument, because
#   both of those are visible to any other local user via `ps`. The password
#   itself is never printed, logged, or embedded in a command line this
#   script prints (including under --dry-run).
#
# Verified against THIS lab (2026-09-14):
#   - root ssh works on all three nodes with the passwords in
#     creds/active.env.
#   - Key auth does NOT currently work on any of the three.
#   - sshpass IS installed on the control host.
#   - The two compute nodes (prefill, decode) advertise
#     `publickey,keyboard-interactive` — NOT `password` — in their SSH auth
#     banner. Plain `sshpass -p`/`-e ssh ...` fails outright against them.
#     The storage target advertises `publickey,password`
#     instead. The combination `-o PubkeyAuthentication=no -o
#     PreferredAuthentications=keyboard-interactive,password` makes OpenSSH
#     answer BOTH shapes with sshpass's password, so one option set covers
#     all three nodes without per-node special-casing. This is an
#     already-observed failure mode in this lab, not theoretical — omitting
#     it is why a naive `sshpass -p ... ssh host` attempt fails silently
#     against smc1/smc2 specifically.
#
# Assumed / not independently re-verified here — this script fails loudly
# rather than silently guessing wrong where it can:
#   - Whether `rsync` exists on any given remote node. NOT assumed present:
#     probed at run time (see "Transfer" below), tar-over-ssh used whenever
#     either end lacks it.
#   - The remote login shell is bash-compatible. This script builds remote
#     command lines with bash's `printf %q` quoting (for --run/-- and the
#     tar-extraction command) — correct for root's default shell on the
#     distros in this lab, and consistent with every other script in this
#     repo already assuming bash remotely, but not re-verified per node here.
#   - Host keys are not checked (StrictHostKeyChecking=no,
#     UserKnownHostsFile=/dev/null): these are lab machines that get
#     reimaged, and a changed host key should not turn into an unattended
#     script hanging on a host-key prompt or aborting on a stale
#     known_hosts entry. This is a deliberate posture for a throwaway lab,
#     not a recommendation for a production fleet.
#   - `--install-key`'s default key is the first existing
#     `~/.ssh/id_ed25519*.pub`. Pass a path explicitly if the control host
#     uses a different key type or name.
#
# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
#   scripts/common/deploy.sh [options] [-- <remote command>]
#
# Options:
#   --node <prefill|decode|target|all|compute>
#         Which node(s) to deploy to. Repeatable. `compute` means
#         prefill+decode. Default: all three.
#   --dest <path>
#         Remote repo path. Default: ${DEPLOY_DEST:-/root/kv-cache}.
#   --install-key [pubkey.pub]
#         Install an ssh public key into the node's authorized_keys so
#         future runs don't need sshpass at all. Default key: the first of
#         ~/.ssh/id_ed25519*.pub that exists. OPT-IN ONLY — this is the one
#         thing in this script that mutates the remote host's account
#         config, so it never happens implicitly. Re-probes key auth after
#         installing and reports whether it now works.
#   --no-creds
#         Deploy the repo WITHOUT creds/. See SECURITY POSTURE above.
#   --dry-run
#         Resolve nodes, probe auth, and print the exact rsync/tar/ssh
#         command lines that would run (password always elided — see
#         SECURITY POSTURE). Writes and executes nothing, locally or
#         remotely.
#   --run <relpath>
#         Repo-relative script to execute on each node after deploy, e.g.
#         --run scripts/common/00-preflight.sh. Repeatable; run in the
#         order given, on every node that deployed successfully.
#   -- <cmd...>
#         Arbitrary remote command, run after any --run items.
#   -h, --help
#         This message.
#
# Examples:
#   scripts/common/deploy.sh --dry-run
#   scripts/common/deploy.sh --install-key
#   scripts/common/deploy.sh --node compute --run scripts/common/00-preflight.sh
#   scripts/common/deploy.sh --node target -- systemctl status nvmf_tgt

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd ssh tar

usage() {
    # Lines 105-140: the USAGE section body, between its own banner and the
    # next one. Kept as an explicit range (not a pattern match) so this
    # can't silently start matching the wrong section if headers elsewhere
    # in the file are edited later.
    sed -n '105,140p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Option parsing
# ─────────────────────────────────────────────────────────────────────────────
DEST="${DEPLOY_DEST:-/root/kv-cache}"
INSTALL_KEY=0
INSTALL_KEY_PATH=""
NO_CREDS=0
DRY_RUN=0
RUN_ITEMS=()
CMD_ARGS=()
declare -A NODE_SEL=()

while [ $# -gt 0 ]; do
    case "$1" in
        --node)
            shift; [ $# -gt 0 ] || die "--node requires an argument"
            case "$1" in
                prefill|decode|target) NODE_SEL["$1"]=1 ;;
                compute) NODE_SEL[prefill]=1; NODE_SEL[decode]=1 ;;
                all)     NODE_SEL[prefill]=1; NODE_SEL[decode]=1; NODE_SEL[target]=1 ;;
                *) die "--node: unknown value '$1' (expected prefill|decode|target|all|compute)" ;;
            esac
            ;;
        --dest)
            shift; [ $# -gt 0 ] || die "--dest requires an argument"
            DEST="$1"
            ;;
        --install-key)
            INSTALL_KEY=1
            # Optional positional pubkey path. Only consume $2 as the path if
            # it actually exists as a file — otherwise there is no reliable
            # way to tell "a pubkey path" apart from "the next flag" or "the
            # start of -- <cmd>", and silently swallowing the wrong token
            # would be worse than requiring an explicit, existing path here.
            if [ $# -gt 1 ] && [ -f "$2" ]; then
                INSTALL_KEY_PATH="$2"; shift
            fi
            ;;
        --no-creds) NO_CREDS=1 ;;
        --dry-run)  DRY_RUN=1 ;;
        --run)
            shift; [ $# -gt 0 ] || die "--run requires an argument"
            RUN_ITEMS+=("$1")
            ;;
        -h|--help) usage 0 ;;
        --) shift; CMD_ARGS=("$@"); break ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)  die "unexpected argument: '$1' (remote commands go after --)" ;;
    esac
    shift
done
DEST="${DEST%/}"
[ -n "${DEST}" ] || die "--dest resolved to an empty path"

ORDER=(prefill decode target)
SELECTED=()
for _label in "${ORDER[@]}"; do
    [ "${NODE_SEL[${_label}]:-0}" = "1" ] && SELECTED+=("${_label}")
done
[ "${#SELECTED[@]}" -gt 0 ] || SELECTED=("${ORDER[@]}")

# ─────────────────────────────────────────────────────────────────────────────
# Node resolution — host/name/user/pass per label, and the .invalid guard.
# ─────────────────────────────────────────────────────────────────────────────
declare -A NODE_HOST=( [prefill]="${PREFILL_HOST}" [decode]="${DECODE_HOST}" [target]="${TARGET_HOST}" )
declare -A NODE_NAME=( [prefill]="${PREFILL_NAME}" [decode]="${DECODE_NAME}" [target]="${TARGET_NAME}" )
declare -A NODE_USER=(
    [prefill]="${PREFILL_USER:-${SSH_USER}}"
    [decode]="${DECODE_USER:-${SSH_USER}}"
    [target]="${TARGET_USER:-${SSH_USER}}"
)
declare -A NODE_PASS=(
    [prefill]="${PREFILL_PASS:-}"
    [decode]="${DECODE_PASS:-}"
    [target]="${TARGET_PASS:-}"
)

for _label in "${SELECTED[@]}"; do
    case "${NODE_HOST[${_label}]}" in
        *.invalid)
            die "${_label} host is still the tracked placeholder" \
                " '${NODE_HOST[${_label}]}' — there is no active creds file." \
                " config/cluster.env's own comment explains why: the" \
                " .invalid TLD is used deliberately so a missing creds file" \
                " fails DNS immediately instead of silently resolving" \
                " somewhere real. Run 'scripts/common/init-creds.sh <N>'," \
                " populate creds/setup-<N>.env, point" \
                " creds/active.env at it, and re-run."
            ;;
    esac
done

step "deploy.sh: dest=${DEST} nodes=${SELECTED[*]}$([ "${DRY_RUN}" = "1" ] && echo ' (DRY RUN)')"

# ─────────────────────────────────────────────────────────────────────────────
# Auth — decided ONCE per host, cached in AUTH_MODE[label] = key|password.
# ─────────────────────────────────────────────────────────────────────────────
declare -A AUTH_MODE=()

# Deliberately no StrictHostKeyChecking / persistent known_hosts — see
# SECURITY POSTURE above for why that's the right call for this lab.
SSH_BASE_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# probe_auth <label> — tries key auth, falls back to password auth via
# sshpass, dies (naming the host) if neither is usable. Idempotent: a
# second call for the same label is a no-op.
probe_auth() {
    local label="$1"
    [ -n "${AUTH_MODE[${label}]:-}" ] && return 0
    local host="${NODE_HOST[${label}]}" user="${NODE_USER[${label}]}"
    info "probing ssh auth: ${label} (${NODE_NAME[${label}]}, ${user}@${host})"
    if ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${user}@${host}" true 2>/dev/null; then
        AUTH_MODE["${label}"]="key"
        ok "${label}: key auth works"
        return 0
    fi
    local pass="${NODE_PASS[${label}]:-}"
    if [ -z "${pass}" ]; then
        die "${label} (${user}@${host}): key auth failed and no password is" \
            " set (${label^^}_PASS in creds/active.env is empty or unset)." \
            " Populate it, or bootstrap key auth once with --install-key."
    fi
    command -v sshpass >/dev/null 2>&1 || die "${label} (${user}@${host}):" \
        " key auth failed and 'sshpass' is not installed on this control" \
        " host — install it, or run with --install-key once key auth is" \
        " otherwise reachable, or fix key auth directly."
    # -o PubkeyAuthentication=no + PreferredAuthentications=keyboard-
    # interactive,password: REQUIRED here, not optional hardening — see
    # SECURITY POSTURE above. Without it this fails on smc1/smc2 specifically
    # (they advertise keyboard-interactive, not password) even though the
    # password is correct.
    if SSHPASS="${pass}" sshpass -e ssh "${SSH_BASE_OPTS[@]}" \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=keyboard-interactive,password \
        "${user}@${host}" true 2>/dev/null; then
        AUTH_MODE["${label}"]="password"
        ok "${label}: password auth works (key auth not available yet — consider --install-key)"
    else
        die "${label} (${user}@${host}): both key auth and sshpass" \
            " password auth failed. Check ${label^^}_PASS in" \
            " creds/active.env, and that the account isn't locked out" \
            " (e.g. by fail2ban after earlier failed attempts)."
    fi
}

# build_ssh_argv <label> — sets global SSH_ARGV=() to the argv PREFIX (up to
# and including ssh's own options) appropriate to that label's cached auth
# mode. Never contains the password itself; password-mode callers must set
# SSHPASS in the environment of the actual invocation (see run_ssh below).
build_ssh_argv() {
    local label="$1"
    SSH_ARGV=()
    if [ "${AUTH_MODE[${label}]}" != "key" ]; then
        SSH_ARGV+=(sshpass -e)
    fi
    SSH_ARGV+=(ssh "${SSH_BASE_OPTS[@]}")
    if [ "${AUTH_MODE[${label}]}" = "key" ]; then
        SSH_ARGV+=(-o BatchMode=yes)
    else
        # shellcheck disable=SC2054 # the comma is inside PreferredAuthentications's
        # VALUE (keyboard-interactive,password), not an array-element separator —
        # this is one array element, correctly comma-joined ssh option syntax.
        SSH_ARGV+=(-o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password)
    fi
}

# run_ssh <label> <remote-cmd-string> — execute one command on the node.
# Safe to use as the receiving end of a local pipe (e.g. tar | run_ssh ...).
run_ssh() {
    local label="$1"; shift
    build_ssh_argv "${label}"
    if [ "${AUTH_MODE[${label}]}" = "key" ]; then
        "${SSH_ARGV[@]}" "${NODE_USER[${label}]}@${NODE_HOST[${label}]}" "$@"
    else
        SSHPASS="${NODE_PASS[${label}]}" "${SSH_ARGV[@]}" "${NODE_USER[${label}]}@${NODE_HOST[${label}]}" "$@"
    fi
}

# describe_ssh <label> — a human-readable, password-free rendering of the
# ssh invocation for --dry-run output. Safe to print: SSHPASS's VALUE never
# appears here, only the fact that sshpass would be used.
describe_ssh() {
    local label="$1"
    build_ssh_argv "${label}"
    printf '%q ' "${SSH_ARGV[@]}" "${NODE_USER[${label}]}@${NODE_HOST[${label}]}"
}

# rsync_e_string <label> — the single-string -e argument rsync wants, built
# the same way as SSH_ARGV. None of our -o values contain spaces, so plain
# whitespace-joining (which is all rsync's -e parsing does) is sufficient.
rsync_e_string() {
    local label="$1"
    build_ssh_argv "${label}"
    printf '%s ' "${SSH_ARGV[@]}"
}

for _label in "${SELECTED[@]}"; do
    probe_auth "${_label}"
done

# ─────────────────────────────────────────────────────────────────────────────
# --install-key (opt-in only; never runs unless explicitly requested)
# ─────────────────────────────────────────────────────────────────────────────
DEFAULT_PUBKEY=""
if [ "${INSTALL_KEY}" = "1" ] && [ -z "${INSTALL_KEY_PATH}" ]; then
    for _f in "${HOME}/.ssh"/id_ed25519*.pub; do
        [ -f "${_f}" ] || continue
        DEFAULT_PUBKEY="${_f}"
        break
    done
fi

declare -A NODE_OK=()
ROWS=()
FAILED=0

for _label in "${SELECTED[@]}"; do
    NODE_OK["${_label}"]=1
done

if [ "${INSTALL_KEY}" = "1" ]; then
    step "Installing ssh key (opt-in, --install-key)"
    PUBKEY_PATH="${INSTALL_KEY_PATH:-${DEFAULT_PUBKEY}}"
    if [ -z "${PUBKEY_PATH}" ]; then
        die "--install-key: no path given and none of ~/.ssh/id_ed25519*.pub" \
            " exist. Pass one explicitly: --install-key /path/to/key.pub"
    fi
    require_file "${PUBKEY_PATH}"
    PUBKEY_CONTENT="$(cat "${PUBKEY_PATH}")"
    info "using public key: ${PUBKEY_PATH}"

    for _label in "${SELECTED[@]}"; do
        if [ "${AUTH_MODE[${_label}]}" = "key" ]; then
            ok "${_label}: key auth already works — nothing to install"
            ROWS+=("${_label}|install-key|SKIPPED (already works)")
            continue
        fi
        if [ "${DRY_RUN}" = "1" ]; then
            info "[dry-run] would append $(basename "${PUBKEY_PATH}") to" \
                 " ~/.ssh/authorized_keys on ${_label}" \
                 " (${NODE_USER[${_label}]}@${NODE_HOST[${_label}]}) via" \
                 " the password-auth path, then re-probe key auth"
            ROWS+=("${_label}|install-key|DRY-RUN")
            continue
        fi
        # Fed via stdin, not interpolated into the remote command string —
        # a pubkey line is public but may contain a comment field with
        # characters (spaces, @) that are simpler to pipe than to quote.
        INSTALL_SCRIPT='set -e; umask 077; mkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; key="$(cat)"; grep -qxF "$key" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"; chmod 700 "$HOME/.ssh"; chmod 600 "$HOME/.ssh/authorized_keys"'
        if run_ssh "${_label}" "${INSTALL_SCRIPT}" <<<"${PUBKEY_CONTENT}"; then
            ok "${_label}: key installed"
            if ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes \
                "${NODE_USER[${_label}]}@${NODE_HOST[${_label}]}" true 2>/dev/null; then
                AUTH_MODE["${_label}"]="key"
                ok "${_label}: key auth now works"
            else
                warn "${_label}: key installed but key auth still does not" \
                     " work (check sshd's PubkeyAuthentication and the" \
                     " account's home-directory permissions on that node)"
            fi
            ROWS+=("${_label}|install-key|OK (auth now: ${AUTH_MODE[${_label}]})")
        else
            err "${_label}: failed to install key"
            ROWS+=("${_label}|install-key|FAIL")
            NODE_OK["${_label}"]=0
            FAILED=1
        fi
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
# Transfer excludes — identical intent on both paths, syntax differs.
# ─────────────────────────────────────────────────────────────────────────────
RSYNC_EXCLUDES=(--exclude='.git/' --exclude='**/.git' --exclude='*.pyc' --exclude='__pycache__' --exclude='.nfs*' --exclude='**/.nfs*')
TAR_EXCLUDES=(--exclude=.git --exclude='*.pyc' --exclude=__pycache__ --exclude='.nfs*')
if [ "${NO_CREDS}" = "1" ]; then
    RSYNC_EXCLUDES+=(--exclude='/creds/')
    TAR_EXCLUDES+=(--exclude='./creds')
fi

# ─────────────────────────────────────────────────────────────────────────────
# Per-node deploy
# ─────────────────────────────────────────────────────────────────────────────
for _label in "${SELECTED[@]}"; do
    [ "${NODE_OK[${_label}]}" = "1" ] || continue
    _host="${NODE_HOST[${_label}]}" _user="${NODE_USER[${_label}]}"
    step "Deploying to ${_label} (${NODE_NAME[${_label}]}, ${_user}@${_host}:${DEST})"

    if [ "${NO_CREDS}" != "1" ]; then
        warn "${_label}: pushing creds/ (root passwords for ALL THREE" \
             " nodes) to ${_user}@${_host} — see this script's header" \
             " comment for the tradeoff. Use --no-creds to skip."
    fi

    # Does rsync exist on BOTH ends? Local check is free; remote check is a
    # real (read-only) probe, run even under --dry-run since it's part of
    # resolving what command WOULD be used, not a mutation.
    _use_rsync=0
    if command -v rsync >/dev/null 2>&1; then
        if run_ssh "${_label}" "command -v rsync" >/dev/null 2>&1; then
            _use_rsync=1
        fi
    fi

    if [ "${DRY_RUN}" = "1" ]; then
        if [ "${_use_rsync}" = "1" ]; then
            info "[dry-run] ${_label}: would run:" \
                 " rsync -a --delete $(printf '%q ' "${RSYNC_EXCLUDES[@]}")" \
                 " -e \"$(rsync_e_string "${_label}")\"" \
                 " ${REPO_ROOT}/ ${_user}@${_host}:${DEST}/"
        else
            info "[dry-run] ${_label}: rsync not on both ends — would run:" \
                 " tar czf - -C ${REPO_ROOT} $(printf '%q ' "${TAR_EXCLUDES[@]}") . |" \
                 " $(describe_ssh "${_label}") \"mkdir -p '${DEST}' && tar xzf - -C '${DEST}'\""
        fi
        ROWS+=("${_label}|transfer|DRY-RUN")
    else
        _xfer_ok=1
        if [ "${_use_rsync}" = "1" ]; then
            info "${_label}: transferring via rsync"
            if [ "${AUTH_MODE[${_label}]}" = "key" ]; then
                rsync -a --delete "${RSYNC_EXCLUDES[@]}" \
                    -e "$(rsync_e_string "${_label}")" \
                    "${REPO_ROOT}/" "${_user}@${_host}:${DEST}/" || _xfer_ok=0
            else
                SSHPASS="${NODE_PASS[${_label}]}" rsync -a --delete "${RSYNC_EXCLUDES[@]}" \
                    -e "$(rsync_e_string "${_label}")" \
                    "${REPO_ROOT}/" "${_user}@${_host}:${DEST}/" || _xfer_ok=0
            fi
        else
            info "${_label}: rsync not present on both ends — falling back to tar-over-ssh" \
                 " (note: unlike rsync --delete, this does not remove files on the" \
                 " remote that were deleted locally since the last deploy)"
            if ! run_ssh "${_label}" "mkdir -p $(printf '%q' "${DEST}")"; then
                _xfer_ok=0
            elif ! tar czf - -C "${REPO_ROOT}" "${TAR_EXCLUDES[@]}" . \
                | run_ssh "${_label}" "tar xzf - -C $(printf '%q' "${DEST}")"; then
                _xfer_ok=0
            fi
        fi

        if [ "${_xfer_ok}" = "1" ]; then
            ok "${_label}: transfer complete"
            ROWS+=("${_label}|transfer|OK")
        else
            err "${_label}: transfer FAILED"
            ROWS+=("${_label}|transfer|FAIL")
            NODE_OK["${_label}"]=0
            FAILED=1
            continue
        fi

        if [ "${NO_CREDS}" != "1" ]; then
            _creds_cmd="chmod 700 $(printf '%q' "${DEST}/creds") 2>/dev/null;"
            _creds_cmd+=" find $(printf '%q' "${DEST}/creds") -maxdepth 1 -type f -exec chmod 600 {} + 2>/dev/null;"
            _creds_cmd+=" test -e $(printf '%q' "${DEST}/creds/active.env")"
            if run_ssh "${_label}" "${_creds_cmd}"; then
                ok "${_label}: creds/ permissions set; active.env symlink resolves"
                ROWS+=("${_label}|creds|OK")
            else
                err "${_label}: creds/ permission fixup or active.env symlink" \
                    " verification FAILED — remote scripts on this node will" \
                    " silently fall back to .invalid placeholders until fixed"
                ROWS+=("${_label}|creds|FAIL")
                NODE_OK["${_label}"]=0
                FAILED=1
            fi
        fi
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Remote execution — --run items, then -- <cmd>. Every selected node that
# still deployed cleanly gets every item; one node's failure here does not
# stop the others (that IS the point — see run-all.sh's identical posture).
# ─────────────────────────────────────────────────────────────────────────────
for _label in "${SELECTED[@]}"; do
    [ "${NODE_OK[${_label}]}" = "1" ] || continue
    _user="${NODE_USER[${_label}]}" _host="${NODE_HOST[${_label}]}"

    for _relpath in "${RUN_ITEMS[@]}"; do
        _remote_cmd="cd $(printf '%q' "${DEST}") && ./$(printf '%q' "${_relpath}")"
        if [ "${DRY_RUN}" = "1" ]; then
            info "[dry-run] ${_label}: would run: $(describe_ssh "${_label}") \"${_remote_cmd}\""
            ROWS+=("${_label}|run:${_relpath}|DRY-RUN")
            continue
        fi
        step "${_label}: ${_relpath}"
        if run_ssh "${_label}" "${_remote_cmd} 2>&1" | sed -u "s/^/[${_label}] /"; then
            ROWS+=("${_label}|run:${_relpath}|OK")
        else
            err "${_label}: ${_relpath} FAILED"
            ROWS+=("${_label}|run:${_relpath}|FAIL")
            FAILED=1
        fi
    done

    if [ "${#CMD_ARGS[@]}" -gt 0 ]; then
        _remote_cmd="cd $(printf '%q' "${DEST}") && $(printf '%q ' "${CMD_ARGS[@]}")"
        if [ "${DRY_RUN}" = "1" ]; then
            info "[dry-run] ${_label}: would run: $(describe_ssh "${_label}") \"${_remote_cmd}\""
            ROWS+=("${_label}|cmd|DRY-RUN")
        else
            step "${_label}: ${CMD_ARGS[*]}"
            if run_ssh "${_label}" "${_remote_cmd} 2>&1" | sed -u "s/^/[${_label}] /"; then
                ROWS+=("${_label}|cmd|OK")
            else
                err "${_label}: remote command FAILED"
                ROWS+=("${_label}|cmd|FAIL")
                FAILED=1
            fi
        fi
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Summary — checks_summary (lib.sh) is a single global pass/fail counter and
# doesn't carry per-node identity, so a plain aligned table fits this
# multi-node, multi-stage result set better (same reasoning as
# scripts/verify/run-all.sh's own summary table).
# ─────────────────────────────────────────────────────────────────────────────
step "Summary"
printf '%-10s %-28s %s\n' "NODE" "STAGE" "RESULT" >&2
for _row in "${ROWS[@]}"; do
    IFS='|' read -r _rlabel _rstage _rresult <<<"${_row}"
    printf '%-10s %-28s %s\n' "${_rlabel}" "${_rstage}" "${_rresult}" >&2
done

if [ "${DRY_RUN}" = "1" ]; then
    log "DRY RUN — nothing was written and nothing ran remotely"
fi

if [ "${FAILED}" = "1" ]; then
    err "deploy: one or more nodes/stages failed — see table above"
    exit 1
fi
ok "deploy: all selected nodes succeeded"
