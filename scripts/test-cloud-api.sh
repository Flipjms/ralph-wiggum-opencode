#!/bin/bash
# Ralph Wiggum: Cloud Agent API Test
# Tests connectivity to Cursor Cloud Agent API
#
# Usage: 
#   CURSOR_API_KEY='your-key' ./test-cloud-api.sh
#   or configure in ~/.cursor/ralph-config.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"

echo "═══════════════════════════════════════════════════════════════════"
echo "🧪 Ralph: Cloud Agent API Test"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# =============================================================================
# GET API KEY
# =============================================================================

get_api_key() {
  # Check environment first
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    echo "$CURSOR_API_KEY"
    return 0
  fi
  
  # Check project config
  local project_config="$WORKSPACE_ROOT/.cursor/ralph-config.json"
  if [[ -f "$project_config" ]]; then
    local key=$(jq -r '.cursor_api_key // empty' "$project_config" 2>/dev/null || echo "")
    if [[ -n "$key" ]]; then
      echo "$key"
      return 0
    fi
  fi
  
  # Check global config
  local global_config="$HOME/.cursor/ralph-config.json"
  if [[ -f "$global_config" ]]; then
    local key=$(jq -r '.cursor_api_key // empty' "$global_config" 2>/dev/null || echo "")
    if [[ -n "$key" ]]; then
      echo "$key"
      return 0
    fi
  fi
  
  return 1
}

API_KEY=$(get_api_key) || {
  echo "❌ No API key found."
  echo ""
  echo "Configure your key via one of:"
  echo "  1. Environment: export CURSOR_API_KEY='your-key'"
  echo "  2. Project:     .cursor/ralph-config.json"
  echo "  3. Global:      ~/.cursor/ralph-config.json"
  echo ""
  echo "Get your key from: https://cursor.com/dashboard?tab=integrations"
  exit 1
}

echo "✓ API key found (${API_KEY:0:8}...)"
echo ""

# =============================================================================
# TEST 1: Basic API Connectivity
# =============================================================================

echo "Test 1: API Connectivity"
echo "------------------------"

# Try a simple authenticated request
# The agents endpoint should return something even if we don't create an agent
RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "https://api.cursor.com/v0/agents" \
  -u "$API_KEY:" \
  -H "Content-Type: application/json" 2>&1) || true

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "201" ]]; then
  echo "✓ API responded with HTTP $HTTP_CODE"
  echo "  Response: $(echo "$BODY" | head -c 200)..."
elif [[ "$HTTP_CODE" == "401" ]]; then
  echo "❌ API returned 401 Unauthorized"
  echo "  Your API key may be invalid or expired."
  echo "  Get a new key from: https://cursor.com/dashboard?tab=integrations"
  exit 1
elif [[ "$HTTP_CODE" == "404" ]]; then
  echo "⚠️  API returned 404 - endpoint may not exist or require different path"
  echo "  Response: $BODY"
  echo ""
  echo "  Trying alternative: list agents..."
else
  echo "⚠️  API returned HTTP $HTTP_CODE"
  echo "  Response: $BODY"
fi

echo ""

# =============================================================================
# TEST 2: Create a Test Agent (dry run style)
# =============================================================================

echo "Test 2: Agent Creation Capability"
echo "----------------------------------"

# We'll use a public test repo to verify agent creation works
# Using a minimal prompt that shouldn't actually do much

# First, check available models
echo "Checking available models..."
MODELS_RESPONSE=$(curl -s -X GET "https://api.cursor.com/v0/models" -u "$API_KEY:" 2>&1)
echo "  Available models: $(echo "$MODELS_RESPONSE" | jq -r '.models // ["unknown"] | join(", ")')"
echo ""

# Use an available model (pick first from the list)
SELECTED_MODEL=$(echo "$MODELS_RESPONSE" | jq -r '.models[0] // "gpt-5.2"')
echo "  Using model: $SELECTED_MODEL"
echo ""

TEST_PAYLOAD=$(jq -n --arg model "$SELECTED_MODEL" '{
  "prompt": { "text": "Echo hello world and stop immediately. This is a test." },
  "source": {
    "repository": "https://github.com/octocat/Hello-World",
    "ref": "main"
  },
  "target": {
    "branchName": "ralph-api-test-DELETE-ME",
    "autoCreatePr": false
  },
  "model": $model
}')

# Use a known accessible repository 
# (The /v0/repositories endpoint has strict rate limits)
FIRST_REPO="https://github.com/agrimsingh/26factorial"

echo "Attempting to create test agent..."
echo "  Repository: $FIRST_REPO"
echo "  Branch: ralph-api-test-DELETE-ME"
echo ""

# Update the payload with user's repo
TEST_PAYLOAD=$(jq -n --arg model "$SELECTED_MODEL" --arg repo "$FIRST_REPO" '{
  "prompt": { "text": "Just say hello and stop. This is a 5-second test." },
  "source": {
    "repository": $repo
  },
  "target": {
    "branchName": "ralph-api-test-DELETE-ME",
    "autoCreatePr": false
  },
  "model": $model
}')

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "https://api.cursor.com/v0/agents" \
  -u "$API_KEY:" \
  -H "Content-Type: application/json" \
  -d "$TEST_PAYLOAD" 2>&1) || true

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "201" ]]; then
  AGENT_ID=$(echo "$BODY" | jq -r '.id // empty')
  AGENT_URL=$(echo "$BODY" | jq -r '.target.url // empty')
  
  echo "✓ Agent created successfully!"
  echo "  Agent ID: $AGENT_ID"
  echo "  URL: $AGENT_URL"
  echo ""
  echo "  Full response:"
  echo "$BODY" | jq .
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "✅ Cloud Agent API is working!"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "Note: A test agent was created on octocat/Hello-World."
  echo "You can ignore the ralph-api-test-DELETE-ME branch."
  
elif [[ "$HTTP_CODE" == "401" ]]; then
  echo "❌ Authentication failed (HTTP 401)"
  echo "  Response: $BODY"
  exit 1
  
elif [[ "$HTTP_CODE" == "403" ]]; then
  echo "❌ Access forbidden (HTTP 403)"
  echo "  Your API key may not have agent creation permissions."
  echo "  Response: $BODY"
  exit 1
  
elif [[ "$HTTP_CODE" == "422" ]]; then
  echo "⚠️  Validation error (HTTP 422)"
  echo "  The API request format may have changed."
  echo "  Response: $BODY"
  exit 1
  
else
  echo "❌ Unexpected response (HTTP $HTTP_CODE)"
  echo "  Response: $BODY"
  exit 1
fi
