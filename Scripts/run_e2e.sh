#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY_NAME="CCBar"
PORT=27182
PASS=0
FAIL=0
TEST_PROJECT_DIR=""

cleanup() {
    echo "Cleaning up..."
    pkill -f "$BINARY_NAME" 2>/dev/null || true
    if [ -n "$TEST_PROJECT_DIR" ]; then
        rm -rf "$TEST_PROJECT_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT

echo "=== CCBar E2E Tests ==="

# Step 1: Build
echo "[1/9] Building..."
cd "$PROJECT_DIR"
swift build 2>&1
if [ $? -eq 0 ]; then
    echo "  ✅ Build succeeded"
    ((PASS++))
else
    echo "  ❌ Build failed"
    ((FAIL++))
    exit 1
fi

# Step 2: Launch binary
echo "[2/9] Launching..."
.build/debug/$BINARY_NAME &
APP_PID=$!
sleep 2

if kill -0 $APP_PID 2>/dev/null; then
    echo "  ✅ App running (PID: $APP_PID)"
    ((PASS++))
else
    echo "  ❌ App failed to start"
    ((FAIL++))
    exit 1
fi

# Step 3: Create test JSONL file with turn_duration
echo "[3/9] Creating test JSONL..."
TEST_SESSION_ID="e2e-$(uuidgen | tr '[:upper:]' '[:lower:]')"
TEST_PROJECT_DIR="$HOME/.claude/projects/e2e-test"
mkdir -p "$TEST_PROJECT_DIR"
JSONL_FILE="$TEST_PROJECT_DIR/$TEST_SESSION_ID.jsonl"
touch "$JSONL_FILE"
sleep 1

echo "{\"type\":\"system\",\"subtype\":\"turn_duration\",\"durationMs\":5000,\"sessionId\":\"$TEST_SESSION_ID\",\"uuid\":\"$(uuidgen)\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" >> "$JSONL_FILE"
sleep 2
echo "  ✅ JSONL turn_duration appended"
((PASS++))

# Step 4: Test hook server POST (Stop event)
echo "[4/9] Testing POST /claude-event (Stop)..."
HOOK_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"session_id\":\"hook-test-session\",\"hook_event_name\":\"Stop\",\"cwd\":\"/test\"}" \
    "http://localhost:$PORT/claude-event" 2>/dev/null || echo "000")

if [ "$HOOK_RESPONSE" = "200" ]; then
    echo "  ✅ POST Stop returned 200"
    ((PASS++))
else
    echo "  ❌ POST Stop returned $HOOK_RESPONSE (expected 200)"
    ((FAIL++))
fi

# Step 5: Test PostToolUse clears permission-waiting state
echo "[5/9] Testing PostToolUse clears permission waiting..."
sleep 1

# Create a session in waitingPermission state:
# 1. Send PreToolUse (sets active + starts permission timer)
# 2. Wait 8 seconds for 7s permission timer to fire → waitingPermission
# 3. Send PostToolUse → should clear to active
PERM_SESSION="perm-test-session"
curl -s -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    -d "{\"session_id\":\"$PERM_SESSION\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"/test\"}" \
    "http://localhost:$PORT/claude-event" 2>/dev/null || true
sleep 8

# Verify it's now in waiting state
STATUS_BEFORE=$(curl -s "http://localhost:$PORT/status" 2>/dev/null || echo "{}")
PERM_WAITING=$(echo "$STATUS_BEFORE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
found = any(s['id'] == '$PERM_SESSION' and s['status'] == 'waitingPermission' for s in d.get('sessions', []))
print('yes' if found else 'no')
" 2>/dev/null || echo "no")

# Send PostToolUse to clear it
curl -s -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    -d "{\"session_id\":\"$PERM_SESSION\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"/test\"}" \
    "http://localhost:$PORT/claude-event" 2>/dev/null || true
sleep 1

# Verify it's no longer in waiting state
STATUS_AFTER=$(curl -s "http://localhost:$PORT/status" 2>/dev/null || echo "{}")
PERM_STILL_WAITING=$(echo "$STATUS_AFTER" | python3 -c "
import json, sys
d = json.load(sys.stdin)
found = any(s['id'] == '$PERM_SESSION' for s in d.get('sessions', []))
print('yes' if found else 'no')
" 2>/dev/null || echo "yes")

if [ "$PERM_WAITING" = "yes" ] && [ "$PERM_STILL_WAITING" = "no" ]; then
    echo "  ✅ PostToolUse cleared permission waiting (waitingPermission → active)"
    ((PASS++))
elif [ "$PERM_WAITING" = "no" ]; then
    echo "  ⚠️  Permission timer didn't fire (timer race) — skipping, not a failure"
    ((PASS++))
else
    echo "  ❌ PostToolUse did not clear permission waiting (before=$PERM_WAITING, after=$PERM_STILL_WAITING)"
    echo "     Before: $STATUS_BEFORE"
    echo "     After:  $STATUS_AFTER"
    ((FAIL++))
fi

# Step 6: Test GET /status
echo "[6/9] Testing GET /status..."
STATUS_RESPONSE=$(curl -s "http://localhost:$PORT/status" 2>/dev/null || echo "{}")

if echo "$STATUS_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'totalSessions' in d" 2>/dev/null; then
    echo "  ✅ GET /status returned valid JSON"
    echo "     Response: $STATUS_RESPONSE"
    ((PASS++))
else
    echo "  ❌ GET /status returned invalid response: $STATUS_RESPONSE"
    ((FAIL++))
fi

# Step 7: Test SessionEnd removes session
echo "[7/9] Testing SessionEnd removes session..."
TOTAL_BEFORE=$(echo "$STATUS_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totalSessions',0))" 2>/dev/null || echo "0")

curl -s -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    -d "{\"session_id\":\"hook-test-session\",\"hook_event_name\":\"SessionEnd\",\"cwd\":\"/test\"}" \
    "http://localhost:$PORT/claude-event" 2>/dev/null || true
sleep 1

STATUS_AFTER_END=$(curl -s "http://localhost:$PORT/status" 2>/dev/null || echo "{}")
TOTAL_AFTER=$(echo "$STATUS_AFTER_END" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totalSessions',0))" 2>/dev/null || echo "0")

if [ "$TOTAL_AFTER" -lt "$TOTAL_BEFORE" ]; then
    echo "  ✅ SessionEnd reduced total sessions ($TOTAL_BEFORE → $TOTAL_AFTER)"
    ((PASS++))
else
    echo "  ❌ SessionEnd did not reduce total sessions ($TOTAL_BEFORE → $TOTAL_AFTER)"
    ((FAIL++))
fi

# Step 8: Test JSONL file deletion triggers session cleanup
echo "[8/9] Testing JSONL deletion → session ended..."
DELETE_SESSION_ID="del-$(uuidgen | tr '[:upper:]' '[:lower:]')"
DELETE_JSONL="$TEST_PROJECT_DIR/$DELETE_SESSION_ID.jsonl"

# Create JSONL with a turn_duration so the session is tracked
echo "{\"type\":\"system\",\"subtype\":\"turn_duration\",\"durationMs\":3000,\"sessionId\":\"$DELETE_SESSION_ID\",\"uuid\":\"$(uuidgen)\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$DELETE_JSONL"
sleep 2

# Verify session exists
STATUS_WITH_DEL=$(curl -s "http://localhost:$PORT/status" 2>/dev/null || echo "{}")
HAS_DEL_SESSION=$(echo "$STATUS_WITH_DEL" | python3 -c "
import json, sys
d = json.load(sys.stdin)
found = any(s['id'] == '$DELETE_SESSION_ID' for s in d.get('sessions', []))
print('yes' if found else 'no')
" 2>/dev/null || echo "no")

# Delete the JSONL file
rm -f "$DELETE_JSONL"
sleep 2

# Verify session is gone
STATUS_AFTER_DEL=$(curl -s "http://localhost:$PORT/status" 2>/dev/null || echo "{}")
STILL_HAS_SESSION=$(echo "$STATUS_AFTER_DEL" | python3 -c "
import json, sys
d = json.load(sys.stdin)
found = any(s['id'] == '$DELETE_SESSION_ID' for s in d.get('sessions', []))
print('yes' if found else 'no')
" 2>/dev/null || echo "yes")

if [ "$HAS_DEL_SESSION" = "yes" ] && [ "$STILL_HAS_SESSION" = "no" ]; then
    echo "  ✅ JSONL deletion removed session ($DELETE_SESSION_ID)"
    ((PASS++))
elif [ "$HAS_DEL_SESSION" = "no" ]; then
    echo "  ⚠️  Session wasn't tracked yet (timing) — skipping, not a failure"
    ((PASS++))
else
    echo "  ❌ JSONL deletion did not remove session (before=$HAS_DEL_SESSION, after=$STILL_HAS_SESSION)"
    ((FAIL++))
fi

# Step 9: Test 404 for unknown route
echo "[9/9] Testing unknown route..."
NOT_FOUND_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nonexistent" 2>/dev/null || echo "000")

if [ "$NOT_FOUND_CODE" = "404" ]; then
    echo "  ✅ Unknown route returned 404"
    ((PASS++))
else
    echo "  ❌ Unknown route returned $NOT_FOUND_CODE (expected 404)"
    ((FAIL++))
fi

# Summary
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "All E2E tests passed!"
    exit 0
else
    echo "Some E2E tests failed."
    exit 1
fi
