# Ralph Wiggum for Cursor

An implementation of [Geoffrey Huntley's Ralph Wiggum technique](https://ghuntley.com/ralph/) for Cursor, enabling autonomous AI development with deliberate context management.

> "That's the beauty of Ralph - the technique is deterministically bad in an undeterministic world."

## What is Ralph?

Ralph is a technique for autonomous AI development. In its purest form, it's a loop:

```bash
while :; do cat PROMPT.md | agent ; done
```

The same prompt is fed repeatedly to an AI agent. Progress persists in **files and git**, not in the LLM's context window. When context fills up, you get a fresh agent with fresh context.

## Prerequisites

Before using Ralph, you need:

| Requirement | Check | How to Set Up |
|-------------|-------|---------------|
| **Git repo** | `git status` works | `git init` |
| **GitHub remote** | `git remote -v` shows origin | Push to GitHub first |
| **GitHub connected to Cursor** | Can use Cloud Agents in Cursor | Cursor Settings → GitHub → Connect |
| **Cursor API Key** | For Cloud Agent API | [cursor.com/dashboard](https://cursor.com/dashboard?tab=integrations) |

**Important:** Cloud Agents work on **existing GitHub repositories**. Ralph does not create repos for you.

## Two Modes

### 🌩️ Cloud Loop (Recommended)

**Fully autonomous.** Spawns Cloud Agents, watches them, chains new ones until task is complete.

```bash
./scripts/ralph-loop.sh
```

Best for: Fire-and-forget, overnight runs, "true Ralph"

### 💻 Local + Handoff

Work in Cursor normally. When context fills up, hooks automatically spawn a Cloud Agent to continue.

Best for: Interactive work where you want hands-on control initially

---

## Quick Start (Cloud Loop)

### 1. Set Up Your Project

```bash
# Must be a git repo with GitHub remote
cd your-project
git status          # Should work
git remote -v       # Should show github.com

# If not set up yet:
git init
git add -A
git commit -m "initial"
gh repo create my-project --private --source=. --push
# Or create repo on GitHub and: git remote add origin https://github.com/you/repo && git push -u origin main
```

### 2. Install Ralph

```bash
curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash
```

This creates:
```
your-project/
├── .cursor/
│   ├── hooks.json              # Cursor hooks config
│   └── ralph-scripts/          # All Ralph scripts
├── .ralph/                     # Synced state (for Cloud Agents)
│   ├── progress.md
│   └── guardrails.md
└── RALPH_TASK.md               # Your task definition

~/.cursor/ralph/<project-hash>/ # External state (tamper-proof)
├── state.md
├── context-log.md
├── progress.md
├── guardrails.md
└── ...
```

### 3. Configure Cursor API Key

Get your key from [cursor.com/dashboard](https://cursor.com/dashboard?tab=integrations)

```bash
# Option A: Environment variable
export CURSOR_API_KEY='key_xxx'

# Option B: Config file (recommended - persists across sessions)
cat > ~/.cursor/ralph-config.json << 'EOF'
{
  "cursor_api_key": "key_xxx"
}
EOF
```

### 4. Define Your Task

Edit `RALPH_TASK.md`:

```markdown
---
task: Build a REST API
test_command: "npm test"
---

# Task: REST API

## Success Criteria

1. [ ] GET /health returns 200
2. [ ] POST /users creates a user
3. [ ] Tests pass
```

**Important:** Use `[ ]` checkboxes. Ralph tracks completion by counting unchecked boxes.

### 5. Test API Connection (Optional)

```bash
./.cursor/ralph-scripts/test-cloud-api.sh
```

### 6. Start the Loop

```bash
./.cursor/ralph-scripts/ralph-loop.sh
```

Ralph will:
1. Show task summary and ask for confirmation
2. Commit any uncommitted work
3. Spawn Cloud Agent 1
4. Poll status every 30s
5. When agent finishes, check if task is complete
6. If incomplete, spawn another agent
7. Repeat until all `[ ]` are `[x]` (or max 10 agents)

---

## Quick Start (Local + Handoff)

### 1-4. Same as Above

Install, configure API key, define task.

### 5. Restart Cursor

Hooks only load on Cursor startup.

### 6. Work in Cursor

Start a conversation:
> "Work on the Ralph task in RALPH_TASK.md"

### 7. Automatic Handoff

When context fills up (~60k tokens):
- Hooks block further prompts
- Work is committed and pushed
- Cloud Agent is spawned automatically
- Message tells you to start a new conversation (or watch the cloud agent)

To watch the spawned agent:
```bash
./.cursor/ralph-scripts/watch-cloud-agent.sh bc-xxx-agent-id
```

---

## File Locations

| Location | Purpose | Who Uses It |
|----------|---------|-------------|
| `RALPH_TASK.md` | Task definition | You define, agents read |
| `.ralph/` | Synced state | Cloud Agents read this |
| `~/.cursor/ralph/<hash>/` | External state | Hooks read/write (tamper-proof) |
| `~/.cursor/ralph-config.json` | API keys | Scripts read |
| `.cursor/hooks.json` | Hook config | Cursor reads |
| `.cursor/ralph-scripts/` | Scripts | You run / hooks run |

---

## Configuration

### `~/.cursor/ralph-config.json`

```json
{
  "cursor_api_key": "key_xxx",
  "github_token": "ghp_xxx"
}
```

| Key | Required | Purpose |
|-----|----------|---------|
| `cursor_api_key` | **Yes** for Cloud | Cloud Agent API authentication |
| `github_token` | No | Optional: for local git push auth |

### `RALPH_TASK.md` Format

```markdown
---
task: Short description
test_command: "npm test"           # Optional: verify completion
max_iterations: 20                 # Optional: safety limit
---

# Task Title

## Success Criteria

1. [ ] First thing to complete
2. [ ] Second thing to complete
3. [ ] Third thing to complete
```

---

## Commands

| Command | Description |
|---------|-------------|
| `./.cursor/ralph-scripts/ralph-loop.sh` | Start autonomous cloud loop |
| `./.cursor/ralph-scripts/watch-cloud-agent.sh <id>` | Watch and chain a specific agent |
| `./.cursor/ralph-scripts/spawn-cloud-agent.sh` | Manually spawn a cloud agent |
| `./.cursor/ralph-scripts/test-cloud-api.sh` | Test API connectivity |

---

## How It Works

### The malloc/free Problem

LLM context is like memory:
- Reading files, tool outputs, conversation = `malloc()`
- **There is no `free()`**
- Only way to free: start a new conversation/agent

### Cloud Loop Flow

```
ralph-loop.sh
     │
     ├─► Commit & push local changes
     │
     ├─► Spawn Cloud Agent 1
     │        │
     │        ▼
     │   Agent works (fresh context)
     │        │
     │        ▼
     │   Agent finishes
     │        │
     │   ┌────┴────────┐
     │   │             │
     │   ▼             ▼
     │ All [x]?      Still [ ]?
     │   │             │
     │   ▼             ▼
     │  Done!     Spawn Agent 2
     │                 │
     └─────────────────┘ (repeat up to 10x)
```

### Local Handoff Flow

```
You in Cursor ──► work ──► ~60k tokens ──► hooks block
                                               │
                                               ▼
                                         commit & push
                                               │
                                               ▼
                                        spawn Cloud Agent
                                               │
                                               ▼
                                    (watch with watch-cloud-agent.sh)
```

---

## Guardrails (Signs)

When Ralph makes mistakes, add "signs" to `.ralph/guardrails.md`:

```markdown
### Sign: Validate Input
- **Trigger**: When accepting user input
- **Instruction**: Always validate and sanitize
- **Added after**: Iteration 3 - SQL injection
```

Signs are synced to cloud agents to prevent repeated mistakes.

---

## Monitoring Cloud Agents

```bash
# Check status
curl -s "https://api.cursor.com/v0/agents/<id>" \
  -u "$CURSOR_API_KEY:" | jq '{status, name, summary}'

# View conversation
curl -s "https://api.cursor.com/v0/agents/<id>/conversation" \
  -u "$CURSOR_API_KEY:" | jq '.messages[-3:]'

# List all your agents
curl -s "https://api.cursor.com/v0/agents" \
  -u "$CURSOR_API_KEY:" | jq '.agents[] | {id, status, name}'
```

Or visit: `https://cursor.com/agents?id=<agent-id>`

---

## Troubleshooting

### "Could not determine repository URL"

Your project needs a GitHub remote:
```bash
git remote add origin https://github.com/you/repo
git push -u origin main
```

### "Branch does not exist"

The source branch must exist on GitHub. Push your current branch:
```bash
git push origin HEAD
```

### "No API key configured"

```bash
echo '{"cursor_api_key": "key_xxx"}' > ~/.cursor/ralph-config.json
```

### Hooks not firing in Cursor

1. Check `.cursor/hooks.json` exists
2. Restart Cursor completely
3. Check Cursor Settings → Hooks tab for errors

### Cloud Agent can't access repo

Make sure GitHub is connected to Cursor:
1. Cursor Settings → GitHub
2. Connect your GitHub account
3. Grant access to the repository

---

## Learn More

- [Original Ralph technique](https://ghuntley.com/ralph/) - Geoffrey Huntley
- [Context as memory](https://ghuntley.com/allocations/) - The malloc/free metaphor
- [Cursor Hooks docs](https://cursor.com/docs/agent/hooks)
- [Cloud Agents API](https://cursor.com/docs/cloud-agent/api/endpoints)

## License

MIT
