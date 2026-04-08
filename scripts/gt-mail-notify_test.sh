#!/bin/bash
# Test suite for gt-mail-notify script.
# Mocks gt, slackcli, and other external commands to verify notification logic.
#
# Usage: bash scripts/gt-mail-notify_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/gt-mail-notify"
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

write_mock() {
  local name=$1
  local content=$2
  echo "$content" > "$MOCK_DIR/$name"
  chmod +x "$MOCK_DIR/$name"
}

setup() {
  TEST_TMPDIR=$(mktemp -d)
  MOCK_DIR="$TEST_TMPDIR/mocks"
  FAKE_STATE_DIR="$TEST_TMPDIR/state"
  OUTPUT="$TEST_TMPDIR/output.txt"
  SLACK_LOG="$TEST_TMPDIR/slack.log"

  mkdir -p "$MOCK_DIR" "$FAKE_STATE_DIR"

  # Patch the script: replace STATE_DIR and PATH
  sed \
    -e "s|^export PATH=.*|export PATH=\"$MOCK_DIR:\$PATH\"|" \
    -e "s|^STATE_DIR=.*|STATE_DIR=\"$FAKE_STATE_DIR\"|" \
    "$SCRIPT" > "$TEST_TMPDIR/script-under-test"
  chmod +x "$TEST_TMPDIR/script-under-test"

  # Default date mock
  write_mock date '#!/bin/bash
if [[ "${1:-}" == "+%H:%M:%S" ]]; then
  echo "00:00:00"
else
  /usr/bin/date "$@"
fi'

  # Default jq — use real jq
  ln -sf "$(which jq)" "$MOCK_DIR/jq"

  # Default gt — empty inbox
  write_mock gt '#!/bin/bash
echo "[]"'

  # Default security — return fake bot token
  write_mock security '#!/bin/bash
echo "xoxb-fake-token"'

  # Default curl — log Slack API calls
  write_mock curl "#!/bin/bash
echo \"CALL: \$*\" >> $SLACK_LOG
exit 0"

  # Empty slack log
  touch "$SLACK_LOG"
}

run_script() {
  bash "$TEST_TMPDIR/script-under-test" > "$OUTPUT" 2>&1 || true
}

output_contains() {
  grep -qF "$1" "$OUTPUT"
}

echo "=== gt-mail-notify test suite ==="
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Test 1: No unread mail → no Slack messages sent
# ═══════════════════════════════════════════════════════════════════════════
echo "Test 1: No unread mail sends nothing"
setup

write_mock gt '#!/bin/bash
echo "[]"'

run_script

if output_contains "no unread mail"; then
  pass "reports no unread mail"
else
  fail "should report no unread mail"
fi

if [[ ! -s "$SLACK_LOG" ]]; then
  pass "no Slack messages sent"
else
  fail "should not send Slack messages when inbox is empty"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: One new message → one Slack notification
# ═══════════════════════════════════════════════════════════════════════════
echo "Test 2: New message triggers Slack notification"
setup

write_mock gt '#!/bin/bash
cat <<EOF
[
  {
    "id": "msg-001",
    "from": "overseer",
    "to": "mayor/",
    "subject": "Circuit-breaker: sa-vwwne",
    "body": "Bead sa-vwwne has been circuit-broken.",
    "timestamp": "2026-03-12T07:18:07Z",
    "read": false,
    "priority": "high",
    "type": "notification"
  }
]
EOF'

run_script

if output_contains "1 unread message"; then
  pass "reports 1 unread message"
else
  fail "should report 1 unread message"
fi

if output_contains "notified: Circuit-breaker: sa-vwwne"; then
  pass "logged notification"
else
  fail "should log the notification"
fi

if [[ -s "$SLACK_LOG" ]]; then
  pass "Slack message sent"
else
  fail "should send Slack message"
fi

# Verify the message ID was recorded
if grep -qF "msg-001" "$FAKE_STATE_DIR/mail-notify-seen.txt"; then
  pass "message ID recorded in state file"
else
  fail "should record message ID in state file"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: Already-seen message is not re-notified
# ═══════════════════════════════════════════════════════════════════════════
echo "Test 3: Already-seen message is skipped"
setup

write_mock gt '#!/bin/bash
cat <<EOF
[
  {
    "id": "msg-001",
    "from": "overseer",
    "to": "mayor/",
    "subject": "Old message",
    "body": "Already seen this.",
    "timestamp": "2026-03-12T06:00:00Z",
    "read": false,
    "priority": "normal",
    "type": "notification"
  }
]
EOF'

# Pre-populate state file with the message ID
echo "msg-001" > "$FAKE_STATE_DIR/mail-notify-seen.txt"

run_script

if [[ ! -s "$SLACK_LOG" ]]; then
  pass "no Slack message for already-seen message"
else
  fail "should not re-notify already-seen message"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: Multiple messages — only new ones notified
# ═══════════════════════════════════════════════════════════════════════════
echo "Test 4: Mix of new and seen messages"
setup

write_mock gt '#!/bin/bash
cat <<EOF
[
  {
    "id": "msg-001",
    "from": "overseer",
    "to": "mayor/",
    "subject": "Old message",
    "body": "Seen.",
    "timestamp": "2026-03-12T06:00:00Z",
    "read": false,
    "priority": "normal",
    "type": "notification"
  },
  {
    "id": "msg-002",
    "from": "gastown/witness",
    "to": "mayor/",
    "subject": "Convoy completed",
    "body": "Convoy xyz finished successfully.",
    "timestamp": "2026-03-12T07:30:00Z",
    "read": false,
    "priority": "normal",
    "type": "notification"
  }
]
EOF'

# Only msg-001 is seen
echo "msg-001" > "$FAKE_STATE_DIR/mail-notify-seen.txt"

run_script

if output_contains "2 unread message"; then
  pass "reports 2 unread messages"
else
  fail "should report 2 unread messages"
fi

if output_contains "notified: Convoy completed"; then
  pass "notified new message"
else
  fail "should notify the new message"
fi

# msg-002 should now be in state file
if grep -qF "msg-002" "$FAKE_STATE_DIR/mail-notify-seen.txt"; then
  pass "new message ID recorded"
else
  fail "should record new message ID"
fi

# Slack log should have exactly 1 invocation (only msg-002)
SLACK_COUNT=$(grep -c "^CALL:" "$SLACK_LOG")
if [[ "$SLACK_COUNT" -eq 1 ]]; then
  pass "only one Slack message sent (skipped seen)"
else
  fail "expected 1 Slack message, got $SLACK_COUNT"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Test 5: Urgent priority shows indicator
# ═══════════════════════════════════════════════════════════════════════════
echo "Test 5: Urgent priority formatting"
setup

write_mock gt '#!/bin/bash
cat <<EOF
[
  {
    "id": "msg-urgent",
    "from": "overseer",
    "to": "mayor/",
    "subject": "Critical failure",
    "body": "Something broke.",
    "timestamp": "2026-03-12T08:00:00Z",
    "read": false,
    "priority": "urgent",
    "type": "task"
  }
]
EOF'

# Capture what curl receives
write_mock curl "#!/bin/bash
echo \"CALL: \$*\" >> $SLACK_LOG
exit 0"

run_script

if grep -q "URGENT" "$SLACK_LOG"; then
  pass "urgent indicator in Slack message"
else
  fail "should include URGENT indicator for urgent priority"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Test 6: Slack failure doesn't record message as seen
# ═══════════════════════════════════════════════════════════════════════════
echo "Test 6: Slack failure prevents recording"
setup

write_mock gt '#!/bin/bash
cat <<EOF
[
  {
    "id": "msg-fail",
    "from": "overseer",
    "to": "mayor/",
    "subject": "Should retry later",
    "body": "This one fails to send.",
    "timestamp": "2026-03-12T09:00:00Z",
    "read": false,
    "priority": "normal",
    "type": "notification"
  }
]
EOF'

# curl fails
write_mock curl '#!/bin/bash
exit 1'

run_script

if output_contains "WARNING: Slack send failed"; then
  pass "logged Slack failure warning"
else
  fail "should warn about Slack send failure"
fi

# Message should NOT be in state file
if ! grep -qF "msg-fail" "$FAKE_STATE_DIR/mail-notify-seen.txt"; then
  pass "failed message not recorded as seen"
else
  fail "should not record message when Slack send fails"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Test 7: gt mail inbox failure is handled gracefully
# ═══════════════════════════════════════════════════════════════════════════
echo "Test 7: Inbox check failure handled gracefully"
setup

write_mock gt '#!/bin/bash
exit 1'

run_script

if output_contains "inbox check failed"; then
  pass "reports inbox check failure"
else
  fail "should report inbox check failure"
fi

if [[ ! -s "$SLACK_LOG" ]]; then
  pass "no Slack messages on inbox failure"
else
  fail "should not send Slack on inbox failure"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
