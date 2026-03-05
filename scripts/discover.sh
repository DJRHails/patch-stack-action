#!/usr/bin/env bash
# Discover patch/* branches and classify them as active or merged.
#
# Requires env: GH_TOKEN, UPSTREAM_REPO, UPSTREAM_BRANCH, FORK_OWNER
# Outputs (via GITHUB_OUTPUT): merged_patches
# Side effects: writes /tmp/sorted_branches.txt, /tmp/meta_* files

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

topo_sort() {
  # Repeatedly emit branches whose parent has already been emitted
  local -a remaining=("$@") sorted=()
  local -a emitted=("upstream/$UPSTREAM_BRANCH")
  local pass=0 max=$(( ${#remaining[@]} + 1 ))
  while [[ ${#remaining[@]} -gt 0 && $pass -lt $max ]]; do
    (( pass++ )) || true
    local -a next=()
    for b in "${remaining[@]}"; do
      local parent
      parent=$(get_parent "$b")
      local found=false
      for e in "${emitted[@]}"; do
        [[ "$e" == "$parent" ]] && { found=true; break; }
      done
      if $found; then
        sorted+=("$b")
        emitted+=("$b")
      else
        next+=("$b")
      fi
    done
    remaining=("${next[@]+"${next[@]}"}")
  done
  # Any remaining have broken deps — append with a warning
  [[ ${#remaining[@]} -gt 0 ]] && {
    echo "::warning::Could not resolve parents for: ${remaining[*]}" >&2
    sorted+=("${remaining[@]}")
  }
  printf '%s\n' "${sorted[@]}"
}

# Collect all patch/* branches present on origin
mapfile -t all_branches < <(
  git branch --list 'patch/*' | sed 's/^[* ]*//' | sort
)
echo "Found ${#all_branches[@]} patch branch(es): ${all_branches[*]:-none}"

active=() merged=()

for branch in "${all_branches[@]}"; do
  # Look up the PR for this branch on the upstream repo.
  # Try cross-fork format (owner:branch) first, then same-repo (branch only).
  pr_json='[]'
  for head_ref in "${FORK_OWNER}:${branch}" "${branch}"; do
    if candidate=$(gh pr list \
      --repo "$UPSTREAM_REPO" \
      --head "$head_ref" \
      --state all \
      --limit 1 \
      --json number,state,url,title,body \
      2>/dev/null) && [[ "$(echo "$candidate" | jq 'length')" -gt 0 ]]; then
      pr_json="$candidate"
      break
    fi
  done
  if [[ "$pr_json" == "[]" ]]; then
    echo "::warning::No PR found for ${branch} on ${UPSTREAM_REPO}"
  fi

  pr_state=$(echo "$pr_json" | jq -r '.[0].state // "NONE"')
  pr_url=$(echo   "$pr_json" | jq -r '.[0].url   // ""')
  pr_num=$(echo   "$pr_json" | jq -r '.[0].number // ""')
  pr_title=$(echo "$pr_json" | jq -r '.[0].title  // ""')
  pr_body=$(echo  "$pr_json" | jq -r '.[0].body   // ""')

  # Persist metadata for later steps
  safe="${branch//\//_}"
  echo "$pr_url"   > "/tmp/meta_url_${safe}"
  echo "$pr_num"   > "/tmp/meta_num_${safe}"
  echo "$pr_title" > "/tmp/meta_title_${safe}"
  printf '%s' "$pr_body" > "/tmp/meta_body_${safe}"

  parent=$(get_parent "$branch")
  unique_commits=$(git log --oneline "${parent}..${branch}" \
    2>/dev/null | wc -l | tr -d ' ')

  if [[ "$pr_state" == "MERGED" || "$unique_commits" -eq 0 ]]; then
    echo "  MERGED/empty: $branch"
    merged+=("$branch")
    continue
  fi

  echo "  ACTIVE (${unique_commits} commit(s)): $branch"
  active+=("$branch")
done

# Topologically sort active branches and persist order
if [[ ${#active[@]} -gt 0 ]]; then
  topo_sort "${active[@]}" > /tmp/sorted_branches.txt
else
  : > /tmp/sorted_branches.txt
fi

echo "Application order:"
cat /tmp/sorted_branches.txt || true

# Write outputs
printf '%s\n' "${merged[@]+"${merged[@]}"}" \
  | paste -sd ',' - > /tmp/out_merged.txt
{
  echo "merged_patches=$(cat /tmp/out_merged.txt)"
} >> "$GITHUB_OUTPUT"
