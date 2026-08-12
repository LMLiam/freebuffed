#!/usr/bin/env bash
#
# Automated tests for the upstream sync scripts:
# .github/scripts/sync-upstream.sh and .github/scripts/upstream-sync-check.sh.
#
# Each test builds its own temporary local repositories (upstream mirror,
# origin, work checkout) under TEST_ROOT, stubs `gh` so the GitHub CLI
# operations are simulated and logged, and asserts on the results. The tests
# do not use the network.
#
# The harness runs under `set -e` so fixture and setup errors abort loudly.
# The sync script may fail on purpose, so run_sync captures its exit status in
# `$status` instead of letting errexit abort.
#
# Note on assertions: outputs are captured into variables before grepping.
# Piping git output straight into `grep -q` is racy under `set -o pipefail`
# (grep exits on first match, the writer dies on SIGPIPE, the pipeline is
# reported as failed).
#
# Usage:
#   bash .github/scripts/sync-upstream_test.sh
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

assert_equals() { # $1 = expected, $2 = actual, $3 = message
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 — expected '$1', got '$2'"
  fi
}

assert_contains() { # $1 = pattern, $2 = text, $3 = message
  if grep -qE -- "$1" <<< "$2"; then
    pass "$3"
  else
    fail "$3 — pattern '$1' not found"
  fi
}

assert_not_contains() { # $1 = pattern, $2 = text, $3 = message
  if grep -qE -- "$1" <<< "$2"; then
    fail "$3 — unexpected pattern '$1'"
  else
    pass "$3"
  fi
}

assert_status_ok() { # $1 = message
  assert_equals "0" "$status" "$1"
}

assert_status_failed() { # $1 = message
  if [[ "$status" != "0" ]]; then
    pass "$1"
  else
    fail "$1 — sync unexpectedly exited 0"
  fi
}

assert_branch_exists() { # $1 = message
  if origin_has_branch; then
    pass "$1"
  else
    fail "$1 — sync/upstream missing"
  fi
}

assert_no_branch() { # $1 = message
  if origin_has_branch; then
    fail "$1 — sync/upstream exists"
  else
    pass "$1"
  fi
}

mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
LOG="${GH_STUB_LOG:?gh stub needs GH_STUB_LOG}"
printf 'gh %s\n' "$*" >> "$LOG"
# Simulate a gh failure. GH_STUB_FAIL is a comma-separated list of globs.
# When the full command line matches one, exit non-zero after logging and
# before printing any output, like a real failed gh call.
# Note: capture "$*" before changing IFS, which controls how "$*" joins args.
if [[ -n "${GH_STUB_FAIL:-}" ]]; then
  cmd_line="$*"
  saved_ifs=$IFS
  IFS=,
  for fail_pat in $GH_STUB_FAIL; do
    if [[ -n "$fail_pat" && "$cmd_line" == $fail_pat ]]; then
      exit 1
    fi
  done
  IFS=$saved_ifs
fi
case "${1:-}" in
  "pr")
    # Emulate gh pr view --json <fields> --jq <expr> for the queries the
    # sync script uses: state, isDraft, labels, comments. Other pr
    # subcommands print nothing, like real gh writing JSON only to the log.
    if [[ "${2:-}" == "view" ]]; then
      case "$*" in
        *"--json labels"*) printf '%s\n' "${GH_STUB_LABELS:-}" ;;
        *"--json isDraft"*) printf '%s\n' "${GH_STUB_DRAFT:-false}" ;;
        *"--json comments"*)
          # Apply the jq filter the sync script uses: emit the id of each
          # comment whose body carries the conflict-notice marker. Build the
          # JSON first: a brace-heavy ${VAR:-default} word would be split by
          # bash's brace counting and append a stray brace to the value.
          comments_json="${GH_STUB_COMMENTS_JSON:-}"
          if [[ -z "$comments_json" ]]; then
            comments_json='{"comments":[]}'
          fi
          python3 -c '
import json, sys
comments = json.loads(sys.argv[1]).get("comments", [])
for c in comments:
    if "sync-conflict-notice" in c.get("body", ""):
        print(c["id"])
' "$comments_json" || exit 1
          ;;
        *"--json state"*) printf '%s\n' "${GH_STUB_STATE:-CLOSED}" ;;
        *) printf '{"state":"%s"}\n' "${GH_STUB_STATE:-CLOSED}" ;;
      esac
    fi
    ;;
  "api")
    # Emulate the HTTP status line gh api --include prints on success.
    printf 'HTTP/2 %s\n' "${GH_STUB_HTTP_STATUS:-200}"
    ;;
esac
exit 0
EOF
chmod +x "$TEST_ROOT/bin/gh"
export PATH="$TEST_ROOT/bin:$PATH"
export GH_STUB_LOG="$TEST_ROOT/gh.log"
: > "$GH_STUB_LOG"
export GH_STUB_STATE=CLOSED
export GH_STUB_LABELS=''

fixture_dir=
fixture_upstream=
fixture_fork=
fixture_work=

new_fixture() { # $1 = scenario name
  reset_gh
  local dir="$TEST_ROOT/$1"
  mkdir -p "$dir"
  # Pin the default branch so the suite behaves identically on any runner
  # (GitHub runners default to `master`; many local installs default to `main`).
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

run_sync_with_env() { # $@ = environment arguments for the sync run
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

upstream_commit() { # $1 = message
  git -C "$fixture_upstream" add -A
  git -C "$fixture_upstream" commit -qm "$1"
  git -C "$fixture_upstream" push -q origin main
}

switch_to_sync_branch() {
  git -C "$fixture_fork" fetch -q origin
  git -C "$fixture_fork" switch -q -C sync/upstream origin/sync/upstream
}

commit_on_sync_branch() { # $1 = message
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "$1"
  git -C "$fixture_fork" push -q origin sync/upstream
}

commit_as_bot_on_sync_branch() { # $1 = message
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" -c user.name="freebuffed[bot]" \
    -c user.email="spoofed@example.com" commit -qm "$1"
  git -C "$fixture_fork" push -q origin sync/upstream
}

branch_file() { git -C "$fixture_work" show "origin/sync/upstream:$1" 2>/dev/null; }
branch_log() { git -C "$fixture_work" log --oneline --format='%h %an %s' origin/sync/upstream 2>/dev/null; }
branch_top() { git -C "$fixture_work" log -1 --format='%h %an %s' origin/sync/upstream 2>/dev/null; }
origin_has_branch() { [[ -n "$(git -C "$fixture_work" ls-remote origin refs/heads/sync/upstream 2>/dev/null)" ]]; }

gh_log() {
  if [[ ! -e "$GH_STUB_LOG" ]]; then
    echo "gh_log: $GH_STUB_LOG is missing — the gh stub never wrote a log for this fixture" >&2
    return 1
  fi
  cat "$GH_STUB_LOG"
}

reset_gh() {
  : > "$TEST_ROOT/gh.log"
  GH_STUB_STATE=CLOSED
  GH_STUB_LABELS=''
  export GH_STUB_DRAFT=false
  export GH_STUB_COMMENTS_JSON='{"comments":[]}'
  unset GH_STUB_FAIL
  unset GH_STUB_HTTP_STATUS
}

test_already_up_to_date() {
  new_fixture "already-up-to-date"
  run_sync
  assert_equals "0" "$status" "no-op exits 0"
  assert_contains "Up to date" "$(sync_out)" "reports up to date"
  assert_no_branch "creates no branch"
  assert_not_contains "pr create" "$(gh_log)" "creates no PR"
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
  assert_contains "pr edit sync/upstream --add-label upstream-conflict" "$(gh_log)" "conflict label added"
  assert_contains "pr comment" "$(gh_log)" "conflict comment posted"

  switch_to_sync_branch
  printf 'v3\nuser line\n' > "$fixture_fork/a.txt"
  commit_on_sync_branch "fix: resolve conflict"
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_LABELS='upstream-conflict'
  GH_STUB_DRAFT=true
  export GH_STUB_COMMENTS_JSON='{"comments":[{"id":42,"body":"<!-- sync-conflict-notice -->\n⚠️ Sync has conflicts in: a.txt. The pull request is a draft and stays a draft until the conflicts are resolved."}]}'

  run_sync
  unset GH_STUB_COMMENTS_JSON
  assert_equals "0" "$status" "resolution run exits 0"
  assert_contains "Up to date" "$(sync_out)" "resolution run is a no-op"
  gh_actions=$(gh_log)
  assert_contains "pr ready" "$gh_actions" "PR marked as ready for review"
  assert_not_contains "pr ready --undo" "$gh_actions" "PR not drafted again"
  assert_contains "pr edit sync/upstream --remove-label upstream-conflict" "$gh_actions" "conflict label removed"
  assert_contains "PATCH" "$gh_actions" "stale conflict notice updated to resolved"
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
  assert_equals "$upstream_head" "$(branch_file UPSTREAM_SHA)" "marker advanced despite excluded-only change"
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
  # A tag named exactly like the branch must not make the check read two
  # refs: the branch head only, on one line.
  git -C "$fixture_upstream" tag main
  git -C "$fixture_upstream" push -q origin refs/heads/main:refs/heads/main refs/tags/main:refs/tags/main
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
  assert_contains "^upstream_sha=${upstream_head}$" "$(cat "$fixture_dir/check.out")" "branch head only, single line"
  assert_equals "3" "$(wc -l < "$fixture_dir/check.out" | tr -d ' ')" "output has exactly three lines"
}

test_check_script_github_outputs() {
  new_fixture "check-outputs"
  marker=$(tr -d '[:space:]' < "$fixture_fork/UPSTREAM_SHA")
  upstream_head=$(git -C "$fixture_upstream" rev-parse HEAD)

  # Up to date: the marker matches upstream, so changed=false.
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
  assert_contains "^upstream_sha=${upstream_head}$" "$check_out" "up-to-date reports the upstream head"
  assert_contains "^marker=${marker}$" "$check_out" "up-to-date reports the marker"

  # New upstream commits: the check reports changed=true with the new head
  # and keeps the old marker.
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

test_conflict_notice_lists_files_as_bullets() {
  new_fixture "notice-bullets"
  # The fork and upstream both change a file whose name contains spaces, so
  # the sync conflicts on it. The notice must list the path as one bullet
  # with a code span, not a flattened ambiguous string.
  git -C "$fixture_fork" switch -q main
  echo "fork line" > "$fixture_fork/file with spaces.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "fix: fork-local edit"
  git -C "$fixture_fork" push -q origin main
  echo "upstream" > "$fixture_upstream/file with spaces.txt"
  upstream_commit "c2"

  run_sync
  assert_equals "0" "$status" "conflicted sync exits 0"
  assert_contains "Applied with conflicts in:" "$(sync_out)" "conflict apply logged"
  gh_actions=$(gh_log)
  assert_contains "pr comment" "$gh_actions" "conflict notice posted"
  # shellcheck disable=SC2016 # the backticks are literal pattern text
  assert_contains '- `file with spaces.txt`' "$gh_actions" "notice lists the spaced filename as one bullet"
  assert_contains "file with spaces.txt" "$(sync_out)" "spaced filename kept intact in the log"
}

test_missing_token_in_ci_mode() {
  new_fixture "missing-token"
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"

  run_sync_ci
  assert_status_failed "missing token fails"
  assert_contains "GH_TOKEN is empty" "$(sync_err)" "missing token reported"
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
  assert_contains 'pr edit sync/upstream --title chore\(upstream\): sync freebuff 0\.0\.147' "$gh_actions" "PR title advanced to 0.0.147"
  assert_not_contains "pr create" "$gh_actions" "PR reused, not recreated"
}

test_title_fallback_to_unknown() {
  new_fixture "unknown-version"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  # Remove the branch's version marker; the no-op run must fall back to
  # "unknown" in the title instead of writing a trailing-space title.
  switch_to_sync_branch
  git -C "$fixture_fork" rm -q UPSTREAM_VERSION
  commit_on_sync_branch "chore: drop version marker"
  reset_gh
  GH_STUB_STATE=OPEN

  run_sync
  assert_equals "0" "$status" "no-op run exits 0"
  assert_contains 'pr edit sync/upstream --title chore\(upstream\): sync freebuff unknown' "$(gh_log)" "title falls back to unknown"
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
  git -C "$fixture_fork" switch -q main
  echo "fork line" >> "$fixture_fork/a.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "fix: fork-local edit"
  git -C "$fixture_fork" push -q origin main
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  GH_STUB_DRAFT=true

  run_sync
  gh_actions=$(gh_log)
  assert_equals "0" "$status" "conflicted first sync exits 0"
  assert_contains "pr create --draft" "$gh_actions" "conflicted PR created as draft"
  assert_contains "pr edit sync/upstream --add-label upstream-conflict" "$gh_actions" "conflict label added at create"
  assert_not_contains "pr ready --undo" "$gh_actions" "fresh create never drafts via ready --undo"
  assert_contains "pr comment" "$gh_actions" "conflict comment posted"
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

  # Simulate a remote branch that advanced after the sync fetched it. A
  # pre-push hook pushes a competing commit to origin/sync/upstream just
  # before the sync pushes, so git rejects the sync's non-fast-forward push.
  git clone -q "$fixture_dir/origin.git" "$fixture_dir/competing"
  git -C "$fixture_dir/competing" config user.email o@o
  git -C "$fixture_dir/competing" config user.name o
  cat > "$fixture_work/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
git -C "$fixture_dir/competing" fetch -q origin
git -C "$fixture_dir/competing" switch -q -C sync/upstream origin/sync/upstream
echo "competing" > "$fixture_dir/competing/competing.txt"
git -C "$fixture_dir/competing" add -A
git -C "$fixture_dir/competing" -c user.name=other -c user.email=o@o commit -qm "chore: competing change"
git -C "$fixture_dir/competing" push -q origin sync/upstream
exit 0
EOF
  chmod +x "$fixture_work/.git/hooks/pre-push"

  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh

  run_sync
  assert_status_failed "push rejected when remote advanced"
  assert_contains "rejected" "$(sync_err)" "non-fast-forward rejection reported"
  assert_not_contains "pr create" "$(gh_log)" "no PR created after failed push"
}

test_closed_pr_with_live_branch() {
  new_fixture "closed-pr"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  # The PR is closed (stub reports CLOSED) but the branch is live. A new
  # upstream commit opens a fresh PR against the same branch.
  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh

  run_sync
  assert_equals "0" "$status" "second sync exits 0"
  gh_actions=$(gh_log)
  assert_contains "pr create" "$gh_actions" "new PR created for closed PR"
  assert_equals "2" "$(grep -c 'chore(upstream)' <<< "$(branch_log)")" "two sync commits appended"
}

test_merged_pr_not_recreated() {
  new_fixture "merged-pr"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  # Simulate a merged PR: main fast-forwards to the sync branch tip and the
  # PR state is MERGED. The branch has no commits ahead of main, so the sync
  # must not recreate the pull request.
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

  # The version bumps to 0.0.147; the title update fails after the push.
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

  # The next no-op run reconciles the stale title.
  reset_gh
  GH_STUB_STATE=OPEN
  run_sync
  assert_equals "0" "$status" "no-op run exits 0"
  assert_contains 'pr edit sync/upstream --title chore\(upstream\): sync freebuff 0\.0\.147' "$(gh_log)" "stale title reconciled"
}

test_label_failure_reconciled() {
  new_fixture "label-recovery"
  git -C "$fixture_fork" switch -q main
  echo "fork line" >> "$fixture_fork/a.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "fix: fork-local edit"
  git -C "$fixture_fork" push -q origin main
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  export GH_STUB_FAIL='pr edit sync/upstream --add-label*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "label add failure fails the sync"
  assert_contains "pr create --draft" "$(gh_log)" "conflicted PR created before label failure"

  # The next no-op run retries the label on the draft PR.
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  run_sync
  assert_equals "0" "$status" "recovery run exits 0"
  assert_contains "pr edit sync/upstream --add-label upstream-conflict" "$(gh_log)" "label added on retry"
}

test_ready_failure_reconciled() {
  new_fixture "ready-recovery"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  # A clean, labelled, auto-drafted PR: the ready toggle fails once. The
  # sync must fail loudly and keep the label so the next run can retry.
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

  # The next no-op run marks it ready and removes the label.
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_LABELS='upstream-conflict'
  GH_STUB_DRAFT=true
  run_sync
  assert_equals "0" "$status" "recovery run exits 0"
  gh_actions=$(gh_log)
  assert_contains "pr ready sync/upstream" "$gh_actions" "PR marked ready on retry"
  assert_contains "pr edit sync/upstream --remove-label upstream-conflict" "$gh_actions" "label removed after ready"
}

test_labels_read_failure_aborts() {
  new_fixture "labels-read-fail"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  # A failed labels read must not be treated as "no label": that would
  # drop the label from a still-drafted pull request. The run fails loudly.
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_LABELS='upstream-conflict'
  GH_STUB_DRAFT=true
  export GH_STUB_FAIL='pr view sync/upstream --json labels*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "labels read failure fails the sync"
  assert_contains "could not read labels" "$(sync_err)" "labels read failure reported"
  assert_not_contains "pr edit sync/upstream --remove-label" "$(gh_log)" "label not removed on failed read"
}

test_comment_failure_reconciled() {
  new_fixture "comment-recovery"
  git -C "$fixture_fork" switch -q main
  echo "fork line" >> "$fixture_fork/a.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "fix: fork-local edit"
  git -C "$fixture_fork" push -q origin main
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  export GH_STUB_FAIL='pr comment*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "comment failure fails the sync"
  assert_contains "pr create --draft" "$(gh_log)" "conflicted PR created before comment failure"

  # The next no-op run posts the missing conflict notice.
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  run_sync
  assert_equals "0" "$status" "recovery run exits 0"
  assert_contains "pr comment" "$(gh_log)" "conflict notice posted on retry"

  # An existing notice must be updated in place, not posted twice: the sync
  # finds the marker comment by id and patches it.
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  export GH_STUB_COMMENTS_JSON='{"comments":[{"id":42,"body":"<!-- sync-conflict-notice -->\n⚠️ Sync has conflicts in: a.txt. The pull request is a draft and stays a draft until the conflicts are resolved."}]}'
  run_sync
  unset GH_STUB_COMMENTS_JSON
  assert_equals "0" "$status" "duplicate-notice run exits 0"
  assert_not_contains "pr comment" "$(gh_log)" "existing conflict notice not duplicated"
  assert_contains "PATCH" "$(gh_log)" "existing conflict notice updated in place"
}

test_conflict_notice_updated_for_later_conflict() {
  new_fixture "notice-update"
  git -C "$fixture_fork" switch -q main
  echo "fork line" >> "$fixture_fork/a.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "fix: fork-local edit"
  git -C "$fixture_fork" push -q origin main
  echo "v2" > "$fixture_upstream/a.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first conflicted sync exits 0"
  assert_contains "pr comment" "$(gh_log)" "first conflict notice posted"

  # Resolve the first conflict and add a fork-local change to b.txt on the
  # sync branch; upstream then changes b.txt, so the next sync conflicts in
  # a different file. The existing notice must be updated, not suppressed
  # and not duplicated.
  switch_to_sync_branch
  printf 'v2\nfork line\n' > "$fixture_fork/a.txt"
  echo "fork edit" > "$fixture_fork/b.txt"
  commit_on_sync_branch "fix: resolve first conflict"
  echo "upstream b" > "$fixture_upstream/b.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN
  GH_STUB_DRAFT=true
  export GH_STUB_COMMENTS_JSON='{"comments":[{"id":42,"body":"<!-- sync-conflict-notice -->\n⚠️ Sync has conflicts in: a.txt. The pull request is a draft and stays a draft until the conflicts are resolved."}]}'

  run_sync
  unset GH_STUB_COMMENTS_JSON
  assert_equals "0" "$status" "later-conflict sync exits 0"
  gh_actions=$(gh_log)
  assert_contains "b.txt" "$gh_actions" "notice updated with the later conflicted file"
  assert_not_contains "sync/upstream:" "$gh_actions" "notice lists plain paths, not rev-prefixed"
  assert_not_contains "pr comment" "$gh_actions" "existing notice not recreated"
  assert_contains "PATCH" "$gh_actions" "existing notice updated in place"
}

test_state_read_failure_reconciled() {
  new_fixture "state-read-recovery"
  echo "upstream file" > "$fixture_upstream/b.txt"
  upstream_commit "c2"
  run_sync
  assert_equals "0" "$status" "first sync exits 0"

  # A failed state read on a live branch must not be read as "not OPEN":
  # the reconcile still runs and the create path fails loudly if a pull
  # request exists.
  echo "more" > "$fixture_upstream/c.txt"
  upstream_commit "c3"
  reset_gh
  GH_STUB_STATE=OPEN
  export GH_STUB_FAIL='pr view sync/upstream --json state*'

  run_sync
  unset GH_STUB_FAIL
  assert_equals "0" "$status" "state read failure does not skip reconciliation"
  assert_contains "pr create" "$(gh_log)" "reconcile runs after state read failure"
}

test_missing_conflict_label_fails() {
  new_fixture "missing-label"
  export GH_STUB_HTTP_STATUS=404

  run_sync
  unset GH_STUB_HTTP_STATUS
  assert_status_failed "missing label fails the sync"
  assert_contains "does not exist" "$(sync_err)" "missing label reported"
  assert_not_contains "could not read label" "$(sync_err)" "404 not reported as an API failure"
  assert_no_branch "no branch created"
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

  # A failed call (network error, rate limit) with no status line reports the
  # call failure, not a missing label.
  new_fixture "label-api-call-failure"
  export GH_STUB_FAIL='api repos/LMLiam/freebuffed/labels/*'

  run_sync
  unset GH_STUB_FAIL
  assert_status_failed "label API call failure fails the sync"
  assert_contains "API call failed" "$(sync_err)" "failed API call reported"
  assert_not_contains "does not exist" "$(sync_err)" "call failure not reported as missing label"
}

test_conflict_label_failure_aborts() {
  new_fixture "conflict-label-fail"
  git -C "$fixture_fork" switch -q main
  echo "fork line" >> "$fixture_fork/a.txt"
  git -C "$fixture_fork" add -A
  git -C "$fixture_fork" commit -qm "fix: fork-local edit"
  git -C "$fixture_fork" push -q origin main
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

run_all_tests() {
  local tests=(
    test_already_up_to_date
    test_clean_upstream_update
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
    test_open_pr_title_advances
    test_manual_draft_left_alone
    test_new_conflicted_pr_created_draft
    test_apply_failure_not_misclassified
    test_marker_example_outside_change_set
    test_conflict_notice_lists_files_as_bullets
    test_missing_and_invalid_branch_marker
    test_remote_advance_rejects_push
    test_closed_pr_with_live_branch
    test_merged_pr_not_recreated
    test_gh_create_failure_aborts
    test_gh_edit_failure_aborts
    test_title_reconciled_after_failure
    test_title_fallback_to_unknown
    test_label_failure_reconciled
    test_ready_failure_reconciled
    test_labels_read_failure_aborts
    test_state_read_failure_reconciled
    test_comment_failure_reconciled
    test_conflict_notice_updated_for_later_conflict
    test_missing_conflict_label_fails
    test_conflict_label_api_failure_fails
    test_conflict_label_failure_aborts
    test_missing_version_file_fails
    test_invalid_version_json_fails
  )
  local test_fn
  for test_fn in "${tests[@]}"; do
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
