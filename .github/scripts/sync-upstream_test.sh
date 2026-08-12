#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-upstream.sh"
CHECKS_SCRIPT="$SCRIPT_DIR/upstream-sync-check.sh"
readonly SCRIPT_DIR SYNC_SCRIPT CHECKS_SCRIPT

TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); echo "ok: $1"; }
fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

assert_equals() {
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 — expected '$1', got '$2'"
  fi
}

assert_contains() {
  if grep -qE -- "$1" <<< "$2"; then
    pass "$3"
  else
    fail "$3 — pattern '$1' not found"
  fi
}

assert_contains_literal() {
  if [[ "$2" == *"$1"* ]]; then
    pass "$3"
  else
    fail "$3 — text '$1' not found"
  fi
}

assert_not_contains_literal() {
  if [[ "$2" == *"$1"* ]]; then
    fail "$3 — unexpected text '$1'"
  else
    pass "$3"
  fi
}

assert_file_absent() {
  if [[ -e "$1" ]]; then
    fail "$2 — file still exists: $1"
  else
    pass "$2"
  fi
}

assert_not_contains() {
  if grep -qE -- "$1" <<< "$2"; then
    fail "$3 — unexpected pattern '$1'"
  else
    pass "$3"
  fi
}

assert_status_failed() {
  if [[ "$status" != "0" ]]; then
    pass "$1"
  else
    fail "$1 — sync unexpectedly exited 0"
  fi
}

assert_branch_exists() {
  if origin_has_branch; then
    pass "$1"
  else
    fail "$1 — sync/upstream missing"
  fi
}

assert_no_branch() {
  if origin_has_branch; then
    fail "$1 — sync/upstream exists"
  else
    pass "$1"
  fi
}

mkdir -p "$TEST_ROOT/bin"
cp "$SCRIPT_DIR/test-support/gh-stub.py" "$TEST_ROOT/bin/gh"
chmod +x "$TEST_ROOT/bin/gh"
export PATH="$TEST_ROOT/bin:$PATH"
export GH_STUB_LOG="$TEST_ROOT/gh.log"
export GH_STUB_STATE_FILE="$TEST_ROOT/gh-state.json"
: > "$GH_STUB_LOG"
export GH_STUB_STATE=CLOSED
export GH_STUB_DRAFT=false
export GH_STUB_LABELS=''
export GH_STUB_COMMENTS_JSON='{"comments":[]}'
export GH_STUB_REPO_LABELS='upstream-conflict'
export GH_STUB_LOGIN='freebuffed[bot]'
unset GH_STUB_FAIL
unset GH_STUB_HTTP_STATUS
unset GH_STUB_OPEN_PR_NUMBERS
unset GH_STUB_REPO_LABELS_JSON

fixture_dir=
fixture_upstream=
fixture_fork=
fixture_work=

new_fixture() {
  reset_gh
  local dir="$TEST_ROOT/$1"
  mkdir -p "$dir"
  git init -q --bare --initial-branch=main "$dir/upstream.git"
  git init -q --bare --initial-branch=main "$dir/origin.git"
  git init -q --initial-branch=main "$dir/upstream"
  git -C "$dir/upstream" config user.email t@t
  git -C "$dir/upstream" config user.name t
  echo "v1" > "$dir/upstream/a.txt"
  mkdir -p "$dir/upstream/freebuff/cli/release"
  printf '{"version":"0.0.146"}' > "$dir/upstream/freebuff/cli/release/package.json"
  git -C "$dir/upstream" add -A
  git -C "$dir/upstream" commit -qm "c1"
  git -C "$dir/upstream" remote add origin "$dir/upstream.git"
  git -C "$dir/upstream" push -q origin main

  git clone -q "$dir/upstream" "$dir/fork"
  git -C "$dir/fork" config user.email u@u
  git -C "$dir/fork" config user.name u
  git -C "$dir/upstream" rev-parse HEAD > "$dir/fork/UPSTREAM_SHA"
  echo "0.0.146" > "$dir/fork/UPSTREAM_VERSION"
  echo "fork readme" > "$dir/fork/README.md"
  git -C "$dir/fork" add -A
  git -C "$dir/fork" commit -qm "fork bootstrap"
  git -C "$dir/fork" remote set-url origin "$dir/origin.git"
  git -C "$dir/fork" push -q origin main

  git clone -q "$dir/origin.git" "$dir/work"
  git -C "$dir/work" config user.email w@w
  git -C "$dir/work" config user.name w

  fixture_dir="$dir"
  fixture_upstream="$dir/upstream"
  fixture_fork="$dir/fork"
  fixture_work="$dir/work"
}

run_sync_with_env() {
  if (
    cd "$fixture_work"
    git switch -q main 2>/dev/null || true
    git pull -q origin main 2>/dev/null || true
    if env "$@" \
      UPSTREAM_URL="$fixture_dir/upstream.git" \
      bash "$SYNC_SCRIPT" >"$fixture_dir/sync.out" 2>"$fixture_dir/sync.err"; then
      sync_status=0
    else
      sync_status=$?
    fi
    git fetch -q origin 2>/dev/null || true
    exit "$sync_status"
  ); then
    status=0
  else
    status=$?
  fi
}

run_sync() {
  run_sync_with_env -u GITHUB_ACTIONS -u GH_TOKEN
}

run_sync_ci() {
  run_sync_with_env GITHUB_ACTIONS=true GH_TOKEN=
}

sync_out() { cat "$fixture_dir/sync.out"; }
sync_err() { cat "$fixture_dir/sync.err"; }

upstream_commit() {
  git -C "$fixture_upstream" add -A
  git -C "$fixture_upstream" commit -qm "$1"
  git -C "$fixture_upstream" push -q origin main
}

switch_to_sync_branch() {
  git -C "$fixture_fork" fetch -q origin
  git -C "$fixture_fork" switch -q -C sync/upstream origin/sync/upstream
}

commit_on_sync_branch() {
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "$1"
  git -C "$fixture_fork" push -q origin sync/upstream
}

commit_as_bot_on_sync_branch() {
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" -c user.name="freebuffed[bot]" \
    -c user.email="spoofed@example.com" commit -qm "$1"
  git -C "$fixture_fork" push -q origin sync/upstream
}

merge_sync_branch_into_main() {
  git -C "$fixture_fork" fetch -q origin
  git -C "$fixture_fork" switch -q -C main origin/main
  git -C "$fixture_fork" merge -q --no-ff -m "Merge sync/upstream" origin/sync/upstream
  git -C "$fixture_fork" push -q origin main
}

squash_sync_branch_into_main() {
  git -C "$fixture_fork" fetch -q origin
  git -C "$fixture_fork" switch -q -C main origin/main
  git -C "$fixture_fork" merge -q --squash origin/sync/upstream
  git -C "$fixture_fork" commit -qm "chore(upstream): squash sync"
  git -C "$fixture_fork" push -q origin main
}

rebase_sync_branch_into_main() {
  git -C "$fixture_fork" fetch -q origin
  git -C "$fixture_fork" switch -q -C main origin/main
  echo "pre-merge fork change" > "$fixture_fork/pre-merge.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "fix: fork change before rebase merge"
  git -C "$fixture_fork" push -q origin main
  git -C "$fixture_fork" switch -q -C rebased-sync origin/sync/upstream
  git -C "$fixture_fork" rebase -q main
  git -C "$fixture_fork" switch -q main
  git -C "$fixture_fork" merge -q --ff-only rebased-sync
  git -C "$fixture_fork" push -q origin main
}

branch_file() { git -C "$fixture_work" show "origin/sync/upstream:$1" 2>/dev/null; }
branch_log() {
  git -C "$fixture_work" log --oneline --format='%h %an %s' origin/sync/upstream 2>/dev/null
}
branch_top() {
  git -C "$fixture_work" log -1 --format='%h %an %s' origin/sync/upstream 2>/dev/null
}
origin_has_branch() {
  local tip
  tip=$(git -C "$fixture_work" ls-remote origin refs/heads/sync/upstream 2>/dev/null)
  [[ -n "$tip" ]]
}

assert_branch_descends_from_main() {
  if git -C "$fixture_work" merge-base --is-ancestor origin/main origin/sync/upstream; then
    pass "$1"
  else
    fail "$1 — sync/upstream is not based on current main"
  fi
}

gh_log() {
  if [[ ! -e "$GH_STUB_LOG" ]]; then
    echo "gh_log: $GH_STUB_LOG is missing — the gh stub never wrote a log for this fixture" >&2
    return 1
  fi
  cat "$GH_STUB_LOG"
}

NOTICE_COMMENT_JSON='{"comments":[{"id":"IC_kwDOT2TnS86Y42","rest_id":42,"user":{"login":"freebuffed[bot]"},"body":"<!-- sync-conflict-notice -->"}]}'
readonly NOTICE_COMMENT_JSON

MIXED_NOTICE_COMMENT_JSON='{"comments":[{"id":"IC_kwDOT2TnS86Y41","rest_id":41,"user":{"login":"maintainer"},"body":"<!-- sync-conflict-notice -->\npublic comment"},{"id":"IC_kwDOT2TnS86Y42","rest_id":42,"user":{"login":"freebuffed[bot]"},"body":"context\n<!-- sync-conflict-notice -->\nmisplaced marker"},{"id":"IC_kwDOT2TnS86Y43","rest_id":43,"user":{"login":"freebuffed[bot]"},"body":"<!-- sync-conflict-notice -->\nautomation comment"}]}'
readonly MIXED_NOTICE_COMMENT_JSON

commit_on_main_branch() {
  git -C "$fixture_fork" switch -q main
  printf '%s\n' "$2" > "$fixture_fork/$1"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "$3"
  git -C "$fixture_fork" push -q origin main
}

assert_title_edited() {
  assert_contains "pr edit sync/upstream --title chore\\(upstream\\): sync freebuff $1" \
    "$2" "PR title advanced to $1"
}

reset_gh() {
  : > "$TEST_ROOT/gh.log"
  rm -f "$TEST_ROOT/gh-state.json"
  export GH_STUB_STATE=CLOSED
  export GH_STUB_DRAFT=false
  export GH_STUB_LABELS=''
  export GH_STUB_COMMENTS_JSON='{"comments":[]}'
  export GH_STUB_REPO_LABELS='upstream-conflict'
  export GH_STUB_LOGIN='freebuffed[bot]'
  unset GH_STUB_FAIL
  unset GH_STUB_HTTP_STATUS
  unset GH_STUB_OPEN_PR_NUMBERS
  unset GH_STUB_REPO_LABELS_JSON
}

test_already_up_to_date() {
  new_fixture "already-up-to-date"
  run_sync
  assert_equals "0" "$status" "no-op exits 0"
  assert_contains "Up to date" "$(sync_out)" "reports up to date"
  assert_no_branch "creates no branch"
  assert_not_contains "pr create" "$(gh_log)" "creates no PR"
}

test_pr_module_sourcing_has_no_side_effects() {
  module_output=$(bash -c 'source "$1"; printf loaded' _ \
    "$SCRIPT_DIR/sync-upstream-pr.sh")
  assert_equals "loaded" "$module_output" "PR module can be sourced without work"
}

test_clean_upstream_update() {
  new_fixture "clean-update"
  echo "v2" > "$fixture_upstream/a.txt"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)

  run_sync
  assert_equals "0" "$status" "sync exits 0"
  assert_branch_exists "branch created"
  assert_equals "v2" "$(branch_file a.txt)" "upstream change to a.txt applied"
  assert_equals "upstream file" "$(branch_file b.txt)" "upstream file b.txt added"
  assert_equals "fork readme" "$(branch_file README.md)" "fork-local README intact"
  assert_equals "$upstream_head" "$(branch_file UPSTREAM_SHA)" "marker advanced to upstream head"
  assert_contains "pr create" "$(gh_log)" "PR created"
}

test_body_file_path_with_spaces() {
  new_fixture "body-file-spaces"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  body_tmp_dir="$fixture_dir/tmp directory"
  mkdir -p "$body_tmp_dir"

  run_sync_with_env TMPDIR="$body_tmp_dir"
  assert_equals "0" "$status" "body-file path with spaces succeeds"
}

test_conflict_then_resolution() {
  new_fixture "conflict-cycle"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  switch_to_sync_branch
  echo "user line" >> "$fixture_fork/a.txt"
  commit_on_sync_branch "fix: manual edit"
  echo "v3" > "$fixture_upstream/a.txt"
  upstream_commit "c3"
  GH_STUB_STATE=OPEN

  run_sync
  assert_equals "0" "$status" "conflicted sync exits 0"
  conflicted_text=$(branch_file a.txt)
  assert_contains '^<<<<<<< ' "$conflicted_text" "conflict markers left in diff"
  assert_contains '^>>>>>>> ' "$conflicted_text" "conflict markers left in diff"
  assert_contains "pr ready --undo" "$(gh_log)" "PR set to draft"
  assert_contains "pr edit sync/upstream --add-label upstream-conflict" \
    "$(gh_log)" "conflict label added"
  assert_contains "pr comment" "$(gh_log)" "conflict comment posted"

  switch_to_sync_branch
  printf 'v3\nuser line\n' > "$fixture_fork/a.txt"
  commit_on_sync_branch "fix: resolve conflict"
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_LABELS='upstream-conflict'
  GH_STUB_DRAFT=true
  export GH_STUB_COMMENTS_JSON="$NOTICE_COMMENT_JSON"

  run_sync
  unset GH_STUB_COMMENTS_JSON
  assert_equals "0" "$status" "resolution run exits 0"
  assert_contains "Up to date" "$(sync_out)" "resolution run is a no-op"
  gh_actions=$(gh_log)
  assert_contains "pr ready" "$gh_actions" "PR marked as ready for review"
  assert_not_contains "pr ready --undo" "$gh_actions" "PR not drafted again"
  assert_contains "pr edit sync/upstream --remove-label upstream-conflict" \
    "$gh_actions" "conflict label removed"
  assert_contains "PATCH" "$gh_actions" "stale conflict notice updated to resolved"
  assert_contains "ready for review" "$(cat "$TEST_ROOT/gh-state.json")" \
    "stale conflict notice body updated"
  assert_not_contains "pr comment" "$gh_actions" "no new comment posted on resolution"
  GH_STUB_LABELS=''
}

test_excluded_only_change_advances_marker() {
  new_fixture "excluded-only-change"
  echo "upstream docs" > "$fixture_upstream/README.md"
  upstream_commit "docs: readme"
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)

  run_sync
  assert_equals "0" "$status" "sync exits 0"
  assert_branch_exists "branch created"
  assert_equals "$upstream_head" "$(branch_file UPSTREAM_SHA)" \
    "marker advanced despite excluded-only change"
  assert_equals "fork readme" "$(branch_file README.md)" "upstream README change not applied"
  assert_contains "sync freebuff 0.0.146" "$(branch_top)" "marker-only commit"
  assert_contains "pr create" "$(gh_log)" "PR created"
}

test_existing_branch_appends() {
  new_fixture "existing-branch"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN

  run_sync
  assert_equals "0" "$status" "second sync exits 0"
  assert_equals "upstream file" "$(branch_file b.txt)" "first update applied"
  assert_equals "more" "$(branch_file c.txt)" "second update applied"
  assert_equals "2" "$(grep -c 'chore(upstream)' <<< "$(branch_log)")" "two appended sync commits"
  assert_not_contains "pr create" "$(gh_log)" "PR reused, not recreated"
}

test_manual_edits_preserved() {
  new_fixture "manual-edits"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  switch_to_sync_branch
  echo "manual user fix" > "$fixture_fork/manual.txt"
  commit_as_bot_on_sync_branch "fix: manual resolution"
  echo "v3" > "$fixture_upstream/a.txt"
  upstream_commit "c3"
  GH_STUB_STATE=OPEN

  run_sync
  assert_equals "0" "$status" "append exits 0"
  assert_equals "manual user fix" "$(branch_file manual.txt)" "manual.txt preserved"
  assert_contains "fix: manual resolution" "$(branch_log)" "manual commit still in history"
  assert_contains 'chore\(upstream\)' "$(branch_top)" "bot appended on top"
}

test_missing_and_invalid_marker() {
  new_fixture "marker-errors"
  git -C "$fixture_fork" rm -q UPSTREAM_SHA
  git -C "$fixture_fork" commit -qm "drop marker"
  git -C "$fixture_fork" push -q origin main

  run_sync
  assert_status_failed "missing marker fails"
  assert_contains "UPSTREAM_SHA is empty" "$(sync_err)" "missing marker reported"

  echo "0123456789abcdef0123456789abcdef01234567" > "$fixture_fork/UPSTREAM_SHA"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "bad marker"
  git -C "$fixture_fork" push -q origin main

  run_sync
  assert_status_failed "invalid marker fails"
  assert_contains "is not a commit" "$(sync_err)" "invalid marker reported"
  assert_no_branch "no branch created on error"
}

test_upstream_branch_lookup_failure() {
  new_fixture "branch-lookup-failure"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  export UPSTREAM_BRANCH=does-not-exist

  run_sync
  unset UPSTREAM_BRANCH
  assert_status_failed "fetch failure exits non-zero"
  assert_no_branch "no branch created"
  assert_not_contains "pr create" "$(gh_log)" "no PR created"
}

test_check_script_missing_branch() {
  new_fixture "check-missing-branch"
  if (
    cd "$fixture_fork"
    UPSTREAM_URL="$fixture_dir/upstream.git" UPSTREAM_BRANCH=does-not-exist \
      bash "$CHECKS_SCRIPT" >"$fixture_dir/check.out" 2>"$fixture_dir/check.err"
  ); then
    status=0
  else
    status=$?
  fi
  assert_status_failed "check fails when the branch lookup is empty"
  assert_contains "not found" "$(cat "$fixture_dir/check.err")" "missing branch reported"
}

test_check_script_tag_collision() {
  new_fixture "check-tag-collision"
  git -C "$fixture_upstream" tag main
  git -C "$fixture_upstream" push -q origin \
    refs/heads/main:refs/heads/main refs/tags/main:refs/tags/main
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)

  if (
    cd "$fixture_fork"
    UPSTREAM_URL="$fixture_dir/upstream.git" \
      GITHUB_OUTPUT="$fixture_dir/check.out" \
      bash "$CHECKS_SCRIPT" >"$fixture_dir/check.log" 2>"$fixture_dir/check.err"
  ); then
    status=0
  else
    status=$?
  fi
  assert_equals "0" "$status" "check exits 0 with a tag named like the branch"
  assert_contains "^upstream_sha=${upstream_head}$" \
    "$(cat "$fixture_dir/check.out")" "branch head only, single line"
  assert_equals "3" "$(wc -l < "$fixture_dir/check.out" | tr -d ' ')" \
    "output has exactly three lines"
}

test_check_script_github_outputs() {
  new_fixture "check-outputs"
  marker=$(tr -d '[:space:]' < "$fixture_fork/UPSTREAM_SHA")
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)

  if (
    cd "$fixture_fork"
    UPSTREAM_URL="$fixture_dir/upstream.git" \
      GITHUB_OUTPUT="$fixture_dir/check.out" \
      bash "$CHECKS_SCRIPT" >"$fixture_dir/check.log" 2>"$fixture_dir/check.err"
  ); then
    status=0
  else
    status=$?
  fi
  check_out=$(cat "$fixture_dir/check.out")
  assert_equals "0" "$status" "up-to-date check exits 0"
  assert_contains "^changed=false$" "$check_out" "up-to-date reports changed=false"
  assert_contains "^upstream_sha=${upstream_head}$" "$check_out" \
    "up-to-date reports the upstream head"
  assert_contains "^marker=${marker}$" "$check_out" "up-to-date reports the marker"

  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  new_head=$(git -C "$fixture_upstream" rev-parse HEAD)
  if (
    cd "$fixture_fork"
    UPSTREAM_URL="$fixture_dir/upstream.git" \
      GITHUB_OUTPUT="$fixture_dir/check.out" \
      bash "$CHECKS_SCRIPT" >"$fixture_dir/check.log" 2>"$fixture_dir/check.err"
  ); then
    status=0
  else
    status=$?
  fi
  check_out=$(cat "$fixture_dir/check.out")
  assert_equals "0" "$status" "new-commits check exits 0"
  assert_contains "^changed=true$" "$check_out" "new-commits reports changed=true"
  assert_contains "^upstream_sha=${new_head}$" "$check_out" "new-commits reports the new head"
  assert_contains "^marker=${marker}$" "$check_out" "new-commits keeps the old marker"
}

test_version_from_synced_tree() {
  new_fixture "version-from-tree"
  printf '{"version":"0.0.147"}' > "$fixture_upstream/freebuff/cli/release/package.json"
  echo "more" > "$fixture_upstream/b.txt"
  upstream_commit "c2"

  run_sync
  assert_equals "0" "$status" "sync exits 0"
  assert_equals "0.0.147" "$(branch_file UPSTREAM_VERSION)" "UPSTREAM_VERSION from tree"
  assert_contains "sync freebuff 0.0.147" "$(branch_top)" "commit message carries tree version"
}

test_filenames_with_spaces() {
  new_fixture "filenames-with-spaces"
  echo "spaced content" > "$fixture_upstream/file with spaces.txt"
  upstream_commit "c2"

  run_sync
  assert_equals "0" "$status" "sync exits 0"
  assert_equals "spaced content" "$(branch_file "file with spaces.txt")" "spaced filename applied"
}

test_conflict_notice_non_ascii_path() {
  new_fixture "notice-non-ascii"
  commit_on_main_branch "café.txt" "fork line" "fix: fork-local edit"
  echo "upstream" > "$fixture_upstream/café.txt"
  upstream_commit "c2"

  run_sync
  assert_equals "0" "$status" "conflicted sync exits 0"
  gh_actions=$(gh_log)
  assert_contains "café.txt" "$gh_actions" "notice lists the readable non-ASCII path"
  assert_not_contains '"caf' "$gh_actions" "notice does not contain the quoted octal-escaped path"
}

test_conflict_notice_lists_files_as_bullets() {
  new_fixture "notice-bullets"
  commit_on_main_branch "file with spaces.txt" "fork line" "fix: fork-local edit"
  echo "upstream" > "$fixture_upstream/file with spaces.txt"
  upstream_commit "c2"

  run_sync
  assert_equals "0" "$status" "conflicted sync exits 0"
  assert_contains "Applied with conflicts in:" "$(sync_out)" "conflict apply logged"
  gh_actions=$(gh_log)
  assert_contains "pr comment" "$gh_actions" "conflict notice posted"
  tick=$(printf '\140')
  assert_contains "- ${tick}file with spaces.txt${tick}" "$gh_actions" \
    "notice lists the spaced filename as one bullet"
  assert_contains "file with spaces.txt" "$(sync_out)" "spaced filename kept intact in the log"
}

test_conflict_notice_formats_special_paths() {
  new_fixture "notice-special-paths"
  newline_file=$'line\nbreak.txt'
  backtick_file='back`tick.txt'
  tab_file=$'tab\tname.txt'
  commit_on_main_branch "$newline_file" "fork line" "fix: fork-local newline path edit"
  commit_on_main_branch "$backtick_file" "fork line" "fix: fork-local backtick path edit"
  commit_on_main_branch "$tab_file" "fork line" "fix: fork-local tab path edit"
  printf 'upstream\n' > "$fixture_upstream/$newline_file"
  printf 'upstream\n' > "$fixture_upstream/$backtick_file"
  printf 'upstream\n' > "$fixture_upstream/$tab_file"
  upstream_commit "c2"

  run_sync
  assert_equals "0" "$status" "special-path conflict sync exits 0"
  notice_body=$(python3 - "$TEST_ROOT/gh-state.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    state = json.load(handle)
print(state["pr"]["comments"][-1]["body"])
PY
  )
  tick=$(printf '\140')
  assert_contains_literal "- ${tick}line\\x0Abreak.txt${tick}" "$notice_body" \
    "newline path is escaped as one notice bullet"
  assert_contains_literal "- ${tick}${tick}back${tick}tick.txt${tick}${tick}" "$notice_body" \
    "backtick path uses a safe code span"
  assert_contains_literal "- ${tick}tab\\x09name.txt${tick}" "$notice_body" \
    "tab path is escaped as one notice bullet"
  assert_not_contains_literal $'line\nbreak.txt' "$notice_body" \
    "notice does not contain a raw newline path"
}

test_missing_token_in_ci_mode() {
  new_fixture "missing-token"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"

  run_sync_ci
  assert_status_failed "missing token fails"
  assert_contains "GH_TOKEN is empty" "$(sync_err)" "missing token reported"
}

test_ci_push_does_not_expose_token_in_argv() {
  new_fixture "ci-push-credentials"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"

  git_wrapper_dir="$fixture_dir/git-wrapper"
  mkdir -p "$git_wrapper_dir"
  real_git=$(command -v git)
  cat > "$git_wrapper_dir/git" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "push" ]]; then
  printf '%s\n' "$*" > "$GIT_PUSH_ARGS_FILE"
  if [[ -n "${GIT_ASKPASS:-}" ]]; then
    printf '%s\n' "$GIT_ASKPASS" > "$GIT_ASKPASS_PATH_FILE"
    ls -ld "$GIT_ASKPASS" | awk '{print substr($1, 1, 10)}' > "$GIT_ASKPASS_MODE_FILE"
  else
    : > "$GIT_ASKPASS_PATH_FILE"
    : > "$GIT_ASKPASS_MODE_FILE"
  fi
  args=("$@")
  if [[ "${args[1]:-}" == https://*github.com/* ]]; then
    args[1]="$FIXTURE_ORIGIN"
  fi
  exec "$REAL_GIT" "${args[@]}"
fi

exec "$REAL_GIT" "$@"
BASH
  chmod +x "$git_wrapper_dir/git"

  run_sync_with_env \
    GITHUB_ACTIONS=true \
    GH_TOKEN='ci-test-token' \
    PATH="$git_wrapper_dir:$PATH" \
    REAL_GIT="$real_git" \
    FIXTURE_ORIGIN="$fixture_dir/origin.git" \
    GIT_PUSH_ARGS_FILE="$fixture_dir/git-push-args" \
    GIT_ASKPASS_PATH_FILE="$fixture_dir/git-askpass-path" \
    GIT_ASKPASS_MODE_FILE="$fixture_dir/git-askpass-mode"
  assert_equals "0" "$status" "CI push succeeds with the credential helper"
  assert_not_contains "ci-test-token" "$(cat "$fixture_dir/git-push-args")" \
    "CI push does not place the token in git arguments"
  assert_equals "-rwx------" "$(cat "$fixture_dir/git-askpass-mode")" \
    "credential helper has restrictive permissions"
  askpass_path=$(cat "$fixture_dir/git-askpass-path")
  assert_file_absent "$askpass_path" "credential helper is removed after the push"
}

test_open_pr_title_advances() {
  new_fixture "open-pr-title"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  printf '{"version":"0.0.147"}' > "$fixture_upstream/freebuff/cli/release/package.json"
  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN

  run_sync
  assert_equals "0" "$status" "second sync exits 0"
  assert_equals "0.0.147" "$(branch_file UPSTREAM_VERSION)" "marker version advanced"
  assert_contains "sync freebuff 0.0.147" "$(branch_top)" "commit carries 0.0.147"
  gh_actions=$(gh_log)
  assert_title_edited "0.0.147" "$gh_actions"
  assert_not_contains "pr create" "$gh_actions" "PR reused, not recreated"
}

test_open_pr_title_unchanged_is_not_edited() {
  new_fixture "open-pr-title-unchanged"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  : > "$GH_STUB_LOG"
  run_sync
  assert_equals "0" "$status" "unchanged-title sync exits 0"
  assert_not_contains "pr edit sync/upstream --title" "$(gh_log)" \
    "unchanged PR title is not edited"
}

test_title_fallback_to_unknown() {
  new_fixture "unknown-version"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  switch_to_sync_branch
  git -C "$fixture_fork" rm -q UPSTREAM_VERSION
  commit_on_sync_branch "chore: drop version marker"
  reset_gh
  GH_STUB_STATE=OPEN

  run_sync
  assert_equals "0" "$status" "no-op run exits 0"
  assert_title_edited "unknown" "$(gh_log)"
}

test_manual_draft_left_alone() {
  new_fixture "manual-draft"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  reset_gh
  GH_STUB_STATE=OPEN
  run_sync
  assert_equals "0" "$status" "no-op run exits 0"
  gh_actions=$(gh_log)
  assert_not_contains "pr ready" "$gh_actions" "manual draft survives a no-op run"

  reset_gh
  GH_STUB_STATE=OPEN
  echo "v3" > "$fixture_upstream/a.txt"
  upstream_commit "c3"
  run_sync
  assert_equals "0" "$status" "clean sync exits 0"
  gh_actions=$(gh_log)
  assert_not_contains "pr ready" "$gh_actions" "manual draft survives a clean sync"
  assert_not_contains "pr create" "$gh_actions" "PR reused, not recreated"
}

test_new_conflicted_pr_created_draft() {
  new_fixture "conflicted-create"
  commit_on_main_branch "a.txt" "fork line" "fix: fork-local edit"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  GH_STUB_DRAFT=true

  run_sync
  gh_actions=$(gh_log)
  assert_equals "0" "$status" "conflicted first sync exits 0"
  assert_contains "pr create --draft" "$gh_actions" "conflicted PR created as draft"
  assert_contains "pr edit sync/upstream --add-label upstream-conflict" \
    "$gh_actions" "conflict label added at create"
  assert_not_contains "pr ready --undo" "$gh_actions" "fresh create never drafts via ready --undo"
  assert_contains "pr comment" "$gh_actions" "conflict comment posted"
}

test_remaining_separator_marker_keeps_pr_in_conflict_state() {
  new_fixture "remaining-separator-marker"
  commit_on_main_branch "a.txt" "fork line" "fix: fork-local edit"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"

  run_sync
  assert_equals "0" "$status" "first conflicted sync exits 0"

  switch_to_sync_branch
  printf '=======\n' > "$fixture_fork/a.txt"
  commit_on_sync_branch "fix: partial conflict resolution"
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  GH_STUB_LABELS='upstream-conflict'

  run_sync
  assert_equals "0" "$status" "separator-marker sync exits 0"
  gh_actions=$(gh_log)
  assert_not_contains "pr ready sync/upstream" "$gh_actions" \
    "separator marker keeps PR in draft state"
  assert_not_contains "pr edit sync/upstream --remove-label upstream-conflict" \
    "$gh_actions" "separator marker keeps conflict label"
}

test_apply_failure_not_misclassified() {
  new_fixture "apply-failure"
  git -C "$fixture_fork" rm -q a.txt
  printf '<<<<<<< HEAD\nexample\n>>>>>>> branch\n' > "$fixture_fork/example-conflict.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "fix: fork-local changes"
  git -C "$fixture_fork" push -q origin main
  git -C "$fixture_upstream" rm -q a.txt
  upstream_commit "c2"

  run_sync
  assert_status_failed "failed apply exits non-zero"
  assert_contains "could not be applied" "$(sync_err)" "hard failure reported"
  assert_no_branch "no sync branch pushed"
}

test_marker_example_outside_change_set() {
  new_fixture "marker-example"
  printf '<<<<<<< HEAD\nexample\n>>>>>>> branch\n' > "$fixture_fork/example-conflict.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "docs: conflict marker example"
  git -C "$fixture_fork" push -q origin main
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"

  run_sync
  gh_actions=$(gh_log)
  assert_equals "0" "$status" "clean sync exits 0"
  assert_not_contains "pr create --draft" "$gh_actions" "PR created ready"
  assert_not_contains "pr edit sync/upstream --add-label" "$gh_actions" "no conflict label"
  assert_not_contains "pr ready --undo" "$gh_actions" "no draft toggling"
}

test_missing_and_invalid_branch_marker() {
  new_fixture "branch-marker-errors"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  switch_to_sync_branch
  git -C "$fixture_fork" rm -q UPSTREAM_SHA
  commit_on_sync_branch "chore: drop branch marker"
  run_sync
  assert_status_failed "missing branch marker fails"
  assert_contains "has no UPSTREAM_SHA" "$(sync_err)" "missing branch marker reported"
  assert_contains "chore: drop branch marker" "$(branch_top)" "branch unchanged"

  switch_to_sync_branch
  echo "0123456789abcdef0123456789abcdef01234567" > "$fixture_fork/UPSTREAM_SHA"
  commit_on_sync_branch "chore: bad branch marker"
  run_sync
  assert_status_failed "invalid branch marker fails"
  assert_contains "is not a commit" "$(sync_err)" "invalid branch marker reported"
  assert_contains "chore: bad branch marker" "$(branch_top)" "branch unchanged"
}

test_remote_advance_rejects_push() {
  new_fixture "remote-advance"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  git clone -q "$fixture_dir/origin.git" "$fixture_dir/competing"
  git -C "$fixture_dir/competing" config user.email o@o
  git -C "$fixture_dir/competing" config user.name o
  cat > "$fixture_work/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
git -C "$fixture_dir/competing" fetch -q origin
git -C "$fixture_dir/competing" switch -q -C sync/upstream origin/sync/upstream
echo "competing" > "$fixture_dir/competing/competing.txt"
git -C "$fixture_dir/competing" add -A
git -C "$fixture_dir/competing" -c user.name=other -c user.email=o@o \
  commit -qm "chore: competing change"
git -C "$fixture_dir/competing" push -q origin sync/upstream
exit 0
EOF
  chmod +x "$fixture_work/.git/hooks/pre-push"

  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN

  run_sync
  assert_status_failed "push rejected when remote advanced"
  assert_contains "rejected" "$(sync_err)" "non-fast-forward rejection reported"
  assert_not_contains "pr create" "$(gh_log)" "no PR created after failed push"
}

test_closed_pr_branch_not_reused() {
  new_fixture "closed-pr"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"
  old_tip=$(git -C "$fixture_work" ls-remote origin refs/heads/sync/upstream | awk '{print $1}')

  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh

  run_sync
  assert_status_failed "closed PR does not reuse its branch"
  assert_equals "$old_tip" \
    "$(git -C "$fixture_work" ls-remote origin refs/heads/sync/upstream | awk '{print $1}')" \
    "closed PR branch remains unchanged"
}

test_merged_pr_not_recreated() {
  new_fixture "merged-pr"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  git -C "$fixture_fork" fetch -q origin
  git -C "$fixture_fork" switch -q -C main origin/main
  git -C "$fixture_fork" merge -q --ff-only origin/sync/upstream
  git -C "$fixture_fork" push -q origin main
  reset_gh
  GH_STUB_STATE=MERGED

  run_sync
  assert_equals "0" "$status" "no-op after merge exits 0"
  assert_contains "Up to date" "$(sync_out)" "reports up to date"
  gh_actions=$(gh_log)
  assert_not_contains "pr create" "$gh_actions" "no PR recreated after merge"
  assert_not_contains "pr ready" "$gh_actions" "no draft toggling after merge"
}

test_merged_pr_uses_current_main_after_merge_commit() {
  new_fixture "merged-pr-current-main-merge"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  merge_sync_branch_into_main
  commit_on_main_branch "a.txt" "fork line after merge" "fix: main edit after merge"
  echo "v3" > "$fixture_upstream/a.txt"
  upstream_commit "c3"
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)
  reset_gh
  GH_STUB_STATE=MERGED

  run_sync
  assert_equals "0" "$status" "merge-commit follow-up exits 0"
  assert_contains '^<<<<<<< ' "$(branch_file a.txt)" \
    "merge-commit follow-up leaves conflict markers"
  assert_contains "fork line after merge" "$(branch_file a.txt)" \
    "merge-commit follow-up keeps the main change"
  assert_equals "$upstream_head" "$(branch_file UPSTREAM_SHA)" \
    "merge-commit follow-up advances the marker"
  assert_branch_descends_from_main "merge-commit follow-up uses current main"
  assert_contains "pr create --draft" "$(gh_log)" \
    "merge-commit follow-up creates a draft conflict PR"
}

test_merged_pr_uses_current_main_after_squash_merge() {
  new_fixture "merged-pr-current-main-squash"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  squash_sync_branch_into_main
  commit_on_main_branch "a.txt" "fork line after squash" "fix: main edit after squash"
  echo "v3" > "$fixture_upstream/a.txt"
  upstream_commit "c3"
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)
  reset_gh
  GH_STUB_STATE=MERGED

  run_sync
  assert_equals "0" "$status" "squash follow-up exits 0"
  assert_contains '^<<<<<<< ' "$(branch_file a.txt)" \
    "squash follow-up leaves conflict markers"
  assert_contains "fork line after squash" "$(branch_file a.txt)" \
    "squash follow-up keeps the main change"
  assert_equals "$upstream_head" "$(branch_file UPSTREAM_SHA)" \
    "squash follow-up advances the marker"
  assert_branch_descends_from_main "squash follow-up uses current main"
  assert_contains "pr create --draft" "$(gh_log)" \
    "squash follow-up creates a draft conflict PR"
}

test_merged_pr_uses_current_main_after_rebase_merge() {
  new_fixture "merged-pr-current-main-rebase"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  rebase_sync_branch_into_main
  commit_on_main_branch "a.txt" "fork line after rebase" "fix: main edit after rebase"
  echo "v3" > "$fixture_upstream/a.txt"
  upstream_commit "c3"
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)
  reset_gh
  GH_STUB_STATE=MERGED

  run_sync
  assert_equals "0" "$status" "rebase follow-up exits 0"
  assert_contains '^<<<<<<< ' "$(branch_file a.txt)" \
    "rebase follow-up leaves conflict markers"
  assert_contains "fork line after rebase" "$(branch_file a.txt)" \
    "rebase follow-up keeps the main change"
  assert_equals "$upstream_head" "$(branch_file UPSTREAM_SHA)" \
    "rebase follow-up advances the marker"
  assert_branch_descends_from_main "rebase follow-up uses current main"
  assert_contains "pr create --draft" "$(gh_log)" \
    "rebase follow-up creates a draft conflict PR"
}

test_reconcile_pr_state_read_failure_does_not_create_duplicate() {
  new_fixture "reconcile-state-read-failure"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  merge_sync_branch_into_main
  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)
  reset_gh
  GH_STUB_STATE=OPEN
  export GH_STUB_FAIL='pr list*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "open PR lookup failure stops reconciliation"
  assert_contains "could not determine whether an open pull request exists" \
    "$(sync_err)" "open PR lookup failure is reported"
  assert_not_contains "pr create" "$(gh_log)" \
    "open PR lookup failure does not create a duplicate PR"
  assert_equals "$upstream_head" "$(branch_file UPSTREAM_SHA)" \
    "sync commit remains available after reconciliation failure"
}

test_gh_create_failure_aborts() {
  new_fixture "gh-create-fail"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  export GH_STUB_FAIL='pr create*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "gh pr create failure aborts sync"
  assert_branch_exists "branch pushed before create failure"
}

test_gh_edit_failure_aborts() {
  new_fixture "gh-edit-fail"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN
  export GH_STUB_FAIL='pr edit*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "gh pr edit failure aborts sync"
  assert_contains "sync freebuff" "$(branch_top)" "branch appended before edit failure"
}

test_title_reconciled_after_failure() {
  new_fixture "title-recovery"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  printf '{"version":"0.0.147"}' > "$fixture_upstream/freebuff/cli/release/package.json"
  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN
  export GH_STUB_FAIL='pr edit sync/upstream --title*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "title update failure fails the sync"
  assert_equals "0.0.147" "$(branch_file UPSTREAM_VERSION)" "marker advanced despite title failure"

  reset_gh
  GH_STUB_STATE=OPEN
  run_sync
  assert_equals "0" "$status" "no-op run exits 0"
  assert_title_edited "0.0.147" "$(gh_log)"
}

test_label_failure_reconciled() {
  new_fixture "label-recovery"
  commit_on_main_branch "a.txt" "fork line" "fix: fork-local edit"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  export GH_STUB_FAIL='pr edit sync/upstream --add-label*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "label add failure fails the sync"
  assert_contains "pr create --draft" "$(gh_log)" "conflicted PR created before label failure"

  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  run_sync
  assert_equals "0" "$status" "recovery run exits 0"
  assert_contains "pr edit sync/upstream --add-label upstream-conflict" \
    "$(gh_log)" "label added on retry"
}

test_ready_failure_reconciled() {
  new_fixture "ready-recovery"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_LABELS='upstream-conflict'
  GH_STUB_DRAFT=true
  export GH_STUB_FAIL='pr ready sync/upstream'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "ready failure fails the sync"
  gh_actions=$(gh_log)
  assert_not_contains "pr edit sync/upstream --remove-label" "$gh_actions" "label kept for retry"

  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_LABELS='upstream-conflict'
  GH_STUB_DRAFT=true
  run_sync
  assert_equals "0" "$status" "recovery run exits 0"
  gh_actions=$(gh_log)
  assert_contains "pr ready sync/upstream" "$gh_actions" "PR marked ready on retry"
  assert_contains "pr edit sync/upstream --remove-label upstream-conflict" \
    "$gh_actions" "label removed after ready"
}

test_labels_read_failure_aborts() {
  new_fixture "labels-read-fail"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_LABELS='upstream-conflict'
  GH_STUB_DRAFT=true
  export GH_STUB_FAIL='pr view sync/upstream --json labels*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "labels read failure fails the sync"
  assert_contains "could not read labels" "$(sync_err)" "labels read failure reported"
  assert_not_contains "pr edit sync/upstream --remove-label" "$(gh_log)" \
    "label not removed on failed read"
}

test_comment_failure_reconciled() {
  new_fixture "comment-recovery"
  commit_on_main_branch "a.txt" "fork line" "fix: fork-local edit"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  export GH_STUB_FAIL='pr comment*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "comment failure fails the sync"
  assert_contains "pr create --draft" "$(gh_log)" "conflicted PR created before comment failure"

  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  run_sync
  assert_equals "0" "$status" "recovery run exits 0"
  assert_contains "pr comment" "$(gh_log)" "conflict notice posted on retry"

  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  export GH_STUB_COMMENTS_JSON="$NOTICE_COMMENT_JSON"
  run_sync
  unset GH_STUB_COMMENTS_JSON
  assert_equals "0" "$status" "duplicate-notice run exits 0"
  assert_not_contains "pr comment" "$(gh_log)" "existing conflict notice not duplicated"
  assert_contains "PATCH" "$(gh_log)" "existing conflict notice updated in place"
}

test_conflict_notice_updated_for_later_conflict() {
  new_fixture "notice-update"
  commit_on_main_branch "a.txt" "fork line" "fix: fork-local edit"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first conflicted sync exits 0"
  assert_contains "pr comment" "$(gh_log)" "first conflict notice posted"

  switch_to_sync_branch
  printf 'v2\nfork line\n' > "$fixture_fork/a.txt"
  echo "fork edit" > "$fixture_fork/b.txt"
  commit_on_sync_branch "fix: resolve first conflict"
  echo "upstream b" > "$fixture_upstream/b.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  export GH_STUB_COMMENTS_JSON="$NOTICE_COMMENT_JSON"

  run_sync
  unset GH_STUB_COMMENTS_JSON
  assert_equals "0" "$status" "later-conflict sync exits 0"
  gh_actions=$(gh_log)
  assert_contains "b.txt" "$gh_actions" "notice updated with the later conflicted file"
  assert_not_contains "sync/upstream:" "$gh_actions" "notice lists plain paths, not rev-prefixed"
  assert_not_contains "pr comment" "$gh_actions" "existing notice not recreated"
  assert_contains "PATCH" "$gh_actions" "existing notice updated in place"
  assert_contains "b.txt" "$(cat "$TEST_ROOT/gh-state.json")" \
    "existing notice body updated with the later conflict"
}

test_state_read_failure_leaves_branch_unchanged() {
  new_fixture "state-read-recovery"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN
  export GH_STUB_FAIL='pr view sync/upstream --json state*'
  old_tip=$(git -C "$fixture_work" ls-remote origin refs/heads/sync/upstream | awk '{print $1}')

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "state read failure stops the sync"
  assert_equals "$old_tip" \
    "$(git -C "$fixture_work" ls-remote origin refs/heads/sync/upstream | awk '{print $1}')" \
    "state read failure leaves the branch unchanged"
}

test_duplicate_open_pr_lookup_fails() {
  new_fixture "duplicate-open-pr"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN
  export GH_STUB_OPEN_PR_NUMBERS='5,6'

  run_sync
  unset GH_STUB_OPEN_PR_NUMBERS
  assert_status_failed "duplicate open PR lookup fails"
  assert_contains "more than one open pull request" "$(sync_err)" \
    "duplicate open PR lookup is reported"
  assert_not_contains "pr create" "$(gh_log)" \
    "duplicate open PR lookup does not create a PR"
}

test_conflict_notice_updates_only_owned_exact_marker() {
  new_fixture "owned-conflict-notice"
  commit_on_main_branch "a.txt" "fork line" "fix: fork-local edit"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first conflicted sync exits 0"

  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  export GH_STUB_COMMENTS_JSON="$MIXED_NOTICE_COMMENT_JSON"

  run_sync
  unset GH_STUB_COMMENTS_JSON
  assert_equals "0" "$status" "owned notice sync exits 0"
  gh_actions=$(gh_log)
  assert_contains "issues/comments/43" "$gh_actions" \
    "automation notice is updated"
  assert_not_contains "issues/comments/41" "$gh_actions" \
    "maintainer notice is not updated"
  assert_not_contains "issues/comments/42" "$gh_actions" \
    "misplaced marker is not updated"
  gh_state=$(cat "$TEST_ROOT/gh-state.json")
  assert_contains "public comment" "$gh_state" \
    "maintainer comment remains unchanged"
  assert_contains "misplaced marker" "$gh_state" \
    "misplaced marker comment remains unchanged"
  assert_contains "a.txt" "$gh_state" \
    "automation notice contains the conflict update"
}

test_missing_conflict_label_fails() {
  new_fixture "missing-label"
  export GH_STUB_REPO_LABELS=''

  run_sync
  unset GH_STUB_REPO_LABELS
  assert_status_failed "missing label fails the sync"
  assert_contains "does not exist" "$(sync_err)" "missing label reported"
  assert_not_contains "could not read label" "$(sync_err)" "404 not reported as an API failure"
  assert_no_branch "no branch created"
}

test_special_conflict_label_is_matched_as_data() {
  new_fixture "special-label"
  export GH_STUB_REPO_LABELS_JSON='["label with spaces","label/with%percent","label – unicode"]'

  run_sync_with_env SYNC_CONFLICT_LABEL='label/with%percent'
  unset GH_STUB_REPO_LABELS_JSON
  assert_equals "0" "$status" "special conflict label sync exits 0"
}

test_invalid_conflict_label_fails_before_api_call() {
  new_fixture "invalid-label"

  run_sync_with_env SYNC_CONFLICT_LABEL='invalid,label'
  assert_status_failed "comma in conflict label fails"
  assert_contains "must not contain commas" "$(sync_err)" \
    "invalid conflict label is reported"
  assert_not_contains "api" "$(gh_log)" \
    "invalid conflict label does not call GitHub"

  new_fixture "control-character-label"

  run_sync_with_env SYNC_CONFLICT_LABEL=$'invalid\nlabel'
  assert_status_failed "control character in conflict label fails"
  assert_contains "must not contain commas or control characters" "$(sync_err)" \
    "control character in conflict label is reported"
  assert_not_contains "api" "$(gh_log)" \
    "control character in conflict label does not call GitHub"
}

test_conflict_label_api_failure_fails() {
  new_fixture "label-api-failure"
  export GH_STUB_HTTP_STATUS=500

  run_sync
  unset GH_STUB_HTTP_STATUS
  assert_status_failed "label API failure fails the sync"
  assert_contains "could not read label" "$(sync_err)" "API failure reported distinctly"
  assert_not_contains "does not exist" "$(sync_err)" "API failure not reported as missing label"
  assert_no_branch "no branch created"

  new_fixture "label-api-call-failure"
  export GH_STUB_FAIL='api *repos/LMLiam/freebuffed/labels*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "label API call failure fails the sync"
  assert_contains "could not read label" "$(sync_err)" "failed API call reported as an API failure"
  assert_not_contains "does not exist" "$(sync_err)" "call failure not reported as missing label"
}

test_conflict_label_failure_aborts() {
  new_fixture "conflict-label-fail"
  commit_on_main_branch "a.txt" "fork line" "fix: fork-local edit"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  export GH_STUB_FAIL='pr edit*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "label add failure aborts the sync"
  assert_contains "pr create --draft" "$(gh_log)" "conflicted PR created before label failure"
}

test_missing_version_file_fails() {
  new_fixture "missing-version"
  git -C "$fixture_upstream" rm -q freebuff/cli/release/package.json
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"

  run_sync
  assert_status_failed "missing version file fails"
  assert_not_contains "could not be applied" "$(sync_err)" "apply succeeded before version read"
  assert_no_branch "no branch pushed"
}

test_invalid_version_json_fails() {
  new_fixture "invalid-version"
  printf 'not-json' > "$fixture_upstream/freebuff/cli/release/package.json"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"

  run_sync
  assert_status_failed "invalid version JSON fails"
  assert_not_contains "could not be applied" "$(sync_err)" "apply succeeded before version read"
  assert_no_branch "no branch pushed"
}

test_stub_models_gh_state() {
  new_fixture "stub-state"
  export GH_STUB_REPO_LABELS=''
  labels=$(gh api --paginate "repos/LMLiam/freebuffed/labels" --jq '.[].name')
  assert_equals "" "$labels" "missing repo label returns an empty list"
  rm -f "$TEST_ROOT/gh-state.json"
  GH_STUB_REPO_LABELS='upstream-conflict'
  labels=$(gh api --paginate "repos/LMLiam/freebuffed/labels" --jq '.[].name')
  assert_equals "upstream-conflict" "$labels" "existing repo label is listed"
  rm -f "$TEST_ROOT/gh-state.json"
  gh pr create --draft --base main --head sync/upstream --title "test title" >/dev/null 2>&1
  is_draft=$(gh pr view sync/upstream --json isDraft --jq '.isDraft')
  assert_equals "true" "$is_draft" "create --draft persists the draft flag"
  gh pr edit sync/upstream --add-label upstream-conflict
  pr_labels=$(gh pr view sync/upstream --json labels --jq '.labels[].name')
  assert_contains "upstream-conflict" "$pr_labels" "added label persists"
  gh pr ready sync/upstream
  is_draft=$(gh pr view sync/upstream --json isDraft --jq '.isDraft')
  assert_equals "false" "$is_draft" "pr ready flips the draft flag"
  gh pr ready --undo sync/upstream
  is_draft=$(gh pr view sync/upstream --json isDraft --jq '.isDraft')
  assert_equals "true" "$is_draft" "ready --undo restores the draft flag"
  gh pr comment sync/upstream --body "<!-- sync-conflict-notice -->
notice"
  notice_ids=$(gh pr view sync/upstream --json comments \
    --jq '.comments[] | select(.body | contains("sync-conflict-notice")) | .id')
  assert_equals "IC_kwDOT2TnS86Y100" "$notice_ids" \
    "GraphQL view returns the node id"
  rest_notice_ids=$(gh api --paginate "repos/LMLiam/freebuffed/issues/5/comments" \
    --jq '.[] | select(.body | contains("sync-conflict-notice")) | .id')
  assert_equals "100" "$rest_notice_ids" "REST comment list returns the numeric id"
  gh api -X PATCH "repos/LMLiam/freebuffed/issues/comments/100" -f body="resolved body"
  assert_contains "PATCH" "$(gh_log)" "notice PATCH issued"
  assert_contains "resolved body" \
    "$(cat "$TEST_ROOT/gh-state.json")" "PATCH updates the stored comment body"
}

run_all_tests() {
  local tests=(
    test_already_up_to_date
    test_pr_module_sourcing_has_no_side_effects
    test_clean_upstream_update
    test_body_file_path_with_spaces
    test_conflict_then_resolution
    test_excluded_only_change_advances_marker
    test_existing_branch_appends
    test_manual_edits_preserved
    test_missing_and_invalid_marker
    test_upstream_branch_lookup_failure
    test_check_script_missing_branch
    test_check_script_tag_collision
    test_check_script_github_outputs
    test_version_from_synced_tree
    test_filenames_with_spaces
    test_missing_token_in_ci_mode
    test_ci_push_does_not_expose_token_in_argv
    test_open_pr_title_advances
    test_open_pr_title_unchanged_is_not_edited
    test_manual_draft_left_alone
    test_new_conflicted_pr_created_draft
    test_remaining_separator_marker_keeps_pr_in_conflict_state
    test_apply_failure_not_misclassified
    test_marker_example_outside_change_set
    test_conflict_notice_non_ascii_path
    test_conflict_notice_lists_files_as_bullets
    test_conflict_notice_formats_special_paths
    test_missing_and_invalid_branch_marker
    test_remote_advance_rejects_push
    test_closed_pr_branch_not_reused
    test_merged_pr_not_recreated
    test_merged_pr_uses_current_main_after_merge_commit
    test_merged_pr_uses_current_main_after_squash_merge
    test_merged_pr_uses_current_main_after_rebase_merge
    test_reconcile_pr_state_read_failure_does_not_create_duplicate
    test_duplicate_open_pr_lookup_fails
    test_gh_create_failure_aborts
    test_gh_edit_failure_aborts
    test_title_reconciled_after_failure
    test_title_fallback_to_unknown
    test_label_failure_reconciled
    test_ready_failure_reconciled
    test_labels_read_failure_aborts
    test_state_read_failure_leaves_branch_unchanged
    test_comment_failure_reconciled
    test_conflict_notice_updated_for_later_conflict
    test_conflict_notice_updates_only_owned_exact_marker
    test_missing_conflict_label_fails
    test_special_conflict_label_is_matched_as_data
    test_invalid_conflict_label_fails_before_api_call
    test_conflict_label_api_failure_fails
    test_conflict_label_failure_aborts
    test_missing_version_file_fails
    test_invalid_version_json_fails
    test_stub_models_gh_state
  )
  local -a selected=()
  local test_fn
  local name
  if [[ -n "${TESTS:-}" ]]; then
    for name in ${TESTS//,/ }; do
      selected+=("$name")
    done
  else
    selected=("${tests[@]}")
  fi
  for test_fn in "${selected[@]}"; do
    if ! printf '%s\n' "${tests[@]}" | grep -qx "$test_fn"; then
      echo "error: unknown test '$test_fn'" >&2
      echo "available:" >&2
      printf '  %s\n' "${tests[@]}" >&2
      exit 1
    fi
  done
  for test_fn in "${selected[@]}"; do
    echo "== $test_fn"
    "$test_fn"
  done
}

run_all_tests

echo
echo "PASS: $pass_count  FAIL: $fail_count"
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
echo "All upstream sync tests passed."
