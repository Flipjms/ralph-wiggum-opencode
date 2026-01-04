#!/bin/bash
# Ralph Wiggum: Before Read File Hook
# - Uses EXTERNAL state (agent cannot tamper)
# - Supplementary tracking (turn-based is primary)
# - Logs file reads for observability

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# MAIN
# =============================================================================

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract file info
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.file_path // .path // ""')
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
  CURRENT_ITER=$(get_iteration "$EXT_DIR")
  
  jq -n \
    --argjson iter "$CURRENT_ITER" \
    '{
      "permission": "deny",
      "user_message": ("🛑 Ralph: Conversation terminated. Start a NEW conversation."),
      "agent_message": ("STOP. This conversation has been terminated due to context limits. You cannot continue.\n\nStart a NEW conversation with: \"Continue Ralph from iteration " + ($iter|tostring) + "\"")
    }'
  exit 0
fi

# =============================================================================
# GET CURRENT CONTEXT STATE
# =============================================================================

TURN_COUNT=$(get_turn_count "$EXT_DIR")
ESTIMATED_TOKENS=$((TURN_COUNT * TOKENS_PER_TURN))

# =============================================================================
# HARD BLOCK AT THRESHOLD
# =============================================================================

if [[ "$ESTIMATED_TOKENS" -ge "$THRESHOLD" ]]; then
  set_terminated "$EXT_DIR" "context_limit_file_read"
  
  jq -n \
    --argjson tokens "$ESTIMATED_TOKENS" \
    --argjson threshold "$THRESHOLD" \
    '{
      "permission": "deny",
      "user_message": ("🛑 Ralph: Context limit reached. File read blocked."),
      "agent_message": ("STOP. Context limit reached (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens).\n\nYou MUST commit your work and end this conversation. A Cloud Agent will continue.")
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
      "agent_message": ("⚠️ Context at " + ($percent|tostring) + "%. ~" + ($remaining|tostring) + " tokens remaining. Complete current task and commit.")
    }'
  exit 0
fi

# =============================================================================
# NORMAL - ALLOW
# =============================================================================

echo '{"permission": "allow"}'
exit 0
