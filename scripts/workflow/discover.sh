#!/usr/bin/env bash
# Discover patch/* branches and classify them as active or merged.
#
# Requires env: UPSTREAM_REPO, FORK_REPO, UPSTREAM_BRANCH,
#               FORK_BASE_BRANCH, FORK_OWNER, UPSTREAM_GH_TOKEN, FORK_GH_TOKEN
# Outputs (via GITHUB_OUTPUT): merged_patches
# Side effects: writes /tmp/active_branches.txt, /tmp/sorted_branches.txt, /tmp/meta_* files

# shellcheck source=workflow/lib.sh
source "$(dirname "$0")/lib.sh"

topo_sort() {
  # Emit branches level by level: within each level, order by PR number
  # (lowest first). Dependency ordering is always preserved — a child
  # never appears before its parent regardless of PR number.
  local -a active_branches=("$@") remaining=("$@") sorted=()
  local -a emitted=("$FORK_BASE_BRANCH")
  local pass=0 max=$(( ${#remaining[@]} + 1 ))
  while [[ ${#remaining[@]} -gt 0 && $pass -lt $max ]]; do
    (( pass++ )) || true
    local -a ready=() next=()
    for b in "${remaining[@]}"; do
      local parent
      parent=$(get_effective_parent "$b" "${active_branches[@]}")
      local found=false
      for e in "${emitted[@]}"; do
        [[ "$e" == "$parent" ]] && { found=true; break; }
      done
      if $found; then
        ready+=("$b")
      else
        next+=("$b")
      fi
    done
    # Sort ready branches by PR number (no-PR branches go last)
    if [[ ${#ready[@]} -gt 1 ]]; then
      local -a pr_sorted=()
      mapfile -t pr_sorted < <(
        for b in "${ready[@]}"; do
          local safe="${b//\//_}"
          local num
          num=$(cat "/tmp/meta_num_${safe}" 2>/dev/null || echo "")
          printf '%s\t%s\n' "${num:-999999}" "$b"
        done | sort -t$'\t' -k1,1n | cut -f2
      )
      ready=("${pr_sorted[@]}")
    fi
    sorted+=("${ready[@]}")
    emitted+=("${ready[@]}")
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
  local repo="$1" token="$2" branch="$3"
  local url
  url="https://api.github.com/repos/${repo}/pulls?state=all&head=${FORK_OWNER}:${branch}&per_page=1"

  local -a curl_args=(
    --silent
    --show-error
    --fail
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  if [[ -n "$token" ]]; then
    curl_args+=(-H "Authorization: Bearer ${token}")
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
  # Look up the PR for this branch on the upstream repo first.
  upstream_pr_json='[]'
  if candidate=$(fetch_pr_json "$UPSTREAM_REPO" "${UPSTREAM_GH_TOKEN:-}" "$branch" 2>/dev/null) \
    && [[ "$(echo "$candidate" | jq 'length')" -gt 0 ]]; then
    upstream_pr_json="$candidate"
  fi

  # If there is no upstream PR, fall back to the fork-local visibility PR.
  selected_pr_json="$upstream_pr_json"
  pr_label=""
  if [[ "$selected_pr_json" != "[]" ]]; then
    pr_label="Upstream PR"
  else
    if candidate=$(fetch_pr_json "$FORK_REPO" "${FORK_GH_TOKEN:-}" "$branch" 2>/dev/null) \
      && [[ "$(echo "$candidate" | jq 'length')" -gt 0 ]]; then
      selected_pr_json="$candidate"
      pr_label="Local PR"
    fi
  fi

  if [[ "$upstream_pr_json" == "[]" ]]; then
    if [[ "$selected_pr_json" != "[]" ]]; then
      echo "::notice::No upstream PR found for ${branch}; using local PR metadata from ${FORK_REPO}"
    else
      echo "::warning::No PR found for ${branch} on ${UPSTREAM_REPO} or ${FORK_REPO}"
    fi
  fi

  upstream_pr_merged_at=$(echo "$upstream_pr_json" | jq -r '.[0].merged_at // ""')
  pr_url=$(echo   "$selected_pr_json" | jq -r '.[0].html_url // .[0].url // ""')
  pr_num=$(echo   "$selected_pr_json" | jq -r '.[0].number // ""')
  pr_title=$(echo "$selected_pr_json" | jq -r '.[0].title  // ""')
  pr_body=$(echo  "$selected_pr_json" | jq -r '.[0].body   // ""')

  # Persist metadata for later steps
  safe="${branch//\//_}"
  echo "$pr_url"   > "/tmp/meta_url_${safe}"
  echo "$pr_num"   > "/tmp/meta_num_${safe}"
  echo "$pr_title" > "/tmp/meta_title_${safe}"
  echo "$pr_label" > "/tmp/meta_pr_label_${safe}"
  printf '%s' "$pr_body" > "/tmp/meta_body_${safe}"

  parent=$(get_parent "$branch")
  unique_commits=$(git log --oneline "${parent}..${branch}" \
    2>/dev/null | wc -l | tr -d ' ')

  if [[ -n "$upstream_pr_merged_at" || "$unique_commits" -eq 0 ]]; then
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
