#!/usr/bin/env bash
# Maintain a fork-local branch that mirrors upstream/<branch>, optionally
# pinned to the latest tag matching a glob pattern.
#
# Requires env: DRY_RUN, UPSTREAM_BRANCH, FORK_UPSTREAM_BRANCH
# Optional env: UPSTREAM_TAG_PATTERN (glob, e.g. "v*")
# Outputs (via GITHUB_OUTPUT): upstream_tag

set -euo pipefail

target_ref="upstream/${UPSTREAM_BRANCH}"
upstream_tag=""

if [[ -n "${UPSTREAM_TAG_PATTERN:-}" ]]; then
  # Find the latest stable tag (exclude pre-release suffixes like -beta.1, -rc2)
  # reachable from the upstream branch, sorted by version.
  upstream_tag=$(
    git tag --list "$UPSTREAM_TAG_PATTERN" \
      --sort=-version:refname \
      --merged "upstream/${UPSTREAM_BRANCH}" \
    | grep -v -E -- '-' \
    | head -1
  ) || true

  if [[ -n "$upstream_tag" ]]; then
    echo "Pinning to tag: ${upstream_tag}"
    target_ref="$upstream_tag"
  else
    echo "::warning::No tag matching '${UPSTREAM_TAG_PATTERN}' found on upstream/${UPSTREAM_BRANCH}; falling back to branch HEAD"
  fi
fi

echo "Syncing ${FORK_UPSTREAM_BRANCH} -> ${target_ref}"
git branch -f "$FORK_UPSTREAM_BRANCH" "$target_ref" >/dev/null

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "upstream_tag=${upstream_tag}" >> "$GITHUB_OUTPUT"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] skipping push"
  exit 0
fi

git fetch origin \
  "+refs/heads/${FORK_UPSTREAM_BRANCH}:refs/remotes/origin/${FORK_UPSTREAM_BRANCH}" \
  --quiet 2>/dev/null || true

git push --force-with-lease origin "$FORK_UPSTREAM_BRANCH" --quiet

echo "${FORK_UPSTREAM_BRANCH} updated"
