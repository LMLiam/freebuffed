#!/usr/bin/env bash

# Reconcile GitHub pull-request state after the Git synchronizer prepares a
# candidate ref. The caller provides `branch_has_conflicts` and
# `conflicted_files`; this module performs no work when it is sourced.
readonly CONFLICT_NOTICE_MARKER='<!-- sync-conflict-notice -->'

validate_conflict_label() {
  local label="$1"

  if [[ "$label" == *,* ]] || [[ "$label" == *[[:cntrl:]]* ]]; then
    echo "::error::SYNC_CONFLICT_LABEL must not contain commas or control characters" >&2
    return 1
  fi
}

ensure_conflict_label() {
  local repo="$1"
  local label="$2"
  local label_names

  # Require an existing repository label before Git changes the sync branch.
  # Compare names as data so special characters cannot change the API path.
  if ! validate_conflict_label "$label"; then
    return 1
  fi
  if ! label_names=$(gh api --paginate \
    "repos/$repo/labels" --jq '.[].name' 2>/dev/null); then
    echo "::error::could not read labels from $repo" >&2
    return 1
  fi
  if grep -Fqx -- "$label" <<< "$label_names"; then
    return 0
  fi
  printf "::error::label '%s' does not exist. Create it once with: gh label create '%s' --color d73a4a --description 'Sync pull request has unresolved conflict markers'\n" \
    "$label" "$label" >&2
  return 1
}

# Return the number of the one open PR for `sync_branch`. Return no output when
# none exists. Treat an API failure or duplicate open PRs as an error.
find_open_pr_number() {
  local sync_branch="$1"
  local numbers_output number
  local -a numbers=()

  if ! numbers_output=$(gh pr list --state open --head "$sync_branch" \
    --json number --jq '.[].number' 2>/dev/null); then
    echo "::error::could not determine whether an open pull request exists for $sync_branch" >&2
    return 1
  fi
  while IFS= read -r number; do
    if [[ -n "$number" ]]; then
      numbers+=("$number")
    fi
  done <<< "$numbers_output"
  if [[ ${#numbers[@]} -gt 1 ]]; then
    echo "::error::found more than one open pull request for $sync_branch" >&2
    return 1
  fi
  if [[ ${#numbers[@]} -eq 1 ]]; then
    printf '%s\n' "${numbers[0]}"
  fi
}

# Read the title before editing it. Scheduled runs must not create a write
# operation when the title already matches the current upstream version.
ensure_pr_title() {
  local sync_branch="$1"
  local title="$2"
  local current_title

  if ! current_title=$(gh pr view "$sync_branch" --json title --jq '.title' 2>/dev/null); then
    echo "::error::could not read title for $sync_branch" >&2
    return 1
  fi
  if [[ "$current_title" == "$title" ]]; then
    return 0
  fi
  if ! gh pr edit "$sync_branch" --title "$title"; then
    echo "::error::could not update title for $sync_branch" >&2
    return 1
  fi
}

create_sync_pr() {
  local ref="$1"
  local body_file="$2"
  local sync_branch="$3"
  local title="$4"
  local conflict_label="$5"

  # Create the PR from the supplied body file. Start conflicted PRs as drafts
  # and label them before the later notice reconciliation.
  if ! cat > "$body_file" <<'EOF'
Automated sync from the [Freebuff upstream mirror](https://github.com/CodebuffAI/freebuff).
EOF
  then
    echo "::error::could not create the pull request body file" >&2
    return 1
  fi
  if branch_has_conflicts "$ref"; then
    if ! gh pr create --draft --base main --head "$sync_branch" \
      --title "$title" --body-file "$body_file"; then
      echo "::error::could not create the draft pull request for $sync_branch" >&2
      return 1
    fi
    if ! gh pr edit "$sync_branch" --add-label "$conflict_label"; then
      echo "::error::could not add label '$conflict_label' to $sync_branch" >&2
      return 1
    fi
  elif ! gh pr create --base main --head "$sync_branch" \
    --title "$title" --body-file "$body_file"; then
    echo "::error::could not create the pull request for $sync_branch" >&2
    return 1
  fi
}

read_pr_draft_state() {
  local sync_branch="$1"

  if ! gh pr view "$sync_branch" --json isDraft --jq '.isDraft' 2>/dev/null; then
    echo "::error::could not read draft state for $sync_branch" >&2
    return 1
  fi
}

conflict_notice_ids() {
  local sync_branch="$1"
  local repo="$2"
  local pr_number automation_login

  # REST PATCH requires the numeric comment id. The GraphQL node id returned
  # by `gh pr view --json comments` is not valid for this endpoint. Restrict
  # selection to the authenticated account and the marker on the first line.
  if ! pr_number=$(gh pr view "$sync_branch" --json number --jq '.number'); then
    echo "::error::could not read pull request number for $sync_branch" >&2
    return 1
  fi
  if ! automation_login=$(gh api user --jq '.login') || [[ -z "$automation_login" ]]; then
    echo "::error::could not read the authenticated GitHub account" >&2
    return 1
  fi
  if ! SYNC_AUTOMATION_LOGIN="$automation_login" \
    SYNC_CONFLICT_NOTICE_MARKER="$CONFLICT_NOTICE_MARKER" \
    gh api --paginate "repos/$repo/issues/$pr_number/comments" \
    --jq '.[] | select((.user.login // "") == env.SYNC_AUTOMATION_LOGIN and ((.body // "") | split("\n")[0]) == env.SYNC_CONFLICT_NOTICE_MARKER) | .id'; then
    echo "::error::could not read comments for $sync_branch" >&2
    return 1
  fi
}

escape_conflict_notice_filename() {
  local LC_ALL=C
  local value="$1"
  local code control replacement

  value="${value//\\/\\\\}"
  for code in {1..31} 127 {128..159}; do
    printf -v control '%b' "\\$(printf '%03o' "$code")"
    printf -v replacement '\\x%02X' "$code"
    value="${value//"$control"/"$replacement"}"
  done
  printf '%s' "$value"
}

format_conflict_notice_files() {
  local ref="$1"
  local file display fence padded

  # Keep the Git path stream NUL-delimited. Escape control characters and
  # grow the Markdown code fence when a filename contains a backtick.
  while IFS= read -r -d '' file; do
    display=$(escape_conflict_notice_filename "$file")
    fence='`'
    while [[ "$display" == *"$fence"* ]]; do
      fence="${fence}"'`'
    done
    padded="$display"
    if [[ "$display" == ' '* && "$display" == *' ' ]]; then
      padded=" $display "
    fi
    printf -- '- %s%s%s\n' "$fence" "$padded" "$fence"
  done < <(conflicted_files "$ref")
}

update_conflict_notice() {
  local sync_branch="$1"
  local repo="$2"
  local body="$3"
  local notice_ids notice_id

  # Update the owned REST comment when it exists. Otherwise create one through
  # `gh pr comment` so the marker can identify it on the next run.
  if ! notice_ids=$(conflict_notice_ids "$sync_branch" "$repo"); then
    return 1
  fi
  notice_id=${notice_ids%%$'\n'*}
  if [[ -n "$notice_id" ]]; then
    if ! gh api -X PATCH "repos/$repo/issues/comments/$notice_id" -f body="$body"; then
      echo "::error::could not update the conflict notice for $sync_branch" >&2
      return 1
    fi
  elif ! gh pr comment "$sync_branch" --body "$body"; then
    echo "::error::could not create the conflict notice for $sync_branch" >&2
    return 1
  fi
}

reconcile_conflicted_pr() {
  local ref="$1"
  local sync_branch="$2"
  local repo="$3"
  local conflict_label="$4"
  local is_draft="$5"
  local notice_body notice_files

  # A conflict PR must stay in draft state, carry the conflict label, and
  # expose the current file list in the owned notice comment.
  if [[ "$is_draft" != "true" ]] && ! gh pr ready --undo "$sync_branch"; then
    echo "::error::could not convert $sync_branch to draft" >&2
    return 1
  fi
  if ! gh pr edit "$sync_branch" --add-label "$conflict_label"; then
    echo "::error::could not add label '$conflict_label' to $sync_branch" >&2
    return 1
  fi
  notice_files=$(format_conflict_notice_files "$ref")
  notice_body=$(printf '%s\n⚠️ Sync has conflicts in:\n%s\nThe pull request is a draft and stays a draft until the conflicts are resolved.\n' \
    "$CONFLICT_NOTICE_MARKER" "$notice_files")
  update_conflict_notice "$sync_branch" "$repo" "$notice_body"
}

reconcile_resolved_pr() {
  local sync_branch="$1"
  local repo="$2"
  local conflict_label="$3"
  local is_draft="$4"
  local pr_labels="$5"
  local notice_body
  local notice_ids notice_id

  # Remove automation conflict state only when this PR carries its label.
  # Leave manually drafted PRs and unrelated comments unchanged.
  if ! grep -Fqx -- "$conflict_label" <<< "$pr_labels"; then
    return 0
  fi
  if [[ "$is_draft" == "true" ]] && ! gh pr ready "$sync_branch"; then
    echo "::error::could not mark $sync_branch ready for review" >&2
    return 1
  fi
  if ! notice_ids=$(conflict_notice_ids "$sync_branch" "$repo"); then
    return 1
  fi
  notice_id=${notice_ids%%$'\n'*}
  if [[ -n "$notice_id" ]]; then
    notice_body=$(printf '%s\n✔️ Sync conflicts are resolved and the pull request is ready for review.\n' \
      "$CONFLICT_NOTICE_MARKER")
    if ! gh api -X PATCH "repos/$repo/issues/comments/$notice_id" -f body="$notice_body"; then
      echo "::error::could not update the resolved conflict notice for $sync_branch" >&2
      return 1
    fi
  fi
  if ! gh pr edit "$sync_branch" --remove-label "$conflict_label"; then
    echo "::error::could not remove label '$conflict_label' from $sync_branch" >&2
    return 1
  fi
}

reconcile_pr() {
  local ref="$1"
  local body_file="$2"
  local sync_branch="$3"
  local repo="$4"
  local conflict_label="$5"
  local version title open_pr_number is_draft pr_labels

  # Reconcile one candidate ref with its pull request.
  # `ref` is the candidate branch and `body_file` is the temporary PR body.
  # With no open PR, no commits is a no-op and commits create a PR. With one
  # open PR, update its title and then either maintain conflict state or
  # remove it after resolution. A failed PR lookup is an error, not no PR.
  # Return non-zero when any state read or state transition fails.
  version=$(git show "$ref:UPSTREAM_VERSION" 2>/dev/null || true)
  version=$(printf '%s' "$version" | tr -d '[:space:]')
  version="${version:-unknown}"
  title="chore(upstream): sync freebuff ${version}"

  if ! open_pr_number=$(find_open_pr_number "$sync_branch"); then
    return 1
  fi
  if [[ -z "$open_pr_number" ]] && [[ "$(git rev-list --count "main..$ref")" -eq 0 ]]; then
    return 0
  fi
  if [[ -z "$open_pr_number" ]]; then
    if ! create_sync_pr "$ref" "$body_file" "$sync_branch" "$title" "$conflict_label"; then
      return 1
    fi
  elif ! ensure_pr_title "$sync_branch" "$title"; then
    return 1
  fi
  if ! is_draft=$(read_pr_draft_state "$sync_branch"); then
    return 1
  fi

  if branch_has_conflicts "$ref"; then
    reconcile_conflicted_pr "$ref" "$sync_branch" "$repo" "$conflict_label" "$is_draft"
    return $?
  fi
  if ! pr_labels=$(gh pr view "$sync_branch" --json labels --jq '.labels[].name' 2>/dev/null); then
    echo "::error::could not read labels for $sync_branch" >&2
    return 1
  fi
  reconcile_resolved_pr "$sync_branch" "$repo" "$conflict_label" "$is_draft" "$pr_labels"
}
