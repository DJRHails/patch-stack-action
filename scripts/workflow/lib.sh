#!/usr/bin/env bash
# Common functions shared across patch-stack scripts.
# Source this file from scripts/workflow: source "$(dirname "$0")/lib.sh"

set -euo pipefail

# Resolve the parent branch for a given patch branch.
# Root branches (no "--") rebase onto upstream; children strip the last segment.
#
# Requires: UPSTREAM_BRANCH env var
get_parent() {
  local branch="${1#patch/}"
  if [[ "$branch" == *"--"* ]]; then
    echo "patch/${branch%--*}"
  else
    echo "upstream/$UPSTREAM_BRANCH"
  fi
}

# Resolve the nearest ancestor that is still active in this run.
# If all patch ancestors were merged or dropped, the branch rebases onto upstream.
get_effective_parent() {
  local branch="$1"
  shift || true

  local parent
  parent=$(get_parent "$branch")

  while [[ "$parent" == patch/* ]]; do
    local candidate
    for candidate in "$@"; do
      if [[ "$candidate" == "$parent" ]]; then
        echo "$parent"
        return
      fi
    done
    parent=$(get_parent "$parent")
  done

  echo "$parent"
}
