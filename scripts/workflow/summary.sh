#!/usr/bin/env bash
# Write the GitHub Actions job summary.
#
# Requires env: UPSTREAM_REPO, UPSTREAM_BRANCH, FORK_REPO, FORK_MAIN,
#               DRY_RUN, MERGED_PATCHES, NEEDS_CLAUDE

set -euo pipefail

{
  echo "# Patch Stack Sync"
  echo ""
  echo "**Upstream:** \`${UPSTREAM_REPO}@${UPSTREAM_BRANCH}\`"
  echo "**Fork:** \`${FORK_REPO}@${FORK_MAIN}\`"
  echo "**Dry run:** ${DRY_RUN}"
  echo ""

  if [[ -n "$MERGED_PATCHES" ]]; then
    echo "## Merged upstream (branches deleted)"
    echo "$MERGED_PATCHES" | tr ',' '\n' \
      | while read -r b; do [[ -n "$b" ]] && echo "- \`$b\`"; done
    echo ""
  fi

  if [[ -s /tmp/preserved_main_commits.txt ]]; then
    echo "## Preserved fork commits on \`${FORK_MAIN}\`"
    while IFS= read -r commit || [[ -n "$commit" ]]; do
      [[ -z "$commit" ]] && continue
      echo "- \`$(git log -1 --format='%h %s' "$commit")\`"
    done < /tmp/preserved_main_commits.txt
    echo ""
  fi

  if [[ "$NEEDS_CLAUDE" == "true" ]]; then
    echo "## Claude resolved conflicts"
    if [[ -f /tmp/claude_summary.md ]]; then
      cat /tmp/claude_summary.md
    fi
  else
    echo "## All patches rebased cleanly -- no conflicts"
  fi
} >> "$GITHUB_STEP_SUMMARY"
