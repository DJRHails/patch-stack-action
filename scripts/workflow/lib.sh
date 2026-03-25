#!/usr/bin/env bash
# Common functions shared across patch-stack scripts.
# Source this file from scripts/workflow: source "$(dirname "$0")/lib.sh"

set -euo pipefail

# Resolve the parent branch for a given patch branch.
# Root branches (no "--") rebase onto the base branch; children strip the last
# segment.
#
# Requires: FORK_BASE_BRANCH env var
get_parent() {
  local branch="${1#patch/}"
  if [[ "$branch" == *"--"* ]]; then
    echo "patch/${branch%--*}"
  else
    echo "$FORK_BASE_BRANCH"
  fi
}

# Resolve the nearest ancestor that is still active in this run.
# If all patch ancestors were merged or dropped, the branch rebases onto the
# base branch.
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
