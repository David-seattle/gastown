#!/bin/bash
# Test suite for gt-refinery-drain merge queue processor.
# Creates temporary git repos and mock commands to test rebase/merge logic.
#
# Usage: bash scripts/gt-refinery-drain_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRAIN_SCRIPT="${DRAIN_SCRIPT:-$SCRIPT_DIR/gt-refinery-drain}"
PASS=0
FAIL=0
TEST_TMPDIR=""
MOCK_DIR=""

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

cleanup() {
  cd /tmp  # Ensure CWD exists before removing TMPDIR
  if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
  TEST_TMPDIR=""
  MOCK_DIR=""
}
trap cleanup EXIT

# ── Helpers ─────────────────────────────────────────────────────────────────

# Create fresh temp directory with GT structure and mock binaries
setup() {
  cleanup
  TEST_TMPDIR=$(mktemp -d)
  MOCK_DIR="$TEST_TMPDIR/mocks"
  mkdir -p "$MOCK_DIR"
  mkdir -p "$TEST_TMPDIR/gt/.beads"
  mkdir -p "$TEST_TMPDIR/gt/.drain-locks"

  # Default empty routes (no hq prefix filtered out)
  echo '{"prefix":"hq-","path":"."}' > "$TEST_TMPDIR/gt/.beads/routes.jsonl"

  # Default mock: bd (no-op, returns empty)
  cat > "$MOCK_DIR/bd" << 'MOCK'
#!/bin/bash
# Default bd mock — returns empty for list, empty for show
if [[ "${1:-}" == "list" ]]; then
  echo "[]"
elif [[ "${1:-}" == "show" ]]; then
  echo ""
elif [[ "${1:-}" == "close" ]]; then
  exit 0
elif [[ "${1:-}" == "create" ]]; then
  echo '{}'
elif [[ "${1:-}" == "dep" ]]; then
  exit 0
fi
MOCK
  chmod +x "$MOCK_DIR/bd"

  # Default mock: gt (no-op)
  cat > "$MOCK_DIR/gt" << 'MOCK'
#!/bin/bash
exit 0
MOCK
  chmod +x "$MOCK_DIR/gt"
}

# Add a rig with route entry and refinery worktree
add_rig_with_refinery() {
  local rig="$1" prefix="$2"
  # Add route entry
  echo "{\"prefix\":\"${prefix}\",\"path\":\"${rig}\"}" >> "$TEST_TMPDIR/gt/.beads/routes.jsonl"

  # Create bare remote and clone as refinery
  local remote_dir="$TEST_TMPDIR/remotes/$rig.git"
  local refinery_dir="$TEST_TMPDIR/gt/$rig/refinery/rig"

  git init --bare "$remote_dir" >/dev/null 2>&1
  git clone "$remote_dir" "$refinery_dir" >/dev/null 2>&1
  cd "$refinery_dir"
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > file.txt
  git add file.txt
  git commit -m "initial" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  cd /tmp
}

# Run the drain script with GT overridden, mocks on PATH
run_drain() {
  local gt_dir="$TEST_TMPDIR/gt"
  # Build a modified script that uses our GT and prepends MOCK_DIR to its PATH
  local modified_script="$TEST_TMPDIR/drain-modified.sh"
  sed "s|^GT=/Users/davidtarico/gt|GT=$gt_dir|" "$DRAIN_SCRIPT" > "$modified_script"
  # The script sets its own PATH on line 12, pushing our mocks behind real binaries.
  # Inject MOCK_DIR at the front of that PATH export so mocks win.
  sed -i '' "s|^export PATH=\"|export PATH=\"$MOCK_DIR:|" "$modified_script"
  chmod +x "$modified_script"

  DRY_RUN="${DRY_RUN:-0}" bash "$modified_script" 2>&1
}

echo "=== gt-refinery-drain test suite ==="
echo ""

# ── Test 1: No rigs with refinery worktree ──────────────────────────────────
echo "--- Test 1: No rigs with refinery worktree ---"
setup
# Add a rig route but do NOT create the refinery directory
echo '{"prefix":"ba-","path":"backend"}' >> "$TEST_TMPDIR/gt/.beads/routes.jsonl"
mkdir -p "$TEST_TMPDIR/gt/backend"  # rig dir exists, but no refinery/rig/.git

output=$(run_drain)
if echo "$output" | grep -q "(empty queue)"; then
  pass "Reports empty queue when no rigs have refinery"
else
  fail "Should report empty queue (got: $output)"
fi

# ── Test 2: Rig with refinery but no MRs ────────────────────────────────────
echo "--- Test 2: Rig with refinery but no MRs ---"
setup
add_rig_with_refinery "backend" "ba-"

# bd list returns empty array (default mock)
output=$(run_drain)
if echo "$output" | grep -q "(empty queue)"; then
  pass "Reports empty queue when no MRs exist"
else
  fail "Should report empty queue when no MRs (got: $output)"
fi

# ── Test 3: MR bead found but bd show returns empty ─────────────────────────
echo "--- Test 3: bd show returns empty for MR bead ---"
setup
add_rig_with_refinery "backend" "ba-"

# bd mock: list returns one MR, show returns empty
cat > "$MOCK_DIR/bd" << 'MOCK'
#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr01","dependency_count":0}]'
elif [[ "${1:-}" == "show" ]]; then
  echo ""
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

output=$(run_drain)
if echo "$output" | grep -q "could not read MR details, skipping"; then
  pass "Logs skip message when bd show returns empty"
else
  fail "Should report 'could not read MR details, skipping' (got: $output)"
fi

# ── Test 4: MR with missing branch field ────────────────────────────────────
echo "--- Test 4: MR with missing branch field ---"
setup
add_rig_with_refinery "backend" "ba-"

# bd mock: list returns MR, show returns detail with branch/target keys present
# but empty values. We include the keys so grep matches (avoiding pipefail crash
# from grep returning 1 when no line matches at all).
cat > "$MOCK_DIR/bd" << 'MOCK'
#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr02","dependency_count":0}]'
elif [[ "${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr02","description":"branch:\ntarget:\nsource_issue: ba-1234"}'
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

output=$(run_drain)
if echo "$output" | grep -q "missing branch or target"; then
  pass "Logs 'missing branch or target, skipping'"
else
  fail "Should report missing branch or target (got: $output)"
fi

# ── Test 5: DRY_RUN=1 ──────────────────────────────────────────────────────
echo "--- Test 5: DRY_RUN=1 logs dry run message ---"
setup
add_rig_with_refinery "backend" "ba-"

cat > "$MOCK_DIR/bd" << 'MOCK'
#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr03","dependency_count":0}]'
elif [[ "${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr03","description":"branch: polecat/fix-stuff\ntarget: main\nsource_issue: ba-5678"}'
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

output=$(DRY_RUN=1 run_drain)
if echo "$output" | grep -q "would attempt rebase merge"; then
  pass "DRY_RUN logs 'would attempt rebase merge'"
else
  fail "Should log dry run message (got: $output)"
fi
# Ensure no git push happened (the mock git would log calls if we instrumented it,
# but the DRY_RUN returns before any git operations, so just check no merge message)
if echo "$output" | grep -q "merged successfully"; then
  fail "DRY_RUN should not actually merge"
else
  pass "DRY_RUN does not execute merge"
fi

# ── Test 6: Branch not found on remote ──────────────────────────────────────
echo "--- Test 6: Branch not found on remote ---"
setup
add_rig_with_refinery "backend" "ba-"

# Track bd close calls (unquoted heredoc so $MOCK_DIR expands)
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr04","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr04","description":"branch: nonexistent/branch\ntarget: main\nsource_issue: ba-9999"}'
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$2:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

output=$(run_drain)
if echo "$output" | grep -q "branch.*not found on remote.*closing MR"; then
  pass "Reports branch not found and closes MR"
else
  fail "Should report branch not found (got: $output)"
fi
# Verify bd close was called with the MR id
if grep -q "ba-mr04" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "bd close called for missing branch MR"
else
  fail "bd close should be called for missing branch MR"
fi

# ── Test 7: Clean fast-forward merge ────────────────────────────────────────
echo "--- Test 7: Clean fast-forward merge ---"
setup
add_rig_with_refinery "backend" "ba-"

# Create a feature branch with new commits on the remote
refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/clean-work >/dev/null 2>&1
echo "new work" >> file.txt
git add file.txt
git commit -m "clean work" >/dev/null 2>&1
git push origin polecat/clean-work >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# Track bd close calls (unquoted heredoc so $MOCK_DIR expands)
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr05","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr05","description":"branch: polecat/clean-work\ntarget: main\nsource_issue: ba-1111"}'
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

output=$(run_drain)
if echo "$output" | grep -q "merged successfully"; then
  pass "Reports merged successfully"
else
  fail "Should report merged successfully (got: $output)"
fi
# Verify both MR and source issue were closed
if grep -q "ba-mr05" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "MR bead closed after merge"
else
  fail "MR bead should be closed after merge"
fi
if grep -q "ba-1111" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "Source issue closed after merge"
else
  fail "Source issue should be closed after merge"
fi
# Verify the merge actually happened (not just "already merged" path)
if echo "$output" | grep -q "already merged"; then
  fail "Should do actual rebase merge, not detect as already merged"
else
  pass "Commit merged via rebase path (not already-merged shortcut)"
fi

# ── Test 7b: Source close refused (open molecule) is force-closed after merge ──
echo "--- Test 7b: Merged source bead whose normal close is refused gets force-closed ---"
setup
add_rig_with_refinery "backend" "ba-"

# Feature branch with new commits on the remote (clean merge path)
refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/blocked-work >/dev/null 2>&1
echo "blocked work" >> file.txt
git add file.txt
git commit -m "blocked work" >/dev/null 2>&1
git push origin polecat/blocked-work >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: source bead ba-7b01's NORMAL close is refused (open molecule); it
# succeeds only with --force. MR bead closes normally. Mirrors the real failure
# where a stalled polecat left its work molecule open, blocking bd close.
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr7b","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr7b","description":"branch: polecat/blocked-work\ntarget: main\nsource_issue: ba-7b01"}'
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  if echo "\$*" | grep -q "ba-7b01" && ! echo "\$*" | grep -q -- "--force"; then
    echo "cannot close ba-7b01: blocked by open issues [ba-wisp-x] (use --force to override)" >&2
    exit 1
  fi
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

output=$(run_drain)
if echo "$output" | grep -q "merged successfully"; then
  pass "7b: merge reached the source-close path"
else
  fail "7b: should report merged successfully (got: $output)"
fi
# The fix must escalate to --force and log it, not swallow the refusal.
if grep -qE "close.*ba-7b01.*--force|close.*--force.*ba-7b01" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "7b: refused source close escalated to --force after merge"
else
  fail "7b: source close should escalate to --force (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi
if echo "$output" | grep -qiE "force-clos"; then
  pass "7b: force-close logged loudly (not swallowed)"
else
  fail "7b: force-close should be logged (got: $output)"
fi

# ── Test 8: Rebase needed (branch diverged) ─────────────────────────────────
echo "--- Test 8: Rebase needed (branch diverged) ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"

# Create diverged history: new commit on main, then branch from old main
git checkout main >/dev/null 2>&1
echo "main diverged work" >> main_file.txt
git add main_file.txt
git commit -m "main diverged" >/dev/null 2>&1
git push origin main >/dev/null 2>&1

# Create branch from old main (before diverge)
git checkout HEAD~1 >/dev/null 2>&1
git checkout -b polecat/diverged-work >/dev/null 2>&1
echo "branch work" >> branch_file.txt
git add branch_file.txt
git commit -m "branch diverged work" >/dev/null 2>&1
git push origin polecat/diverged-work >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr06","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr06","description":"branch: polecat/diverged-work\ntarget: main\nsource_issue: ba-2222"}'
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

output=$(run_drain)
if echo "$output" | grep -q "merged successfully"; then
  pass "Diverged branch rebased and merged successfully"
else
  fail "Should rebase and merge diverged branch (got: $output)"
fi
# Verify both commits appear on main
cd "$refinery"
git fetch origin >/dev/null 2>&1
main_log=$(git log --oneline origin/main)
if echo "$main_log" | grep -q "main diverged" && echo "$main_log" | grep -q "branch diverged work"; then
  pass "Both diverged commits appear on target after rebase merge"
else
  fail "Both commits should appear on target (main log: $main_log)"
fi
cd /tmp

# ── Test 9: Rebase conflict ────────────────────────────────────────────────
echo "--- Test 9: Rebase conflict creates resolution task ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"

# Create conflicting changes on same file/line
git checkout main >/dev/null 2>&1
echo "main version of line" > conflict.txt
git add conflict.txt
git commit -m "main conflict line" >/dev/null 2>&1
git push origin main >/dev/null 2>&1

# Branch from before the conflict commit
git checkout HEAD~1 >/dev/null 2>&1
git checkout -b polecat/conflict-work >/dev/null 2>&1
echo "branch version of line" > conflict.txt
git add conflict.txt
git commit -m "branch conflict line" >/dev/null 2>&1
git push origin polecat/conflict-work >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock that returns a task id on create (unquoted heredoc so $MOCK_DIR expands)
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr07","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr07","description":"branch: polecat/conflict-work\ntarget: main\nsource_issue: ba-3333"}'
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
elif [[ "\${1:-}" == "create" ]]; then
  echo '{"id":"ba-task01"}'
elif [[ "\${1:-}" == "dep" ]]; then
  echo "DEP:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

# gt mock that logs sling calls (MOCK_DIR expanded at write time)
cat > "$MOCK_DIR/gt" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "sling" ]]; then
  echo "SLING:\$*" >> "$MOCK_DIR/gt_calls.log"
fi
exit 0
MOCK
chmod +x "$MOCK_DIR/gt"
> "$MOCK_DIR/bd_calls.log"
> "$MOCK_DIR/gt_calls.log"

output=$(run_drain)
if echo "$output" | grep -q "rebase conflict, creating resolution task"; then
  pass "Reports rebase conflict"
else
  fail "Should report rebase conflict (got: $output)"
fi
if echo "$output" | grep -q "conflict task ba-task01 slung"; then
  pass "Reports conflict task slung"
else
  fail "Should report conflict task slung (got: $output)"
fi
# Verify dep add was called to block MR on task
if grep -q "DEP:dep add ba-mr07 ba-task01" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "bd dep add called to block MR on conflict task"
else
  fail "bd dep add should link MR to conflict task (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi
# Verify gt sling was called
if grep -q "SLING:.*ba-task01.*backend" "$MOCK_DIR/gt_calls.log" 2>/dev/null; then
  pass "gt sling called for conflict task"
else
  fail "gt sling should be called (calls: $(cat "$MOCK_DIR/gt_calls.log" 2>/dev/null))"
fi

# ── Test 10: Lock acquisition — second process skipped ──────────────────────
echo "--- Test 10: Lock acquisition — second process skipped ---"
setup
add_rig_with_refinery "backend" "ba-"

# bd mock returns MRs
cat > "$MOCK_DIR/bd" << 'MOCK'
#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr08","dependency_count":0}]'
elif [[ "${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr08","description":"branch: polecat/locked\ntarget: main\nsource_issue: ba-4444"}'
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

# Pre-create a lock file with our own PID (simulating another running process)
mkdir -p "$TEST_TMPDIR/gt/.drain-locks"
echo $$ > "$TEST_TMPDIR/gt/.drain-locks/backend.lock"

output=$(run_drain)
if echo "$output" | grep -q "lock held.*skipping"; then
  pass "Second process skipped due to held lock"
else
  fail "Should skip rig when lock is held (got: $output)"
fi

# ── Test 11: Stale lock detection ───────────────────────────────────────────
echo "--- Test 11: Stale lock detection ---"
setup
add_rig_with_refinery "backend" "ba-"

# bd mock returns MRs with branch info for full processing
cat > "$MOCK_DIR/bd" << 'MOCK'
#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr09","dependency_count":0}]'
elif [[ "${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr09","description":"branch: nonexistent/stale-test\ntarget: main\nsource_issue: ba-5555"}'
elif [[ "${1:-}" == "close" ]]; then
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

# Create a lock file with a guaranteed-dead PID
mkdir -p "$TEST_TMPDIR/gt/.drain-locks"
echo 2147483647 > "$TEST_TMPDIR/gt/.drain-locks/backend.lock"

output=$(run_drain)
if echo "$output" | grep -q "removing stale lock"; then
  pass "Stale lock detected and removed"
else
  fail "Should detect and remove stale lock (got: $output)"
fi
# Script should continue processing after removing stale lock
if echo "$output" | grep -q "1 MR(s) ready"; then
  pass "Processing continues after stale lock removal"
else
  fail "Should continue processing after stale lock removal (got: $output)"
fi

# ── Test 12: parse_mr_field extracts fields correctly ───────────────────────
echo "--- Test 12: parse_mr_field extracts fields correctly ---"

# Source the function directly by extracting it
parse_mr_field() {
    local desc="$1" field="$2"
    echo "$desc" | grep "^${field}:" | head -1 | sed "s/^${field}: *//"
}

desc="branch: polecat/my-feature
target: main
source_issue: ba-1234
retry_count: 2"

result=$(parse_mr_field "$desc" "branch")
if [[ "$result" == "polecat/my-feature" ]]; then
  pass "parse_mr_field extracts branch"
else
  fail "parse_mr_field branch: expected 'polecat/my-feature', got '$result'"
fi

result=$(parse_mr_field "$desc" "target")
if [[ "$result" == "main" ]]; then
  pass "parse_mr_field extracts target"
else
  fail "parse_mr_field target: expected 'main', got '$result'"
fi

result=$(parse_mr_field "$desc" "source_issue")
if [[ "$result" == "ba-1234" ]]; then
  pass "parse_mr_field extracts source_issue"
else
  fail "parse_mr_field source_issue: expected 'ba-1234', got '$result'"
fi

result=$(parse_mr_field "$desc" "retry_count")
if [[ "$result" == "2" ]]; then
  pass "parse_mr_field extracts retry_count"
else
  fail "parse_mr_field retry_count: expected '2', got '$result'"
fi

# Note: parse_mr_field uses grep which returns 1 when no line matches.
# Under set -eo pipefail, this kills the pipeline. Use || true to capture.
result=$(parse_mr_field "$desc" "nonexistent" || true)
if [[ -z "$result" ]]; then
  pass "parse_mr_field returns empty for missing field"
else
  fail "parse_mr_field nonexistent: expected empty, got '$result'"
fi

# Test with extra spaces after colon
desc_spaces="branch:   polecat/spaced-branch"
result=$(parse_mr_field "$desc_spaces" "branch")
if [[ "$result" == "polecat/spaced-branch" ]]; then
  pass "parse_mr_field handles extra spaces after colon"
else
  fail "parse_mr_field spaces: expected 'polecat/spaced-branch', got '$result'"
fi

# ── Test 13: discover_rigs reads routes.jsonl correctly ─────────────────────
echo "--- Test 13: discover_rigs reads routes.jsonl correctly ---"
setup

# Set up routes with various prefixes including hq (should be excluded)
cat > "$TEST_TMPDIR/gt/.beads/routes.jsonl" << 'ROUTES'
{"prefix":"hq-","path":"."}
{"prefix":"hq-cv-","path":"."}
{"prefix":"ba-","path":"backend"}
{"prefix":"fr-","path":"frontend"}
{"prefix":"gt-","path":"gastown/mayor/rig"}
{"prefix":"cl-","path":"cleansing"}
ROUTES

# discover_rigs uses jq and reads from $GT/.beads/routes.jsonl
# Run it via the modified script, but we only need the function.
# Replicate the function with our GT:
gt_dir="$TEST_TMPDIR/gt"
rigs=$(jq -r 'select(.prefix | test("^hq-") | not) | .path' "$gt_dir/.beads/routes.jsonl" |
    cut -d/ -f1 | sort -u)

expected="backend
cleansing
frontend
gastown"

if [[ "$rigs" == "$expected" ]]; then
  pass "discover_rigs returns correct rigs (excludes hq, deduplicates)"
else
  fail "discover_rigs: expected '$expected', got '$rigs'"
fi

# Verify hq rigs are excluded
if echo "$rigs" | grep -q "^\\.$"; then
  fail "discover_rigs should exclude hq entries (path '.')"
else
  pass "discover_rigs excludes hq entries"
fi

# Verify gastown is deduplicated (only one entry even though path has slashes)
gastown_count=$(echo "$rigs" | grep -c "gastown")
if [[ "$gastown_count" -eq 1 ]]; then
  pass "discover_rigs deduplicates multi-segment paths"
else
  fail "discover_rigs should deduplicate (got $gastown_count gastown entries)"
fi

# ── Test 14: Direct push blocked — falls back to GitHub PR ────────────────
echo "--- Test 14: Direct push blocked — falls back to GitHub PR ---"
setup
add_rig_with_refinery "backend" "ba-"

# Create a feature branch with new commits
refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/pr-work >/dev/null 2>&1
echo "pr work" >> file.txt
git add file.txt
git commit -m "pr work" >/dev/null 2>&1
git push origin polecat/pr-work >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: list returns MR, show returns details, close/update tracked
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr14","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr14","description":"branch: polecat/pr-work\ntarget: main\nsource_issue: ba-7777"}'
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
elif [[ "\${1:-}" == "update" ]]; then
  echo "UPDATE:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

# git mock: override ONLY push to target (simulating branch protection block)
# Wrap the real git so all other git commands work normally
REAL_GIT=$(which git)
cat > "$MOCK_DIR/git" << MOCK
#!/bin/bash
# Block push to target branch (simulates GitHub branch protection)
if [[ "\${1:-}" == "push" ]] && [[ "\$*" == *"temp-merge:main"* ]]; then
  exit 1
fi
# Allow force-push of rebased branch to polecat branch
exec $REAL_GIT "\$@"
MOCK
chmod +x "$MOCK_DIR/git"

# gh mock: track PR creation and auto-merge calls
cat > "$MOCK_DIR/gh" << MOCK
#!/bin/bash
echo "GH:\$*" >> "$MOCK_DIR/gh_calls.log"
if [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "list" ]]; then
  echo "[]"  # No existing PRs (any state)
elif [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "create" ]]; then
  echo "https://github.com/test/backend/pull/42"
elif [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "merge" ]]; then
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/gh"
> "$MOCK_DIR/gh_calls.log"

output=$(run_drain)

# Should NOT say "push failed ... leaving open for retry" (old behavior)
if echo "$output" | grep -q "leaving open for retry"; then
  fail "Should NOT leave open for retry — should fall back to PR"
else
  pass "Does not leave open for retry on blocked push"
fi

# Should log that it's trying the PR approach
if echo "$output" | grep -q "direct push blocked\|trying GitHub PR\|created PR"; then
  pass "Falls back to GitHub PR when direct push is blocked"
else
  fail "Should fall back to GitHub PR (got: $output)"
fi

# Verify gh pr create was called
if grep -q "pr create" "$MOCK_DIR/gh_calls.log" 2>/dev/null; then
  pass "gh pr create called"
else
  fail "gh pr create should be called (gh calls: $(cat "$MOCK_DIR/gh_calls.log" 2>/dev/null))"
fi

# Verify gh pr merge --auto was called (to enable auto-merge)
if grep -q "pr merge.*--auto" "$MOCK_DIR/gh_calls.log" 2>/dev/null; then
  pass "gh pr merge --auto called for auto-merge"
else
  fail "gh pr merge --auto should be called (gh calls: $(cat "$MOCK_DIR/gh_calls.log" 2>/dev/null))"
fi

# ── Test 15: Direct push blocked + existing PR — skip duplicate PR ────────
echo "--- Test 15: Direct push blocked + existing PR — skip duplicate ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/existing-pr >/dev/null 2>&1
echo "existing pr work" >> file.txt
git add file.txt
git commit -m "existing pr work" >/dev/null 2>&1
git push origin polecat/existing-pr >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr15","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr15","description":"branch: polecat/existing-pr\ntarget: main\nsource_issue: ba-8888"}'
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

REAL_GIT=$(which git)
cat > "$MOCK_DIR/git" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "push" ]] && [[ "\$*" == *"temp-merge:main"* ]]; then
  exit 1
fi
exec $REAL_GIT "\$@"
MOCK
chmod +x "$MOCK_DIR/git"

# gh mock: pr list returns an existing open PR as JSON array
cat > "$MOCK_DIR/gh" << MOCK
#!/bin/bash
echo "GH:\$*" >> "$MOCK_DIR/gh_calls.log"
if [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "list" ]]; then
  echo '[{"number":99,"state":"OPEN"}]'
elif [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "create" ]]; then
  echo "https://github.com/test/backend/pull/99"
fi
MOCK
chmod +x "$MOCK_DIR/gh"
> "$MOCK_DIR/gh_calls.log"

output=$(run_drain)

# Should detect existing PR and skip creation
if echo "$output" | grep -q "PR #99 already open\|already open.*waiting"; then
  pass "Detects existing PR and skips duplicate creation"
else
  fail "Should detect existing PR (got: $output)"
fi

# Verify gh pr create was NOT called
if grep -q "pr create" "$MOCK_DIR/gh_calls.log" 2>/dev/null; then
  fail "gh pr create should NOT be called when PR exists"
else
  pass "gh pr create not called when PR already exists"
fi

# ── Test 16: Closed PR prevents re-creation (core loop fix) ──────────────
echo "--- Test 16: Closed PR prevents re-creation ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/closed-pr >/dev/null 2>&1
echo "closed pr work" >> file.txt
git add file.txt
git commit -m "closed pr work" >/dev/null 2>&1
git push origin polecat/closed-pr >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: list returns MR, show returns details, close is tracked
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr16","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr16","description":"branch: polecat/closed-pr\ntarget: main\nsource_issue: ba-9100"}'
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  echo "✓ Closed \$2"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

REAL_GIT=$(which git)
cat > "$MOCK_DIR/git" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "push" ]] && [[ "\$*" == *"temp-merge:main"* ]]; then
  exit 1
fi
exec $REAL_GIT "\$@"
MOCK
chmod +x "$MOCK_DIR/git"

# gh mock: pr list returns a CLOSED PR (simulating user closed a drain PR)
cat > "$MOCK_DIR/gh" << MOCK
#!/bin/bash
echo "GH:\$*" >> "$MOCK_DIR/gh_calls.log"
if [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "list" ]]; then
  echo '[{"number":302,"state":"CLOSED"}]'
elif [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "create" ]]; then
  echo "https://github.com/test/backend/pull/303"
fi
MOCK
chmod +x "$MOCK_DIR/gh"
> "$MOCK_DIR/gh_calls.log"

output=$(run_drain)

# Should detect closed PR and NOT create a new one
if grep -q "pr create" "$MOCK_DIR/gh_calls.log" 2>/dev/null; then
  fail "Should NOT create a new PR when a closed PR exists for the branch"
else
  pass "No new PR created when closed PR exists (loop prevention)"
fi

# Should log the closed PR detection
if echo "$output" | grep -q "PR #302 exists (CLOSED)"; then
  pass "Logs closed PR detection"
else
  fail "Should log closed PR detection (got: $output)"
fi

# Should close the MR bead
if grep -q "ba-mr16" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "MR bead closed when closed PR detected"
else
  fail "MR bead should be closed (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi

# ── Test 17: drain_close logs errors instead of suppressing ──────────────
echo "--- Test 17: drain_close logs errors ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/close-error >/dev/null 2>&1
echo "close error work" >> file.txt
git add file.txt
git commit -m "close error work" >/dev/null 2>&1
git push origin polecat/close-error >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: close FAILS with error message
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr17","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr17","description":"branch: polecat/close-error\ntarget: main\nsource_issue: ba-9200"}'
elif [[ "\${1:-}" == "close" ]]; then
  echo "Error: connection refused" >&2
  exit 1
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

REAL_GIT=$(which git)
cat > "$MOCK_DIR/git" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "push" ]] && [[ "\$*" == *"temp-merge:main"* ]]; then
  exit 1
fi
exec $REAL_GIT "\$@"
MOCK
chmod +x "$MOCK_DIR/git"

# gh mock: no existing PRs, successful PR creation
cat > "$MOCK_DIR/gh" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "list" ]]; then
  echo "[]"
elif [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "create" ]]; then
  echo "https://github.com/test/backend/pull/50"
elif [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "merge" ]]; then
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/gh"

output=$(run_drain)

# Should log the bd close failure (not suppress it)
if echo "$output" | grep -q "WARNING.*bd close.*failed"; then
  pass "drain_close logs warning on failure"
else
  fail "Should log bd close failure (got: $output)"
fi

# ── Test 18: close_all_mrs_for_branch closes duplicates ──────────────────
echo "--- Test 18: close_all_mrs_for_branch closes duplicate MR beads ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/dupe-branch >/dev/null 2>&1
echo "dupe work" >> file.txt
git add file.txt
git commit -m "dupe work" >/dev/null 2>&1
git push origin polecat/dupe-branch >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: list returns TWO MR beads for the same branch, show returns details,
# close is tracked. Use a call counter to alternate show responses.
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  # Return both MR beads: one for process_rig query, and both for close_all query
  echo '[{"id":"ba-mr18a","dependency_count":0},{"id":"ba-mr18b","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  # Both MR beads reference the same branch
  if [[ "\${2:-}" == "ba-mr18a" ]]; then
    echo '{"id":"ba-mr18a","description":"branch: polecat/dupe-branch\ntarget: main\nsource_issue: ba-9300"}'
  elif [[ "\${2:-}" == "ba-mr18b" ]]; then
    echo '{"id":"ba-mr18b","description":"branch: polecat/dupe-branch\ntarget: main\nsource_issue: ba-9300"}'
  else
    echo '{}'
  fi
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  echo "✓ Closed \$2"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

REAL_GIT=$(which git)
cat > "$MOCK_DIR/git" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "push" ]] && [[ "\$*" == *"temp-merge:main"* ]]; then
  exit 1
fi
exec $REAL_GIT "\$@"
MOCK
chmod +x "$MOCK_DIR/git"

# gh mock: no existing PRs, successful PR creation
cat > "$MOCK_DIR/gh" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "list" ]]; then
  echo "[]"
elif [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "create" ]]; then
  echo "https://github.com/test/backend/pull/55"
elif [[ "\${1:-}" == "pr" ]] && [[ "\${2:-}" == "merge" ]]; then
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/gh"

output=$(run_drain)

# Both MR beads should be closed
if grep -q "ba-mr18a" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "First duplicate MR bead closed"
else
  fail "First MR bead should be closed (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi
if grep -q "ba-mr18b" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "Second duplicate MR bead closed"
else
  fail "Second MR bead should be closed (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi

# Source issue should also be closed
if grep -q "ba-9300" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "Source issue closed along with MR beads"
else
  fail "Source issue should be closed (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi

# ── Test 19: Refinery HEAD detached after processing ───────────────────────
echo "--- Test 19: Refinery HEAD detached after processing ---"
setup
add_rig_with_refinery "backend" "ba-"

# Create a feature branch with new commits
refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/detach-test >/dev/null 2>&1
echo "detach test" >> file.txt
git add file.txt
git commit -m "detach test work" >/dev/null 2>&1
git push origin polecat/detach-test >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr19","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr19","description":"branch: polecat/detach-test\ntarget: main\nsource_issue: ba-9400"}'
elif [[ "\${1:-}" == "close" ]]; then
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"

output=$(run_drain)
if echo "$output" | grep -q "merged successfully"; then
  pass "MR merged for detach test"
else
  fail "Expected merged successfully (got: $output)"
fi

# After processing, the refinery should have a detached HEAD (not on main).
# This prevents "refusing to update checked out branch" errors when other
# clones (e.g., mayor/rig) push to origin/main.
cd "$refinery"
if git symbolic-ref HEAD >/dev/null 2>&1; then
  CHECKED_OUT=$(git symbolic-ref --short HEAD 2>/dev/null)
  fail "Refinery HEAD should be detached, but is on branch '$CHECKED_OUT'"
else
  pass "Refinery HEAD is detached after processing"
fi
cd /tmp

# ── Test 20: Dedup — skip conflict task if MR has open dependency ─────────
echo "--- Test 20: Dedup — skip conflict task if MR has open dependency ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"

# Create conflicting changes on same file/line
git checkout main >/dev/null 2>&1
echo "main dedup version" > dedup_conflict.txt
git add dedup_conflict.txt
git commit -m "main dedup conflict" >/dev/null 2>&1
git push origin main >/dev/null 2>&1

git checkout HEAD~1 >/dev/null 2>&1
git checkout -b polecat/dedup-conflict >/dev/null 2>&1
echo "branch dedup version" > dedup_conflict.txt
git add dedup_conflict.txt
git commit -m "branch dedup conflict" >/dev/null 2>&1
git push origin polecat/dedup-conflict >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: show returns MR with an existing open dependency (conflict task)
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr20","dependency_count":1}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr20","description":"branch: polecat/dedup-conflict\ntarget: main\nsource_issue: ba-dedup1","dependencies":[{"id":"ba-task-existing","status":"open","title":"Resolve merge conflicts: ba-dedup1"}]}'
elif [[ "\${1:-}" == "create" ]]; then
  echo "CREATE:\$*" >> "$MOCK_DIR/bd_calls.log"
  echo '{"id":"ba-task-dup"}'
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

cat > "$MOCK_DIR/gt" << MOCK
#!/bin/bash
echo "SLING:\$*" >> "$MOCK_DIR/gt_calls.log"
exit 0
MOCK
chmod +x "$MOCK_DIR/gt"
> "$MOCK_DIR/gt_calls.log"

output=$(run_drain)

# dependency_count=1 should filter out this MR at line 352, so no processing at all
if echo "$output" | grep -q "(empty queue)"; then
  pass "MR with dependency_count=1 filtered out (not processed)"
else
  # If it somehow gets through, at least verify no duplicate task created
  if grep -q "CREATE" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
    fail "Should NOT create duplicate conflict task (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
  else
    pass "No duplicate conflict task created"
  fi
fi

# ── Test 21: Dedup — in-process dedup when dependency_count is stale ──────
echo "--- Test 21: Dedup — in-process dedup catches stale dependency_count ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"

# Create conflicting changes
git checkout main >/dev/null 2>&1
echo "main stale version" > stale_conflict.txt
git add stale_conflict.txt
git commit -m "main stale conflict" >/dev/null 2>&1
git push origin main >/dev/null 2>&1

git checkout HEAD~1 >/dev/null 2>&1
git checkout -b polecat/stale-conflict >/dev/null 2>&1
echo "branch stale version" > stale_conflict.txt
git add stale_conflict.txt
git commit -m "branch stale conflict" >/dev/null 2>&1
git push origin polecat/stale-conflict >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: list returns dependency_count=0 (stale), but show reveals open dependency
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr21","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  echo '{"id":"ba-mr21","description":"branch: polecat/stale-conflict\ntarget: main\nsource_issue: ba-stale1","dependencies":[{"id":"ba-task-prev","status":"open","title":"Resolve merge conflicts: ba-stale1"}]}'
elif [[ "\${1:-}" == "create" ]]; then
  echo "CREATE:\$*" >> "$MOCK_DIR/bd_calls.log"
  echo '{"id":"ba-task-dup2"}'
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

cat > "$MOCK_DIR/gt" << MOCK
#!/bin/bash
echo "SLING:\$*" >> "$MOCK_DIR/gt_calls.log"
exit 0
MOCK
chmod +x "$MOCK_DIR/gt"
> "$MOCK_DIR/gt_calls.log"

output=$(run_drain)

# The in-process dedup should catch this even though dependency_count was 0
if echo "$output" | grep -q "already has open dependency"; then
  pass "In-process dedup catches stale dependency_count"
else
  fail "Should detect existing open dependency (got: $output)"
fi

# No duplicate task should be created
if grep -q "CREATE" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  fail "Should NOT create duplicate conflict task"
else
  pass "No duplicate conflict task created with stale count"
fi

# ── Test 22: bd list failure is logged, not silently swallowed ──────────────
echo "--- Test 22: bd list failure is logged ---"
setup
add_rig_with_refinery "backend" "ba-"

# bd mock: list FAILS (simulates Dolt unreachable / wrong database)
cat > "$MOCK_DIR/bd" << 'MOCK'
#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo 'Error: database "backend" not found on Dolt server at 127.0.0.1:14006' >&2
  exit 1
fi
exit 0
MOCK
chmod +x "$MOCK_DIR/bd"

output=$(run_drain)

# The drain should log that bd list failed, not silently report empty queue
if echo "$output" | grep -q "bd list failed"; then
  pass "bd list failure is logged"
else
  fail "bd list failure should be logged, not silently swallowed (got: $output)"
fi

# It should NOT report "(empty queue)" — that masks the real error
if echo "$output" | grep -q "(empty queue)"; then
  fail "Should not report empty queue when bd list actually failed"
else
  pass "Does not report false empty queue on bd list failure"
fi

# ── Test 23: Source issue closed — MR and conflict tasks closed ─────────────
echo "--- Test 23: Source issue closed — orphaned MR cleaned up ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/orphan-branch >/dev/null 2>&1
echo "orphan work" >> file.txt
git add file.txt
git commit -m "orphan work" >/dev/null 2>&1
git push origin polecat/orphan-branch >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: source issue is CLOSED, MR has an open conflict task dependency
BD_SHOW_CALL=0
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr23","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  if [[ "\${2:-}" == "ba-src23" ]]; then
    echo '{"id":"ba-src23","status":"closed"}'
  elif [[ "\${2:-}" == "ba-task23" ]]; then
    echo '{"id":"ba-task23","status":"open"}'
  else
    echo '{"id":"ba-mr23","description":"branch: polecat/orphan-branch\ntarget: main\nsource_issue: ba-src23","dependencies":[{"id":"ba-task23","status":"open","title":"Resolve merge conflicts: ba-src23"}]}'
  fi
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

output=$(run_drain)

# Should detect source issue is closed and close the MR
if echo "$output" | grep -q "source issue ba-src23 is closed, closing MR"; then
  pass "Detects source issue is closed"
else
  fail "Should detect source issue is closed (got: $output)"
fi

# Conflict task should also be closed
if grep -q "ba-task23" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "Open conflict task closed when source issue closed"
else
  fail "Conflict task should be closed (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi

# MR bead should be closed (via close_all_mrs_for_branch)
if grep -q "ba-mr23" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "MR bead closed when source issue closed"
else
  fail "MR bead should be closed (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi

# Should NOT attempt git fetch or rebase (early return)
if echo "$output" | grep -q "merged successfully\|rebase conflict\|git fetch failed"; then
  fail "Should return early without attempting merge"
else
  pass "Returns early without attempting merge"
fi

# ── Test 24: Source issue closed — skip in_progress conflict task ──────────
echo "--- Test 24: Source issue closed — skip in_progress conflict task ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/active-conflict >/dev/null 2>&1
echo "active conflict work" >> file.txt
git add file.txt
git commit -m "active conflict" >/dev/null 2>&1
git push origin polecat/active-conflict >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: source issue CLOSED, conflict task is IN_PROGRESS (active polecat)
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr24","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  if [[ "\${2:-}" == "ba-src24" ]]; then
    echo '{"id":"ba-src24","status":"closed"}'
  elif [[ "\${2:-}" == "ba-task24" ]]; then
    echo '{"id":"ba-task24","status":"in_progress"}'
  else
    echo '{"id":"ba-mr24","description":"branch: polecat/active-conflict\ntarget: main\nsource_issue: ba-src24","dependencies":[{"id":"ba-task24","status":"in_progress","title":"Resolve merge conflicts: ba-src24"}]}'
  fi
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

output=$(run_drain)

# Should detect source issue is closed
if echo "$output" | grep -q "source issue ba-src24 is closed"; then
  pass "Detects source issue closed with active conflict task"
else
  fail "Should detect source issue closed (got: $output)"
fi

# Should skip the in_progress conflict task
if echo "$output" | grep -q "skipping active conflict task ba-task24"; then
  pass "Skips in_progress conflict task"
else
  fail "Should skip in_progress conflict task (got: $output)"
fi

# The in_progress task should NOT appear in close calls
if grep -q "ba-task24" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  fail "Should NOT close in_progress conflict task"
else
  pass "In_progress conflict task not closed"
fi

# MR bead should still be closed
if grep -q "ba-mr24" "$MOCK_DIR/bd_calls.log" 2>/dev/null; then
  pass "MR bead still closed even with active conflict task"
else
  fail "MR bead should be closed (calls: $(cat "$MOCK_DIR/bd_calls.log" 2>/dev/null))"
fi

# ── Test 25: Source issue still open — normal processing ───────────────────
echo "--- Test 25: Source issue still open — normal merge processing ---"
setup
add_rig_with_refinery "backend" "ba-"

refinery="$TEST_TMPDIR/gt/backend/refinery/rig"
cd "$refinery"
git checkout -b polecat/still-open >/dev/null 2>&1
echo "still open work" >> file.txt
git add file.txt
git commit -m "still open" >/dev/null 2>&1
git push origin polecat/still-open >/dev/null 2>&1
git checkout main >/dev/null 2>&1
cd /tmp

# bd mock: source issue is OPEN (not closed) — should proceed normally
cat > "$MOCK_DIR/bd" << MOCK
#!/bin/bash
if [[ "\${1:-}" == "list" ]]; then
  echo '[{"id":"ba-mr25","dependency_count":0}]'
elif [[ "\${1:-}" == "show" ]]; then
  if [[ "\${2:-}" == "ba-src25" ]]; then
    echo '{"id":"ba-src25","status":"open"}'
  else
    echo '{"id":"ba-mr25","description":"branch: polecat/still-open\ntarget: main\nsource_issue: ba-src25"}'
  fi
elif [[ "\${1:-}" == "close" ]]; then
  echo "CLOSED:\$*" >> "$MOCK_DIR/bd_calls.log"
  exit 0
else
  exit 0
fi
MOCK
chmod +x "$MOCK_DIR/bd"
> "$MOCK_DIR/bd_calls.log"

output=$(run_drain)

# Should NOT trigger the source-closed path
if echo "$output" | grep -q "source issue.*is closed"; then
  fail "Should NOT detect source as closed when it's open"
else
  pass "Does not falsely detect source as closed"
fi

# Should proceed with normal merge
if echo "$output" | grep -q "merged successfully"; then
  pass "Normal merge proceeds when source issue is open"
else
  fail "Should proceed with normal merge (got: $output)"
fi

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
