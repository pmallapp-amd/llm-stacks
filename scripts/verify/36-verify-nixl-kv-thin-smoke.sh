#!/usr/bin/env bash
# 36-verify-nixl-kv-thin-smoke.sh — cross-node smoke test for the
# PLUGIN-SIDE naming/fan-out/commit scheme (xnvme_kv_backend.cpp), with no
# LMCache in the path. This is now THE acceptance-level naming/commit test
# for this branch: splitting/naming/atomicity live entirely in the plugin
# (this branch no longer carries a Python-side adapter that duplicates that
# protocol — see overlays/lmcache/nixl_kv_thin_l2_adapter.py's docstring),
# so there is only one layer's scheme left to verify.
#
# Node:          run from the CONTROL HOST. Drives prefill (writer) and
#                decode (reader) over ssh, inside their containers.
# Prerequisites: both role containers up (scripts/common/container.sh up),
#                /dev/ng1n1 present on both, and the KV namespace reachable.
#                No vLLM and no LMCache daemon needed.
#
# ═══════════════════════════════════════════════════════════════════════════
# WHY THIS RUNG EXISTS, GIVEN RUNG 30 ALREADY PASSES
# ═══════════════════════════════════════════════════════════════════════════
# 30-verify-kv-roundtrip.sh proves a single-process-pair store+retrieve
# works at all under the plugin's fan-out. This rung adds cross-node name
# AGREEMENT (writer and reader independently derive the same bare name,
# never exchanging it), a namespace-isolation negative control, and --
# unique to this scheme, because the commit marker is synthesized entirely
# inside the plugin's own completion callback rather than by a second
# explicit caller-side store -- a probe-before-commit-lands negative
# control (`race` mode).
#
# NEGATIVE CONTROLS ARE NOT OPTIONAL HERE. An instrument reading zero is not
# evidence until you have shown it can respond at all.
#
# usage: 36-verify-nixl-kv-thin-smoke.sh [--pages N] [--namespace NS]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/common/lib.sh

PAGES=24
NS_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pages)     PAGES="${2:?}"; shift 2 ;;
        --namespace) NS_OVERRIDE="${2:?}"; shift 2 ;;
        *) die "unknown argument: $1 (usage: $0 [--pages N] [--namespace NS])" ;;
    esac
done

# Same derivation as start-lmcache-daemon.sh.
if [ -n "${NS_OVERRIDE}" ]; then
    NS="${NS_OVERRIDE}"
else
    _NS_INPUT="v1|${MODEL}|${TP_SIZE}|${LMCACHE_CHUNK_SIZE}|${KV_CACHE_DTYPE}|${LMCACHE_L1_ALIGN_BYTES:-4096}|${KV_MAX_VALUE_SIZE_EFFECTIVE}"
    NS="$(printf '%s' "${_NS_INPUT}" | sha256sum | cut -c1-12)"
fi

NONCE="nixlkvthin-$(date +%s)-$$"
PASS=0; FAIL=0
SMOKE="scripts/verify/_nixl_kv_thin_smoke.py"

NODE_ROOT="${DEPLOY_DEST:-/root/kv-cache}"

step "nixl_kv_thin (plugin-side fan-out) cross-node smoke test"
info "namespace=${NS}  nonce=${NONCE}  pages=${PAGES}"

run_on() {
    local role="$1"; shift
    kv_ssh "${role}" \
        "cd ${NODE_ROOT} && ./scripts/common/container.sh exec ${role} \"SMOKE_NS=${NS} python3 ${SMOKE} $*\"" 2>&1
}

check() {
    local label="$1" want="$2" role="$3"; shift 3
    local out; out="$(run_on "${role}" "$@" || true)"
    local got; got="$(echo "${out}" | grep -E '^RESULT:' | head -1)"
    if [[ "${got}" == "${want}"* ]]; then
        ok "${label}  [${got}]"
        PASS=$((PASS + 1))
    else
        warn "${label}  EXPECTED ${want}* GOT '${got:-<no RESULT line>}'"
        echo "${out}" | tail -20 >&2
        FAIL=$((FAIL + 1))
    fi
}

# 1. The instrument must be able to read zero BEFORE it is allowed to read
#    one. Probing a nonce nothing has written must MISS.
check "negative control: probe before write MISSes" \
    "RESULT:MISS" decode probe --nonce "${NONCE}" --expect-miss

# 2. Write from prefill as ONE descriptor, read+verify from decode as ONE
#    descriptor. The plugin fans both out internally (~ordinal parts, !c
#    commit) with neither side ever constructing a suffix itself.
check "cross-node: write ${PAGES} page(s) worth, ONE descriptor, on prefill" \
    "RESULT:OK" prefill write --nonce "${NONCE}" --pages "${PAGES}"
check "cross-node: read+verify ${PAGES} page(s) worth on decode" \
    "RESULT:OK" decode read --nonce "${NONCE}" --pages "${PAGES}"

# 3. Reverse direction — the tier has to be symmetric to be a shared cache.
REV="${NONCE}-rev"
check "cross-node: write ${PAGES} page(s) worth on decode" \
    "RESULT:OK" decode write --nonce "${REV}" --pages "${PAGES}"
check "cross-node: read+verify ${PAGES} page(s) worth on prefill" \
    "RESULT:OK" prefill read --nonce "${REV}" --pages "${PAGES}"

# 4. A nonce nobody wrote must MISS even after real data exists in the
#    namespace.
check "negative control: unwritten nonce MISSes" \
    "RESULT:QUERY_MISS" decode read --nonce "${NONCE}-never" \
    --pages "${PAGES}" --expect-miss

# 5. Same content, different geometry fingerprint: MUST miss.
check "negative control: foreign namespace MISSes" \
    "RESULT:QUERY_MISS" decode read --nonce "${NONCE}" \
    --pages "${PAGES}" --namespace "ffffffffffff" --expect-miss

# 6. Unique to this scheme: the commit marker is written entirely inside the
#    plugin's completion callback (xnvme_kv_backend.cpp's kv_complete_cb()),
#    only after every part has durably landed — not by a second explicit
#    Python call the way the earlier Python-side adapter's store did. A
#    probe issued
#    right after transfer() returns (NIXL_IN_PROG, before any part has even
#    necessarily completed) must therefore MISS, and the same name must HIT
#    once the transfer handle itself reports DONE. ${PAGES} wants to be
#    large enough that this window is wide relative to probe latency (~57
#    µs per the design doc) — if this check ever flakes toward a false
#    RACE_FALSE_HIT, raise --pages rather than weakening the assertion.
check "race: probe mid-store MISSes, probe post-DONE HITs" \
    "RESULT:OK" prefill race --nonce "${NONCE}-race" --pages "${PAGES}"

echo
if [ "${FAIL}" -eq 0 ]; then
    ok "nixl_kv_thin smoke: ${PASS}/${PASS} passed"
    exit 0
fi
die "nixl_kv_thin smoke: ${FAIL} of $((PASS + FAIL)) checks FAILED"
