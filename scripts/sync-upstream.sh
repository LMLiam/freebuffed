#!/usr/bin/env bash
#
# Sync changes from the Freebuff upstream mirror into a `sync/upstream` branch.
#
# The workflow .github/workflows/sync-upstream.yml runs this automatically.
# Use this script when the workflow reports a conflict, or to sync manually.
#
# On a clean apply it creates the branch, commits, and pushes. On conflicts it
# leaves conflict markers in the working tree for you to resolve.
#
# Usage:
#   bash scripts/sync-upstream.sh
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/CodebuffAI/freebuff.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
SYNC_BRANCH="${SYNC_BRANCH:-sync/upstream}"

EXCLUDES=(
  ':(exclude).github'
  ':(exclude).coderabbit.yaml'
  ':(exclude)FORK.md'
  ':(exclude)README.md'
  ':(exclude)README.zh-CN.md'
  ':(exclude)UPSTREAM_VERSION'
  ':(exclude)UPSTREAM_SHA'
  ':(exclude)release-please-config.json'
  ':(exclude).release-please-manifest.json'
  ':(exclude)CHANGELOG.md'
  ':(exclude)scripts/sync-upstream.sh'
)

cd "$(git rev-parse --show-toplevel)"

branch=$(git branch --show-current)
if [[ "$branch" != "main" ]]; then
  echo "error: run from main (currently on $branch)" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean — commit or stash your changes first" >&2
  exit 1
fi

marker=$(cat UPSTREAM_SHA 2>/dev/null || true)
if [[ -z "$marker" ]]; then
  echo "error: UPSTREAM_SHA is empty — set it to the upstream commit this tree is based on" >&2
  exit 1
fi

echo "Fetching $UPSTREAM_URL $UPSTREAM_BRANCH ..."
git fetch --filter=blob:none --no-tags "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
upstream_sha=$(git rev-parse FETCH_HEAD)

if [[ "$upstream_sha" == "$marker" ]]; then
  echo "Up to date (marker ${marker:0:8})"
  exit 0
fi
echo "New upstream commits: ${marker:0:8} -> ${upstream_sha:0:8}"

git diff "$marker" FETCH_HEAD -- . "${EXCLUDES[@]}" > /tmp/upstream-sync.patch
if [[ ! -s /tmp/upstream-sync.patch ]]; then
  echo "No upstream changes outside the fork-local paths"
  exit 0
fi

if git branch --list "$SYNC_BRANCH" | grep -q .; then
  echo "error: local branch $SYNC_BRANCH already exists" >&2
  echo "  if it is a leftover:  git branch -D $SYNC_BRANCH" >&2
  echo "  if you are resolving: git switch $SYNC_BRANCH and continue manually" >&2
  exit 1
fi
git switch -c "$SYNC_BRANCH"

if git apply --check /tmp/upstream-sync.patch; then
  git apply /tmp/upstream-sync.patch
  npm_version=$(curl -s https://registry.npmjs.org/freebuff/latest | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")
  echo "$upstream_sha" > UPSTREAM_SHA
  echo "$npm_version" > UPSTREAM_VERSION
  git add -A
  git commit -m "chore(upstream): sync freebuff ${npm_version}"
  git push -u origin "$SYNC_BRANCH"
  echo
  echo "Pushed $SYNC_BRANCH. Open or update the pull request with:"
  echo "  gh pr create --base main --head $SYNC_BRANCH --title \"chore(upstream): sync freebuff ${npm_version}\""
else
  echo
  echo "Upstream changes conflict with fork changes. Resolving with a 3-way merge..."
  git apply --3way /tmp/upstream-sync.patch || true
  echo
  echo "Conflict markers are in the working tree. Resolve them, then:"
  echo "  echo '$upstream_sha' > UPSTREAM_SHA"
  echo "  echo '<npm version>' > UPSTREAM_VERSION"
  echo "  git add -A"
  echo "  git commit -m 'chore(upstream): sync freebuff <version>'"
  echo "  git push -u origin $SYNC_BRANCH"
  exit 1
fi
