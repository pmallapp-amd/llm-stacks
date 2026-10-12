#!/usr/bin/env bash
# run-all.sh — run this role's verify steps in order.
#
# Default is FAIL-FAST: each step rules out the layer below it, so running
# a later step after an earlier one failed just reproduces the same root
# cause in a harder-to-read form. (Same reasoning as the rung ladder in
# docs/BRINGUP.md §2.4.)
#
# Usage:
#   ./run-all.sh                 # every step, stop at the first failure
#   ./run-all.sh --from 04       # skip host/rdma/kvdev, e.g. after a container recreate
#   ./run-all.sh --through 03    # host preconditions only, before starting anything
#   ./run-all.sh --keep-going    # run them all and summarise at the end
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FROM=00; THROUGH=99; KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from)       shift; FROM="${1:?--from needs NN}" ;;
        --through)    shift; THROUGH="${1:?--through needs NN}" ;;
        --keep-going) KEEP=1 ;;
        -h|--help)    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

rc=0; ran=0; failed=()
for s in [0-9][0-9]-verify-*.sh; do
    n="${s%%-*}"
    [ "$n" \< "$FROM" ] && continue
    [ "$THROUGH" \< "$n" ] && continue
    ran=$((ran + 1))
    if ! bash "./$s"; then
        rc=1; failed+=("$s")
        [ "$KEEP" -eq 1 ] || { echo "" >&2; echo "FAIL decode/verify: $s failed — stopping (use --keep-going to continue)" >&2; exit 1; }
    fi
done

echo "" >&2
if [ "$rc" -eq 0 ]; then
    echo "OK   decode/verify: all $ran step(s) passed" >&2
else
    echo "FAIL decode/verify: ${#failed[@]} of $ran step(s) failed: ${failed[*]}" >&2
fi
exit "$rc"
