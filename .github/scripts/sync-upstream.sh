#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/check-conflict-markers.sh"

readonly UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/CodebuffAI/freebuff.git}"
readonly UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
readonly SYNC_BRANCH="${SYNC_BRANCH:-sync/upstream}"
readonly REPO="${GITHUB_REPOSITORY:-LMLiam/freebuffed}"
readonly COMMIT_NAME="${SYNC_COMMIT_NAME:-freebuffed[bot]}"
readonly COMMIT_EMAIL="${SYNC_COMMIT_EMAIL:-freebuffed[bot]@users.noreply.github.com}"

# Keep fork-owned CI, configuration, documentation, release metadata, and
# sync markers out of upstream patches. The sync still advances its marker
# for commits that change only these paths.
readonly -a EXCLUDES=(
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

readonly CONFLICT_LABEL="${SYNC_CONFLICT_LABEL:-upstream-conflict}"

# Print changed paths that contain a standard conflict marker in `ref`.
# A conflict means that a changed text file contains `<<<<<<<`, `=======`, or
# `>>>>>>>` at the start of a line. Output paths with NUL delimiters and
# return success only when at least one path is printed.
conflicted_files() {
  local ref="$1"
  local found=false
  local file
  while IFS= read -r -d '' file; do
    found=true
    printf '%s\0' "$file"
  done < <(conflict_marker_files main "$ref")
  if [[ "$found" == "true" ]]; then
    return 0
  fi
  return 1
}

branch_has_conflicts() {
  conflicted_files "$1" >/dev/null 2>&1
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/sync-upstream-pr.sh"

# Create one private credential helper for the current run. The helper reads
# `GH_TOKEN` only when Git asks for a password. Keep the token out of process
# arguments, then remove the helper with the temporary directory.
ensure_git_askpass() {
  local tmp_dir="$1"
  local askpass_file="$tmp_dir/git-askpass"
  if [[ ! -e "$askpass_file" ]]; then
    (
      umask 077
      cat > "$askpass_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  *Username*)
    printf '%s\n' 'x-access-token'
    ;;
  *Password*)
    printf '%s\n' "${GH_TOKEN:?}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
      chmod 700 "$askpass_file"
    ) || return 1
  fi
  printf '%s' "$askpass_file"
}

# Push `refspec` to the sync remote. Use the temporary credential helper in
# GitHub Actions and the configured `origin` remote in local runs.
# Arguments: the refspec, the run temporary directory, and optional Git push
# options. Keep options separate from the refspec so a lease can protect a
# branch deletion.
# Return non-zero when Git cannot complete the push.
push_sync_ref() {
  local refspec="$1"
  local tmp_dir="$2"
  shift 2
  local -a push_options=("$@")
  local askpass_file
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    if [[ -z "${GH_TOKEN:-}" ]]; then
      echo "::error::GH_TOKEN is empty — add the SYNC_TOKEN secret to the repository." >&2
      return 1
    fi
    if ! askpass_file=$(ensure_git_askpass "$tmp_dir"); then
      echo "::error::could not create the Git credential helper" >&2
      return 1
    fi
    if ! GIT_ASKPASS="$askpass_file" GIT_TERMINAL_PROMPT=0 git push \
      "https://github.com/${REPO}.git" \
      "${push_options[@]}" \
      "$refspec"; then
      return 1
    fi
  else
    if ! git push origin "${push_options[@]}" "$refspec"; then
      return 1
    fi
  fi
}

SYNC_TMP_DIR=

cleanup_sync_tmp_dir() {
  if [[ -n "${SYNC_TMP_DIR:-}" ]]; then
    rm -rf -- "$SYNC_TMP_DIR"
  fi
}

# Run one synchronization from the checked-out `main` branch. The marker and
# remote branch state determine whether the run appends, starts from current
# `main`, retires a merged branch, or stops before changing the remote.
main() {
  local tmp_dir patch_file body_file
  local branch main_marker upstream_sha remote_tip retire_sync_branch marker
  local pr_state pr_number merged_pr_number current_tip upstream_version
  local pr_record current_pr_number current_pr_state
  local -a unmerged=()
  local f

  cd "$(git rev-parse --show-toplevel)"

  tmp_dir=$(mktemp -d)
  SYNC_TMP_DIR="$tmp_dir"
  trap cleanup_sync_tmp_dir EXIT
  patch_file="$tmp_dir/upstream-sync.patch"
  body_file="$tmp_dir/sync-pr-body.md"

  branch=$(git branch --show-current)
  if [[ "$branch" != "main" ]]; then
    echo "error: run from main (currently on $branch)" >&2
    return 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is not clean — commit or stash your changes first" >&2
    return 1
  fi

  if ! ensure_conflict_label "$REPO" "$CONFLICT_LABEL"; then
    return 1
  fi

  main_marker=$(tr -d '[:space:]' < UPSTREAM_SHA 2>/dev/null || true)
  if [[ -z "$main_marker" ]]; then
    echo "error: UPSTREAM_SHA is empty — set it to the upstream commit this tree is based on" >&2
    return 1
  fi

  echo "Fetching $UPSTREAM_URL $UPSTREAM_BRANCH ..."
  git fetch --filter=blob:none --no-tags "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
  upstream_sha=$(git rev-parse FETCH_HEAD)

  remote_tip=$(git ls-remote origin "refs/heads/$SYNC_BRANCH" | awk '{print $1}')
  retire_sync_branch=false
  if [[ -n "$remote_tip" ]]; then
    # Reuse a retained branch only for an open pull request that is not in
    # main. A branch already in main has been integrated, so start from the
    # current main. A merged pull request also gets a new branch from main.
    git fetch origin "$SYNC_BRANCH"
    if git merge-base --is-ancestor "origin/$SYNC_BRANCH" main; then
      echo "Sync branch $SYNC_BRANCH is already in main — basing the next sync on main."
      git checkout -B "$SYNC_BRANCH" main
      marker="$main_marker"
    else
      # Query all matching PRs so an empty result means no PR, while a failed
      # request remains an API error. A branch without an open or merged PR
      # is not safe to reuse because its commits may have no other copy.
      if ! pr_record=$(find_sync_pr_state "$SYNC_BRANCH"); then
        return 1
      fi
      IFS=$'\t' read -r pr_state pr_number <<< "$pr_record"
      case "$pr_state" in
        OPEN)
          echo "Sync branch $SYNC_BRANCH has an open pull request — appending to it (${remote_tip:0:8})."
          git checkout -B "$SYNC_BRANCH" "origin/$SYNC_BRANCH"
          marker=$(git show "origin/$SYNC_BRANCH:UPSTREAM_SHA" 2>/dev/null | tr -d '[:space:]' || true)
          if [[ -z "$marker" ]]; then
            echo "error: $SYNC_BRANCH has no UPSTREAM_SHA — a sync branch without a marker cannot be appended to." >&2
            echo "Restore UPSTREAM_SHA or recreate the branch." >&2
            return 1
          fi
          ;;
        MERGED)
          echo "Sync branch $SYNC_BRANCH belongs to a merged pull request — basing the next sync on main."
          git checkout -B "$SYNC_BRANCH" main
          marker="$main_marker"
          retire_sync_branch=true
          merged_pr_number="$pr_number"
          ;;
        CLOSED)
          echo "::error::$SYNC_BRANCH belongs to a closed pull request; reopen it or remove the branch before syncing" >&2
          return 1
          ;;
        NONE)
          echo "::error::$SYNC_BRANCH has no pull request; create one or remove the branch before syncing" >&2
          return 1
          ;;
        *)
          echo "::error::unexpected pull request state '$pr_state' for $SYNC_BRANCH; branch left unchanged" >&2
          return 1
          ;;
      esac
    fi
  else
    marker="$main_marker"
  fi

  if ! git cat-file -e "$marker^{commit}" 2>/dev/null; then
    echo "error: marker ${marker:0:12} is not a commit in the fetched upstream history — check UPSTREAM_SHA" >&2
    return 1
  fi

  if [[ "$upstream_sha" == "$marker" ]]; then
    echo "Up to date (marker ${marker:0:8})"
    if [[ -n "$remote_tip" ]] &&
      ! reconcile_pr "origin/$SYNC_BRANCH" "$body_file" "$SYNC_BRANCH" "$REPO" "$CONFLICT_LABEL"; then
      return 1
    fi
    return 0
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
        return 1
      fi
      echo "Applied with conflicts in:"
      printf '  %s\n' "${unmerged[@]}"
    fi
  else
    echo "Upstream changed only fork-local paths — advancing the marker only."
  fi

  # Always record the upstream checkpoint. If the patch is empty because all
  # changed paths are excluded, this commit is marker-only. Without it, every
  # run would examine the same upstream commits again.
  echo "$upstream_sha" > UPSTREAM_SHA
  upstream_version=$(
    git show "$upstream_sha:freebuff/cli/release/package.json" |
      python3 -c "import json, sys; print(json.load(sys.stdin)['version'])"
  )
  echo "$upstream_version" > UPSTREAM_VERSION

  git add -A
  git -c user.name="$COMMIT_NAME" -c user.email="$COMMIT_EMAIL" \
    commit -m "chore(upstream): sync freebuff ${upstream_version}"

  if [[ "$retire_sync_branch" == "true" ]]; then
    current_tip=$(git ls-remote origin "refs/heads/$SYNC_BRANCH" | awk '{print $1}')
    if [[ "$current_tip" != "$remote_tip" ]]; then
      echo "::error::$SYNC_BRANCH changed while the sync was running; branch left unchanged" >&2
      return 1
    fi
    if ! pr_record=$(find_sync_pr_state "$SYNC_BRANCH"); then
      return 1
    fi
    IFS=$'\t' read -r current_pr_state current_pr_number <<< "$pr_record"
    if [[ "$current_pr_state" != "MERGED" ||
      "$current_pr_number" != "$merged_pr_number" ]]; then
      echo "::error::pull request state for $SYNC_BRANCH changed before branch retirement; branch left unchanged" >&2
      return 1
    fi
    if ! push_sync_ref ":$SYNC_BRANCH" "$tmp_dir" \
      "--force-with-lease=refs/heads/$SYNC_BRANCH:$remote_tip"; then
      return 1
    fi
    remote_tip=
  fi
  if ! push_sync_ref "$SYNC_BRANCH" "$tmp_dir"; then
    return 1
  fi

  if ! reconcile_pr "$SYNC_BRANCH" "$body_file" "$SYNC_BRANCH" "$REPO" "$CONFLICT_LABEL"; then
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
