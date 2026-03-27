# Claude Code Smart Context Manager

A complete setup for Claude Code CLI that shows live context, rate limits, and
auto-warns before compaction — including an AI-powered context summarizer.

---

## What you get

```
Sonnet 4.6 │ ctx ▓▓▓▓░░░░░░ 42% │ 5h↺2h0m ▓▓░░░░░░░░ 23% │ 7d↺3d0h ▓▓▓▓░░░░░░ 41% │ $0.0312 │ main ~2
```

| Component | What it does |
|---|---|
| **statusline.sh** | Live bar in Claude Code showing ctx %, 5h window, weekly limit, cost, git branch |
| **hooks/context-display.sh** | Injects warnings into Claude's context at 60/75/83% — also tells Claude to be careful |
| **ai-context-parser.js** | Calls Claude API to analyze your transcript and produce a dense summary for clean restarts |
| **install.sh** | One-command setup |

---

## Install

```bash
git clone <this-repo> claude-code-setup
cd claude-code-setup
bash install.sh
```

Then **restart Claude Code**.

### Prerequisites

| Tool | Install |
|---|---|
| `jq` | `brew install jq` / `apt install jq` |
| `node` | https://nodejs.org |
| `curl` | Usually pre-installed |

---

## How the context tracking works

Claude Code natively sends a JSON payload to your statusline script on every interaction. This includes:

- `context_window.used_percentage` — how full your context is (0–100)
- `rate_limits.five_hour.used_percentage` — 5-hour rolling window usage
- `rate_limits.seven_day.used_percentage` — weekly usage
- `rate_limits.*.resets_at` — Unix timestamp of next reset
- `cost.total_cost_usd` — session cost so far

The statusline script reads this, builds color-coded bars, and saves a snapshot
to `~/.claude/tmp/context-state.json` for the hook to read.

> **Note:** Rate limit data (5h/7d) only appears for Pro/Max/claude.ai subscribers
> with the correct OAuth scopes. If bars are missing, see Troubleshooting below.

---

## Color coding

| Color | Meaning |
|---|---|
| 🟢 Green | < 50% used — all good |
| 🟡 Yellow | 50–80% — watch it |
| 🔴 Red | > 80% — act soon |

Claude Code auto-compacts at ~83% context. The hook warns you progressively before that.

---

## The hook: how it talks to Claude

The `UserPromptSubmit` hook runs before every message you send. It reads the saved
context state and injects text into Claude's context:

| Context % | What happens |
|---|---|
| < 60% | Silent — no injection |
| 60–74% | Light info note injected into context |
| 75–82% | Warning advisory injected — Claude is told to be careful |
| ≥ 83% | Critical alert injected + stderr message to user UI |

This means Claude itself knows how full the context is and can be more careful
about verbosity, or you can ask it to summarize.

---

## AI Context Parser

Analyzes your current session transcript and produces a dense summary.
Useful before `/clear` to preserve important context:

```bash
# Run manually anytime
node ~/.claude/ai-context-parser.js --force

# Only run if context > 70% (for scripts/hooks)
node ~/.claude/ai-context-parser.js --watch

# Point at a specific transcript
node ~/.claude/ai-context-parser.js ~/.claude/projects/myproject/session.jsonl
```

The summary is also saved to `~/.claude/tmp/last-context-summary.md`.

**Workflow:**
1. Context hits 75% → hook warns you
2. Run `node ~/.claude/ai-context-parser.js --force`
3. Copy the summary
4. Run `/clear` in Claude Code
5. Paste summary as first message → fresh context, no lost state

---

## Useful Claude Code commands

| Command | What it does |
|---|---|
| `/compact` | Built-in context compression (run at ~75%) |
| `/clear` | Start fresh session |
| `/context` | Show context usage |
| `/usage` | Show rate limit status |
| `/statusline <description>` | Generate a statusline from natural language |

---

## Troubleshooting

### Rate limit bars (5h/7d) not showing

**macOS:** Check your OAuth scopes:
```bash
security find-generic-password -s "Claude Code-credentials" -w | jq '.claudeAiOauth.scopes'
# Should show: ["user:inference", "user:profile"]
```

If `user:profile` is missing:
```bash
security delete-generic-password -s "Claude Code-credentials"
# Then quit ALL Claude Code instances and restart (triggers fresh OAuth)
```

**Linux:** Check `~/.claude/.credentials.json` exists and is populated.

### Statusline not appearing

```bash
# Test manually
echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42}}' \
  | bash ~/.claude/statusline.sh
```

- Check `jq` is installed: `which jq`
- Check script is executable: `ls -la ~/.claude/statusline.sh`
- Check settings.json path is correct

### Hook not triggering

- Ensure `~/.claude/hooks/context-display.sh` is executable (`chmod +x`)
- Check `~/.claude/settings.json` has the `hooks` block
- Run `claude` from a trusted workspace (workspace trust must be accepted)

---

## File layout after install

```
~/.claude/
  statusline.sh              ← main statusline script
  ai-context-parser.js       ← AI context summarizer
  settings.json              ← Claude Code config (statusLine + hooks)
  hooks/
    context-display.sh       ← UserPromptSubmit hook
  tmp/
    context-state.json       ← live state snapshot (written by statusline)
    last-context-summary.md  ← last AI summary output
```
