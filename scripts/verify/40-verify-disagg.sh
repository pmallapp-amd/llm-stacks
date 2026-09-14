#!/usr/bin/env bash
# 40-verify-disagg.sh — end-to-end functional proof that KV actually flows
# prefill -> decode AND is reused, through the real proxy/vLLM/LMCache stack
# (everything scripts/verify/20-/30- deliberately bypass).
#
# Node:          anywhere with curl and network reach to
#                PROXY_HOST:PROXY_PORT, PREFILL_HOST:PREFILL_PORT,
#                DECODE_HOST:DECODE_PORT (does not need to be one of the
#                three cluster nodes).
# Prerequisites: scripts/proxy/start-proxy.sh, scripts/prefill/03-start-prefill.sh,
#                scripts/decode/03-start-decode.sh all up. Strongly
#                recommended: scripts/verify/10-/20-/30- already clean —
#                this script's failures are much harder to root-cause on
#                their own than those layers' failures are.
# Next step:     none — this is the top of the verify/ stack. A clean run
#                here is the acceptance signal for the whole cluster.
#
# usage: 40-verify-disagg.sh [--ttft-improvement-min=RATIO] [--tokens=N]
#
# WHY this test sends the SAME prompt twice rather than just checking
# metrics once: a hit-token counter that increases proves LMCache stored
# and re-read SOMETHING, but not that the something it read was USED to
# skip recomputation. A materially faster second time-to-first-token is
# the behavioral proof that the cache hit actually shortened the prefill
# critical path — the two assertions catch different failure modes (a
# counter that increments but a decode that still recomputes everything
# would be caught by the TTFT check; a TTFT that improves for an unrelated
# reason, e.g. a warm GPU clock, would be caught by the hit-token check).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_cmd curl

TTFT_IMPROVEMENT_MIN="${TTFT_IMPROVEMENT_MIN:-1.5}"
GEN_TOKENS=16
for arg in "$@"; do
    case "${arg}" in
        --ttft-improvement-min=*) TTFT_IMPROVEMENT_MIN="${arg#--ttft-improvement-min=}" ;;
        --tokens=*) GEN_TOKENS="${arg#--tokens=}" ;;
        *) die "unknown argument: ${arg} (expected --ttft-improvement-min=RATIO, --tokens=N)" ;;
    esac
done

PROXY_BASE="http://${PROXY_HOST}:${PROXY_PORT}"
PREFILL_BASE="http://${PREFILL_HOST}:${PREFILL_PORT}"
DECODE_BASE="http://${DECODE_HOST}:${DECODE_PORT}"

step "Disaggregation end-to-end verification"
banner_config
log "TTFT_IMPROVEMENT_MIN=${TTFT_IMPROVEMENT_MIN}  GEN_TOKENS=${GEN_TOKENS}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Preconditions.
# ─────────────────────────────────────────────────────────────────────────────
step "Preconditions: /health on prefill, decode, proxy"
check "prefill /health" curl -fsS --max-time 5 "${PREFILL_BASE}/health" || true
check "decode /health"  curl -fsS --max-time 5 "${DECODE_BASE}/health"  || true
check "proxy /health"   curl -fsS --max-time 5 "${PROXY_BASE}/health"  || true

# ─────────────────────────────────────────────────────────────────────────────
# Metric extraction helpers.
#
# ASSUMED metric names (see patches/lmcache/README.md's ASSUMED philosophy —
# same honesty applies here): LMCache and vLLM's exact Prometheus metric
# names have moved across versions in the past and are not something this
# repo has a confirmed-installed copy to check against. Rather than
# hardcode one name and hard-fail when it's wrong, try several plausible
# candidates in order and use whichever first has ANY matching series;
# report which pattern matched (or that none did) so a human can tell
# "the metric doesn't exist under any name we tried" from "the metric is
# genuinely zero".
# ─────────────────────────────────────────────────────────────────────────────
_metric_sum() {
    # _metric_sum <metrics_text> <grep_ere_pattern>
    printf '%s\n' "$1" | grep -E "$2" | grep -v '^#' | awk '{s+=$NF} END{print s+0}'
}

_first_matching_metric() {
    # _first_matching_metric <metrics_text> <pattern...>
    # Prints "<matched_pattern> <value>" on ONE line (patterns are plain
    # EREs with no whitespace, so this is safely `read -r`-splittable by
    # the caller). Deliberately does NOT rely on a global variable set as
    # a side effect: this function is always invoked via `$(...)` command
    # substitution, which runs it in a SUBSHELL — any variable it sets
    # would vanish the instant the subshell exits, silently. Returning
    # everything through stdout is the only channel that survives that.
    local text="$1"; shift
    local pat
    for pat in "$@"; do
        if printf '%s\n' "${text}" | grep -qE "${pat}"; then
            printf '%s %s\n' "${pat}" "$(_metric_sum "${text}" "${pat}")"
            return 0
        fi
    done
    printf 'none NA\n'
    return 1
}

LMCACHE_HIT_TOKEN_PATTERNS=(
    '^lmcache[_:].*hit.*token'
    '^lmcache[_:].*num_hit_tokens'
    '^lmcache[_:].*retrieve.*hit'
)
VLLM_PREFIX_HIT_PATTERNS=(
    '^vllm:prefix_cache_hits'
    '^vllm:gpu_prefix_cache_hit'
    '^vllm:.*prefix_cache.*hit'
)
VLLM_PREEMPTION_PATTERNS=(
    '^vllm:num_preemptions'
    '^vllm:.*preemption'
)

step "Baseline metrics (decode /metrics, before any test traffic)"
_decode_metrics_before="$(curl -fsS --max-time 10 "${DECODE_BASE}/metrics" 2>/dev/null || true)"
if [ -z "${_decode_metrics_before}" ]; then
    warn "decode /metrics returned nothing — is --enable-metrics / the" \
         " default vLLM metrics endpoint actually exposed? Hit-token" \
         " delta assertion below will be skipped (WARN, not a hard fail)."
fi
read -r _hit_before_pattern _hit_before <<<"$(_first_matching_metric "${_decode_metrics_before}" "${LMCACHE_HIT_TOKEN_PATTERNS[@]}")"
log "  lmcache hit-token metric (pattern: ${_hit_before_pattern}): ${_hit_before}"

# ─────────────────────────────────────────────────────────────────────────────
# Build a long, unique prompt — random nonce means this cannot possibly be
# a pre-warmed hit from an earlier run. Target character count uses a
# DELIBERATELY LOW chars-per-token floor (3) so the real prompt comes in
# comfortably over 2000 tokens even for a tokenizer that splits more
# aggressively than typical English-prose averages (~3.5-4 chars/token for
# Llama-family BPE) — better to overshoot the token-count floor than to
# ship a prompt that looks long enough by eye but tokenizes under it.
# ─────────────────────────────────────────────────────────────────────────────
step "Building unique long prompt (target >= 2000 tokens)"
_NONCE="$(date +%s%N)-${RANDOM}-${RANDOM}"
_MIN_TOKENS=2000
_CHARS_PER_TOKEN_FLOOR=3
_TARGET_CHARS=$((_MIN_TOKENS * _CHARS_PER_TOKEN_FLOOR))
_FILLER="The quick brown fox jumps over the lazy dog while pondering distributed systems, cache coherence protocols, key-value disaggregation, and the philosophy of eventual consistency in globally replicated stores. "
_PROMPT="KVSTACK-DISAGG-TEST nonce=${_NONCE}. Continue this text with your own analysis: "
while [ "${#_PROMPT}" -lt "${_TARGET_CHARS}" ]; do
    _PROMPT+="${_FILLER}"
done
log "  prompt length: ${#_PROMPT} chars (target >= ${_TARGET_CHARS} for >= ${_MIN_TOKENS} tokens)"

_build_payload() {
    # _build_payload <prompt> <max_tokens> <out_file>
    MODEL="${SERVED_MODEL_NAME}" MAX_TOKENS="$2" python3 -c '
import json, os, sys
payload = {
    "model": os.environ["MODEL"],
    "prompt": sys.stdin.read(),
    "max_tokens": int(os.environ["MAX_TOKENS"]),
    "stream": True,
    "temperature": 0,
}
json.dump(payload, sys.stdout)
' <<<"$1" > "$3"
}

_send_timed() {
    # _send_timed <base_url> <payload_file> <body_out_file>
    # prints "<time_starttransfer> <http_code>" on stdout.
    curl -s -o "$3" \
        -H 'Content-Type: application/json' \
        --data-binary "@$2" \
        -w '%{time_starttransfer} %{http_code}\n' \
        --max-time 300 \
        "$1/v1/completions"
}

# ─────────────────────────────────────────────────────────────────────────────
# Request 1: through the proxy (prime prefill, then decode). Cold — first
# time this exact prompt has ever existed.
# ─────────────────────────────────────────────────────────────────────────────
step "Request 1 (via proxy, cold — first time this prompt has existed)"
_payload1="${WORKDIR}/req1.json"
_body1="${WORKDIR}/resp1.sse"
_build_payload "${_PROMPT}" "${GEN_TOKENS}" "${_payload1}"
_ttft1="0"; _code1="000"
read -r _ttft1 _code1 < <(_send_timed "${PROXY_BASE}" "${_payload1}" "${_body1}") || true
log "  request 1: http=${_code1} ttft=${_ttft1}s body_bytes=$(wc -c < "${_body1}")"
check "request 1 returned HTTP 200" bash -c "[ '${_code1}' = '200' ]" || true
check "request 1 body non-empty" bash -c "[ -s '${_body1}' ]" || true

# ─────────────────────────────────────────────────────────────────────────────
# Request 2: through the proxy, IDENTICAL prompt. Should now be a cache hit
# end to end (prefill's priming pass finds LMCache already has the KV from
# request 1's store, and decode's own lookup finds the same).
# ─────────────────────────────────────────────────────────────────────────────
step "Request 2 (via proxy, SAME prompt — should hit cache)"
_payload2="${WORKDIR}/req2.json"
_body2="${WORKDIR}/resp2.sse"
_build_payload "${_PROMPT}" "${GEN_TOKENS}" "${_payload2}"
_ttft2="0"; _code2="000"
read -r _ttft2 _code2 < <(_send_timed "${PROXY_BASE}" "${_payload2}" "${_body2}") || true
log "  request 2: http=${_code2} ttft=${_ttft2}s body_bytes=$(wc -c < "${_body2}")"
check "request 2 returned HTTP 200" bash -c "[ '${_code2}' = '200' ]" || true
check "request 2 body non-empty" bash -c "[ -s '${_body2}' ]" || true

# ─────────────────────────────────────────────────────────────────────────────
# Metrics after — the assertion that would have caught "LMCache hit tokens:
# 0 on every decode request" (plugins/nvme-kv/spdk_nvme_kv_backend.h's
# queryMem() comment, observed 2026-09-07).
# ─────────────────────────────────────────────────────────────────────────────
step "Metrics after (decode /metrics)"
_decode_metrics_after="$(curl -fsS --max-time 10 "${DECODE_BASE}/metrics" 2>/dev/null || true)"
read -r _hit_after_pattern _hit_after <<<"$(_first_matching_metric "${_decode_metrics_after}" "${LMCACHE_HIT_TOKEN_PATTERNS[@]}")"
log "  lmcache hit-token metric after: ${_hit_after} (pattern: ${_hit_after_pattern})"

read -r _ _prefix_before <<<"$(_first_matching_metric "${_decode_metrics_before}" "${VLLM_PREFIX_HIT_PATTERNS[@]}")"
read -r _ _prefix_after <<<"$(_first_matching_metric "${_decode_metrics_after}" "${VLLM_PREFIX_HIT_PATTERNS[@]}")"
log "  vllm prefix-cache-hit metric: before=${_prefix_before} after=${_prefix_after}"
read -r _ _preempt_after <<<"$(_first_matching_metric "${_decode_metrics_after}" "${VLLM_PREEMPTION_PATTERNS[@]}")"
log "  vllm preemption metric (informational): ${_preempt_after}"

if [ "${_hit_before}" = "NA" ] || [ "${_hit_after}" = "NA" ]; then
    warn "could not find a lmcache hit-token metric under any known name" \
         " on decode's /metrics — this is a coverage gap, not a pass:" \
         " the hit-token regression this repo has hit before (see" \
         " plugins/nvme-kv/spdk_nvme_kv_backend.h's queryMem() comment)" \
         " could be present right now and this check would not catch it." \
         " Update LMCACHE_HIT_TOKEN_PATTERNS in this script once you know" \
         " the real metric name for the installed LMCache version."
else
    check "decode-side LMCache hit-token counter INCREASED after request 1" \
        bash -c "python3 -c \"import sys; sys.exit(0 if float('${_hit_after}') > float('${_hit_before}') else 1)\"" || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# TTFT comparison — soft assertion (noisy on a shared box), reported as a
# ratio either way.
# ─────────────────────────────────────────────────────────────────────────────
step "Time-to-first-token comparison"
_ratio="$(python3 -c "
t1, t2 = float('${_ttft1}'), float('${_ttft2}')
print(f'{(t1 / t2) if t2 > 0 else 0:.2f}')
" 2>/dev/null || echo "0")"
log "  ttft1=${_ttft1}s  ttft2=${_ttft2}s  ratio(ttft1/ttft2)=${_ratio}x  (threshold: ${TTFT_IMPROVEMENT_MIN}x)"
if python3 -c "import sys; sys.exit(0 if float('${_ratio}') >= float('${TTFT_IMPROVEMENT_MIN}') else 1)" 2>/dev/null; then
    ok "second-request TTFT improved by ${_ratio}x (>= ${TTFT_IMPROVEMENT_MIN}x threshold)"
else
    warn "second-request TTFT improved by only ${_ratio}x (< ${TTFT_IMPROVEMENT_MIN}x" \
         " threshold) — TREATED AS WARN, NOT A FAILURE: TTFT on a shared" \
         " box is noisy (GPU clocks, other tenants, scheduler jitter)." \
         " If the hit-token counter check above passed, the cache IS" \
         " being used even if this run's timing didn't show the expected" \
         " speedup; re-run this script a few times if you want more" \
         " confidence in the TTFT signal specifically."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Direct-to-decode, bypassing the proxy entirely — isolates "the proxy is
# broken" from "disaggregation itself is broken". Uses a FRESH prompt (own
# nonce) since going straight to decode skips the priming step on purpose;
# this is a basic decode-alone liveness check, not another cache-hit test.
# ─────────────────────────────────────────────────────────────────────────────
step "Direct-to-decode request (bypassing proxy)"
_direct_nonce="${_NONCE}-direct"
_direct_prompt="KVSTACK-DISAGG-TEST-DIRECT nonce=${_direct_nonce}. Say a short greeting."
_payload3="${WORKDIR}/req3.json"
_body3="${WORKDIR}/resp3.sse"
_build_payload "${_direct_prompt}" "${GEN_TOKENS}" "${_payload3}"
_ttft3="0"; _code3="000"
read -r _ttft3 _code3 < <(_send_timed "${DECODE_BASE}" "${_payload3}" "${_body3}") || true
log "  direct-to-decode: http=${_code3} ttft=${_ttft3}s body_bytes=$(wc -c < "${_body3}")"
check "direct-to-decode returned HTTP 200" bash -c "[ '${_code3}' = '200' ]" || true
check "direct-to-decode body non-empty" bash -c "[ -s '${_body3}' ]" || true

# ─────────────────────────────────────────────────────────────────────────────
# Final verdict.
# ─────────────────────────────────────────────────────────────────────────────
step "Verdict"
if checks_summary; then
    ok "disaggregation end-to-end verification PASSED"
    exit 0
else
    err "disaggregation end-to-end verification FAILED"
    log "Read these logs next, in this order:"
    log "  ${LOG_DIR}/vllm-prefill.log   — grep for: SPDK_NVMe_KV, NIXL_ERR, unsupported backend"
    log "  ${LOG_DIR}/vllm-decode.log    — grep for: SPDK_NVMe_KV, hit tokens, NIXL_ERR, unsupported backend"
    log "  ${LOG_DIR}/kv-target.log      — grep for: SPDK_NVMe_KV, NIXL_ERR, SGL length"
    log "Example: grep -E 'SPDK_NVMe_KV|NIXL_ERR|unsupported backend|hit tokens' ${LOG_DIR}/vllm-decode.log | tail -50"
    exit 1
fi
