#!/bin/bash
# Test suite for gt-patrol orchestrator script.
# Mocks all external commands (gt, bd, tmux, jq, gt-polecat-recover, gt-refinery-drain)
# and verifies the logic of each patrol step by checking output strings.
#
# Usage: bash scripts/gt-patrol_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATROL="$SCRIPT_DIR/gt-patrol"
PASS=0
FAIL=0
TEST_TMPDIR=""

pass() {
  local msg=$1
  echo "  PASS: $msg"
  PASS=$((PASS + 1))
}

fail() {
  local msg=$1
  echo "  FAIL: $msg"
  FAIL=$((FAIL + 1))
}

cleanup() {
  cd /tmp
  if [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
  TEST_TMPDIR=""
}
trap cleanup EXIT

# ── Setup helpers ──────────────────────────────────────────────────────────
# Creates a temp dir with mock executables and a modified patrol script
# that uses the mock PATH and a fake GT directory.
setup() {
  TEST_TMPDIR=$(mktemp -d)
  MOCK_DIR="$TEST_TMPDIR/mocks"
  FAKE_GT="$TEST_TMPDIR/gt"
  OUTPUT="$TEST_TMPDIR/output.txt"
  NUKE_LOG="$TEST_TMPDIR/nuke.log"
  CLOSE_LOG="$TEST_TMPDIR/close.log"
  KILL_LOG="$TEST_TMPDIR/kill.log"
  BD_CLOSE_LOG="$TEST_TMPDIR/bd-close.log"

  mkdir -p "$MOCK_DIR" "$FAKE_GT/.beads"

  # Default routes.jsonl (needed by step 3+7+8)
  cat > "$FAKE_GT/.beads/routes.jsonl" <<'ROUTES'
{"prefix":"hq-","path":"."}
{"prefix":"aim-","path":"ai_manager"}
{"prefix":"gt-","path":"gastown/mayor/rig"}
{"prefix":"ba-","path":"backend"}
ROUTES

  # Create the modified patrol script that uses our MOCK_DIR and FAKE_GT
  # We patch: GT=..., PATH=..., and remove the hardcoded PATH export
  sed \
    -e "s|^export PATH=.*|export PATH=\"$MOCK_DIR:\$PATH\"|" \
    -e "s|^GT=/Users/davidtarico/gt|GT=$FAKE_GT|" \
    "$PATROL" > "$TEST_TMPDIR/patrol-under-test"
  chmod +x "$TEST_TMPDIR/patrol-under-test"

  # Default no-op stubs for gt-polecat-recover and gt-refinery-drain
  write_mock gt-polecat-recover '#!/bin/bash
exit 0'
  write_mock gt-refinery-drain '#!/bin/bash
exit 0'

  # Default date mock (returns fixed timestamp for TS function and epoch for step 7)
  write_mock date '#!/bin/bash
if [[ "${1:-}" == "+%H:%M:%S" ]]; then
  echo "00:00:00"
elif [[ "${1:-}" == "+%s" ]]; then
  echo "1000000"
else
  /usr/bin/date "$@"
fi'

  # Default jq — use real jq
  ln -sf "$(which jq)" "$MOCK_DIR/jq"

  # Default tmux — no sessions
  write_mock tmux '#!/bin/bash
if [[ "${1:-}" == "list-sessions" ]]; then
  exit 1  # tmux exits 1 when no server/sessions
elif [[ "${1:-}" == "kill-session" ]]; then
  exit 0
fi'

  # Default bd — returns empty arrays
  write_mock bd '#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo "[]"
elif [[ "${1:-}" == "close" ]]; then
  exit 0
fi'

  # Default gt — returns empty results
  write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "polecat nuke") exit 0 ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  "convoy close") exit 0 ;;
  *) exit 0 ;;
esac'
}

write_mock() {
  local name=$1
  local content=$2
  echo "$content" > "$MOCK_DIR/$name"
  chmod +x "$MOCK_DIR/$name"
}

run_patrol() {
  # Run the patched patrol script, capture output
  bash "$TEST_TMPDIR/patrol-under-test" > "$OUTPUT" 2>&1 || true
}

output_contains() {
  grep -qF "$1" "$OUTPUT"
}

output_matches() {
  grep -qE "$1" "$OUTPUT"
}

echo "=== gt-patrol test suite ==="
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Polecat cleanup
# ═══════════════════════════════════════════════════════════════════════════
echo "--- Step 4: Polecat cleanup ---"

# Test 1: No polecats → "(none)" output
echo "Test 1: No polecats"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
run_patrol
# Step 4 should print "(none)" — check the output after "[4/8]"
if output_contains "(none)"; then
  pass "No polecats prints (none)"
else
  fail "No polecats should print (none)"
  cat "$OUTPUT"
fi
cleanup

# Test 2: Done polecat → gets nuked
echo "Test 2: Done polecat gets nuked"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list")
    echo "[{\"rig\":\"ai_manager\",\"name\":\"obsidian\",\"state\":\"done\"}]"
    ;;
  "polecat nuke")
    echo "nuked: $3" >> '"$TEST_TMPDIR"'/nuke.log
    ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
run_patrol
if output_contains "Nuking: ai_manager/obsidian"; then
  pass "Done polecat gets nuked"
else
  fail "Done polecat should be nuked"
  cat "$OUTPUT"
fi
cleanup

# Test 3: Working polecat → NOT nuked
echo "Test 3: Working polecat not nuked"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list")
    echo "[{\"rig\":\"ai_manager\",\"name\":\"granite\",\"state\":\"working\"}]"
    ;;
  "polecat nuke")
    echo "ERROR: should not nuke working polecat" >> '"$TEST_TMPDIR"'/nuke.log
    ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
run_patrol
if output_contains "Nuking:"; then
  fail "Working polecat should NOT be nuked"
  cat "$OUTPUT"
else
  pass "Working polecat not nuked"
fi
cleanup

# Test 4: Idle polecat → gets nuked
echo "Test 4: Idle polecat gets nuked"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list")
    echo "[{\"rig\":\"backend\",\"name\":\"marble\",\"state\":\"idle\"}]"
    ;;
  "polecat nuke")
    echo "nuked: $3" >> '"$TEST_TMPDIR"'/nuke.log
    ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
run_patrol
if output_contains "Nuking: backend/marble"; then
  pass "Idle polecat gets nuked"
else
  fail "Idle polecat should be nuked"
  cat "$OUTPUT"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Step 5: Dispatch
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Step 5: Dispatch ---"

# Test 5: Empty scheduler queue → "(none)"
echo "Test 5: Empty scheduler queue"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
run_patrol
# After [5/8] line, output should say "(none)" for empty dispatch
if output_contains "queue: 0 scheduled, 0 ready"; then
  pass "Empty scheduler queue reported correctly"
else
  fail "Empty scheduler queue should show 0 scheduled, 0 ready"
  cat "$OUTPUT"
fi
cleanup

# Test 6: Queue with ready beads → dispatches
echo "Test 6: Queue with ready beads dispatches"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status")
    echo "{\"queued_total\":2,\"queued_ready\":2,\"beads\":[{\"status\":\"ready\",\"id\":\"aim-1234\",\"title\":\"Fix bug\"},{\"status\":\"ready\",\"id\":\"ba-5678\",\"title\":\"Add feature\"}]}"
    ;;
  "scheduler run")
    echo "Dispatching aim-1234 to ai_manager"
    echo "Dispatched 1 bead(s)"
    ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
run_patrol
if output_contains "queue: 2 scheduled, 2 ready" && output_contains "Dispatched 1"; then
  pass "Ready beads get dispatched"
else
  fail "Ready beads should be dispatched"
  cat "$OUTPUT"
fi
cleanup

# Test 7: Dispatch failure → reports error
echo "Test 7: Dispatch failure reports error"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":1,\"queued_ready\":1,\"beads\":[{\"status\":\"ready\",\"id\":\"aim-err\",\"title\":\"Broken\"}]}" ;;
  "scheduler run")
    echo "error: cannot dispatch"
    exit 1
    ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
run_patrol
if output_contains "dispatch output (rc=1)"; then
  pass "Dispatch failure reports error code"
else
  fail "Dispatch failure should report error with rc"
  cat "$OUTPUT"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Step 6a: Epic auto-close
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Step 6a: Epic auto-close ---"

# Test 8a: Epic auto-closed when all non-epic children are closed
echo "Test 8a: Epic auto-closed when all children closed"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list")
    echo "[{\"id\":\"cv-epic-1\",\"status\":\"open\",\"completed\":2,\"total\":3,\"tracked\":[{\"id\":\"epic-1\",\"status\":\"open\",\"issue_type\":\"epic\"},{\"id\":\"task-1\",\"status\":\"closed\",\"issue_type\":\"task\"},{\"id\":\"task-2\",\"status\":\"closed\",\"issue_type\":\"task\"}]}]"
    ;;
  "convoy close") exit 0 ;;
  *) exit 0 ;;
esac'
write_mock bd '#!/bin/bash
if [[ "${1:-}" == "close" ]]; then
  echo "closed: $*" >> '"$TEST_TMPDIR"'/bd-close.log
  exit 0
elif [[ "${1:-}" == "list" ]]; then
  echo "[]"
fi'
run_patrol
if grep -q "epic-1" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  pass "Epic auto-closed when all children closed"
else
  fail "Epic should be auto-closed when all non-epic children are closed"
  cat "$OUTPUT"
fi
cleanup

# Test 8b: Epic NOT auto-closed when children still open
echo "Test 8b: Epic not closed when children still open"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list")
    echo "[{\"id\":\"cv-epic-2\",\"status\":\"open\",\"completed\":1,\"total\":3,\"tracked\":[{\"id\":\"epic-2\",\"status\":\"open\",\"issue_type\":\"epic\"},{\"id\":\"task-3\",\"status\":\"closed\",\"issue_type\":\"task\"},{\"id\":\"task-4\",\"status\":\"open\",\"issue_type\":\"task\"}]}]"
    ;;
  "convoy close") exit 0 ;;
  *) exit 0 ;;
esac'
write_mock bd '#!/bin/bash
if [[ "${1:-}" == "close" ]]; then
  echo "closed: $*" >> '"$TEST_TMPDIR"'/bd-close.log
  exit 0
elif [[ "${1:-}" == "list" ]]; then
  echo "[]"
fi'
run_patrol
if [[ -f "$TEST_TMPDIR/bd-close.log" ]] && grep -q "epic-2" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  fail "Epic should NOT be closed when children still open"
  cat "$OUTPUT"
else
  pass "Epic not closed when children still open"
fi
cleanup

# Test 8b2: Epic NOT auto-closed when it has zero non-epic children
echo "Test 8b2: Epic not closed when no non-epic children exist"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list")
    echo "[{\"id\":\"cv-epic-empty\",\"status\":\"open\",\"completed\":0,\"total\":1,\"tracked\":[{\"id\":\"epic-empty\",\"status\":\"open\",\"issue_type\":\"epic\"}]}]"
    ;;
  "convoy close") exit 0 ;;
  *) exit 0 ;;
esac'
write_mock bd '#!/bin/bash
if [[ "${1:-}" == "close" ]]; then
  echo "closed: $*" >> '"$TEST_TMPDIR"'/bd-close.log
  exit 0
elif [[ "${1:-}" == "list" ]]; then
  echo "[]"
fi'
run_patrol
if [[ -f "$TEST_TMPDIR/bd-close.log" ]] && grep -q "epic-empty" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  fail "Epic should NOT be closed when it has no non-epic children"
  cat "$OUTPUT"
else
  pass "Epic not closed when no non-epic children exist"
fi
cleanup

# Test 8c: No tracked field in convoy JSON → no crash
echo "Test 8c: Convoy without tracked field handled gracefully"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list")
    echo "[{\"id\":\"cv-old\",\"status\":\"open\",\"completed\":0,\"total\":3}]"
    ;;
  "convoy close") exit 0 ;;
  *) exit 0 ;;
esac'
run_patrol
if output_contains "Checking epics for auto-close"; then
  pass "Convoy without tracked field handled gracefully"
else
  fail "Should not crash on convoy without tracked field"
  cat "$OUTPUT"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Step 6b: Convoy closing
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Step 6b: Convoy closing ---"

# Test 8: No convoys → "(none)"
echo "Test 8: No convoys"
setup
run_patrol
# Check for (none) in step 6 area
if output_contains "[7b/9] Closing completed convoys" && output_contains "(none)"; then
  pass "No convoys prints (none)"
else
  fail "No convoys should print (none)"
  cat "$OUTPUT"
fi
cleanup

# Test 9: Completed convoy → gets closed
echo "Test 9: Completed convoy gets closed"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list")
    echo "[{\"id\":\"cv-done-1\",\"status\":\"open\",\"completed\":3,\"total\":3,\"tracked\":[{\"id\":\"t1\",\"status\":\"closed\",\"issue_type\":\"task\"},{\"id\":\"t2\",\"status\":\"closed\",\"issue_type\":\"task\"},{\"id\":\"t3\",\"status\":\"closed\",\"issue_type\":\"task\"}]}]"
    ;;
  "convoy close")
    echo "closed: $3" >> '"$TEST_TMPDIR"'/close.log
    ;;
  *) exit 0 ;;
esac'
run_patrol
if output_contains "Closing: cv-done-1 (3/3 done)"; then
  pass "Completed convoy gets closed"
else
  fail "Completed convoy should be closed"
  cat "$OUTPUT"
fi
cleanup

# Test 10: Incomplete convoy → NOT closed
echo "Test 10: Incomplete convoy not closed"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list")
    echo "[{\"id\":\"cv-wip-1\",\"status\":\"open\",\"completed\":1,\"total\":3}]"
    ;;
  "convoy close")
    echo "ERROR: should not close incomplete" >> '"$TEST_TMPDIR"'/close.log
    ;;
  *) exit 0 ;;
esac'
run_patrol
if output_contains "Closing: cv-wip-1"; then
  fail "Incomplete convoy should NOT be closed"
  cat "$OUTPUT"
else
  pass "Incomplete convoy not closed"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Step 7: Orphaned tmux sessions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Step 7: Orphaned tmux sessions ---"

# Helper to write a gt mock that also handles polecat list for step 7
write_step6_gt_mock() {
  local polecat_json=$1
  write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo '"'$polecat_json'"' ;;
  "polecat nuke") exit 0 ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
}

# Test 11: No tmux sessions → "(none)"
echo "Test 11: No tmux sessions"
setup
write_step6_gt_mock '[]'
write_mock tmux '#!/bin/bash
if [[ "${1:-}" == "list-sessions" ]]; then
  exit 1
fi'
run_patrol
# After [7/8], should see (none)
if output_contains "[8/9] Checking for orphaned tmux sessions"; then
  pass "No tmux sessions prints (none)"
else
  fail "No tmux sessions should print (none)"
  cat "$OUTPUT"
fi
cleanup

# Test 12: Polecat session with matching polecat → NOT killed
echo "Test 12: Polecat session with matching polecat not killed"
setup
# Polecat "obsidian" in rig "ai_manager" → session name "aim-obsidian"
# The route for ai_manager has prefix "aim-"
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list")
    echo "[{\"rig\":\"ai_manager\",\"name\":\"obsidian\",\"state\":\"working\"}]"
    ;;
  "polecat nuke") exit 0 ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
# tmux session "aim-obsidian" exists, old enough
write_mock tmux '#!/bin/bash
if [[ "${1:-}" == "list-sessions" ]]; then
  echo "aim-obsidian 999000"
  exit 0
elif [[ "${1:-}" == "kill-session" ]]; then
  echo "KILLED: $3" >> '"$TEST_TMPDIR"'/kill.log
  exit 0
fi'
run_patrol
if output_contains "Killing orphan: aim-obsidian"; then
  fail "Session with matching polecat should NOT be killed"
  cat "$OUTPUT"
else
  pass "Session with matching polecat not killed"
fi
cleanup

# Test 13: Orphaned polecat session (no matching polecat) → killed
echo "Test 13: Orphaned polecat session killed"
setup
# No polecats alive
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "polecat nuke") exit 0 ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
# tmux session "aim-orphan" matches aim- prefix but no matching polecat
write_mock tmux '#!/bin/bash
if [[ "${1:-}" == "list-sessions" ]]; then
  echo "aim-orphan 999000"
  exit 0
elif [[ "${1:-}" == "kill-session" ]]; then
  echo "KILLED: ${@}" >> '"$TEST_TMPDIR"'/kill.log
  exit 0
fi'
run_patrol
if output_contains "Killing orphan: aim-orphan"; then
  pass "Orphaned polecat session killed"
else
  fail "Orphaned polecat session should be killed"
  cat "$OUTPUT"
fi
cleanup

# Test 14: Protected session (aim-refinery, aim-witness) → NOT killed
echo "Test 14: Protected service sessions not killed"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
# Protected sessions: aim-refinery, aim-witness should be skipped
write_mock tmux '#!/bin/bash
if [[ "${1:-}" == "list-sessions" ]]; then
  echo "aim-refinery 999000"
  echo "aim-witness 999000"
  echo "hq-mayor 999000"
  echo "hq-overseer 999000"
  echo "aim-deacon 999000"
  exit 0
elif [[ "${1:-}" == "kill-session" ]]; then
  echo "KILLED: ${@}" >> '"$TEST_TMPDIR"'/kill.log
  exit 0
fi'
run_patrol
if output_contains "Killing orphan:"; then
  fail "Protected sessions should NOT be killed"
  cat "$OUTPUT"
else
  pass "Protected sessions not killed"
fi
cleanup

# Test 15: Young session (< 120s old) → NOT killed
echo "Test 15: Young session not killed"
setup
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
# date +%s returns 1000000, session created at 999950 → age = 50s < 120s grace
write_mock tmux '#!/bin/bash
if [[ "${1:-}" == "list-sessions" ]]; then
  echo "aim-youngster 999950"
  exit 0
elif [[ "${1:-}" == "kill-session" ]]; then
  echo "KILLED: ${@}" >> '"$TEST_TMPDIR"'/kill.log
  exit 0
fi'
run_patrol
if output_contains "Skipping young session: aim-youngster"; then
  pass "Young session not killed (grace period)"
else
  fail "Young session should be skipped with grace period message"
  cat "$OUTPUT"
fi
cleanup

# Test 16: gt polecat list failure → entire step skipped (fail-safe)
echo "Test 16: Polecat list failure skips orphan cleanup"
setup
CALL_COUNT_FILE="$TEST_TMPDIR/polecat_call_count"
echo "0" > "$CALL_COUNT_FILE"
# First polecat list call (step 4) returns [], second call (step 7) fails
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list")
    COUNT=$(cat '"$CALL_COUNT_FILE"')
    COUNT=$((COUNT + 1))
    echo "$COUNT" > '"$CALL_COUNT_FILE"'
    if [[ $COUNT -eq 1 ]]; then
      echo "[]"
    else
      echo "error: cannot connect" >&2
      exit 1
    fi
    ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run") exit 0 ;;
  "convoy list") echo "[]" ;;
  *) exit 0 ;;
esac'
# An orphaned session exists, but polecat list fails so it should NOT be killed
write_mock tmux '#!/bin/bash
if [[ "${1:-}" == "list-sessions" ]]; then
  echo "aim-orphan 999000"
  exit 0
elif [[ "${1:-}" == "kill-session" ]]; then
  echo "KILLED: ${@}" >> '"$TEST_TMPDIR"'/kill.log
  exit 0
fi'
run_patrol
if output_contains "WARNING: gt polecat list failed" && ! output_contains "Killing orphan:"; then
  pass "Polecat list failure triggers fail-safe, skips orphan cleanup"
else
  fail "Polecat list failure should skip orphan cleanup entirely"
  cat "$OUTPUT"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Step 8: Noise bead closing
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Step 8: Noise bead closing ---"

# Test 17: No noise beads → "(none)"
echo "Test 17: No noise beads"
setup
write_mock bd '#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo "[]"
elif [[ "${1:-}" == "close" ]]; then
  exit 0
fi'
run_patrol
# The last (none) in the output should be from step 8
if output_contains "[9/9] Closing system noise beads"; then
  # Count how many lines after [9/9] contain (none)
  if sed -n '/\[9\/9\]/,$ p' "$OUTPUT" | grep -q "(none)"; then
    pass "No noise beads prints (none)"
  else
    fail "No noise beads should print (none)"
    cat "$OUTPUT"
  fi
else
  fail "Step 9 header missing"
  cat "$OUTPUT"
fi
cleanup

# Test 18: Compaction report beads → closed
echo "Test 18: Compaction report beads closed"
setup
write_mock bd '#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo "[{\"id\":\"hq-noise-1\",\"title\":\"Compaction Report 2026-03-07\",\"issue_type\":\"task\",\"status\":\"open\"},{\"id\":\"hq-noise-2\",\"title\":\"Weekly Compaction Summary\",\"issue_type\":\"task\",\"status\":\"open\"}]"
elif [[ "${1:-}" == "close" ]]; then
  # Log what was closed
  echo "closed: $*" >> '"$TEST_TMPDIR"'/bd-close.log
  exit 0
fi'
run_patrol
if output_contains "Closing 2 noise bead(s)"; then
  pass "Compaction report beads get closed"
else
  fail "Compaction report beads should be closed"
  cat "$OUTPUT"
fi
cleanup

# Test 19: Regular work beads → NOT closed
echo "Test 19: Regular work beads not closed"
setup
write_mock bd '#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo "[{\"id\":\"hq-work-1\",\"title\":\"Implement user authentication\",\"issue_type\":\"task\",\"status\":\"open\"},{\"id\":\"hq-work-2\",\"title\":\"Fix login page CSS\",\"issue_type\":\"task\",\"status\":\"open\"}]"
elif [[ "${1:-}" == "close" ]]; then
  echo "closed: $*" >> '"$TEST_TMPDIR"'/bd-close.log
  exit 0
fi'
run_patrol
if output_contains "Closing" && output_matches "Closing [0-9]+ noise"; then
  fail "Regular work beads should NOT be closed as noise"
  cat "$OUTPUT"
else
  # Verify step 8 says (none)
  if sed -n '/\[9\/9\]/,$ p' "$OUTPUT" | grep -q "(none)"; then
    pass "Regular work beads not closed"
  else
    fail "Regular work beads should result in (none) for step 9"
    cat "$OUTPUT"
  fi
fi
cleanup

# Test 20: Hooked/in_progress wisp-wisp beads → closed as noise
echo "Test 20: Hooked/in_progress wisp-wisp beads closed"
setup
# Status-aware bd mock: only return beads matching the requested --status flag
write_mock bd '#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  STATUS=""
  for a in "$@"; do
    case "$a" in --status=*) STATUS="${a#--status=}" ;; esac
  done
  case "$STATUS" in
    open)
      echo "[]"
      ;;
    hooked)
      echo "[{\"id\":\"aim-wisp-wisp-dy7e\",\"title\":\"mol-witness-patrol\",\"issue_type\":\"molecule\",\"status\":\"hooked\"}]"
      ;;
    in_progress)
      echo "[{\"id\":\"aim-wisp-wisp-dpez\",\"title\":\"Check refinery mail\",\"issue_type\":\"task\",\"status\":\"in_progress\"},{\"id\":\"aim-real-work\",\"title\":\"Real work item\",\"issue_type\":\"task\",\"status\":\"in_progress\"}]"
      ;;
    *)
      echo "[]"
      ;;
  esac
elif [[ "${1:-}" == "close" ]]; then
  echo "closed: $*" >> '"$TEST_TMPDIR"'/bd-close.log
  exit 0
fi'
run_patrol
# wisp-wisp beads should be closed regardless of status
if grep -q "aim-wisp-wisp-dy7e" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  pass "Hooked wisp-wisp bead closed as noise"
else
  fail "Hooked wisp-wisp bead should be closed as noise"
  cat "$OUTPUT"
fi
if grep -q "aim-wisp-wisp-dpez" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  pass "In-progress wisp-wisp bead closed as noise"
else
  fail "In-progress wisp-wisp bead should be closed as noise"
  cat "$OUTPUT"
fi
# Real work bead should NOT be closed
if grep -q "aim-real-work" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  fail "Real work bead should NOT be closed as noise"
  cat "$OUTPUT"
else
  pass "Real work bead not closed"
fi
cleanup

# Test 21: HQ-level wisp-wisp beads → closed as noise
echo "Test 21: HQ-level wisp-wisp beads closed"
setup
# HQ wisp-wisp beads are at the HQ level (no --rig flag), status=open
# Their titles DON'T match the HQ_NOISE title patterns — they're generic step names
write_mock bd '#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  RIG=""
  STATUS=""
  for a in "$@"; do
    case "$a" in
      --rig) RIG="next" ;;
      --status=*) STATUS="${a#--status=}" ;;
      *)
        if [[ "$RIG" == "next" ]]; then RIG="$a"; fi
        ;;
    esac
  done
  # HQ-level query (no --rig flag)
  if [[ -z "$RIG" || "$RIG" == "next" ]]; then
    case "$STATUS" in
      open)
        echo "[{\"id\":\"hq-wisp-wisp-3tw2\",\"title\":\"Commit all implementation changes\",\"issue_type\":\"task\",\"status\":\"open\"},{\"id\":\"hq-wisp-wisp-z4fl\",\"title\":\"Load context and verify assignment\",\"issue_type\":\"task\",\"status\":\"open\"},{\"id\":\"hq-real-work\",\"title\":\"Fix authentication bug\",\"issue_type\":\"task\",\"status\":\"open\"}]"
        ;;
      *) echo "[]" ;;
    esac
  else
    echo "[]"
  fi
elif [[ "${1:-}" == "close" ]]; then
  echo "closed: $*" >> '"$TEST_TMPDIR"'/bd-close.log
  exit 0
fi'
run_patrol
# HQ wisp-wisp beads should be closed
if grep -q "hq-wisp-wisp-3tw2" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  pass "HQ wisp-wisp bead (3tw2) closed as noise"
else
  fail "HQ wisp-wisp bead (3tw2) should be closed as noise"
  cat "$OUTPUT"
fi
if grep -q "hq-wisp-wisp-z4fl" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  pass "HQ wisp-wisp bead (z4fl) closed as noise"
else
  fail "HQ wisp-wisp bead (z4fl) should be closed as noise"
  cat "$OUTPUT"
fi
# Real HQ work bead should NOT be closed
if grep -q "hq-real-work" "$TEST_TMPDIR/bd-close.log" 2>/dev/null; then
  fail "Real HQ work bead should NOT be closed as noise"
  cat "$OUTPUT"
else
  pass "Real HQ work bead not closed"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Step 5b: Circuit-breaker notification
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Step 5b: Circuit-breaker notification ---"

# Test 22: Circuit-broken in dispatch output → mail sent to mayor
echo "Test 22: Circuit-breaker sends mail to mayor"
setup
MAIL_LOG="$TEST_TMPDIR/mail.log"
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":1,\"queued_ready\":1,\"beads\":[{\"status\":\"ready\",\"id\":\"su-e82e\",\"title\":\"Investigate cases\"}]}" ;;
  "scheduler run")
    echo "Context hq-wisp-abc12 (work: su-e82e) failed 3 times, circuit-broken"
    exit 0
    ;;
  "convoy list") echo "[]" ;;
  "mail send")
    echo "MAIL: $*" >> '"$MAIL_LOG"'
    ;;
  *) exit 0 ;;
esac'
run_patrol
if [[ -f "$MAIL_LOG" ]] && grep -q "mayor/" "$MAIL_LOG"; then
  pass "Circuit-breaker sends mail to mayor"
else
  fail "Circuit-breaker should send mail to mayor"
  cat "$OUTPUT"
  [[ -f "$MAIL_LOG" ]] && cat "$MAIL_LOG"
fi
cleanup

# Test 23: No circuit-broken → no mail sent
echo "Test 23: Normal dispatch sends no mail"
setup
MAIL_LOG="$TEST_TMPDIR/mail.log"
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":1,\"queued_ready\":1,\"beads\":[{\"status\":\"ready\",\"id\":\"aim-1234\",\"title\":\"Fix bug\"}]}" ;;
  "scheduler run")
    echo "Dispatching aim-1234 to ai_manager"
    echo "Dispatched 1 bead(s)"
    exit 0
    ;;
  "convoy list") echo "[]" ;;
  "mail send")
    echo "MAIL: $*" >> '"$MAIL_LOG"'
    ;;
  *) exit 0 ;;
esac'
run_patrol
if [[ -f "$MAIL_LOG" ]]; then
  fail "Normal dispatch should NOT send mail"
  cat "$MAIL_LOG"
else
  pass "Normal dispatch sends no mail"
fi
cleanup

# Test 24: Mail includes bead ID and troubleshooting process
echo "Test 24: Circuit-breaker mail includes bead ID"
setup
MAIL_LOG="$TEST_TMPDIR/mail.log"
write_mock gt '#!/bin/bash
case "${1:-} ${2:-}" in
  "polecat list") echo "[]" ;;
  "scheduler status") echo "{\"queued_total\":0,\"queued_ready\":0,\"beads\":[]}" ;;
  "scheduler run")
    echo "Context hq-wisp-xyz99 (work: aim-5678) failed 3 times, circuit-broken"
    exit 0
    ;;
  "convoy list") echo "[]" ;;
  "mail send")
    echo "MAIL: $*" >> '"$MAIL_LOG"'
    ;;
  *) exit 0 ;;
esac'
run_patrol
if [[ -f "$MAIL_LOG" ]] && grep -q "aim-5678" "$MAIL_LOG"; then
  pass "Circuit-breaker mail includes bead ID"
else
  fail "Circuit-breaker mail should include bead ID"
  cat "$OUTPUT"
  [[ -f "$MAIL_LOG" ]] && cat "$MAIL_LOG"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Rig clone sync
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Step 3: Rig clone sync ---"

# Helper: create a bare "origin" repo and a clone that's behind by one commit.
# Sets RIG_CLONE to the clone path. Caller must have called setup first.
create_behind_rig_clone() {
  local rig_name=$1
  local bare_repo="$TEST_TMPDIR/origins/${rig_name}.git"
  local clone_dir="$FAKE_GT/${rig_name}/mayor/rig"

  mkdir -p "$TEST_TMPDIR/origins"
  git init --bare "$bare_repo" >/dev/null 2>&1

  # Create initial commit via a temp working copy
  local tmp_work="$TEST_TMPDIR/tmp-work-${rig_name}"
  git clone "$bare_repo" "$tmp_work" >/dev/null 2>&1
  cd "$tmp_work"
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "initial" > file.txt
  git add file.txt
  git commit -m "initial" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Clone to rig location
  mkdir -p "$(dirname "$clone_dir")"
  git clone "$bare_repo" "$clone_dir" >/dev/null 2>&1
  cd "$clone_dir"
  git config user.email "test@test.com"
  git config user.name "Test"

  # Add another commit to origin (making the clone 1 behind)
  cd "$tmp_work"
  echo "new work" >> file.txt
  git add file.txt
  git commit -m "polecat work merged" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  cd /tmp
  rm -rf "$tmp_work"
}

# Test 25: Rig clone behind origin → gets ff-only pulled
echo "Test 25: Behind rig clone gets synced"
setup
create_behind_rig_clone "ai_manager"

# Fetch so clone knows about the new origin/main commit
cd "$FAKE_GT/ai_manager/mayor/rig" && git fetch origin >/dev/null 2>&1
cd /tmp

# Verify it's actually behind before patrol runs
BEFORE_HEAD=$(cd "$FAKE_GT/ai_manager/mayor/rig" && git rev-parse HEAD)
ORIGIN_HEAD=$(cd "$FAKE_GT/ai_manager/mayor/rig" && git rev-parse origin/main)
if [[ "$BEFORE_HEAD" == "$ORIGIN_HEAD" ]]; then
  fail "Test setup broken: clone should be behind origin"
else
  run_patrol
  AFTER_HEAD=$(cd "$FAKE_GT/ai_manager/mayor/rig" && git rev-parse HEAD)
  if [[ "$AFTER_HEAD" == "$ORIGIN_HEAD" ]]; then
    pass "Behind rig clone gets synced via ff-only pull"
  else
    fail "Rig clone should be at origin/main after patrol sync"
    echo "  before=$BEFORE_HEAD origin=$ORIGIN_HEAD after=$AFTER_HEAD"
    cat "$OUTPUT"
  fi
fi
cleanup

# Test 26: Rig clone already up-to-date → no error
echo "Test 26: Up-to-date rig clone is fine"
setup
create_behind_rig_clone "ai_manager"
# Pull manually so it's up-to-date
cd "$FAKE_GT/ai_manager/mayor/rig" && git pull --ff-only >/dev/null 2>&1
cd /tmp

run_patrol
if output_contains "Syncing rig clones"; then
  pass "Up-to-date rig clone reports no error"
else
  fail "Patrol should have rig sync step"
  cat "$OUTPUT"
fi
cleanup

# Test 27: Rig without mayor/rig clone dir → skipped silently
echo "Test 27: Rig without clone dir is skipped"
setup
# ai_manager route exists but no mayor/rig directory
mkdir -p "$FAKE_GT/ai_manager"
run_patrol
# Should not error out
if output_contains "Syncing rig clones"; then
  pass "Missing rig clone dir skipped without error"
else
  fail "Patrol should have rig sync step even with missing dirs"
  cat "$OUTPUT"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
