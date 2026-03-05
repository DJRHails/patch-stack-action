#!/usr/bin/env bash
# Seed test repos for patch-stack-action integration testing.
#
# Resets DJRHails/patch-stack-test-upstream and
# DJRHails/patch-stack-test-fork to a known state with:
#   - 3 active patch branches (one clean, one dependent, one conflicting)
#   - 1 merged patch branch
#   - 1 superseded patch branch
#   - PRs on upstream for each patch
#   - Upstream evolution (merge, conflict, supersede)
#
# Usage: bash scripts/dev/seed-test-repos.sh [--skip-cleanup]
#
# Requires: gh CLI authenticated, git

set -euo pipefail

UPSTREAM_REPO="DJRHails/patch-stack-test-upstream"
FORK_REPO="DJRHails/patch-stack-test-fork"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Patch Stack Test Repo Seeder ==="
echo "Work dir: $WORK_DIR"
echo ""

# ── Helpers ──────────────────────────────────────────────────────

commit_file() {
  local file="$1" content="$2" msg="$3"
  mkdir -p "$(dirname "$file")"
  printf '%s' "$content" > "$file"
  git add "$file"
  git commit -m "$msg" --quiet
}

# ── Step 0: Clean up existing PRs and branches ───────────────────

if [[ "${1:-}" != "--skip-cleanup" ]]; then
  echo "-- Cleaning up existing PRs on upstream --"
  # Close all open PRs
  gh pr list --repo "$UPSTREAM_REPO" --state open --json number \
    --jq '.[].number' | while read -r num; do
    echo "  Closing PR #$num"
    gh pr close "$num" --repo "$UPSTREAM_REPO" 2>/dev/null || true
  done

  echo "-- Deleting remote patch/* and archived/* branches --"
  for repo in "$UPSTREAM_REPO" "$FORK_REPO"; do
    echo "  Repo: $repo"
    gh api "repos/$repo/git/refs" --paginate --jq \
      '.[] | select(.ref | test("refs/heads/(patch|archived)/")) | .ref' \
      2>/dev/null | while read -r ref; do
      branch="${ref#refs/heads/}"
      echo "    Deleting $branch"
      gh api -X DELETE "repos/$repo/git/refs/heads/$branch" \
        2>/dev/null || true
    done
  done
  echo ""
fi

# ── Step 1: Seed upstream with base project ──────────────────────

echo "-- Step 1: Seeding upstream repo --"
cd "$WORK_DIR"
mkdir upstream && cd upstream
git init -b main --quiet
git remote add origin "git@github.com:${UPSTREAM_REPO}.git"

git config user.name "upstream-dev"
git config user.email "upstream-dev@test.local"

mkdir -p src docs

cat > src/index.ts << 'SRCEOF'
import { loadConfig } from "./config";
import { formatMessage } from "./utils";

const config = loadConfig();

function main(): void {
  const msg = formatMessage("Server starting", config.prefix);
  process.stdout.write(msg + "\n");

  const server = Bun.serve({
    port: config.port,
    fetch(req: Request): Response {
      const url = new URL(req.url);
      if (url.pathname === "/health") {
        return new Response("ok");
      }
      const body = formatMessage(
        `${req.method} ${url.pathname}`,
        config.prefix,
      );
      return new Response(body, { status: 200 });
    },
  });

  process.stdout.write(
    `Listening on http://localhost:${server.port}\n`,
  );
}

main();
SRCEOF
git add src/index.ts

cat > src/config.ts << 'SRCEOF'
export interface AppConfig {
  port: number;
  prefix: string;
  environment: string;
}

export function loadConfig(): AppConfig {
  return {
    port: Number(process.env.PORT) || 3000,
    prefix: process.env.APP_PREFIX || "app",
    environment: process.env.NODE_ENV || "development",
  };
}
SRCEOF
git add src/config.ts

cat > src/utils.ts << 'SRCEOF'
export function formatMessage(
  message: string,
  prefix: string,
): string {
  const timestamp = new Date().toISOString();
  return `[${timestamp}] [${prefix}] ${message}`;
}

export function slugify(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}
SRCEOF
git add src/utils.ts

cat > docs/guide.md << 'SRCEOF'
# Getting Started

## Installation

```bash
bun install
```

## Running

```bash
bun run src/index.ts
```

## Configuration

Set these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | Server port |
| `APP_PREFIX` | `app` | Log prefix |
| `NODE_ENV` | `development` | Environment |

## API

- `GET /health` — returns `ok`
- `GET /*` — echoes the request method and path
SRCEOF
git add docs/guide.md

git commit -m "Initial project setup" --quiet
git push --force origin main --quiet
BASE_SHA=$(git rev-parse HEAD)
echo "  Upstream base: $BASE_SHA"

# ── Step 2: Mirror to fork ───────────────────────────────────────

echo ""
echo "-- Step 2: Mirroring content to fork --"
cd "$WORK_DIR"
mkdir fork && cd fork
git init -b main --quiet
git remote add origin "git@github.com:${FORK_REPO}.git"
git remote add upstream "git@github.com:${UPSTREAM_REPO}.git"

git config user.name "patch-author"
git config user.email "patch-author@test.local"

# Pull upstream's fresh main (single commit)
git fetch upstream main --quiet
git reset --hard upstream/main
git push --force origin main --quiet
echo "  Fork synced to upstream main"

# ── Step 3: Create patch branches on fork ────────────────────────

echo ""
echo "-- Step 3: Creating patch branches --"

# 3a: patch/add-logging — adds structured logging to index.ts
echo "  Creating patch/add-logging..."
git checkout -b patch/add-logging main --quiet
cat > src/index.ts << 'SRCEOF'
import { loadConfig } from "./config";
import { formatMessage, log } from "./utils";

const config = loadConfig();

function main(): void {
  log("info", "Server starting", { port: config.port });

  const server = Bun.serve({
    port: config.port,
    fetch(req: Request): Response {
      const url = new URL(req.url);
      log("info", "Request received", {
        method: req.method,
        path: url.pathname,
      });

      if (url.pathname === "/health") {
        return new Response("ok");
      }
      const body = formatMessage(
        `${req.method} ${url.pathname}`,
        config.prefix,
      );
      return new Response(body, { status: 200 });
    },
  });

  log("info", "Server ready", {
    url: `http://localhost:${server.port}`,
  });
}

main();
SRCEOF
git add src/index.ts

# Also add the log function to utils
cat > src/utils.ts << 'SRCEOF'
export function formatMessage(
  message: string,
  prefix: string,
): string {
  const timestamp = new Date().toISOString();
  return `[${timestamp}] [${prefix}] ${message}`;
}

export function slugify(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

export type LogLevel = "debug" | "info" | "warn" | "error";

export function log(
  level: LogLevel,
  message: string,
  data?: Record<string, unknown>,
): void {
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    ...data,
  };
  const output = JSON.stringify(entry);
  if (level === "error") {
    process.stderr.write(output + "\n");
  } else {
    process.stdout.write(output + "\n");
  }
}
SRCEOF
git add src/utils.ts
git commit -m "Add structured JSON logging" --quiet
echo "    Done"

# 3b: patch/add-logging--improve-format — depends on add-logging
echo "  Creating patch/add-logging--improve-format..."
git checkout -b patch/add-logging--improve-format patch/add-logging \
  --quiet
cat > src/utils.ts << 'SRCEOF'
export function formatMessage(
  message: string,
  prefix: string,
): string {
  const timestamp = new Date().toISOString();
  return `[${timestamp}] [${prefix}] ${message}`;
}

export function slugify(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

export type LogLevel = "debug" | "info" | "warn" | "error";

const LEVEL_COLORS: Record<LogLevel, string> = {
  debug: "\x1b[90m",
  info: "\x1b[36m",
  warn: "\x1b[33m",
  error: "\x1b[31m",
};
const RESET = "\x1b[0m";

export function log(
  level: LogLevel,
  message: string,
  data?: Record<string, unknown>,
): void {
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    ...data,
  };
  const color = LEVEL_COLORS[level];
  const output = `${color}${JSON.stringify(entry)}${RESET}`;
  if (level === "error") {
    process.stderr.write(output + "\n");
  } else {
    process.stdout.write(output + "\n");
  }
}
SRCEOF
git add src/utils.ts
git commit -m "Add color coding to log output" --quiet
echo "    Done"

# 3c: patch/fix-config — modifies config.ts (will conflict later)
echo "  Creating patch/fix-config..."
git checkout -b patch/fix-config main --quiet
cat > src/config.ts << 'SRCEOF'
export interface AppConfig {
  port: number;
  prefix: string;
  environment: string;
  debug: boolean;
}

export function loadConfig(): AppConfig {
  const env = process.env.NODE_ENV || "development";
  return {
    port: Number(process.env.PORT) || 3000,
    prefix: process.env.APP_PREFIX || "app",
    environment: env,
    debug: env === "development",
  };
}
SRCEOF
git add src/config.ts
git commit -m "Add debug flag derived from environment" --quiet
echo "    Done"

# 3d: patch/already-merged — simple docs change (will be merged)
echo "  Creating patch/already-merged..."
git checkout -b patch/already-merged main --quiet
cat >> docs/guide.md << 'SRCEOF'

## Logging

The server outputs structured JSON logs to stdout. Error-level
messages go to stderr. Set `LOG_LEVEL` to control verbosity.
SRCEOF
git add docs/guide.md
git commit -m "Document logging behavior" --quiet
echo "    Done"

# 3e: patch/already-upstream — adds slugify export (will be
#     independently added to upstream, making this superseded)
echo "  Creating patch/already-upstream..."
git checkout -b patch/already-upstream main --quiet
cat > src/index.ts << 'SRCEOF'
import { loadConfig } from "./config";
import { formatMessage, slugify } from "./utils";

const config = loadConfig();

function main(): void {
  const msg = formatMessage("Server starting", config.prefix);
  process.stdout.write(msg + "\n");

  const server = Bun.serve({
    port: config.port,
    fetch(req: Request): Response {
      const url = new URL(req.url);
      if (url.pathname === "/health") {
        return new Response("ok");
      }
      const slug = slugify(url.pathname);
      const body = formatMessage(
        `${req.method} /${slug}`,
        config.prefix,
      );
      return new Response(body, { status: 200 });
    },
  });

  process.stdout.write(
    `Listening on http://localhost:${server.port}\n`,
  );
}

main();
SRCEOF
git add src/index.ts
git commit -m "Use slugify for request path normalization" --quiet
echo "    Done"

# Push all patch branches to fork
echo ""
echo "  Pushing all patch branches to fork..."
git checkout main --quiet
git push origin \
  patch/add-logging \
  patch/add-logging--improve-format \
  patch/fix-config \
  patch/already-merged \
  patch/already-upstream \
  --force --quiet
echo "    All branches pushed to fork"

# ── Step 4: Push branches to upstream and create PRs ─────────────

echo ""
echo "-- Step 4: Pushing branches to upstream and creating PRs --"
cd "$WORK_DIR/upstream"

# Fetch from fork to get the patch branches
git remote add fork "git@github.com:${FORK_REPO}.git" 2>/dev/null \
  || git remote set-url fork "git@github.com:${FORK_REPO}.git"
git fetch fork '+refs/heads/patch/*:refs/heads/patch/*' --quiet

# Push all patch branches to upstream
git push origin \
  patch/add-logging \
  patch/add-logging--improve-format \
  patch/fix-config \
  patch/already-merged \
  patch/already-upstream \
  --force --quiet
echo "  Branches pushed to upstream"

# Create PRs
echo "  Creating PRs..."

create_pr() {
  local branch="$1" title="$2" body="$3"
  # Check if PR already exists
  existing=$(gh pr list --repo "$UPSTREAM_REPO" \
    --head "$branch" --state open --json number --jq 'length')
  if [[ "$existing" -gt 0 ]]; then
    echo "    PR for $branch already exists, skipping"
    return
  fi
  gh pr create \
    --repo "$UPSTREAM_REPO" \
    --head "$branch" \
    --base main \
    --title "$title" \
    --body "$body"
  echo "    Created PR: $title"
}

create_pr "patch/add-logging" \
  "Add structured JSON logging" \
  "$(cat << 'PREOF'
## Summary

Adds structured JSON logging throughout the application:
- New `log()` function in utils with level, message, and data
- Replaces `formatMessage` calls in index.ts with structured logging
- Error-level logs go to stderr, everything else to stdout

## Test plan

- [ ] Run server and verify JSON log output
- [ ] Check error logs go to stderr
PREOF
)"

create_pr "patch/add-logging--improve-format" \
  "Add color coding to log output" \
  "$(cat << 'PREOF'
## Summary

Builds on the structured logging PR to add ANSI color coding:
- Debug: gray, Info: cyan, Warn: yellow, Error: red
- Colors wrap the full JSON output line

Depends on: patch/add-logging

## Test plan

- [ ] Run in terminal and verify colored output
PREOF
)"

create_pr "patch/fix-config" \
  "Add debug flag derived from environment" \
  "$(cat << 'PREOF'
## Summary

Adds a `debug` boolean to AppConfig that is automatically set
based on the NODE_ENV value. When environment is "development",
debug is true.

## Test plan

- [ ] Verify debug=true in development
- [ ] Verify debug=false in production
PREOF
)"

create_pr "patch/already-merged" \
  "Document logging behavior" \
  "$(cat << 'PREOF'
## Summary

Adds a "Logging" section to docs/guide.md describing the
structured JSON log output and LOG_LEVEL configuration.

## Test plan

- [ ] Review rendered markdown
PREOF
)"

create_pr "patch/already-upstream" \
  "Use slugify for request path normalization" \
  "$(cat << 'PREOF'
## Summary

Imports and uses the existing `slugify` utility to normalize
request paths before logging/responding. This makes paths
consistent (lowercase, no special chars).

## Test plan

- [ ] Request /Foo/BAR and verify response uses /foo-bar
PREOF
)"

# ── Step 5: Merge one PR and evolve upstream ─────────────────────

echo ""
echo "-- Step 5: Evolving upstream --"

# 5a: Merge the already-merged PR
echo "  Merging patch/already-merged PR..."
pr_num=$(gh pr list --repo "$UPSTREAM_REPO" \
  --head "patch/already-merged" --state open \
  --json number --jq '.[0].number')
if [[ -n "$pr_num" ]]; then
  gh pr merge "$pr_num" --repo "$UPSTREAM_REPO" --squash \
    --delete-branch
  echo "    Merged PR #$pr_num"
else
  echo "    No open PR found for patch/already-merged"
fi

# 5b: Fetch the merge, then add conflicting + superseding commits
git fetch origin main --quiet
git reset --hard origin/main

# Conflict: change config.ts on same lines as patch/fix-config
cat > src/config.ts << 'SRCEOF'
export interface AppConfig {
  port: number;
  prefix: string;
  environment: string;
  verbose: boolean;
}

export function loadConfig(): AppConfig {
  const env = process.env.NODE_ENV || "development";
  return {
    port: Number(process.env.PORT) || 3000,
    prefix: process.env.APP_PREFIX || "app",
    environment: env,
    verbose: process.env.VERBOSE === "true",
  };
}
SRCEOF
git add src/config.ts
git commit -m "Add verbose flag to config" --quiet
echo "  Added conflicting config change (verbose vs debug)"

# Supersede: independently add the same slugify usage
cat > src/index.ts << 'SRCEOF'
import { loadConfig } from "./config";
import { formatMessage, slugify } from "./utils";

const config = loadConfig();

function main(): void {
  const msg = formatMessage("Server starting", config.prefix);
  process.stdout.write(msg + "\n");

  const server = Bun.serve({
    port: config.port,
    fetch(req: Request): Response {
      const url = new URL(req.url);
      if (url.pathname === "/health") {
        return new Response("ok");
      }
      const slug = slugify(url.pathname);
      const body = formatMessage(
        `${req.method} /${slug}`,
        config.prefix,
      );
      return new Response(body, { status: 200 });
    },
  });

  process.stdout.write(
    `Listening on http://localhost:${server.port}\n`,
  );
}

main();
SRCEOF
git add src/index.ts
git commit -m "Normalize request paths with slugify" --quiet
echo "  Added superseding slugify change"

git push origin main --quiet
echo "  Upstream main pushed"

# ── Step 6: Install caller workflow on fork ──────────────────────

echo ""
echo "-- Step 6: Installing caller workflow on fork --"
cd "$WORK_DIR/fork"
# Reset to upstream (which now has the evolved main)
git fetch upstream main --quiet
git reset --hard upstream/main

mkdir -p .github/workflows
cat > .github/workflows/patch-stack-sync.yml << 'WFEOF'
name: Patch Stack Sync

on:
  schedule:
    - cron: '0 2 * * *'
  workflow_dispatch:
    inputs:
      dry_run:
        description: 'Dry run — preview only, no pushes or PR mutations'
        type: boolean
        default: false

jobs:
  sync:
    uses: DJRHails/patch-stack-action/.github/workflows/patch-stack-sync.yml@main
    with:
      upstream_repo: DJRHails/patch-stack-test-upstream
      upstream_branch: main
      fork_repo: DJRHails/patch-stack-test-fork
      fork_main: main
      dry_run: ${{ inputs.dry_run || false }}
    secrets:
      app_id: ${{ secrets.PATCH_STACK_APP_ID }}
      app_private_key: ${{ secrets.PATCH_STACK_APP_PRIVATE_KEY }}
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
WFEOF
git add .github/workflows/patch-stack-sync.yml
git commit -m "Add patch-stack-sync caller workflow" --quiet
git push --force origin main --quiet
echo "  Caller workflow installed"

# ── Done ─────────────────────────────────────────────────────────

echo ""
echo "=== Setup complete ==="
echo ""
echo "Upstream: https://github.com/$UPSTREAM_REPO"
echo "Fork:    https://github.com/$FORK_REPO"
echo ""
echo "Patch branches:"
echo "  patch/add-logging              — ACTIVE (clean rebase)"
echo "  patch/add-logging--improve-format — ACTIVE (depends on add-logging)"
echo "  patch/fix-config               — ACTIVE (will conflict)"
echo "  patch/already-merged           — MERGED (PR merged)"
echo "  patch/already-upstream         — SUPERSEDED (code in upstream)"
echo ""
echo "Next steps:"
echo "  1. Set up GitHub App and add secrets (see README)"
echo "  2. Test with: gh workflow run patch-stack-sync.yml \\"
echo "       --repo $FORK_REPO -f dry_run=true"
