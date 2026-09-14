#!/usr/bin/env bash
# run-all.sh — run the benchmarking ladder against the proxy end to end:
# install (if needed) -> baseline -> prefix-cache -> concurrency ->
# prefix-benefit summary.
#
# Node:          anywhere with network reach to the proxy.
# Prerequisites: full P/D stack up (scripts/proxy/start-proxy.sh,
#                scripts/prefill/03-start-prefill.sh,
#                scripts/decode/03-start-decode.sh). ${VENV} must already
#                exist (scripts/common/20-build-vllm-lmcache.sh) — this
#                script installs llama-benchy INTO it if missing, but does
#                not build the venv itself.
# Next step:     none — read the final summary this script prints, then
#                docs/BENCHMARKING.md's "How to interpret a NEGATIVE
#                result" section if the numbers don't show a benefit.
#
# usage: run-all.sh [--quick]
#   --quick   shrinks every sweep to a single pp/tg/depth value and
#             --runs 2, for a fast smoke test that the harness itself
#             works end to end. --quick RESULTS ARE NOT REPORTABLE: with
#             --runs 2 the std-based significance check in compare_runs.py
#             is nearly meaningless (2 samples barely constrain a std at
#             all), and a single shape says nothing about how the cache
#             benefit or transport comparison behaves across the shapes
#             that actually matter for this deployment. Use --quick only
#             to confirm "does the harness run without erroring", never to
#             answer "does the remote KV cache help".
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QUICK=0
for arg in "$@"; do
    case "${arg}" in
        --quick) QUICK=1 ;;
        *) die "unknown argument: ${arg} (expected --quick)" ;;
    esac
done

if [ "${QUICK}" -eq 1 ]; then
    warn "--quick mode: shrinking sweeps to a single shape + --runs 2." \
         " THESE RESULTS ARE NOT REPORTABLE — smoke test only. See this" \
         " script's header comment for why."
    export BENCHY_PP="512"
    export BENCHY_TG="128"
    export BENCHY_DEPTH="0 4096"
    export BENCHY_CONCURRENCY="1 2"
    export BENCHY_RUNS="2"
    export BENCHY_WARMUP_RUNS="1"
fi

step "run-all: benchmarking ladder ($([ "${QUICK}" -eq 1 ] && echo QUICK || echo FULL))"
banner_config
log "BENCHY_PP=${BENCHY_PP}  BENCHY_TG=${BENCHY_TG}  BENCHY_DEPTH=${BENCHY_DEPTH}" \
    " BENCHY_CONCURRENCY=${BENCHY_CONCURRENCY}  BENCHY_RUNS=${BENCHY_RUNS}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 0: install llama-benchy if not already present. Idempotent — if
# already installed at the pinned version, pip's own install is a fast
# no-op; we still call the script rather than duplicating its checks here.
# ─────────────────────────────────────────────────────────────────────────────
if [ -x "${VENV}/bin/llama-benchy" ]; then
    info "llama-benchy already installed at ${VENV}/bin/llama-benchy — skipping 01-install-benchy.sh"
else
    step "run-all: 01-install-benchy.sh"
    bash "${BENCH_DIR}/01-install-benchy.sh"
fi

declare -a RESULTS=()
declare -a TIMES=()
_overall_rc=0
BASELINE_RUNDIR=""
PREFIX_CACHE_RUNDIR=""

LAST_RUNDIR=""
# _run_step <script_name> [args...] — sets LAST_RUNDIR as a side effect
# and appends to RESULTS/TIMES/_overall_rc, ALL of which are globals this
# function must mutate in the CALLING shell, not a subshell copy — this
# is deliberately called as a plain statement (`_run_step foo; x="${LAST_RUNDIR}"`)
# rather than via `x="$(_run_step foo)"` command substitution, because
# command substitution forks a subshell and every one of those mutations
# would silently vanish the instant it exited, leaving RESULTS/TIMES empty
# and _overall_rc stuck at 0 regardless of what actually failed.
#
# The script's stdout (by convention, EXACTLY the run directory path and
# nothing else — see 10-bench-baseline.sh / 20-bench-prefix-cache.sh's
# trailing comment) is captured to a temp file rather than a variable via
# command substitution, for the same subshell reason. stderr is left
# unredirected so log/info/ok/warn output streams live to the terminal.
_run_step() {
    local script="$1"; shift
    local start elapsed rc=0 tmp_out
    tmp_out="$(mktemp)"
    start="$(date +%s)"
    step "run-all: ${script} $*"
    if bash "${BENCH_DIR}/${script}" "$@" >"${tmp_out}"; then
        rc=0
    else
        rc=$?
    fi
    LAST_RUNDIR="$(cat "${tmp_out}" 2>/dev/null || true)"
    rm -f "${tmp_out}"
    elapsed=$(( $(date +%s) - start ))
    TIMES+=("${elapsed}")
    if [ "${rc}" -eq 0 ]; then
        RESULTS+=("PASS")
        ok "${script} completed (${elapsed}s) -> ${LAST_RUNDIR}"
    else
        RESULTS+=("FAIL")
        err "${script} failed (${elapsed}s, exit ${rc})"
        _overall_rc=1
    fi
    return "${rc}"
}

_run_step 10-bench-baseline.sh --target proxy || true
BASELINE_RUNDIR="${LAST_RUNDIR}"
if [ "${_overall_rc}" -ne 0 ]; then
    err "baseline failed — stopping (prefix-cache/concurrency results" \
        " would have no cold denominator to compare against)"
else
    _run_step 20-bench-prefix-cache.sh || true
    PREFIX_CACHE_RUNDIR="${LAST_RUNDIR}"
    if [ "${_overall_rc}" -eq 0 ]; then
        _run_step 30-bench-concurrency.sh || true
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Prefix-benefit summary — the headline number, printed even in a partial
# failure (as long as 20-bench-prefix-cache.sh itself succeeded), since an
# operator watching this run wants that answer as soon as it's available
# rather than only on a fully clean run.
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${PREFIX_CACHE_RUNDIR}" ] && [ -f "${PREFIX_CACHE_RUNDIR}/result.json" ]; then
    step "run-all: prefix-cache benefit summary"
    python3 "${BENCH_DIR}/compare_runs.py" --prefix-benefit --format md \
        "${PREFIX_CACHE_RUNDIR}/result.json" || warn "compare_runs.py --prefix-benefit exited non-zero"
else
    warn "no prefix-cache result.json available — skipping benefit summary"
fi

step "run-all: summary"
printf '%-32s %-8s %s\n' "SCRIPT" "RESULT" "TIME" >&2
_i=0
_scripts=("10-bench-baseline.sh" "20-bench-prefix-cache.sh" "30-bench-concurrency.sh")
for _script in "${_scripts[@]}"; do
    if [ "${_i}" -lt "${#RESULTS[@]}" ]; then
        printf '%-32s %-8s %ss\n' "${_script}" "${RESULTS[${_i}]}" "${TIMES[${_i}]}" >&2
    else
        printf '%-32s %-8s %s\n' "${_script}" "SKIPPED" "-" >&2
    fi
    _i=$((_i + 1))
done
[ -n "${BASELINE_RUNDIR}" ] && log "  baseline run:     ${BASELINE_RUNDIR}"
[ -n "${PREFIX_CACHE_RUNDIR}" ] && log "  prefix-cache run: ${PREFIX_CACHE_RUNDIR}"
[ "${QUICK}" -eq 1 ] && warn "REMINDER: this was a --quick run — results above are a smoke test only, not reportable numbers."

if [ "${_overall_rc}" -eq 0 ]; then
    ok "run-all: all benchmarks completed"
else
    err "run-all: one or more benchmarks failed — see FAIL row(s) above"
fi
exit "${_overall_rc}"
