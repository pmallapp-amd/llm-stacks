#!/usr/bin/env bash
# run.sh — deploy a vLLM server if none is already up, then launch llama-benchy
# (llama-bench-style pp/tg sweep for any OpenAI-compatible endpoint) against it,
# with the live llama-benchy-viz-tui dashboard piped in by default.
#
# Cross-track: this benchmark is track-agnostic. It only needs an
# OpenAI-compatible endpoint, so it selects a stack by NAME via
# bench/tracks.registry (see that file for the full track contract) rather
# than by hardcoded path — `TRACK=mooncake bash run.sh` is the whole change
# needed to benchmark a different transfer layer.
# Installs llama-benchy and llama-benchy-viz-tui via `uv tool install` on first
# run if missing. Docker images (vllm-nixl:rocm / vllm-mooncake:rocm etc.) are
# NOT built automatically — that's a separate, ~20-25 min one-time step; if the
# image is missing, the deploy script itself fails with a clear "run NN-build
# first" message.
#
#   TRACK=<name>          which registered track to deploy (default: nixl).
#                         `bash run.sh --list-tracks` prints the options.
#   BASE_URL=<url>        vLLM OpenAI-compatible base URL (default: http://127.0.0.1:8000/v1).
#                         Readiness is probed at <root>/health, falling back to
#                         <root>/status for P/D-proxy-fronted tracks.
#   MODEL=<hf-name>       must match the model the deploy script serves
#                         (default: the TRACK's registered default model)
#   AUTO_DEPLOY=1         1 = run DEPLOY_SCRIPT automatically if BASE_URL isn't
#                         already healthy; 0 = just error out instead (default: 1)
#   DEPLOY_SCRIPT=<path>  escape hatch — run this exact script instead of
#                         resolving TRACK through the registry, for a stack
#                         that isn't registered (default: from TRACK)
#   PORT=<n>              passed through to DEPLOY_SCRIPT; derived from BASE_URL
#                         if not set, so the deployed server and the benchmarked
#                         URL always agree (default: parsed from BASE_URL, else 8000)
#   DEPTH="0 4096 ..."    context depths to sweep (default: "0 4096 8192 16384")
#   PP="512 1024"         prompt-processing token counts to sweep (default: "512 1024")
#   TG=256                generation token count (default: 256)
#   CONCURRENCY="1 4 16"  concurrency levels to sweep (default: "1 4 16")
#   LATENCY_MODE=generation   api|generation|none (default: generation)
#   EXACT_TG=0            1 = force output length via min_tokens+ignore_eos (default: 0)
#   PREFIX_CACHING=0      1 = add --enable-prefix-caching (default: 0)
#   SKIP_COHERENCE=0      1 = add --skip-coherence (default: 0 — unchanged).
#                         llama-benchy's coherence check samples the endpoint and
#                         aborts the sweep if the reply looks degenerate; ordinary
#                         sampling variance can trip it (TinyLlama did), throwing
#                         away a long run. Skip it only when correctness has been
#                         established separately — e.g. a temperature=0 agreement
#                         check across endpoints — and say so in the result.
#   VIZ=1                 1 = pipe into llama-benchy-viz-tui for a live dashboard,
#                         0 = plain CLI/table output (default: 1)
#   SAVE_FORMAT=md        md|json|csv — passed to --format (default: md)
#   RESULTS=<path>        output dir for --save-result
#                         (default: <repo>/results/$(hostname -s)/$(date +%F)-llama-benchy)
#   PROFILE=<name>        bench/profiles/serving/<name>.env — supplies defaults
#                         for the sweep knobs above (throughput, smoke,
#                         pd-handoff). Explicit env still wins; no PROFILE =
#                         unchanged behaviour, run stamped UNTUNED.
#                         `bash run.sh --list-profiles` prints the options.
#   PREFLIGHT_REQUIRE_DEPLOYMENT_RECORD=1
#                         refuse (rather than warn) when the server under test
#                         left no deployment record (default: 0).
#
# ── Client config vs server config ────────────────────────────────────────────
# This benchmark measures a server it usually did not configure. The sweep knobs
# above are the CLIENT half; the SERVER half (per-role tensor-parallel size, GPU
# assignment, dtype, gpu-memory-utilization, any RCCL workaround) belongs to the
# deploy script and can dominate the result. Deploy scripts that call
# deployment_record_write (bench/lib/deployment.sh) leave their resolved
# configuration behind; this script reads it, gates on it, and puts it in the
# provenance stamp as a clearly-attributed SERVER section. Against a server with
# no such record the run still works — the stamp then says
# "SERVER CONFIG: NOT RECORDED" instead of implying the verdict covers both.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PATH="${HOME}/.local/bin:${PATH}"

# Track resolution goes through the registry, never a hardcoded track path.
source "${SCRIPT_DIR}/../lib/tracks.sh"
# Configuration layer: profile defaults -> preflight gate -> provenance stamp.
# See bench/profiles/README.md. No-op without PROFILE, except that the run is
# always stamped with a verdict.
source "${SCRIPT_DIR}/../lib/profiles.sh"
# deployment.sh must be sourced BEFORE preflight.sh/provenance.sh are used: it
# supplies the SERVER half of the configuration (the deploy script's resolved
# TP/GPU/dtype/workaround settings), which those two consume when present.
source "${SCRIPT_DIR}/../lib/deployment.sh"
source "${SCRIPT_DIR}/../lib/preflight.sh"
source "${SCRIPT_DIR}/../lib/provenance.sh"
if [ "${1:-}" = "--list-tracks" ]; then track_list; exit 0; fi
if [ "${1:-}" = "--list-profiles" ]; then profile_list serving; exit 0; fi
profile_load serving "${PROFILE:-}" || exit 2
export PROVENANCE_SCRIPT="${BASH_SOURCE[0]}"

TRACK=${TRACK:-nixl}
BASE_URL=${BASE_URL:-http://127.0.0.1:8000/v1}
MODEL=${MODEL:-$(track_default_model "${TRACK}")}
AUTO_DEPLOY=${AUTO_DEPLOY:-1}
DEPLOY_SCRIPT=${DEPLOY_SCRIPT:-$(track_deploy_script "${TRACK}")}
DERIVED_PORT=$(echo "${BASE_URL}" | sed -E 's#^[a-zA-Z]+://[^:/]+:?([0-9]*).*#\1#')
PORT=${PORT:-${DERIVED_PORT:-8000}}
DEPTH=${DEPTH:-"0 4096 8192 16384"}
PP=${PP:-"512 1024"}
TG=${TG:-256}
CONCURRENCY=${CONCURRENCY:-"1 4 16"}
LATENCY_MODE=${LATENCY_MODE:-generation}
EXACT_TG=${EXACT_TG:-0}
PREFIX_CACHING=${PREFIX_CACHING:-0}
SKIP_COHERENCE=${SKIP_COHERENCE:-0}
VIZ=${VIZ:-1}
SAVE_FORMAT=${SAVE_FORMAT:-md}
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
RESULTS=${RESULTS:-${REPO_ROOT}/results/$(hostname -s)/$(date +%F)-llama-benchy}

mkdir -p "${RESULTS}"

# ── Preflight gate ───────────────────────────────────────────────────────────
# Runs before deployment: a sweep that is going to be unusable should not first
# spend 20 minutes bringing a model up.
export PREFLIGHT_BACKEND="${TRACK}" PREFLIGHT_TRANSPORT="${BASE_URL}"
export MODEL DEPTH PP TG CONCURRENCY EXACT_TG PREFIX_CACHING
# This benchmark measures a server it did not deploy, so a missing deployment
# record is itself a finding and the stamp must say so rather than omit the
# server section. See bench/lib/deployment.sh.
export PREFLIGHT_EXPECT_DEPLOYMENT=1 PROVENANCE_EXPECT_DEPLOYMENT=1
preflight_gate serving || exit 1
# Remember which deployment the gate saw, so the post-deploy re-check below can
# tell "the same stack, already gated" from "a stack that appeared since".
PRE_DEPLOY_SIGNATURE="${DEPLOYMENT_RECORD:-}:${DEPLOYMENT_STATUS:-}:$(
    [ -n "${DEPLOYMENT_RECORD:-}" ] && deployment_get "${DEPLOYMENT_RECORD}" recorded_epoch || true)"

# ── Ensure the tools are installed ───────────────────────────────────────────
command -v uv >/dev/null 2>&1 || {
    echo "ERR: uv not found — install it first:"
    echo "     curl -fsSL https://astral.sh/uv/install.sh | sh"
    exit 1
}

command -v llama-benchy >/dev/null 2>&1 || {
    echo "Installing llama-benchy..."
    uv tool install llama-benchy
}

if [ "${VIZ}" = "1" ]; then
    command -v llama-benchy-viz-tui >/dev/null 2>&1 || {
        echo "Installing llama-benchy-viz-tui..."
        uv tool install git+https://github.com/alexziskind1/llama-benchy-viz-tui
    }
fi

# ── Preflight: deploy a server if none is already up ─────────────────────────
# _endpoint_ready <base-url> — is something already serving at this URL?
#
# tracks.registry's contract specifies /health, and a plain vLLM server honours
# it. The pd-disagg track does not: its client-facing endpoint is vLLM's own
# disagg_proxy_demo.py, which exposes /status (reporting prefill/decode node
# counts) and 404s on both /health and /v1/models. Probing only /health
# therefore concluded that a perfectly healthy P/D proxy was down, and — with
# AUTO_DEPLOY=1 — redeployed the whole stack on top of itself.
#
# Falling back to /status rather than requiring the caller to know which probe
# their track uses: this is auto-detection of an already-running server, so
# guessing right is the whole job. Strictly widening — anything that answered
# /health before still takes the first branch and behaves identically.
_endpoint_ready() {
    local root=${1%/v1}
    curl -sf "${root}/health" >/dev/null 2>&1 && return 0
    curl -sf "${root}/status" >/dev/null 2>&1 && return 0
    return 1
}

if ! _endpoint_ready "${BASE_URL}"; then
    if [ "${AUTO_DEPLOY}" != "1" ]; then
        echo "ERR: no server responding at ${BASE_URL%/v1}/{health,status} (AUTO_DEPLOY=0)"
        echo "     Deploy one first, e.g.:"
        echo "       bash ${DEPLOY_SCRIPT}"
        echo "     Registered tracks (TRACK=<name>):"
        track_list | sed 's/^/       /'
        exit 1
    fi
    [ -f "${DEPLOY_SCRIPT}" ] || {
        echo "ERR: DEPLOY_SCRIPT not found at ${DEPLOY_SCRIPT}"
        exit 1
    }
    echo "No server responding at ${BASE_URL%/v1}/{health,status} — deploying via:"
    echo "  MODEL=${MODEL} PORT=${PORT} bash ${DEPLOY_SCRIPT}"
    echo ""
    MODEL="${MODEL}" PORT="${PORT}" bash "${DEPLOY_SCRIPT}"
    echo ""
    _endpoint_ready "${BASE_URL}" || {
        echo "ERR: ${DEPLOY_SCRIPT} finished but ${BASE_URL%/v1}/{health,status} still isn't responding"
        exit 1
    }
fi

# ── Preflight, second pass: the server side ──────────────────────────────────
# The gate above ran BEFORE deployment on purpose (a sweep that will be refused
# should not first spend 20 minutes loading weights), which means that on the
# auto-deploy path there was no deployment record to check yet. Re-gate now that
# the stack is up, but only if the deployment actually changed under us —
# otherwise this is a duplicate of the first pass and just adds noise.
POST_DEPLOY_SIGNATURE="$(
    deployment_resolve "${BASE_URL}" >/dev/null 2>&1
    printf '%s:%s:%s' "${DEPLOYMENT_RECORD:-}" "${DEPLOYMENT_STATUS:-}" \
        "$([ -n "${DEPLOYMENT_RECORD:-}" ] && deployment_get "${DEPLOYMENT_RECORD}" recorded_epoch || true)"
)"
if [ "${POST_DEPLOY_SIGNATURE}" != "${PRE_DEPLOY_SIGNATURE}" ]; then
    echo ""
    echo "preflight (second pass): the deployment changed since the first gate — re-checking the"
    echo "                         server side, which is only knowable once the stack is up."
    preflight_gate serving || exit 1
else
    # Keep the shell's DEPLOYMENT_* state consistent with what the stamp will
    # report, without re-running the gate.
    deployment_resolve "${BASE_URL}"
fi

echo "llama-benchy: ${MODEL} @ ${BASE_URL}  (track: ${TRACK})"
echo "  depth: ${DEPTH} | pp: ${PP} | tg: ${TG} | concurrency: ${CONCURRENCY}"
echo "  viz: ${VIZ} | results: ${RESULTS}"
echo ""

RESULT_FILE="${RESULTS}/llama-benchy-$(date +%Y%m%d-%H%M%S).${SAVE_FORMAT}"

CMD=(llama-benchy
    --base-url "${BASE_URL}"
    --model "${MODEL}"
    --tg "${TG}"
    --latency-mode "${LATENCY_MODE}"
    --save-result "${RESULT_FILE}"
    --format "${SAVE_FORMAT}"
)
# DEPTH/PP/CONCURRENCY are intentionally unquoted below — they hold
# space-separated lists that llama-benchy expects as separate argv entries.
# shellcheck disable=SC2206  # deliberate split, see above
CMD+=(--depth ${DEPTH})
# shellcheck disable=SC2206
CMD+=(--pp ${PP})
# shellcheck disable=SC2206
CMD+=(--concurrency ${CONCURRENCY})
[ "${EXACT_TG}" = "1" ] && CMD+=(--exact-tg)
[ "${PREFIX_CACHING}" = "1" ] && CMD+=(--enable-prefix-caching)
[ "${SKIP_COHERENCE}" = "1" ] && CMD+=(--skip-coherence)

if [ "${VIZ}" = "1" ]; then
    "${CMD[@]}" --emit-progress - | llama-benchy-viz-tui
else
    "${CMD[@]}"
fi

provenance_write "${RESULT_FILE}" \
    "track=${TRACK}" \
    "deploy_script=${DEPLOY_SCRIPT}" \
    "base_url=${BASE_URL}" \
    "model=${MODEL}" \
    "depth=${DEPTH}" \
    "pp=${PP}" \
    "tg=${TG}" \
    "concurrency=${CONCURRENCY}" \
    "latency_mode=${LATENCY_MODE}" \
    "exact_tg=${EXACT_TG}" \
    "prefix_caching=${PREFIX_CACHING}" \
    "skip_coherence=${SKIP_COHERENCE}" \
    "auto_deploy=${AUTO_DEPLOY}" \
    "llama_benchy_argv=${CMD[*]}"

echo ""
echo "Results saved to ${RESULT_FILE}"
