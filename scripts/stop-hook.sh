#!/bin/bash
# Ralph Wiggum: Stop Hook
# - Uses EXTERNAL state (agent cannot tamper)
# - Forces commit of any uncommitted work
# - Spawns Cloud Agent if context limit was reached
# - Sets terminated flag to block further prompts
#
# Core Ralph principle: Tests determine completion, not the agent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# MAIN
# =============================================================================

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract info
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')
STOP_STATUS=$(echo "$HOOK_INPUT" | jq -r '.status // "unknown"')
LOOP_COUNT=$(echo "$HOOK_INPUT" | jq -r '.loop_count // 0')

TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"

# If Ralph isn't active, allow exit
if [[ ! -f "$TASK_FILE" ]]; then
  echo '{}'
  exit 0
fi

# Get external state directory
EXT_DIR=$(get_ralph_external_dir "$WORKSPACE_ROOT")
if [[ ! -d "$EXT_DIR" ]]; then
  echo '{}'
  exit 0
fi

# =============================================================================
# GET CURRENT STATE
# =============================================================================

CURRENT_ITERATION=$(get_iteration "$EXT_DIR")
TURN_COUNT=$(get_turn_count "$EXT_DIR")
ESTIMATED_TOKENS=$((TURN_COUNT * TOKENS_PER_TURN))
UNCHECKED_CRITERIA=$(grep -c '\- \[ \]' "$TASK_FILE" 2>/dev/null || echo "0")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Get test command
TEST_COMMAND=""
if grep -q "^test_command:" "$TASK_FILE" 2>/dev/null; then
  TEST_COMMAND=$(grep "^test_command:" "$TASK_FILE" | sed 's/test_command: *//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | xargs)
fi

# =============================================================================
# CLOUD MODE CHECK
# =============================================================================

get_api_key() {
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    echo "$CURSOR_API_KEY"
    return 0
  fi
  
  local project_config="$WORKSPACE_ROOT/.cursor/ralph-config.json"
  if [[ -f "$project_config" ]]; then
    local key=$(jq -r '.cursor_api_key // empty' "$project_config" 2>/dev/null)
    if [[ -n "$key" ]]; then echo "$key"; return 0; fi
  fi
  
  local global_config="$HOME/.cursor/ralph-config.json"
  if [[ -f "$global_config" ]]; then
    local key=$(jq -r '.cursor_api_key // empty' "$global_config" 2>/dev/null)
    if [[ -n "$key" ]]; then echo "$key"; return 0; fi
  fi
  
  return 1
}

is_cloud_enabled() {
  get_api_key > /dev/null 2>&1
}

# =============================================================================
# FORCE COMMIT ANY UNCOMMITTED WORK
# =============================================================================

force_commit() {
  cd "$WORKSPACE_ROOT"
  
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    echo "Committing work..." >&2
    git add -A 2>/dev/null || true
    git commit -m "ralph: checkpoint at iteration $CURRENT_ITERATION (turn $TURN_COUNT, ~$ESTIMATED_TOKENS tokens)" 2>/dev/null || true
    git push origin HEAD 2>/dev/null || true
    return 0
  fi
  return 1
}

# =============================================================================
# RUN TESTS
# =============================================================================

run_tests() {
  local test_cmd="$1"
  
  if [[ -z "$test_cmd" ]]; then
    echo "NO_TEST_COMMAND"
    return 0
  fi
  
  cd "$WORKSPACE_ROOT"
  
  set +e
  TEST_OUTPUT=$(eval "$test_cmd" 2>&1)
  TEST_EXIT_CODE=$?
  set -e
  
  echo "$TEST_OUTPUT" > "$EXT_DIR/.last_test_output"
  
  if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    echo "PASS"
  else
    echo "FAIL:$TEST_EXIT_CODE"
  fi
}

# =============================================================================
# LOG THE STOP EVENT
# =============================================================================

cat >> "$EXT_DIR/progress.md" <<EOF

---

### Agent Stopped (Iteration $CURRENT_ITERATION)
- Time: $TIMESTAMP
- Status: $STOP_STATUS
- Turns: $TURN_COUNT (~$ESTIMATED_TOKENS tokens)
- Criteria remaining: $UNCHECKED_CRITERIA

EOF

# =============================================================================
# CASE 1: Already terminated (shouldn't happen, but handle gracefully)
# =============================================================================

if is_terminated "$EXT_DIR"; then
  echo '{}' 
  exit 0
fi

# =============================================================================
# CASE 2: Context limit reached - handoff to Cloud Agent
# =============================================================================

if [[ "$ESTIMATED_TOKENS" -ge "$THRESHOLD" ]]; then
  
  # Force commit FIRST
  force_commit
  
  # Set terminated flag to prevent further prompts
  set_terminated "$EXT_DIR" "context_limit_$ESTIMATED_TOKENS"
  
  cat >> "$EXT_DIR/progress.md" <<EOF
**Context limit reached ($ESTIMATED_TOKENS tokens). Initiating handoff...**

EOF
  
  # Prepare for next iteration
  NEXT_ITERATION=$((CURRENT_ITERATION + 1))
  
  # Update state for next agent
  cat > "$EXT_DIR/state.md" <<EOF
---
iteration: $NEXT_ITERATION
status: handoff_pending
started_at: $TIMESTAMP
previous_context: $ESTIMATED_TOKENS
---

# Ralph State

Iteration $NEXT_ITERATION - Awaiting fresh context (handoff from iteration $CURRENT_ITERATION)
EOF

  # Reset context log for next agent
  reset_context "$EXT_DIR" "$CURRENT_ITERATION"
  
  # Try Cloud Mode
  if is_cloud_enabled; then
    if "$SCRIPT_DIR/spawn-cloud-agent.sh" "$WORKSPACE_ROOT" 2>&1; then
      # Clear terminated flag since cloud agent will take over
      clear_terminated "$EXT_DIR"
      
      jq -n \
        --argjson iter "$NEXT_ITERATION" \
        '{
          "followup_message": ("🌩️ Context limit reached. Cloud Agent spawned for iteration " + ($iter|tostring) + ". This conversation is complete.")
        }'
      exit 0
    else
      echo "Cloud spawn failed, staying in local mode" >&2
    fi
  fi
  
  # Local Mode - tell user to start new conversation
  jq -n \
    --argjson iter "$NEXT_ITERATION" \
    '{
      "followup_message": ("⚠️ Context limit reached. Start a NEW conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\"")
    }'
  exit 0
fi

# =============================================================================
# CASE 3: All criteria checked - verify with tests
# =============================================================================

if [[ "$UNCHECKED_CRITERIA" -eq 0 ]]; then
  
  if [[ -n "$TEST_COMMAND" ]]; then
    TEST_RESULT=$(run_tests "$TEST_COMMAND")
    TEST_OUTPUT=$(cat "$EXT_DIR/.last_test_output" 2>/dev/null || echo "")
    
    if [[ "$TEST_RESULT" == "PASS" ]]; then
      force_commit
      
      cat >> "$EXT_DIR/progress.md" <<EOF
## 🎉 RALPH COMPLETE (Tests Verified)
- Test command: $TEST_COMMAND
- Result: ✅ PASSED

\`\`\`
$TEST_OUTPUT
\`\`\`

EOF
      
      cat > "$EXT_DIR/state.md" <<EOF
---
iteration: $CURRENT_ITERATION
status: complete
completed_at: $TIMESTAMP
---

# Ralph State

✅ Task completed - verified by tests.
EOF
      
      jq -n '{
        "followup_message": "🎉 Ralph task COMPLETE! All criteria satisfied and tests pass."
      }'
      exit 0
      
    else
      # Tests failed
      cat >> "$EXT_DIR/progress.md" <<EOF
### ❌ Tests FAILED
- Test command: $TEST_COMMAND
- Output:
\`\`\`
$TEST_OUTPUT
\`\`\`

**Task is NOT complete. Tests must pass.**

EOF
      
      jq -n \
        --arg output "$TEST_OUTPUT" \
        '{
          "followup_message": ("⚠️ Criteria checked but tests FAIL. Fix the issues.\n\nTest output:\n" + $output)
        }'
      exit 0
    fi
    
  else
    # No test command
    force_commit
    
    cat > "$EXT_DIR/state.md" <<EOF
---
iteration: $CURRENT_ITERATION
status: complete
completed_at: $TIMESTAMP
---

# Ralph State

✅ Task completed (no test verification).
EOF
    
    jq -n '{
      "followup_message": "🎉 Ralph task complete (no test command for verification)."
    }'
    exit 0
  fi
fi

# =============================================================================
# CASE 4: Normal stop with work remaining
# =============================================================================

force_commit

jq -n \
  --argjson remaining "$UNCHECKED_CRITERIA" \
  '{
    "followup_message": ("Agent stopped with " + ($remaining|tostring) + " criteria remaining. Continue working.")
  }'

exit 0
