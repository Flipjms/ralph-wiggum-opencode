#!/bin/bash
# Ralph Wiggum: Before Shell Execution Hook
# - Uses EXTERNAL state (agent cannot tamper)
# - At threshold: ONLY allows git commands
# - Blocks everything else to force graceful stop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# MAIN
# =============================================================================

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract command and workspace
COMMAND=$(echo "$HOOK_INPUT" | jq -r '.command // ""')
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')

# Get external state directory (if Ralph is active)
EXT_DIR=$(get_ralph_external_dir "$WORKSPACE_ROOT")
if [[ ! -d "$EXT_DIR" ]]; then
  echo '{"permission": "allow"}'
  exit 0
fi

# =============================================================================
# HARD TERMINATION CHECK
# =============================================================================

if is_terminated "$EXT_DIR"; then
  # Only allow git commands for final commit
  if [[ "$COMMAND" =~ ^git[[:space:]]+(add|commit|push|status|diff) ]] || [[ "$COMMAND" =~ ^git$ ]]; then
    jq -n '{
      "permission": "allow",
      "agent_message": "Git command allowed. After committing, this conversation MUST end."
    }'
    exit 0
  fi
  
  jq -n \
    --arg cmd "$COMMAND" \
    '{
      "permission": "deny",
      "user_message": "🛑 Ralph: Conversation terminated. Only git commands allowed.",
      "agent_message": ("BLOCKED: " + $cmd + "\n\nThis conversation is terminated. Only git add/commit/push allowed.\n\nCommit your work and END this conversation.")
    }'
  exit 0
fi

# =============================================================================
# GET CURRENT CONTEXT STATE
# =============================================================================

TURN_COUNT=$(get_turn_count "$EXT_DIR")
ESTIMATED_TOKENS=$((TURN_COUNT * TOKENS_PER_TURN))

# =============================================================================
# AT THRESHOLD - ONLY ALLOW GIT
# =============================================================================

if [[ "$ESTIMATED_TOKENS" -ge "$THRESHOLD" ]]; then
  
  # Set terminated flag
  set_terminated "$EXT_DIR" "context_limit_shell"
  
  # Allow git commands
  if [[ "$COMMAND" =~ ^git[[:space:]]+(add|commit|push|status|diff) ]] || [[ "$COMMAND" =~ ^git$ ]]; then
    jq -n '{
      "permission": "allow",
      "agent_message": "Git command allowed. Context limit reached - commit and push, then STOP."
    }'
    exit 0
  fi
  
  # Block everything else
  jq -n \
    --argjson tokens "$ESTIMATED_TOKENS" \
    --argjson threshold "$THRESHOLD" \
    --arg cmd "$COMMAND" \
    '{
      "permission": "deny",
      "user_message": ("🛑 Ralph: Command blocked. Context limit reached."),
      "agent_message": ("BLOCKED: " + $cmd + "\n\nContext limit reached (" + ($tokens|tostring) + "/" + ($threshold|tostring) + ").\n\nONLY git commands allowed. Commit and push your work, then STOP.")
    }'
  exit 0
fi

# =============================================================================
# WARNING AT 80%
# =============================================================================

if [[ "$ESTIMATED_TOKENS" -ge "$WARN_THRESHOLD" ]]; then
  REMAINING=$((THRESHOLD - ESTIMATED_TOKENS))
  PERCENT=$((ESTIMATED_TOKENS * 100 / THRESHOLD))
  
  jq -n \
    --argjson percent "$PERCENT" \
    --argjson remaining "$REMAINING" \
    '{
      "permission": "allow",
      "agent_message": ("⚠️ Context at " + ($percent|tostring) + "%. Complete task and commit soon.")
    }'
  exit 0
fi

# =============================================================================
# NORMAL - ALLOW
# =============================================================================

echo '{"permission": "allow"}'
exit 0
