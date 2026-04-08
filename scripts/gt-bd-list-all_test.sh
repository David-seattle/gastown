#!/bin/bash
# Test suite for gt-bd-list-all — unified bd list across all rigs.
#
# Usage: bash scripts/gt-bd-list-all_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/gt-bd-list-all"
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

setup() {
  cleanup
  TEST_TMPDIR=$(mktemp -d)
  MOCK_DIR="$TEST_TMPDIR/mocks"
  FAKE_GT="$TEST_TMPDIR/gt"
  mkdir -p "$MOCK_DIR" "$FAKE_GT/.beads"

  # Default routes
  cat > "$FAKE_GT/.beads/routes.jsonl" <<'ROUTES'
{"prefix":"hq-","path":"."}
{"prefix":"aim-","path":"ai_manager"}
{"prefix":"su-","path":"suplagents"}
ROUTES

  # Real jq
  ln -sf "$(which jq)" "$MOCK_DIR/jq"
}

write_mock() {
  local name=$1
  local content=$2
  echo "$content" > "$MOCK_DIR/$name"
  chmod +x "$MOCK_DIR/$name"
}

run_script() {
  PATH="$MOCK_DIR:$PATH" GT="$FAKE_GT" bash "$SCRIPT" "$@" 2>/dev/null || true
}

echo "=== gt-bd-list-all test suite ==="
echo ""

# --- Test 1: No beads anywhere → empty array ---
echo "Test 1: No beads anywhere"
setup
write_mock bd '#!/bin/bash
echo "[]"'
OUTPUT=$(run_script --status=open --json --limit=0)
if [[ "$OUTPUT" == "[]" ]]; then
  pass "Empty results return []"
else
  fail "Empty results should return []"
  echo "  got: $OUTPUT"
fi

# --- Test 2: HQ beads only → returns HQ beads ---
echo "Test 2: HQ beads only"
setup
write_mock bd '#!/bin/bash
RIG=""
for a in "$@"; do
  case "$a" in --rig) RIG="next" ;; *) [[ "$RIG" == "next" ]] && RIG="$a" ;; esac
done
if [[ -z "$RIG" || "$RIG" == "next" ]]; then
  echo "[{\"id\":\"hq-1234\",\"title\":\"HQ bead\"}]"
else
  echo "[]"
fi'
OUTPUT=$(run_script --status=open --json --limit=0)
COUNT=$(echo "$OUTPUT" | jq length)
if [[ "$COUNT" -eq 1 ]] && echo "$OUTPUT" | jq -e '.[0].id == "hq-1234"' >/dev/null; then
  pass "HQ-only beads returned"
else
  fail "Should return 1 HQ bead"
  echo "  got: $OUTPUT"
fi

# --- Test 3: Per-rig beads only → returns rig beads ---
echo "Test 3: Per-rig beads only"
setup
write_mock bd '#!/bin/bash
RIG=""
for a in "$@"; do
  case "$a" in --rig) RIG="next" ;; *) [[ "$RIG" == "next" ]] && RIG="$a" ;; esac
done
case "$RIG" in
  ai_manager) echo "[{\"id\":\"aim-5678\",\"title\":\"AI bead\"}]" ;;
  suplagents) echo "[{\"id\":\"su-abcd\",\"title\":\"SU bead\"}]" ;;
  *) echo "[]" ;;
esac'
OUTPUT=$(run_script --status=open --json --limit=0)
COUNT=$(echo "$OUTPUT" | jq length)
if [[ "$COUNT" -eq 2 ]]; then
  pass "Per-rig beads from both rigs returned"
else
  fail "Should return 2 per-rig beads"
  echo "  got: $OUTPUT"
fi

# --- Test 4: Mixed HQ + rig beads → merged ---
echo "Test 4: Mixed HQ + rig beads merged"
setup
write_mock bd '#!/bin/bash
RIG=""
for a in "$@"; do
  case "$a" in --rig) RIG="next" ;; *) [[ "$RIG" == "next" ]] && RIG="$a" ;; esac
done
case "$RIG" in
  ai_manager) echo "[{\"id\":\"aim-1\",\"title\":\"AI\"}]" ;;
  suplagents) echo "[{\"id\":\"su-1\",\"title\":\"SU\"},{\"id\":\"su-2\",\"title\":\"SU2\"}]" ;;
  *) echo "[{\"id\":\"hq-1\",\"title\":\"HQ\"}]" ;;
esac'
OUTPUT=$(run_script --status=open --json --limit=0)
COUNT=$(echo "$OUTPUT" | jq length)
if [[ "$COUNT" -eq 4 ]]; then
  pass "All 4 beads merged from HQ + 2 rigs"
else
  fail "Should return 4 merged beads"
  echo "  got: $OUTPUT"
fi
# Verify all IDs present
for id in hq-1 aim-1 su-1 su-2; do
  if echo "$OUTPUT" | jq -e ".[] | select(.id == \"$id\")" >/dev/null; then
    pass "Bead $id present in merged output"
  else
    fail "Bead $id should be in merged output"
  fi
done

# --- Test 5: Passes through all flags to bd list ---
echo "Test 5: Flags passed through to bd"
setup
BD_LOG="$TEST_TMPDIR/bd.log"
write_mock bd '#!/bin/bash
echo "$@" >> '"$BD_LOG"'
echo "[]"'
run_script --status=hooked --json --limit=0 --label-any gt:merge-request
# Should see the flags in every bd call (HQ + 2 rigs = 3 calls)
CALL_COUNT=$(wc -l < "$BD_LOG" | tr -d ' ')
if [[ "$CALL_COUNT" -eq 3 ]]; then
  pass "bd called 3 times (HQ + 2 rigs)"
else
  fail "bd should be called 3 times (HQ + 2 rigs), got $CALL_COUNT"
  cat "$BD_LOG"
fi
# Check that flags are present in each call
if grep -q -- "--status=hooked" "$BD_LOG" && grep -q -- "--label-any" "$BD_LOG"; then
  pass "Flags passed through to bd"
else
  fail "Flags should be passed through to bd"
  cat "$BD_LOG"
fi
# Check rig flags
if grep -q -- "--rig ai_manager" "$BD_LOG" && grep -q -- "--rig suplagents" "$BD_LOG"; then
  pass "Per-rig --rig flags added"
else
  fail "--rig flags should be added for each rig"
  cat "$BD_LOG"
fi

# --- Test 6: Multiple --status flags → multiple queries per rig ---
echo "Test 6: Multiple --status flags"
setup
BD_LOG="$TEST_TMPDIR/bd.log"
write_mock bd '#!/bin/bash
echo "$@" >> '"$BD_LOG"'
STATUS=""
for a in "$@"; do
  case "$a" in --status=*) STATUS="${a#--status=}" ;; esac
done
RIG=""
for a in "$@"; do
  case "$a" in --rig) RIG="next" ;; *) [[ "$RIG" == "next" ]] && RIG="$a" ;; esac
done
if [[ "$RIG" == "ai_manager" && "$STATUS" == "hooked" ]]; then
  echo "[{\"id\":\"aim-hooked\",\"title\":\"Hooked\",\"status\":\"hooked\"}]"
elif [[ "$RIG" == "suplagents" && "$STATUS" == "in_progress" ]]; then
  echo "[{\"id\":\"su-wip\",\"title\":\"WIP\",\"status\":\"in_progress\"}]"
else
  echo "[]"
fi'
OUTPUT=$(run_script --status=hooked --status=in_progress --json --limit=0)
COUNT=$(echo "$OUTPUT" | jq length)
if [[ "$COUNT" -eq 2 ]]; then
  pass "Multiple statuses queried and merged"
else
  fail "Should return 2 beads from different statuses"
  echo "  got: $OUTPUT"
fi
# Should be 6 calls: 2 statuses × 3 targets (HQ + 2 rigs)
CALL_COUNT=$(wc -l < "$BD_LOG" | tr -d ' ')
if [[ "$CALL_COUNT" -eq 6 ]]; then
  pass "bd called 6 times (2 statuses × 3 targets)"
else
  fail "bd should be called 6 times, got $CALL_COUNT"
  cat "$BD_LOG"
fi

# --- Test 7: bd failure on one rig → other rigs still returned ---
echo "Test 7: bd failure on one rig doesn't break others"
setup
write_mock bd '#!/bin/bash
RIG=""
for a in "$@"; do
  case "$a" in --rig) RIG="next" ;; *) [[ "$RIG" == "next" ]] && RIG="$a" ;; esac
done
case "$RIG" in
  ai_manager) echo "ERROR: database locked" >&2; exit 1 ;;
  suplagents) echo "[{\"id\":\"su-ok\",\"title\":\"OK\"}]" ;;
  *) echo "[{\"id\":\"hq-ok\",\"title\":\"OK\"}]" ;;
esac'
OUTPUT=$(run_script --status=open --json --limit=0)
COUNT=$(echo "$OUTPUT" | jq length)
if [[ "$COUNT" -eq 2 ]]; then
  pass "Failure on one rig doesn't prevent other results"
else
  fail "Should return 2 beads despite one rig failing"
  echo "  got: $OUTPUT"
fi

# --- Test 8: Missing routes.jsonl → returns HQ only ---
echo "Test 8: Missing routes.jsonl returns HQ only"
setup
rm -f "$FAKE_GT/.beads/routes.jsonl"
write_mock bd '#!/bin/bash
RIG=""
for a in "$@"; do
  case "$a" in --rig) RIG="next" ;; *) [[ "$RIG" == "next" ]] && RIG="$a" ;; esac
done
if [[ -z "$RIG" || "$RIG" == "next" ]]; then
  echo "[{\"id\":\"hq-only\",\"title\":\"HQ\"}]"
else
  echo "[]"
fi'
OUTPUT=$(run_script --status=open --json --limit=0)
COUNT=$(echo "$OUTPUT" | jq length)
if [[ "$COUNT" -eq 1 ]] && echo "$OUTPUT" | jq -e '.[0].id == "hq-only"' >/dev/null; then
  pass "Missing routes.jsonl falls back to HQ only"
else
  fail "Should return HQ beads when routes.jsonl missing"
  echo "  got: $OUTPUT"
fi

# --- Test 9: Deduplication — same bead from HQ and rig not duplicated ---
echo "Test 9: Deduplication"
setup
write_mock bd '#!/bin/bash
RIG=""
for a in "$@"; do
  case "$a" in --rig) RIG="next" ;; *) [[ "$RIG" == "next" ]] && RIG="$a" ;; esac
done
case "$RIG" in
  ai_manager) echo "[{\"id\":\"aim-dupe\",\"title\":\"Dupe\"}]" ;;
  *) echo "[{\"id\":\"aim-dupe\",\"title\":\"Dupe\"}]" ;;
esac'
OUTPUT=$(run_script --status=open --json --limit=0)
COUNT=$(echo "$OUTPUT" | jq length)
if [[ "$COUNT" -eq 1 ]]; then
  pass "Duplicate bead IDs deduplicated"
else
  fail "Should deduplicate bead IDs, got $COUNT"
  echo "  got: $OUTPUT"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
