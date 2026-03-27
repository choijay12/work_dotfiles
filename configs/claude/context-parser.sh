#!/bin/bash
# =============================================================================
# Claude Code Context Parser — Token-Free Edition
# Uses Gemini CLI (free) or Ollama (local) to summarize your session
# No Claude API tokens consumed.
#
# Usage:
#   ./context-parser.sh              → auto-detect backend, summarize latest session
#   ./context-parser.sh --gemini     → force Gemini CLI
#   ./context-parser.sh --ollama     → force Ollama
#   ./context-parser.sh --watch      → only run if context > 70%
#   ./context-parser.sh --force      → always run
#
# Output: Dense context summary printed + saved to ~/.claude/tmp/last-summary.md
# =============================================================================

CLAUDE_DIR="$HOME/.claude"
STATE_FILE="$CLAUDE_DIR/tmp/context-state.json"
OUTPUT_FILE="$CLAUDE_DIR/tmp/last-context-summary.md"
COMPACT_THRESHOLD=70

# ── Args ──────────────────────────────────────────────────────────────────────
BACKEND="auto"
WATCH_MODE=false
FORCE_MODE=false

for arg in "$@"; do
  case "$arg" in
    --gemini) BACKEND="gemini" ;;
    --ollama) BACKEND="ollama" ;;
    --watch)  WATCH_MODE=true ;;
    --force)  FORCE_MODE=true ;;
    *.jsonl)  TRANSCRIPT_FILE="$arg" ;;
  esac
done

# ── Read context state ────────────────────────────────────────────────────────
CTX_PCT=0
MODEL="?"
COST="0"
if [ -f "$STATE_FILE" ]; then
  CTX_PCT=$(jq -r '.ctx_pct // 0' "$STATE_FILE" 2>/dev/null | cut -d. -f1)
  MODEL=$(jq -r  '.model // "?"' "$STATE_FILE" 2>/dev/null)
  COST=$(jq -r   '.cost // 0'   "$STATE_FILE" 2>/dev/null)
fi

# ── Watch mode: only run above threshold ──────────────────────────────────────
if $WATCH_MODE && ! $FORCE_MODE; then
  if [ "$CTX_PCT" -lt "$COMPACT_THRESHOLD" ]; then
    echo "Context at ${CTX_PCT}% — below threshold (${COMPACT_THRESHOLD}%). Skipping."
    exit 0
  fi
fi

# ── Find latest transcript ────────────────────────────────────────────────────
if [ -z "$TRANSCRIPT_FILE" ]; then
  TRANSCRIPT_FILE=$(find "$CLAUDE_DIR/projects" -name "*.jsonl" 2>/dev/null \
    | xargs ls -t 2>/dev/null | head -1)
fi

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
  echo "❌ No transcript found. Make sure you're running inside a Claude Code session."
  echo "   Or pass a path: $0 ~/.claude/projects/myproject/session.jsonl"
  exit 1
fi

echo "📂 Transcript: $TRANSCRIPT_FILE"
echo "📊 Context: ${CTX_PCT}% | Model: ${MODEL} | Session cost: \$${COST}"
echo ""

# ── Extract readable conversation from JSONL ──────────────────────────────────
CONVERSATION=$(python3 - "$TRANSCRIPT_FILE" << 'PYEOF'
import sys, json

path = sys.argv[1]
messages = []

with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except:
            continue

        role = entry.get("type", "")
        if role not in ("user", "assistant"):
            continue

        msg = entry.get("message", {})
        content = msg.get("content", "")

        if isinstance(content, list):
            text_parts = [
                c.get("text", "")
                for c in content
                if isinstance(c, dict) and c.get("type") == "text"
            ]
            content = " ".join(text_parts)

        content = str(content).strip()
        if not content:
            continue

        # Truncate very long messages
        if len(content) > 3000:
            content = content[:3000] + "... [truncated]"

        messages.append(f"[{role.upper()}]: {content}")

# Last 25 exchanges
print("\n\n".join(messages[-25:]))
PYEOF
)

if [ -z "$CONVERSATION" ]; then
  echo "❌ No conversation found in transcript."
  exit 1
fi

# Count messages
MSG_COUNT=$(echo "$CONVERSATION" | grep -c "^\[" || echo "?")
echo "📝 Analyzing ~${MSG_COUNT} messages..."
echo ""

# ── Prompt ────────────────────────────────────────────────────────────────────
PROMPT="You are a context manager for a coding session. Context window is ${CTX_PCT}% full.

Analyze this conversation and produce a DENSE, structured handoff summary. Be extremely concise. Use bullet points. No preamble.

## Current Task
What is being built/fixed/investigated right now?

## Key Decisions Made
Architecture choices, approaches chosen, things ruled out.

## Files Modified
Which files were changed and what was changed.

## Current Blockers
Unresolved issues, errors, open questions.

## Next Steps
What needs to happen next to complete the task.

## Critical Context
Env details, constraints, requirements that must be remembered.

SESSION TRANSCRIPT:
${CONVERSATION}

Write the summary now:"

# ── Auto-detect backend ───────────────────────────────────────────────────────
if [ "$BACKEND" = "auto" ]; then
  if command -v gemini >/dev/null 2>&1; then
    BACKEND="gemini"
    echo "🤖 Using: Gemini CLI (free)"
  elif command -v ollama >/dev/null 2>&1 && ollama list 2>/dev/null | grep -q .; then
    BACKEND="ollama"
    echo "🖥️  Using: Ollama (local)"
  else
    echo "❌ No AI backend found. Install one:"
    echo ""
    echo "  Option A — Gemini CLI (free, needs Google account):"
    echo "    npm install -g @google/gemini-cli && gemini"
    echo ""
    echo "  Option B — Ollama (local, no account needed):"
    echo "    brew install ollama && ollama pull llama3.2"
    echo ""
    exit 1
  fi
fi

# ── Run summarization ─────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo "  CONTEXT SUMMARY"
echo "═══════════════════════════════════════════════════════"
echo ""

SUMMARY=""

if [ "$BACKEND" = "gemini" ]; then
  # Gemini CLI: pipe prompt via stdin
  # gemini reads from stdin when using -p flag
  SUMMARY=$(echo "$PROMPT" | gemini 2>/dev/null)
  if [ -z "$SUMMARY" ]; then
    echo "⚠️  Gemini returned empty. Trying non-interactive mode..."
    SUMMARY=$(gemini -p "$PROMPT" 2>/dev/null)
  fi

elif [ "$BACKEND" = "ollama" ]; then
  # Pick best available model for summarization
  OLLAMA_MODEL=""
  for candidate in qwen2.5:7b deepseek-r1:8b llama3.2 llama3.1 mistral phi3 llama2; do
    if ollama list 2>/dev/null | grep -q "^${candidate}"; then
      OLLAMA_MODEL="$candidate"
      break
    fi
  done

  if [ -z "$OLLAMA_MODEL" ]; then
    OLLAMA_MODEL=$(ollama list 2>/dev/null | awk 'NR==2{print $1}')
  fi

  if [ -z "$OLLAMA_MODEL" ]; then
    echo "❌ No Ollama models found. Pull one first:"
    echo "   ollama pull llama3.2"
    exit 1
  fi

  echo "   Model: $OLLAMA_MODEL"
  SUMMARY=$(echo "$PROMPT" | ollama run "$OLLAMA_MODEL" 2>/dev/null)
fi

if [ -z "$SUMMARY" ]; then
  echo "❌ Summary generation failed. Check that your AI backend is working:"
  [ "$BACKEND" = "gemini" ] && echo "  gemini --version"
  [ "$BACKEND" = "ollama" ] && echo "  ollama run llama3.2 'hello'"
  exit 1
fi

echo "$SUMMARY"
echo ""
echo "═══════════════════════════════════════════════════════"

# ── Save summary ──────────────────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR/tmp"
cat > "$OUTPUT_FILE" << EOF
# Context Handoff Summary
_Generated: $(date)_
_Context was: ${CTX_PCT}%_
_Model used: ${BACKEND}_
_Session cost at time of summary: \$${COST}_

${SUMMARY}
EOF

echo ""
echo "✅ Summary saved to: $OUTPUT_FILE"
echo ""
echo "💡 Next steps:"
echo "   1. Review the summary above"
echo "   2. Run /compact in Claude Code (keeps conversation, condenses tokens)"
echo "      — OR —"
echo "   3. Run /clear then paste the summary as your first message (full reset)"
echo ""
