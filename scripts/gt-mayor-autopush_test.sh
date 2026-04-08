#!/bin/bash
# Test suite for gt-mayor-autopush
#
# Tests push_if_needed logic: no-op when clean, push when ahead,
# rebase+push when diverged, skip when detached HEAD.
#
# Usage: bash scripts/gt-mayor-autopush_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOPUSH_SCRIPT="$SCRIPT_DIR/gt-mayor-autopush"
PASS=0
FAIL=0
TEST_TMPDIR=""

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

cleanup() {
  cd /tmp
  if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
  TEST_TMPDIR=""
}
trap cleanup EXIT

# Create a bare remote + clone simulating a mayor/rig setup
setup() {
  cleanup
  TEST_TMPDIR=$(mktemp -d)
  BARE_REPO="$TEST_TMPDIR/origin.git"
  CLONE_DIR="$TEST_TMPDIR/gt/testrig/mayor/rig"

  git init --bare "$BARE_REPO" >/dev/null 2>&1
  mkdir -p "$(dirname "$CLONE_DIR")"
  git clone "$BARE_REPO" "$CLONE_DIR" >/dev/null 2>&1
  cd "$CLONE_DIR"
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > file.txt
  git add file.txt
  git commit -m "initial" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  cd /tmp

  # Create routes.jsonl pointing to our test rig
  mkdir -p "$TEST_TMPDIR/gt/.beads"
  echo '{"prefix":"tr-","path":"testrig"}' > "$TEST_TMPDIR/gt/.beads/routes.jsonl"
}

# Run autopush in patrol mode with GT overridden
run_autopush() {
  local modified="$TEST_TMPDIR/autopush-modified.sh"
  sed "s|^GT=/Users/davidtarico/gt|GT=$TEST_TMPDIR/gt|" "$AUTOPUSH_SCRIPT" > "$modified"
  chmod +x "$modified"
  bash "$modified" 2>&1
}

echo "=== gt-mayor-autopush test suite ==="
echo ""

# ── Test 1: No unpushed commits — no-op ────────────────────────────────────
echo "--- Test 1: No unpushed commits ---"
setup

output=$(run_autopush)
# Should produce no [autopush] log lines (nothing to push)
if echo "$output" | grep -q "\[autopush\]"; then
  fail "Should be silent when nothing to push (got: $output)"
else
  pass "No output when no unpushed commits"
fi

# ── Test 2: Unpushed commits get pushed ─────────────────────────────────────
echo "--- Test 2: Unpushed commits get pushed ---"
setup

cd "$TEST_TMPDIR/gt/testrig/mayor/rig"
echo "new work" >> file.txt
git add file.txt
git commit -m "unpushed work" >/dev/null 2>&1
cd /tmp

# Verify there IS an unpushed commit
AHEAD=$(cd "$TEST_TMPDIR/gt/testrig/mayor/rig" && git rev-list --count origin/main..HEAD)
if [[ "$AHEAD" -ne 1 ]]; then
  fail "Setup error: expected 1 ahead, got $AHEAD"
else
  output=$(run_autopush)
  if echo "$output" | grep -q "pushed successfully"; then
    pass "Unpushed commit pushed to origin"
  else
    fail "Should report pushed successfully (got: $output)"
  fi

  # Verify the remote now has the commit
  AHEAD_AFTER=$(cd "$TEST_TMPDIR/gt/testrig/mayor/rig" && git fetch origin >/dev/null 2>&1 && git rev-list --count origin/main..HEAD)
  if [[ "$AHEAD_AFTER" -eq 0 ]]; then
    pass "Remote is now up to date"
  else
    fail "Remote should be up to date (still $AHEAD_AFTER ahead)"
  fi
fi

# ── Test 3: Diverged branch — rebase and push ──────────────────────────────
echo "--- Test 3: Diverged branch — rebase and push ---"
setup

# Push a commit directly to the bare repo (simulating drain or another clone pushing)
SCRATCH="$TEST_TMPDIR/scratch"
git clone "$TEST_TMPDIR/origin.git" "$SCRATCH" >/dev/null 2>&1
cd "$SCRATCH"
git config user.email "test@test.com"
git config user.name "Test"
echo "remote work" >> remote_file.txt
git add remote_file.txt
git commit -m "remote commit" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
cd /tmp

# Now add a local commit to mayor/rig (diverged from origin)
cd "$TEST_TMPDIR/gt/testrig/mayor/rig"
echo "local work" >> local_file.txt
git add local_file.txt
git commit -m "local commit" >/dev/null 2>&1
cd /tmp

output=$(run_autopush)
if echo "$output" | grep -q "rebased and pushed"; then
  pass "Diverged branch rebased and pushed"
else
  fail "Should rebase and push diverged branch (got: $output)"
fi

# Verify both commits are on origin
cd "$TEST_TMPDIR/gt/testrig/mayor/rig"
git fetch origin >/dev/null 2>&1
REMOTE_LOG=$(git log --oneline origin/main)
if echo "$REMOTE_LOG" | grep -q "remote commit" && echo "$REMOTE_LOG" | grep -q "local commit"; then
  pass "Both local and remote commits present on origin"
else
  fail "Both commits should be on origin (log: $REMOTE_LOG)"
fi
cd /tmp

# ── Test 4: Detached HEAD — skip ───────────────────────────────────────────
echo "--- Test 4: Detached HEAD — skip ---"
setup

cd "$TEST_TMPDIR/gt/testrig/mayor/rig"
git checkout --detach HEAD >/dev/null 2>&1
cd /tmp

output=$(run_autopush)
if echo "$output" | grep -q "\[autopush\]"; then
  fail "Should skip detached HEAD (got: $output)"
else
  pass "Detached HEAD skipped silently"
fi

# ── Test 5: Post-commit hook mode (GIT_DIR set) ────────────────────────────
echo "--- Test 5: Post-commit hook mode ---"
setup

cd "$TEST_TMPDIR/gt/testrig/mayor/rig"
echo "hook work" >> file.txt
git add file.txt
git commit -m "hook commit" >/dev/null 2>&1
cd /tmp

# Simulate post-commit hook: set GIT_DIR
GIT_DIR_VAL="$TEST_TMPDIR/gt/testrig/mayor/rig/.git"
output=$(GIT_DIR="$GIT_DIR_VAL" bash "$AUTOPUSH_SCRIPT" 2>&1)
if echo "$output" | grep -q "pushed successfully"; then
  pass "Post-commit hook mode pushes successfully"
else
  fail "Post-commit hook mode should push (got: $output)"
fi

# ── Test 6: No tracking branch — skip ──────────────────────────────────────
echo "--- Test 6: No tracking branch — skip ---"
setup

cd "$TEST_TMPDIR/gt/testrig/mayor/rig"
git checkout -b untracked-branch >/dev/null 2>&1
echo "untracked" >> file.txt
git add file.txt
git commit -m "untracked commit" >/dev/null 2>&1
cd /tmp

output=$(run_autopush)
if echo "$output" | grep -q "\[autopush\]"; then
  fail "Should skip branch with no upstream (got: $output)"
else
  pass "Untracked branch skipped silently"
fi

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
