#!/usr/bin/env bash
#
# Sync changes from the Freebuff upstream mirror into a `sync/upstream`
# branch, then open or update the sync pull request.
#
# The workflow .github/workflows/sync-upstream.yml runs this.
#
# Conflicts stay in the pull request. The sync applies upstream changes with a
# three-way merge: files that both sides changed are left with conflict
# markers, the result is committed and pushed, and the pull request opens with
# the conflicts visible. Resolve the markers in the pull request and push a
# follow-up commit.
#
# Usage:
#   bash .github/scripts/sync-upstream.sh
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/CodebuffAI/freebuff.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
SYNC_BRANCH="${SYNC_BRANCH:-sync/upstream}"
REPO="${GITHUB_REPOSITORY:-LMLiam/freebuffed}"
COMMIT_NAME="${SYNC_COMMIT_NAME:-freebuffed[bot]}"
COMMIT_EMAIL="${SYNC_COMMIT_EMAIL:-freebuffed[bot]@users.noreply.github.com}"

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

marker=$(tr -d '[:space:]' < UPSTREAM_SHA 2>/dev/null || true)
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

git diff --full-index "$marker" FETCH_HEAD -- . "${EXCLUDES[@]}" > /tmp/upstream-sync.patch
if [[ ! -s /tmp/upstream-sync.patch ]]; then
  echo "No upstream changes outside the fork-local paths"
  exit 0
fi

remote_tip=$(git ls-remote origin "refs/heads/$SYNC_BRANCH" | awk '{print $1}')
if [[ -n "$remote_tip" ]]; then
  tip_name=$(git log -1 --format='%cn' "$remote_tip" 2>/dev/null || true)
  if [[ "$tip_name" != "$COMMIT_NAME" ]]; then
    echo "Sync branch $SYNC_BRANCH has manual changes (tip by ${tip_name:-unknown}) — not overwriting."
    if gh pr view "$SYNC_BRANCH" --json number --jq '.number' >/dev/null 2>&1; then
      if ! gh pr view "$SYNC_BRANCH" --json comments --jq '.comments[].body' 2>/dev/null | grep -q "has manual changes"; then
        gh pr comment "$SYNC_BRANCH" --body "The bot paused: $SYNC_BRANCH has manual changes and will not be overwritten. Merge the pull request when ready — the next sync resumes once the marker advances."
      fi
    fi
    exit 0
  fi
fi

if git branch --list "$SYNC_BRANCH" | grep -q .; then
  echo "error: local branch $SYNC_BRANCH already exists" >&2
  echo "  if it is a leftover:  git branch -D $SYNC_BRANCH" >&2
  exit 1
fi
git switch -c "$SYNC_BRANCH"

conflicts=""
if git apply --3way /tmp/upstream-sync.patch; then
  echo "Applied cleanly."
else
  conflicts=$(git grep -l '^<<<<<<< ' -- . 2>/dev/null | tr '\n' ' ' || true)
  if [[ -z "$conflicts" ]]; then
    echo "::error::Upstream changes could not be applied (no three-way merge available). Inspect /tmp/upstream-sync.patch." >&2
    exit 1
  fi
  echo "Applied with conflicts in: ${conflicts}"
fi

# Advance the markers.
echo "$upstream_sha" > UPSTREAM_SHA
npm_version=$(curl -s https://registry.npmjs.org/freebuff/latest | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")
echo "$npm_version" > UPSTREAM_VERSION

git add -A
git -c user.name="$COMMIT_NAME" -c user.email="$COMMIT_EMAIL" \
  commit -m "chore(upstream): sync freebuff ${npm_version}"

# Push. In CI the push uses SYNC_TOKEN; locally it uses your origin.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is empty — add the SYNC_TOKEN secret to the repository." >&2
    exit 1
  fi
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
fi
git push --force-with-lease origin "$SYNC_BRANCH"

title="chore(upstream): sync freebuff ${npm_version}"
if gh pr view "$SYNC_BRANCH" --json number --jq '.number' >/dev/null 2>&1; then
  echo "Pull request already open; branch updated."
else
  cat > /tmp/sync-pr-body.md <<'EOF'
Automated sync from the [Freebuff upstream mirror](https://github.com/CodebuffAI/freebuff).
EOF
  gh pr create --base main --head "$SYNC_BRANCH" --title "$title" --body-file /tmp/sync-pr-body.md
fi

if [[ -n "$conflicts" ]]; then
  if ! gh pr view "$SYNC_BRANCH" --json comments --jq '.comments[].body' 2>/dev/null | grep -q "Sync has conflicts"; then
    gh pr comment "$SYNC_BRANCH" --body "⚠️ Sync has conflicts in: ${conflicts}. Resolve the conflict markers in this pull request, then push a follow-up commit."
  fi
fi
