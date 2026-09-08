#!/usr/bin/env bash
# deploy.sh — bring up the rocm-aic stack (vLLM v0.26.0 + LMCache v0.5.3 +
# NIXL v1.3.2, unmodified) with one of our two NIXL storage plugins compiled in.
#
# Replaces the former deploy-spdk.sh / deploy-xnvme.sh / deploy-pd-spdk.sh.
#
#   BACKEND=spdk    SPDK_NVMe_KV over NVMe-oF/TCP to a remote target.
#                   RAM-backed bdev_kvmalloc in practice — category (2), a
#                   workaround for hardware unavailability, never a device
#                   measurement. This is the DEFAULT precisely because it is the
#                   path that cannot wedge real hardware.
#   BACKEND=xnvme   XNVME_KV over io_uring_cmd to a LOCAL NVMe-KV device node.
#                   Category (1) — the actual end-goal hardware. Read the safety
#                   note below before running this.
#
# Three configurations, selected by MODE and PD_ROLE:
#
#   MODE=mp                 (default) LMCache MP mode: LMCache runs as a
#                           standalone `lmcache server` in its own container and
#                           vLLM talks to it over LMCacheMPConnector. Brought up
#                           via docker compose. Single-node, kv_both.
#   MODE=inprocess          LMCache runs INSIDE vLLM (LMCacheConnectorV1),
#                           configured by a generated YAML, one plain
#                           `docker run`. Single-node, kv_both.
#   MODE=inprocess PD_ROLE=producer   prefill / STORE-only    ┐ P+D disaggregated:
#   MODE=inprocess PD_ROLE=receiver   decode  / RETRIEVE-only ┘ run once per role,
#                           on separate hosts, both pointed at the SAME target.
#                           PD_ROLE implies MODE=inprocess.
#
# WHY TWO MODES RATHER THAN ONE: `lmcache server --help` (confirmed against the
# live image 2026-08-21) has NO --pd-role/--store-location/--retrieve-locations
# flags, so the sidecar's MP-server CLI cannot express asymmetric producer/
# receiver roles at all. The in-process path is configured by a YAML file
# (LMCACHE_CONFIG_FILE) that does. They are genuinely different LMCache
# integration modes sharing one image, not one mode with a switch — the mode
# split below is that boundary, kept explicit rather than blended.
#
# NOT "PDBackend" / enable_pd. LMCache v0.5.3 has two unrelated mechanisms that
# both smell like "the P/D thing":
#   1. enable_pd / pd_role (lmcache/v1/storage_backend/pd_backend.py) — a
#      peer-to-peer transfer channel for direct producer->receiver handoff.
#      CONFIRMED UNUSABLE here: its transfer_channel requires a backend with
#      supportsRemote()==true, and spdk_nvme_kv_backend.h explicitly declares
#      `supportsRemote() const override { return false; }`.
#   2. enable_nixl_storage / store_location / retrieve_locations
#      (lmcache/v1/storage_backend/nixl_storage_backend.py) — ordinary
#      persistent L1->L2 storage. THIS is what PD_ROLE uses: two independent
#      instances against the SAME target, with vLLM's own kv_role gating
#      (vllm_v1_adapter.py:1050,1141,1661) enforcing the asymmetry. That is
#      disaggregation-via-shared-persistent-store, not a direct RDMA handoff —
#      a better fit for measuring genuine KV movement through the storage tier.
#
# STATUS. BACKEND=spdk without PD_ROLE has been built and deployed (2026-08-19);
# its STORE path was confirmed to silently fail past a size ceiling, since fixed
# and validated 2026-08-25. Every other combination is STAGED, NEVER RUN —
# derived from reading ROCm/rocm-aic @ bb386562, our own plugin/LMCache sources
# and the patches in patches/, not from an execution. Treat a first invocation as
# bring-up, not a benchmark: watch it fail, fix the actual error, and do not
# trust a number until a correctness check has passed.
#
# ⚠️  SAFETY — BACKEND=xnvme drives a real NVMe-KV device. Once a container from
# this deploy is exercising it, NEVER kill it (SIGKILL, `docker kill`, or even a
# graceful `docker stop`), and never wrap it in `timeout`. Any of those reliably
# wedges the device's CC.EN/CSTS.RDY handshake — every subsequent probe from any
# process, any host driver, Docker or native, hangs at ~100% CPU forever with no
# further log output, and the ONLY known recovery is restarting the DPU-side
# pds_dp_app from the device's own management console. Nothing host-side clears
# it: no rescan, no FLR, no setup.sh re-run. If a run needs to stop, let it
# finish or fail on its own.
#
# Contract: accepts MODEL=/PORT=, serves an OpenAI-compatible API + /health at
# http://127.0.0.1:${PORT}/v1, exits nonzero with a clear message on a missing
# prerequisite, safe to re-run against an already-healthy endpoint.
#
# Prerequisites:
#   1. SKIP_BUILD=1 bash build.sh   clone rocm-aic to the pinned commit, patch, stage
#   2. ROCM_ARCH=<arch> bash build.sh   apply patches/, `make build` the image
#   3. BACKEND=spdk : a target reachable at AIC_SPDK_KV_TRID — start one with
#                     LISTEN_ADDR=<routable-ip> bash target.sh
#      BACKEND=xnvme: the device bound to the KERNEL nvme driver (not vfio-pci),
#                     so AIC_XNVME_DEV exists. Re-check after every reboot.
#
# Override env (defaults in parentheses):
#   MODEL=<hf-name>            (TinyLlama/TinyLlama-1.1B-Chat-v1.0)
#   PORT=<n>                   (spdk 8300 / xnvme 8301 / PD 8301)
#   GPU=<n|csv>                ROCR_VISIBLE_DEVICES (sidecar 0 / PD 0,1,..,7)
#   TENSOR_PARALLEL_SIZE=<n>   (sidecar 1 / PD 8)
#   MAX_MODEL_LEN=<n>          vLLM --max-model-len. READ THIS BEFORE USING THE
#                              DEFAULT MODEL: in sidecar mode this is forwarded
#                              as VLM_MAX_MODEL_LEN and compose's own default of
#                              32768 applies when unset — which COLLIDES with
#                              TinyLlama (max_position_embeddings=2048), so vLLM
#                              refuses to start with a pydantic ValidationError.
#                              Pass MAX_MODEL_LEN=2048 for TinyLlama. Do NOT
#                              reach for VLLM_ALLOW_LONG_MAX_MODEL_LEN=1: it
#                              silences the check rather than fixing it, and
#                              TinyLlama uses RoPE, so positions past 2048
#                              produce nan — a server that runs and is wrong,
#                              which is worse than one that refuses to start.
#   DTYPE=<auto|bfloat16|...>  (PD mode only; bfloat16)
#   HF_OVERRIDES=<json>        (PD mode only; unset)
#   HF_TOKEN=<token>           required. HF_TOKEN=none is the explicit way to say
#                              "public model, already cached" so that fact lands
#                              in the deployment record instead of being smuggled
#                              in as a fake-looking token string.
#   HF_HOME=<path>             (~/.cache/huggingface)
#   ROCM_AIC_DIR=<path>        vendored checkout (<this-dir>/vendor/rocm-aic)
#   IMAGE_REF=<tag>            (rocm-aic:latest)
#   AIC_SPDK_KV_TRID=<trid>    BACKEND=spdk target
#   AIC_XNVME_DEV=<path>       BACKEND=xnvme device node (/dev/ng0n1)
#   AIC_KV_POOL=<n>            NIXL OBJ pool size (2000000) — see the note at the
#                              assignment below before changing it.
#   INSTANCE=<name>            In-process mode: this deployment's identity.
#                              Defaults to PD_ROLE, else "single", so existing
#                              names are unchanged. It determines the container
#                              name (aic-<backend>-<instance>), the LMCache
#                              config file, and the log directory. SET THIS to
#                              run a second in-process deployment on one host —
#                              without it the second deploy removes the first
#                              and rewrites the config file bind-mounted into
#                              it. deploy.sh now refuses that rather than doing
#                              it silently.
#   REPLACE=1                  Permit removing an existing running container of
#                              the same INSTANCE that is serving a DIFFERENT
#                              port. Off by default; the refusal is the point.
#   NIXL_KV_DEBUG_XFER=<n>     Diagnostic. Dump the NIXL descriptor lists for the
#                              first <n> postXfer()/queryMem() calls: per-side
#                              descriptor counts, per-descriptor lengths, the
#                              storage descriptor's metaInfo, and the derived
#                              12-byte on-device key. Unset/0 = off. IN-PROCESS
#                              MODE ONLY — the sidecar (MODE=mp) path would also
#                              need the variable added to the compose service's
#                              `environment:` list, and passing it here without
#                              that would silently do nothing.
#   AIC_SPDK_KV_SLOT_OFFSET=<n>  PD mode: per-deployment key-space offset. MUST
#                              differ between producer and receiver — both share
#                              one namespace, and identical offsets cause silent
#                              cross-instance key collision. (0)
#   AIC_NIXL_STAGING_GB=<n>    PD mode: LocalCPUBackend pinned pool used as the
#                              NIXL staging buffer. nixl_buffer_device=cpu
#                              requires max_local_cpu_size > 0 (confirmed via a
#                              real first-run ValueError). Not an L1 cache —
#                              local_cpu stays False. (8)
#   LMCACHE_L1_SIZE_GB=<n>     sidecar mode (20)
#   AIC_SPDK_PLUGIN_SO=<path>  sidecar+spdk: run a locally-built plugin .so
#                              instead of the image's baked-in copy. (unset)
#   COMPOSE_PROJECT=<name>     (rocm-aic-<backend>[-pd])
#   DEPLOY_DEGRADED=<list>     degraded-config markers for the deployment record
#                              (unvalidated-first-run[,experimental-pd-via-shared-storage])
#   DEPLOY_RECORD=0            skip writing the deployment record
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# ══ deployment record (server-side provenance) ══════════════════════════════
# Inlined rather than sourced: this stack ships as a small flat tree, and the
# reader of these records (the kv-cache benchmark harness) lives elsewhere, so a
# separate library file bought nothing here. Format and write locations are
# unchanged, so that reader still finds and parses them.
# lib/deployment.sh — the SERVER half of a serving benchmark's provenance.
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
#   source "${SCRIPT_DIR}/lib/deployment.sh"
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
        echo "# kv-cache deployment record — written by lib/deployment.sh"
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
# ══ end deployment record ═══════════════════════════════════════════════════

# ── Mode + backend resolution ────────────────────────────────────────────────
BACKEND=${BACKEND:-spdk}
case "${BACKEND}" in
    spdk|xnvme) ;;
    *) echo "ERR: BACKEND must be 'spdk' or 'xnvme', got '${BACKEND}'"; exit 1 ;;
esac

MODE=${MODE:-}
PD_ROLE=${PD_ROLE:-}
if [ -n "${PD_ROLE}" ]; then
    case "${PD_ROLE}" in
        producer|receiver) ;;
        *) echo "ERR: PD_ROLE must be 'producer' or 'receiver', got '${PD_ROLE}'"; exit 1 ;;
    esac
    # Asymmetric roles are expressible ONLY through the in-process YAML — see the
    # header: `lmcache server --help` has no --pd-role/--store-location/
    # --retrieve-locations, so MP mode cannot express P/D at all.
    MODE=${MODE:-inprocess}
    [ "${MODE}" = "inprocess" ] || {
        echo "ERR: PD_ROLE requires MODE=inprocess — MP mode's 'lmcache server'"
        echo "     CLI has no role flags, so it cannot express producer/receiver."
        exit 1; }
else
    MODE=${MODE:-mp}
fi
case "${MODE}" in
    mp|inprocess) ;;
    *) echo "ERR: MODE must be 'mp' or 'inprocess', got '${MODE}'"; exit 1 ;;
esac

if [ "${BACKEND}" = "spdk" ]; then
    NIXL_BACKEND="SPDK_NVMe_KV"
    CATEGORY="2 (RAM-backed target, no real device)"
    DEFAULT_PORT=8300
else
    NIXL_BACKEND="XNVME_KV"
    CATEGORY="1 (real NVMe-KV device — the end-goal hardware)"
    DEFAULT_PORT=8301
fi
[ "${MODE}" = "inprocess" ] && DEFAULT_PORT=8301

MODEL=${MODEL:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}
PORT=${PORT:-${DEFAULT_PORT}}
HF_HOME=${HF_HOME:-$HOME/.cache/huggingface}
ROCM_AIC_DIR=${ROCM_AIC_DIR:-${SCRIPT_DIR}/vendor/rocm-aic}
IMAGE_REF="${IMAGE_REF:-rocm-aic:latest}"
MAX_MODEL_LEN=${MAX_MODEL_LEN:-}
AIC_SPDK_KV_TRID=${AIC_SPDK_KV_TRID:-"trtype:TCP adrfam:IPv4 traddr:<SETUP3_TARGET_NODE_IP> trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0"}
AIC_XNVME_DEV=${AIC_XNVME_DEV:-/dev/ng0n1}

# NixlObjPool (the OBJ-family backends: SPDK_NVMe_KV / XNVME_KV) registers ONE
# storage object per raw L1 page — l1_align_bytes, empirically 4096 B for
# TinyLlama's fp8 KV layout, confirmed 2026-08-18 — NOT one per KV chunk. A pool
# sized "one slot per chunk" (this repo's old static default of 64) therefore
# exhausts on the first multi-page store, and NixlStorageAgent's own "nothing to
# store" fast-path reports that as a SUCCESSFUL ZERO-BYTE STORE with no warning.
#
# 2,000,000 deliberately does NOT scale with LMCACHE_L1_SIZE_GB (matching L1's
# default 20 GiB at 4096 B/page would need 5,242,880): registering that many NIXL
# OBJ descriptors was confirmed to blow up non-linearly — 2,000,000 came up
# healthy in ~90 s with real STORE traffic; 5,242,880 was still spinning at 100%+
# CPU with zero forward progress after 10+ minutes. A tested ceiling, not a
# capacity-matched value. Re-verify startup time if you raise it, or if your
# model's l1_align_bytes differs from the 4096 B assumption.
AIC_KV_POOL=${AIC_KV_POOL:-${AIC_SPDK_KV_POOL:-${AIC_XNVME_KV_POOL:-2000000}}}

if [ "${BACKEND}" = "spdk" ]; then
    STORAGE_TARGET="${AIC_SPDK_KV_TRID}"
else
    STORAGE_TARGET="${AIC_XNVME_DEV}"
fi

# ── Shared preflight ─────────────────────────────────────────────────────────
[ -e /dev/kfd ] || { echo "ERR: /dev/kfd absent — run: modprobe amdgpu"; exit 1; }
[ -d "${ROCM_AIC_DIR}/docker" ] || {
    echo "ERR: ${ROCM_AIC_DIR}/docker not found — run: SKIP_BUILD=1 bash build.sh"; exit 1; }
[ -n "${HF_TOKEN:-}" ] || {
    echo "ERR: HF_TOKEN not set (HuggingFace access token required)."
    echo "     If the model is public and already cached on this host, pass"
    echo "     HF_TOKEN=none to state that explicitly."
    exit 1; }
if [ "${HF_TOKEN}" = "none" ]; then
    echo "NOTE: HF_TOKEN=none — no HuggingFace auth. Requires ${MODEL} to be"
    echo "      public or already present in ${HF_HOME}; a gated or uncached"
    echo "      model will fail during weight load, not here."
fi
docker image inspect "${IMAGE_REF}" >/dev/null 2>&1 || {
    echo "ERR: ${IMAGE_REF} not found — run: ROCM_ARCH=<arch> bash build.sh"
    echo "     (builds rocm-aic with our ${NIXL_BACKEND} plugin compiled in)"
    exit 1; }

if [ "${BACKEND}" = "xnvme" ]; then
    [ -e "${AIC_XNVME_DEV}" ] || {
        echo "ERR: ${AIC_XNVME_DEV} absent — bind the device to the kernel nvme"
        echo "     driver first (NOT vfio-pci; that bind is for the raw-PCIe"
        echo "     nixlbench path). A reboot resets driver bindings."
        exit 1; }
    # Check for anything already holding the device before touching it — assuming
    # a device is idle because it "should" be has bitten this project before.
    if docker ps -a --format '{{.Names}}' | grep -qi 'lmcache-xnvme\|vllm-nixl-xnvme'; then
        echo "WARN: a container name suggesting device use already exists — check"
        echo "      'docker ps -a' and this host's lsof/vfio state before proceeding."
    fi
fi

echo "deploy: rocm-aic ${MODE} / ${NIXL_BACKEND}"
echo "  model     : ${MODEL}"
echo "  port      : ${PORT}"
echo "  target    : ${STORAGE_TARGET}"
echo "  category  : ${CATEGORY}"
[ -n "${PD_ROLE}" ] && echo "  pd role   : ${PD_ROLE}"
echo ""

# ── Hugepages (SPDK's DPDK path only; xNVMe's io_uring_cmd needs none) ───────
if [ "${BACKEND}" = "spdk" ]; then
    echo "=== hugepages ==="
    NR_HUGE=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)
    if [ "${NR_HUGE}" -lt 512 ]; then
        echo "  allocating 512 x 2MB hugepages..."
        echo 512 > /proc/sys/vm/nr_hugepages
    fi
    echo "  hugepages: $(cat /proc/sys/vm/nr_hugepages)"
    echo ""
fi

# Wait for /health, failing fast if the container died. Liveness via `docker
# inspect`, NOT `docker ps | grep -q`: grep -q exits at the first match, so
# docker ps dies of SIGPIPE and pipefail reports the pipeline as failed, aborting
# a healthy deploy with a false "container exited" (observed 2026-08-26, ~20 s
# before the server became ready). The old form also substring-matched, so an
# unrelated container whose name merely contained this one satisfied the check.
wait_for_health() {
    local container=$1 tries=$2 gap=$3 i
    for i in $(seq 1 "${tries}"); do
        sleep "${gap}"
        if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
            echo "  READY after $((i * gap))s"; return 0
        fi
        [ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null)" = "true" ] || {
            echo "ERR: container exited"; docker logs "${container}" 2>&1 | tail -80; return 1; }
    done
    echo "ERR: health timeout after $((tries * gap))s"
    if [ "${BACKEND}" = "xnvme" ]; then
        echo "     Per the safety rule: if the device-touching container is still alive"
        echo "     and mid-transfer, do NOT kill it — let it finish or fail on its own."
    fi
    docker logs "${container}" 2>&1 | tail -80
    return 1
}

write_compose_overrides() {
    mkdir -p "$(dirname "${STORAGE_COMPOSE}")"
    cat > "${STORAGE_COMPOSE}" <<'KV_COMPOSE_EOF'
# docker-compose.storage.yml — compose override adding our NIXL storage-plugin
# backends (SPDK_NVMe_KV, XNVME_KV) to AMD's rocm-aic stack.
#
# STATUS: staged, never composed or run (as of this session, 2026-08-19). Written from
# reading the pinned ROCm/rocm-aic checkout (commit bb386562, 2026-08-14) and this
# repo's own plugin/LMCache sources — no `docker compose` invocation of this file has
# happened yet, because the image it depends on (rocm-aic + our two plugins compiled
# in, per ../nixl/core/nvme-kv-plugin/ and ../nixl/core/xnvme-kv-plugin/, via the
# sibling Dockerfile-build patch) does not exist yet either. Treat the first
# `docker compose ... up` against this file as bring-up, not a benchmark — see
# deploy-spdk.sh / deploy-xnvme.sh for the full caveat and stack/tracks/mori/README.md
# for the tone this note is borrowed from.
#
# ── HOW TO COMPOSE THIS FILE ─────────────────────────────────────────────────────
# This file lives in THIS repo (the repository root), not inside the vendored
# rocm-aic checkout (build.sh clones that to vendor/rocm-aic/,
# not committed here — see build.sh's header). rocm-aic's own docker-compose.yml
# resolves relative build contexts and volume paths (`context: ..`, `../logs/...`,
# `../monitoring/...`) relative to ITS OWN docker/ directory, so both files must be
# composed with docker/ as the working directory, base file first:
#
#   cd vendor/rocm-aic/docker
#   docker compose \
#     -f docker-compose.yml \
#     -f <repo-root>/docker-compose.storage.yml \
#     --profile storage-spdk up -d      # SPDK_NVMe_KV variant (rocm-aic-spdk)
#   # or --profile storage-xnvme        # XNVME_KV variant (rocm-aic-xnvme)
#
# deploy-spdk.sh / deploy-xnvme.sh do this cd + -f/--profile dance for you; this
# header is for anyone composing by hand or debugging why a relative path didn't
# resolve.
#
# ── WHY TWO NEW SERVICES, NOT TWO PROFILES OF THE EXISTING `lmcache` SERVICE ──────
# The base `lmcache` service picks its L1/L2 topology at container-start time via a
# shell `case` inside its single `command:` (keyed off AIC_L2_BACKEND / GDS_MODE). A
# compose service has exactly one `command:` — profiles choose which SERVICES start,
# they cannot choose between two command bodies of the same service. So rather than
# extend `lmcache`, this file defines two full sibling services, `lmcache-spdk` and
# `lmcache-xnvme`, each behind its own profile, each running its own fixed
# `--l2-adapter` invocation instead of the base entrypoint's case logic. Both reuse
# the same shared image (`${IMAGE_REF}` — this is one monolithic image containing
# vLLM + LMCache + NIXL + our plugins, not a per-service image, so no separate
# `build:` block is needed here as long as `make build` in the vendored checkout has
# already produced that tag) and copy the base `lmcache` service's caps/ulimits/
# security_opt, which already cover everything SPDK's/xNVMe's userspace NVMe
# initiators need (see the per-service comments below for exactly what's reused vs.
# added).
#
# `vllm` only has one IPC/PID namespace to join at a time. Point it at whichever of
# the two new services is active via VLLM_IPC_MODE=service:lmcache-spdk (or
# -xnvme) and VLLM_PID_MODE=service:lmcache-spdk (or -xnvme) — the deploy scripts set
# both. The `depends_on` entries added to `vllm` below MERGE additively with the base
# file's `vllm.depends_on.lmcache` (which has `required: false`) rather than replacing
# it — harmless, since the `cache` profile the base `lmcache` service lives behind is
# never activated by `storage-spdk`/`storage-xnvme`.
#
# Also adds a `ports:` mapping to `vllm` — the base compose file's `vllm` service has
# NONE (it's reachable only from other containers on the internal `aic` bridge
# network, e.g. the `client` container, by design). This repo's bench/tracks.registry
# contract (see bench/tracks.registry's header) requires a deploy script to serve at
# http://127.0.0.1:${PORT}/v1 on the HOST, so a `ports:` entry publishing the
# container's 8000 to the host is required for this track to be benchmarkable the
# same way every other track in this repo is.
#
# ── --l2-adapter FLAG SHAPE: confirmed from two real sources, not guessed whole ──
# The base docker-compose.yml already invokes --l2-adapter for two existing NIXL
# storage backends — read from ROCm/rocm-aic @ bb386562, docker/docker-compose.yml:
#
#   AIS_MT (file-based nixl_store, hipFile P2PDMA to local NVMe), line ~279:
#     --l2-adapter "{\"type\":\"nixl_store\",\"backend\":\"AIS_MT\",
#       \"backend_params\":{\"file_path\":\"/data/nvme/lmcache\",
#       \"use_direct_io\":\"$$AIC_NIXL_USE_DIRECT_IO\",
#       \"file_size\":\"$$LMCACHE_NVME_SLOT_SIZE\"},\"pool_size\":$$LMCACHE_NVME_POOL}"
#
#   POSIX (file-based nixl_store, buffered I/O, NFS-over-RDMA), line ~280:
#     --l2-adapter "{\"type\":\"nixl_store\",\"backend\":\"POSIX\",
#       \"backend_params\":{\"file_path\":\"/data/nfs/lmcache\",
#       \"use_direct_io\":\"false\"},\"pool_size\":$$LMCACHE_NFS_POOL}"
#
# Both are FILE-addressed (file_path/file_size/use_direct_io) because AIS_MT/POSIX
# are byte-range-into-a-file nixl_store adapters — that's the SHAPE (the JSON
# envelope: type/backend/backend_params/pool_size), not the content, we're following.
#
# SPDK_NVMe_KV and XNVME_KV are KV-*key*-addressed instead, and rocm-aic's own
# sibling patch (patches/lmcache/
# 15-add-spdk-xnvme-kv-l2-adapter-backends.patch, already written by a parallel task)
# confirms exactly how rocm-aic's LMCache fork treats them: it adds both names to
# `_VALID_NIXL_BACKENDS` and routes them (alongside OBJ/AZURE_BLOB) through
# `NixlObjPool` + `init_storage_handlers_object(...)` in
# `lmcache/v1/distributed/l2_adapters/nixl_store_l2_adapter.py`'s `NixlStorageAgent`
# class — i.e. the OBJECT-based branch, not the file-based one, so no file_path/
# file_size/use_direct_io keys are read or required for these two. Fetching that
# class's real source (LMCache v0.5.3, the exact pin this repo's Makefile uses)
# confirms `backend_params` for OBJ-mode backends is NOT inspected key-by-key by
# LMCache at all — `NixlStorageAgent.__init__` passes it straight through:
#   self.nixl_agent.create_backend(backend, backend_params)
# i.e. verbatim to NIXL core's own backend constructor, the exact same call vanilla
# LMCache's classic NixlStaticStorageBackend path (stack/tracks/lmcache/ in this
# repo) already makes with these same two backends. That means the backend_params
# key names CONFIRMED there carry over unchanged:
#   SPDK_NVMe_KV -> {"trid": "<NVMe-oF transport-ID string>"}   (see
#     stack/tracks/lmcache/lmcache-config-spdk.yaml and
#     stack/tracks/lmcache/patches/README.md's note on patch 0003 — a single key,
#     confirmed against spdk_nvme_kv_plugin.cpp's getParams(), NOT "dev_uri")
#   XNVME_KV     -> {"dev_uri": "/dev/ng0n1"}                    (see
#     stack/tracks/lmcache/lmcache-config.yaml)
#
# UNVERIFIED: the confirmation above covers the Python/LMCache side (backend_params
# passthrough) and the plugin side (getParams() key names), both against a REAL
# source read — not a guess. What remains genuinely unconfirmed is (a) NixlObjPool's
# page_size/pool_size behavior for a KV-object backend under real load (only
# exercised so far, in this repo, via the classic YAML-config path — never through
# rocm-aic's newer NixlStorageAgent/--l2-adapter path at all), and (b) whether the
# SPDK/xnvme .so's the sibling Dockerfile-build patch compiles in actually get found
# by NIXL_PLUGIN_DIR inside THIS image the same way the existing AIS_MT/POSIX ones
# do. Both can only be settled by actually running `docker compose ... build` +
# `up` once the image exists — which is exactly why this whole track is staged, not
# validated.

services:

  # ---------------------------------------------------------------------------
  # lmcache-spdk: SPDK_NVMe_KV backend against the RAM-backed bdev_kvmalloc SPDK
  # TCP target on host <SETUP3_TARGET_NODE> (CIRRASCALE cluster, <SETUP3_TARGET_NODE_IP>:4420 — see this
  # repo's memory handoff_2026_08_18_3node_storage_target for how that target was
  # built and validated as a real cross-host NVMe-oF endpoint). Category (2) per
  # the repo's category taxonomy: a workaround for hardware unavailability (no real device
  # NVMe-KV PCIe function anywhere on the CIRRASCALE cluster) — a number off this
  # service is never a result about the device.
  #
  # Caps/ulimits/security_opt copied verbatim from the base `lmcache` service
  # (docker/docker-compose.yml) — CAP_SYS_ADMIN + IPC_LOCK + unlimited memlock +
  # seccomp:unconfined already cover everything SPDK's DPDK-based NVMe-oF/TCP
  # initiator needs (same set stack/tracks/mooncake/vllm/03-deploy.sh and
  # stack/tracks/lmcache/deploy-spdk.sh grant their own SPDK-touching containers).
  # The one thing the base service's mounts do NOT already provide is hugepages
  # (its volumes are NVME_DATA/NFS_DATA/GDS_SLAB_DATA/config-file, none of which is
  # /dev/hugepages) — added below.
  # ---------------------------------------------------------------------------
  lmcache-spdk:
    profiles: [storage-spdk]
    image: ${IMAGE_REF:-${IMAGE_NAME:-rocm-aic}:latest}
    container_name: aic-lmcache-spdk
    networks: [aic]
    ipc: shareable
    shm_size: "${AIC_SHM_SIZE:-64gb}"
    cap_add:
      - CAP_SYS_ADMIN
      - SYS_PTRACE
      - IPC_LOCK
    security_opt:
      - seccomp:unconfined
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
      memlock:
        soft: -1
        hard: -1
    devices:
      - /dev/kfd
      - /dev/dri
    volumes:
      # SPDK's DPDK EAL needs hugepages -- the one mount none of the base
      # `lmcache` service's volumes provide.
      - /dev/hugepages:/dev/hugepages
      - ${LOG:-../logs}/lmcache-spdk:/var/log/aic-lmcache
    environment:
      - LMCACHE_PORT=${LMCACHE_SPDK_PORT:-6556}
      - LMCACHE_L1_SIZE_GB=${LMCACHE_L1_SIZE_GB:-20}
      - LMCACHE_MAX_GPU_WORKERS=${LMCACHE_MAX_GPU_WORKERS:-1}
      - ROCR_VISIBLE_DEVICES=${GPU:-0}
      - PYTHONHASHSEED=0
      - TZ=${TZ:-America/Edmonton}
      - HIPFILE_ALLOW_COMPAT_MODE=false
      - HIPFILE_UNSUPPORTED_FILE_SYSTEMS=false
      - NIXL_TELEMETRY_ENABLE=${NIXL_TELEMETRY_ENABLE-y}
      - NIXL_TELEMETRY_EXPORTER=${NIXL_TELEMETRY_EXPORTER:-prometheus}
      - NIXL_TELEMETRY_PROMETHEUS_PORT=${NIXL_SPDK_METRICS_PORT:-19091}
      # SPDK_NVMe_KV's one backend_params key -- a full NVMe-oF transport-ID
      # string, NOT "dev_uri" (see the file header's --l2-adapter note). Default
      # points at the <SETUP3_TARGET_NODE> storage target this variant is built for.
      - AIC_SPDK_KV_TRID=${AIC_SPDK_KV_TRID:-trtype:TCP adrfam:IPv4 traddr:<SETUP3_TARGET_NODE_IP> trsvcid:4420 subnqn:nqn.2024-01.io.nixl:kv0}
      # pool_size here means "number of raw L1 pages" (NixlObjPool registers
      # ONE storage object per l1_align_bytes-sized page for OBJ-family
      # backends -- no file_size/pages_per_file grouping like the file-based
      # backends above get), NOT "number of KV chunks". Confirmed empirically
      # 2026-08-18 (see README's "Known gap" section): TinyLlama's fp8 KV
      # layout gives l1_align_bytes=4096, so a 256-token chunk needs ~700
      # pages -- the old default of 64 exhausted on the very first multi-page
      # store, and NixlStorageAgent's own "nothing to store" fast-path
      # reported that as a *successful* zero-byte store with no warning.
      # 2000000 is NOT derived from LMCACHE_L1_SIZE_GB's default (that would
      # be 5242880 = 20 GiB / 4096 B) -- registering that many NIXL OBJ
      # descriptors in init_storage_handlers_object() was empirically
      # confirmed (2026-08-18) to blow up non-linearly (2,000,000 came up
      # healthy in ~90s; 5,242,880 was still spinning at 100%+ CPU with zero
      # forward progress after 10+ minutes). 2,000,000 is the largest value
      # actually verified to come up quickly AND land real STORE traffic on
      # <SETUP3_TARGET_NODE>'s target (confirmed via nvmf_get_stats' completed_nvme_io) --
      # treat it as a tested ceiling, not a capacity-matched value, and
      # re-verify startup time before raising it further.
      - AIC_SPDK_KV_POOL=${AIC_SPDK_KV_POOL:-2000000}
    entrypoint: ["/bin/bash", "-o", "pipefail", "-c"]
    command:
      - |
        exec lmcache server \
          --no-separate-object-groups \
          --host 0.0.0.0 \
          --http-port 8080 \
          --port "$$LMCACHE_PORT" \
          --l1-size-gb "$$LMCACHE_L1_SIZE_GB" \
          --eviction-policy LRU \
          --max-gpu-workers "$$LMCACHE_MAX_GPU_WORKERS" \
          --worker-reap-timeout-seconds "$${LMCACHE_WORKER_REAP_TIMEOUT:-3600}" \
          --l2-adapter "{\"type\":\"nixl_store\",\"backend\":\"SPDK_NVMe_KV\",\"backend_params\":{\"trid\":\"$$AIC_SPDK_KV_TRID\"},\"pool_size\":$$AIC_SPDK_KV_POOL}"
        # UNVERIFIED: confirm this exact --l2-adapter invocation against a real
        # rocm-aic build with our plugin actually compiled in -- see file header.
    healthcheck:
      test:
        - CMD
        - python3
        - -c
        - "import os, socket; port=int(os.getenv('LMCACHE_PORT','6556')); s=socket.create_connection(('127.0.0.1', port), 2); s.close()"
      interval: 10s
      timeout: 5s
      retries: 18
      start_period: 30s

  # ---------------------------------------------------------------------------
  # lmcache-xnvme: XNVME_KV backend against the real NVMe-KV device
  # on host <SETUP2_PD_NODE_IP> (PCIe 0000:1c:00.0, IOMMU group 3, kernel nvme-bound
  # device node). Category (1): the actual end-goal hardware.
  #
  # SAFETY (see
  # kv-cache-bench-ops skill): once a container using this service is exercising
  # the device, NEVER kill it (SIGKILL, `docker kill`, or even a graceful
  # `docker stop`), and never wrap it in `timeout`. Any of those reliably wedges
  # the device's controller-enable handshake -- every subsequent probe from any process,
  # any host driver, Docker or native, hangs at ~100% CPU forever with no further
  # log output, and the ONLY recovery is restarting the DPU-side pds_dp_app from
  # the device's own management console (nothing on this host side clears it -- no
  # rescan, no FLR, no setup.sh re-run). If a run needs to stop, let it finish or
  # fail on its own.
  #
  # Caps/security_opt copied from the base `lmcache` service, same as
  # lmcache-spdk above. No hugepages/memlock/IPC_LOCK-driven DPDK path here --
  # xNVMe's io_uring_cmd path talks to the kernel-bound device node directly
  # (matching stack/tracks/lmcache/deploy.sh's XNVME_KV-via-LMCache precedent,
  # which needs only --cap-add SYS_ADMIN --cap-add IPC_LOCK plus the device
  # node itself -- NOT stack/tracks/nixl/vllm/11-deploy-qwen-nixl-xnvme.sh's,
  # which never actually exercises the device: that script's own header says the
  # XNVME_KV plugin there is loaded/dlopen'd but unused, real transfer stays on
  # UCX, so it mounts no device node at all).
  # ---------------------------------------------------------------------------
  lmcache-xnvme:
    profiles: [storage-xnvme]
    image: ${IMAGE_REF:-${IMAGE_NAME:-rocm-aic}:latest}
    container_name: aic-lmcache-xnvme
    networks: [aic]
    ipc: shareable
    shm_size: "${AIC_SHM_SIZE:-64gb}"
    cap_add:
      - CAP_SYS_ADMIN
      - SYS_PTRACE
      - IPC_LOCK
    security_opt:
      - seccomp:unconfined
    devices:
      - /dev/kfd
      - /dev/dri
      # Real device node, bound to the kernel nvme driver (NOT vfio-pci --
      # that bind is only for the raw-PCIe/nixlbench path in
      # stack/tracks/nixl/core/04-nvme.sh). Default matches this repo's other
      # XNVME_KV-via-LMCache deploy (stack/tracks/lmcache/deploy.sh's
      # NIXL_XNVME_DEV=/dev/ng0n1 default).
      - ${AIC_XNVME_DEV:-/dev/ng0n1}
    volumes:
      - ${LOG:-../logs}/lmcache-xnvme:/var/log/aic-lmcache
    environment:
      - LMCACHE_PORT=${LMCACHE_XNVME_PORT:-6557}
      - LMCACHE_L1_SIZE_GB=${LMCACHE_L1_SIZE_GB:-20}
      - LMCACHE_MAX_GPU_WORKERS=${LMCACHE_MAX_GPU_WORKERS:-1}
      - ROCR_VISIBLE_DEVICES=${GPU:-0}
      - PYTHONHASHSEED=0
      - TZ=${TZ:-America/Edmonton}
      - HIPFILE_ALLOW_COMPAT_MODE=false
      - HIPFILE_UNSUPPORTED_FILE_SYSTEMS=false
      - NIXL_TELEMETRY_ENABLE=${NIXL_TELEMETRY_ENABLE-y}
      - NIXL_TELEMETRY_EXPORTER=${NIXL_TELEMETRY_EXPORTER:-prometheus}
      - NIXL_TELEMETRY_PROMETHEUS_PORT=${NIXL_XNVME_METRICS_PORT:-19092}
      # XNVME_KV's one backend_params key -- see
      # stack/tracks/lmcache/lmcache-config.yaml (nixl_backend_params.dev_uri).
      - AIC_XNVME_DEV=${AIC_XNVME_DEV:-/dev/ng0n1}
      # See lmcache-spdk's AIC_SPDK_KV_POOL comment above -- same
      # pages-not-chunks sizing rule, and the same empirically-confirmed
      # non-linear registration cost above ~2,000,000 objects, applies to
      # this OBJ-family backend too. This static fallback only matters for a
      # direct `docker compose up` bypassing deploy-xnvme.sh.
      - AIC_XNVME_KV_POOL=${AIC_XNVME_KV_POOL:-2000000}
      # No per-transfer debug print exists for this plugin at the LMCache
      # --l2-adapter layer the way stack/tracks/lmcache/deploy.sh's
      # NIXL_XNVME_KV_DEBUG=1 works for its own (different) code path --
      # kept here as a pass-through in case the plugin itself still honors it.
      - NIXL_XNVME_KV_DEBUG=${NIXL_XNVME_KV_DEBUG:-}
    entrypoint: ["/bin/bash", "-o", "pipefail", "-c"]
    command:
      - |
        exec lmcache server \
          --no-separate-object-groups \
          --host 0.0.0.0 \
          --http-port 8080 \
          --port "$$LMCACHE_PORT" \
          --l1-size-gb "$$LMCACHE_L1_SIZE_GB" \
          --eviction-policy LRU \
          --max-gpu-workers "$$LMCACHE_MAX_GPU_WORKERS" \
          --worker-reap-timeout-seconds "$${LMCACHE_WORKER_REAP_TIMEOUT:-3600}" \
          --l2-adapter "{\"type\":\"nixl_store\",\"backend\":\"XNVME_KV\",\"backend_params\":{\"dev_uri\":\"$$AIC_XNVME_DEV\"},\"pool_size\":$$AIC_XNVME_KV_POOL}"
        # UNVERIFIED: confirm this exact --l2-adapter invocation against a real
        # rocm-aic build with our plugin actually compiled in -- see file header.
    healthcheck:
      test:
        - CMD
        - python3
        - -c
        - "import os, socket; port=int(os.getenv('LMCACHE_PORT','6557')); s=socket.create_connection(('127.0.0.1', port), 2); s.close()"
      interval: 10s
      timeout: 5s
      retries: 18
      start_period: 30s

  # ---------------------------------------------------------------------------
  # vllm: additive overrides only -- the base service's command/environment
  # already read every knob (VLLM_MODEL, TENSOR_PARALLEL_SIZE, KV_TRANSFER_ARG,
  # etc.) from the environment, so nothing there needs overriding. Two things
  # this repo's deploy contract needs that the base file doesn't provide:
  #
  #   1. `ports:` -- the base `vllm` service has none (by design: it's reachable
  #      only from other containers on the internal `aic` bridge network, e.g.
  #      the `client` service). bench/tracks.registry's contract requires a
  #      deploy script to serve at http://127.0.0.1:${PORT}/v1 on the HOST, so
  #      this is required for the track to be benchmarkable like every other one
  #      in this repo.
  #   2. `depends_on` entries for the two new services -- MERGE additively with
  #      the base file's `vllm.depends_on.lmcache` (required: false), so this
  #      does not remove that entry, just adds ours alongside it.
  #
  # VLLM_IPC_MODE / VLLM_PID_MODE (service:lmcache-spdk or service:lmcache-xnvme)
  # are set by the deploy scripts, not hardcoded here, since only one of the two
  # profiles is ever active in a given `up`.
  # ---------------------------------------------------------------------------
  vllm:
    ports:
      - "${PORT:-8000}:8000"
    depends_on:
      lmcache-spdk:
        condition: service_healthy
        required: false
      lmcache-xnvme:
        condition: service_healthy
        required: false
KV_COMPOSE_EOF
    cat > "${PLUGIN_COMPOSE}" <<'KV_OVERRIDE_EOF'
# docker-compose.plugin-override.yml — run a locally-built SPDK_NVMe_KV plugin
# instead of the one baked into the rocm-aic image.
#
# WHY THIS EXISTS. The plugin `.so` inside `rocm-aic:latest` is whatever was
# current when that image was built. Rebuilding a 43.5 GB image to test a
# one-file plugin change is wasteful, and — worse — the 2026-08-25 session
# verified changes C and D from a plugin compiled into an *ephemeral* container,
# so the fix existed nowhere persistent and a later redeploy would silently have
# run the OLD plugin and produced a result that looked fine and meant nothing.
# This file makes "run a specific .so" an explicit, recorded deployment input
# rather than something done by hand and forgotten.
#
# HOW IT IS USED. Never include this file unconditionally. `deploy-spdk.sh` adds
# it to the `docker compose` invocation ONLY when AIC_SPDK_PLUGIN_SO is set, and
# validates first that the value names an existing REGULAR FILE.
#
# That validation is the whole point. Docker silently materialises a bind mount
# whose host path does not exist as an empty DIRECTORY. Mounted at the path
# below, that would shadow the image's working plugin with a directory, and the
# only downstream symptom is NIXL's generic "backend not found" — a failure mode
# that has already cost this project two debugging sessions (see
# the SPDK_SRC note in bench/lib/preflight.sh). Hence also the `:?` guard here:
# if this file is ever included with the variable unset, compose refuses loudly
# instead of mounting something meaningless.
#
# The mount is read-only: the container must never be able to modify the
# artifact whose sha256 gets recorded in the run's provenance sidecar.
#
# The target path is NIXL_PLUGIN_DIR inside the image, the same directory the
# stock AIS_MT/POSIX/UCX plugins live in. It must match the layout the plugin
# build produces (lib/x86_64-linux-gnu/plugins/), so the override lands exactly
# where the image's own copy sits rather than beside it.
services:
  lmcache-spdk:
    volumes:
      - ${AIC_SPDK_PLUGIN_SO:?AIC_SPDK_PLUGIN_SO must name the .so to mount — do not include this compose file without it}:/opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_SPDK_NVMe_KV.so:ro
KV_OVERRIDE_EOF
}

if [ "${MODE}" = "mp" ]; then
    # ── MP mode: docker compose, LMCache as its own `lmcache server` ─────
    GPU=${GPU:-0}
    TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE:-1}
    LMCACHE_L1_SIZE_GB=${LMCACHE_L1_SIZE_GB:-20}
    COMPOSE_PROJECT=${COMPOSE_PROJECT:-rocm-aic-${BACKEND}}
    DEPLOY_DEGRADED=${DEPLOY_DEGRADED-unvalidated-first-run}

    # Compose overrides are GENERATED into the vendored tree rather than tracked
    # here: they are build-context artefacts of one specific vendored checkout,
    # and this stack keeps its top level to nine entries. Regenerated on every
    # deploy, so editing the copy under vendor/ is pointless — edit the heredocs
    # in write_compose_overrides() below.
    STORAGE_COMPOSE="${ROCM_AIC_DIR}/docker/kv-storage.override.yml"
    PLUGIN_COMPOSE="${ROCM_AIC_DIR}/docker/kv-plugin.override.yml"
    write_compose_overrides
    CONTAINER_VLLM="aic-vllm-gpu${GPU}"
    CONTAINER_LMCACHE="aic-lmcache-${BACKEND}"
    COMPOSE_PROFILE="storage-${BACKEND}"
    LMCACHE_SVC="lmcache-${BACKEND}"
    if [ "${BACKEND}" = "spdk" ]; then LMCACHE_SVC_PORT=${LMCACHE_SPDK_PORT:-6556}
    else                               LMCACHE_SVC_PORT=${LMCACHE_XNVME_PORT:-6557}; fi


    # AIC_SPDK_PLUGIN_SO — optional: run a locally-built plugin instead of the
    # image's baked-in copy. Validated as a REGULAR FILE, not merely "exists":
    # docker turns a bind mount of a nonexistent host path into an empty
    # DIRECTORY, which would shadow the image's plugin and surface only as NIXL's
    # generic "backend not found". Refusing here is the difference between a clear
    # error and a debugging session.
    AIC_SPDK_PLUGIN_SO=${AIC_SPDK_PLUGIN_SO:-}
    PLUGIN_COMPOSE_ARGS=()
    if [ -n "${AIC_SPDK_PLUGIN_SO}" ]; then
        [ -e "${AIC_SPDK_PLUGIN_SO}" ] || {
            echo "ERR: AIC_SPDK_PLUGIN_SO=${AIC_SPDK_PLUGIN_SO} does not exist."
            echo "     Refusing: docker would bind-mount this as an empty DIRECTORY"
            echo "     over the image's plugin, and the only symptom would be NIXL"
            echo "     reporting 'backend not found'."
            exit 1; }
        [ -f "${AIC_SPDK_PLUGIN_SO}" ] || {
            echo "ERR: AIC_SPDK_PLUGIN_SO=${AIC_SPDK_PLUGIN_SO} is not a regular file."
            echo "     It must be the .so itself, not the directory containing it."
            exit 1; }
        # Absolute path: compose resolves relative bind sources against the compose
        # file's directory (the vendored rocm-aic/docker tree), not the caller's cwd.
        case "${AIC_SPDK_PLUGIN_SO}" in
            /*) : ;;
            *) AIC_SPDK_PLUGIN_SO=$(cd "$(dirname "${AIC_SPDK_PLUGIN_SO}")" && pwd)/$(basename "${AIC_SPDK_PLUGIN_SO}") ;;
        esac
        PLUGIN_COMPOSE_ARGS=(-f "${PLUGIN_COMPOSE}")
        echo "  plugin    : ${AIC_SPDK_PLUGIN_SO}"
        echo "              sha256 $(sha256sum "${AIC_SPDK_PLUGIN_SO}" | cut -d' ' -f1)"
        echo "              (OVERRIDE — mounted over the image's own copy, read-only)"
    fi

    echo "=== prep dirs ==="
    mkdir -p "${HF_HOME}/hub" "${HF_HOME}/datasets" "${HF_HOME}/vllm" \
        "${HF_HOME}/vllm_config" "${HF_HOME}/torch" "${HF_HOME}/torch_inductor" \
        "${ROCM_AIC_DIR}/logs/vllm" "${ROCM_AIC_DIR}/logs/${LMCACHE_SVC}"
    echo "  HF_HOME : ${HF_HOME}"

    echo ""
    echo "=== docker compose up (--profile ${COMPOSE_PROFILE}) ==="
    # KV_TRANSFER_ARG must point vLLM's LMCacheMPConnector at THIS deployment's
    # container name + port, not the Makefile's own default JSON (which hardcodes
    # aic-lmcache:6555 — the base `lmcache` service this track deliberately bypasses).
    KV_TRANSFER_ARG_VAL="--kv-transfer-config '{\"kv_connector\":\"LMCacheMPConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"lmcache.mp.host\":\"tcp://${CONTAINER_LMCACHE}\",\"lmcache.mp.port\":${LMCACHE_SVC_PORT}}}'"

    (
        cd "${ROCM_AIC_DIR}/docker"
        HF_TOKEN="${HF_TOKEN}" HF_HOME="${HF_HOME}" \
        VLLM_MODEL="${MODEL}" GPU="${GPU}" PORT="${PORT}" \
        TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE}" \
        LMCACHE_L1_SIZE_GB="${LMCACHE_L1_SIZE_GB}" \
        LMCACHE_SPDK_PORT="${LMCACHE_SVC_PORT}" \
        LMCACHE_XNVME_PORT="${LMCACHE_SVC_PORT}" \
        VLM_MAX_MODEL_LEN="${MAX_MODEL_LEN}" \
        AIC_SPDK_KV_TRID="${AIC_SPDK_KV_TRID}" \
        AIC_SPDK_KV_POOL="${AIC_KV_POOL}" \
        AIC_XNVME_DEV="${AIC_XNVME_DEV}" \
        AIC_XNVME_KV_POOL="${AIC_KV_POOL}" \
        AIC_SPDK_PLUGIN_SO="${AIC_SPDK_PLUGIN_SO}" \
        NIXL_XNVME_KV_DEBUG="${NIXL_XNVME_KV_DEBUG:-}" \
        VLLM_IPC_MODE="service:${LMCACHE_SVC}" \
        VLLM_PID_MODE="service:${LMCACHE_SVC}" \
        KV_TRANSFER_ARG="${KV_TRANSFER_ARG_VAL}" \
        LOG="${ROCM_AIC_DIR}/logs" \
        docker compose -p "${COMPOSE_PROJECT}" \
            -f docker-compose.yml \
            -f "${STORAGE_COMPOSE}" \
            "${PLUGIN_COMPOSE_ARGS[@]}" \
            --profile "${COMPOSE_PROFILE}" up -d
    )

    echo ""
    echo "=== waiting for vLLM health ==="
    wait_for_health "${CONTAINER_VLLM}" 60 5 || {
        docker logs "${CONTAINER_LMCACHE}" 2>&1 | tail -60; exit 1; }

    RECORD_CONTAINERS="${CONTAINER_VLLM} ${CONTAINER_LMCACHE}"
    STACK_DESC="vLLM -> LMCacheMPConnector -> NixlStorageAgent l2-adapter -> ${NIXL_BACKEND} -> ${STORAGE_TARGET}"
    TRACK_NAME="rocm-aic-${BACKEND}"
else
    # ── In-process mode: one docker run, LMCache inside vLLM ──────────────────
    GPU=${GPU:-0,1,2,3,4,5,6,7}
    TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE:-8}
    DTYPE=${DTYPE:-bfloat16}
    HF_OVERRIDES=${HF_OVERRIDES:-}
    AIC_SPDK_KV_SLOT_OFFSET=${AIC_SPDK_KV_SLOT_OFFSET:-0}
    AIC_NIXL_STAGING_GB=${AIC_NIXL_STAGING_GB:-8}
    # Every per-deployment path and name hangs off INSTANCE. Defaulting it to
    # PD_ROLE (or "single") keeps every existing name byte-identical, so this
    # is not a rename — it is the knob that lets a SECOND in-process deployment
    # exist on one host at all.
    INSTANCE=${INSTANCE:-${PD_ROLE:-single}}
    COMPOSE_PROJECT=${COMPOSE_PROJECT:-rocm-aic-${BACKEND}-${INSTANCE}}
    if [ -n "${PD_ROLE}" ]; then
        DEPLOY_DEGRADED=${DEPLOY_DEGRADED-unvalidated-first-run,experimental-pd-via-shared-storage}
    else
        DEPLOY_DEGRADED=${DEPLOY_DEGRADED-unvalidated-first-run}
    fi

    CONTAINER_NAME="aic-${BACKEND}-${INSTANCE}"
    CONFIG_DIR="${ROCM_AIC_DIR}/pd-configs"
    CONFIG_FILE="${CONFIG_DIR}/lmcache-${INSTANCE}-${BACKEND}.yaml"
    LOG_SUBDIR="${ROCM_AIC_DIR}/logs/${INSTANCE}"

    # Which port is container $1 serving, if it is RUNNING? Empty otherwise.
    #
    # Read from the container's own argv rather than from a deployment record:
    # the record is written at the END of a deploy, so a deploy that died
    # half-way leaves a live container with no record at all — exactly the case
    # where clobbering it would be most surprising.
    container_port() {
        [ "$(docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null || true)" = "true" ] \
            || return 0
        docker inspect "$1" --format '{{json .Config.Cmd}}' 2>/dev/null \
            | tr ',' '\n' | grep -A1 '"--port"' | tail -1 | tr -dc '0-9' || true
    }

    # A second in-process deployment on one host used to destroy the first, two
    # separate ways:
    #
    #   1. CONTAINER_NAME did not vary with anything an operator sets per
    #      deployment, and the `docker rm -f` is unconditional. COMPOSE_PROJECT
    #      does not disambiguate it — on this path that value is only ever
    #      attached as a docker LABEL.
    #   2. CONFIG_FILE is bind-mounted INTO the running container, so merely
    #      writing it re-configured a live instance underneath itself. That is
    #      how the decode node ended up with a config file claiming
    #      nixl_pool_size: 0 while the process actually running there had loaded
    #      2000000 — the file on disk stopped describing its own container, and
    #      the next restart would silently have adopted the other config.
    #
    # (1) is fixed by keying both off INSTANCE, and by refusing below to remove
    # a running container that serves a DIFFERENT port than this deploy targets.
    # (2) is fixed by moving the removal to BEFORE the config write, so the file
    # is only ever written once nothing has it mounted.
    EXISTING_PORT=$(container_port "${CONTAINER_NAME}")
    if [ -n "${EXISTING_PORT}" ] && [ "${EXISTING_PORT}" != "${PORT}" ] \
       && [ "${REPLACE:-0}" != "1" ]; then
        echo "ERR: container '${CONTAINER_NAME}' is already running and serving port" >&2
        echo "     ${EXISTING_PORT}, but this deploy targets port ${PORT}." >&2
        echo "" >&2
        echo "     Continuing would remove that container AND rewrite" >&2
        echo "     ${CONFIG_FILE}," >&2
        echo "     which is bind-mounted into it." >&2
        echo "" >&2
        echo "     To run a SECOND instance alongside it, give this one its own" >&2
        echo "     identity:      INSTANCE=<name> ... bash deploy.sh" >&2
        echo "     To replace the existing one:  REPLACE=1 ... bash deploy.sh" >&2
        exit 1
    fi

    # A different instance already holding this port is always a mistake:
    # --network host means the second vLLM would fail to bind, after a long
    # model load.
    PORT_HOLDER=""
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
        if [ "$(container_port "${c}")" = "${PORT}" ]; then PORT_HOLDER="${c}"; break; fi
    done
    if [ -n "${PORT_HOLDER}" ] && [ "${PORT_HOLDER}" != "${CONTAINER_NAME}" ]; then
        echo "ERR: port ${PORT} is already served by container '${PORT_HOLDER}'." >&2
        echo "     Choose a free PORT, or stop that container first." >&2
        exit 1
    fi

    [ -n "${PD_ROLE}" ] && echo "  slot off  : ${AIC_SPDK_KV_SLOT_OFFSET}"
    echo "  instance  : ${INSTANCE}  (container ${CONTAINER_NAME})"
    echo ""
    echo "=== remove any previous '${CONTAINER_NAME}' ==="
    # Deliberately BEFORE the config write below. See (2) above.
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

    echo ""
    echo "=== prep dirs + LMCache config ==="
    mkdir -p "${HF_HOME}/hub" "${CONFIG_DIR}" "${LOG_SUBDIR}"

    # kv_both stores AND retrieves, so it needs both location keys; each P/D half
    # needs exactly one, and vLLM's own kv_role gating (vllm_v1_adapter.py:1050,
    # 1141,1661) is what actually enforces the asymmetry.
    case "${PD_ROLE:-both}" in
        producer) KV_ROLE="kv_producer"
                  ROLE_LOCATIONS='store_location: NixlStorageBackend' ;;
        receiver) KV_ROLE="kv_consumer"
                  ROLE_LOCATIONS='retrieve_locations: ["NixlStorageBackend"]' ;;
        both)     KV_ROLE="kv_both"
                  ROLE_LOCATIONS='store_location: NixlStorageBackend
retrieve_locations: ["NixlStorageBackend"]' ;;
    esac

    # The registered location name is the generic class-based key
    # "NixlStorageBackend", NOT the specific NIXL backend type string
    # ("SPDK_NVMe_KV"). CONFIRMED 2026-08-21 from a real run's log line:
    # "Created backend: NixlStorageBackend (NixlStaticStorageBackend)"
    # (storage_manager.py:1296). Both instances came up HEALTHY with the wrong
    # value too — store_location resolution is not checked at startup, so the
    # earlier guess would have silently no-op'd on the first real STORE/RETRIEVE,
    # matching this track's established "successful zero-byte store" failure mode.
    # Grep a fresh container's log for "Created backend:" to re-confirm.
    if [ "${BACKEND}" = "spdk" ]; then
        BACKEND_PARAMS=$(printf '    trid: "%s"\n    kv_slot_offset: "%s"' \
            "${AIC_SPDK_KV_TRID}" "${AIC_SPDK_KV_SLOT_OFFSET}")
    else
        # UNTESTED COMBINATION. patches/lmcache-17 whitelists XNVME_KV alongside
        # SPDK_NVMe_KV in nixl_storage_backend.py, so this should work, but no
        # in-process XNVME_KV run has ever been made. dev_uri mirrors the sidecar
        # path's one backend_params key.
        echo "  NOTE: PD_ROLE + BACKEND=xnvme has never been run — see the header."
        BACKEND_PARAMS=$(printf '    dev_uri: "%s"' "${AIC_XNVME_DEV}")
    fi

    cat > "${CONFIG_FILE}" <<EOF
local_cpu: False
max_local_cpu_size: ${AIC_NIXL_STAGING_GB}
remote_serde: NULL
${ROLE_LOCATIONS}
nixl_buffer_device: "cpu"
extra_config:
  enable_nixl_storage: true
  nixl_backend: "${NIXL_BACKEND}"
  nixl_pool_size: ${AIC_KV_POOL}
  nixl_backend_params:
${BACKEND_PARAMS}
EOF
    echo "  config: ${CONFIG_FILE}"
    cat "${CONFIG_FILE}"

    echo ""
    echo "=== docker run ==="
    # No `docker rm -f` here — it happens BEFORE the config write above, so
    # that write can never land on a file a live container still has mounted.

    CONTEXT_ARGS=()
    [ -n "${MAX_MODEL_LEN}" ] && CONTEXT_ARGS+=(--max-model-len "${MAX_MODEL_LEN}")
    [ -n "${HF_OVERRIDES}" ] && CONTEXT_ARGS+=(--hf-overrides "${HF_OVERRIDES}")

    DEVICE_ARGS=(--device /dev/kfd --device /dev/dri)
    [ "${BACKEND}" = "xnvme" ] && DEVICE_ARGS+=(--device "${AIC_XNVME_DEV}")

    docker run -d --name "${CONTAINER_NAME}" \
        --label "compose_project=${COMPOSE_PROJECT}" \
        --network host \
        --cap-add CAP_SYS_ADMIN --cap-add SYS_PTRACE --cap-add IPC_LOCK \
        --security-opt seccomp:unconfined \
        --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 \
        --shm-size 64gb \
        "${DEVICE_ARGS[@]}" \
        -v /dev/hugepages:/dev/hugepages \
        -v "${HF_HOME}:/root/.cache/huggingface" \
        -v "${CONFIG_FILE}:/etc/lmcache/config.yaml:ro" \
        -v "${LOG_SUBDIR}:/var/log/aic" \
        -e HF_TOKEN="${HF_TOKEN}" \
        -e ROCR_VISIBLE_DEVICES="${GPU}" \
        -e LMCACHE_CONFIG_FILE=/etc/lmcache/config.yaml \
        -e PYTHONHASHSEED=123 \
        -e NIXL_KV_DEBUG_XFER="${NIXL_KV_DEBUG_XFER:-}" \
        -e VLLM_ENABLE_V1_MULTIPROCESSING=1 \
        -e VLLM_WORKER_MULTIPROC_METHOD=spawn \
        --entrypoint vllm \
        "${IMAGE_REF}" \
        serve "${MODEL}" \
        --port "${PORT}" \
        --tensor-parallel-size "${TENSOR_PARALLEL_SIZE}" \
        --dtype "${DTYPE}" \
        --enforce-eager \
        "${CONTEXT_ARGS[@]}" \
        --kv-transfer-config "{\"kv_connector\":\"LMCacheConnectorV1\",\"kv_role\":\"${KV_ROLE}\"}"

    echo ""
    echo "=== waiting for vLLM health ==="
    wait_for_health "${CONTAINER_NAME}" 120 10 || exit 1

    RECORD_CONTAINERS="${CONTAINER_NAME}"
    STACK_DESC="vLLM -> LMCacheConnectorV1 (in-process) -> NixlStorageBackend -> ${NIXL_BACKEND} -> ${STORAGE_TARGET}"
    TRACK_NAME="rocm-aic-${BACKEND}-${PD_ROLE:-inprocess}"
fi

# ── Smoke test. A P/D half is not independently promptable; everything else is.
if [ -z "${PD_ROLE}" ]; then
    echo ""
    echo "=== smoke test ==="
    RESP=$(curl -sf "http://127.0.0.1:${PORT}/v1/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${MODEL}\",
             \"prompt\":\"The rocm-aic stack routes KV-cache offload through\",
             \"max_tokens\":40,\"temperature\":0}") || true
    echo "${RESP}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['text'])" \
        2>/dev/null || echo "${RESP}"
fi

# ── Deployment record (server half of a benchmark's provenance) ──────────────
if [ "${DEPLOY_RECORD:-1}" != "0" ]; then
    echo ""
    echo "=== deployment record ==="
    DEPLOY_RECORD_CONTAINERS="${RECORD_CONTAINERS}" \
    DEPLOY_RECORD_DEGRADED="${DEPLOY_DEGRADED}" \
    deployment_record_write "${PORT}" \
        model="${MODEL}" \
        image="${IMAGE_REF}" \
        track="${TRACK_NAME}" \
        mode="${MODE}" \
        backend="${NIXL_BACKEND}" \
        storage_target="${STORAGE_TARGET}" \
        category="${CATEGORY}" \
        tensor_parallel_size="${TENSOR_PARALLEL_SIZE}" \
        gpu="${GPU}" \
        kv_pool_size="${AIC_KV_POOL}" \
        max_model_len="${MAX_MODEL_LEN:-<default>}" \
        ${PD_ROLE:+pd_role="${PD_ROLE}"} \
        ${PD_ROLE:+slot_offset="${AIC_SPDK_KV_SLOT_OFFSET}"} \
        compose_project="${COMPOSE_PROJECT}" || true
fi

echo ""
echo "=== Deployed ==="
echo "  containers : ${RECORD_CONTAINERS}"
echo "  endpoint   : http://127.0.0.1:${PORT}/v1"
echo "  stack      : ${STACK_DESC}"
echo "  category   : ${CATEGORY}"
echo ""
if [ "${BACKEND}" = "spdk" ]; then
    echo "  VERIFY     : an HTTP 200 proves nothing about the storage tier. On the target"
    echo "               host, take 'python3 \${SPDK_SRC}/scripts/rpc.py nvmf_get_stats |"
    echo "               grep completed_nvme_io' before and after a request — it MUST"
    echo "               increase. Use nvmf_get_stats, NOT bdev_get_iostat: the latter"
    echo "               never moves for SPDK's KV command set."
else
    echo "  VERIFY     : nvmf_get_stats does NOT apply here — there is no NVMe-oF target"
    echo "               in this path. Use NIXL telemetry instead:"
    echo "                 docker exec ${RECORD_CONTAINERS%% *} curl -s localhost:19092/metrics"
    echo "  SAFETY     : never kill/stop/timeout-wrap a container mid-transfer against"
    echo "               the device — see this script's header."
fi
echo "  ALSO       : check whether RETRIEVE actually fires rather than re-prefilling —"
echo "               grep the container log for 'need to load: [1-9]' or 'Retrieved'."
