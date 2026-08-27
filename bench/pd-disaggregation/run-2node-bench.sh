#!/usr/bin/env bash
# 2-node P/D serving sweep against the cross-host proxy.
# Trimmed from the full throughput profile (DEPTH 0/4096, CONCURRENCY 1/16) to keep
# a 72B run to a sane wall clock; explicit env wins over the profile, and the
# provenance stamp records the resolved values.
set -uo pipefail
cd /opt/rixl-bench
PROFILE=throughput \
BASE_URL=http://127.0.0.1:9000/v1 \
AUTO_DEPLOY=0 \
MODEL=Qwen/Qwen2.5-72B-Instruct \
DEPTH="0 4096" \
PP="512 1024" \
CONCURRENCY="1 16" \
RESULTS=/opt/rixl-bench/results/setup3-prefill-node/2026-08-17-llama-benchy-2node-pd \
bash bench/llama-benchy/run.sh
echo "BENCH_EXIT=$?"
