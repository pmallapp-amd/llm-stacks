#!/usr/bin/env bash
# init-creds.sh — scaffold a per-setup credentials file from the template.
#
# Runs on:      any machine (your workstation is fine — this only writes files)
# Prerequisite: none
# Next step:    edit the generated file, then scripts/common/00-preflight.sh
#
# Creates creds/setup-<N>.env from config/creds.env.template and points
# creds/active.env at it. The creds/ directory is gitignored in its entirety,
# so nothing this script writes can be committed.
#
#   scripts/common/init-creds.sh 4            # create creds/setup-4.env
#   scripts/common/init-creds.sh 5 --activate # create it and make it live
#   scripts/common/init-creds.sh --show       # show which setup is active
#
# Refuses to overwrite an existing file without --force: clobbering a populated
# credentials file is unrecoverable, and the most likely time to run this by
# accident is when one already exists.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEMPLATE="${REPO_ROOT}/config/creds.env.template"
CREDS_DIR="${REPO_ROOT}/creds"
ACTIVE="${CREDS_DIR}/active.env"

SETUP=""
FORCE=0
ACTIVATE=1
SHOW=0

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force)       FORCE=1 ;;
        --activate)    ACTIVATE=1 ;;
        --no-activate) ACTIVATE=0 ;;
        --show)        SHOW=1 ;;
        -h|--help)     usage 0 ;;
        -*)            die "unknown flag: $1 (try --help)" ;;
        *)             SETUP="$1" ;;
    esac
    shift
done

# ── --show: report the current state and exit ────────────────────────────────
if [ "${SHOW}" = "1" ]; then
    step "Credentials state"
    if [ -L "${ACTIVE}" ]; then
        ok "active.env -> $(readlink "${ACTIVE}")"
    elif [ -e "${ACTIVE}" ]; then
        warn "active.env is a regular file, not a symlink to a setup-N.env"
    else
        warn "no creds/active.env — config/cluster.env will fall back to .invalid placeholders"
    fi
    if [ -d "${CREDS_DIR}" ]; then
        log "available setups:"
        found=0
        for f in "${CREDS_DIR}"/setup-*.env; do
            [ -e "${f}" ] || continue
            found=1
            printf '       %s\n' "$(basename "${f}")" >&2
        done
        [ "${found}" = "1" ] || printf '       (none)\n' >&2
    else
        log "creds/ does not exist yet"
    fi
    exit 0
fi

[ -n "${SETUP}" ] || die "which setup? e.g. $0 4   (or --show to inspect, --help for usage)"
case "${SETUP}" in
    *[!A-Za-z0-9_-]*) die "setup name '${SETUP}' must be alphanumeric, - or _ only" ;;
esac

require_file "${TEMPLATE}"

TARGET_FILE="${CREDS_DIR}/setup-${SETUP}.env"

step "Scaffolding creds/setup-${SETUP}.env"

mkdir -p "${CREDS_DIR}"
# 0700: the directory holds passwords. Harmless if it already existed as 0755,
# but a fresh one should not be world-readable.
chmod 700 "${CREDS_DIR}" 2>/dev/null || true

# Belt and braces. The .gitignore rule is /creds/, but if someone has changed
# that, writing secrets into a tracked path is exactly the mistake this whole
# arrangement exists to prevent — so verify rather than assume.
if ! git -C "${REPO_ROOT}" check-ignore -q "${TARGET_FILE}" 2>/dev/null; then
    die "creds/ is NOT gitignored — refusing to write credentials into a tracked path.
       Restore the '/creds/' line in .gitignore before running this."
fi

if [ -e "${TARGET_FILE}" ] && [ "${FORCE}" != "1" ]; then
    die "${TARGET_FILE} already exists.
       Refusing to overwrite a populated credentials file; pass --force if you
       really mean to replace it."
fi

cp "${TEMPLATE}" "${TARGET_FILE}"
# 0600 before the user has a chance to type anything into it.
chmod 600 "${TARGET_FILE}"
ok "wrote ${TARGET_FILE} (mode 0600)"

if [ "${ACTIVATE}" = "1" ]; then
    # Relative target so the symlink survives the repo being moved or cloned
    # to a different path.
    ln -sfn "setup-${SETUP}.env" "${ACTIVE}"
    ok "creds/active.env -> setup-${SETUP}.env"
else
    log "not activated; run: ln -sfn setup-${SETUP}.env creds/active.env"
fi

cat >&2 <<EOF

Next:
  1. \$EDITOR ${TARGET_FILE}
       Fill in node addresses, BMCs and credentials. Anything left unset falls
       back to a .invalid placeholder, which fails loudly rather than silently
       pointing at a real machine.
  2. Verify it loads:
       source config/cluster.env && echo "\${PREFILL_HOST} \${DECODE_HOST} \${TARGET_HOST}"
  3. scripts/common/00-preflight.sh

EOF
