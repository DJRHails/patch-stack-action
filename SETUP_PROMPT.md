# Patch-Stack Setup Prompt

Copy the prompt below into a Claude Code session (or any AI coding assistant) at the root of your **fork** repository to automate the full patch-stack setup: workflow file, README fork note, and CLAUDE.md documentation.

Replace the placeholder values before running.

---

## Prompt

```
Set up a patch-stack fork workflow for this repository.

**Context:**
- Upstream repo: <UPSTREAM_OWNER>/<UPSTREAM_REPO>
- Fork repo: <FORK_OWNER>/<FORK_REPO>
- Upstream branch to track: main
- Fork integration branch: main
- Fork upstream mirror branch: upstream

**Tasks:**

1. Create `.github/workflows/patch-stack-sync.yml` with this content:

   ```yaml
   name: Patch Stack Sync

   on:
     schedule:
       - cron: "0 4 * * *" # nightly at 4am UTC
     workflow_dispatch:
       inputs:
         dry_run:
           description: "Dry run — preview only, no pushes or PR mutations"
           type: boolean
           default: false

   jobs:
     sync:
       uses: DJRHails/patch-stack-action/.github/workflows/patch-stack-sync.yml@main
       with:
         upstream_repo: <UPSTREAM_OWNER>/<UPSTREAM_REPO>
         upstream_branch: main
         fork_repo: <FORK_OWNER>/<FORK_REPO>
         fork_main: main
         fork_upstream_branch: upstream
         dry_run: ${{ inputs.dry_run || false }}
       secrets:
         app_id: ${{ secrets.PATCH_STACK_APP_ID }}
         app_private_key: ${{ secrets.PATCH_STACK_APP_PRIVATE_KEY }}
         claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
   ```

2. Add a fork note to the top of README.md (after the title/heading):

   ```markdown
   > **Fork note — patch-stack workflow:**
   > This is a patch-stack fork of [<UPSTREAM_OWNER>/<UPSTREAM_REPO>](https://github.com/<UPSTREAM_OWNER>/<UPSTREAM_REPO>), managed by [DJRHails/patch-stack-action](https://github.com/DJRHails/patch-stack-action).
   >
   > **How it works:**
   > - The `upstream` branch mirrors upstream `main` nightly (4 AM UTC via [patch-stack-sync](.github/workflows/patch-stack-sync.yml)).
   > - Each `patch/*` branch holds a single logical change rebased automatically onto `upstream`.
   > - The fork's `main` integrates all patches via squash-merge PRs (commits prefixed `patch-stack:`).
   > - Merge conflicts during rebase are resolved automatically using Claude Code.
   >
   > **Adding a new patch:**
   > 1. Create a branch: `git checkout -b patch/my-feature upstream`
   > 2. Make your changes and push: `git push origin patch/my-feature`
   > 3. The nightly sync will rebase it onto upstream, create a PR, and squash-merge it into `main`.
   >
   > **Current patches:** _(none yet)_
   ```

3. If a CLAUDE.md (or AGENTS.md) file exists, add a "Patch-Stack Fork Workflow" section near the top with:

   - Branch layout table (`upstream`, `patch/*`, `main`)
   - How nightly sync works (mirror, rebase, rebuild, cleanup)
   - How to create a new patch
   - Patch dependency naming convention (`--` separators)
   - Current patches list (empty initially)
   - Commit conventions (`patch-stack: <desc> (#PR)`)
   - Required secrets table (PATCH_STACK_APP_ID, PATCH_STACK_APP_PRIVATE_KEY, CLAUDE_CODE_OAUTH_TOKEN)
   - Guidelines: don't manually merge patch branches, don't manually rebase main, fork-specific infra goes directly on main

4. Create the upstream mirror branch:

   ```bash
   git remote add upstream https://github.com/<UPSTREAM_OWNER>/<UPSTREAM_REPO>.git || true
   git fetch upstream main
   git branch upstream upstream/main
   git push origin upstream
   ```

5. Commit all changes on `main` with message:
   `chore: set up patch-stack fork workflow`

**Required GitHub setup (manual steps):**
- Create a GitHub App with Contents (R&W) and Pull requests (R&W) permissions
- Install it on the fork repo (and optionally on upstream for PR comments)
- Add repo secrets: PATCH_STACK_APP_ID, PATCH_STACK_APP_PRIVATE_KEY
- Run `claude setup-token` locally and add as CLAUDE_CODE_OAUTH_TOKEN secret
```
