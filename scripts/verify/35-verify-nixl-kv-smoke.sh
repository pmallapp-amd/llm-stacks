#!/usr/bin/env bash
# 35-verify-nixl-kv-smoke.sh — cross-node smoke test for the nixl_kv
# adapter's NAMING SCHEME and COMMIT PROTOCOL, with no LMCache in the path.
#
# Node:          run from the CONTROL HOST. Drives prefill (writer) and
#                decode (reader) over ssh, inside their containers.
# Prerequisites: both role containers up (scripts/common/container.sh up),
#                /dev/ng1n1 present on both (HANDOFF §3.4), and the KV
#                namespace reachable. No vLLM and no LMCache daemon needed.
# Next step:     the full engine-level acceptance run
#                (docs/design/nixl-kv-l2-adapter.md §9).
#
# ═══════════════════════════════════════════════════════════════════════════
# WHY THIS RUNG EXISTS, GIVEN RUNG 30 ALREADY PASSES
# ═══════════════════════════════════════════════════════════════════════════
# 30-verify-kv-roundtrip.sh proves the DEVICE and the NAMESPACE can carry a
# cross-node store+retrieve (TODO 6.25). It says nothing about whether the
# nixl_kv ADAPTER's scheme is sound. This rung tests exactly that, and only
# that:
#
#   1. tile ordinals    — one ObjectKey becomes N device objects, and page i
#                         must read back as page i. If the ordinal were ever
#                         dropped, every page would collapse onto one key and
#                         hold the LAST page's bytes. Nothing else in the
#                         stack catches that: a 4096 B read returns 4096 B, so
#                         the plugin's cdw0 short-read guard passes, LMCache
#                         reports a hit, and generation is fluent and wrong.
#   2. commit protocol  — the commit object is written only after every page
#                         reports DONE, and is the ONLY thing lookup probes.
#                         That is this medium's os.rename: there is no
#                         tmp-then-publish on a KV namespace.
#   3. group abort      — a commit whose geometry disagrees with the reader's
#                         must abort the whole group, never reassemble it.
#   4. namespace isolation — a different geometry fingerprint must MISS, not
#                         silently read another geometry's bytes.
#
# The writer and reader NEVER exchange a name. Both derive names from
# (namespace, key_string, ordinal) via the adapter's own functions, which
# _nixl_kv_smoke.py IMPORTS rather than re-spells — see that file's header for
# why (patches/lmcache/README.md records what hand-mirroring an on-device
# naming convention cost last time).
#
# NEGATIVE CONTROLS ARE NOT OPTIONAL HERE. This project's §5 trap list opens
# with "a correct completion proves nothing", and §7.6's lesson is that an
# instrument reading zero is not evidence until you have shown it responds at
# all. So the first thing this script does is prove the probe can MISS.
#
# usage: 35-verify-nixl-kv-smoke.sh [--pages N] [--namespace NS]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/common/lib.sh

PAGES=6
NS_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pages)     PAGES="${2:?}"; shift 2 ;;
        --namespace) NS_OVERRIDE="${2:?}"; shift 2 ;;
        *) die "unknown argument: $1 (usage: $0 [--pages N] [--namespace NS])" ;;
    esac
done

# Same derivation as start-lmcache-daemon.sh. Computed HERE rather than read
# from a node so that a node whose cluster.env has drifted shows up as a
# cross-node MISS in this test rather than as a confusing pass.
if [ -n "${NS_OVERRIDE}" ]; then
    NS="${NS_OVERRIDE}"
else
    _NS_INPUT="v1|${MODEL}|${TP_SIZE}|${LMCACHE_CHUNK_SIZE}|${KV_CACHE_DTYPE}|${LMCACHE_L1_ALIGN_BYTES:-4096}|${KV_MAX_VALUE_SIZE_EFFECTIVE}"
    NS="$(printf '%s' "${_NS_INPUT}" | sha256sum | cut -c1-12)"
fi

NONCE="nixlkv-$(date +%s)-$$"
PASS=0; FAIL=0
SMOKE="scripts/verify/_nixl_kv_smoke.py"

# The repo path ON THE NODES, which is NOT this control host's REPO_ROOT --
# deploy.sh puts it at DEPLOY_DEST (default /root/kv-cache). Using REPO_ROOT
# here made every check fail with a `cd: No such file or directory` that
# grep then reported as "<no RESULT line>", i.e. a confusing red on a
# perfectly healthy cluster. Same failure family as HANDOFF §7.12.
NODE_ROOT="${DEPLOY_DEST:-/root/kv-cache}"

step "nixl_kv cross-node smoke test"
info "namespace=${NS}  nonce=${NONCE}  pages=${PAGES}"

# run_on <prefill|decode> <args...> -> prints output, returns script's status
run_on() {
    local role="$1"; shift
    local host user pass
    case "${role}" in
        prefill) host="${PREFILL_HOST}"; user="${PREFILL_USER:-root}"; pass="${PREFILL_PASS}" ;;
        decode)  host="${DECODE_HOST}";  user="${DECODE_USER:-root}";  pass="${DECODE_PASS}" ;;
    esac
    SSHPASS="${pass}" sshpass -e ssh \
        -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=keyboard-interactive,password \
        "${user}@${host}" \
        "cd ${NODE_ROOT} && ./scripts/common/container.sh exec ${role} \"SMOKE_NS=${NS} python3 ${SMOKE} $*\"" 2>&1
}

# check <label> <expected-RESULT-prefix> <role> <args...>
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

# 2. Write from prefill, read+verify from decode. The verify is byte-exact
#    PER PAGE with per-ordinal content, so a collapsed ordinal fails here.
check "cross-node: write ${PAGES} pages on prefill" \
    "RESULT:OK" prefill write --nonce "${NONCE}" --pages "${PAGES}"
check "cross-node: read+verify ${PAGES} pages on decode" \
    "RESULT:OK" decode read --nonce "${NONCE}" --pages "${PAGES}"

# 3. Reverse direction — the tier has to be symmetric to be a shared cache.
REV="${NONCE}-rev"
check "cross-node: write ${PAGES} pages on decode" \
    "RESULT:OK" decode write --nonce "${REV}" --pages "${PAGES}"
check "cross-node: read+verify ${PAGES} pages on prefill" \
    "RESULT:OK" prefill read --nonce "${REV}" --pages "${PAGES}"

# 4. A nonce nobody wrote must MISS even after real data exists in the
#    namespace — otherwise "everything is a hit" passes every test above.
check "negative control: unwritten nonce MISSes" \
    "RESULT:QUERY_MISS" decode read --nonce "${NONCE}-never" \
    --pages "${PAGES}" --expect-miss

# 5. Same content, different geometry fingerprint: MUST miss. This is the
#    whole point of the namespace prefix (design §5) — a dtype or KV-plane
#    change must become a miss, never a mis-typed read.
check "negative control: foreign namespace MISSes" \
    "RESULT:QUERY_MISS" decode read --nonce "${NONCE}" \
    --pages "${PAGES}" --namespace "ffffffffffff" --expect-miss

# 6. Right key, wrong geometry: the commit record must reject the group
#    rather than let a short/long read reassemble a partial one.
check "group abort: page-count disagreement is rejected" \
    "RESULT:COMMIT_INVALID" decode read --nonce "${NONCE}" \
    --pages "$((PAGES + 2))"

echo
if [ "${FAIL}" -eq 0 ]; then
    ok "nixl_kv smoke: ${PASS}/${PASS} passed"
    exit 0
fi
die "nixl_kv smoke: ${FAIL} of $((PASS + FAIL)) checks FAILED"
