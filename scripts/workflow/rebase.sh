#!/usr/bin/env bash
# Rebase each active patch branch onto its parent. If all rebases succeed,
# rebuild fork/main as fork-local upstream mirror + preserved local commits +
# squash-merged patches.
#
# Requires env: DRY_RUN, UPSTREAM_BRANCH, FORK_MAIN, FORK_UPSTREAM_BRANCH
# Outputs (via GITHUB_OUTPUT): needs_claude

# shellcheck source=workflow/lib.sh
source "$(dirname "$0")/lib.sh"

PATCH_STACK_COMMIT_PREFIX="patch-stack: "
PATCH_STACK_BRANCH_TRAILER="Patch-Stack-Branch: "
PATCH_STACK_PR_TRAILERS=("Upstream PR:" "Local PR:")

needs_claude=false
echo "[]" > /tmp/conflicts.json
active_branches=()
if [[ -f /tmp/active_branches.txt ]]; then
  mapfile -t active_branches < /tmp/active_branches.txt
fi
legacy_patch_subjects=()

build_legacy_patch_subject() {
  local branch="$1" pr_title="$2" pr_num="$3"
  if [[ -n "$pr_title" && -n "$pr_num" ]]; then
    printf '%s (#%s)' "$pr_title" "$pr_num"
  else
    printf '%s' "${branch#patch/}"
  fi
}

build_patch_commit_message() {
  local branch="$1" pr_title="$2" pr_num="$3" pr_url="$4" pr_label="$5"
  local legacy_subject
  legacy_subject=$(build_legacy_patch_subject "$branch" "$pr_title" "$pr_num")

  local message="${PATCH_STACK_COMMIT_PREFIX}${legacy_subject}

${PATCH_STACK_BRANCH_TRAILER}${branch}"
  if [[ -n "$pr_url" ]]; then
    if [[ -n "$pr_label" ]]; then
      message="${message}
${pr_label}: ${pr_url}"
    else
      message="${message}
Local PR: ${pr_url}"
    fi
  fi

  printf '%s' "$message"
}

load_legacy_patch_subjects() {
  local branch safe pr_title pr_num
  legacy_patch_subjects=()

  while IFS= read -r branch || [[ -n "$branch" ]]; do
    [[ -z "$branch" ]] && continue
    safe="${branch//\//_}"
    pr_title=$(cat "/tmp/meta_title_${safe}" 2>/dev/null || echo "")
    pr_num=$(cat  "/tmp/meta_num_${safe}"   2>/dev/null || echo "")
    legacy_patch_subjects+=("$(build_legacy_patch_subject "$branch" "$pr_title" "$pr_num")")
  done < /tmp/sorted_branches.txt
}

is_patch_generated_commit() {
  local commit="$1"
  local subject body
  subject=$(git log -1 --format=%s "$commit")
  body=$(git log -1 --format=%b "$commit")

  [[ "$subject" == "${PATCH_STACK_COMMIT_PREFIX}"* ]] && return 0
  [[ "$body" == *"${PATCH_STACK_BRANCH_TRAILER}"* ]] && return 0
  local pr_trailer
  for pr_trailer in "${PATCH_STACK_PR_TRAILERS[@]}"; do
    [[ "$body" == *"$pr_trailer"* ]] && return 0
  done

  local expected
  for expected in "${legacy_patch_subjects[@]}"; do
    [[ "$subject" == "$expected" ]] && return 0
  done

  return 1
}

collect_preserved_main_commits() {
  : > /tmp/preserved_main_commits.txt
  load_legacy_patch_subjects

  local commit
  while IFS= read -r commit || [[ -n "$commit" ]]; do
    [[ -z "$commit" ]] && continue
    if ! is_patch_generated_commit "$commit"; then
      printf '%s\n' "$commit" >> /tmp/preserved_main_commits.txt
    fi
  done < <(git rev-list --reverse "$FORK_UPSTREAM_BRANCH..$FORK_MAIN")
}

replay_preserved_main_commits() {
  [[ -s /tmp/preserved_main_commits.txt ]] || return 0

  echo ""
  echo "-- Replaying preserved $FORK_MAIN commits --"

  local commit subject
  while IFS= read -r commit || [[ -n "$commit" ]]; do
    [[ -z "$commit" ]] && continue
    subject=$(git log -1 --format=%s "$commit")
    echo "  Cherry-picking $commit $subject"

    if git cherry-pick "$commit" --quiet 2>/tmp/preserve_err.txt; then
      continue
    fi

    echo "::error::Failed to replay preserved $FORK_MAIN commit $commit"
    cat /tmp/preserve_err.txt
    git cherry-pick --abort 2>/dev/null \
      || git reset --hard HEAD 2>/dev/null || true
    return 1
  done < /tmp/preserved_main_commits.txt
}

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
  pr_label=$(cat "/tmp/meta_pr_label_${safe}" 2>/dev/null || echo "")

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

# Always collect preserved commits before rebuilding (Claude needs them too)
if [[ "$DRY_RUN" != "true" ]]; then
  collect_preserved_main_commits
fi

# If no conflicts, rebuild fork/main now (Claude will do it otherwise)
if ! $needs_claude && [[ "$DRY_RUN" != "true" ]]; then
  echo ""
  echo "-- Rebuilding $FORK_MAIN (${FORK_UPSTREAM_BRANCH} + preserved commits + squash per patch) --"
  git checkout "$FORK_MAIN" --quiet
  git reset --hard "$FORK_UPSTREAM_BRANCH"

  if ! replay_preserved_main_commits; then
    needs_claude=true
  fi

  if ! $needs_claude; then
    while IFS= read -r branch || [[ -n "$branch" ]]; do
      [[ -z "$branch" ]] && continue
      safe="${branch//\//_}"
      pr_title=$(cat "/tmp/meta_title_${safe}" 2>/dev/null || echo "")
      pr_num=$(cat  "/tmp/meta_num_${safe}"   2>/dev/null || echo "")
      pr_url=$(cat  "/tmp/meta_url_${safe}"   2>/dev/null || echo "")
      pr_label=$(cat "/tmp/meta_pr_label_${safe}" 2>/dev/null || echo "")
      echo "  Squash-merging $branch..."

      # --squash stages all changes without creating a merge commit,
      # then we create one labelled commit per patch.
      if git merge --squash "$branch" --quiet 2>/tmp/squash_err.txt; then
        if git diff --cached --quiet; then
          echo "    No staged changes after squash; skipping empty patch"
        else
          git commit -m "$(build_patch_commit_message "$branch" "$pr_title" "$pr_num" "$pr_url" "$pr_label")" --quiet
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
  fi

  if ! $needs_claude; then
    git push --force-with-lease origin "$FORK_MAIN" --quiet
    echo "$FORK_MAIN rebuilt and pushed"
  fi
fi

echo "needs_claude=${needs_claude}" >> "$GITHUB_OUTPUT"
