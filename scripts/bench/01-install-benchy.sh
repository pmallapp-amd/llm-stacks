#!/usr/bin/env bash
# 01-install-benchy.sh — install llama-benchy into the shared vLLM venv.
#
# Node:          anywhere with network reach to the deployment under test
#                (does not need to be SMC1/SMC2/SMC3; commonly a jump host
#                or an operator laptop, since llama-benchy is a pure HTTP
#                client with no GPU/NIXL/SPDK dependency of its own).
# Prerequisites: scripts/common/20-build-vllm-lmcache.sh has already run ON
#                THIS HOST and produced ${VENV} — this script does NOT
#                create the venv itself. It installs INTO an existing one
#                so llama-benchy shares the same python/transformers stack
#                already validated by that script (avoids a second,
#                divergent transformers/tokenizers pin fighting the first).
# Next step:     scripts/bench/10-bench-baseline.sh (or run-all.sh).
#
# usage: 01-install-benchy.sh [--upgrade] [--from-git]
#   --upgrade    force reinstall even if the pinned version already matches
#   --from-git   install `git+https://github.com/eugr/llama-benchy` instead
#                of the pinned PyPI release (for testing an unreleased fix)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

UPGRADE=0
FROM_GIT=0
for arg in "$@"; do
    case "${arg}" in
        --upgrade) UPGRADE=1 ;;
        --from-git) FROM_GIT=1 ;;
        *) die "unknown argument: ${arg} (expected --upgrade, --from-git)" ;;
    esac
done

step "Installing llama-benchy ${BENCHY_VERSION} into ${VENV}"

if [ ! -x "${VENV}/bin/python" ]; then
    die "no venv at ${VENV} — run scripts/common/20-build-vllm-lmcache.sh" \
        " first. This script installs llama-benchy INTO that venv; it does" \
        " not create one, because llama-benchy needs to share the exact" \
        " transformers/tokenizers install already validated for vLLM +" \
        " LMCache, not a second independently-resolved copy."
fi

# shellcheck source=/dev/null
source "${VENV}/bin/activate"

PIP_ARGS=()
[ "${UPGRADE}" -eq 1 ] && PIP_ARGS+=(--upgrade)

if [ "${FROM_GIT}" -eq 1 ]; then
    info "installing from git (unreleased): git+https://github.com/eugr/llama-benchy"
    python -m pip install "${PIP_ARGS[@]}" "git+https://github.com/eugr/llama-benchy"
else
    info "installing pinned release: llama-benchy==${BENCHY_VERSION}"
    python -m pip install "${PIP_ARGS[@]}" "llama-benchy==${BENCHY_VERSION}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Pre-download the tokenizer for MODEL, outside any timed run.
#
# WHY: llama-benchy accepts --tokenizer and otherwise resolves one itself
# via `transformers` to compute prompt/response token counts for --pp/--tg
# shaping. The FIRST time a given tokenizer is requested, transformers has
# to hit the HF Hub (or, worse, time out retrying if HF_TOKEN is wrong/
# missing for a gated repo) before it can even start the benchmark's first
# request. If that cold fetch happens to occur DURING a timed sweep — e.g.
# the very first invocation of scripts/bench/10-bench-baseline.sh, right
# when its warm-up requests should be measuring server behavior, not
# network-to-huggingface.co behavior — every latency number from that run
# is polluted by an unrelated, non-reproducible download. Doing it here,
# once, up front, with its own clear pass/fail, means every later `benchy_
# run` invocation is guaranteed to hit an already-warm local HF cache.
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-downloading tokenizer for ${MODEL} (HF_HOME=${HF_HOME})"
export HF_HOME
if [ -n "${HF_TOKEN}" ]; then
    export HF_TOKEN
fi
python - <<PYEOF
import os
from transformers import AutoTokenizer

model = os.environ["MODEL"]
tok = AutoTokenizer.from_pretrained(model, token=os.environ.get("HF_TOKEN") or None)
print(f"tokenizer OK: {type(tok).__name__} vocab_size={tok.vocab_size}")
PYEOF
ok "tokenizer cached under HF_HOME=${HF_HOME}"

step "Verifying llama-benchy CLI"
require_cmd python
# WHY a symlink step exists at all: inside the vendor container ${VENV} is
# a SHIM, not a virtualenv — container.sh's `shim` subcommand creates
# ${VENV}/bin/{python,python3} as symlinks to /usr/bin/python3 and an
# activate that is a deliberate no-op, because the rocm-aic image already
# carries vllm/lmcache/nixl on its SYSTEM interpreter. pip therefore
# installs console scripts to /usr/local/bin, and ${VENV}/bin/llama-benchy
# never appears. Measured 2026-09-18: ${VENV}/bin contained only
# activate, python, python3. Without this bridge both the check below and
# lib-bench.sh's `[ -x "${VENV}/bin/llama-benchy" ]` guard fail, on an
# install that actually succeeded.
if [ ! -x "${VENV}/bin/llama-benchy" ]; then
    _benchy_real="$(command -v llama-benchy 2>/dev/null || true)"
    if [ -n "${_benchy_real}" ]; then
        info "bridging ${_benchy_real} -> ${VENV}/bin/llama-benchy (container shim, not a venv)"
        ln -sfn "${_benchy_real}" "${VENV}/bin/llama-benchy"
    fi
fi
"${VENV}/bin/llama-benchy" --help >/dev/null || die "llama-benchy --help failed"

RESOLVED_VERSION="$(python -c 'import importlib.metadata as m; print(m.version("llama-benchy"))' 2>/dev/null || echo unknown)"
ok "llama-benchy installed and importable: version ${RESOLVED_VERSION}"

log "next: scripts/bench/10-bench-baseline.sh (or scripts/bench/run-all.sh)"
