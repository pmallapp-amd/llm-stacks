#!/usr/bin/env bash
# Reduced-depth llama-benchy sweep against the live proxy, run from a
# control host (no GPU/NIXL needed — llama-benchy is a pure HTTP client).
#
# Deliberately NOT --quick: that flag overrides BENCHY_DEPTH with its own
# single-shape values and stamps the result non-reportable. This keeps
# --runs 3 (enough for a std) and two depths for a real cold/warm delta.
#
# Prereqs: a venv with llama-benchy at ${VENV} (see the venv note below).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

LOCAL_ROOT="${LOCAL_ROOT:-$HOME/kvstack-local}"

# WHY a derived creds file: creds/setup-4.env assigns HF_HOME unconditionally
# (HF_HOME=/root/.cache/huggingface, not HF_HOME="${HF_HOME:-...}"), so merely
# exporting HF_HOME before sourcing it is NOT enough — cluster.env sources the
# creds file and the plain assignment clobbers the export. An unreadable
# HF_HOME makes llama-benchy stall on the HF Hub instead of failing fast.
# Regenerated here rather than tracked, so no extra copy of the node passwords
# is created until someone actually runs the benchmark. Delete it when done.
if [ ! -f creds/bench-local.env ]; then
    sed "s#^HF_HOME=.*#HF_HOME=${LOCAL_ROOT}/hf-cache#" creds/setup-4.env > creds/bench-local.env
    chmod 600 creds/bench-local.env
    echo "generated creds/bench-local.env (HF_HOME -> ${LOCAL_ROOT}/hf-cache)"
fi

export CREDS_FILE="$(pwd)/creds/bench-local.env"
export VENV="${VENV:-${LOCAL_ROOT}/venv}"
export LOG_DIR="${LOCAL_ROOT}/logs"
export RUN_DIR="${LOCAL_ROOT}/run"
export BENCHY_RESULT_DIR="${LOCAL_ROOT}/bench"
export HF_HOME="${LOCAL_ROOT}/hf-cache"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${BENCHY_RESULT_DIR}" "${HF_HOME}"

export BENCHY_PP="512 1024"
export BENCHY_TG="128"
export BENCHY_DEPTH="0 4096"
export BENCHY_CONCURRENCY="1 2 4"
export BENCHY_RUNS="3"
export BENCHY_WARMUP_RUNS="1"

# NOTE: the headline `--prefix-benefit` table this prints is NOT a cache
# result — it pairs depth=0 against depth>0, i.e. two different workloads.
# See docs/KNOWN-ISSUES.md item 17 and TODO 1.13.
bash scripts/bench/run-all.sh
