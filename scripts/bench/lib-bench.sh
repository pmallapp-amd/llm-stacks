#!/usr/bin/env bash
# lib-bench.sh — shared helpers for scripts/bench/*.sh.
#
# Sourced, never executed directly:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
#     source "$(dirname "${BASH_SOURCE[0]}")/lib-bench.sh"
#
# (common/lib.sh MUST be sourced first — this file uses step/info/warn/die/
# log/require_cmd/wait_for_http/ensure_dirs and every BENCHY_*/MODEL/etc var
# that common/lib.sh pulls in from config/cluster.env.)
#
# WHY this exists separately from the numbered scripts: 10-/20-/30-/40- all
# need the exact same three things (preflight the endpoint, invoke
# llama-benchy with the repo's house configuration, snapshot /metrics around
# the run) and drifting three near-duplicate copies of that logic is how a
# fix to one benchmark script quietly fails to reach the other two.

# ─────────────────────────────────────────────────────────────────────────────
# benchy_preflight <base_url>
#
# Two independent checks, in order, because they catch two independent
# failure modes:
#
#   1. wait_for_http "<base>/models" — is anything answering HTTP at all.
#      Cheap, generic, catches "the process is down" / "wrong host:port".
#
#   2. an ACTUAL 1-token POST to /v1/chat/completions — llama-benchy drives
#      chat completions ONLY (see docs/BENCHMARKING.md's "chat-only
#      constraint" section). A deployment that only serves
#      /v1/completions (e.g. a base, non-instruct-tuned server, or a
#      reverse proxy that only forwards the legacy completions route)
#      would pass check 1, pass llama-benchy's own /v1/models
#      auto-detection, and then fail every single shape in a long sweep
#      with the same opaque HTTP 404 — burning the whole sweep's wall
#      clock before the operator learns anything. Two seconds here saves
#      that.
#
# Also compares the /v1/models-reported model id against SERVED_MODEL_NAME
# and WARNS (does not die) on mismatch: a warm-body mismatch is often
# operator error (pointed BENCHY_BASE_URL at the wrong stack) but is not,
# by itself, proof the benchmark run below will fail.
# ─────────────────────────────────────────────────────────────────────────────
benchy_preflight() {
    local base_url="$1"
    require_cmd curl python3

    step "Preflight: ${base_url}"

    info "waiting for ${base_url}/models to answer HTTP"
    wait_for_http "${base_url}/models" 60 \
        || die "preflight failed: ${base_url}/models never answered within 60s." \
               " Is the proxy/vLLM server actually up? (scripts/proxy/start-proxy.sh," \
               " scripts/prefill/03-start-prefill.sh, scripts/decode/03-start-decode.sh)"
    ok "${base_url}/models answered"

    local models_body
    models_body="$(curl -fsS --max-time 10 "${base_url}/models" 2>/dev/null || true)"
    local reported_model
    reported_model="$(printf '%s' "${models_body}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    ids = [m.get("id", "") for m in data.get("data", [])]
    print(ids[0] if ids else "")
except Exception:
    print("")
' 2>/dev/null || true)"
    if [ -n "${reported_model}" ] && [ "${reported_model}" != "${SERVED_MODEL_NAME}" ]; then
        warn "model mismatch: ${base_url}/models reports '${reported_model}'," \
             " but SERVED_MODEL_NAME='${SERVED_MODEL_NAME}'. Not fatal — the" \
             " server may legitimately serve a different alias — but confirm" \
             " this is the deployment you meant to benchmark before trusting" \
             " the numbers below."
    elif [ -n "${reported_model}" ]; then
        log "  model confirmed: ${reported_model}"
    else
        warn "could not parse a model id out of ${base_url}/models response" \
             " (schema drift, or an empty 'data' list) — skipping the" \
             " model-identity check. Not fatal on its own."
    fi

    info "sending a 1-token /v1/chat/completions probe (llama-benchy is chat-only)"
    local probe_payload probe_out probe_code
    probe_payload="$(python3 -c '
import json, os
print(json.dumps({
    "model": os.environ.get("SERVED_MODEL_NAME", ""),
    "messages": [{"role": "user", "content": "hi"}],
    "max_tokens": 1,
    "stream": False,
}))
')"
    probe_out="$(mktemp)"
    probe_code="$(curl -s -o "${probe_out}" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        --data-binary "${probe_payload}" \
        --max-time 30 \
        "${base_url}/chat/completions" 2>/dev/null || echo 000)"
    if [ "${probe_code}" != "200" ]; then
        local body_snippet
        body_snippet="$(head -c 500 "${probe_out}" 2>/dev/null || true)"
        rm -f "${probe_out}"
        die "preflight failed: /v1/chat/completions probe returned HTTP" \
            " ${probe_code} (expected 200). llama-benchy drives" \
            " /v1/chat/completions exclusively — if this endpoint only" \
            " serves /v1/completions, every shape in the sweep below would" \
            " fail identically. Response body (first 500 bytes):" $'\n' \
            "${body_snippet}"
    fi
    rm -f "${probe_out}"
    ok "chat-completions probe succeeded (HTTP 200)"
}

# ─────────────────────────────────────────────────────────────────────────────
# benchy_capture_counters <rundir> <pre|post>
#
# Snapshots /metrics from prefill and decode into the run directory so a
# human (or compare_runs.py, later) can compute LMCache hit-token deltas
# across the WHOLE benchmark, not just the single request-pair
# scripts/verify/40-verify-disagg.sh checks. Tolerates missing /metrics —
# a benchmark run is still useful without this, and dying here would throw
# away every result the run already produced for the sake of an optional
# diagnostic.
# ─────────────────────────────────────────────────────────────────────────────
benchy_capture_counters() {
    local rundir="$1" phase="$2"
    local prefill_base="http://${PREFILL_HOST}:${PREFILL_PORT}"
    local decode_base="http://${DECODE_HOST}:${DECODE_PORT}"

    local out
    out="${rundir}/metrics-prefill-${phase}.txt"
    if curl -fsS --max-time 10 "${prefill_base}/metrics" -o "${out}" 2>/dev/null; then
        log "  captured prefill /metrics (${phase}) -> ${out}"
    else
        warn "could not capture prefill /metrics (${phase}) — is" \
             " --enable-metrics on? Continuing without it (advisory only)."
        rm -f "${out}"
    fi

    out="${rundir}/metrics-decode-${phase}.txt"
    if curl -fsS --max-time 10 "${decode_base}/metrics" -o "${out}" 2>/dev/null; then
        log "  captured decode /metrics (${phase}) -> ${out}"
    else
        warn "could not capture decode /metrics (${phase}) — is" \
             " --enable-metrics on? Continuing without it (advisory only)."
        rm -f "${out}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# _bench_write_run_env <rundir> <base_url> <label>
#
# WHY this file matters more than it looks: a benchmark number without the
# configuration that produced it is unfalsifiable. "prefill was 3.1x faster
# warm" means nothing six months from now if nobody recorded what
# KV_TRANSPORT, KV_MAX_VALUE_SIZE_EFFECTIVE, LMCACHE_CHUNK_SIZE, TP_SIZE, or
# even which git commit of THIS repo's proxy/plugin code was running at the
# time. Every field below is chosen because changing it plausibly changes
# the number: transport flips the physical wire, max-value-size changes
# on-wire object geometry (see config/cluster.env's KV_MAX_VALUE_SIZE_EFFECTIVE
# comment — the multipart-split boundary this repo's own round-trip test
# exists to exercise), TP_SIZE changes how much HBM is left for local KV,
# and the git commit is the only thing that pins "which version of the
# proxy's sequential-priming behavior" (scripts/proxy/disagg_proxy.py) was
# in effect. KV_BACKEND selects WHICH of NVMF_TRTYPE/KV_MAX_VALUE_SIZE
# (SPDK_NVMe_KV) or XNVME_DEV/XNVME_VERSION (XNVME_KV) is actually load-
# bearing for a given run — both sets are recorded unconditionally so a
# run.env is self-describing regardless of which backend produced it.
# ─────────────────────────────────────────────────────────────────────────────
_bench_write_run_env() {
    local rundir="$1" base_url="$2" label="$3"
    local env_file="${rundir}/run.env"

    local git_commit="unknown"
    if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        git_commit="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo 'no-commits-yet')"
        if git -C "${REPO_ROOT}" diff --quiet 2>/dev/null && git -C "${REPO_ROOT}" diff --cached --quiet 2>/dev/null; then
            :
        else
            git_commit="${git_commit}-dirty"
        fi
    fi

    local vllm_version="unknown" lmcache_version="unknown"
    if [ -x "${VENV}/bin/python" ]; then
        vllm_version="$("${VENV}/bin/python" -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo unknown)"
        lmcache_version="$("${VENV}/bin/python" -c 'import lmcache; print(lmcache.__version__)' 2>/dev/null || echo unknown)"
    fi

    local benchy_version="unknown"
    if [ -x "${VENV}/bin/llama-benchy" ]; then
        benchy_version="$("${VENV}/bin/llama-benchy" --version 2>/dev/null | tail -1 || echo unknown)"
    fi

    # SPDK version: not importable like a python package — the initiator-side
    # SPDK tree only leaves a trace in its build dir. Best-effort grep of
    # SPDK_SRC's own version file; "undeterminable" is an honest answer when
    # SPDK_SRC isn't present on this host (e.g. running the harness from a
    # jump host that never built the stack itself).
    local spdk_version="undeterminable"
    if [ -f "${SPDK_SRC:-}/VERSION" ]; then
        spdk_version="$(cat "${SPDK_SRC}/VERSION" 2>/dev/null || echo undeterminable)"
    elif [ -n "${SPDK_VERSION:-}" ]; then
        spdk_version="${SPDK_VERSION} (configured; SPDK_SRC/VERSION not found on this host)"
    fi

    # libxnvme version — XNVME_KV links libxnvme.so dynamically (see
    # plugins/xnvme-kv/meson.build). This repo tracks no XNVME_SRC/
    # XNVME_VERSION var of its own, so the best-effort source is whatever
    # the loader actually resolves to; "undeterminable" is an honest answer
    # when running from a jump host that never built the stack.
    local xnvme_version="undeterminable"
    if command -v ldconfig >/dev/null 2>&1; then
        xnvme_version="$(ldconfig -p 2>/dev/null | grep -m1 'libxnvme\.so' \
            | sed 's/^\s*//' || echo undeterminable)"
        [ -n "${xnvme_version}" ] || xnvme_version="undeterminable"
    fi

    cat > "${env_file}" <<EOF
# run.env — full resolved configuration for this benchmark run.
# Generated by scripts/bench/lib-bench.sh:_bench_write_run_env — do not
# hand-edit. A benchmark number without this file is unfalsifiable: see
# docs/BENCHMARKING.md's "Reproducibility" section.

LABEL=${label}
BASE_URL=${base_url}
TIMESTAMP_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

REPO_GIT_COMMIT=${git_commit}

MODEL=${MODEL}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME}
TP_SIZE=${TP_SIZE}
MAX_MODEL_LEN=${MAX_MODEL_LEN}
BLOCK_SIZE=${BLOCK_SIZE}
KV_CACHE_DTYPE=${KV_CACHE_DTYPE}
GPU_MEM_UTIL=${GPU_MEM_UTIL}

KV_TRANSPORT=${KV_TRANSPORT}
KV_BACKEND=${KV_BACKEND}
NVMF_TRTYPE=${NVMF_TRTYPE}
KV_MAX_VALUE_SIZE=${KV_MAX_VALUE_SIZE}
KV_NUM_QPAIRS=${KV_NUM_QPAIRS}
XNVME_DEV=${XNVME_DEV}
KV_MAX_VALUE_SIZE_EFFECTIVE=${KV_MAX_VALUE_SIZE_EFFECTIVE}
LMCACHE_MP_PORT=${LMCACHE_MP_PORT}
LMCACHE_CHUNK_SIZE=${LMCACHE_CHUNK_SIZE}
LMCACHE_MAX_LOCAL_CPU_SIZE=${LMCACHE_MAX_LOCAL_CPU_SIZE}

VLLM_VERSION=${vllm_version}
LMCACHE_VERSION=${lmcache_version}
LLAMA_BENCHY_VERSION=${benchy_version}
SPDK_VERSION=${spdk_version}
XNVME_VERSION=${xnvme_version}

BENCHY_PP=${BENCHY_PP}
BENCHY_TG=${BENCHY_TG}
BENCHY_DEPTH=${BENCHY_DEPTH}
BENCHY_CONCURRENCY=${BENCHY_CONCURRENCY}
BENCHY_RUNS=${BENCHY_RUNS}
BENCHY_WARMUP_RUNS=${BENCHY_WARMUP_RUNS}
BENCHY_LATENCY_MODE=${BENCHY_LATENCY_MODE}
EOF
    ok "wrote ${env_file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# benchy_run <label> <base_url> [extra llama-benchy args...]
#
# Builds and runs the llama-benchy invocation from the repo's BENCHY_* vars,
# capturing results + progress + configuration under a fresh timestamped
# directory. Any extra args passed by the caller are appended AFTER the
# house defaults, so a caller can override (e.g. pass its own --depth) by
# relying on llama-benchy accepting the LAST occurrence of a repeated flag
# — verify that assumption against the installed --help if a caller
# actually needs to override rather than extend.
# ─────────────────────────────────────────────────────────────────────────────
benchy_run() {
    local label="$1" base_url="$2"; shift 2
    local extra_args=("$@")

    require_cmd date mkdir
    [ -x "${VENV}/bin/llama-benchy" ] \
        || die "llama-benchy not found at ${VENV}/bin/llama-benchy —" \
               " run scripts/bench/01-install-benchy.sh first"

    local timestamp rundir
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    rundir="${BENCHY_RESULT_DIR}/${timestamp}-${label}"
    mkdir -p "${rundir}"
    info "run directory: ${rundir}"

    benchy_capture_counters "${rundir}" "pre"
    _bench_write_run_env "${rundir}" "${base_url}" "${label}"

    # shellcheck disable=SC2086,SC2206
    # Intentional: BENCHY_PP/BENCHY_TG/BENCHY_DEPTH/BENCHY_CONCURRENCY are
    # documented (config/cluster.env) as space-separated LISTS that
    # llama-benchy's --pp/--tg/--depth/--concurrency flags each expect as
    # several distinct argv words (`--pp 512 1024 2048`), not one quoted
    # string. Quoting them here would hand llama-benchy's argparse a single
    # token "512 1024 2048" for --pp instead of three, which argparse
    # would either reject outright or (worse) silently coerce, quietly
    # collapsing the whole sweep down to one shape.
    local cmd=(
        "${VENV}/bin/llama-benchy"
        --base-url "${base_url}"
        --model "${MODEL}"
        --served-model-name "${SERVED_MODEL_NAME}"
        --pp ${BENCHY_PP}
        --tg ${BENCHY_TG}
        --depth ${BENCHY_DEPTH}
        --concurrency ${BENCHY_CONCURRENCY}
        --runs "${BENCHY_RUNS}"
        --latency-mode "${BENCHY_LATENCY_MODE}"
        --save-result "${rundir}/result.json"
        --format json
        --emit-progress "${rundir}/progress.jsonl"
    )
    # Warmup. llama-benchy 0.4.0 has NO --warmup-runs flag — verified
    # 2026-09-18 against the installed CLI (`--help | grep -c -- --warmup-runs`
    # returns 0). It always runs exactly ONE warmup iteration whose result is
    # discarded (`total_runs = num_runs + 1`), and the only control it offers
    # is --no-warmup to suppress that one. This file previously passed
    # --warmup-runs unconditionally, which made argparse reject EVERY sweep
    # with "unrecognized arguments" — the harness could not run at all.
    #
    # So BENCHY_WARMUP_RUNS is honoured as far as the tool allows: 0 means
    # --no-warmup, anything else means the tool's built-in single warmup.
    # A value >1 cannot be expressed; warn rather than silently delivering 1.
    if [ "${BENCHY_WARMUP_RUNS}" -eq 0 ] 2>/dev/null; then
        cmd+=(--no-warmup)
    elif [ "${BENCHY_WARMUP_RUNS}" -gt 1 ] 2>/dev/null; then
        warn "BENCHY_WARMUP_RUNS=${BENCHY_WARMUP_RUNS}, but llama-benchy" \
             " ${BENCHY_VERSION} supports only one built-in warmup iteration" \
             " (no --warmup-runs flag). Proceeding with 1."
    fi

    cmd+=("${extra_args[@]}")

    info "running: ${cmd[*]}"
    local rc=0
    "${cmd[@]}" > "${rundir}/stdout.log" 2> "${rundir}/stderr.log" || rc=$?

    # result.md: llama-benchy's --format flag controls ONLY the
    # --save-result FILE, and the tool has no json->md conversion mode of
    # its own — so the only way to get BOTH a machine-readable json and a
    # human-readable table would ordinarily be to run the entire sweep
    # TWICE, which is a non-starter (doubles wall clock, and a re-run's
    # numbers are never bit-identical to the first — see this file's
    # "significance" comments in compare_runs.py). Instead: llama-benchy
    # prints its own human-readable results table to STDOUT regardless of
    # --format (that flag only affects --save-result), so stdout.log
    # already IS the table this repo wants for result.md — just save it
    # under that name too rather than re-invoking anything.
    if [ -f "${rundir}/result.json" ]; then
        cp "${rundir}/stdout.log" "${rundir}/result.md"
    else
        warn "result.json was not produced (rc=${rc}) — skipping result.md"
    fi

    benchy_capture_counters "${rundir}" "post"

    if [ "${rc}" -ne 0 ]; then
        err "llama-benchy exited ${rc} — see ${rundir}/stderr.log"
        log "  last 30 lines of stderr:"
        tail -n 30 "${rundir}/stderr.log" >&2 || true
        return "${rc}"
    fi

    ok "benchmark '${label}' complete -> ${rundir}"
    printf '%s\n' "${rundir}"
}
