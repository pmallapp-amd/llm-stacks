#!/usr/bin/env bash
# 50-verify-pd-direct.sh — prove the DIRECT SMC1->SMC2 NIXL/UCX transfer
# actually fired, as distinct from a storage-tier (LMCache/SMC3) cache hit
# or vLLM's own upstream prefix cache. Closes docs/TODO.md 1.7's "add a
# verify rung proving the direct transfer actually fired" gap:
# scripts/verify/40-verify-disagg.sh asserts a cache-hit counter rises,
# which passes identically whether the hit came from SMC3, from
# LMCacheMPConnector's reuse tier, or from a direct NixlConnector transfer
# — it cannot distinguish them. This script exists specifically to.
#
# Node:          anywhere with curl and network reach to PREFILL_HOST:
#                PREFILL_PORT and DECODE_HOST:DECODE_PORT. The LOG-based
#                assertions below (the ONLY assertions F5 says are
#                trustworthy) require running ON the prefill/decode node
#                itself, since that is where ${LOG_DIR}/vllm-{prefill,
#                decode}.log actually live — see the per-check notes.
# Prerequisites: scripts/prefill/03-start-prefill.sh,
#                scripts/decode/03-start-decode.sh up, PD_ENABLED=1 (the
#                default — see config/cluster.env).
# Next step:     none — this is the acceptance rung for the direct P->D
#                leg specifically. scripts/verify/40-verify-disagg.sh
#                remains the broader "did caching help at all" proof.
#
# usage: 50-verify-pd-direct.sh [--tokens=N]
#
# ═══════════════════════════════════════════════════════════════════════════
# F5 — THE MEASUREMENT TRAP THIS SCRIPT IS BUILT AROUND
# ═══════════════════════════════════════════════════════════════════════════
# vLLM's own prefix cache sits UPSTREAM of the connector layer. If it hits,
# NO connector is consulted — LMCache or NixlConnector. With a large GPU KV
# cache, same-instance repeats are served by vLLM and every connector looks
# dead no matter what connector order is configured. This is why this
# script:
#   1. Uses a FRESH, high-entropy nonce prompt DECODE has never seen, so
#      decode's own prefix cache cannot possibly have it already.
#   2. Asserts on a non-zero "need to load:" AND a non-zero "External
#      prefix cache hit rate" IN THE LOGS — not on a flag, not on a
#      metric's mere presence, and not on HTTP 200 (a request can return
#      200 having silently recomputed everything).
#   3. Also runs a SECOND, repeat request with the SAME nonce straight to
#      decode, with no handoff metadata attached — this is expected to be
#      served by decode's OWN prefix cache (the connector is never
#      consulted for it), which is deliberately included so this script can
#      show what that outcome looks like in the logs, not just assert it
#      can't happen.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

require_cmd curl python3

GEN_TOKENS=16
for arg in "$@"; do
    case "${arg}" in
        --tokens=*) GEN_TOKENS="${arg#--tokens=}" ;;
        *) die "unknown argument: ${arg} (expected --tokens=N)" ;;
    esac
done

PREFILL_BASE="http://${PREFILL_HOST}:${PREFILL_PORT}"
DECODE_BASE="http://${DECODE_HOST}:${DECODE_PORT}"

step "P->D direct-transfer verification (distinct from a storage/L2 cache hit)"
banner_config
log "PD_ENABLED=${PD_ENABLED} PD_CONNECTOR=${PD_CONNECTOR} PD_LMCACHE_FIRST=${PD_LMCACHE_FIRST}" \
    " PD_HANDOFF_FIELD=${PD_HANDOFF_FIELD}"

if [ "${PD_ENABLED}" != "1" ]; then
    die "PD_ENABLED=${PD_ENABLED} — the direct leg is disabled" \
        " (config/cluster.env's revert switch). There is nothing for this" \
        " script to verify; set PD_ENABLED=1 and restart both roles first."
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Which node is THIS? Same self-detecting pattern as
# scripts/verify/10-verify-network.sh / run-all.sh — determines whether the
# log-based (authoritative, per F5) checks below can run at all.
# ─────────────────────────────────────────────────────────────────────────────
_local_ips="$(hostname -I 2>/dev/null || true)"
THIS_ROLE="unknown"
case " ${_local_ips} " in
    *" ${PREFILL_HOST} "*) THIS_ROLE="prefill" ;;
    *" ${DECODE_HOST} "*)  THIS_ROLE="decode" ;;
esac
info "role: ${THIS_ROLE}   local IPs: ${_local_ips:-<none>}"
DECODE_LOG=""
[ "${THIS_ROLE}" = "decode" ] && DECODE_LOG="$(logfile_for "vllm-decode")"

# ─────────────────────────────────────────────────────────────────────────────
# 1. NIXL side-channel handshake reachability (F2). This is necessary but
#    NOT sufficient for the direct leg firing — it only proves the port is
#    open, not that a handshake actually completed. The log-based checks
#    below are what actually prove a transfer fired.
# ─────────────────────────────────────────────────────────────────────────────
step "NIXL side-channel port reachability"
check "prefill side channel reachable (${PREFILL_HOST}:${NIXL_SIDE_CHANNEL_PORT_PREFILL})" \
    wait_for_port "${PREFILL_HOST}" "${NIXL_SIDE_CHANNEL_PORT_PREFILL}" 5 || true
check "decode side channel reachable (${DECODE_HOST}:${NIXL_SIDE_CHANNEL_PORT_DECODE})" \
    wait_for_port "${DECODE_HOST}" "${NIXL_SIDE_CHANNEL_PORT_DECODE}" 5 || true

step "Preconditions: /health on prefill, decode"
check "prefill /health" curl -fsS --max-time 5 "${PREFILL_BASE}/health" || true
check "decode /health"  curl -fsS --max-time 5 "${DECODE_BASE}/health"  || true

# ─────────────────────────────────────────────────────────────────────────────
# Build a FRESH, high-entropy prompt — decode must never have seen this
# exact content before, or its own upstream prefix cache could serve step 3
# below and this script would misreport a NixlConnector hit that never
# happened (F5).
# ─────────────────────────────────────────────────────────────────────────────
step "Building unique long prompt (target >= 2000 tokens)"
_NONCE="pd-direct-$(date +%s%N)-${RANDOM}-${RANDOM}"
_MIN_TOKENS=2000
_CHARS_PER_TOKEN_FLOOR=3
_TARGET_CHARS=$((_MIN_TOKENS * _CHARS_PER_TOKEN_FLOOR))
_FILLER="The quick brown fox jumps over the lazy dog while pondering distributed systems, cache coherence protocols, key-value disaggregation, and RDMA-versus-storage-mediated KV transfer. "
_PROMPT="KVSTACK-PD-DIRECT-TEST nonce=${_NONCE}. Continue this text with your own analysis: "
while [ "${#_PROMPT}" -lt "${_TARGET_CHARS}" ]; do
    _PROMPT+="${_FILLER}"
done
log "  prompt length: ${#_PROMPT} chars (target >= ${_TARGET_CHARS} for >= ${_MIN_TOKENS} tokens)"

_build_payload() {
    # _build_payload <prompt> <max_tokens> <out_file> [extra_json_file]
    # extra_json_file, if given, is a JSON OBJECT merged into the request
    # body — this is how the captured handoff field gets attached to the
    # decode request.
    local prompt="$1" max_tokens="$2" out="$3" extra="${4:-}"
    MODEL="${SERVED_MODEL_NAME}" MAX_TOKENS="${max_tokens}" EXTRA_FILE="${extra}" python3 -c '
import json, os, sys
payload = {
    "model": os.environ["MODEL"],
    "prompt": sys.stdin.read(),
    "max_tokens": int(os.environ["MAX_TOKENS"]),
    "stream": False,
    "temperature": 0,
}
extra_file = os.environ.get("EXTRA_FILE", "")
if extra_file:
    with open(extra_file) as f:
        extra = json.load(f)
    if isinstance(extra, dict):
        payload.update(extra)
json.dump(payload, sys.stdout)
' <<<"${prompt}" > "${out}"
}

_send() {
    # _send <base_url> <payload_file> <body_out_file> — prints "<http_code>"
    curl -s -o "$3" \
        -H 'Content-Type: application/json' \
        --data-binary "@$2" \
        -w '%{http_code}' \
        --max-time 120 \
        "$1/v1/completions"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Prime prefill DIRECTLY (bypassing the proxy on purpose — this isolates
#    "is the direct leg wired correctly at all" from "is the proxy threading
#    it correctly", which scripts/verify/40-verify-disagg.sh /
#    scripts/proxy/disagg_proxy.py's own /status counter cover separately).
#    Capture the response and extract PD_HANDOFF_FIELD from it.
# ─────────────────────────────────────────────────────────────────────────────
step "Priming prefill directly (max_tokens=1) and capturing ${PD_HANDOFF_FIELD}"
_prime_payload="${WORKDIR}/prime.json"
_prime_body="${WORKDIR}/prime.resp"
_build_payload "${_PROMPT}" 1 "${_prime_payload}"
_prime_code="$(_send "${PREFILL_BASE}" "${_prime_payload}" "${_prime_body}")"
log "  prefill priming: http=${_prime_code} body_bytes=$(wc -c < "${_prime_body}")"
check "prefill priming returned HTTP 200" bash -c "[ '${_prime_code}' = '200' ]" || true

_handoff_json="${WORKDIR}/handoff.json"
_HANDOFF_PRESENT=0
if PD_HANDOFF_FIELD="${PD_HANDOFF_FIELD}" python3 -c '
import json, os, sys
field = os.environ["PD_HANDOFF_FIELD"]
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as exc:
    print(f"prime response not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)
value = data.get(field) if isinstance(data, dict) else None
if value is None:
    print(f"no {field!r} field in prime response", file=sys.stderr)
    sys.exit(1)
with open(sys.argv[2], "w") as f:
    json.dump({field: value}, f)
' "${_prime_body}" "${_handoff_json}" 2>"${WORKDIR}/handoff.err"; then
    _HANDOFF_PRESENT=1
    ok "captured ${PD_HANDOFF_FIELD} from prefill's response"
else
    warn "$(cat "${WORKDIR}/handoff.err")"
    warn "THIS IS THE SIGNATURE OF A MISCONFIGURED DIRECT LEG (per" \
         " scripts/proxy/disagg_proxy.py's prefill_no_handoff counter):" \
         " either NixlConnector isn't composed into --kv-transfer-config" \
         " (check PD_ENABLED, gen-kv-transfer-config.sh's output), or this" \
         " installed vLLM names the handoff field something other than" \
         " '${PD_HANDOFF_FIELD}' — override PD_HANDOFF_FIELD in" \
         " config/cluster.env if so."
fi
check "prefill response carried ${PD_HANDOFF_FIELD}" bash -c "[ '${_HANDOFF_PRESENT}' = '1' ]" || true

# ─────────────────────────────────────────────────────────────────────────────
# 3. Send the matching request to decode WITH the captured handoff attached
#    (if we got one) — this is the request that should trigger a NixlConnector
#    remote load if the direct leg is wired correctly.
# ─────────────────────────────────────────────────────────────────────────────
step "Sending matching request to decode (fresh nonce, first time decode has seen it)"
_decode_log_lines_before=0
[ -n "${DECODE_LOG}" ] && [ -f "${DECODE_LOG}" ] && _decode_log_lines_before="$(wc -l < "${DECODE_LOG}")"

_decode_payload="${WORKDIR}/decode1.json"
_decode_body="${WORKDIR}/decode1.resp"
if [ "${_HANDOFF_PRESENT}" -eq 1 ]; then
    _build_payload "${_PROMPT}" "${GEN_TOKENS}" "${_decode_payload}" "${_handoff_json}"
else
    _build_payload "${_PROMPT}" "${GEN_TOKENS}" "${_decode_payload}"
fi
_decode_code="$(_send "${DECODE_BASE}" "${_decode_payload}" "${_decode_body}")"
log "  decode (first, fresh): http=${_decode_code} body_bytes=$(wc -c < "${_decode_body}")"
check "decode (first) returned HTTP 200" bash -c "[ '${_decode_code}' = '200' ]" || true

_decode_log_lines_after=0
_decode_new_log=""
if [ -n "${DECODE_LOG}" ] && [ -f "${DECODE_LOG}" ]; then
    _decode_log_lines_after="$(wc -l < "${DECODE_LOG}")"
    _decode_new_log="$(tail -n "+$((_decode_log_lines_before + 1))" "${DECODE_LOG}")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Repeat request, SAME nonce, straight to decode, WITHOUT the handoff
#    field — this is expected to be served by decode's OWN upstream prefix
#    cache (populated by step 3's generation), which is the outcome that
#    makes every connector look dead if mistaken for a connector hit. Shown
#    here deliberately so this script demonstrates, not just asserts, the
#    distinction the whole file is about.
# ─────────────────────────────────────────────────────────────────────────────
step "Repeat request to decode, SAME nonce, no handoff (expected: vLLM's own prefix cache)"
_decode_log_lines_before2="${_decode_log_lines_after}"
_decode_payload2="${WORKDIR}/decode2.json"
_decode_body2="${WORKDIR}/decode2.resp"
_build_payload "${_PROMPT}" "${GEN_TOKENS}" "${_decode_payload2}"
_decode_code2="$(_send "${DECODE_BASE}" "${_decode_payload2}" "${_decode_body2}")"
log "  decode (repeat): http=${_decode_code2} body_bytes=$(wc -c < "${_decode_body2}")"
check "decode (repeat) returned HTTP 200" bash -c "[ '${_decode_code2}' = '200' ]" || true

_decode_new_log2=""
if [ -n "${DECODE_LOG}" ] && [ -f "${DECODE_LOG}" ]; then
    _decode_new_log2="$(tail -n "+$((_decode_log_lines_before2 + 1))" "${DECODE_LOG}")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. The verdict — per F5, built ONLY from log evidence, never from a flag
#    or from the request having returned 200. If this host is not
#    prefill/decode, the log is unavailable and this section says so
#    plainly rather than guessing from HTTP status alone.
# ─────────────────────────────────────────────────────────────────────────────
step "Verdict: which tier actually served request 3 (the fresh-nonce one)?"

NEED_TO_LOAD_RE='need to load: *[1-9][0-9]*'
EXTERNAL_HIT_RE='External prefix cache hit rate'
LMCACHE_HIT_RE='lmcache.*(hit|retriev).*[1-9]'
VLLM_PREFIX_HIT_RE='prefix.cache.*hit'

if [ -z "${DECODE_LOG}" ]; then
    warn "this host is not the decode node (THIS_ROLE=${THIS_ROLE}) —" \
         " ${LOG_DIR}/vllm-decode.log is not locally readable from here." \
         " Re-run this script directly ON ${DECODE_NAME} (${DECODE_HOST})" \
         " for the authoritative, log-based verdict (F5: metrics/flags" \
         " alone are not trustworthy evidence). HTTP-level results above" \
         " (200s, response sizes) are NOT a substitute for this."
elif [ ! -f "${DECODE_LOG}" ]; then
    warn "expected decode log ${DECODE_LOG} does not exist — is" \
         " scripts/decode/03-start-decode.sh actually running via" \
         " start_bg (see lib.sh)? Cannot render a verdict without it."
else
    _need_to_load_hit=0
    printf '%s\n' "${_decode_new_log}" | grep -qE "${NEED_TO_LOAD_RE}" && _need_to_load_hit=1
    _external_hit_rate_hit=0
    printf '%s\n' "${_decode_new_log}" | grep -qE "${EXTERNAL_HIT_RE}" && _external_hit_rate_hit=1
    _lmcache_hit=0
    printf '%s\n' "${_decode_new_log}" | grep -qiE "${LMCACHE_HIT_RE}" && _lmcache_hit=1
    _vllm_prefix_hit=0
    printf '%s\n' "${_decode_new_log}" | grep -qiE "${VLLM_PREFIX_HIT_RE}" && _vllm_prefix_hit=1

    log "  request 3 (fresh nonce) new decode log evidence:"
    log "    'need to load: <nonzero>'        : $([ "${_need_to_load_hit}" = 1 ] && echo yes || echo no)"
    log "    'External prefix cache hit rate' : $([ "${_external_hit_rate_hit}" = 1 ] && echo yes || echo no)"
    log "    lmcache hit/retrieve line        : $([ "${_lmcache_hit}" = 1 ] && echo yes || echo no)"
    log "    vllm prefix-cache-hit line       : $([ "${_vllm_prefix_hit}" = 1 ] && echo yes || echo no)"

    check "request 3: non-zero 'need to load:' present in decode log" \
        bash -c "[ '${_need_to_load_hit}' = '1' ]" || true
    check "request 3: non-zero 'External prefix cache hit rate' present in decode log" \
        bash -c "[ '${_external_hit_rate_hit}' = '1' ]" || true

    if [ "${_need_to_load_hit}" = 1 ] && [ "${_external_hit_rate_hit}" = 1 ]; then
        ok "VERDICT (request 3): served by NixlConnector DIRECT transfer" \
           " (P->D leg fired — both required log signals present)"
    elif [ "${_lmcache_hit}" = 1 ]; then
        warn "VERDICT (request 3): served by LMCache L2 (storage-mediated" \
             " reuse tier), NOT the direct NixlConnector leg — the" \
             " required 'need to load:'/'External prefix cache hit rate'" \
             " signals were absent. Check PD_LMCACHE_FIRST (should be 0" \
             " for NixlConnector to get first refusal) and confirm" \
             " PD_ENABLED=1 actually took effect on both roles."
    elif [ "${_vllm_prefix_hit}" = 1 ]; then
        warn "VERDICT (request 3): apparently served by vLLM's OWN prefix" \
             " cache — unexpected for a fresh nonce decode has never seen;" \
             " investigate whether this nonce collided with a prior run or" \
             " whether decode's block-hash keying is broader than expected."
    else
        warn "VERDICT (request 3): NO connector evidence found at all —" \
             " neither NixlConnector nor LMCache signals appear in the new" \
             " decode log lines. Likely a cold miss/recompute; see the" \
             " grep patterns below to start diagnosing."
    fi

    log ""
    log "  request 4 (repeat, same nonce, no handoff) — expected outcome:" \
        " vLLM's OWN prefix cache serves it, connector never consulted:"
    _vllm_prefix_hit2=0
    printf '%s\n' "${_decode_new_log2}" | grep -qiE "${VLLM_PREFIX_HIT_RE}" && _vllm_prefix_hit2=1
    _need_to_load_hit2=0
    printf '%s\n' "${_decode_new_log2}" | grep -qE "${NEED_TO_LOAD_RE}" && _need_to_load_hit2=1
    if [ "${_need_to_load_hit2}" = 0 ]; then
        ok "  confirmed: no 'need to load:' line for the repeat request —" \
           " consistent with vLLM's own prefix cache serving it upstream" \
           " of any connector, exactly the F5 confound this script exists" \
           " to make visible rather than mistake for a dead connector."
    else
        warn "  unexpected: repeat request STILL shows 'need to load:' —" \
             " decode's own prefix cache may not have retained the block" \
             " (evicted already, or --enable-prefix-caching not active)."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Final summary + failure diagnostics.
# ─────────────────────────────────────────────────────────────────────────────
step "Verdict summary"
if checks_summary; then
    ok "P->D direct-transfer verification PASSED"
    exit 0
else
    err "P->D direct-transfer verification FAILED"
    log "Grep these patterns next, in ${LOG_DIR}/vllm-{prefill,decode}.log:"
    log "  NIXL_ERR_BACKEND"
    log "  registerMem: registration failed"
    log "  VRAM memory is detected as host"
    log "  no usable transports"
    log "  is not available"
    log "  need to load:"
    log "  External prefix cache hit rate"
    log "Example: grep -E 'NIXL_ERR_BACKEND|registerMem: registration failed|VRAM memory is detected as host|no usable transports|is not available|need to load:|External prefix cache hit rate' ${LOG_DIR}/vllm-decode.log | tail -50"
    exit 1
fi
