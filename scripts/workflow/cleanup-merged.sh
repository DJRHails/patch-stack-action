#!/usr/bin/env bash
# Delete merged branches and collapse descendant branch prefixes.
#
# Requires env: DRY_RUN, MERGED_PATCHES, GH_TOKEN, FORK_REPO

set -euo pipefail

branch_segments() {
  local name="${1#patch/}"
  local stripped="${name//--/$'\n'}"
  wc -l <<< "$stripped" | tr -d ' '
}

strip_prefix() {
  local branch="$1"
  local prefix="$2"
  local name="${branch#patch/}"
  local prefix_name="${prefix#patch/}"

  if [[ "$name" == "$prefix_name" ]]; then
    echo ""
  elif [[ "$name" == "$prefix_name"--* ]]; then
    echo "patch/${name#"${prefix_name}"--}"
  else
    echo "$branch"
  fi
}

contains_branch() {
  local needle="$1"
  shift || true
  local branch
  for branch in "$@"; do
    [[ "$branch" == "$needle" ]] && return 0
  done
  return 1
}

rename_remote_branch() {
  local source="$1"
  local target="$2"
  local encoded_source
  encoded_source=$(jq -rn --arg v "$source" '$v|@uri')
  gh api \
    --method POST \
    "repos/${FORK_REPO}/branches/${encoded_source}/rename" \
    -f new_name="$target" \
    >/dev/null
}

mapfile -t merged_branches < <(
  printf '%s\n' "$MERGED_PATCHES" \
    | tr ',' '\n' \
    | sed '/^$/d' \
    | awk -F'--' '{print NF "\t" $0}' \
    | sort -n -k1,1 -k2,2 \
    | cut -f2-
)

mapfile -t all_branches < <(
  git branch --list 'patch/*' | sed 's/^[* ]*//' | sort
)

canonical_merged=()
for merged in "${merged_branches[@]}"; do
  canonical="$merged"
  for prefix in "${canonical_merged[@]}"; do
    canonical=$(strip_prefix "$canonical" "$prefix")
    [[ -z "$canonical" ]] && break
  done
  [[ -n "$canonical" ]] && canonical_merged+=("$canonical")
done

rename_sources=()
rename_targets=()
for branch in "${all_branches[@]}"; do
  contains_branch "$branch" "${merged_branches[@]}" && continue

  target="$branch"
  for prefix in "${canonical_merged[@]}"; do
    target=$(strip_prefix "$target" "$prefix")
    [[ -z "$target" ]] && break
  done

  if [[ -n "$target" && "$target" != "$branch" ]]; then
    rename_sources+=("$branch")
    rename_targets+=("$target")
  fi
done

for i in "${!rename_sources[@]}"; do
  target="${rename_targets[$i]}"

  for j in "${!rename_sources[@]}"; do
    [[ "$i" == "$j" ]] && continue
    if [[ "${rename_targets[$j]}" == "$target" ]]; then
      echo "::error::Multiple descendant branches would be renamed to $target"
      exit 1
    fi
  done

  if contains_branch "$target" "${all_branches[@]}" \
    && ! contains_branch "$target" "${merged_branches[@]}" \
    && ! contains_branch "$target" "${rename_sources[@]}"; then
    echo "::error::Cannot rename ${rename_sources[$i]} to existing branch $target"
    exit 1
  fi
done

mapfile -t rename_order < <(
  for i in "${!rename_sources[@]}"; do
    printf '%s\t%s\n' "$(branch_segments "${rename_sources[$i]}")" "$i"
  done | sort -n -k1,1 | cut -f2
)

for idx in "${rename_order[@]}"; do
  source="${rename_sources[$idx]}"
  target="${rename_targets[$idx]}"
  echo "Renaming descendant branch: $source -> $target"
  if [[ "$DRY_RUN" != "true" ]]; then
    rename_remote_branch "$source" "$target"
    git branch -m "$source" "$target"
  else
    echo "  [dry-run] skipping rename"
  fi
done

for branch in "${merged_branches[@]}"; do
  [[ -z "$branch" ]] && continue
  echo "Deleting merged branch: $branch"
  if [[ "$DRY_RUN" != "true" ]]; then
    git push origin --delete "$branch" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
  else
    echo "  [dry-run] skipping delete"
  fi
done
