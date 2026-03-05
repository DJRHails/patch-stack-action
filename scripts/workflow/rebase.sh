#!/usr/bin/env bash
# Rebase each active patch branch onto its parent. If all rebases succeed,
# rebuild fork/main as upstream + squash-merged patches.
#
# Requires env: DRY_RUN, UPSTREAM_BRANCH, FORK_MAIN
# Outputs (via GITHUB_OUTPUT): needs_claude

# shellcheck source=workflow/lib.sh
source "$(dirname "$0")/lib.sh"

needs_claude=false
echo "[]" > /tmp/conflicts.json
active_branches=()
if [[ -f /tmp/active_branches.txt ]]; then
  mapfile -t active_branches < /tmp/active_branches.txt
fi

add_conflict() {
  local branch="$1" parent="$2" files="$3"
  local pr_url="$4" pr_title="$5" pr_body="$6"
  jq --arg b "$branch" --arg p "$parent" --arg f "$files" \
     --arg u "$pr_url" --arg t "$pr_title" --arg d "$pr_body" \
     '. += [{branch:$b, parent:$p,
              conflicting_files:($f|split("\n")|map(select(.!=""))),
              pr_url:$u, pr_title:$t, pr_body:$d}]' \
     /tmp/conflicts.json > /tmp/conflicts.tmp \
    && mv /tmp/conflicts.tmp /tmp/conflicts.json
}

while IFS= read -r branch || [[ -n "$branch" ]]; do
  [[ -z "$branch" ]] && continue
  parent=$(get_effective_parent "$branch" "${active_branches[@]}")
  safe="${branch//\//_}"
  pr_url=$(cat   "/tmp/meta_url_${safe}"   2>/dev/null || echo "")
  pr_title=$(cat "/tmp/meta_title_${safe}" 2>/dev/null || echo "")
  pr_body=$(cat  "/tmp/meta_body_${safe}"  2>/dev/null || echo "")

  echo ""
  echo "-- Rebasing $branch onto $parent --"
  git checkout "$branch" --quiet
  git rebase --abort 2>/dev/null || true

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] skipping rebase"
    continue
  fi

  if git rebase "$parent" --quiet 2>/tmp/rebase_err.txt; then
    echo "  Clean -- pushing"
    git push --force-with-lease origin "$branch" --quiet
  else
    echo "  Conflict -- queued for Claude"
    needs_claude=true
    files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    add_conflict "$branch" "$parent" "$files" \
      "$pr_url" "$pr_title" "$pr_body"
    git rebase --abort 2>/dev/null || true
  fi
done < /tmp/sorted_branches.txt

# If no conflicts, rebuild fork/main now (Claude will do it otherwise)
if ! $needs_claude && [[ "$DRY_RUN" != "true" ]]; then
  echo ""
  echo "-- Rebuilding $FORK_MAIN (squash per patch) --"
  git checkout "$FORK_MAIN" --quiet
  git reset --hard "upstream/$UPSTREAM_BRANCH"

  while IFS= read -r branch || [[ -n "$branch" ]]; do
    [[ -z "$branch" ]] && continue
    safe="${branch//\//_}"
    pr_title=$(cat "/tmp/meta_title_${safe}" 2>/dev/null || echo "")
    pr_num=$(cat  "/tmp/meta_num_${safe}"   2>/dev/null || echo "")
    pr_url=$(cat  "/tmp/meta_url_${safe}"   2>/dev/null || echo "")
    echo "  Squash-merging $branch..."

    # --squash stages all changes without creating a merge commit,
    # then we create one labelled commit per patch.
    if git merge --squash "$branch" --quiet 2>/tmp/squash_err.txt; then
      if git diff --cached --quiet; then
        echo "    No staged changes after squash; skipping empty patch"
      else
        if [[ -n "$pr_title" && -n "$pr_num" ]]; then
          msg="${pr_title} (#${pr_num})"
        else
          msg="${branch#patch/}"
        fi
        [[ -n "$pr_url" ]] && msg="${msg}\n\nUpstream PR: ${pr_url}"
        git commit -m "$(printf '%b' "$msg")" --quiet
        echo "    Done"
      fi
    else
      echo "::error::Squash merge failed for $branch -- queueing for Claude"
      cat /tmp/squash_err.txt
      git merge --abort 2>/dev/null \
        || git reset --hard HEAD 2>/dev/null || true
      needs_claude=true
      break
    fi
  done < /tmp/sorted_branches.txt

  if ! $needs_claude; then
    git push --force-with-lease origin "$FORK_MAIN" --quiet
    echo "$FORK_MAIN rebuilt and pushed"
  fi
fi

echo "needs_claude=${needs_claude}" >> "$GITHUB_OUTPUT"
