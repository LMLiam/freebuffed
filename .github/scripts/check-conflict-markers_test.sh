#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-conflict-markers.sh"
TEST_ROOT=$(mktemp -d)
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
  if grep -qF -- "$1" <<< "$2"; then
    pass "$3"
  else
    fail "$3 — text '$1' not found"
  fi
}

assert_not_contains() {
  if grep -qF -- "$1" <<< "$2"; then
    fail "$3 — unexpected text '$1'"
  else
    pass "$3"
  fi
}

new_fixture() {
  fixture_dir="$TEST_ROOT/$1"
  mkdir -p "$fixture_dir"
  git init -q --initial-branch=main "$fixture_dir/repo"
  git -C "$fixture_dir/repo" config user.email test@example.com
  git -C "$fixture_dir/repo" config user.name test
  printf 'base\n' > "$fixture_dir/repo/base.txt"
  git -C "$fixture_dir/repo" add base.txt
  git -C "$fixture_dir/repo" commit -qm "base"
  base_sha=$(git -C "$fixture_dir/repo" rev-parse HEAD)
  git -C "$fixture_dir/repo" switch -q -c feature
}

commit_head() {
  git -C "$fixture_dir/repo" add -A
  git -C "$fixture_dir/repo" commit -qm "$1"
}

run_check() {
  run_check_refs "$base_sha" HEAD
}

run_check_refs() {
  if output=$(cd "$fixture_dir/repo" && "$CHECK_SCRIPT" "$1" "$2" 2>&1); then
    status=0
  else
    status=$?
  fi
}

run_check_with_git_failure() {
  local failure_mode="$1"
  local wrapper_dir="$fixture_dir/git-wrapper"
  local real_git

  mkdir -p "$wrapper_dir"
  real_git=$(command -v git)
  cat > "$wrapper_dir/git" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${GIT_FAILURE_MODE:-}" == "diff" && "${1:-}" == "diff" ]]; then
  exit 2
fi
if [[ "${GIT_FAILURE_MODE:-}" == "grep" && "${1:-}" == "grep" ]]; then
  exit 2
fi
exec "$REAL_GIT" "$@"
BASH
  chmod +x "$wrapper_dir/git"
  if output=$(cd "$fixture_dir/repo" && env \
    PATH="$wrapper_dir:$PATH" REAL_GIT="$real_git" GIT_FAILURE_MODE="$failure_mode" \
    "$CHECK_SCRIPT" "$base_sha" HEAD 2>&1); then
    status=0
  else
    status=$?
  fi
}

test_clean_files_pass() {
  new_fixture clean
  printf 'clean\n' > "$fixture_dir/repo/clean.txt"
  commit_head "clean file"

  run_check
  assert_equals "0" "$status" "clean files pass"
  assert_contains "No conflict markers in changed files." "$output" \
    "clean files report no markers"
}

test_all_three_markers_fail() {
  new_fixture all-markers
  printf '<<<<<<< ours\nleft\n=======\nright\n>>>>>>> theirs\n' \
    > "$fixture_dir/repo/conflict.txt"
  commit_head "all conflict markers"

  run_check
  assert_equals "1" "$status" "all three markers fail"
  assert_contains "conflict.txt" "$output" "all marker file is reported"
  assert_contains "<<<<<<< ours" "$output" "start marker is reported"
  assert_contains "=======" "$output" "separator marker is reported"
  assert_contains ">>>>>>> theirs" "$output" "end marker is reported"
}

test_binary_files_are_ignored() {
  new_fixture binary
  printf 'binary\0<<<<<<< ours\0=======\0>>>>>>> theirs\0' \
    > "$fixture_dir/repo/image.bin"
  commit_head "binary file"

  run_check
  assert_equals "0" "$status" "binary files pass"
  assert_contains "No conflict markers in changed files." "$output" \
    "binary files report no markers"
}

test_empty_diff_passes() {
  new_fixture empty-diff

  run_check
  assert_equals "0" "$status" "empty diff passes"
  assert_contains "No changed files." "$output" "empty diff is reported"
}

test_unusual_filename_is_handled() {
  new_fixture unusual-filename
  unusual_file='file with spaces [and brackets].txt'
  printf '<<<<<<< ours\n=======\n>>>>>>> theirs\n' \
    > "$fixture_dir/repo/$unusual_file"
  commit_head "unusual filename"

  run_check
  assert_equals "1" "$status" "unusual filename with markers fails"
  assert_contains "$unusual_file" "$output" \
    "unusual filename is reported"
}

test_filename_starting_with_dash_is_handled() {
  new_fixture dash-filename
  dash_file='--help'
  printf '<<<<<<< ours\n=======\n>>>>>>> theirs\n' \
    > "$fixture_dir/repo/$dash_file"
  commit_head "dash filename"

  run_check
  assert_equals "1" "$status" "dash filename with markers fails"
  assert_contains "$dash_file" "$output" \
    "dash filename is reported"
}

test_merge_base_range_ignores_inherited_marker() {
  new_fixture merge-base-range
  git -C "$fixture_dir/repo" switch -q main
  printf '<<<<<<< inherited\n=======\n>>>>>>> inherited\n' \
    > "$fixture_dir/repo/inherited-conflict.txt"
  git -C "$fixture_dir/repo" add inherited-conflict.txt
  git -C "$fixture_dir/repo" commit -qm "add inherited marker"
  branch_point=$(git -C "$fixture_dir/repo" rev-parse HEAD)

  git -C "$fixture_dir/repo" switch -q -C feature "$branch_point"
  git -C "$fixture_dir/repo" switch -q main
  git -C "$fixture_dir/repo" rm -q inherited-conflict.txt
  git -C "$fixture_dir/repo" commit -qm "remove inherited marker"
  main_head=$(git -C "$fixture_dir/repo" rev-parse HEAD)

  git -C "$fixture_dir/repo" switch -q feature
  printf 'clean feature change\n' > "$fixture_dir/repo/feature.txt"
  commit_head "clean feature change"

  run_check_refs "$main_head" HEAD
  assert_equals "0" "$status" "inherited markers outside the PR delta pass"
  assert_contains "No conflict markers in changed files." "$output" \
    "merge-base range scans only feature changes"
}

test_git_diff_failure_fails_closed() {
  new_fixture diff-failure
  printf 'clean\n' > "$fixture_dir/repo/clean.txt"
  commit_head "clean file"

  run_check_with_git_failure diff
  assert_equals "1" "$status" "git diff failure fails the check"
  assert_contains "could not read changed files" "$output" \
    "git diff failure is reported"
  assert_not_contains "No conflict markers" "$output" \
    "git diff failure is not reported as clean"
}

test_git_grep_error_fails_closed() {
  new_fixture grep-failure
  printf 'clean\n' > "$fixture_dir/repo/clean.txt"
  commit_head "clean file"

  run_check_with_git_failure grep
  assert_equals "1" "$status" "git grep status 2 fails the check"
  assert_contains "could not scan changed file" "$output" \
    "git grep error is reported"
  assert_not_contains "No conflict markers" "$output" \
    "git grep error is not reported as clean"
}

run_all_tests() {
  local tests=(
    test_clean_files_pass
    test_all_three_markers_fail
    test_binary_files_are_ignored
    test_empty_diff_passes
    test_unusual_filename_is_handled
    test_filename_starting_with_dash_is_handled
    test_merge_base_range_ignores_inherited_marker
    test_git_diff_failure_fails_closed
    test_git_grep_error_fails_closed
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
echo "All conflict-marker tests passed."
