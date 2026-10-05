#!/usr/bin/env bash
# kv_path_bench.sh — measure the KV RETRIEVE path's effective bandwidth.
#
#   kv_path_bench.sh <container> <port> <model> <label> [nreq] [prompt_tokens]
#
# WHY THIS EXISTS, AND WHY IT IS NOT pd_bench.py.
#
# Every KV-path bandwidth number on this branch before 2026-09-10 was derived by
# SUBTRACTION: time a long-prompt request, time a short-prompt "decode probe",
# subtract, divide the KV bytes by the difference. That is what produced OPEN-2's
# 617 MB/s. pd_bench.py --kvpath automates the same method.
#
# The method is fragile, and on this rig it visibly failed: the decode probe's
# own latency spread was 182% (1.42 s to 16.29 s across five samples), so the
# floor being subtracted was worth less than the thing being measured. It
# reported 140 MB/s for a path that was in fact running at 476 MB/s.
#
# LMCache logs the number DIRECTLY, per request, from inside the retrieve path,
# with no decode in it at all:
#
#   Retrieved 10688 out of 10688 required tokens (from 10688 total tokens).
#   size: 1.4678 gb, cost 3085.1074 ms, throughput: 0.4758 GB/s;
#
# That is exactly the quantity OPEN-3 exists to move, measured at the right
# boundary. This script drives traffic that forces the retrieve path and scrapes
# it. Prefer it over the subtraction for anything where the number matters.
#
# It still prints the hit / need-to-load lines, because the standing failure
# mode is unchanged: a throughput line only means something if the request that
# produced it actually hit the cache, and a run with NO retrieval lines at all
# is a silent cache MISS, not a fast path.
set -u

C=${1:?container}; PORT=${2:?port}; MODEL=${3:?model}; LABEL=${4:?label}
N=${5:-5}; PT=${6:-8192}
LINK_MBPS=${LINK_MBPS:-3125}          # 25 Gb/s. Check with: ethtool <iface>

docker logs "$C" >/dev/null 2>&1 || { echo "ERR: no container '$C'" >&2; exit 1; }
BEFORE=$(docker logs "$C" 2>&1 | wc -l)

cd "$(dirname "$0")"

# One warmup request populates the cache (that one is the STORE), then N
# requests share its prefix and must all be LOADS. build_prompt/one_request are
# imported from pd_bench.py rather than reimplemented, so the prompt shape is
# identical to the one every other measurement on this branch used.
python3 - "$PORT" "$MODEL" "$N" "$PT" <<'PY'
import sys, time, urllib.request
port, model, n, pt = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
sys.path.insert(0, '.')
from pd_bench import build_prompt, one_request
# Fresh prefix key per invocation: the backend is persistent, so a fixed key
# would let a previous run's entry turn this run's warmup from a store into a
# no-op hit. HANDOFF "Benchmarking" trap #2.
key = int(time.time()) % 1000000
url = f"http://127.0.0.1:{port}"
one_request(url, model, build_prompt(key, pt, key), 8, 1800)          # the STORE
for i in range(n):
    dt, ptok, _ = one_request(url, model, build_prompt(key + 1 + i, pt, key), 8, 1800)
    print(f"  req{i}  wall={dt:.2f}s  prompt_tokens={ptok}")
PY

NEW=$(docker logs "$C" 2>&1 | tail -n +$((BEFORE + 1)))

echo "--- hit / need-to-load (${LABEL}) ---"
echo "$NEW" | grep -oE 'LMCache hit tokens: [0-9]+, need to load: [0-9]+' || \
    echo "  NONE — no LMCache accounting lines at all; this run measured nothing."

echo "--- LMCache-reported retrievals (${LABEL}) ---"
echo "$NEW" | grep -oE 'size: [0-9.]+ gb, cost [0-9.]+ ms, throughput: [0-9.]+ GB/s' \
    | tee "/tmp/kv_path_bench-${LABEL}.txt"

echo "--- summary (${LABEL}) ---"
awk -v link="$LINK_MBPS" -v label="$LABEL" '
    { for (i = 1; i <= NF; i++) {
        if ($i == "size:")       gb = $(i+1)
        if ($i == "cost")        ms = $(i+1)
        if ($i == "throughput:") bw = $(i+1)
      }
      n++; GB[n] = gb; MS[n] = ms; BW[n] = bw
    }
    END {
      if (n == 0) {
        print "  NO RETRIEVALS LOGGED — the requests did not hit the cache."
        print "  That is a cache MISS, not a measurement. Check need-to-load above."
        exit 1
      }
      # sort cost and bandwidth INDEPENDENTLY so min/med/max mean what they say
      # on each row; they are the same five samples either way.
      for (i = 1; i <= n; i++) for (j = i+1; j <= n; j++) {
        if (MS[j] < MS[i]) { t = MS[i]; MS[i] = MS[j]; MS[j] = t }
        if (BW[j] < BW[i]) { t = BW[i]; BW[i] = BW[j]; BW[j] = t }
      }
      m = int((n + 1) / 2)
      printf "  n=%d   size=%s GB\n", n, GB[1]
      printf "  cost_ms   min=%.1f  med=%.1f  max=%.1f\n", MS[1], MS[m], MS[n]
      printf "  MB/s      min=%.0f  med=%.0f  max=%.0f\n", BW[1]*1000, BW[m]*1000, BW[n]*1000
      printf "  => median %.0f MB/s of a %d MB/s link = %.1f%% of line rate\n",
             BW[m]*1000, link, BW[m]*1000 / link * 100
    }' "/tmp/kv_path_bench-${LABEL}.txt"
