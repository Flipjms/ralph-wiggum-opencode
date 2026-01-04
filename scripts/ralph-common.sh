#!/bin/bash
# Ralph Wiggum: Common utilities for all hooks
# Sources this file to get consistent paths and helpers

# =============================================================================
# EXTERNAL STATE DIRECTORY
# =============================================================================
# State is stored OUTSIDE the workspace to prevent agent tampering.
# The agent cannot edit files in ~/.cursor/ralph/
#
# Structure:
#   ~/.cursor/ralph/
#     <project-hash>/
#       state.md
#       context-log.md
#       progress.md
#       guardrails.md
#       failures.md
#       edits.log
#       .terminated    # Flag file for hard termination

# Generate a stable hash for the workspace
get_project_hash() {
  local workspace="$1"
  # Use first 12 chars of sha256 of absolute path
  echo -n "$workspace" | shasum -a 256 | cut -c1-12
}

# Get the external Ralph state directory
get_ralph_external_dir() {
  local workspace="$1"
  local hash=$(get_project_hash "$workspace")
  echo "$HOME/.cursor/ralph/$hash"
}

# Initialize external state if needed
init_external_state() {
  local workspace="$1"
  local ext_dir=$(get_ralph_external_dir "$workspace")
  
  if [[ ! -d "$ext_dir" ]]; then
    mkdir -p "$ext_dir"
    
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # state.md
    cat > "$ext_dir/state.md" <<EOF
---
iteration: 0
status: initialized
workspace: $workspace
started_at: $timestamp
---

# Ralph State

Iteration 0 - Initialized, waiting for first prompt.
EOF

    # context-log.md
    cat > "$ext_dir/context-log.md" <<EOF
# Context Allocation Log (External State)

> This file is managed by hooks. Stored outside workspace to prevent tampering.

## Current Session

- Turn count: 0
- Estimated tokens: 0
- Threshold: 60000 tokens
- Status: 🟢 Healthy

## Activity Log

| Turn | Tokens | Timestamp |
|------|--------|-----------|
EOF

    # progress.md
    cat > "$ext_dir/progress.md" <<EOF
# Progress Log

> External state - survives context resets.
> Workspace: $workspace

---

## Iteration History

EOF

    # guardrails.md
    cat > "$ext_dir/guardrails.md" <<EOF
# Ralph Guardrails (Signs)

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them

### Sign: Test After Changes
- Run tests after every significant change

### Sign: Commit Checkpoints
- Commit working states before risky changes

### Sign: One Thing at a Time
- Focus on one criterion at a time

---

## Learned Signs

EOF

    # failures.md
    cat > "$ext_dir/failures.md" <<EOF
# Failure Log

## Pattern Detection

- Repeated failures: 0
- Gutter risk: Low

## Recent Failures

EOF

    # edits.log
    cat > "$ext_dir/edits.log" <<EOF
# Edit Log (External State)
# Format: TIMESTAMP | FILE | CHANGE_TYPE | CHARS | ITERATION

EOF

  fi
  
  echo "$ext_dir"
}

# =============================================================================
# CONFIGURATION
# =============================================================================

THRESHOLD=60000
WARN_PERCENT=80
WARN_THRESHOLD=$((THRESHOLD * WARN_PERCENT / 100))

# Tokens per turn estimate (agent response + tool calls + system prompt overhead)
TOKENS_PER_TURN=2500

# =============================================================================
# HELPERS
# =============================================================================

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Check if terminated flag is set
is_terminated() {
  local ext_dir="$1"
  [[ -f "$ext_dir/.terminated" ]]
}

# Set terminated flag
set_terminated() {
  local ext_dir="$1"
  local reason="${2:-context_limit}"
  echo "$reason" > "$ext_dir/.terminated"
}

# Clear terminated flag (for new iteration)
clear_terminated() {
  local ext_dir="$1"
  rm -f "$ext_dir/.terminated"
}

# Get current turn count
get_turn_count() {
  local ext_dir="$1"
  grep 'Turn count:' "$ext_dir/context-log.md" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0"
}

# Increment turn count and return estimated tokens
increment_turn() {
  local ext_dir="$1"
  local current=$(get_turn_count "$ext_dir")
  local next=$((current + 1))
  local tokens=$((next * TOKENS_PER_TURN))
  
  sedi "s/Turn count: [0-9]*/Turn count: $next/" "$ext_dir/context-log.md"
  sedi "s/Estimated tokens: [0-9]*/Estimated tokens: $tokens/" "$ext_dir/context-log.md"
  
  # Update status
  if [[ $tokens -ge $THRESHOLD ]]; then
    sedi "s/Status: .*/Status: 🔴 LIMIT REACHED/" "$ext_dir/context-log.md"
  elif [[ $tokens -ge $WARN_THRESHOLD ]]; then
    sedi "s/Status: .*/Status: 🟡 Warning - Approaching limit/" "$ext_dir/context-log.md"
  fi
  
  echo "$tokens"
}

# Get current iteration
get_iteration() {
  local ext_dir="$1"
  grep '^iteration:' "$ext_dir/state.md" 2>/dev/null | sed 's/iteration: *//' || echo "0"
}

# Increment iteration
increment_iteration() {
  local ext_dir="$1"
  local current=$(get_iteration "$ext_dir")
  local next=$((current + 1))
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  cat > "$ext_dir/state.md" <<EOF
---
iteration: $next
status: active
started_at: $timestamp
---

# Ralph State

Iteration $next - Active
EOF
  
  echo "$next"
}

# Reset context for new iteration (after cloud handoff)
reset_context() {
  local ext_dir="$1"
  local prev_iteration="${2:-0}"
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  cat > "$ext_dir/context-log.md" <<EOF
# Context Allocation Log (External State)

> Fresh context after handoff from iteration $prev_iteration

## Current Session

- Turn count: 0
- Estimated tokens: 0
- Threshold: $THRESHOLD tokens
- Status: 🟢 Fresh context

## Activity Log

| Turn | Tokens | Timestamp |
|------|--------|-----------|
EOF

  # Clear edits log for new session
  cat > "$ext_dir/edits.log" <<EOF
# Edit Log (External State)
# New session after iteration $prev_iteration handoff
# Format: TIMESTAMP | FILE | CHANGE_TYPE | CHARS | ITERATION

EOF
}
