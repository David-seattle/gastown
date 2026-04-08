#!/bin/bash
# Test suite for gt-polecat-stop-guard.
# Creates realistic JSONL transcripts (matching Claude Code's actual format)
# to test all detection scenarios.
#
# Usage: bash scripts/gt-polecat-stop-guard_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/gt-polecat-stop-guard"
PASS=0
FAIL=0
TMP_DIR=""

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
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR"
  fi
  TMP_DIR=""
}
trap cleanup EXIT

setup() {
  cleanup
  TMP_DIR=$(mktemp -d)
}

# ─── JSONL helpers ────────────────────────────────────────────────────────────
# These produce lines matching Claude Code's actual JSONL format.

# Emit an assistant message with a Bash tool_use.
# $1 = tool_use id
# $2 = command string
emit_tool_use() {
  local id="$1" cmd="$2"
  cat <<JSONL
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"tool_use","id":"${id}","name":"Bash","input":{"command":"${cmd}","description":"run command","timeout":30000},"caller":{"type":"direct"}}],"stop_reason":"tool_use"}}
JSONL
}

# Emit a user message with a tool_result (content as string).
# $1 = tool_use_id (matching the tool_use)
# $2 = is_error (true/false)
# $3 = result text
emit_tool_result() {
  local id="$1" is_error="$2" text="$3"
  cat <<JSONL
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"${id}","type":"tool_result","is_error":${is_error},"content":"${text}"}]}}
JSONL
}

# Emit a user message with a tool_result (content as list of text blocks).
# $1 = tool_use_id
# $2 = is_error (true/false)
# $3 = result text
emit_tool_result_list() {
  local id="$1" is_error="$2" text="$3"
  cat <<JSONL
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"${id}","type":"tool_result","is_error":${is_error},"content":[{"type":"text","text":"${text}"}]}]}}
JSONL
}

# Emit an assistant text message (no tool use).
# $1 = text content
emit_text() {
  local text="$1"
  cat <<JSONL
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"${text}"}]}}
JSONL
}

# ─── Test runner helper ───────────────────────────────────────────────────────

# Run the stop guard with given transcript and stop_hook_active flag.
# $1 = transcript path
# $2 = stop_hook_active (true/false, default false)
run_guard() {
  local transcript="$1"
  local stop_active="${2:-false}"
  local input="{\"session_id\":\"test\",\"transcript_path\":\"${transcript}\",\"stop_hook_active\":${stop_active}}"
  echo "$input" | GT_POLECAT=1 "$SCRIPT" 2>/dev/null || true
}

is_blocked() {
  echo "$1" | grep -q '"decision".*"block"'
}

# ─── Tests ────────────────────────────────────────────────────────────────────

echo "=== gt-polecat-stop-guard tests ==="

# ── 1: Non-polecat sessions are never blocked ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_text "I finished my work." > "$transcript"
output=$(echo '{"session_id":"test","transcript_path":"'"$transcript"'","stop_hook_active":false}' | "$SCRIPT" 2>/dev/null || true)
if [[ -z "$output" ]]; then
  pass "non-polecat: allow stop (no GT_POLECAT)"
else
  fail "non-polecat: allow stop (no GT_POLECAT)" "got output: $output"
fi

# ── 2: No gt done call → block ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_abc" "bd list --json 2>&1" > "$transcript"
emit_tool_result "toolu_abc" "false" "[]" >> "$transcript"
output=$(run_guard "$transcript")
if is_blocked "$output"; then
  pass "no gt done: block"
else
  fail "no gt done: block" "expected block, got: $output"
fi

# ── 3: Successful gt done (COMPLETED) → allow ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_done1" "gt done 2>&1" > "$transcript"
emit_tool_result "toolu_done1" "false" "Pushing branch to remote...\\n✓ Branch pushed to origin\\n✓ Work submitted to merge queue (verified)" >> "$transcript"
output=$(run_guard "$transcript")
if [[ -z "$output" ]]; then
  pass "successful gt done COMPLETED: allow"
else
  fail "successful gt done COMPLETED: allow" "expected allow, got: $output"
fi

# ── 4: Successful gt done ESCALATED → allow ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_esc1" "gt done --status ESCALATED 2>&1" > "$transcript"
emit_tool_result "toolu_esc1" "false" "→ Signaling ESCALATED\\n  Issue: sa-lcro5\\n  Branch: polecat/rust/sa-lcro5" >> "$transcript"
output=$(run_guard "$transcript")
if [[ -z "$output" ]]; then
  pass "successful gt done ESCALATED: allow"
else
  fail "successful gt done ESCALATED: allow" "expected allow, got: $output"
fi

# ── 5: Successful gt done DEFERRED → allow ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_def1" "gt done --status DEFERRED 2>&1" > "$transcript"
emit_tool_result "toolu_def1" "false" "→ Signaling DEFERRED\\n  Issue: sa-93zmx" >> "$transcript"
output=$(run_guard "$transcript")
if [[ -z "$output" ]]; then
  pass "successful gt done DEFERRED: allow"
else
  fail "successful gt done DEFERRED: allow" "expected allow, got: $output"
fi

# ── 6: gt done with is_error=true → block ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_err1" "gt done 2>&1" > "$transcript"
emit_tool_result "toolu_err1" "true" "Error: exit code 1" >> "$transcript"
output=$(run_guard "$transcript")
if is_blocked "$output"; then
  pass "gt done is_error=true: block"
else
  fail "gt done is_error=true: block" "expected block, got: $output"
fi

# ── 7: gt done with "cannot complete" in output → block ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_inc1" "gt done 2>&1" > "$transcript"
emit_tool_result "toolu_inc1" "false" "cannot complete: 3/5 molecule steps incomplete\\nIncomplete steps: [sa-wisp-a sa-wisp-b sa-wisp-c]" >> "$transcript"
output=$(run_guard "$transcript")
if is_blocked "$output"; then
  pass "gt done 'cannot complete': block"
else
  fail "gt done 'cannot complete': block" "expected block, got: $output"
fi

# ── 8: No escape hatch — stop_hook_active=true still blocks without gt done ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_text "I tried but could not run gt done." > "$transcript"
output=$(run_guard "$transcript" "true")
if is_blocked "$output"; then
  pass "no escape hatch: stop_hook_active=true blocks without gt done"
else
  fail "no escape hatch: stop_hook_active=true blocks without gt done" "expected block, got: $output"
fi

# ── 9: stop_hook_active=true allows if gt done succeeded ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_retry1" "gt done 2>&1" > "$transcript"
emit_tool_result "toolu_retry1" "false" "✓ Branch pushed to origin" >> "$transcript"
output=$(run_guard "$transcript" "true")
if [[ -z "$output" ]]; then
  pass "stop_hook_active=true with successful gt done: allow"
else
  fail "stop_hook_active=true with successful gt done: allow" "expected allow, got: $output"
fi

# ── 10: First gt done fails (cannot complete), second succeeds → allow ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_fail1" "gt done 2>&1" > "$transcript"
emit_tool_result "toolu_fail1" "false" "cannot complete: 2/5 molecule steps incomplete" >> "$transcript"
emit_text "Let me finish the remaining steps first." >> "$transcript"
emit_tool_use "toolu_bd1" "bd close sa-wisp-abc 2>&1" >> "$transcript"
emit_tool_result "toolu_bd1" "false" "✓ Closed sa-wisp-abc" >> "$transcript"
emit_tool_use "toolu_pass1" "gt done 2>&1" >> "$transcript"
emit_tool_result "toolu_pass1" "false" "✓ Branch pushed to origin\\n✓ Work submitted to merge queue" >> "$transcript"
output=$(run_guard "$transcript")
if [[ -z "$output" ]]; then
  pass "first gt done fails, second succeeds: allow"
else
  fail "first gt done fails, second succeeds: allow" "expected allow, got: $output"
fi

# ── 11: Result content as list of text blocks (alternate format) → allow ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_list1" "gt done 2>&1" > "$transcript"
emit_tool_result_list "toolu_list1" "false" "✓ Branch pushed to origin" >> "$transcript"
output=$(run_guard "$transcript")
if [[ -z "$output" ]]; then
  pass "result content as list of text blocks: allow"
else
  fail "result content as list of text blocks: allow" "expected allow, got: $output"
fi

# ── 12: Missing transcript file → allow (fail-open) ──
setup
output=$(run_guard "/nonexistent/path/transcript.jsonl")
if [[ -z "$output" ]]; then
  pass "missing transcript: allow (fail-open)"
else
  fail "missing transcript: allow (fail-open)" "expected allow, got: $output"
fi

# ── 13: grep command referencing gt done does NOT match ──
# "command":"grep 'gt done'" does not start with "command":"gt done"
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_grep1" "grep 'gt done' done.go 2>&1" > "$transcript"
emit_tool_result "toolu_grep1" "false" "found some references" >> "$transcript"
output=$(run_guard "$transcript")
if is_blocked "$output"; then
  pass "grep referencing 'gt done': correctly blocks (not a gt done call)"
else
  fail "grep referencing 'gt done': correctly blocks (not a gt done call)" "expected block, got: $output"
fi

# ── 14: Realistic full session — work, then gt done with warnings → allow ──
# Mimics the actual rust polecat transcript structure
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_work1" "bd update sa-wisp-xyz --claim 2>&1" > "$transcript"
emit_tool_result "toolu_work1" "false" "✓ Updated issue: sa-wisp-xyz" >> "$transcript"
emit_tool_use "toolu_work2" "npm run build 2>&1" >> "$transcript"
emit_tool_result "toolu_work2" "false" "Build complete" >> "$transcript"
emit_tool_use "toolu_work3" "git commit -m 'Add feature' 2>&1" >> "$transcript"
emit_tool_result "toolu_work3" "false" "[polecat/rust/sa-lcro5 abc1234] Add feature" >> "$transcript"
emit_tool_use "toolu_gtdone" "gt done 2>&1" >> "$transcript"
emit_tool_result "toolu_gtdone" "false" "Pushing branch to remote...\\n✓ Branch pushed to origin\\n⚠ Warning: MR bead creation failed: parsing bd create output: invalid character\\nBranch is pushed but MR bead not created.\\nNotifying Witness...\\n⚠ Warning: could not notify witness" >> "$transcript"
output=$(run_guard "$transcript")
if [[ -z "$output" ]]; then
  pass "realistic session with gt done warnings: allow"
else
  fail "realistic session with gt done warnings: allow" "expected allow, got: $output"
fi

# ── 15: gt done inside a pipe or subshell — still matches ──
setup
transcript="$TMP_DIR/transcript.jsonl"
emit_tool_use "toolu_pipe1" "gt done --status ESCALATED 2>&1 | tee /tmp/done.log" > "$transcript"
emit_tool_result "toolu_pipe1" "false" "→ Signaling ESCALATED" >> "$transcript"
output=$(run_guard "$transcript")
if [[ -z "$output" ]]; then
  pass "gt done in pipe: allow"
else
  fail "gt done in pipe: allow" "expected allow, got: $output"
fi

# ── 16: Validate against real polecat transcript ──
# Use the actual rust polecat transcript if available
REAL_TRANSCRIPT="/Users/davidtarico/.claude/projects/-Users-davidtarico-gt-suplari-assistant-polecats-rust-suplari-assistant/ca08e47f-ed87-4999-a56c-e3901f0e42f2.jsonl"
if [[ -f "$REAL_TRANSCRIPT" ]]; then
  output=$(run_guard "$REAL_TRANSCRIPT")
  if [[ -z "$output" ]]; then
    pass "real rust polecat transcript: allow (gt done succeeded)"
  else
    fail "real rust polecat transcript: allow" "expected allow, got: $output"
  fi
else
  pass "real rust polecat transcript: skipped (file not found)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
