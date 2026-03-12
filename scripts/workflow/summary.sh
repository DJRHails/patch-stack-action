#!/usr/bin/env bash
# Write the GitHub Actions job summary.
#
# Requires env: UPSTREAM_REPO, UPSTREAM_BRANCH, FORK_REPO, FORK_MAIN,
#               FORK_UPSTREAM_BRANCH, DRY_RUN, MERGED_PATCHES, NEEDS_CLAUDE
# Optional env: UPSTREAM_TAG, UPSTREAM_SHA

set -euo pipefail

{
	echo "# Patch Stack Sync"
	echo ""
	upstream_short_sha="${UPSTREAM_SHA:+${UPSTREAM_SHA:0:12}}"
	if [[ -n "${UPSTREAM_TAG:-}" ]]; then
		echo "**Upstream:** \`${UPSTREAM_REPO}@${UPSTREAM_TAG}\` (\`${upstream_short_sha:-unknown}\`, pinned tag on \`${UPSTREAM_BRANCH}\`)"
	elif [[ -n "${upstream_short_sha:-}" ]]; then
		echo "**Upstream:** \`${UPSTREAM_REPO}@${UPSTREAM_BRANCH}\` (\`${upstream_short_sha}\`)"
	else
		echo "**Upstream:** \`${UPSTREAM_REPO}@${UPSTREAM_BRANCH}\`"
	fi
	echo "**Fork:** \`${FORK_REPO}@${FORK_MAIN}\`"
	echo "**Fork upstream mirror:** \`${FORK_REPO}@${FORK_UPSTREAM_BRANCH}\`"
	echo "**Dry run:** ${DRY_RUN}"
	echo ""

	if [[ -n "$MERGED_PATCHES" ]]; then
		echo "## Merged upstream (branches deleted)"
		echo "$MERGED_PATCHES" | tr ',' '\n' |
			while read -r b; do [[ -n "$b" ]] && echo "- \`$b\`"; done
		echo ""
	fi

	if [[ -s /tmp/preserved_main_commits.txt ]]; then
		echo "## Preserved fork commits on \`${FORK_MAIN}\`"
		while IFS= read -r commit || [[ -n "$commit" ]]; do
			[[ -z "$commit" ]] && continue
			echo "- \`$(git log -1 --format='%h %s' "$commit")\`"
		done </tmp/preserved_main_commits.txt
		echo ""
	fi

	if [[ -s /tmp/sorted_branches.txt ]]; then
		echo "## Applied patches"
		echo ""
		echo "| # | Branch | Upstream PR | Local PR |"
		echo "|---|--------|-------------|----------|"
		idx=0
		while IFS= read -r branch || [[ -n "$branch" ]]; do
			[[ -z "$branch" ]] && continue
			((idx++)) || true
			safe="${branch//\//_}"
			pr_num=$(cat "/tmp/meta_num_${safe}" 2>/dev/null || echo "")
			pr_url=$(cat "/tmp/meta_url_${safe}" 2>/dev/null || echo "")
			pr_label=$(cat "/tmp/meta_pr_label_${safe}" 2>/dev/null || echo "")

			upstream_col="—"
			local_col="—"
			if [[ "$pr_label" == "Upstream PR" && -n "$pr_num" ]]; then
				upstream_col="[#${pr_num}](${pr_url})"
			elif [[ "$pr_label" == "Local PR" && -n "$pr_num" ]]; then
				local_col="[#${pr_num}](${pr_url})"
			fi

			echo "| ${idx} | \`${branch}\` | ${upstream_col} | ${local_col} |"
		done </tmp/sorted_branches.txt
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
} >>"$GITHUB_STEP_SUMMARY"
