#!/usr/bin/env bash
#
# Automated tests for .github/scripts/sync-upstream.sh.
#
# The sync script force-updates a persistent branch, so it gets a real test
# suite. Each scenario builds its own throwaway git repositories (upstream
# mirror, origin, work checkout) under a temp dir, stubs `gh` so the
# pull-request side is simulated and logged, then asserts on the results.
# No network access is used.
#
# Note on assertions: outputs are captured into variables before grepping.
# Piping git output straight into `grep -q` is racy under `set -o pipefail`
# (grep exits on first match, the writer dies on SIGPIPE, the pipeline is
# reported as failed).
#
# Usage:
#   bash .github/scripts/test-sync-upstream.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-upstream.sh"

H="$(mktemp -d)"
trap 'rm -rf "$H"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
contains() { grep -qE -- "$1" <<< "$2"; } # $1 = pattern, $2 = text

# --- stub gh: logs every call, reports a controllable PR state -------------
mkdir -p "$H/bin"
cat > "$H/bin/gh" <<'EOF'
#!/usr/bin/env bash
LOG="${GH_STUB_LOG:?gh stub needs GH_STUB_LOG}"
echo "gh $*" >> "$LOG"
case "${1:-} ${2:-}" in
  "pr view") echo "{\"state\":\"${GH_STUB_STATE:-CLOSED}\"}" ;;
esac
exit 0
EOF
chmod +x "$H/bin/gh"
export PATH="$H/bin:$PATH"
export GH_STUB_LOG="$H/gh.log"
export GH_STUB_STATE=CLOSED

FIXTURE_DIR=
FIXTURE_UPSTREAM=
FIXTURE_FORK=
FIXTURE_WORK=

# --- build an isolated upstream + origin + work checkout -------------------
new_fixture() {
  local dir="$H/$1"
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

  FIXTURE_DIR="$dir"
  FIXTURE_UPSTREAM="$dir/upstream"
  FIXTURE_FORK="$dir/fork"
  FIXTURE_WORK="$dir/work"
}

# --- run the sync script from the work checkout (never in CI mode) ---------
run_sync() {
  (
    cd "$FIXTURE_WORK"
    git switch -q main 2>/dev/null || true
    git pull -q origin main 2>/dev/null || true
    env -u GITHUB_ACTIONS -u GH_TOKEN \
      UPSTREAM_URL="$FIXTURE_DIR/upstream.git" \
      bash "$SYNC_SCRIPT" >"$FIXTURE_DIR/sync.out" 2>"$FIXTURE_DIR/sync.err"
    echo $? > "$FIXTURE_DIR/sync.exit"
    git fetch -q origin 2>/dev/null || true
  )
}
sync_exit() { tr -d '[:space:]' < "$FIXTURE_DIR/sync.exit"; }
sync_out() { cat "$FIXTURE_DIR/sync.out"; }
sync_err() { cat "$FIXTURE_DIR/sync.err"; }

# --- small helpers ----------------------------------------------------------
upstream_commit() { # $1 = message
  git -C "$FIXTURE_UPSTREAM" add -A
  git -C "$FIXTURE_UPSTREAM" commit -qm "$1"
  git -C "$FIXTURE_UPSTREAM" push -q origin main
}
user_commit_on_sync_branch() { # $1 = message; commits on the fork as the user
  git -C "$FIXTURE_FORK" fetch -q origin
  git -C "$FIXTURE_FORK" switch -q -C sync/upstream origin/sync/upstream
  git -C "$FIXTURE_FORK" add -A
  git -C "$FIXTURE_FORK" commit -qm "$1"
  git -C "$FIXTURE_FORK" push -q origin sync/upstream
}
branch_file() { git -C "$FIXTURE_WORK" show "origin/sync/upstream:$1" 2>/dev/null; }
branch_has_file() { git -C "$FIXTURE_WORK" cat-file -e "origin/sync/upstream:$1" 2>/dev/null; }
branch_log() { git -C "$FIXTURE_WORK" log --oneline --format='%h %an %s' origin/sync/upstream 2>/dev/null; }
branch_top() { git -C "$FIXTURE_WORK" log -1 --format='%h %an %s' origin/sync/upstream 2>/dev/null; }
origin_has_branch() { [[ -n "$(git -C "$FIXTURE_WORK" ls-remote origin refs/heads/sync/upstream 2>/dev/null)" ]]; }
gh_log() { cat "$H/gh.log"; }
reset_gh() { : > "$H/gh.log"; GH_STUB_STATE=CLOSED; }

# ============================================================================
echo "T1: already up to date"
new_fixture t1
run_sync
out=$(sync_out)
if [[ "$(sync_exit)" == "0" ]] && contains "Up to date" "$out"; then pass "T1 no-op exits 0"; else fail "T1 (exit $(sync_exit)): $out"; fi
if ! origin_has_branch; then pass "T1 creates no branch"; else fail "T1 branch created unexpectedly"; fi
if ! contains "pr create" "$(gh_log)"; then pass "T1 creates no PR"; else fail "T1 PR created unexpectedly"; fi

echo "T2: clean upstream update"
new_fixture t2
echo "v2" > "$FIXTURE_UPSTREAM/a.txt"
echo "upstream file" > "$FIXTURE_UPSTREAM/b.txt"
upstream_commit "c2"
C2=$(git -C "$FIXTURE_UPSTREAM" rev-parse HEAD)
run_sync
out=$(sync_out)
err=$(sync_err)
if [[ "$(sync_exit)" == "0" ]]; then pass "T2 sync exits 0"; else fail "T2 (exit $(sync_exit)): $out $err"; fi
if origin_has_branch; then pass "T2 branch created"; else fail "T2 branch missing"; fi
if branch_has_file b.txt && [[ "$(branch_file a.txt)" == "v2" ]]; then pass "T2 upstream changes applied"; else fail "T2 changes not applied"; fi
if branch_has_file README.md && [[ "$(branch_file README.md)" == "fork readme" ]]; then pass "T2 fork-local README intact"; else fail "T2 README not the fork's own"; fi
if [[ "$(branch_file UPSTREAM_SHA)" == "$C2" ]]; then pass "T2 marker advanced"; else fail "T2 marker wrong: $(branch_file UPSTREAM_SHA)"; fi
if contains "pr create" "$(gh_log)"; then pass "T2 PR created"; else fail "T2 no PR created"; fi

echo "T3: genuine three-way conflict, then resolution flips ready"
new_fixture t3
echo "v2" > "$FIXTURE_UPSTREAM/a.txt"
upstream_commit "c2"
run_sync
# user edits the same region upstream later changes
git -C "$FIXTURE_FORK" fetch -q origin
git -C "$FIXTURE_FORK" switch -q -C sync/upstream origin/sync/upstream
echo "user line" >> "$FIXTURE_FORK/a.txt"
git -C "$FIXTURE_FORK" add -A
git -C "$FIXTURE_FORK" commit -qm "fix: manual edit"
git -C "$FIXTURE_FORK" push -q origin sync/upstream
echo "v3" > "$FIXTURE_UPSTREAM/a.txt"
upstream_commit "c3"
GH_STUB_STATE=OPEN
run_sync
a=$(branch_file a.txt)
if [[ "$(sync_exit)" == "0" ]]; then pass "T3 conflicted sync exits 0"; else fail "T3 (exit $(sync_exit)): $(sync_err)"; fi
if contains '^<<<<<<< ' "$a" && contains '^>>>>>>> ' "$a"; then pass "T3 conflict markers left in diff"; else fail "T3 no conflict markers"; fi
if contains "pr ready --undo" "$(gh_log)"; then pass "T3 PR set to draft"; else fail "T3 PR not drafted"; fi
if contains "pr comment" "$(gh_log)"; then pass "T3 conflict comment posted"; else fail "T3 no conflict comment"; fi
# user resolves the conflict; the next run flips the PR back to ready
git -C "$FIXTURE_FORK" fetch -q origin
git -C "$FIXTURE_FORK" switch -q -C sync/upstream origin/sync/upstream
printf 'v3\nuser line\n' > "$FIXTURE_FORK/a.txt"
git -C "$FIXTURE_FORK" add -A
git -C "$FIXTURE_FORK" commit -qm "fix: resolve conflict"
git -C "$FIXTURE_FORK" push -q origin sync/upstream
reset_gh
run_sync
out=$(sync_out)
if [[ "$(sync_exit)" == "0" ]] && contains "Up to date" "$out"; then pass "T3 resolution run is a no-op"; else fail "T3 resolution run (exit $(sync_exit))"; fi
g=$(gh_log)
if contains "pr ready" "$g" && ! contains "pr ready --undo" "$g"; then pass "T3 PR flipped back to ready"; else fail "T3 PR not flipped ready: $g"; fi

echo "T4: excluded-only upstream commit advances the marker"
new_fixture t4
echo "upstream docs" > "$FIXTURE_UPSTREAM/README.md"
upstream_commit "docs: readme"
C4=$(git -C "$FIXTURE_UPSTREAM" rev-parse HEAD)
run_sync
if [[ "$(sync_exit)" == "0" ]]; then pass "T4 sync exits 0"; else fail "T4 (exit $(sync_exit)): $(sync_err)"; fi
if origin_has_branch; then pass "T4 branch created"; else fail "T4 branch missing"; fi
if [[ "$(branch_file UPSTREAM_SHA)" == "$C4" ]]; then pass "T4 marker advanced despite excluded-only change"; else fail "T4 marker not advanced"; fi
if branch_has_file README.md && [[ "$(branch_file README.md)" == "fork readme" ]]; then pass "T4 upstream README change not applied"; else fail "T4 README overwritten by upstream"; fi
if contains "sync freebuff 0.0.146" "$(branch_top)"; then pass "T4 marker-only commit"; else fail "T4 commit wrong: $(branch_top)"; fi
if contains "pr create" "$(gh_log)"; then pass "T4 PR created"; else fail "T4 no PR created"; fi

echo "T5: existing bot-owned branch appends instead of recreating"
new_fixture t5
echo "upstream file" > "$FIXTURE_UPSTREAM/b.txt"
upstream_commit "c2"
run_sync
echo "more" > "$FIXTURE_UPSTREAM/c.txt"
upstream_commit "c3"
reset_gh
GH_STUB_STATE=OPEN
run_sync
if [[ "$(sync_exit)" == "0" ]]; then pass "T5 second sync exits 0"; else fail "T5 (exit $(sync_exit)): $(sync_err)"; fi
if branch_has_file b.txt && branch_has_file c.txt; then pass "T5 both updates applied"; else fail "T5 second update missing"; fi
if [[ "$(grep -c "chore(upstream)" <<< "$(branch_log)")" == "2" ]]; then pass "T5 two appended sync commits"; else fail "T5 commit count: $(branch_log)"; fi
if ! contains "pr create" "$(gh_log)"; then pass "T5 PR reused, not recreated"; else fail "T5 PR recreated: $(gh_log)"; fi

echo "T6: manually edited branch (even with spoofed bot name) is preserved"
new_fixture t6
echo "upstream file" > "$FIXTURE_UPSTREAM/b.txt"
upstream_commit "c2"
run_sync
git -C "$FIXTURE_FORK" fetch -q origin
git -C "$FIXTURE_FORK" switch -q -C sync/upstream origin/sync/upstream
echo "manual user fix" > "$FIXTURE_FORK/manual.txt"
git -C "$FIXTURE_FORK" -c user.name="freebuffed[bot]" -c user.email="spoofed@example.com" add -A
git -C "$FIXTURE_FORK" -c user.name="freebuffed[bot]" -c user.email="spoofed@example.com" commit -qm "fix: manual resolution"
git -C "$FIXTURE_FORK" push -q origin sync/upstream
echo "v3" > "$FIXTURE_UPSTREAM/a.txt"
upstream_commit "c3"
GH_STUB_STATE=OPEN
run_sync
if [[ "$(sync_exit)" == "0" ]]; then pass "T6 append exits 0"; else fail "T6 (exit $(sync_exit)): $(sync_err)"; fi
if [[ "$(branch_file manual.txt)" == "manual user fix" ]]; then pass "T6 manual commit preserved"; else fail "T6 manual.txt lost"; fi
if contains "fix: manual resolution" "$(branch_log)"; then pass "T6 manual commit still in history"; else fail "T6 manual commit gone: $(branch_log)"; fi
if contains 'chore\(upstream\)' "$(branch_top)"; then pass "T6 bot appended on top"; else fail "T6 no append commit"; fi

echo "T7: missing and invalid marker"
new_fixture t7
git -C "$FIXTURE_FORK" rm -q UPSTREAM_SHA
git -C "$FIXTURE_FORK" commit -qm "drop marker"
git -C "$FIXTURE_FORK" push -q origin main
run_sync
err=$(sync_err)
if [[ "$(sync_exit)" != "0" ]] && contains "UPSTREAM_SHA is empty" "$err"; then pass "T7a missing marker errors cleanly"; else fail "T7a (exit $(sync_exit)): $err"; fi
echo "0123456789abcdef0123456789abcdef01234567" > "$FIXTURE_FORK/UPSTREAM_SHA"
git -C "$FIXTURE_FORK" add -A
git -C "$FIXTURE_FORK" commit -qm "bad marker"
git -C "$FIXTURE_FORK" push -q origin main
run_sync
err=$(sync_err)
if [[ "$(sync_exit)" != "0" ]] && contains "is not a commit" "$err"; then pass "T7b invalid marker errors cleanly"; else fail "T7b (exit $(sync_exit)): $err"; fi
if ! origin_has_branch; then pass "T7 no branch created on error"; else fail "T7 branch created on error"; fi

echo "T8: upstream branch lookup failure"
new_fixture t8
echo "v2" > "$FIXTURE_UPSTREAM/a.txt"
upstream_commit "c2"
export UPSTREAM_BRANCH=does-not-exist
run_sync
unset UPSTREAM_BRANCH
if [[ "$(sync_exit)" != "0" ]]; then pass "T8 fetch failure exits non-zero"; else fail "T8 unexpectedly succeeded"; fi
if ! origin_has_branch; then pass "T8 no branch created"; else fail "T8 branch created"; fi
if ! contains "pr create" "$(gh_log)"; then pass "T8 no PR created"; else fail "T8 PR created"; fi

echo "T9: version extracted from the synced tree"
new_fixture t9
printf '{"version":"0.0.147"}' > "$FIXTURE_UPSTREAM/freebuff/cli/release/package.json"
echo "more" > "$FIXTURE_UPSTREAM/b.txt"
upstream_commit "c2"
run_sync
if [[ "$(branch_file UPSTREAM_VERSION)" == "0.0.147" ]]; then pass "T9 UPSTREAM_VERSION from tree"; else fail "T9 version wrong: $(branch_file UPSTREAM_VERSION)"; fi
if contains "sync freebuff 0.0.147" "$(branch_top)"; then pass "T9 commit message carries tree version"; else fail "T9 commit message: $(branch_top)"; fi

echo "T10: filenames containing spaces"
new_fixture t10
echo "spaced content" > "$FIXTURE_UPSTREAM/file with spaces.txt"
upstream_commit "c2"
run_sync
if [[ "$(sync_exit)" == "0" ]]; then pass "T10 sync exits 0"; else fail "T10 (exit $(sync_exit)): $(sync_err)"; fi
if branch_has_file "file with spaces.txt" && [[ "$(branch_file "file with spaces.txt")" == "spaced content" ]]; then pass "T10 spaced filename applied"; else fail "T10 spaced file missing"; fi

echo "T11: missing SYNC_TOKEN in CI mode"
new_fixture t11
echo "v2" > "$FIXTURE_UPSTREAM/a.txt"
upstream_commit "c2"
(
  cd "$FIXTURE_WORK"
  git switch -q main 2>/dev/null || true
  git pull -q origin main 2>/dev/null || true
  env GITHUB_ACTIONS=true GH_TOKEN= \
    UPSTREAM_URL="$FIXTURE_DIR/upstream.git" \
    bash "$SYNC_SCRIPT" >"$FIXTURE_DIR/sync.out" 2>"$FIXTURE_DIR/sync.err"
  echo $? > "$FIXTURE_DIR/sync.exit"
)
err=$(sync_err)
if [[ "$(sync_exit)" != "0" ]] && contains "GH_TOKEN is empty" "$err"; then pass "T11 missing token errors cleanly"; else fail "T11 (exit $(sync_exit)): $err"; fi

# ============================================================================
echo
echo "PASS: $PASS  FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All sync machinery tests passed."
