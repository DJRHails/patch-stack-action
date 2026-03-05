#!/usr/bin/env bash
# Repeatable local git simulations for patch-stack workflow edge cases.
#
# Usage:
#   bash scripts/dev/local-simulations.sh           # run all scenarios
#   bash scripts/dev/local-simulations.sh empty     # run one scenario
#   bash scripts/dev/local-simulations.sh rename    # run one scenario
#   bash scripts/dev/local-simulations.sh collapse  # run one scenario
#   bash scripts/dev/local-simulations.sh preserve  # run one scenario

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
SCENARIOS_RAN=0

info() {
  printf '==> %s\n' "$1"
}

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'Expected: %s\nActual:   %s\n' "$expected" "$actual" >&2
    fail "$message"
  fi
}

assert_line_count() {
  local expected="$1"
  local text="$2"
  local message="$3"
  local actual
  actual=$(printf '%s\n' "$text" | sed '/^$/d' | wc -l | tr -d ' ')
  assert_eq "$expected" "$actual" "$message"
}

reset_tmp_state() {
  rm -f /tmp/active_branches.txt \
    /tmp/conflicts.json \
    /tmp/conflicts.tmp \
    /tmp/out_merged.txt \
    /tmp/preserved_main_commits.txt \
    /tmp/rebase_err.txt \
    /tmp/sorted_branches.txt \
    /tmp/squash_err.txt \
    /tmp/meta_*
}

make_fake_gh() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

decode_uri() {
  local value="$1"
  printf '%b' "${value//%/\\x}"
}

if [[ "${1:-}" == "api" ]]; then
  shift
  method="GET"
  endpoint=""
  new_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method)
        method="$2"
        shift 2
        ;;
      -f)
        case "$2" in
          new_name=*)
            new_name="${2#new_name=}"
            ;;
        esac
        shift 2
        ;;
      repos/*)
        endpoint="$1"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ "$method" == "POST" && "$endpoint" == repos/*/branches/*/rename ]]; then
    encoded_branch="${endpoint#*"/branches/"}"
    encoded_branch="${encoded_branch%/rename}"
    old_name=$(decode_uri "$encoded_branch")

    git --git-dir="$LOCAL_REMOTE_DIR" branch -m "$old_name" "$new_name" >/dev/null
    exit 0
  fi
fi

exit 0
EOF
  chmod +x "$fake_bin/gh"
}

create_repo() {
  local name="$1"
  local remote_dir="$TMP_ROOT/${name}-remote.git"
  local work_dir="$TMP_ROOT/${name}-work"
  local fake_bin="$TMP_ROOT/${name}-bin"

  git init --bare -q "$remote_dir"
  git clone -q "$remote_dir" "$work_dir" >/dev/null
  make_fake_gh "$fake_bin"

  (
    cd "$work_dir"
    git config user.name tester
    git config user.email tester@example.com
    printf 'base\n' > app.txt
    git add app.txt
    git commit -q -m base
    git push -q origin HEAD:main
  )

  printf '%s\n%s\n%s\n' "$work_dir" "$fake_bin" "$remote_dir"
}

branch_list() {
  git branch --list 'patch/*' | sed 's/^[* ]*//' | sort
}

scenario_rename_descendant() {
  info "rename: collapse patch/merged-pr--child-pr to patch/child-pr"
  reset_tmp_state

  local work_dir fake_bin remote_dir
  mapfile -t repo_info < <(create_repo rename)
  work_dir="${repo_info[0]}"
  fake_bin="${repo_info[1]}"
  remote_dir="${repo_info[2]}"

  (
    cd "$work_dir"
    git checkout -q -b patch/merged-pr main
    printf 'base\nmerged\n' > app.txt
    git commit -qam merged
    git push -q origin HEAD

    git checkout -q -b patch/merged-pr--child-pr
    printf 'base\nmerged\nchild\n' > app.txt
    git commit -qam child
    git push -q origin HEAD

    PATH="$fake_bin:$PATH" \
      LOCAL_REMOTE_DIR="$remote_dir" \
      DRY_RUN=false \
      GH_TOKEN=dummy \
      FORK_REPO=owner/repo \
      MERGED_PATCHES='patch/merged-pr' \
      bash "$ROOT_DIR/scripts/workflow/cleanup-merged.sh"

    branches=$(branch_list)
    assert_eq 'patch/child-pr' "$branches" "descendant rename should collapse merged parent prefix"

    remote_branches=$(git --git-dir="$remote_dir" for-each-ref --format='%(refname:short)' refs/heads/patch | sort)
    assert_eq 'patch/child-pr' "$remote_branches" "remote branch rename should match local branch rename"
  )

  pass "rename"
  SCENARIOS_RAN=$((SCENARIOS_RAN + 1))
}

scenario_collapse_multi_level() {
  info "collapse: collapse multi-level descendants after multiple merges"
  reset_tmp_state

  local work_dir fake_bin remote_dir
  mapfile -t repo_info < <(create_repo collapse)
  work_dir="${repo_info[0]}"
  fake_bin="${repo_info[1]}"
  remote_dir="${repo_info[2]}"

  (
    cd "$work_dir"
    git checkout -q -b patch/a main
    printf 'base\na\n' > app.txt
    git commit -qam a
    git push -q origin HEAD

    git checkout -q -b patch/a--b
    printf 'base\na\nb\n' > app.txt
    git commit -qam b
    git push -q origin HEAD

    git checkout -q -b patch/a--b--c
    printf 'base\na\nb\nc\n' > app.txt
    git commit -qam c
    git push -q origin HEAD

    PATH="$fake_bin:$PATH" \
      LOCAL_REMOTE_DIR="$remote_dir" \
      DRY_RUN=false \
      GH_TOKEN=dummy \
      FORK_REPO=owner/repo \
      MERGED_PATCHES='patch/a,patch/a--b' \
      bash "$ROOT_DIR/scripts/workflow/cleanup-merged.sh"

    branches=$(branch_list)
    assert_eq 'patch/c' "$branches" "grandchild branch should collapse to its surviving suffix"

    remote_branches=$(git --git-dir="$remote_dir" for-each-ref --format='%(refname:short)' refs/heads/patch | sort)
    assert_eq 'patch/c' "$remote_branches" "remote grandchild branch should also collapse"
  )

  pass "collapse"
  SCENARIOS_RAN=$((SCENARIOS_RAN + 1))
}

scenario_empty_after_rebase() {
  info "empty: rebase drops an already-applied patch and rebuild skips empty squash"
  reset_tmp_state

  local work_dir fake_bin
  mapfile -t repo_info < <(create_repo empty)
  work_dir="${repo_info[0]}"
  fake_bin="${repo_info[1]}"

  (
    cd "$work_dir"

    git branch upstream/main main
    git checkout -q -b patch/already-applied upstream/main
    printf 'base\nfeature\n' > app.txt
    git commit -qam 'patch change'
    git push -q origin HEAD

    git checkout -q main
    git checkout -q upstream/main
    printf 'base\nfeature\n' > app.txt
    git commit -qam 'upstream equivalent change'
    git push -q origin HEAD:main
    git checkout -q main

    printf 'patch/already-applied\n' > /tmp/active_branches.txt
    printf 'patch/already-applied\n' > /tmp/sorted_branches.txt
    printf 'Already applied feature\n' > /tmp/meta_title_patch_already-applied
    printf '123\n' > /tmp/meta_num_patch_already-applied
    printf 'https://example.test/pr/123\n' > /tmp/meta_url_patch_already-applied
    printf 'PR body\n' > /tmp/meta_body_patch_already-applied

    DRY_RUN=false \
      UPSTREAM_BRANCH=main \
      FORK_MAIN=main \
      bash "$ROOT_DIR/scripts/workflow/rebase.sh"

    main_subject=$(git log -1 --format=%s main)
    assert_eq 'upstream equivalent change' "$main_subject" "main should stay at upstream when squash has no changes"

    patch_subject=$(git log -1 --format=%s patch/already-applied)
    assert_eq 'upstream equivalent change' "$patch_subject" "rebased patch should collapse to upstream-equivalent history"

    needs_claude=$(sed -n 's/^needs_claude=//p' "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true)
    if [[ -n "$needs_claude" ]]; then
      assert_eq 'false' "$needs_claude" "empty patch should not require Claude"
    fi
  )

  pass "empty"
  SCENARIOS_RAN=$((SCENARIOS_RAN + 1))
}

scenario_preserve_base_commits() {
  info "preserve: keep direct main commits and re-tag legacy patch rebuild commits"
  reset_tmp_state

  local work_dir fake_bin
  mapfile -t repo_info < <(create_repo preserve)
  work_dir="${repo_info[0]}"
  fake_bin="${repo_info[1]}"

  (
    cd "$work_dir"

    git branch upstream/main main

    git checkout -q main
    mkdir -p .github/workflows
    printf 'name: Patch Stack Sync\n' > .github/workflows/patch-stack-sync.yml
    git add .github/workflows/patch-stack-sync.yml
    git commit -q -m 'chore: add sync workflow'

    printf 'base\nfeature\n' > app.txt
    git add app.txt
    git commit -q -m 'Feature patch (#7)'
    git push -q origin HEAD:main

    git checkout -q -b patch/feature upstream/main
    printf 'base\nfeature\n' > app.txt
    git add app.txt
    git commit -q -m 'feature implementation'
    git push -q origin HEAD

    printf 'patch/feature\n' > /tmp/active_branches.txt
    printf 'patch/feature\n' > /tmp/sorted_branches.txt
    printf 'Feature patch\n' > /tmp/meta_title_patch_feature
    printf '7\n' > /tmp/meta_num_patch_feature
    printf 'https://example.test/pr/7\n' > /tmp/meta_url_patch_feature
    printf 'PR body\n' > /tmp/meta_body_patch_feature

    DRY_RUN=false \
      UPSTREAM_BRANCH=main \
      FORK_MAIN=main \
      bash "$ROOT_DIR/scripts/workflow/rebase.sh"

    subjects=$(git log --format=%s --max-count=2 main)
    expected_subjects=$'patch-stack: Feature patch (#7)\nchore: add sync workflow'
    assert_eq "$expected_subjects" "$subjects" "main should preserve base commit and regenerate patch commit with reserved prefix"

    patch_body=$(git log -1 --format=%B main)
    [[ "$patch_body" == *'Patch-Stack-Branch: patch/feature'* ]] \
      || fail "patch rebuild commit should record the source branch trailer"

    app_contents=$(cat app.txt)
    assert_eq $'base\nfeature' "$app_contents" "patch changes should be applied exactly once after rebuild"

    preserved=$(cat /tmp/preserved_main_commits.txt)
    assert_line_count 1 "$preserved" "only the direct main commit should be preserved"

    preserved_subject=$(git log -1 --format=%s "$(cat /tmp/preserved_main_commits.txt)")
    assert_eq 'chore: add sync workflow' "$preserved_subject" "legacy patch rebuild commit should not be preserved"
  )

  pass "preserve"
  SCENARIOS_RAN=$((SCENARIOS_RAN + 1))
}

run_named_scenario() {
  case "$1" in
    rename)
      scenario_rename_descendant
      ;;
    collapse)
      scenario_collapse_multi_level
      ;;
    empty)
      scenario_empty_after_rebase
      ;;
    preserve)
      scenario_preserve_base_commits
      ;;
    all)
      scenario_rename_descendant
      scenario_collapse_multi_level
      scenario_empty_after_rebase
      scenario_preserve_base_commits
      ;;
    *)
      fail "unknown scenario: $1"
      ;;
  esac
}

main() {
  local scenario="${1:-all}"
  local github_output_file="$TMP_ROOT/github-output.txt"
  : > "$github_output_file"
  export GITHUB_OUTPUT="$github_output_file"

  run_named_scenario "$scenario"
  info "completed ${SCENARIOS_RAN} scenario(s)"
}

main "$@"
