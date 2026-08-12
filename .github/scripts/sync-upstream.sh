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
# The sync labels conflicted pull requests with `upstream-conflict`. The label
# is a prerequisite: it must exist in the repository or the sync fails loudly.
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

conflicted_files() {
  local ref="$1"
  local files=()
  local f
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(git diff --name-only -z --diff-filter=ACMR main "$ref" -- . 2>/dev/null || true)
  if [[ ${#files[@]} -eq 0 ]]; then
    return 1
  fi
  # git grep prefixes matches with "$ref:"; strip it so the conflict
  # notice lists plain paths, not "origin/sync/upstream:a.txt". Print
  # non-ASCII paths readably instead of as octal escapes.
  git -c core.quotePath=false grep -lE '^(<<<<<<< |>>>>>>> )' "$ref" -- "${files[@]/#/:(literal)}" 2>/dev/null |
    sed "s|^$ref:||"
}

branch_has_conflicts() {
  conflicted_files "$1" >/dev/null 2>&1
}

ensure_conflict_label() {
  local code
  # Distinguish a missing label (404) from an API failure such as a network
  # error, rate limit, or missing permission: only a confirmed 404 gets the
  # create hint, and any other failure aborts with its own message.
  # gh api prints the status line with --include but exits non-zero on HTTP
  # error statuses, so capture the output regardless of the exit status and
  # decide on the status code itself; an empty status line means the call
  # produced no response at all.
  code=$(gh api "repos/$REPO/labels/$CONFLICT_LABEL" --silent --include 2>/dev/null |
    awk 'NR==1{print $2}' || true)
  case "$code" in
    200) return 0 ;;
    404)
      echo "::error::label '$CONFLICT_LABEL' does not exist. Create it once with: gh label create \"$CONFLICT_LABEL\" --color d73a4a --description 'Sync pull request has unresolved conflict markers'" >&2
      exit 1
      ;;
    *)
      echo "::error::could not read label '$CONFLICT_LABEL' (status ${code:-unknown})" >&2
      exit 1
      ;;
  esac
}

# Reconcile the sync pull request towards its desired state. Both the changed
# and the unchanged run call this, so a run that fails part-way (for example
# after the push) converges on the next run. The title and version come from
# the branch itself, so a stale title is repaired even when main lags.
reconcile_pr() {
  local ref="$1"
  local version title state is_draft pr_labels
  local notice_marker notice_ids notice_id notice_files notice_body
  notice_marker='<!-- sync-conflict-notice -->'
  # Capture the version before stripping whitespace, so a failed read falls
  # back to "unknown" instead of producing an empty version.
  version=$(git show "$ref:UPSTREAM_VERSION" 2>/dev/null || true)
  version=$(printf '%s' "$version" | tr -d '[:space:]')
  version="${version:-unknown}"
  title="chore(upstream): sync freebuff ${version}"

  # A missing pull request is normal when the branch is live (it is created
  # below). A final branch with no commits ahead of main has nothing to
  # reconcile. Any other read failure must not be read as "not OPEN": route
  # it to the create path, which fails loudly when a pull request exists.
  if ! state=$(gh pr view "$SYNC_BRANCH" --json state --jq '.state' 2>/dev/null); then
    if [[ "$(git rev-list --count "main..$ref")" -eq 0 ]]; then
      return 0
    fi
  fi

  # A merged or closed pull request whose branch has no commits ahead of main
  # is final; do not recreate it.
  if [[ "$state" != "OPEN" ]] && [[ "$(git rev-list --count "main..$ref")" -eq 0 ]]; then
    return 0
  fi

  # Create the pull request when none is open.
  if [[ "$state" != "OPEN" ]]; then
    cat > "$body_file" <<'EOF'
Automated sync from the [Freebuff upstream mirror](https://github.com/CodebuffAI/freebuff).
EOF
    if branch_has_conflicts "$ref"; then
      gh pr create --draft --base main --head "$SYNC_BRANCH" \
        --title "$title" --body-file "$body_file"
      gh pr edit "$SYNC_BRANCH" --add-label "$CONFLICT_LABEL"
    else
      gh pr create --base main --head "$SYNC_BRANCH" \
        --title "$title" --body-file "$body_file"
    fi
    state=OPEN
  else
    gh pr edit "$SYNC_BRANCH" --title "$title"
  fi

  # The pull request exists here (created or already open), so a failed
  # draft-state read must not be treated as "not a draft": that would drop
  # the label from a still-drafted pull request. Fail loudly instead.
  if ! is_draft=$(gh pr view "$SYNC_BRANCH" --json isDraft --jq '.isDraft' 2>/dev/null); then
    echo "::error::could not read draft state for $SYNC_BRANCH" >&2
    exit 1
  fi

  if branch_has_conflicts "$ref"; then
    # Keep the pull request drafted and labelled while conflicts remain.
    if [[ "$is_draft" != "true" ]]; then
      gh pr ready --undo "$SYNC_BRANCH"
    fi
    gh pr edit "$SYNC_BRANCH" --add-label "$CONFLICT_LABEL"
    # One identifiable bot comment lists the conflicted files, and the sync
    # updates it in place. A later unrelated conflict updates the same
    # comment, so no notice is suppressed and none is duplicated. Read the
    # comments loudly: a failed read must not be treated as "no notice",
    # which would post a duplicate on every run until the API recovers.
    if ! notice_ids=$(gh pr view "$SYNC_BRANCH" --json comments \
      --jq '.comments[] | select(.body | contains("sync-conflict-notice")) | .id' 2>/dev/null); then
      echo "::error::could not read comments for $SYNC_BRANCH" >&2
      exit 1
    fi
    notice_id=${notice_ids%%$'\n'*}
    # One bullet per file with a code span: a space-joined list would make
    # filenames that contain spaces ambiguous.
    # shellcheck disable=SC2016 # the backticks in sed are literal text
    notice_files=$(conflicted_files "$ref" | sed 's|^|- `|; s|$|`|')
    notice_body=$(printf '%s\n⚠️ Sync has conflicts in:\n%s\nThe pull request is a draft and stays a draft until the conflicts are resolved.\n' \
      "$notice_marker" "$notice_files")
    if [[ -n "$notice_id" ]]; then
      gh api -X PATCH "repos/$REPO/issues/comments/$notice_id" -f body="$notice_body"
    else
      gh pr comment "$SYNC_BRANCH" --body "$notice_body"
    fi
    return 0
  fi

  # Clean. The label marks an automatically drafted pull request. Read it
  # loudly: a failed read must not be treated as "no label", which would
  # drop the label from a still-drafted pull request.
  if ! pr_labels=$(gh pr view "$SYNC_BRANCH" --json labels --jq '.labels[].name' 2>/dev/null); then
    echo "::error::could not read labels for $SYNC_BRANCH" >&2
    exit 1
  fi
  if grep -qx "$CONFLICT_LABEL" <<< "$pr_labels"; then
    # Clean again. Mark the auto-drafted pull request ready, update the
    # stale conflict notice to resolved, then drop the label so a manual
    # draft is never forced ready by a later run. A failure here aborts the
    # sync and is retried on the next run.
    if [[ "$is_draft" == "true" ]]; then
      gh pr ready "$SYNC_BRANCH"
    fi
    if ! notice_ids=$(gh pr view "$SYNC_BRANCH" --json comments \
      --jq '.comments[] | select(.body | contains("sync-conflict-notice")) | .id' 2>/dev/null); then
      echo "::error::could not read comments for $SYNC_BRANCH" >&2
      exit 1
    fi
    notice_id=${notice_ids%%$'\n'*}
    if [[ -n "$notice_id" ]]; then
      notice_body=$(printf '%s\n✔️ Sync conflicts are resolved and the pull request is ready for review.\n' "$notice_marker")
      gh api -X PATCH "repos/$REPO/issues/comments/$notice_id" -f body="$notice_body"
    fi
    gh pr edit "$SYNC_BRANCH" --remove-label "$CONFLICT_LABEL"
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

ensure_conflict_label

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
    reconcile_pr "origin/$SYNC_BRANCH"
  fi
  exit 0
fi
echo "New upstream commits: ${marker:0:8} -> ${upstream_sha:0:8}"

if [[ -z "$remote_tip" ]]; then
  git switch -c "$SYNC_BRANCH"
fi

git diff --full-index "$marker" "$upstream_sha" -- . \
  "${EXCLUDES[@]}" > "$patch_file"

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
    # One path per line: a space-joined string would make filenames that
    # contain spaces ambiguous in the log.
    echo "Applied with conflicts in:"
    printf '  %s\n' "${unmerged[@]}"
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

reconcile_pr "$SYNC_BRANCH"
