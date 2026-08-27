#!/usr/bin/env bash
# 03-fix-hf-remote-code.sh — make trust_remote_code models loadable from an HF cache.
#
# THE BUG (hit 2026-08-21 loading moonshotai/Kimi-K2.5, transformers 4.x in
# rocm/atom-dev:vllm-latest):
#
#   FileNotFoundError: .../models--moonshotai--Kimi-K2.5/blobs/tool_declaration_ts.py
#
# The Hugging Face cache stores every file once under blobs/<sha> and exposes it
# through a symlink in snapshots/<rev>/<name>. For ordinary weights that is
# invisible. For trust_remote_code models it is not:
#
#   transformers/dynamic_module_utils.py
#     get_cached_module_file -> _compute_local_source_files_hash
#       -> get_relative_import_files(resolved_module_file)
#         -> get_relative_imports(f)  ->  open(module_file)
#
# `resolved_module_file` is the REAL path (blobs/<sha>), so when transformers
# walks the module's relative imports it looks for them next to that file — i.e.
# in blobs/, where everything is named by hash. `import tool_declaration_ts`
# therefore resolves to blobs/tool_declaration_ts.py, which cannot exist.
#
# It only bites models whose remote code imports its own sibling modules, which
# is why most trust_remote_code models are fine and Kimi-K2.5 is not.
#
# THE FIX: replace the .py symlinks in the snapshot with real copies, so the
# realpath of each module is inside the snapshot directory and its siblings sit
# next to it. Costs a few hundred KB. The blobs are left untouched, so nothing
# is lost and `hf download` will simply re-link on a future fetch.
#
# Idempotent: already-regular files are skipped.
#
# Usage:
#   bash 03-fix-hf-remote-code.sh [MODEL_DIR]
#     MODEL_DIR defaults to the Kimi-K2.5 cache dir under ${HF_CACHE:-/var/tmp/hf}.
#     Pass any models--*/ directory to repair a different model.
#
# NEEDS ROOT. A cache populated by a container is owned by root, so running this
# as an ordinary user fails with "Permission denied". Easiest route is to run it
# inside the image that already mounts the cache, rather than reaching for sudo:
#
#   docker run --rm -v /var/tmp/hf:/hf -v <repo>:/repo --entrypoint bash \
#     rocm/atom-dev:vllm-latest \
#     -c "HF_CACHE=/hf bash /repo/stack/tracks/atom/03-fix-hf-remote-code.sh"
set -euo pipefail

HF_CACHE=${HF_CACHE:-/var/tmp/hf}
MODEL_DIR=${1:-${HF_CACHE}/hub/models--moonshotai--Kimi-K2.5}

[ -d "${MODEL_DIR}/snapshots" ] || {
    echo "ERR: ${MODEL_DIR}/snapshots not found."
    echo "     Pass the models--<org>--<name> cache directory as \$1."
    exit 1; }

echo "=== Dereferencing remote-code symlinks under ${MODEL_DIR} ==="
fixed=0; skipped=0
while IFS= read -r -d '' f; do
    if [ -L "${f}" ]; then
        target=$(readlink -f "${f}") || { echo "  WARN dangling: ${f}"; continue; }
        [ -f "${target}" ] || { echo "  WARN target missing: ${f}"; continue; }
        # cp to a temp then mv, so an interrupted run cannot leave a truncated
        # module in place of a working symlink.
        cp -f "${target}" "${f}.real.$$"
        mv -f "${f}.real.$$" "${f}"
        echo "  fixed   $(basename "${f}")"
        fixed=$((fixed+1))
    else
        skipped=$((skipped+1))
    fi
done < <(find "${MODEL_DIR}/snapshots" -maxdepth 2 -name '*.py' -print0)

echo
echo "  ${fixed} symlink(s) dereferenced, ${skipped} already regular files"
if [ "${fixed}" -eq 0 ] && [ "${skipped}" -eq 0 ]; then
    echo "  NOTE: no .py files found — this model may not use trust_remote_code,"
    echo "        in which case it never had this problem."
fi
