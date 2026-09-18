#!/usr/bin/env bash
# 60-verify-l2-crossnode.sh — THE acceptance rung for the nixl_kv L2 tier.
#
# Node:          run from the CONTROL HOST. Drives prefill (writer) and
#                decode (reader) over ssh.
# Prerequisites: both role containers up, amdgpu loaded, /dev/ng1n1 present,
#                model weights staged. Rungs 20/30/35 green.
# Next step:     nothing — this is the top of the ladder for the storage tier.
#
# ═══════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES, AND THE THREE THINGS THAT CAN FAKE IT
# ═══════════════════════════════════════════════════════════════════════════
# Claim under test: a KV chunk computed on ONE node is discovered and served
# on ANOTHER node, from the shared KV namespace, through LMCache — i.e. the
# L2 tier is a genuinely shared cache, not a per-daemon capacity extension.
#
# Three separate mechanisms can produce a convincing-looking hit while that
# claim is false. All three must be structurally excluded, not argued away:
#
#   1. vLLM's OWN PREFIX CACHE sits upstream of every connector. If it hits,
#      no connector is consulted at all. EXCLUDED BY: restarting the reader's
#      vLLM between the baseline and the test, so its prefix cache is empty
#      by construction rather than by assumption.
#
#   2. THE P->D NixlConnector LEG can move the same KV directly, and
#      MultiConnector gives the whole load to the FIRST child reporting a
#      match — NixlConnector, which is hardcoded connectors[0] (HANDOFF §1).
#      EXCLUDED BY: killing the writer node's vLLM outright before the read,
#      so there is no peer to pull from, and by addressing the reader's
#      engine DIRECTLY rather than through the proxy.
#
#   3. L1 (host DRAM) absorbs everything — measured: a same-daemon prefetch
#      reported "4/4 retained keys (4 L1, 0 L2)", which is why prefill-only
#      retrieve_ops=0 was long misfiled as a bug (TODO 6.21's "open half").
#      EXCLUDED BY: restarting the reader's LMCache DAEMON, which empties L1
#      and the in-process index together.
#
# The counter that specifically proves the fix is l2_device_hits > 0 WITH
# l2_index_hits == 0: a key served by DISCOVERING it on the device, in a
# daemon that never stored it. Every other signal is satisfiable by a
# same-daemon hit.
#
# And the assertion that cannot pass while the bytes are wrong is TOKEN
# IDENTITY against a recompute baseline. A page-collapse bug (all pages of a
# chunk landing on one device key) returns 4096 B for a 4096 B read, so the
# plugin's cdw0 short-read guard passes, LMCache reports a hit, throughput
# drops to zero, and the output is fluent and WRONG. Every check in this
# script except token identity passes under that failure.
#
# usage: 60-verify-l2-crossnode.sh [--tokens N] [--keep-up]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/common/lib.sh

PROMPT_TOKENS=1200        # >= 2 chunks at chunk_size=256
KEEP_UP=0
NO_DRAIN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --tokens)  PROMPT_TOKENS="${2:?}"; shift 2 ;;
        --keep-up) KEEP_UP=1; shift ;;
        --no-drain) NO_DRAIN=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

NODE_ROOT="${DEPLOY_DEST:-/root/kv-cache}"
# L1 is deliberately small. Not to force eviction — the reader restart does
# that job properly — but because LMCACHE_MAX_LOCAL_CPU_SIZE is PER TP WORKER
# and the tracked default of 80 has taken a node down before (invariant 9).
L1_GB="${ACCEPT_L1_GB:-4}"
NONCE="acc-$(date +%s)-$$"
PASS=0; FAIL=0

_ssh() {
    local role="$1"; shift
    local host user pass
    case "${role}" in
        prefill) host="${PREFILL_HOST}"; user="${PREFILL_USER:-root}"; pass="${PREFILL_PASS}" ;;
        decode)  host="${DECODE_HOST}";  user="${DECODE_USER:-root}";  pass="${DECODE_PASS}" ;;
    esac
    SSHPASS="${pass}" sshpass -e ssh -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o PubkeyAuthentication=no \
        -o PreferredAuthentications=keyboard-interactive,password \
        "${user}@${host}" "$@"
}
_in() { local role="$1"; shift; _ssh "${role}" "cd ${NODE_ROOT} && ./scripts/common/container.sh exec ${role} \"$*\""; }

check() {
    local label="$1" cond="$2" detail="${3:-}"
    if [ "${cond}" = "1" ]; then ok "${label} ${detail}"; PASS=$((PASS+1));
    else warn "${label} FAILED ${detail}"; FAIL=$((FAIL+1)); fi
}

# l2stat <role> <counter> — read one L2 adapter counter from the daemon's
# HTTP status. The adapter's report_status() is the only place these exist;
# the plugin's own m_* metrics do NOT cover lookups at all.
l2stat() {
    _in "$1" "curl -s --max-time 5 http://127.0.0.1:8080/status" 2>/dev/null \
      | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('ERR'); raise SystemExit
a=d['storage_manager']['l2_adapters'][0]
print(a.get('$2','ERR'))"
}

# engine_gen <role> <port> — POST to the role's OWN engine, not the proxy
# (masker 2). Greedy, seeded, so two runs of the same prompt on the same
# weights must produce identical tokens.
#
# Takes TWO arguments. It used to declare a third (`prompt`) that it never
# read — the prompt is staged on the node at /tmp/acc_prompt.txt in step 0
# and opened inside the heredoc below — while every call site passed two.
# Under `set -u` that made the FIRST generation of the run die on
# "$3: unbound variable", after both models had already loaded (~5 min in).
# The stale parameter is removed rather than the call sites changed: the
# file on the node is the real interface.
# stage_prompt <role> <label> — write the prompt INSIDE the role's container.
#
# Two traps, both of which silently produced a FileNotFoundError five
# minutes into a run (after both models had loaded):
#   1. It must be staged with `_in` (container exec), not `_ssh` (host). The
#      container does not share the host's /tmp, and engine_gen reads the
#      file from INSIDE the container. Staging on the host writes a file
#      nothing ever reads.
#   2. It must be staged AFTER the role is up, and re-staged after every
#      role_down/role_up pair — role_down REMOVES the container (TODO 6.32
#      #1), which destroys its /tmp along with it. Anything staged before
#      the cold-start sequence is gone by the time it is needed.
# Hence this is a function called at each point of use, rather than a
# one-time step-0 setup.
stage_prompt() {
    local role="$1" label="$2"
    _in "${role}" "python3 - <<'PYEOF'
seed = '${label} '
body = ('The quick brown fox jumps over the lazy dog. ' * 400)
open('/tmp/acc_prompt.txt','w').write(seed + body[:${PROMPT_TOKENS}*4])
PYEOF"
}

# adapter_name_log <role> <"FIRST COMMIT WRITE"|"FIRST DEVICE PROBE"> —
# pull the adapter's one-shot commit-name log line out of the MP daemon's
# log INSIDE the role's container.
#
# Timing is the whole point: role_down REMOVES the container, and the
# daemon's log goes with it. The writer's name must therefore be harvested
# in step 2, BEFORE step 3 tears the writer down — by the end of the run
# both logs are gone. Harvesting late is the same as not instrumenting at
# all, which is the mistake this rung already made once (TODO 6.28).
adapter_name_log() {
    local role="$1" marker="$2"
    _in "${role}" "grep -m1 '${marker}' /var/log/kvstack/lmcache-mp-daemon.log" \
        2>/dev/null | sed "s/.*${marker}//" | tr -d '\r' | head -1
}

engine_gen() {
    local role="$1" port="$2"
    _in "${role}" "python3 - <<'PYEOF'
import json, urllib.request
prompt = open('/tmp/acc_prompt.txt').read()
body = json.dumps({'model': '${MODEL}', 'prompt': prompt, 'max_tokens': 24,
                   'temperature': 0.0, 'seed': 12345}).encode()
req = urllib.request.Request('http://127.0.0.1:${port}/v1/completions', body,
                             {'Content-Type': 'application/json'})
r = json.load(urllib.request.urlopen(req, timeout=300))
print('TOKENS:' + json.dumps(r['choices'][0]['text']))
PYEOF"
}

step "nixl_kv L2 cross-node acceptance"
info "nonce=${NONCE}  prompt≈${PROMPT_TOKENS} tokens  L1=${L1_GB} GiB"
warn "This rung STOPS and RESTARTS vLLM on both nodes. Check 'uptime' first" \
     " — both nodes have rebooted mid-run before (TODO 6.20)."

# ── Step 0: drain the namespace ───────────────────────────────────────────
# NOTE: nuse is NOT a usable progress signal on this device — measured
# 2026-09-17, it stayed 0x0 after 256+ pages were written. Use the adapter's
# l2_commit_writes counter instead (steps 2 and 5 below do exactly that;
# nothing in this script asserts on nuse).
step "0. draining the KV namespace"
# FATAL, not a warning (TODO 6.32 #3): a stale namespace can turn a real
# MISS into a spurious HIT — i.e. it can manufacture a false PASS of the
# very claim this rung exists to prove (step 5's l2_device_hits assertion).
# Continuing past a failed drain would make every check below unattributable.
#
# --no-drain exists because `50-reset-namespace.sh` RESTARTS `nvmf_tgt` on
# the target, and that target is SHARED (TODO 6.18, HANDOFF §3.2.2): when
# another party's subsystem is live on it, their namespace is RAM-backed
# too, so draining ours destroys theirs. "Agree ownership first" is not
# satisfiable from inside a script, so the script must be able to run
# without it rather than tempt an operator into reclaiming the target
# unilaterally.
#
# What is lost, stated honestly: the drain is DEFENCE IN DEPTH, not the
# soundness argument. Soundness comes from the per-run nonce below — the
# prompt, and therefore its chunk hashes and ObjectKeys, are unique to THIS
# run, so no object a previous run left behind can satisfy it. A stale
# namespace cannot manufacture a hit for content never written before.
# Step 6's "unseen nonce must MISS" negative control independently guards
# the "everything looks like a hit" failure mode. Use --no-drain when, and
# only when, you do not own the target.
if [ "${NO_DRAIN}" = "1" ]; then
    warn "--no-drain: SKIPPING the namespace drain. Soundness now rests on" \
         " the per-run nonce (content unique to this run) and step 6's" \
         " negative control, NOT on a clean namespace. Correct when the" \
         " target is shared (TODO 6.18); do not make it the default."
else
    scripts/target/50-reset-namespace.sh >/dev/null 2>&1 || \
        die "50-reset-namespace.sh failed or is unavailable — refusing to" \
            " continue with a possibly-stale namespace. Fix the drain (or the" \
            " target-node ssh path it depends on) before re-running this rung." \
            " If the target is shared and not yours to restart, re-run with" \
            " --no-drain and read the comment above this line first."
fi

# A per-run nonce in the prompt makes the content unique to THIS run, so a
# hit cannot come from anything a previous run left behind. The prompt is
# NOT staged here: the containers do not exist yet, and the cold-start
# sequence below would destroy anything staged into them anyway. See
# stage_prompt() — it is called at each point of use instead.
info "prompt content is nonce-bound (nonce=${NONCE}); staged per-role" \
     " after each bring-up by stage_prompt()"

# role_up <role> / role_down <role> — the whole point of this rung is that
# the reader is COLD, so start/stop has to be orchestrated here rather than
# left to the operator. Env is threaded through container.sh exec so the
# daemon comes up on nixl_kv with a sane L1 (invariant 9).
ROLE_ENV="LMCACHE_L2_ADAPTER_TYPE=nixl_kv LMCACHE_MAX_LOCAL_CPU_SIZE=${L1_GB}"

role_down() {
    local role="$1"
    # Orderly shutdown first, cheap and worth doing — let vLLM and the
    # daemon exit through their own pidfile-tracked stop path before the
    # container is recreated out from under them.
    _in "${role}" "./scripts/${role}/99-stop.sh" >/dev/null 2>&1 || true
    # DEFECT (TODO 6.32 #1): `pkill -f lmcache.v1.multiprocess.http_server`
    # was measured 2026-09-18 to leave the MP daemon running — SAME PID
    # before and after — while `pkill -f api_server` kills vLLM fine. That
    # asymmetry is the trap: a surviving daemon keeps L1 and the in-process
    # index WARM, which silently invalidates the entire cold-reader premise
    # this rung exists to establish (a real MISS would come back looking
    # like an unattributable hit). The only thing measured to actually work
    # is recreating the container outright.
    #
    # `container.sh down` is `docker rm -f ... >/dev/null && ok "removed"`,
    # so it returns non-zero when there is nothing to remove — that failure
    # IS the desired end state (no container == no daemon), so it is
    # tolerated here rather than treated as an error.
    _ssh "${role}" "cd ${NODE_ROOT} && ./scripts/common/container.sh down ${role}" \
        >/dev/null 2>&1 || true
    sleep 5
    # Don't trust the teardown — prove the daemon is gone rather than
    # assume it, the same discipline as step 3's "confirmed unreachable"
    # check below. Checked directly over ssh, NOT through container.sh
    # exec: there may be no container left to exec into, and --network
    # host means the daemon's :8080 is already the HOST's :8080, so a
    # plain curl from the control host is a real reachability test.
    if _ssh "${role}" "curl -s --max-time 5 http://127.0.0.1:8080/status" \
        >/dev/null 2>&1; then
        die "${role}: LMCache daemon on :8080 STILL answers after" \
            " container.sh down ${role} — the cold-reader premise of this" \
            " rung is not established; nothing measured past this point" \
            " would be attributable. Investigate before re-running."
    fi
}

role_up() {
    local role="$1" port="$2"
    # role_down now recreates the container (DEFECT 1), so role_up must
    # ensure it exists again before exec'ing into it — container.sh exec
    # dies immediately ("is not running") against a container that was
    # never created.
    _ssh "${role}" "cd ${NODE_ROOT} && ./scripts/common/container.sh up ${role}" \
        || die "${role}: container.sh up failed — cannot start the stack" \
               " inside a container that isn't there."
    # DEFECT (TODO 6.32 #2): this used to redirect the backgrounded start to
    # /dev/null, so a vLLM that started and then died presented as a silent
    # 600s timeout below — it cost a full diagnostic cycle. Capture the
    # output to a log an operator can read, on both the failure path and
    # (named in the `ok` line) the success path.
    local log="/tmp/60-acc-${role}-${NONCE}.log"
    : > "${log}"
    _in "${role}" "${ROLE_ENV} ./scripts/${role}/03-start-${role}.sh" >"${log}" 2>&1 &
    local waited=0
    until _in "${role}" "curl -s --max-time 3 http://127.0.0.1:${port}/health" >/dev/null 2>&1; do
        sleep 10; waited=$((waited+10))
        if [ "${waited}" -ge "${VLLM_BOOT_TIMEOUT:-600}" ]; then
            err "${role} did not become healthy on :${port} within ${waited}s" \
                " — last 40 lines of ${log}:"
            tail -n 40 "${log}" >&2 2>/dev/null || true
            die "${role} boot timed out (or died silently) after ${waited}s;" \
                " full log at ${log}"
        fi
    done
    # The engine answering /health is NOT the same as the daemon being
    # reachable; start-vllm.sh gates on the daemon, but re-assert it here so
    # a half-up stack fails as itself rather than as a cache miss.
    _in "${role}" "curl -s --max-time 5 http://127.0.0.1:8080/status" >/dev/null 2>&1 \
        || die "${role}: vLLM is healthy but the LMCache daemon's HTTP status" \
               " is unreachable — the L2 tier is not attached."
    ok "${role} up (vLLM :${port} + daemon :8080), ${waited}s — start log: ${log}"
}

step "bringing both roles up cold on nixl_kv"
role_down prefill; role_down decode
role_up prefill "${PREFILL_PORT}"
role_up decode  "${DECODE_PORT}"
stage_prompt prefill "Session ${NONCE}."
stage_prompt decode  "Session ${NONCE}."
ok "prompt staged inside both containers (nonce=${NONCE})"

# ── Step 1: BASELINE — reader recomputes with an empty namespace ──────────
step "1. baseline: reader recomputes (namespace drained)"
BASE_OUT="$(engine_gen decode "${DECODE_PORT}" || true)"
BASE_TOKENS="$(echo "${BASE_OUT}" | grep '^TOKENS:' | head -1 | cut -d: -f2-)"
check "baseline produced output" "$([ -n "${BASE_TOKENS}" ] && echo 1 || echo 0)"
info "baseline tokens: ${BASE_TOKENS:0:80}..."

# ── Step 2: writer stores ─────────────────────────────────────────────────
step "2. writer (prefill) computes and stores to L2"
engine_gen prefill "${PREFILL_PORT}" >/dev/null 2>&1 || true
COMMITS="$(l2stat prefill l2_commit_writes)"
check "writer committed groups to L2" \
    "$([ "${COMMITS}" != "0" ] && [ "${COMMITS}" != "ERR" ] && echo 1 || echo 0)" \
    "(l2_commit_writes=${COMMITS})"
# Harvest the writer's first commit name NOW — step 3 destroys the
# container and its daemon log a few lines below.
WRITER_NAME="$(adapter_name_log prefill 'FIRST COMMIT WRITE' || true)"
info "writer first commit name:${WRITER_NAME:- (not found in daemon log)}"

# ── Step 3: kill the writer entirely ──────────────────────────────────────
step "3. killing writer's vLLM AND daemon (excludes the P->D leg)"
role_down prefill
# role_down now recreates the container (DEFECT 1), so there may be no
# container left to exec into — check the vLLM port directly over ssh
# (--network host makes 127.0.0.1:${PREFILL_PORT} the HOST's port), the
# same reasoning as role_down's own daemon-unreachable check above.
if _ssh prefill "curl -s --max-time 3 http://127.0.0.1:${PREFILL_PORT}/health" \
    >/dev/null 2>&1; then
    die "writer's vLLM is STILL answering after teardown — the P->D leg" \
        " is not excluded and any hit below would be unattributable."
fi
ok "writer down and confirmed unreachable (container removed; port" \
   " ${PREFILL_PORT} and daemon :8080 both unreachable)"

# ── Step 4: restart the reader (empties prefix cache + L1 + index) ────────
step "4. restarting reader's vLLM + daemon (excludes prefix cache and L1)"
role_down decode
role_up decode "${DECODE_PORT}"
# Re-stage: role_down removed the container, taking /tmp with it.
stage_prompt decode "Session ${NONCE}."
# Prove the restart actually reset the tier, rather than trusting it.
_RESET_IDX="$(l2stat decode l2_index_hits)"
_RESET_DEV="$(l2stat decode l2_device_hits)"
check "reader restarted with counters at zero" \
    "$([ "${_RESET_IDX}" = "0" ] && [ "${_RESET_DEV}" = "0" ] && echo 1 || echo 0)" \
    "(index=${_RESET_IDX} device=${_RESET_DEV})"

# ── Step 5: the assertions ────────────────────────────────────────────────
step "5. cold reader serves the writer's chunks"
TEST_OUT="$(engine_gen decode "${DECODE_PORT}" || true)"
TEST_TOKENS="$(echo "${TEST_OUT}" | grep '^TOKENS:' | head -1 | cut -d: -f2-)"
DEV_HITS="$(l2stat decode l2_device_hits)"
IDX_HITS="$(l2stat decode l2_index_hits)"
# Attempt counters (TODO 6.28's blocking sub-task, already in the adapter —
# see overlays/lmcache/nixl_kv_l2_adapter.py's __init__ for how to read the
# combination). Read alongside the outcome counters above so a FAILING run
# is self-diagnosing instead of costing another full diagnostic cycle, as
# 6.28's own run did.
LOOKUP_CALLS="$(l2stat decode l2_lookup_calls)"
LOOKUP_KEYS="$(l2stat decode l2_lookup_keys)"
LOOKUP_EXECS="$(l2stat decode l2_lookup_executions)"
KEYS_PROBED="$(l2stat decode l2_keys_probed)"
PROBE_MISSES="$(l2stat decode l2_probe_misses)"
PROBE_ERR="$(l2stat decode l2_probe_errors)"
ABORTS="$(l2stat decode l2_load_aborts)"

check "l2_device_hits > 0 (served a key this daemon NEVER stored)" \
    "$([ "${DEV_HITS}" != "0" ] && [ "${DEV_HITS}" != "ERR" ] && echo 1 || echo 0)" \
    "(=${DEV_HITS})"

if [ "${DEV_HITS}" = "0" ] || [ "${DEV_HITS}" = "ERR" ]; then
    # Unconditional on failure — this is the exact undiagnosable state
    # TODO 6.28's 2026-09-18 run left behind (l2_device_hits=0 with no way
    # to tell "lookup ran, names didn't match" from "lookup never ran").
    warn "l2_device_hits==0 — self-diagnosing via the attempt counters" \
         " rather than starting another cycle:"
    info "  reader: l2_lookup_calls=${LOOKUP_CALLS}" \
         " l2_lookup_keys=${LOOKUP_KEYS}" \
         " l2_lookup_executions=${LOOKUP_EXECS}" \
         " l2_keys_probed=${KEYS_PROBED} l2_probe_misses=${PROBE_MISSES}"
    info "  writer: l2_commit_writes=${COMMITS} (from step 2, before its" \
         " container was torn down in step 3)"
    if [ "${LOOKUP_CALLS}" = "0" ] || [ "${LOOKUP_CALLS}" = "ERR" ]; then
        warn "  l2_lookup_calls==0 -> LMCache never called the adapter's" \
             " lookup at all. The fault is in the LMCache->adapter seam," \
             " ABOVE this adapter — do not spend more time in this file."
    elif [ "${LOOKUP_EXECS}" = "0" ]; then
        warn "  l2_lookup_calls>0 but l2_lookup_executions==0 -> the" \
             " adapter's asyncio event loop never ran the lookup" \
             " coroutine (wedged or dead loop)."
    elif [ "${KEYS_PROBED}" = "0" ]; then
        warn "  l2_keys_probed==0 with l2_lookup_calls>0 -> every key" \
             " short-circuited on the in-process index; the device was" \
             " never asked."
    fi
    if [ "${PROBE_MISSES}" != "0" ] && [ "${PROBE_MISSES}" != "ERR" ]; then
        warn "  l2_probe_misses=${PROBE_MISSES} -> we DID probe and the" \
             " device said absent: a naming / key-derivation divergence" \
             " between writer and reader, not a plumbing problem."
        # The comparison itself, rather than an instruction to go and make
        # it by hand. The writer's name was harvested in step 2 (its
        # container is already gone); the reader's is still live here.
        READER_NAME="$(adapter_name_log decode 'FIRST DEVICE PROBE' || true)"
        info "  writer wrote :${WRITER_NAME:- (unavailable)}"
        info "  reader probed:${READER_NAME:- (unavailable)}"
        if [ -n "${WRITER_NAME}" ] && [ -n "${READER_NAME}" ]; then
            # Compare only the commit-name field, not the whole log line
            # (batch sizes legitimately differ between the two roles).
            _wn="$(printf '%s' "${WRITER_NAME}" | grep -o 'first_commit_name=[^ ]*' || true)"
            _rn="$(printf '%s' "${READER_NAME}" | grep -o 'first_commit_name=[^ ]*' || true)"
            if [ -n "${_wn}" ] && [ "${_wn}" = "${_rn}" ]; then
                warn "  names AGREE (${_wn}) — so the divergence is NOT in" \
                     " the first key. Suspect ordering/coverage: the reader" \
                     " may be probing a different SUBSET than the writer" \
                     " stored, or the writer never committed this key."
            else
                warn "  names DIFFER — this is the root cause. Diff the two" \
                     " ObjectKey fields: ns, model_name, worker/kv_rank," \
                     " object_group_id, chunk_hash, cache_salt. ns is the" \
                     " geometry fingerprint; a kv_rank/object_group_id" \
                     " mismatch is the leading hypothesis (TODO 6.28), the" \
                     " roles differing as kv_producer vs kv_consumer."
            fi
        fi
    fi
fi

check "l2_index_hits == 0 (not served from its own in-process index)" \
    "$([ "${IDX_HITS}" = "0" ] && echo 1 || echo 0)" "(=${IDX_HITS})"
check "l2_probe_errors == 0" "$([ "${PROBE_ERR}" = "0" ] && echo 1 || echo 0)" "(=${PROBE_ERR})"
check "l2_load_aborts == 0"  "$([ "${ABORTS}" = "0" ] && echo 1 || echo 0)" "(=${ABORTS})"
check "TOKEN IDENTITY vs recompute baseline" \
    "$([ "${TEST_TOKENS}" = "${BASE_TOKENS}" ] && echo 1 || echo 0)"
[ "${TEST_TOKENS}" = "${BASE_TOKENS}" ] || {
    warn "  baseline: ${BASE_TOKENS}"
    warn "  with L2 : ${TEST_TOKENS}"
    warn "  A MISMATCH HERE MEANS THE CACHE RETURNED WRONG BYTES — this is the"
    warn "  page-collapse signature and no other check in this script catches it."
}

# ── Step 6: negative control A — a nonce nobody ever prefilled ───────────
# Without this, "everything is a hit" passes step 5.
step "6. negative control A: unseen nonce must MISS"
_DEV_BEFORE="$(l2stat decode l2_device_hits)"
stage_prompt decode "Session ${NONCE}-UNSEEN."
engine_gen decode "${DECODE_PORT}" >/dev/null 2>&1 || true
_DEV_AFTER="$(l2stat decode l2_device_hits)"
check "unseen nonce did NOT produce a device hit" \
    "$([ "${_DEV_AFTER}" = "${_DEV_BEFORE}" ] && echo 1 || echo 0)" \
    "(device_hits ${_DEV_BEFORE} -> ${_DEV_AFTER})"

# ── Step 7: negative control B — drain, then the CORRECT nonce must miss ──
# Proves the step-5 hit came from the DEVICE and nowhere else. HANDOFF §7.6's
# lesson, applied in reverse: an instrument reading non-zero is not evidence
# until you have shown it can read zero on the same input.
step "7. negative control B: drained namespace, correct nonce, must MISS"
# Not fatal like step 0: unlike the main assertion (step 5), a stale
# namespace here cannot manufacture a false PASS — if step 2's commit
# object survives the drain, "no device hit" below reports it as a
# FAILURE, not a silent pass. But that failure would be about a dirty
# drain, not about the property this control is meant to test, so say so
# rather than calling it merely "inconclusive".
scripts/target/50-reset-namespace.sh >/dev/null 2>&1 || \
    warn "drain failed — this negative control is VOID. Any FAIL below may" \
         " just mean step 2's commit object is still on the device, not" \
         " that the L2 tier failed to exclude a drained key."
role_down decode; role_up decode "${DECODE_PORT}"
stage_prompt decode "Session ${NONCE}."
DRAIN_OUT="$(engine_gen decode "${DECODE_PORT}" || true)"
DRAIN_TOKENS="$(echo "${DRAIN_OUT}" | grep '^TOKENS:' | head -1 | cut -d: -f2-)"
_DEV_DRAINED="$(l2stat decode l2_device_hits)"
check "drained namespace yields NO device hit" \
    "$([ "${_DEV_DRAINED}" = "0" ] && echo 1 || echo 0)" "(=${_DEV_DRAINED})"
check "recompute after drain still matches baseline" \
    "$([ "${DRAIN_TOKENS}" = "${BASE_TOKENS}" ] && echo 1 || echo 0)"

[ "${KEEP_UP}" = "1" ] || { role_down prefill; role_down decode; }

echo
if [ "${FAIL}" -eq 0 ]; then
    ok "L2 cross-node acceptance: ${PASS}/${PASS} passed"
    exit 0
fi
die "L2 cross-node acceptance: ${FAIL} of $((PASS+FAIL)) checks FAILED"
