# patch-stack-action

A reusable GitHub Actions workflow that maintains a fork where `main` always equals **a fork-local upstream mirror + preserved fork-only base commits + your in-flight patches applied in order**.

Each patch corresponds to an open PR on the upstream repo. On each run the workflow:

1. **Discovers** all `patch/*` branches in your fork
2. **Checks** whether each patch's upstream PR has been merged or the problem fixed another way
3. **Mirrors** `upstream/main` into a fork-local `upstream` branch for PR bases
4. **Rebases** each patch branch onto its parent (or the fork-local `upstream` branch for roots)
5. **Rebuilds** `fork/main` = fork-local upstream mirror + preserved fork-only base commits + patches in topological order
6. **Resolves conflicts** using Claude Code when git can't do it cleanly
7. **Closes and archives** patches whose upstream PRs are superseded

## Repo structure

```
patch-stack-action/                  ← this repo (public, reusable)
  .github/workflows/
    patch-stack-sync.yml             ← the reusable workflow

your-fork/
  .github/workflows/
    patch-stack-sync.yml             ← 20-line caller (copy from example-caller.yml)
```

## Branch naming

Dependencies are encoded in the branch name using `--` as a separator. No config file needed.

```
patch/fix-auth                              # root — rebases onto fork/upstream
patch/fix-auth--improve-token-refresh       # depends on fix-auth
patch/fix-auth--improve-token-refresh--cleanup  # depends on improve-token-refresh
patch/perf-improvement                      # independent root
```

The parent of any branch is its name with the last `--segment` stripped.
Roots (no `--`) rebase directly onto the fork-local `upstream` mirror branch, which is force-updated to match `upstream/main` on every run.

When a PR is merged upstream → branch is deleted.
When upstream fixes the same problem another way → PR is closed, branch renamed to `archived/*`.

## Rebuild model

On each rebuild, the workflow treats `fork/main` as:

```text
fork/upstream + preserved base commits + patch-stack commits
```

Preserved base commits are commits already on `fork/main` that do not look like patch-stack-generated squash commits. This makes it possible to keep local fork plumbing, such as `.github/workflows/patch-stack-sync.yml`, directly on `main` while still rebuilding the patch stack on top.

Patch-stack-generated rebuild commits use the reserved subject prefix `patch-stack: ` and include a `Patch-Stack-Branch:` trailer in the commit body so future runs can distinguish them from preserved base commits.

The workflow also maintains a fork-local `upstream` branch that mirrors the tracked upstream branch. Root patch PRs can target this branch, while dependent patches can target their parent patch branch, so the whole stack is visible in the fork's GitHub UI.

## Usage

Copy `example-caller.yml` into your fork at `.github/workflows/patch-stack-sync.yml` and update the two repo inputs:

```yaml
jobs:
  sync:
    uses: DJRHails/patch-stack-action/.github/workflows/patch-stack-sync.yml@main
    with:
      upstream_repo: vercel-labs/agent-browser   # ← change this
      fork_repo: djrhails/agent-browser           # ← change this
      fork_upstream_branch: upstream              # ← optional, defaults to "upstream"
    secrets:
      app_id: ${{ secrets.PATCH_STACK_APP_ID }}
      app_private_key: ${{ secrets.PATCH_STACK_APP_PRIVATE_KEY }}
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `upstream_repo` | ✅ | — | `owner/repo` of the upstream |
| `upstream_branch` | | `main` | Branch to track on upstream |
| `fork_repo` | ✅ | — | `owner/repo` of your fork |
| `fork_main` | | `main` | Fork branch to keep rebuilt |
| `fork_upstream_branch` | | `upstream` | Fork branch that mirrors the tracked upstream branch and serves as the base for root patch PRs |
| `dry_run` | | `false` | Preview without pushing or closing PRs |

## Secrets

| Secret | Description |
|--------|-------------|
| `app_id` | GitHub App ID |
| `app_private_key` | GitHub App private key |
| `claude_code_oauth_token` | Claude Code OAuth token (Pro/Max subscription). Generate with `claude setup-token` |

## Setup

### 1. Create a GitHub App

A GitHub App token is required for the fork (not `GITHUB_TOKEN`) for three reasons:
- Pushes made by the action can trigger other workflows
- Fetching and pushing the fork even when it is private
- Cron-triggered runs — OIDC token exchange [fails on scheduled workflows](https://github.com/anthropics/claude-code-action/issues/814); passing a pre-generated App token via `github_token` bypasses this entirely

**Permissions needed:**
- Contents: Read & Write
- Pull requests: Read & Write
- Metadata: Read (auto-granted)

**Install the app on:**
- Your fork (required)
- The upstream repo (optional)

If the upstream repo is public, the workflow can fetch it anonymously even when the app is not installed there.

Without an upstream installation, the workflow can still:
- fetch upstream commits
- discover PR metadata on public upstream repos
- rebase patches and rebuild `fork/main`

Without an upstream installation, the workflow cannot:
- comment on upstream PRs when a patch is superseded
- close upstream PRs automatically
- access private upstream repos

Add to your fork's repository secrets:
- `PATCH_STACK_APP_ID`
- `PATCH_STACK_APP_PRIVATE_KEY`

### 2. Add Claude Code OAuth token

Generate a token locally with `claude setup-token`, then add it as `CLAUDE_CODE_OAUTH_TOKEN` in your fork's repository secrets.

### 3. Copy the caller workflow

```
cp example-caller.yml your-fork/.github/workflows/patch-stack-sync.yml
```

Edit `upstream_repo` and `fork_repo` (and optionally `fork_upstream_branch`), commit, push.

### 4. Open PRs from patch branches

Create branches named `patch/<description>` in your fork and open PRs from them against the upstream repo. The automation handles the rest.

If you also want the stack visible inside your fork, create fork-local PRs that follow the same dependency graph:

```bash
# Root patch
gh pr create \
  --repo your-fork/your-repo \
  --head patch/my-feature \
  --base upstream

# Dependent patch
gh pr create \
  --repo your-fork/your-repo \
  --head patch/my-feature--enhancement \
  --base patch/my-feature
```

## Converting a standard fork to a patch-stack fork

If you already have a fork where you've been making changes directly on `main`, follow these steps to restructure it into a patch stack.

### 1. Identify your changes

List the commits on your fork that are not in upstream:

```bash
git fetch upstream main
git log --oneline upstream/main..main
```

Group related commits into logical patches — each group will become one `patch/*` branch.

### 2. Create patch branches

For each group of changes, create a patch branch based on upstream/main:

```bash
# Start from upstream
git checkout upstream/main

# Create a branch for your first patch
git checkout -b patch/my-feature

# Cherry-pick the relevant commits
git cherry-pick abc1234 def5678

# Push to your fork
git push origin patch/my-feature
```

For dependent patches (changes that build on another patch), use the `--` naming convention:

```bash
git checkout patch/my-feature
git checkout -b patch/my-feature--enhancement
git cherry-pick ghi9012
git push origin patch/my-feature--enhancement
```

### 3. Open PRs on upstream

For each patch branch, push it to the upstream repo and create a PR:

```bash
# Push the branch to upstream
git push upstream patch/my-feature

# Create the PR
gh pr create \
  --repo owner/upstream-repo \
  --head patch/my-feature \
  --base main \
  --title "Add my feature" \
  --body "Description of the feature..."
```

### 4. Install the automation

Follow the [Setup](#setup) section above to create a GitHub App, add secrets, and copy the caller workflow into `.github/workflows/patch-stack-sync.yml`.

### 5. Reset fork/main

Once everything is in place, reset your fork's `main` to match the automated output:

```bash
# Let the workflow do its first run
gh workflow run patch-stack-sync.yml -f dry_run=true

# Verify the output, then run for real
gh workflow run patch-stack-sync.yml
```

After the first successful run, your fork's `main` will be rebuilt as `fork/upstream + patches` and future syncs are fully automated.

### Tips

- **One PR per patch branch** — each patch branch should map to exactly one upstream PR
- **Keep patches independent when possible** — independent patches can be reordered or dropped without affecting each other
- **Use dependency chains sparingly** — `patch/a--b--c` means all three must succeed; a conflict in `a` blocks `b` and `c`
- **Write clear PR descriptions** — Claude Code reads these to understand intent when resolving conflicts

## Local simulations

For shell-script edge cases, there is a local harness that creates temporary bare repos and runs the workflow scripts against them without GitHub access:

```bash
bash scripts/dev/local-simulations.sh
```

Run a single scenario by name:

```bash
bash scripts/dev/local-simulations.sh rename
bash scripts/dev/local-simulations.sh collapse
bash scripts/dev/local-simulations.sh empty
bash scripts/dev/local-simulations.sh preserve
```

Current scenarios cover:

- descendant branch collapse after a merged parent (`patch/merged-pr--child-pr` → `patch/child-pr`)
- multi-level collapse when several ancestors are merged
- empty-after-rebase patches that should not fail the `fork/main` rebuild
- preserved direct commits on `main` while legacy patch rebuild commits are regenerated with the `patch-stack:` prefix

The harness uses a fake local `gh` binary to emulate branch rename API calls and asserts on the resulting local and bare-remote refs.

Workflow runtime scripts live in [`scripts/workflow/`](/Users/dh/projects/github.com/DJRHails/patch-stack-action/scripts/workflow), while developer-only tooling lives in [`scripts/dev/`](/Users/dh/projects/github.com/DJRHails/patch-stack-action/scripts/dev).

## Notes on Claude Code auth

`claude-code-action` defaults to OIDC token exchange for GitHub auth. This **fails on cron-triggered runs** with a 401. We bypass it by passing the pre-generated App token directly as `github_token` — Claude Code then uses that instead of attempting OIDC.
