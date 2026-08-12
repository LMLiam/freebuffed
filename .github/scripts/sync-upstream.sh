#!/usr/bin/env bash
#
# Sync changes from the Freebuff upstream mirror into a `sync/upstream`
# branch, then open or update the sync pull request.
#
# The workflow .github/workflows/sync-upstream.yml runs this.
#
# The sync never force-pushes. When `sync/upstream` already exists, the sync
# checks out its tip, applies only the upstream delta since that branch's
# marker, and appends a new commit with a plain fast-forward push. A plain
# push cannot overwrite the remote tip, so manual commits on the branch are
# preserved by construction.
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

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
PATCH_FILE="$TMP_DIR/upstream-sync.patch"
BODY_FILE="$TMP_DIR/sync-pr-body.md"

branch=$(git branch --show-current)
if [[ "$branch" != "main" ]]; then
  echo "error: run from main (currently on $branch)" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean — commit or stash your changes first" >&2
  exit 1
fi

main_marker=$(tr -d '[:space:]' < UPSTREAM_SHA 2>/dev/null || true)
if [[ -z "$main_marker" ]]; then
  echo "error: UPSTREAM_SHA is empty — set it to the upstream commit this tree is based on" >&2
  exit 1
fi

echo "Fetching $UPSTREAM_URL $UPSTREAM_BRANCH ..."
git fetch --filter=blob:none --no-tags "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
upstream_sha=$(git rev-parse FETCH_HEAD)

# If the sync branch already exists, build on top of it so that manual
# commits on the branch survive. The delta base is that branch's own marker.
remote_tip=$(git ls-remote origin "refs/heads/$SYNC_BRANCH" | awk '{print $1}')
if [[ -n "$remote_tip" ]]; then
  echo "Sync branch $SYNC_BRANCH exists — appending to it (${remote_tip:0:8})."
  git fetch origin "$SYNC_BRANCH"
  git checkout -B "$SYNC_BRANCH" "origin/$SYNC_BRANCH"
  marker=$(git show "origin/$SYNC_BRANCH:UPSTREAM_SHA" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -z "$marker" ]]; then
    marker="$main_marker"
  fi
else
  marker="$main_marker"
fi

if [[ "$upstream_sha" == "$marker" ]]; then
  echo "Up to date (marker ${marker:0:8})"
  if [[ -n "$remote_tip" ]]; then
    # Keep the draft state in sync with the branch content, so a conflict
    # resolved since the last run does not leave the PR stuck as a draft.
    if git grep -lE '^(<<<<<<< |>>>>>>> )' "origin/$SYNC_BRANCH" -- . "${EXCLUDES[@]}" >/dev/null 2>&1; then
      gh pr ready --undo "$SYNC_BRANCH" 2>/dev/null || true
    else
      gh pr ready "$SYNC_BRANCH" 2>/dev/null || true
    fi
    if ! gh pr view "$SYNC_BRANCH" --json state --jq '.state' 2>/dev/null | grep -q OPEN; then
      version=$(tr -d '[:space:]' < UPSTREAM_VERSION 2>/dev/null || echo "unknown")
      cat > "$BODY_FILE" <<'EOF'
Automated sync from the [Freebuff upstream mirror](https://github.com/CodebuffAI/freebuff).
EOF
      gh pr create --base main --head "$SYNC_BRANCH" --title "chore(upstream): sync freebuff ${version}" --body-file "$BODY_FILE"
    fi
  fi
  exit 0
fi
echo "New upstream commits: ${marker:0:8} -> ${upstream_sha:0:8}"

if [[ -z "$remote_tip" ]]; then
  git switch -c "$SYNC_BRANCH"
fi

git diff --full-index "$marker" "$upstream_sha" -- . "${EXCLUDES[@]}" > "$PATCH_FILE"
if [[ ! -s "$PATCH_FILE" ]]; then
  echo "No upstream changes outside the fork-local paths"
  exit 0
fi

conflicts=""
if git apply --3way "$PATCH_FILE"; then
  echo "Applied cleanly."
else
  conflicts=$(git grep -l '^<<<<<<< ' -- . 2>/dev/null | tr '\n' ' ' || true)
  if [[ -z "$conflicts" ]]; then
    echo "::error::Upstream changes could not be applied (no three-way merge available). Inspect ${PATCH_FILE}." >&2
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

# Push. In CI the push uses SYNC_TOKEN, passed as an ephemeral credential to
# this one command — nothing is written to the repository's git config. A
# plain push only fast-forwards — it can never overwrite the remote tip.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is empty — add the SYNC_TOKEN secret to the repository." >&2
    exit 1
  fi
  git push "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "$SYNC_BRANCH"
else
  git push origin "$SYNC_BRANCH"
fi

if gh pr view "$SYNC_BRANCH" --json state --jq '.state' 2>/dev/null | grep -q OPEN; then
  echo "Pull request already open; branch updated."
else
  cat > "$BODY_FILE" <<'EOF'
Automated sync from the [Freebuff upstream mirror](https://github.com/CodebuffAI/freebuff).
EOF
  gh pr create --base main --head "$SYNC_BRANCH" --title "chore(upstream): sync freebuff ${npm_version}" --body-file "$BODY_FILE"
fi

if [[ -n "$conflicts" ]]; then
  gh pr ready --undo "$SYNC_BRANCH" 2>/dev/null || true
  if ! gh pr view "$SYNC_BRANCH" --json comments --jq '.comments[].body' 2>/dev/null | grep -q "Sync has conflicts"; then
    gh pr comment "$SYNC_BRANCH" --body "⚠️ Sync has conflicts in: ${conflicts}. The pull request is a draft and the Conflict markers check blocks merging until they are resolved."
  fi
else
  gh pr ready "$SYNC_BRANCH" 2>/dev/null || true
fi
