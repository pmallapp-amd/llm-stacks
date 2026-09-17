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
#                scripts/decode/03-start-decode.sh up. P/D disaggregation
#                is always on in this architecture (there is no PD_ENABLED
#                switch anymore — see config/cluster.env's "Compute leg"
#                section: composition is fixed as
#                MultiConnector[NixlConnector, LMCacheMPConnector]).
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
#   2. Captures a BASELINE of the "External prefix cache hit rate" before
#      sending the request, then POLLS the decode log for a NEW stats line
#      (up to 45 s, 2 s intervals).  Asserts that the EXTERNAL PREFIX CACHE
#      HIT RATE ROSE vs. baseline — this is the only log signal that
#      empirically discriminates between "direct transfer fired" and
#      "decode recomputed everything" on this stack (vLLM 0.26.0+rocm,
#      LMCache 0.5.3).  The mere PRESENCE of the hit-rate string is
#      meaningless (it is cumulative and always printed); only the DELTA is
#      meaningful.  "need to load:" is retained as corroborating-only: it
#      is NEVER emitted by this stack at default verbosity, and was verified
#      absent on runs independently proven to transfer KV — but stacks that
#      DO emit it still surface via the report-only check.
#   3. Also runs a SECOND, repeat request with the SAME nonce straight to
#      decode, with no handoff metadata attached — this is expected to be
#      served by decode's OWN prefix cache (the connector is never
#      consulted for it), which is deliberately included so this script can
#      show what that outcome looks like in the logs, not just assert it
#      can't happen.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

# NOTE: deliberately NOT requiring `bc`. It is absent from the runtime image
# this stack actually runs in (rocm-aic:mp-pd-ionic2609 ships no bc), so a
# `require_cmd ... bc` here would `die` before a single check ran — turning a
# working acceptance rung into an unconditional failure. The one float
# comparison this script needs is done with awk, which is present everywhere.
require_cmd curl python3 awk

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
log "connector composition (fixed, not configurable): MultiConnector[NixlConnector," \
    " LMCacheMPConnector], NixlConnector FIRST — PD_HANDOFF_FIELD=${PD_HANDOFF_FIELD}"

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
# NOTE: the bound side-channel address may differ from the inference-plane
# ${PREFILL_HOST}/${DECODE_HOST} (the management IP). lib.sh setup_pd_env()
# resolves the actual bound address as ${PD_SIDE_CHANNEL_HOST_<ROLE>} if
# set, else hostname -I | awk '{print $1}' — on a decode node whose first
# IP is a fabric address (e.g. 30.2.1.1), probing ${DECODE_HOST} alone would
# produce a false-negative reachability failure on a perfectly healthy
# system. Use the same resolution logic here.
_check_sc_prefill="${PD_SIDE_CHANNEL_HOST_PREFILL:-${PREFILL_HOST}}"
_check_sc_decode="${PD_SIDE_CHANNEL_HOST_DECODE:-${DECODE_HOST}}"
check "prefill side channel reachable (${_check_sc_prefill}:${NIXL_SIDE_CHANNEL_PORT_PREFILL})" \
    wait_for_port "${_check_sc_prefill}" "${NIXL_SIDE_CHANNEL_PORT_PREFILL}" 5 || true
check "decode side channel reachable (${_check_sc_decode}:${NIXL_SIDE_CHANNEL_PORT_DECODE})" \
    wait_for_port "${_check_sc_decode}" "${NIXL_SIDE_CHANNEL_PORT_DECODE}" 5 || true

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
# The priming request MUST ask for the handoff, or NixlConnector never
# stages blocks and returns no ${PD_HANDOFF_FIELD} at all — prefill answers
# perfectly normally, decode silently re-prefills the whole prompt, and
# every request succeeds at correct latency while no disaggregation happens
# at all ("looks fine, isn't" failure per scripts/proxy/disagg_proxy.py
# lines 48-51). The handoff-request shape mirrors disagg_proxy.py lines
# 396-403: do_remote_decode=True, do_remote_prefill=False, remote_*: None.
# ─────────────────────────────────────────────────────────────────────────
step "Priming prefill directly (max_tokens=1) and capturing ${PD_HANDOFF_FIELD}"
_prime_payload="${WORKDIR}/prime.json"
_prime_body="${WORKDIR}/prime.resp"
_handoff_req_json="${WORKDIR}/handoff_req.json"
HANDOFF_FIELD="${PD_HANDOFF_FIELD}" python3 -c '
import json, os, sys
json.dump({
    os.environ["HANDOFF_FIELD"]: {
        "do_remote_decode": True,
        "do_remote_prefill": False,
        "remote_engine_id": None,
        "remote_block_ids": None,
        "remote_host": None,
        "remote_port": None,
    }
}, sys.stdout)
' > "${_handoff_req_json}"
_build_payload "${_PROMPT}" 1 "${_prime_payload}" "${_handoff_req_json}"
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
         " either NixlConnector isn't actually composed into" \
         " --kv-transfer-config on prefill (check" \
         " gen-kv-transfer-config.sh's actual emitted output — the" \
         " composition is hardcoded to MultiConnector[NixlConnector," \
         " LMCacheMPConnector], so this would be a real bug in that" \
         " generator, not a config flag left in the wrong state), or this" \
         " installed vLLM names the handoff field something other than" \
         " '${PD_HANDOFF_FIELD}' — override PD_HANDOFF_FIELD in" \
         " config/cluster.env if so."
fi
check "prefill response carried ${PD_HANDOFF_FIELD}" bash -c "[ '${_HANDOFF_PRESENT}' = '1' ]" || true

# ─────────────────────────────────────────────────────────────────────────────
# 3. Send the matching request to decode WITH the captured handoff attached
#    (if we got one) — this is the request that should trigger a NixlConnector
#    remote load if the direct leg is wired correctly.
#
#    The verification strategy (per F5) relies on LOG EVIDENCE, not HTTP
#    status. vLLM emits stats (including "External prefix cache hit rate")
#    from a PERIODIC logger roughly every 10 seconds (stat "Avg prompt
#    throughput", "External prefix cache hit rate"). This creates a RACE
#    condition: if we grep the log immediately after the request returns, the
#    stats line covering that request likely has NOT been written yet — the
#    periodic logger may fire up to ~10s after the request finishes (measured
#    on vLLM 0.26.0+rocm + LMCache 0.5.3: the grep and the proving line both
#    timestamp at the same second and still miss each other). We therefore
#    capture a BASELINE of the "External prefix cache hit rate" BEFORE
#    sending the request, then POLL for a NEW stats line after it returns.
# ─────────────────────────────────────────────────────────────────────────────
step "Sending matching request to decode (fresh nonce, first time decode has seen it)"

# --- Baseline: capture the LAST "External prefix cache hit rate: N%" value
#     in the decode log before sending request 3.  The periodic logger writes
#     a line shaped like:
#       Avg prompt throughput: 2.1 tokens/s, ..., External prefix cache hit rate: 48.3%, ...
#     We extract just the numeric rate.  If no stats line exists yet, treat
#     baseline as 0.0.
_baseline_rate=0.0
if [ -n "${DECODE_LOG}" ] && [ -f "${DECODE_LOG}" ]; then
    _last_hit_line="$(grep -oP 'External prefix cache hit rate:\s*\K[0-9]+(\.[0-9]+)?' "${DECODE_LOG}" 2>/dev/null | tail -1 || true)"
    [ -n "${_last_hit_line}" ] && _baseline_rate="${_last_hit_line}"
fi
log "  baseline 'External prefix cache hit rate': ${_baseline_rate}%"

# Capture line count BEFORE sending, so we can later isolate lines written
# after the request (the poll loop waits for the stats line itself, but we
# also keep the old windowing logic for the "need to load:" corroboration
# and for request 4).
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

# --- Poll for a NEW stats line.  The periodic logger may not have fired
#     yet, so we wait up to 45 seconds, sleeping 2s between attempts.  When
#     a new line appears after our pre-request line count, we extract the
#     "External prefix cache hit rate" value.  If none appears in 45s, this
#     is a hard FAIL — the periodic logger is missing, so we cannot render a
#     verdict at all, which is distinct from "a stats line appeared and showed
#     no hit".
_POLLED_LINE=""
_POLLED_RATE=""
_POLL_DEADLINE=$(( $(date +%s) + 45 ))
if [ -n "${DECODE_LOG}" ] && [ -f "${DECODE_LOG}" ]; then
    while [ "$(date +%s)" -lt "${_POLL_DEADLINE}" ]; do
        _candidate="$(tail -n "+$((_decode_log_lines_before + 1))" "${DECODE_LOG}" 2>/dev/null \
            | grep -oP 'External prefix cache hit rate:\s*\K[0-9]+(\.[0-9]+)?' | tail -1 || true)"
        if [ -n "${_candidate}" ]; then
            _POLLED_LINE="${_candidate}"
            _POLLED_RATE="${_candidate}"
            break
        fi
        sleep 2
    done
fi

if [ -n "${DECODE_LOG}" ] && [ -f "${DECODE_LOG}" ]; then
    if [ -z "${_POLLED_LINE}" ]; then
        check "request 3: periodic stats line appeared after request (polled 45s)" \
            false
        log "  FATAL: no 'External prefix cache hit rate' stats line appeared in" \
            " decode log within 45 seconds of sending request 3. The vLLM periodic" \
            " logger (stat 'Avg prompt throughput', 'External prefix cache hit rate')" \
            " may not be running, or the log path (${DECODE_LOG}) does not match" \
            " what vLLM is actually writing to. This is a SYSTEM-LEVEL failure" \
            " distinct from a stats-line-that-showed-no-hit — no verdict is" \
            " possible without the stats evidence."
    else
        log "  polled 'External prefix cache hit rate': ${_POLLED_RATE}%"
    fi
fi

# Also capture the raw new-log window for corroborating signals (need to load,
# lmcache hit, vLLM prefix hit, and for request 4's window).
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
#
#    ═══════════════════════════════════════════════════════════════════════════
#    WHY "need to load:" is CORROBORATING-ONLY (demoted from hard assert)
#    ═══════════════════════════════════════════════════════════════════════════
#    vLLM 0.26.0+rocm + LMCache 0.5.3 at default verbosity NEVER emits the
#    string "need to load:" in its logs.  This was verified by grep'ing the
#    full decode log across many requests, including on runs independently
#    PROVED to have transferred KV (the "External prefix cache hit rate"
#    delta confirmed the transfer).  Zero occurrences were found.
#
#    Asserting on a string this stack never emits can never pass, making it
#    a dead assertion that silently renders the whole script a rubber stamp
#    (the check always fails and is ||true'd away).  We retain it as a
#    corroborating-only signal so that stacks which DO emit it (older vLLM
#    versions, LMCache configurations with DEBUG logging, or custom builds)
#    still surface the information — but the hard gate is the one signal
#    that actually works on this stack.
#
#    ═══════════════════════════════════════════════════════════════════════════
#    WHY "External prefix cache hit rate" presence is INSUFFICIENT
#    ═══════════════════════════════════════════════════════════════════════════
#    The "External prefix cache hit rate" is a CUMULATIVE / rolling rate,
#    not a per-request statistic.  It is printed on EVERY stats line,
#    including when the current window had zero external hits (value: 0.0%).
#    The string appears identically whether the transfer succeeded or not.
#    Merely grepping for its presence would PASS on a system that never
#    transferred anything, which is exactly the false-positive trap F5 warns
#    about.
#
#    The real signal is the DELTA: if the external prefix cache hit rate
#    ROSE after the handoff-attached request, the direct P->D leg delivered
#    KV blocks that LMCache's reuse tier or vLLM's upstream prefix cache
#    would not have had.  If it FELL or stayed flat, the request was served
#    without an external transfer — even though the string "External prefix
#    cache hit rate" is present in both outcomes.
#
#    Measured on vLLM 0.26.0+rocm + LMCache 0.5.3 + Qwen3-8B TP=1,
#    MultiConnector[NixlConnector, LMCacheMPConnector], ~1230-token fresh-
#    nonce prompt:
#
#      WITH handoff (direct transfer)    -> "External prefix cache hit rate"
#                                            ROSE (48.3% -> 58.2%)
#      WITHOUT handoff (recompute)       -> "External prefix cache hit rate"
#                                            FELL (50.5% -> 33.4%)
#
#    The absolute rate value varies with workload history (cumulative), but
#    the DIRECTION of change relative to a pre-request baseline is the
#    discriminator.
# ═══════════════════════════════════════════════════════════════════════════
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

    # Assess poll result: baseline was captured BEFORE sending request 3;
    # _POLLED_RATE is the first new "External prefix cache hit rate" value
    # that appeared in the decode log AFTER the request.  Compute the delta.
    _new_rate_numeric=0.0
    if [ -n "${_POLLED_RATE}" ]; then
        _new_rate_numeric="${_POLLED_RATE}"
    fi
    _rate_increased=0
    # Float compare via awk, NOT bc: these are decimal strings like "48.3",
    # and bc is not installed in the rocm-aic runtime image this actually
    # runs in. awk exits 0 only when the comparison holds, so the `if` reads
    # directly off its status with no output parsing.
    if [ -n "${_POLLED_RATE}" ]; then
        if awk -v new="${_new_rate_numeric}" -v base="${_baseline_rate}" \
               'BEGIN { exit !(new > base) }'; then
            _rate_increased=1
        fi
    fi

    log "  request 3 (fresh nonce) decode log evidence:"
    log "    external prefix cache hit rate: ${_baseline_rate}% -> ${_new_rate_numeric}% (baseline -> polled)"
    log "    'need to load: <nonzero>'       : $([ "${_need_to_load_hit}" = 1 ] && echo yes || echo no)"
    log "    lmcache hit/retrieve line       : $([ "${_lmcache_hit}" = 1 ] && echo yes || echo no)"
    log "    vllm prefix-cache-hit line      : $([ "${_vllm_prefix_hit}" = 1 ] && echo yes || echo no)"

    # ── HARD ASSERT (the one strong gate, per F5) ──
    # The external prefix cache hit rate MUST have increased relative to the
    # pre-request baseline.  This is the only signal that empirically
    # discriminates between "direct transfer fired" and "decode recomputed
    # everything" on this stack (vLLM 0.26.0+rocm, LMCache 0.5.3).
    check "request 3: external prefix cache hit rate rose (${_baseline_rate}% -> ${_new_rate_numeric}%)" \
        bash -c "[ '${_rate_increased}' = '1' ]" || true

    # ── CORROBORATING, report-only ──
    # Decode "Avg prompt throughput" in the new window: near-zero
    # corroborates a KV transfer (decode skips prefill), a large value means
    # decode recomputed the prefix.
    _avg_prompt_throughput="$(printf '%s\n' "${_decode_new_log}" \
        | grep -oP 'Avg prompt throughput:\s*\K[0-9.]+' | tail -1 || true)"
    if [ -n "${_avg_prompt_throughput}" ]; then
        log "    corroborating: decode 'Avg prompt throughput' = ${_avg_prompt_throughput} tokens/s" \
            " (near-zero = KV transfer avoided prefill; large = decode recomputed)"
    else
        log "    corroborating: no 'Avg prompt throughput' line in new decode log window" \
            " (periodic logger line may fall outside the window)"
    fi

    # ── CORROBORATING, report-only ──
    # "need to load:" if present — retained for stacks that DO emit it (see
    # the comment block above for why this was demoted).
    if [ "${_need_to_load_hit}" = 1 ]; then
        log "    corroborating: 'need to load: <nonzero>' IS present in decode log" \
            " (this stack does not emit it at default verbosity, but it would be" \
            " a positive signal on stacks that do)"
    fi

    # ── Narrate the verdict ──
    if [ "${_rate_increased}" = 1 ]; then
        ok "VERDICT (request 3): served by NixlConnector DIRECT transfer" \
           " (P->D leg fired — external prefix cache hit rate rose" \
           " ${_baseline_rate}% -> ${_new_rate_numeric}%)"
    elif [ "${_lmcache_hit}" = 1 ]; then
        warn "VERDICT (request 3): served by LMCache L2 (storage-mediated" \
             " reuse tier), NOT the direct NixlConnector leg — the" \
             " external prefix cache hit rate did NOT rise" \
             " (${_baseline_rate}% -> ${_new_rate_numeric}%)." \
             " Connector order is HARDCODED as" \
             " MultiConnector[NixlConnector, LMCacheMPConnector] with" \
             " NixlConnector FIRST (config/cluster.env's 'Compute leg'" \
             " section — MultiConnector.get_num_new_matched_tokens() gives" \
             " the match to whichever child reports non-zero FIRST, and" \
             " there is no longer a PD_LMCACHE_FIRST switch to have gotten" \
             " this backwards). If LMCache is winning the match instead of" \
             " NixlConnector, check scripts/common/gen-kv-transfer-config.sh's" \
             " actual emitted --kv-transfer-config on decode for the real" \
             " child order, and confirm the direct leg's prerequisites" \
             " (NIXL side-channel reachability, F2; UCX_NET_DEVICES" \
             " resolving to a routable interface) actually held for this" \
             " request — see scripts/verify/10-verify-network.sh."
    elif [ "${_vllm_prefix_hit}" = 1 ]; then
        warn "VERDICT (request 3): apparently served by vLLM's OWN prefix" \
             " cache — unexpected for a fresh nonce decode has never seen;" \
             " investigate whether this nonce collided with a prior run or" \
             " whether decode's block-hash keying is broader than expected."
    else
        warn "VERDICT (request 3): NO connector evidence found at all —" \
             " neither NixlConnector nor LMCache signals appear in the new" \
             " decode log lines, and the external prefix cache hit rate did" \
             " NOT rise (${_baseline_rate}% -> ${_new_rate_numeric}%)." \
             " Likely a cold miss/recompute; see the grep patterns below" \
             " to start diagnosing."
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
