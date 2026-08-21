#!/usr/bin/env bash
# Maintain the fork's base branch that mirrors upstream/<branch>, optionally
# pinned to the latest tag matching a glob pattern.
#
# Requires env: DRY_RUN, UPSTREAM_BRANCH, FORK_BASE_BRANCH, UPSTREAM_REPO
# Optional env: UPSTREAM_TAG_PATTERN (glob, e.g. "v*")
#               UPSTREAM_COMMIT_OVERRIDE (full or short SHA)
#               UPSTREAM_GH_TOKEN (for authenticated GitHub API calls)
# Outputs (via GITHUB_OUTPUT): upstream_tag, upstream_sha

set -euo pipefail

target_ref="upstream/${UPSTREAM_BRANCH}"
upstream_tag=""

if [[ -n "${UPSTREAM_TAG_PATTERN:-}" ]]; then
  # Use the GitHub Releases API to find the latest stable release tag.
  # This handles repos that cut releases from release branches: the tag
  # commit is then not an ancestor of main, so a local
  # `git tag --merged upstream/<branch>` walk silently skips every such
  # release and pins base to the last on-main tag, which can be months old.
  gh_token="${UPSTREAM_GH_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$gh_token" ]]; then
    export GH_TOKEN="$gh_token"
  fi

  upstream_tag=$(
    gh api "repos/${UPSTREAM_REPO}/releases/latest" --jq '.tag_name' 2>/dev/null
  ) || true

  if [[ -n "$upstream_tag" ]]; then
    echo "Pinning to tag: ${upstream_tag} (via GitHub Releases API)"
    target_ref="$upstream_tag"
  else
    echo "::warning::GitHub Releases API returned no latest release for ${UPSTREAM_REPO}; falling back to branch HEAD"
  fi
fi

# Allow a commit override to skip ahead of the latest tag.  The override
# expires automatically once a tag is released that contains the commit.
# The commit must be reachable from upstream/<branch> (i.e. already merged).
if [[ -n "${UPSTREAM_COMMIT_OVERRIDE:-}" ]]; then
  override_sha=$(git rev-parse --verify "${UPSTREAM_COMMIT_OVERRIDE}^{commit}" 2>/dev/null) || {
    echo "::error::upstream_commit_override '${UPSTREAM_COMMIT_OVERRIDE}' is not a valid commit on upstream/${UPSTREAM_BRANCH}"
    exit 1
  }

  # Reachable from the upstream branch OR contained in an upstream-pattern
  # tag: release-branch repos have tag commits that are not on main.
  if ! git merge-base --is-ancestor "$override_sha" "upstream/${UPSTREAM_BRANCH}" 2>/dev/null \
    && ! git tag --list "${UPSTREAM_TAG_PATTERN:-*}" --contains "$override_sha" 2>/dev/null | grep -q .; then
    echo "::error::upstream_commit_override '${UPSTREAM_COMMIT_OVERRIDE}' is not reachable from upstream/${UPSTREAM_BRANCH} or any '${UPSTREAM_TAG_PATTERN:-*}' tag"
    exit 1
  fi

  if [[ -n "$upstream_tag" ]] && git merge-base --is-ancestor "$override_sha" "$upstream_tag" 2>/dev/null; then
    echo "Override commit ${UPSTREAM_COMMIT_OVERRIDE} is already contained in ${upstream_tag}; ignoring override"
  else
    echo "Applying commit override: ${UPSTREAM_COMMIT_OVERRIDE} (${override_sha})"
    target_ref="$override_sha"
    upstream_tag="${upstream_tag:+${upstream_tag}+}${override_sha:0:12}"
  fi
fi

echo "Syncing ${FORK_BASE_BRANCH} -> ${target_ref}"
git branch -f "$FORK_BASE_BRANCH" "$target_ref" >/dev/null

upstream_sha=$(git rev-parse "$FORK_BASE_BRANCH")

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "upstream_tag=${upstream_tag}" >> "$GITHUB_OUTPUT"
  echo "upstream_sha=${upstream_sha}" >> "$GITHUB_OUTPUT"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] skipping push"
  exit 0
fi

git fetch origin \
  "+refs/heads/${FORK_BASE_BRANCH}:refs/remotes/origin/${FORK_BASE_BRANCH}" \
  --quiet 2>/dev/null || true

git push --force-with-lease origin "$FORK_BASE_BRANCH" --quiet

echo "${FORK_BASE_BRANCH} updated"
