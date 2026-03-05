#!/usr/bin/env bash
# Maintain a fork-local branch that mirrors upstream/<branch>.
#
# Requires env: DRY_RUN, UPSTREAM_BRANCH, FORK_UPSTREAM_BRANCH

set -euo pipefail

echo "Syncing ${FORK_UPSTREAM_BRANCH} -> upstream/${UPSTREAM_BRANCH}"
git branch -f "$FORK_UPSTREAM_BRANCH" "upstream/$UPSTREAM_BRANCH" >/dev/null

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] skipping push"
  exit 0
fi

git fetch origin \
  "+refs/heads/${FORK_UPSTREAM_BRANCH}:refs/remotes/origin/${FORK_UPSTREAM_BRANCH}" \
  --quiet 2>/dev/null || true

git push --force-with-lease origin "$FORK_UPSTREAM_BRANCH" --quiet

echo "${FORK_UPSTREAM_BRANCH} updated"
