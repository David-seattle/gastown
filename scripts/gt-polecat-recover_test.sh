#!/bin/bash
# Test suite for gt-polecat-recover.
# Mocks bd and gt commands to test all detection and recovery scenarios.
#
# Usage: bash scripts/gt-polecat-recover_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/gt-polecat-recover"
PASS=0
FAIL=0
MOCK_DIR=""
BD_LOG=""
GT_LOG=""

pass() {
  local test_name=$1
  echo "  PASS: $test_name"
  PASS=$((PASS + 1))
}

fail() {
  local test_name=$1
  shift
  echo "  FAIL: $test_name${1:+ ($1)}"
  FAIL=$((FAIL + 1))
}

cleanup() {
  cd /tmp
  if [[ -n "${MOCK_DIR:-}" && -d "${MOCK_DIR:-}" ]]; then
    rm -rf "$MOCK_DIR"
  fi
  MOCK_DIR=""
}
trap cleanup EXIT

setup() {
  cleanup
  MOCK_DIR=$(mktemp -d)
  BD_LOG="$MOCK_DIR/bd.log"
  GT_LOG="$MOCK_DIR/gt.log"
  touch "$BD_LOG" "$GT_LOG"
}

# Create a mock bd script.
# $1 = JSON to return for "bd list --status=hooked"
create_bd_mock() {
  local hooked_json="$1"
  # The dataset served by `bd show <id>` (authoritative single-bead lookup).
  # Defaults to the hooked dataset; pass a 2nd arg to make `bd show` return a
  # bead that is ABSENT from the bulk `bd list` snapshot — this simulates the
  # dispatch race where a just-hooked bead is transiently missing from the
  # bulk query but is still retrievable directly.
  local show_json="${2:-$1}"
  printf '%s' "$show_json" > "$MOCK_DIR/show_data.json"
  cat > "$MOCK_DIR/bd" <<MOCK_EOF
#!/bin/bash
# Log all bd invocations for verification
echo "\$@" >> "$BD_LOG"

# bd list --status=hooked
if [[ "\$1" == "list" ]] && echo "\$@" | grep -q -- "--status=hooked"; then
  cat <<'JSON_EOF'
${hooked_json}
JSON_EOF
  exit 0
fi

# bd show <id> --json → authoritative single-bead lookup
if [[ "\$1" == "show" ]]; then
  jq -c --arg id "\$2" '[.[] | select(.id == \$id)]' "$MOCK_DIR/show_data.json" 2>/dev/null || echo "[]"
  exit 0
fi

# bd update <id> --status=open
if [[ "\$1" == "update" ]]; then
  exit 0
fi

exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/bd"
}

# Create a mock gt script.
# $1 = JSON to return for "gt polecat list --all --json"
create_gt_mock() {
  local polecat_json="$1"
  cat > "$MOCK_DIR/gt" <<MOCK_EOF
#!/bin/bash
# Log all gt invocations for verification
echo "\$@" >> "$GT_LOG"

# gt polecat list --all --json
if [[ "\$1" == "polecat" ]] && [[ "\$2" == "list" ]]; then
  cat <<'JSON_EOF'
${polecat_json}
JSON_EOF
  exit 0
fi

# gt sling <id> --no-boot
if [[ "\$1" == "sling" ]]; then
  exit 0
fi

exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/gt"
}

# Run the script under test with mocked PATH.
# Tolerates non-zero exit codes so set -e in the test doesn't abort.
# The script has a known set -e interaction: its final [[ $ERRORS -gt 0 ]] && exit 1
# returns exit code 1 from [[ ]] when ERRORS=0, which set -e catches.
run_script() {
  mkdir -p "$MOCK_DIR/fake-gt"
  PATH="$MOCK_DIR:$PATH" GT="$MOCK_DIR/fake-gt" RECOVERY_COUNTS_FILE="$MOCK_DIR/recovery-counts" bash "$SCRIPT" "$@" 2>&1 || true
}

# Helper: build a hooked bead JSON object
bead_json() {
  local id="$1" assignee="$2" title="${3:-Test bead}" type="${4:-task}" ephemeral="${5:-false}"
  cat <<EOF
{"id":"$id","assignee":"$assignee","title":"$title","issue_type":"$type","ephemeral":$ephemeral,"created_at":"2026-03-07T10:00:00Z","status":"hooked"}
EOF
}

echo "=== gt-polecat-recover test suite ==="
echo ""

# --- Test 1: No hooked beads (empty string) ---
echo "--- Test 1: No hooked beads (empty output) ---"
setup
create_bd_mock ""
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "No hooked/in-progress beads found"; then
  pass "Empty output reports no hooked beads"
else
  fail "Empty output reports no hooked beads" "got: $OUTPUT"
fi

# --- Test 2: Empty JSON array from bd list ---
echo "--- Test 2: Empty JSON array from bd list ---"
setup
create_bd_mock "[]"
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "No hooked/in-progress beads found"; then
  pass "Empty JSON array reports no hooked beads"
else
  fail "Empty JSON array reports no hooked beads" "got: $OUTPUT"
fi

# --- Test 3: Bead hooked to dead agent (deacon) ---
echo "--- Test 3: Bead hooked to dead agent (deacon) ---"
setup
BEAD=$(bead_json "aim-1234" "deacon" "Deacon bead")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*aim-1234"; then
  pass "Deacon assignee detected as STALE"
else
  fail "Deacon assignee detected as STALE" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "reason=dead agent"; then
  pass "Deacon reason is dead agent"
else
  fail "Deacon reason is dead agent" "got: $OUTPUT"
fi

# --- Test 4: Bead hooked to dead suffix (/witness, /refinery) ---
echo "--- Test 4: Bead hooked to dead suffix ---"
setup
BEAD_W=$(bead_json "aim-2001" "backend/witness" "Witness bead")
BEAD_R=$(bead_json "aim-2002" "backend/refinery" "Refinery bead")
create_bd_mock "[$BEAD_W, $BEAD_R]"
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*aim-2001"; then
  pass "/witness suffix detected as STALE"
else
  fail "/witness suffix detected as STALE" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "STALE.*aim-2002"; then
  pass "/refinery suffix detected as STALE"
else
  fail "/refinery suffix detected as STALE" "got: $OUTPUT"
fi

# --- Test 5: Bead hooked to running polecat ---
echo "--- Test 5: Bead hooked to running polecat (NOT stale) ---"
setup
BEAD=$(bead_json "aim-3001" "backend/polecats/pc-alpha" "Active polecat bead")
POLECAT_JSON='[{"rig":"backend","name":"pc-alpha","session_running":true}]'
create_bd_mock "[$BEAD]"
create_gt_mock "$POLECAT_JSON"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*aim-3001"; then
  fail "Running polecat should NOT be stale" "was marked STALE"
else
  pass "Running polecat is NOT stale"
fi
if echo "$OUTPUT" | grep -q "No hooked/in-progress beads found"; then
  pass "Reports no stale beads when polecat is running"
else
  fail "Reports no stale beads when polecat is running" "got: $OUTPUT"
fi

# --- Test 6: Bead hooked to polecat that doesn't exist ---
echo "--- Test 6: Bead hooked to polecat that doesn't exist ---"
setup
BEAD=$(bead_json "aim-4001" "backend/polecats/pc-gone" "Missing polecat bead")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*aim-4001"; then
  pass "Missing polecat detected as STALE"
else
  fail "Missing polecat detected as STALE" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "reason=polecat not found"; then
  pass "Reason is polecat not found"
else
  fail "Reason is polecat not found" "got: $OUTPUT"
fi

# --- Test 7: Bead hooked to polecat with session_running=false ---
echo "--- Test 7: Bead hooked to polecat with session_running=false ---"
setup
BEAD=$(bead_json "aim-5001" "frontend/polecats/pc-dead" "Dead session bead")
POLECAT_JSON='[{"rig":"frontend","name":"pc-dead","session_running":false}]'
create_bd_mock "[$BEAD]"
create_gt_mock "$POLECAT_JSON"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*aim-5001"; then
  pass "Dead session polecat detected as STALE"
else
  fail "Dead session polecat detected as STALE" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "reason=session dead"; then
  pass "Reason is session dead"
else
  fail "Reason is session dead" "got: $OUTPUT"
fi

# --- Test 8: Unknown assignee type ---
echo "--- Test 8: Unknown assignee type ---"
setup
BEAD=$(bead_json "aim-6001" "some-random-thing" "Unknown assignee bead")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "unknown agent type"; then
  pass "Unknown assignee type reported"
else
  fail "Unknown assignee type reported" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "aim-6001.*skipping"; then
  pass "Unknown assignee is skipped"
else
  fail "Unknown assignee is skipped" "got: $OUTPUT"
fi

# --- Test 9: --fix flag unhooks stale beads ---
echo "--- Test 9: --fix flag unhooks stale beads ---"
setup
BEAD1=$(bead_json "aim-7001" "deacon" "Stale bead 1")
BEAD2=$(bead_json "aim-7002" "backend/polecats/pc-missing" "Stale bead 2")
create_bd_mock "[$BEAD1, $BEAD2]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix)
if echo "$OUTPUT" | grep -q "Unhooking stale beads"; then
  pass "--fix triggers unhooking"
else
  fail "--fix triggers unhooking" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "OK.*aim-7001.*open"; then
  pass "Bead aim-7001 unhook reported"
else
  fail "Bead aim-7001 unhook reported" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "OK.*aim-7002.*open"; then
  pass "Bead aim-7002 unhook reported"
else
  fail "Bead aim-7002 unhook reported" "got: $OUTPUT"
fi
# Verify bd update was called with --status=open for both beads
if grep -q "update aim-7001 --status=open" "$BD_LOG"; then
  pass "bd update called for aim-7001 with --status=open"
else
  fail "bd update called for aim-7001 with --status=open" "bd log: $(cat "$BD_LOG")"
fi
if grep -q "update aim-7002 --status=open" "$BD_LOG"; then
  pass "bd update called for aim-7002 with --status=open"
else
  fail "bd update called for aim-7002 with --status=open" "bd log: $(cat "$BD_LOG")"
fi

# --- Test 10: --fix --resling re-slings polecat beads ---
echo "--- Test 10: --fix --resling re-slings polecat beads ---"
setup
BEAD=$(bead_json "aim-8001" "backend/polecats/pc-dead" "Resling bead" "task" "false")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "Re-slinging"; then
  pass "--resling triggers re-slinging"
else
  fail "--resling triggers re-slinging" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "SLUNG.*aim-8001"; then
  pass "Bead aim-8001 re-slung"
else
  fail "Bead aim-8001 re-slung" "got: $OUTPUT"
fi
if grep -q "sling aim-8001 backend --force --no-boot" "$GT_LOG"; then
  pass "gt sling called with correct args including --force"
else
  fail "gt sling should include --force for stale molecule cleanup" "gt log: $(cat "$GT_LOG")"
fi

# --- Test 11: Ephemeral beads are NOT re-slung ---
echo "--- Test 11: Ephemeral beads are NOT re-slung ---"
setup
BEAD=$(bead_json "aim-9001" "backend/polecats/pc-gone" "Ephemeral bead" "task" "true")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "STALE.*aim-9001"; then
  pass "Ephemeral bead detected as stale"
else
  fail "Ephemeral bead detected as stale" "got: $OUTPUT"
fi
# Should NOT be re-slung
if echo "$OUTPUT" | grep -q "SLUNG.*aim-9001"; then
  fail "Ephemeral bead should NOT be re-slung" "was re-slung"
else
  pass "Ephemeral bead is NOT re-slung"
fi
if grep -q "sling aim-9001" "$GT_LOG"; then
  fail "gt sling should NOT be called for ephemeral bead" "gt log: $(cat "$GT_LOG")"
else
  pass "gt sling not called for ephemeral bead"
fi

# --- Test 12: Non-task/bug/feature types are NOT re-slung ---
echo "--- Test 12: Non-task/bug/feature types are NOT re-slung ---"
setup
BEAD_CHORE=$(bead_json "aim-a001" "backend/polecats/pc-gone" "Chore bead" "chore" "false")
BEAD_SPIKE=$(bead_json "aim-a002" "backend/polecats/pc-gone" "Spike bead" "spike" "false")
BEAD_TASK=$(bead_json "aim-a003" "backend/polecats/pc-gone" "Task bead" "task" "false")
create_bd_mock "[$BEAD_CHORE, $BEAD_SPIKE, $BEAD_TASK]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
# chore and spike should NOT be re-slung
if echo "$OUTPUT" | grep -q "SLUNG.*aim-a001"; then
  fail "Chore bead should NOT be re-slung" "was re-slung"
else
  pass "Chore type is NOT re-slung"
fi
if echo "$OUTPUT" | grep -q "SLUNG.*aim-a002"; then
  fail "Spike bead should NOT be re-slung" "was re-slung"
else
  pass "Spike type is NOT re-slung"
fi
# task SHOULD be re-slung
if echo "$OUTPUT" | grep -q "SLUNG.*aim-a003"; then
  pass "Task type IS re-slung"
else
  fail "Task type IS re-slung" "got: $OUTPUT"
fi
# Verify gt sling was only called for the task bead
SLING_COUNT=$(grep -c "sling" "$GT_LOG" || true)
if [[ "$SLING_COUNT" -eq 1 ]]; then
  pass "gt sling called exactly once (only for task)"
else
  fail "gt sling called exactly once (only for task)" "called $SLING_COUNT times"
fi

# --- Test 13: --fix without --resling shows eligible count ---
echo "--- Test 13: --fix without --resling shows eligible count ---"
setup
BEAD=$(bead_json "aim-b001" "backend/polecats/pc-gone" "Eligible bead" "bug" "false")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix)
if echo "$OUTPUT" | grep -q "eligible for re-sling"; then
  pass "Shows eligible re-sling count without --resling"
else
  fail "Shows eligible re-sling count without --resling" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Use --resling"; then
  pass "Suggests --resling flag"
else
  fail "Suggests --resling flag" "got: $OUTPUT"
fi

# --- Test 14: Report-only mode (no --fix) shows run hint ---
echo "--- Test 14: Report-only mode shows run hint ---"
setup
BEAD=$(bead_json "aim-c001" "deacon" "Report-only bead")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "Run with --fix"; then
  pass "Report-only mode shows --fix hint"
else
  fail "Report-only mode shows --fix hint" "got: $OUTPUT"
fi
# Verify bd update was NOT called
if grep -q "update" "$BD_LOG"; then
  fail "No bd update in report-only mode" "bd log: $(cat "$BD_LOG")"
else
  pass "No bd update in report-only mode"
fi

# --- Test 15: Boot agent detected as dead ---
echo "--- Test 15: Boot agent detected as dead ---"
setup
BEAD=$(bead_json "aim-d001" "boot" "Boot agent bead")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*aim-d001"; then
  pass "Boot assignee detected as STALE"
else
  fail "Boot assignee detected as STALE" "got: $OUTPUT"
fi

# --- Test 16: Mixed scenario - stale and running polecats ---
echo "--- Test 16: Mixed scenario ---"
setup
BEAD_LIVE=$(bead_json "aim-e001" "backend/polecats/pc-live" "Live bead")
BEAD_DEAD=$(bead_json "aim-e002" "backend/polecats/pc-dead" "Dead bead")
BEAD_DEACON=$(bead_json "aim-e003" "deacon" "Deacon bead")
POLECAT_JSON='[{"rig":"backend","name":"pc-live","session_running":true},{"rig":"backend","name":"pc-dead","session_running":false}]'
create_bd_mock "[$BEAD_LIVE, $BEAD_DEAD, $BEAD_DEACON]"
create_gt_mock "$POLECAT_JSON"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*aim-e002"; then
  pass "Dead polecat is stale in mixed scenario"
else
  fail "Dead polecat is stale in mixed scenario" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "STALE.*aim-e003"; then
  pass "Deacon is stale in mixed scenario"
else
  fail "Deacon is stale in mixed scenario" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "STALE.*aim-e001"; then
  fail "Live polecat should NOT be stale" "was marked stale"
else
  pass "Live polecat is NOT stale in mixed scenario"
fi
if echo "$OUTPUT" | grep -q "Found 2 stale"; then
  pass "Correct stale count in mixed scenario"
else
  fail "Correct stale count in mixed scenario" "got: $OUTPUT"
fi

# --- Test 17: null JSON from bd list ---
echo "--- Test 17: null JSON from bd list ---"
setup
create_bd_mock "null"
create_gt_mock "[]"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "No hooked/in-progress beads found"; then
  pass "null JSON reports no hooked beads"
else
  fail "null JSON reports no hooked beads" "got: $OUTPUT"
fi

# --- Test 18: feature type IS re-slung ---
echo "--- Test 18: feature type IS re-slung ---"
setup
BEAD=$(bead_json "aim-f001" "backend/polecats/pc-gone" "Feature bead" "feature" "false")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "SLUNG.*aim-f001"; then
  pass "Feature type IS re-slung"
else
  fail "Feature type IS re-slung" "got: $OUTPUT"
fi

# --- Test 19: bug type IS re-slung ---
echo "--- Test 19: bug type IS re-slung ---"
setup
BEAD=$(bead_json "aim-g001" "backend/polecats/pc-gone" "Bug bead" "bug" "false")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "SLUNG.*aim-g001"; then
  pass "Bug type IS re-slung"
else
  fail "Bug type IS re-slung" "got: $OUTPUT"
fi

# --- Test 20: Dead agent beads are NOT re-slung (deacon is not a polecat) ---
echo "--- Test 20: Dead agent beads are NOT re-slung ---"
setup
BEAD=$(bead_json "aim-h001" "deacon" "Deacon bead" "task" "false")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "OK.*aim-h001"; then
  pass "Deacon bead is unhook-fixed"
else
  fail "Deacon bead is unhook-fixed" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "SLUNG.*aim-h001"; then
  fail "Deacon bead should NOT be re-slung" "was re-slung"
else
  pass "Deacon bead is NOT re-slung (not a polecat)"
fi

# --- Test 21: in_progress bead with dead polecat → detected as stale ---
echo "--- Test 21: in_progress bead with dead polecat detected as stale ---"
setup
# Custom bd mock: returns nothing for --status=hooked, returns bead for --status=in_progress
cat > "$MOCK_DIR/bd" <<'MOCK_EOF'
#!/bin/bash
echo "$@" >> BD_LOG_PLACEHOLDER

if [[ "$1" == "list" ]]; then
  STATUS=""
  for a in "$@"; do
    case "$a" in --status=*) STATUS="${a#--status=}" ;; esac
  done
  case "$STATUS" in
    hooked) echo "[]" ;;
    in_progress)
      cat <<'JSON'
[{"id":"su-e82e","assignee":"suplagents/polecats/obsidian","title":"Research backend case creation APIs","issue_type":"task","ephemeral":false,"created_at":"2026-03-06T10:00:00Z","status":"in_progress"}]
JSON
      ;;
    *) echo "[]" ;;
  esac
  exit 0
fi

if [[ "$1" == "update" ]]; then
  exit 0
fi

exit 0
MOCK_EOF
sed -i '' "s|BD_LOG_PLACEHOLDER|$BD_LOG|" "$MOCK_DIR/bd"
chmod +x "$MOCK_DIR/bd"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "STALE.*su-e82e"; then
  pass "in_progress bead with dead polecat detected as stale"
else
  fail "in_progress bead with dead polecat should be detected as stale" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "SLUNG.*su-e82e"; then
  pass "in_progress bead re-slung after recovery"
else
  fail "in_progress bead should be re-slung" "got: $OUTPUT"
fi
# Verify bd update was called to reset status to open
if grep -q "update su-e82e --status=open" "$BD_LOG"; then
  pass "bd update called to reset in_progress bead to open"
else
  fail "bd update should reset in_progress bead to open" "bd log: $(cat "$BD_LOG")"
fi

# --- Test 22: Per-rig bead with dead polecat → detected as stale ---
echo "--- Test 22: Per-rig in_progress bead detected as stale ---"
setup
# Need routes.jsonl for rig iteration
mkdir -p "$MOCK_DIR/fake-gt/.beads"
cat > "$MOCK_DIR/fake-gt/.beads/routes.jsonl" <<'ROUTES'
{"prefix":"hq-","path":"."}
{"prefix":"su-","path":"suplagents"}
{"prefix":"aim-","path":"ai_manager"}
ROUTES
# bd mock: HQ returns nothing, suplagents --rig query returns the stuck bead
cat > "$MOCK_DIR/bd" <<'MOCK_EOF'
#!/bin/bash
echo "$@" >> BD_LOG_PLACEHOLDER

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

if [[ "$1" == "list" ]]; then
  if [[ "$RIG" == "suplagents" && "$STATUS" == "in_progress" ]]; then
    cat <<'JSON'
[{"id":"su-e82e","assignee":"suplagents/polecats/obsidian","title":"Research backend APIs","issue_type":"task","ephemeral":false,"created_at":"2026-03-06T10:00:00Z","status":"in_progress"}]
JSON
  else
    echo "[]"
  fi
  exit 0
fi

if [[ "$1" == "update" ]]; then
  exit 0
fi

exit 0
MOCK_EOF
sed -i '' "s|BD_LOG_PLACEHOLDER|$BD_LOG|" "$MOCK_DIR/bd"
chmod +x "$MOCK_DIR/bd"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "STALE.*su-e82e"; then
  pass "Per-rig in_progress bead with dead polecat detected as stale"
else
  fail "Per-rig in_progress bead should be detected as stale" "got: $OUTPUT"
fi
if grep -q "update su-e82e --status=open" "$BD_LOG"; then
  pass "bd update called for per-rig bead"
else
  fail "bd update should be called for per-rig bead" "bd log: $(cat "$BD_LOG")"
fi

# --- Test 23: Re-sling passes rig from assignee to gt sling ---
echo "--- Test 23: Re-sling passes rig to gt sling ---"
setup
BEAD=$(bead_json "aim-8888" "suplagents/polecats/obsidian" "Resling rig bead" "task" "false")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
# gt sling should be called with the rig extracted from the assignee
if grep -q "sling aim-8888 suplagents --force --no-boot" "$GT_LOG"; then
  pass "gt sling called with rig and --force from assignee"
else
  fail "gt sling should include rig and --force" "gt log: $(cat "$GT_LOG")"
fi

# --- Test 24: Unhook clears stale assignee ---
echo "--- Test 24: Unhook clears stale assignee ---"
setup
BEAD=$(bead_json "aim-9999" "suplagents/polecats/obsidian" "Stale assignee bead" "task" "false")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix)
# bd update should clear the assignee in addition to setting status=open
if grep -q 'update aim-9999 --status=open --assignee' "$BD_LOG"; then
  pass "Unhook clears assignee"
else
  fail "Unhook should clear assignee" "bd log: $(cat "$BD_LOG")"
fi

# --- Test 25: Open bead with stale polecat assignee → detected and cleaned ---
echo "--- Test 25: Open bead with stale polecat assignee detected ---"
setup
# bd mock: open bead with dead polecat assignee
cat > "$MOCK_DIR/bd" <<'MOCK_EOF'
#!/bin/bash
echo "$@" >> BD_LOG_PLACEHOLDER

if [[ "$1" == "list" ]]; then
  STATUS=""
  for a in "$@"; do
    case "$a" in --status=*) STATUS="${a#--status=}" ;; esac
  done
  case "$STATUS" in
    open)
      cat <<'JSON'
[{"id":"su-e82e","assignee":"suplagents/polecats/obsidian","title":"Research backend APIs","issue_type":"task","ephemeral":false,"created_at":"2026-03-06T10:00:00Z","status":"open"}]
JSON
      ;;
    *) echo "[]" ;;
  esac
  exit 0
fi

if [[ "$1" == "update" ]]; then
  exit 0
fi

exit 0
MOCK_EOF
sed -i '' "s|BD_LOG_PLACEHOLDER|$BD_LOG|" "$MOCK_DIR/bd"
chmod +x "$MOCK_DIR/bd"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "STALE.*su-e82e"; then
  pass "Open bead with dead polecat assignee detected as stale"
else
  fail "Open bead with dead polecat assignee should be detected" "got: $OUTPUT"
fi
if grep -q 'update su-e82e --status=open --assignee' "$BD_LOG"; then
  pass "Assignee cleared on open bead"
else
  fail "Assignee should be cleared on open bead" "bd log: $(cat "$BD_LOG")"
fi

# --- Test 26: Script runs under /bin/bash (Bash 3.2 compatibility) ---
echo "--- Test 26: Bash 3.2 compatibility (launchd uses /bin/bash) ---"
setup
BEAD=$(bead_json "aim-z001" "backend/polecats/pc-gone" "Bash3 bead" "task" "false")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
# Run explicitly under /bin/bash (Bash 3.2 on macOS) to catch declare -A etc.
BASH3_OUTPUT=$(mkdir -p "$MOCK_DIR/fake-gt" && PATH="$MOCK_DIR:$PATH" GT="$MOCK_DIR/fake-gt" RECOVERY_COUNTS_FILE="$MOCK_DIR/recovery-counts" /bin/bash "$SCRIPT" --fix --resling 2>&1) || true
if echo "$BASH3_OUTPUT" | grep -q "invalid option"; then
  fail "Script must not use Bash 4+ features (declare -A)" "got: $BASH3_OUTPUT"
elif echo "$BASH3_OUTPUT" | grep -q "SLUNG.*aim-z001"; then
  pass "Script works under /bin/bash (Bash 3.2)"
elif echo "$BASH3_OUTPUT" | grep -q "SLING-SKIP\|SLING-FAIL"; then
  fail "Re-sling failed under /bin/bash" "got: $BASH3_OUTPUT"
else
  fail "Unexpected output under /bin/bash" "got: $BASH3_OUTPUT"
fi

# --- Test 27: MR bead exists → skip re-sling (work already submitted) ---
echo "--- Test 27: MR bead exists → skip re-sling ---"
setup
cat > "$MOCK_DIR/bd" <<'MOCK_EOF'
#!/bin/bash
echo "$@" >> BD_LOG_PLACEHOLDER

STATUS=""
for a in "$@"; do
  case "$a" in --status=*) STATUS="${a#--status=}" ;; esac
done

if [[ "$1" == "list" ]]; then
  case "$STATUS" in
    hooked)
      cat <<'JSON'
[{"id":"sa-vwwne","assignee":"suplari_assistant/polecats/nitro","title":"Implement idle session rotation","issue_type":"task","ephemeral":false,"created_at":"2026-03-07T10:00:00Z","status":"hooked"}]
JSON
      ;;
    open)
      cat <<'JSON'
[{"id":"sa-wisp-t8hj4","assignee":"","title":"Merge: sa-vwwne","issue_type":"wisp","ephemeral":true,"created_at":"2026-03-07T11:00:00Z","status":"open"}]
JSON
      ;;
    *) echo "[]" ;;
  esac
  exit 0
fi

if [[ "$1" == "update" ]]; then
  exit 0
fi

exit 0
MOCK_EOF
sed -i '' "s|BD_LOG_PLACEHOLDER|$BD_LOG|" "$MOCK_DIR/bd"
chmod +x "$MOCK_DIR/bd"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "SKIP-MR.*sa-vwwne"; then
  pass "MR bead exists: skip re-sling"
else
  fail "MR bead exists: skip re-sling" "expected SKIP-MR, got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "SLUNG.*sa-vwwne"; then
  fail "MR bead exists: should NOT re-sling" "was re-slung despite MR bead"
else
  pass "MR bead exists: NOT re-slung"
fi

# --- Test 28: No MR bead → re-sling normally ---
echo "--- Test 28: No MR bead → re-sling normally ---"
setup
cat > "$MOCK_DIR/bd" <<'MOCK_EOF'
#!/bin/bash
echo "$@" >> BD_LOG_PLACEHOLDER

STATUS=""
for a in "$@"; do
  case "$a" in --status=*) STATUS="${a#--status=}" ;; esac
done

if [[ "$1" == "list" ]]; then
  case "$STATUS" in
    hooked)
      cat <<'JSON'
[{"id":"sa-abc12","assignee":"suplari_assistant/polecats/nitro","title":"Some task","issue_type":"task","ephemeral":false,"created_at":"2026-03-07T10:00:00Z","status":"hooked"}]
JSON
      ;;
    *) echo "[]" ;;
  esac
  exit 0
fi

if [[ "$1" == "update" ]]; then
  exit 0
fi

exit 0
MOCK_EOF
sed -i '' "s|BD_LOG_PLACEHOLDER|$BD_LOG|" "$MOCK_DIR/bd"
chmod +x "$MOCK_DIR/bd"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "SLUNG.*sa-abc12"; then
  pass "no MR bead: re-slung normally"
else
  fail "no MR bead: re-slung normally" "expected SLUNG, got: $OUTPUT"
fi

# --- Test 29: MR bead for different parent → re-sling proceeds ---
echo "--- Test 29: MR bead for different parent → re-sling proceeds ---"
setup
cat > "$MOCK_DIR/bd" <<'MOCK_EOF'
#!/bin/bash
echo "$@" >> BD_LOG_PLACEHOLDER

STATUS=""
for a in "$@"; do
  case "$a" in --status=*) STATUS="${a#--status=}" ;; esac
done

if [[ "$1" == "list" ]]; then
  case "$STATUS" in
    hooked)
      cat <<'JSON'
[{"id":"sa-xyz99","assignee":"suplari_assistant/polecats/chrome","title":"Another task","issue_type":"task","ephemeral":false,"created_at":"2026-03-07T10:00:00Z","status":"hooked"}]
JSON
      ;;
    open)
      cat <<'JSON'
[{"id":"sa-wisp-abc","assignee":"","title":"Merge: sa-OTHER","issue_type":"wisp","ephemeral":true,"created_at":"2026-03-07T11:00:00Z","status":"open"}]
JSON
      ;;
    *) echo "[]" ;;
  esac
  exit 0
fi

if [[ "$1" == "update" ]]; then
  exit 0
fi

exit 0
MOCK_EOF
sed -i '' "s|BD_LOG_PLACEHOLDER|$BD_LOG|" "$MOCK_DIR/bd"
chmod +x "$MOCK_DIR/bd"
create_gt_mock "[]"
OUTPUT=$(run_script --fix --resling)
if echo "$OUTPUT" | grep -q "SLUNG.*sa-xyz99"; then
  pass "MR for different parent: re-sling proceeds"
else
  fail "MR for different parent: re-sling proceeds" "expected SLUNG, got: $OUTPUT"
fi

# --- Test 30: Running polecat stuck at interactive prompt → detected as stale ---
echo "--- Test 30: Running polecat stuck at rate limit prompt → stale ---"
setup
BEAD=$(bead_json "sa-m7cjx" "suplari_assistant/polecats/rust" "Worker callback retry" "task" "false")
POLECAT_JSON='[{"rig":"suplari_assistant","name":"rust","state":"working","issue":"sa-m7cjx","session_running":true}]'
create_bd_mock "[$BEAD]"
create_gt_mock "$POLECAT_JSON"
# Mock tmux to simulate a polecat stuck at the rate limit prompt
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  cat <<'OUTPUT'
⏺ Background command "Check next step" completed (exit code 0)
  ⎿  You're out of extra usage · resets 7am (America/Phoenix)

❯ /rate-limit-options

────────────────────────────────────────────────────────────
  What do you want to do?

  ❯ 1. Stop and wait for limit to reset
    2. Switch to extra usage

  Enter to confirm · Esc to cancel
OUTPUT
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*sa-m7cjx"; then
  pass "Running polecat stuck at rate limit detected as STALE"
else
  fail "Running polecat stuck at rate limit detected as STALE" "got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "reason=stuck at interactive prompt"; then
  pass "Reason is stuck at interactive prompt"
else
  fail "Reason is stuck at interactive prompt" "got: $OUTPUT"
fi

# --- Test 31: Running polecat with normal output → NOT stale ---
echo "--- Test 31: Running polecat with normal output → NOT stale ---"
setup
BEAD=$(bead_json "sa-n0rml" "suplari_assistant/polecats/rust" "Normal work" "task" "false")
POLECAT_JSON='[{"rig":"suplari_assistant","name":"rust","state":"working","issue":"sa-n0rml","session_running":true}]'
create_bd_mock "[$BEAD]"
create_gt_mock "$POLECAT_JSON"
# Mock tmux with normal working output
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  cat <<'OUTPUT'
⏺ Read file: src/main.go

⏺ I'll implement the retry logic with exponential backoff.

⏺ Edit file: src/worker/callback.go
OUTPUT
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*sa-n0rml"; then
  fail "Normal working polecat should NOT be stale" "was marked STALE"
else
  pass "Normal working polecat is NOT stale"
fi

# --- Test 32: Running polecat stuck at generic confirmation prompt → stale ---
echo "--- Test 32: Running polecat stuck at generic confirmation → stale ---"
setup
BEAD=$(bead_json "sa-c0nfm" "backend/polecats/alpha" "Some task" "task" "false")
POLECAT_JSON='[{"rig":"backend","name":"alpha","state":"working","issue":"sa-c0nfm","session_running":true}]'
create_bd_mock "[$BEAD]"
create_gt_mock "$POLECAT_JSON"
# Mock tmux with a generic interactive prompt
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  cat <<'OUTPUT'
Some previous output here

  Enter to confirm · Esc to cancel
OUTPUT
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "STALE.*sa-c0nfm"; then
  pass "Polecat stuck at confirmation prompt detected as STALE"
else
  fail "Polecat stuck at confirmation prompt detected as STALE" "got: $OUTPUT"
fi

# --- Test 33: Orphaned polecat — alive but bead assigned to different polecat ---
echo "--- Test 33: Orphaned polecat detected as stale ---"
setup
# Bead assigned to chrome, but rust also claims to be working on it
BEAD=$(bead_json "sa-m7cjx" "suplari_assistant/polecats/chrome" "Worker callback retry" "task" "false")
POLECAT_JSON='[
  {"rig":"suplari_assistant","name":"chrome","state":"working","issue":"sa-m7cjx","session_running":true},
  {"rig":"suplari_assistant","name":"rust","state":"working","issue":"sa-m7cjx","session_running":true}
]'
create_bd_mock "[$BEAD]"
create_gt_mock "$POLECAT_JSON"
# Mock tmux: both sessions show normal output (no stuck prompt)
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  echo "Normal working output"
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script)
# chrome should NOT be stale (it's the actual assignee)
if echo "$OUTPUT" | grep -q "STALE.*chrome"; then
  fail "Assigned polecat (chrome) should NOT be stale" "was marked STALE"
else
  pass "Assigned polecat (chrome) is NOT stale"
fi
# rust should be detected as orphaned
if echo "$OUTPUT" | grep -q "ORPHAN.*rust"; then
  pass "Orphaned polecat (rust) detected"
else
  fail "Orphaned polecat (rust) detected" "got: $OUTPUT"
fi

# --- Test 34: Polecat with no bead at all — orphaned ---
echo "--- Test 34: Polecat working on nonexistent bead → orphaned ---"
setup
# No beads at all, but a polecat is alive
create_bd_mock "[]"
POLECAT_JSON='[{"rig":"backend","name":"ghost","state":"working","issue":"aim-gone","session_running":true}]'
create_gt_mock "$POLECAT_JSON"
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  echo "Normal output"
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "ORPHAN.*ghost"; then
  pass "Polecat with no bead detected as orphaned"
else
  fail "Polecat with no bead detected as orphaned" "got: $OUTPUT"
fi

# --- Test 35: All polecats properly assigned — no orphans ---
echo "--- Test 35: No orphans when all polecats properly assigned ---"
setup
BEAD=$(bead_json "aim-ok01" "backend/polecats/alpha" "Good bead" "task" "false")
POLECAT_JSON='[{"rig":"backend","name":"alpha","state":"working","issue":"aim-ok01","session_running":true}]'
create_bd_mock "[$BEAD]"
create_gt_mock "$POLECAT_JSON"
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  echo "Normal output"
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "ORPHAN"; then
  fail "No orphans when all polecats properly assigned" "found ORPHAN in output"
else
  pass "No orphans when all polecats properly assigned"
fi

# --- Test 35b: Freshly-dispatched polecat (bead hooked but unassigned) is NOT orphaned ---
echo "--- Test 35b: Fresh polecat claiming an unassigned hooked bead is NOT orphaned ---"
setup
# Bead is hooked and present, but assignee is still empty: the polecat was just
# dispatched and its agent is in pre-generation, not yet claimed via gt prime.
BEAD=$(bead_json "sa-fresh1" "" "Fresh dispatch in pregen" "task" "false")
POLECAT_JSON='[{"rig":"suplari_assistant","name":"rust","state":"working","issue":"sa-fresh1","session_running":true}]'
create_bd_mock "[$BEAD]"
create_gt_mock "$POLECAT_JSON"
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  echo "Normal output"
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "ORPHAN.*rust"; then
  fail "Fresh polecat with unassigned hooked bead should NOT be orphaned" "got: $OUTPUT"
else
  pass "Fresh polecat with unassigned hooked bead is NOT orphaned"
fi

# --- Test 35c: Bead missing from bulk snapshot but present via bd show — NOT orphaned ---
echo "--- Test 35c: Dispatch-race bead (absent from bulk list, present via bd show) is NOT orphaned ---"
setup
# The bulk hooked/in_progress/open snapshot is built from several bd calls and
# races against fresh dispatch: a just-hooked bead can be transiently absent.
# bd show (authoritative) still returns it as a live, unassigned worker. The
# orphan check must trust bd show, not the racy bulk snapshot.
RACEBEAD=$(bead_json "sa-race1" "" "Mid-dispatch race bead" "task" "false")
# hooked list EMPTY (snapshot missed it); bd show returns it live + unassigned.
create_bd_mock "[]" "[$RACEBEAD]"
POLECAT_JSON='[{"rig":"suplari_assistant","name":"rust","state":"working","issue":"sa-race1","session_running":true}]'
create_gt_mock "$POLECAT_JSON"
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  echo "Normal output"
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script)
if echo "$OUTPUT" | grep -q "ORPHAN.*rust"; then
  fail "Dispatch-race bead should NOT be orphaned (bd show confirms it is live)" "got: $OUTPUT"
else
  pass "Dispatch-race bead (snapshot-missed, show-present) is NOT orphaned"
fi

# --- Test 36: --fix nukes orphaned polecats ---
echo "--- Test 36: --fix nukes orphaned polecats ---"
setup
# No beads, but an orphaned polecat exists
create_bd_mock "[]"
POLECAT_JSON='[{"rig":"backend","name":"ghost","state":"working","issue":"aim-gone","session_running":true}]'
create_gt_mock "$POLECAT_JSON"
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  echo "Normal output"
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script --fix)
if echo "$OUTPUT" | grep -q "ORPHAN.*ghost"; then
  pass "Orphaned polecat detected with --fix"
else
  fail "Orphaned polecat detected with --fix" "got: $OUTPUT"
fi
if grep -q "polecat nuke.*ghost" "$GT_LOG" 2>/dev/null; then
  pass "gt polecat nuke called for orphan"
else
  fail "gt polecat nuke called for orphan" "gt log: $(cat "$GT_LOG" 2>/dev/null)"
fi

# --- Test 37: --fix with only stale beads, no orphans — no crash ---
echo "--- Test 37: --fix with stale beads only (no orphan crash) ---"
setup
BEAD=$(bead_json "aim-7001" "deacon" "Stale bead")
create_bd_mock "[$BEAD]"
create_gt_mock "[]"
OUTPUT=$(run_script --fix)
if echo "$OUTPUT" | grep -q "OK.*aim-7001"; then
  pass "Stale bead unhook works without orphans"
else
  fail "Stale bead unhook works without orphans" "got: $OUTPUT"
fi

# --- Test 38: --fix with only orphans, no stale beads — no crash ---
echo "--- Test 38: --fix with orphans only (no stale crash) ---"
setup
create_bd_mock "[]"
POLECAT_JSON='[{"rig":"suplari_assistant","name":"rust","state":"working","issue":"sa-xyz","session_running":true}]'
create_gt_mock "$POLECAT_JSON"
cat > "$MOCK_DIR/tmux" <<'TMUX_EOF'
#!/bin/bash
if [[ "$1" == "capture-pane" ]]; then
  echo "Normal output"
  exit 0
fi
exit 0
TMUX_EOF
chmod +x "$MOCK_DIR/tmux"
OUTPUT=$(run_script --fix)
if echo "$OUTPUT" | grep -q "ORPHAN.*rust"; then
  pass "Orphan detected in orphan-only scenario"
else
  fail "Orphan detected in orphan-only scenario" "got: $OUTPUT"
fi
# Should not crash on empty STALE_IDS
if echo "$OUTPUT" | grep -q "unbound variable"; then
  fail "No unbound variable error" "got unbound variable error"
else
  pass "No unbound variable error with empty stale list"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
