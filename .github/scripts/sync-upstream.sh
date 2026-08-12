#!/usr/bin/env bash
#
# Sync changes from the Freebuff upstream mirror into a `sync/upstream`
# branch and open or update the sync pull request.
#
# The workflow .github/workflows/sync-upstream.yml runs this script. FORK.md
# documents the sync model: markers, excluded paths, conflict handling, and
# push semantics.
#
# One non-obvious decision: the marker advances even when upstream changed
# only fork-local paths. The script pushes a marker-only commit so the next
# run can detect upstream commits it has not examined yet.
#
# Usage:
#   bash .github/scripts/sync-upstream.sh
set -euo pipefail

readonly UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/CodebuffAI/freebuff.git}"
readonly UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
readonly SYNC_BRANCH="${SYNC_BRANCH:-sync/upstream}"
readonly REPO="${GITHUB_REPOSITORY:-LMLiam/freebuffed}"
readonly COMMIT_NAME="${SYNC_COMMIT_NAME:-freebuffed[bot]}"
readonly COMMIT_EMAIL="${SYNC_COMMIT_EMAIL:-freebuffed[bot]@users.noreply.github.com}"

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
readonly EXCLUDES

CONFLICT_LABEL="${SYNC_CONFLICT_LABEL:-upstream-conflict}"
readonly CONFLICT_LABEL

branch_has_conflicts() {
  local ref="$1"
  local files=()
  local f
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(git diff --name-only -z --diff-filter=ACMR main "$ref" -- . 2>/dev/null || true)
  if [[ ${#files[@]} -eq 0 ]]; then
    return 1
  fi
  git grep -lE '^(<<<<<<< |>>>>>>> )' "$ref" -- "${files[@]/#/:(literal)}" >/dev/null 2>&1
}

create_sync_pr() {
  if branch_has_conflicts "$2"; then
    gh pr create --draft --base main --head "$SYNC_BRANCH" \
      --title "$1" --body-file "$body_file"
    gh pr edit "$SYNC_BRANCH" --add-label "$CONFLICT_LABEL" 2>/dev/null || true
  else
    gh pr create --base main --head "$SYNC_BRANCH" \
      --title "$1" --body-file "$body_file"
  fi
}

sync_draft_state() {
  if branch_has_conflicts "$1"; then
    gh pr ready --undo "$SYNC_BRANCH" 2>/dev/null || true
    gh pr edit "$SYNC_BRANCH" --add-label "$CONFLICT_LABEL" 2>/dev/null || true
  elif gh pr view "$SYNC_BRANCH" --json labels \
    --jq '.labels[].name' 2>/dev/null | grep -qx "$CONFLICT_LABEL"; then
    gh pr ready "$SYNC_BRANCH" 2>/dev/null || true
    gh pr edit "$SYNC_BRANCH" --remove-label "$CONFLICT_LABEL" 2>/dev/null || true
  fi
}

cd "$(git rev-parse --show-toplevel)"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
patch_file="$tmp_dir/upstream-sync.patch"
body_file="$tmp_dir/sync-pr-body.md"

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
    echo "error: $SYNC_BRANCH has no UPSTREAM_SHA — a sync branch without a marker cannot be appended to." >&2
    echo "Restore UPSTREAM_SHA or recreate the branch." >&2
    exit 1
  fi
else
  marker="$main_marker"
fi

# The marker must name a commit in the fetched upstream history, otherwise the
# diff below would fail without a clear error.
if ! git cat-file -e "$marker^{commit}" 2>/dev/null; then
  echo "error: marker ${marker:0:12} is not a commit in the fetched upstream history — check UPSTREAM_SHA" >&2
  exit 1
fi

if [[ "$upstream_sha" == "$marker" ]]; then
  echo "Up to date (marker ${marker:0:8})"
  if [[ -n "$remote_tip" ]]; then
    sync_draft_state "origin/$SYNC_BRANCH"
    # After a sync merge the branch has no commits ahead of main, so a new
    # pull request would be empty. Only recreate it when the branch is ahead.
    ahead_count=$(git rev-list --count "main..origin/$SYNC_BRANCH")
    if [[ "$ahead_count" -gt 0 ]] &&
      ! gh pr view "$SYNC_BRANCH" --json state --jq '.state' 2>/dev/null | grep -q OPEN; then
      version=$(tr -d '[:space:]' < UPSTREAM_VERSION 2>/dev/null || echo "unknown")
      cat > "$body_file" <<'EOF'
Automated sync from the [Freebuff upstream mirror](https://github.com/CodebuffAI/freebuff).
EOF
      create_sync_pr "chore(upstream): sync freebuff ${version}" "origin/$SYNC_BRANCH"
    fi
  fi
  exit 0
fi
echo "New upstream commits: ${marker:0:8} -> ${upstream_sha:0:8}"

if [[ -z "$remote_tip" ]]; then
  git switch -c "$SYNC_BRANCH"
fi

git diff --full-index "$marker" "$upstream_sha" -- . \
  "${EXCLUDES[@]}" > "$patch_file"

conflicts=""
if [[ -s "$patch_file" ]]; then
  if git apply --3way "$patch_file"; then
    echo "Applied cleanly."
  else
    unmerged=()
    while IFS= read -r -d '' f; do
      unmerged+=("$f")
    done < <(git diff --name-only --diff-filter=U -z 2>/dev/null || true)
    if [[ ${#unmerged[@]} -eq 0 ]]; then
      echo "::error::Upstream changes could not be applied and no conflict was produced. Inspect ${patch_file}." >&2
      exit 1
    fi
    conflicts="${unmerged[*]}"
    echo "Applied with conflicts in: ${conflicts}"
  fi
else
  echo "Upstream changed only fork-local paths — advancing the marker only."
fi

# Advance the markers. The version is read from the synced tree itself, so
# the markers are deterministic: the npm registry can lag or race the mirror.
echo "$upstream_sha" > UPSTREAM_SHA
upstream_version=$(
  git show "$upstream_sha:freebuff/cli/release/package.json" |
    python3 -c "import json, sys; print(json.load(sys.stdin)['version'])"
)
echo "$upstream_version" > UPSTREAM_VERSION

git add -A
git -c user.name="$COMMIT_NAME" -c user.email="$COMMIT_EMAIL" \
  commit -m "chore(upstream): sync freebuff ${upstream_version}"

# Push. In CI the sync uses SYNC_TOKEN as an ephemeral credential for this
# one command; nothing is written to the repository's git config.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is empty — add the SYNC_TOKEN secret to the repository." >&2
    exit 1
  fi
  git push \
    "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" \
    "$SYNC_BRANCH"
else
  git push origin "$SYNC_BRANCH"
fi

title="chore(upstream): sync freebuff ${upstream_version}"

if gh pr view "$SYNC_BRANCH" --json state --jq '.state' 2>/dev/null | grep -q OPEN; then
  echo "Pull request already open; branch updated."
  gh pr edit "$SYNC_BRANCH" --title "$title"
  sync_draft_state "$SYNC_BRANCH"
else
  cat > "$body_file" <<'EOF'
Automated sync from the [Freebuff upstream mirror](https://github.com/CodebuffAI/freebuff).
EOF
  create_sync_pr "$title" "$SYNC_BRANCH"
fi

if [[ -n "$conflicts" ]]; then
  if ! gh pr view "$SYNC_BRANCH" --json comments --jq '.comments[].body' 2>/dev/null | grep -q "Sync has conflicts"; then
    gh pr comment "$SYNC_BRANCH" --body \
      "⚠️ Sync has conflicts in: ${conflicts}. The pull request is a draft and stays a draft until the conflicts are resolved."
  fi
fi
