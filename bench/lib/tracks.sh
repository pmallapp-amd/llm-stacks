#!/usr/bin/env bash
# bench/lib/tracks.sh — resolver for bench/tracks.registry.
#
# Source this from any benchmark that needs to deploy a track:
#   source "${REPO_ROOT}/bench/lib/tracks.sh"
#   script=$(track_deploy_script nixl)
#   model=$(track_default_model  nixl)
#
# Every function takes a track name and returns nonzero (with a message on
# stderr listing the known tracks) if it is not registered. No dependencies
# beyond coreutils — these scripts run on bare remote hosts.

# TRACKS_REGISTRY may be pre-set to point at an alternate registry file.
: "${TRACKS_REGISTRY:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tracks.registry}"
: "${TRACKS_REPO_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# _track_field <name> <field-number>
_track_field() {
    local name=$1 field=$2 line
    line=$(grep -v '^[[:space:]]*#' "${TRACKS_REGISTRY}" 2>/dev/null \
           | grep -v '^[[:space:]]*$' | awk -F'|' -v n="${name}" '$1==n {print; exit}')
    if [ -z "${line}" ]; then
        echo "ERR: unknown track '${name}'. Known tracks:" >&2
        track_list | sed 's/^/       /' >&2
        echo "     (or set DEPLOY_SCRIPT=<path> to use an unregistered stack)" >&2
        return 1
    fi
    echo "${line}" | awk -F'|' -v f="${field}" '{print $f}'
}

# track_list — print every registered track name + description
track_list() {
    grep -v '^[[:space:]]*#' "${TRACKS_REGISTRY}" 2>/dev/null \
      | grep -v '^[[:space:]]*$' \
      | awk -F'|' '{printf "%-16s %s\n", $1, $4}'
}

# track_deploy_script <name> — absolute path to the track's deploy script
track_deploy_script() {
    local rel; rel=$(_track_field "$1" 2) || return 1
    echo "${TRACKS_REPO_ROOT}/${rel}"
}

# track_default_model <name> — the model that track's deploy script serves by default
track_default_model() { _track_field "$1" 3; }

# track_description <name>
track_description() { _track_field "$1" 4; }
