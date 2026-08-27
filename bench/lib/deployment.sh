#!/usr/bin/env bash
# bench/lib/deployment.sh — the SERVER half of a serving benchmark's provenance.
#
# Why this exists: bench/lib/provenance.sh records what the *benchmark process*
# knows, which for a serving sweep is the client invocation and nothing else.
# The deployment — per-role tensor-parallel size, GPU assignment, dtype,
# gpu-memory-utilization, whether the RCCL peer-to-peer workaround is on — lives
# in a different process that exited long before the sweep started, and any one
# of those can dominate the number.
#
# results/setup3-prefill-node/2026-08-14-llama-benchy/ is the worked
# example: stamped VERDICT: VALIDATED on the strength of its client knobs while
# both vLLM instances ran with NCCL_P2P_DISABLE=1 and
# --disable-custom-all-reduce, so tensor-parallel collectives were host-staged
# instead of going over XGMI. Nothing in the stamp said so; a hand-written
# DEPLOYMENT.md next to the result did. This file replaces that hand-written
# file with a record the deploy script writes itself.
#
# Shape follows the rest of bench/lib/: a flat KEY=value file plus a small
# resolver, no YAML, no dependency beyond coreutils + (optionally) docker,
# because these run on bare lab hosts.
#
# ── Writing (from a deploy script, once the stack is confirmed up) ────────────
#   source "${REPO_ROOT}/bench/lib/deployment.sh"
#   DEPLOY_RECORD_CONTAINERS="vllm-pd-prefill vllm-pd-decode pd-proxy" \
#   deployment_record_write "9000 8100 8000" \
#       model="${MODEL}" image="${VLLM_IMAGE}" prefill_tp="${PREFILL_TP}" ...
#
# The first argument is the list of ports this deployment answers on, most
# client-facing first. The record is written once per port, so a benchmark only
# has to know the URL it is pointed at.
#
# ── Reading (from a benchmark, via preflight.sh / provenance.sh) ──────────────
#   deployment_resolve "http://127.0.0.1:9000/v1"
#   echo "${DEPLOYMENT_STATUS}"     # CURRENT | STALE | UNVERIFIED | MISSING
#   deployment_render               # the block that goes into the stamp
#
# ── Staleness is detected, not assumed ───────────────────────────────────────
# A record that describes a deployment which is no longer running is WORSE than
# no record: it would put a confident, wrong server configuration into a stamp.
# Three independent signals, all recorded at write time:
#   boot_id        /proc/sys/kernel/random/boot_id — changes on every reboot,
#                  and a reboot definitely killed the containers.
#   container_ids  full docker IDs, which change on every `docker run`. If a
#                  recorded ID is not in `docker ps -q`, this deployment is gone
#                  (stopped, or redeployed on top of itself).
#   recorded_epoch age, reported in the stamp for a human to judge.
# When docker cannot be consulted the status is UNVERIFIED — explicitly not
# "probably fine".
#
# The state directory is preferred at /run/kv-cache-bench because /run is tmpfs:
# a reboot clears every record, so the most common staleness case cannot even
# be represented. Non-root writers fall back to $XDG_RUNTIME_DIR and then /tmp;
# readers scan all of them, so a root-deployed stack is still visible to a
# benchmark run as an ordinary user.

# ── Injectable seams (defaults are the real thing; tests override) ────────────
: "${DEPLOYMENT_RUNNING_IDS_CMD:=docker ps -q --no-trunc}"
: "${DEPLOYMENT_BOOT_ID_FILE:=/proc/sys/kernel/random/boot_id}"
# NOT written as ": ${VAR:=docker inspect --format={{.Id}}}" — the ${...:=default}
# expansion terminates at the first '}' it can, so that form silently assigns
# `docker inspect --format={{.Id` (one brace short). docker then fails to parse
# the template, every container name resolves to '?name', and deployment_check_status
# can only ever answer UNVERIFIED — which disables the stale-detection this file
# exists for. Observed on <SETUP3_PREFILL_NODE> 2026-08-14; use the plain
# assignment below, where the braces are unambiguous.
if [ -z "${DEPLOYMENT_CONTAINER_ID_CMD:-}" ]; then
    DEPLOYMENT_CONTAINER_ID_CMD='docker inspect --format={{.Id}}'
fi

DEPLOYMENT_RECORD_VERSION=1

# Populated by deployment_resolve.
DEPLOYMENT_RECORD=""        # path to the record file, empty when none
DEPLOYMENT_STATUS="MISSING" # CURRENT | STALE | UNVERIFIED | MISSING
DEPLOYMENT_STATUS_REASON=""
DEPLOYMENT_SEARCHED=""      # where we looked, for an honest "not found" message

# deployment_state_dirs — candidate directories, most preferred first.
deployment_state_dirs() {
    if [ -n "${KV_BENCH_DEPLOY_STATE_DIR:-}" ]; then
        printf '%s\n' "${KV_BENCH_DEPLOY_STATE_DIR}"
        return 0
    fi
    printf '%s\n' /run/kv-cache-bench
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        printf '%s\n' "${XDG_RUNTIME_DIR}/kv-cache-bench"
    fi
    printf '%s\n' "/tmp/kv-cache-bench-$(id -u 2>/dev/null || echo 0)"
    return 0
}

# deployment_writable_dir — first candidate we can actually create and write.
deployment_writable_dir() {
    local d
    while IFS= read -r d; do
        [ -n "${d}" ] || continue
        if mkdir -p "${d}" 2>/dev/null && [ -w "${d}" ]; then
            printf '%s' "${d}"
            return 0
        fi
    done <<EOF
$(deployment_state_dirs)
EOF
    return 1
}

# deployment_port_from_url <url> — 9000 from http://127.0.0.1:9000/v1
deployment_port_from_url() {
    local url=$1 port
    port=$(printf '%s' "${url}" | sed -E 's#^[a-zA-Z]+://[^:/]+:?([0-9]*).*#\1#')
    printf '%s' "${port}"
}

# _deployment_boot_id — empty when unreadable (a container without /proc, say)
_deployment_boot_id() {
    if [ -r "${DEPLOYMENT_BOOT_ID_FILE}" ]; then
        tr -d '[:space:]' < "${DEPLOYMENT_BOOT_ID_FILE}" 2>/dev/null || true
    fi
}

# _deployment_scrub <string> — a record is one KEY=value per line, so a value
# may not contain a newline. Tabs/CRs collapse to spaces for the same reason.
_deployment_scrub() {
    printf '%s' "$1" | tr '\n\r\t' '   '
}

# ── Writer ───────────────────────────────────────────────────────────────────
#
# deployment_record_write <ports> [KEY=VALUE ...]
#
#   <ports>   space-separated list of ports this deployment answers on, most
#             client-facing first (e.g. "9000 8100 8000" for a proxy-fronted
#             P/D pair). An identical record is written for each, so a benchmark
#             only needs to know the URL it was pointed at.
#   KEY=VALUE the RESOLVED configuration — the values the deploy script settled
#             on after applying its own defaults, not the raw environment. A
#             default that was never set explicitly is exactly the thing this
#             record exists to capture.
#
# Environment read by the writer:
#   DEPLOY_RECORD_CONTAINERS  space-separated container NAMES, resolved to full
#                             docker IDs for the staleness check.
#   DEPLOY_RECORD_SCRIPT      path recorded as the producing script
#                             (default: the outermost sourcing script).
#   DEPLOY_RECORD_DEGRADED    comma-separated list of active settings that make
#                             the numbers unrepresentative of the hardware. The
#                             preflight gate reads this key generically, so a
#                             future degrading option becomes visible to the
#                             gate by naming itself here — no new gate check.
#
# Never fatal: a deploy that cannot write its record still deploys. It says so
# loudly, and the benchmark's stamp will report the record as MISSING.
deployment_record_write() {
    local ports=$1; shift || true
    local dir file p kv
    local script=${DEPLOY_RECORD_SCRIPT:-${BASH_SOURCE[-1]:-unknown}}
    local sha="unavailable"

    if ! dir=$(deployment_writable_dir); then
        echo "WARN: no writable deployment-record directory (tried:" \
             "$(deployment_state_dirs | tr '\n' ' '))" >&2
        echo "      This deployment will show as 'NOT RECORDED' in any benchmark stamp." >&2
        return 1
    fi
    if [ -f "${script}" ] && command -v sha256sum >/dev/null 2>&1; then
        sha=$(sha256sum "${script}" 2>/dev/null | awk '{print $1}')
    fi

    # Container names -> full IDs. A name that cannot be resolved is recorded
    # as-is with a '?' marker rather than dropped, so the staleness check errs
    # towards "cannot verify" instead of "verified clean".
    local ids="" cname cid
    for cname in ${DEPLOY_RECORD_CONTAINERS:-}; do
        # shellcheck disable=SC2086  # the command is a configurable seam
        cid=$(${DEPLOYMENT_CONTAINER_ID_CMD} "${cname}" 2>/dev/null | tr -d '[:space:]')
        if [ -n "${cid}" ]; then
            ids="${ids}${ids:+ }${cid}"
        else
            ids="${ids}${ids:+ }?${cname}"
        fi
    done

    local primary; primary=$(printf '%s' "${ports}" | awk '{print $1}')
    local tmp; tmp=$(mktemp "${dir}/.deployment.XXXXXX" 2>/dev/null) || {
        echo "WARN: could not create a temp file in ${dir}; deployment record not written" >&2
        return 1
    }

    {
        echo "# kv-cache deployment record — written by bench/lib/deployment.sh"
        echo "# Read by bench/lib/{preflight,provenance}.sh to put the SERVER-side"
        echo "# configuration into a benchmark result's provenance stamp."
        echo "# Do not hand-edit: a hand-edited record is indistinguishable from a"
        echo "# real one, which is the whole failure mode this file exists to prevent."
        echo "record_version=${DEPLOYMENT_RECORD_VERSION}"
        echo "recorded_at=$(date -Is 2>/dev/null || date)"
        echo "recorded_epoch=$(date +%s)"
        echo "boot_id=$(_deployment_boot_id)"
        echo "host=$(hostname -s 2>/dev/null || echo unknown)"
        echo "fqdn=$(hostname -f 2>/dev/null || echo unknown)"
        echo "deployed_by=${USER:-$(id -un 2>/dev/null || echo unknown)}"
        echo "deploy_script=${script}"
        echo "deploy_script_sha256=${sha}"
        echo "ports=$(_deployment_scrub "${ports}")"
        echo "client_port=${primary}"
        echo "containers=$(_deployment_scrub "${DEPLOY_RECORD_CONTAINERS:-}")"
        echo "container_ids=${ids}"
        echo "degraded=$(_deployment_scrub "${DEPLOY_RECORD_DEGRADED:-}")"
        for kv in "$@"; do
            case "${kv}" in
                *=*) printf '%s=%s\n' "${kv%%=*}" "$(_deployment_scrub "${kv#*=}")" ;;
                *)   echo "WARN: deployment_record_write: ignoring non-KEY=VALUE '${kv}'" >&2 ;;
            esac
        done
    } > "${tmp}"
    chmod 0644 "${tmp}" 2>/dev/null || true

    # One record per port, installed atomically so a benchmark never reads a
    # half-written file.
    local written=""
    for p in ${ports}; do
        case "${p}" in ''|*[!0-9]*) continue ;; esac
        file="${dir}/deployment-${p}.env"
        if cp "${tmp}" "${file}.new" 2>/dev/null && mv -f "${file}.new" "${file}" 2>/dev/null; then
            written="${written}${written:+ }${file}"
        fi
    done
    rm -f "${tmp}"

    if [ -z "${written}" ]; then
        echo "WARN: deployment record could not be written under ${dir}" >&2
        return 1
    fi
    echo "  deployment record → ${dir}/deployment-{$(printf '%s' "${ports}" | tr ' ' ',')}.env"
    return 0
}

# There is deliberately no deployment_record_clear(): a torn-down stack does not
# need its record deleted, because the container-ID check already reports the
# record as STALE, which is strictly more informative than its absence.

# ── Reader ───────────────────────────────────────────────────────────────────

# deployment_find <port> — path to the record for a port, nonzero if none.
# Scans every candidate directory, so a record written by root under /run is
# found by a benchmark running as an ordinary user.
deployment_find() {
    local port=$1 dir
    DEPLOYMENT_SEARCHED=""
    [ -n "${port}" ] || return 1
    while IFS= read -r dir; do
        [ -n "${dir}" ] || continue
        DEPLOYMENT_SEARCHED="${DEPLOYMENT_SEARCHED}${DEPLOYMENT_SEARCHED:+ }${dir}/deployment-${port}.env"
        if [ -r "${dir}/deployment-${port}.env" ]; then
            printf '%s' "${dir}/deployment-${port}.env"
            return 0
        fi
    done <<EOF
$(deployment_state_dirs)
EOF
    return 1
}

# deployment_get <file> <key> — value of a key, empty when absent
deployment_get() {
    local file=$1 key=$2
    [ -r "${file}" ] || return 1
    awk -F'=' -v k="${key}" '
        /^[[:space:]]*#/ { next }
        index($0, "=") == 0 { next }
        {
            name = substr($0, 1, index($0, "=") - 1)
            if (name == k) { print substr($0, index($0, "=") + 1); exit }
        }' "${file}"
}

# deployment_check_status <file> — CURRENT | STALE | UNVERIFIED, with the reason
# on the second line. Never guesses: if docker cannot be consulted it says so.
deployment_check_status() {
    local file=$1
    local rec_boot cur_boot ids running id missing=""

    rec_boot=$(deployment_get "${file}" boot_id)
    cur_boot=$(_deployment_boot_id)
    if [ -n "${rec_boot}" ] && [ -n "${cur_boot}" ] && [ "${rec_boot}" != "${cur_boot}" ]; then
        echo "STALE"
        echo "the host has rebooted since this record was written (boot_id changed), so the \
containers it describes are certainly gone"
        return 0
    fi

    ids=$(deployment_get "${file}" container_ids)
    if [ -z "${ids}" ]; then
        echo "UNVERIFIED"
        echo "the record names no containers, so whether it still describes the running stack \
cannot be checked"
        return 0
    fi
    case "${ids}" in
        *'?'*) echo "UNVERIFIED"
               echo "the deploy script could not resolve every container to an ID (${ids}), so \
liveness cannot be checked"
               return 0 ;;
    esac

    # shellcheck disable=SC2086  # the command is a configurable seam
    if ! running=$(${DEPLOYMENT_RUNNING_IDS_CMD} 2>/dev/null); then
        echo "UNVERIFIED"
        echo "could not list running containers ('${DEPLOYMENT_RUNNING_IDS_CMD}' failed), so the \
record's liveness is unknown"
        return 0
    fi
    for id in ${ids}; do
        case " $(printf '%s' "${running}" | tr '\n' ' ') " in
            *" ${id} "*) : ;;
            *) missing="${missing}${missing:+ }${id}" ;;
        esac
    done
    if [ -n "${missing}" ]; then
        echo "STALE"
        echo "container(s) named in the record are not running (${missing}) — the stack was \
stopped or redeployed after the record was written"
        return 0
    fi
    echo "CURRENT"
    echo "every container named in the record is still running on this boot"
    return 0
}

# deployment_resolve <base-url-or-port> — find + status-check, exporting
# DEPLOYMENT_RECORD / DEPLOYMENT_STATUS / DEPLOYMENT_STATUS_REASON /
# DEPLOYMENT_DEGRADED / DEPLOYMENT_MODEL. Always returns 0; MISSING is a normal,
# reportable outcome, not an error.
deployment_resolve() {
    local target=${1:-} port out
    case "${target}" in
        ''|*[!0-9]*) port=$(deployment_port_from_url "${target}") ;;
        *) port=${target} ;;
    esac

    DEPLOYMENT_RECORD=""
    DEPLOYMENT_STATUS="MISSING"
    DEPLOYMENT_STATUS_REASON="no deployment record for port ${port:-unknown}"
    DEPLOYMENT_DEGRADED=""
    DEPLOYMENT_MODEL=""
    DEPLOYMENT_PORT="${port}"
    # Marks "already resolved for this endpoint in this shell", so the stamp
    # reuses the gate's answer instead of re-running the liveness check and
    # possibly disagreeing with the gate it was supposed to be reporting.
    DEPLOYMENT_RESOLVED_FOR="${target}"
    export DEPLOYMENT_RESOLVED_FOR

    # deployment_find runs in a command substitution, so the DEPLOYMENT_SEARCHED
    # it sets is lost with the subshell. Rebuild it here so a "not found" stamp
    # can still say exactly where it looked.
    DEPLOYMENT_SEARCHED=""
    local _d
    while IFS= read -r _d; do
        [ -n "${_d}" ] || continue
        DEPLOYMENT_SEARCHED="${DEPLOYMENT_SEARCHED}${DEPLOYMENT_SEARCHED:+ }${_d}/deployment-${port}.env"
    done <<EOF
$(deployment_state_dirs)
EOF

    if ! DEPLOYMENT_RECORD=$(deployment_find "${port}"); then
        DEPLOYMENT_RECORD=""
        export DEPLOYMENT_RECORD DEPLOYMENT_STATUS DEPLOYMENT_STATUS_REASON \
               DEPLOYMENT_DEGRADED DEPLOYMENT_MODEL DEPLOYMENT_PORT DEPLOYMENT_SEARCHED
        return 0
    fi

    out=$(deployment_check_status "${DEPLOYMENT_RECORD}")
    DEPLOYMENT_STATUS=$(printf '%s' "${out}" | head -1)
    DEPLOYMENT_STATUS_REASON=$(printf '%s' "${out}" | sed -n '2,$p' | tr '\n' ' ')
    DEPLOYMENT_DEGRADED=$(deployment_get "${DEPLOYMENT_RECORD}" degraded)
    DEPLOYMENT_MODEL=$(deployment_get "${DEPLOYMENT_RECORD}" model)
    export DEPLOYMENT_RECORD DEPLOYMENT_STATUS DEPLOYMENT_STATUS_REASON \
           DEPLOYMENT_DEGRADED DEPLOYMENT_MODEL DEPLOYMENT_PORT DEPLOYMENT_SEARCHED
    return 0
}

# deployment_age_human <file> — "3m ago" / "2h 5m ago" / "unknown"
deployment_age_human() {
    local file=$1 written now age
    written=$(deployment_get "${file}" recorded_epoch)
    case "${written}" in ''|*[!0-9]*) echo "unknown"; return 0 ;; esac
    now=$(date +%s)
    age=$((now - written))
    if [ "${age}" -lt 0 ]; then echo "in the future (clock skew?)"; return 0; fi
    if [ "${age}" -lt 60 ]; then echo "${age}s ago"; return 0; fi
    if [ "${age}" -lt 3600 ]; then echo "$((age / 60))m ago"; return 0; fi
    echo "$((age / 3600))h $(((age % 3600) / 60))m ago"
}

# deployment_render — the block that goes into a provenance stamp. Prints an
# explicit, self-explaining "NOT RECORDED" section when there is no record,
# because a silently absent server section is the same bug in a new place.
deployment_render() {
    if [ -z "${DEPLOYMENT_RECORD:-}" ]; then
        echo "status           : NOT RECORDED"
        echo "  No deployment record was found for port '${DEPLOYMENT_PORT:-unknown}'. The"
        echo "  SERVER-side configuration of this run is therefore UNKNOWN and UNATTESTED:"
        echo "  tensor-parallel size, GPU assignment, dtype, gpu-memory-utilization and any"
        echo "  performance workaround could be anything. The verdict above covers the CLIENT"
        echo "  configuration only."
        echo "  Usual causes: the server was deployed by hand or by an older deploy script;"
        echo "  a third-party endpoint (BASE_URL=... AUTO_DEPLOY=0); or the record directory"
        echo "  was not writable at deploy time."
        if [ -n "${DEPLOYMENT_SEARCHED:-}" ]; then
            echo "  Looked for:"
            # shellcheck disable=SC2086  # deliberate split: a space-separated path list
            printf '%s\n' ${DEPLOYMENT_SEARCHED} | sed 's/^/    /'
        fi
        return 0
    fi

    echo "status           : ${DEPLOYMENT_STATUS}"
    echo "  ${DEPLOYMENT_STATUS_REASON}"
    case "${DEPLOYMENT_STATUS}" in
        STALE)
            echo "  ⚠ The configuration below is NOT the configuration that served this"
            echo "    benchmark. Treat every server-side value here as wrong." ;;
        UNVERIFIED)
            echo "  ⚠ The configuration below could not be confirmed to be the one that served"
            echo "    this benchmark. Treat it as a claim, not a measurement." ;;
    esac
    echo "record           : ${DEPLOYMENT_RECORD}"
    echo "recorded         : $(deployment_age_human "${DEPLOYMENT_RECORD}") \
($(deployment_get "${DEPLOYMENT_RECORD}" recorded_at))"
    if [ -n "${DEPLOYMENT_DEGRADED:-}" ]; then
        echo "DEGRADED         : ${DEPLOYMENT_DEGRADED}"
        echo "  ^ the deployment declares these settings as performance-degrading. Numbers"
        echo "    from this run characterise a degraded deployment, not the hardware."
    fi
    echo ""
    echo "  --- resolved deployment configuration (verbatim from the record) ---"
    grep -v '^[[:space:]]*#' "${DEPLOYMENT_RECORD}" 2>/dev/null | sed 's/^/  /'
}
