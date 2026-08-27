#!/usr/bin/env bash
# bench/lib/profiles.sh — resolver for bench/profiles/<family>/<name>.env
#
# A *profile* is a named benchmark intent ("smoke", "throughput", "vram"),
# not a named invocation. It supplies **defaults**; anything already set in
# the environment always wins, so every documented invocation
#   SEG_TYPE=VRAM OP=WRITE bash stack/tracks/nixl/core/03-storage-floor.sh
# keeps working unchanged, with or without a profile.
#
# Source this from any benchmark that wants profile support:
#   source "${REPO_ROOT}/bench/lib/profiles.sh"
#   profile_load storage "${PROFILE:-}"     # no-op when PROFILE is empty
#
# Same shape as lib/tracks.sh: a flat declarative file parsed by a small
# resolver, no dependencies beyond coreutils, because these run on bare
# remote hosts with no build toolchain.
#
# Two *families* exist because the two benchmark kinds have genuinely
# different parameter vocabularies:
#   storage — nixlbench-style block/batch sweeps (03/04/10, nixlbench flags)
#   serving — vLLM client-side sweeps (llama-benchy, 05-llm.sh, 02-bench.sh)
# A profile lives in exactly one family and may only set keys in that
# family's vocabulary (see PROFILE_KEYS_* below).

: "${PROFILES_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/profiles}"

# ── Family vocabularies ──────────────────────────────────────────────────────
# Every knob a profile of that family is allowed to set, and (equally
# important) every knob the provenance stamp reports as resolved — so a
# degraded value that came from a script default rather than a profile still
# shows up in the record.
PROFILE_KEYS_storage="ITERS WARMUP_ITERS NUM_THREADS PIPELINE_DEPTH \
NIXL_KV_NUM_QPAIRS NIXL_XNVME_NUM_QUEUES MAX_BATCH_SIZE MAX_BLOCK_SIZE \
INITIATOR_SEG SEG_TYPE OP MODE USE_HUGEPAGES CHECK_CONSISTENCY \
STORAGE_ENABLE_DIRECT PROGRESS_THREADS"

PROFILE_KEYS_serving="MODEL DEPTH PP TG CONCURRENCY MAX_CONCURRENCY NUM_PROMPTS \
MAX_TOKENS EXACT_TG PREFIX_CACHING LATENCY_MODE VIZ PD SAVE_FORMAT"

# Metadata a profile file declares about itself. These are NEVER taken from
# the environment — a verdict that could be set by `PROFILE_VERDICT=VALIDATED
# bash ...` would be worthless.
PROFILE_META_KEYS="PROFILE_VERDICT PROFILE_SUMMARY PROFILE_CAVEAT"

# profile_keys <family> — space-separated vocabulary for a family
profile_keys() {
    case "$1" in
        storage) echo "${PROFILE_KEYS_storage}" ;;
        serving) echo "${PROFILE_KEYS_serving}" ;;
        *) echo "ERR: unknown profile family '$1' (known: storage serving)" >&2; return 1 ;;
    esac
}

# profile_list <family> — print every profile in a family with its verdict
profile_list() {
    local family=$1 f name verdict summary
    [ -d "${PROFILES_DIR}/${family}" ] || {
        echo "ERR: no profile family '${family}' under ${PROFILES_DIR}" >&2; return 1; }
    for f in "${PROFILES_DIR}/${family}"/*.env; do
        [ -f "${f}" ] || continue
        name=$(basename "${f}" .env)
        verdict=$(grep -E '^[[:space:]]*PROFILE_VERDICT[[:space:]]*=' "${f}" \
                  | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
        summary=$(grep -E '^[[:space:]]*PROFILE_SUMMARY[[:space:]]*=' "${f}" \
                  | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
        printf "%-14s %-10s %s\n" "${name}" "${verdict:-?}" "${summary}"
    done
}

# profile_list_all — every family, every profile
profile_list_all() {
    local family
    for family in storage serving; do
        echo "${family}:"
        profile_list "${family}" | sed 's/^/  /'
    done
}

# _profile_trim <string>
_profile_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "${s}"
}

# profile_load <family> <name>
#
# Sets, for every KEY=VALUE in the profile, the variable KEY — but only if it
# is not already set in the environment (explicit env always wins). Exports
# PROFILE_NAME / PROFILE_FAMILY / PROFILE_VERDICT / PROFILE_SUMMARY /
# PROFILE_CAVEAT / PROFILE_APPLIED / PROFILE_OVERRIDDEN for the provenance
# stamp. An empty/absent name is a valid no-op that yields the UNTUNED
# verdict — that is what a legacy, profile-less invocation gets.
profile_load() {
    local family=$1 name=${2:-}
    local vocab; vocab=$(profile_keys "${family}") || return 1

    PROFILE_FAMILY=${family}
    PROFILE_APPLIED=""
    PROFILE_OVERRIDDEN=""
    PROFILE_CAVEAT=""

    if [ -z "${name}" ] || [ "${name}" = "none" ]; then
        PROFILE_NAME="none"
        PROFILE_VERDICT="UNTUNED"
        PROFILE_SUMMARY="no profile selected — script/environment defaults only"
        export PROFILE_NAME PROFILE_FAMILY PROFILE_VERDICT PROFILE_SUMMARY \
               PROFILE_CAVEAT PROFILE_APPLIED PROFILE_OVERRIDDEN
        return 0
    fi

    local file="${PROFILES_DIR}/${family}/${name}.env"
    if [ ! -f "${file}" ]; then
        echo "ERR: unknown ${family} profile '${name}'. Known ${family} profiles:" >&2
        profile_list "${family}" 2>/dev/null | sed 's/^/       /' >&2
        return 1
    fi

    PROFILE_NAME=${name}
    PROFILE_VERDICT=""
    PROFILE_SUMMARY=""

    local line key val
    while IFS= read -r line || [ -n "${line}" ]; do
        line=${line%$'\r'}
        line=$(_profile_trim "${line}")
        case "${line}" in ''|'#'*) continue ;; esac
        case "${line}" in *=*) : ;; *)
            echo "WARN: ${file}: ignoring malformed line: ${line}" >&2; continue ;;
        esac
        key=$(_profile_trim "${line%%=*}")
        val=$(_profile_trim "${line#*=}")
        # Inline comments are only stripped from unquoted values, so a value
        # that legitimately contains '#' must be quoted.
        case "${val}" in
            \"*\") val=${val#\"}; val=${val%\"} ;;
            \'*\') val=${val#\'}; val=${val%\'} ;;
            *' #'*) val=$(_profile_trim "${val%% #*}") ;;
        esac
        case "${key}" in
            [A-Za-z_]*) : ;;
            *) echo "WARN: ${file}: ignoring invalid key '${key}'" >&2; continue ;;
        esac

        # Metadata: always from the file, never overridable from the env.
        case " ${PROFILE_META_KEYS} " in
            *" ${key} "*) printf -v "${key}" '%s' "${val}"; continue ;;
        esac

        case " ${vocab} " in
            *" ${key} "*) : ;;
            *) echo "WARN: ${file}: '${key}' is not in the ${family} vocabulary" \
                    "— applying anyway, but it will not appear in the provenance stamp" >&2 ;;
        esac

        if [ -n "${!key+x}" ]; then
            PROFILE_OVERRIDDEN="${PROFILE_OVERRIDDEN}${PROFILE_OVERRIDDEN:+ }${key}=${!key}(profile:${val})"
        else
            export "${key}=${val}"
            PROFILE_APPLIED="${PROFILE_APPLIED}${PROFILE_APPLIED:+ }${key}=${val}"
        fi
    done < "${file}"

    if [ -z "${PROFILE_VERDICT}" ]; then
        echo "ERR: ${file} declares no PROFILE_VERDICT (VALIDATED|UNTUNED|SMOKE)." >&2
        echo "     Every profile must state what its runs are worth." >&2
        return 1
    fi
    case "${PROFILE_VERDICT}" in
        VALIDATED|UNTUNED|SMOKE) : ;;
        *) echo "ERR: ${file}: PROFILE_VERDICT='${PROFILE_VERDICT}' is not one of VALIDATED|UNTUNED|SMOKE" >&2
           return 1 ;;
    esac

    export PROFILE_NAME PROFILE_FAMILY PROFILE_VERDICT PROFILE_SUMMARY \
           PROFILE_CAVEAT PROFILE_APPLIED PROFILE_OVERRIDDEN
    return 0
}

# profile_resolved — print "KEY=VALUE" for every knob in the loaded family's
# vocabulary, using the value in effect right now. Unset knobs print as
# "(script default)" so a reader can tell "nobody chose this" apart from
# "somebody chose the degraded value".
profile_resolved() {
    local family=${1:-${PROFILE_FAMILY:-}} key vocab
    vocab=$(profile_keys "${family}") || return 1
    for key in ${vocab}; do
        if [ -n "${!key+x}" ]; then
            printf '%s=%s\n' "${key}" "${!key}"
        else
            printf '%s=(script default)\n' "${key}"
        fi
    done
}
