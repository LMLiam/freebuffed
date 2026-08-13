#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/check-conflict-markers.sh"

readonly PR_SCRIPT="$SCRIPT_DIR/sync-upstream-pr.py"
readonly UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/CodebuffAI/freebuff.git}"
readonly UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
readonly SYNC_BRANCH="${SYNC_BRANCH:-sync/upstream}"
readonly REPO="${GITHUB_REPOSITORY:-LMLiam/freebuffed}"
readonly COMMIT_NAME="${SYNC_COMMIT_NAME:-freebuffed[bot]}"
readonly COMMIT_EMAIL="${SYNC_COMMIT_EMAIL:-freebuffed[bot]@users.noreply.github.com}"
readonly CONFLICT_LABEL="${SYNC_CONFLICT_LABEL:-upstream-conflict}"

# Keep fork-owned files and sync markers out of upstream patches.
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

# Escape a Git path for one human-readable log line.
# Arguments: one path.
# Output: UTF-8 text with controls, DEL, and backslashes escaped.
display_git_path() {
  local LC_ALL=C
  local value="$1"
  local code control replacement

  value="${value//\\/\\\\}"
  for code in {1..31} 127; do
    printf -v control '%b' "\\$(printf '%03o' "$code")"
    printf -v replacement '\\x%02X' "$code"
    value="${value//"$control"/$replacement}"
  done
  printf '%s' "$value"
}

# Read and validate the upstream version at one Git ref.
# Arguments: Git ref.
# Output: a three-part decimal version.
# Return non-zero for missing, malformed, or unsupported version data.
read_upstream_version() {
  local ref="$1"
  local package_json version

  if ! package_json=$(git show "$ref:freebuff/cli/release/package.json" 2>/dev/null); then
    echo "::error::could not read the upstream version at $ref" >&2
    return 1
  fi
  if ! version=$(python3 -c '
import json
import re
import sys

try:
    value = json.load(sys.stdin).get("version")
except (AttributeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, str) or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value) is None:
    raise SystemExit(1)
print(value)
' <<< "$package_json"); then
    echo "::error::upstream version at $ref must be a MAJOR.MINOR.PATCH string" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

# Create one private credential helper for the current run.
# Arguments: private temporary directory.
# Output: credential-helper path.
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
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "${GH_TOKEN:?}" ;;
  *) exit 1 ;;
esac
EOF
      chmod 700 "$askpass_file"
    ) || return 1
  fi
  printf '%s' "$askpass_file"
}

# Push one refspec to the sync remote.
# Arguments: refspec, private temporary directory, then Git push options.
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
    GIT_ASKPASS="$askpass_file" GIT_TERMINAL_PROMPT=0 git push \
      "https://github.com/${REPO}.git" \
      "${push_options[@]}" \
      "$refspec"
  else
    git push origin "${push_options[@]}" "$refspec"
  fi
}

# Classify the pull request for the observed remote tip.
# Arguments: tip SHA.
# Output: ABSENT or STATE<TAB>NUMBER.
classify_sync_pr() {
  python3 "$PR_SCRIPT" classify \
    --repo "$REPO" --base main --head "$SYNC_BRANCH" --tip "$1"
}

# Reconcile one immutable candidate ref with GitHub.
# Arguments: ref, version, NUL-delimited conflict file, and optional PR number.
reconcile_sync_pr() {
  local ref="$1"
  local version="$2"
  local conflict_file="$3"
  local pr_number="${4:-}"
  local tip
  local -a arguments

  tip=$(git rev-parse "$ref")
  arguments=(
    reconcile
    --repo "$REPO"
    --base main
    --head "$SYNC_BRANCH"
    --tip "$tip"
    --version "$version"
    --label "$CONFLICT_LABEL"
    --conflicts0 "$conflict_file"
  )
  if [[ -n "$pr_number" ]]; then
    arguments+=(--pr-number "$pr_number")
  fi
  python3 "$PR_SCRIPT" "${arguments[@]}"
}

# Validate a retained branch that has no pull request for its current tip.
# Arguments: observed tip, main marker, and fetched upstream tip.
# Output: the candidate upstream version.
# Return non-zero without changing the branch when validation fails.
validate_unmatched_candidate() {
  local observed_tip="$1"
  local main_marker="$2"
  local upstream_tip="$3"
  local current_tip marker version expected_version ahead_count

  current_tip=$(git ls-remote origin "refs/heads/$SYNC_BRANCH" | awk '{print $1}')
  if [[ "$current_tip" != "$observed_tip" ]]; then
    echo "::error::$SYNC_BRANCH changed during candidate validation; branch left unchanged" >&2
    return 1
  fi
  if ! git merge-base --is-ancestor main "origin/$SYNC_BRANCH"; then
    echo "::error::unmatched live branch $SYNC_BRANCH is not based on current main; preserve its commits, then create a pull request or remove the branch" >&2
    return 1
  fi
  if ! ahead_count=$(git rev-list --count "main..origin/$SYNC_BRANCH" 2>/dev/null) ||
    [[ "$ahead_count" -eq 0 ]]; then
    echo "::error::unmatched live branch $SYNC_BRANCH has no synchronization candidate; branch left unchanged" >&2
    return 1
  fi
  marker=$(git show "origin/$SYNC_BRANCH:UPSTREAM_SHA" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -z "$marker" ]] || ! git cat-file -e "$marker^{commit}" 2>/dev/null; then
    echo "::error::unmatched live branch $SYNC_BRANCH has no valid UPSTREAM_SHA; branch left unchanged" >&2
    return 1
  fi
  if [[ "$marker" == "$main_marker" ]] ||
    ! git merge-base --is-ancestor "$main_marker" "$marker" ||
    ! git merge-base --is-ancestor "$marker" "$upstream_tip"; then
    echo "::error::unmatched live branch $SYNC_BRANCH has an invalid upstream checkpoint; branch left unchanged" >&2
    return 1
  fi
  if ! version=$(git show "origin/$SYNC_BRANCH:UPSTREAM_VERSION" 2>/dev/null); then
    echo "::error::unmatched live branch $SYNC_BRANCH has no UPSTREAM_VERSION; branch left unchanged" >&2
    return 1
  fi
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "::error::unmatched live branch $SYNC_BRANCH has an invalid UPSTREAM_VERSION; branch left unchanged" >&2
    return 1
  fi
  if ! expected_version=$(read_upstream_version "$marker") ||
    [[ "$version" != "$expected_version" ]]; then
    echo "::error::unmatched live branch $SYNC_BRANCH version does not match its upstream checkpoint; branch left unchanged" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

SYNC_TMP_DIR=

cleanup_sync_tmp_dir() {
  if [[ -n "${SYNC_TMP_DIR:-}" ]]; then
    rm -rf -- "$SYNC_TMP_DIR"
  fi
}

# Run one synchronization from the checked-out main branch.
# The function fails closed for ambiguous Git or GitHub state.
main() {
  local tmp_dir patch_file conflict_file
  local branch main_marker upstream_sha upstream_version marker remote_tip
  local pr_record pr_state pr_number current_tip current_record current_state current_number
  local replace_merged_branch=false
  local -a unmerged=()
  local file

  cd "$(git rev-parse --show-toplevel)"
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is empty — add the SYNC_TOKEN secret to the repository." >&2
    return 1
  fi

  tmp_dir=$(mktemp -d)
  SYNC_TMP_DIR="$tmp_dir"
  trap cleanup_sync_tmp_dir EXIT
  patch_file="$tmp_dir/upstream-sync.patch"
  conflict_file="$tmp_dir/conflict-files"

  branch=$(git branch --show-current)
  if [[ "$branch" != "main" ]]; then
    echo "error: run from main (currently on $branch)" >&2
    return 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is not clean — commit or stash your changes first" >&2
    return 1
  fi
  if ! python3 "$PR_SCRIPT" preflight --repo "$REPO" --label "$CONFLICT_LABEL"; then
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
  if ! git cat-file -e "$main_marker^{commit}" 2>/dev/null; then
    echo "error: marker ${main_marker:0:12} is not in the fetched upstream history" >&2
    return 1
  fi

  remote_tip=$(git ls-remote origin "refs/heads/$SYNC_BRANCH" | awk '{print $1}')
  pr_number=
  if [[ -n "$remote_tip" ]]; then
    git fetch origin "$SYNC_BRANCH"
    if git merge-base --is-ancestor "origin/$SYNC_BRANCH" main; then
      echo "Sync branch $SYNC_BRANCH is already in main — using current main."
      git checkout -B "$SYNC_BRANCH" main
      marker="$main_marker"
    else
      if ! pr_record=$(classify_sync_pr "$remote_tip"); then
        return 1
      fi
      IFS=$'\t' read -r pr_state pr_number <<< "$pr_record"
      case "$pr_state" in
        OPEN)
          echo "Sync branch $SYNC_BRANCH has open pull request #$pr_number — appending to it."
          git checkout -B "$SYNC_BRANCH" "origin/$SYNC_BRANCH"
          marker=$(git show "origin/$SYNC_BRANCH:UPSTREAM_SHA" 2>/dev/null | tr -d '[:space:]' || true)
          ;;
        MERGED)
          echo "Sync branch $SYNC_BRANCH matches merged pull request #$pr_number — using current main."
          git checkout -B "$SYNC_BRANCH" main
          marker="$main_marker"
          replace_merged_branch=true
          ;;
        CLOSED)
          echo "::error::$SYNC_BRANCH matches closed pull request #$pr_number; reopen it or preserve and remove the branch" >&2
          return 1
          ;;
        ABSENT)
          if ! upstream_version=$(validate_unmatched_candidate \
            "$remote_tip" "$main_marker" "$upstream_sha"); then
            return 1
          fi
          if ! write_conflict_marker_files main "origin/$SYNC_BRANCH" "$conflict_file"; then
            return 1
          fi
          echo "Recovering the pull request for the preserved $SYNC_BRANCH candidate."
          reconcile_sync_pr "origin/$SYNC_BRANCH" "$upstream_version" "$conflict_file"
          return $?
          ;;
        *)
          echo "::error::unexpected pull request classification '$pr_state'; branch left unchanged" >&2
          return 1
          ;;
      esac
    fi
  else
    marker="$main_marker"
  fi

  if [[ -z "$marker" ]] || ! git cat-file -e "$marker^{commit}" 2>/dev/null; then
    echo "error: sync branch has no valid UPSTREAM_SHA" >&2
    return 1
  fi
  if [[ "$upstream_sha" == "$marker" ]]; then
    echo "Up to date (marker ${marker:0:8})"
    if [[ -n "$pr_number" && "$replace_merged_branch" == "false" ]]; then
      if ! upstream_version=$(read_upstream_version "$marker") ||
        ! write_conflict_marker_files main "$SYNC_BRANCH" "$conflict_file"; then
        return 1
      fi
      reconcile_sync_pr "$SYNC_BRANCH" "$upstream_version" "$conflict_file" "$pr_number"
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
      while IFS= read -r -d '' file; do
        unmerged+=("$file")
      done < <(git diff --name-only --diff-filter=U -z 2>/dev/null || true)
      if [[ ${#unmerged[@]} -eq 0 ]]; then
        echo "::error::Upstream changes could not be applied and no conflict was produced." >&2
        return 1
      fi
      echo "Applied with conflicts in:"
      for file in "${unmerged[@]}"; do
        printf '  %s\n' "$(display_git_path "$file")"
      done
    fi
  else
    echo "Upstream changed only fork-local paths — advancing the marker only."
  fi

  echo "$upstream_sha" > UPSTREAM_SHA
  if ! upstream_version=$(read_upstream_version "$upstream_sha"); then
    return 1
  fi
  echo "$upstream_version" > UPSTREAM_VERSION
  git add -A
  git -c user.name="$COMMIT_NAME" -c user.email="$COMMIT_EMAIL" \
    commit -m "chore(upstream): sync freebuff ${upstream_version}"

  if [[ "$replace_merged_branch" == "true" ]]; then
    current_tip=$(git ls-remote origin "refs/heads/$SYNC_BRANCH" | awk '{print $1}')
    if [[ "$current_tip" != "$remote_tip" ]]; then
      echo "::error::$SYNC_BRANCH changed while the sync was running; branch left unchanged" >&2
      return 1
    fi
    if ! current_record=$(classify_sync_pr "$current_tip"); then
      return 1
    fi
    IFS=$'\t' read -r current_state current_number <<< "$current_record"
    if [[ "$current_state" != "MERGED" || "$current_number" != "$pr_number" ]]; then
      echo "::error::pull request state changed before branch replacement; branch left unchanged" >&2
      return 1
    fi
    if ! push_sync_ref "$SYNC_BRANCH:refs/heads/$SYNC_BRANCH" "$tmp_dir" \
      "--force-with-lease=refs/heads/$SYNC_BRANCH:$remote_tip"; then
      return 1
    fi
    pr_number=
  elif ! push_sync_ref "$SYNC_BRANCH:refs/heads/$SYNC_BRANCH" "$tmp_dir"; then
    return 1
  fi

  if ! write_conflict_marker_files main "$SYNC_BRANCH" "$conflict_file"; then
    return 1
  fi
  reconcile_sync_pr "$SYNC_BRANCH" "$upstream_version" "$conflict_file" "$pr_number"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
