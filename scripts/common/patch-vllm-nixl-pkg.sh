#!/usr/bin/env bash
# patch-vllm-nixl-pkg.sh — make vLLM resolve NIXL to the `nixl` package on ROCm
# instead of demanding a separate `rixl` package.
#
# Node:          SMC1 (prefill) / SMC2 (decode) — any host that launches a vLLM
#                container. Needs docker and the image present locally.
# Prerequisites: none beyond the image.
# Next step:     the emitted file is bind-mounted over vLLM's own nixl_utils.py
#                by scripts/{prefill,decode}/03-start-*.sh.
#
# WHY THIS EXISTS
# vLLM picks the NIXL python package by platform, not by what is installed:
#
#     package_name = "rixl" if current_platform.is_rocm() else "nixl"
#
# On ROCm that is a hard dependency on a package called `rixl`. The rocm-aic
# images carry `nixl` built WITH the ROCm patches — it is the ROCm-correct
# build, it exposes the same `_api`/`_bindings` surface, and this repo has
# already driven XNVME_KV through it end to end (a cross-process KV
# store/retrieve, 2026-09-15). Only two of the six rocm-aic tags additionally
# ship `rixl`, and on this cluster those two exist on the decode host only. So
# the platform check, not the stack, is what made prefill unable to start:
#
#     Worker failed with error 'NIXL is not available'
#
# and both engines exited 1 AFTER loading weights, which is a slow and
# confusing way to discover a missing import.
#
# WHY IT PATCHES AT LAUNCH RATHER THAN VENDORING A COPY
# nixl_utils.py belongs to vLLM and changes between versions. A copy committed
# here would silently go stale and start overwriting a newer file with an older
# one — a worse failure than the one it fixes, because it would look like it
# worked. Instead the file is extracted from whatever image is actually being
# launched, rewritten, and verified. If upstream changes the shape of those two
# lines this script FAILS rather than emitting a file that no longer patches
# anything.
#
# WHY NOT A `rixl` SHIM PACKAGE
# A shim directory named `rixl` that re-exports `nixl` would also work and would
# need no knowledge of vLLM internals. It was not chosen because it keeps the
# name alive: anyone debugging later would find a `rixl` on the path, go looking
# for the package it implies, and find a decoy. Removing the lookup says what is
# actually true — there is one NIXL package here and it is `nixl`.
#
# usage: patch-vllm-nixl-pkg.sh <image> [outdir]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMG="${1:?usage: patch-vllm-nixl-pkg.sh <image> [outdir]}"
OUTDIR="${2:-/opt/kvstack/vllm-patch}"
SRC_PATH="/usr/local/lib/python3.12/dist-packages/vllm/distributed/nixl_utils.py"

require_cmd docker
mkdir -p "${OUTDIR}"
OUT="${OUTDIR}/nixl_utils.py"

step "Patching vLLM NIXL package selection out of ${IMG}"

# Locate the file rather than trusting the hardcoded path — the dist-packages
# python version moves between image builds.
_found="$(docker run --rm --entrypoint bash "${IMG}" -c \
    'find /usr/local/lib/python3*/dist-packages/vllm -name nixl_utils.py 2>/dev/null | head -1' \
    | tr -d '\r')"
[ -n "${_found}" ] || die "no nixl_utils.py found inside ${IMG}. Either this is" \
    " not a vLLM image, or vLLM has moved/renamed the module — in which case" \
    " the package-selection patch below needs rewriting, not retrying."
[ "${_found}" = "${SRC_PATH}" ] || \
    warn "nixl_utils.py is at ${_found}, not the expected ${SRC_PATH}." \
         " Using the discovered path; update SRC_PATH if this is now permanent."
log "source: ${_found}"

docker run --rm --entrypoint cat "${IMG}" "${_found}" > "${OUT}"
[ -s "${OUT}" ] || die "extracted an empty nixl_utils.py from ${IMG}"

# Both call sites choose the package the same way. Count them BEFORE editing so
# a silent no-op is impossible: this is the whole point of the script, and an
# unpatched file that still says "rixl" would fail exactly the way it does now,
# only later and with a launch script that claims to have fixed it.
_before="$(grep -c '"rixl" if current_platform.is_rocm() else "nixl"' "${OUT}" || true)"
if [ "${_before}" -eq 0 ]; then
    if grep -q 'rixl' "${OUT}"; then
        die "nixl_utils.py still mentions rixl but not in the expected form." \
            " vLLM changed how it selects the package; read the file and" \
            " rewrite this patch deliberately rather than loosening the match."
    fi
    ok "no rixl selection present — image already resolves NIXL as 'nixl', nothing to patch"
    printf '%s\n' "${OUT}"
    exit 0
fi
log "found ${_before} rixl package-selection site(s)"

# Prefer `nixl`, fall back to `rixl` only if nixl is genuinely absent. This
# removes the hard dependency without breaking an image that ships only rixl.
python3 - "$@" <<PYEOF
import io, re, sys
p = "${OUT}"
s = io.open(p, encoding="utf-8").read()
old = '"rixl" if current_platform.is_rocm() else "nixl"'
new = ('(_kvstack_nixl_pkg())')
s = s.replace(old, new)
helper = '''

def _kvstack_nixl_pkg() -> str:
    """Return the installed NIXL package name.

    Patched in by scripts/common/patch-vllm-nixl-pkg.sh. Upstream hardcodes
    "rixl" on ROCm, but the rocm-aic images ship a ROCm-patched "nixl" and no
    "rixl" at all, so the platform test rejects a working install. Probe
    instead: prefer nixl, fall back to rixl, and if neither is importable
    return "nixl" so the caller's own ImportError path reports it.
    """
    import importlib.util
    for _pkg in ("nixl", "rixl"):
        try:
            if importlib.util.find_spec(_pkg) is not None:
                return _pkg
        except (ImportError, ValueError):
            continue
    return "nixl"

'''
# Insert the helper after the logger line so it is defined before first use.
anchor = "logger = init_logger(__name__)"
if anchor not in s:
    sys.exit("anchor %r not found in nixl_utils.py" % anchor)
s = s.replace(anchor, anchor + "\n" + helper, 1)
io.open(p, "w", encoding="utf-8").write(s)
PYEOF

# Verify the result rather than assuming the rewrite landed.
_after="$(grep -c '"rixl" if current_platform.is_rocm() else "nixl"' "${OUT}" || true)"
[ "${_after}" -eq 0 ] || die "patch did not take: ${_after} rixl selection(s) remain in ${OUT}"
grep -q '_kvstack_nixl_pkg' "${OUT}" || die "helper not inserted into ${OUT}"
python3 -m py_compile "${OUT}" || die "patched nixl_utils.py does not compile"

ok "patched ${_before} site(s); ${OUT} compiles"
printf '%s\n' "${OUT}"
