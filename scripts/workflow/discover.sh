#!/usr/bin/env bash
# Discover patch/* branches and classify them as active or merged.
#
# Requires env: UPSTREAM_REPO, UPSTREAM_BRANCH, FORK_OWNER
# Outputs (via GITHUB_OUTPUT): merged_patches
# Side effects: writes /tmp/active_branches.txt, /tmp/sorted_branches.txt, /tmp/meta_* files

# shellcheck source=workflow/lib.sh
source "$(dirname "$0")/lib.sh"

topo_sort() {
  # Repeatedly emit branches whose parent has already been emitted
  local -a active_branches=("$@") remaining=("$@") sorted=()
  local -a emitted=("upstream/$UPSTREAM_BRANCH")
  local pass=0 max=$(( ${#remaining[@]} + 1 ))
  while [[ ${#remaining[@]} -gt 0 && $pass -lt $max ]]; do
    (( pass++ )) || true
    local -a next=()
    for b in "${remaining[@]}"; do
      local parent
      parent=$(get_effective_parent "$b" "${active_branches[@]}")
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

fetch_pr_json() {
  local branch="$1"
  local url
  url="https://api.github.com/repos/${UPSTREAM_REPO}/pulls?state=all&head=${FORK_OWNER}:${branch}&per_page=1"

  local -a curl_args=(
    --silent
    --show-error
    --fail
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  if [[ -n "${GH_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi

  curl "${curl_args[@]}" "$url"
}

# Collect all patch/* branches present on origin
mapfile -t all_branches < <(
  git branch --list 'patch/*' | sed 's/^[* ]*//' | sort
)
echo "Found ${#all_branches[@]} patch branch(es): ${all_branches[*]:-none}"

active=() merged=()

for branch in "${all_branches[@]}"; do
  # Look up the PR for this branch on the upstream repo.
  pr_json='[]'
  if candidate=$(fetch_pr_json "$branch" 2>/dev/null) \
    && [[ "$(echo "$candidate" | jq 'length')" -gt 0 ]]; then
    pr_json="$candidate"
  fi
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

if [[ ${#active[@]} -gt 0 ]]; then
  printf '%s\n' "${active[@]}" > /tmp/active_branches.txt
else
  : > /tmp/active_branches.txt
fi

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
