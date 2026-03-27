#!/bin/bash
# =============================================================================
# Claude Code Smart Context Setup — Install Script
# =============================================================================
# Installs:
#   1. statusline.sh      → live statusbar with context, 5h, weekly, cost, git
#   2. hooks/context-display.sh → auto-warns Claude + user at 60/75/83% ctx
#   3. context-parser.sh → AI-powered context summarizer (requires Node.js)
#   4. settings.json      → wires everything into Claude Code
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
TMP_DIR="$CLAUDE_DIR/tmp"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "═══════════════════════════════════════════════════════"
echo "  Claude Code Smart Context Setup"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Prerequisites check ───────────────────────────────────────────────────────
echo "🔍 Checking prerequisites..."

MISSING=""
command -v jq    >/dev/null 2>&1 || MISSING="$MISSING jq"
command -v node  >/dev/null 2>&1 || MISSING="$MISSING node"
command -v curl  >/dev/null 2>&1 || MISSING="$MISSING curl"

if [ -n "$MISSING" ]; then
  echo "⚠️  Missing tools:$MISSING"
  echo ""
  echo "Install them:"
  echo "  macOS:  brew install$MISSING"
  echo "  Ubuntu: apt install$MISSING"
  echo ""
  echo "Continuing anyway (some features may not work)..."
else
  echo "✅ All prerequisites found (jq, node, curl)"
fi

# ── Create directories ────────────────────────────────────────────────────────
echo ""
echo "📁 Creating directories..."
mkdir -p "$HOOKS_DIR" "$TMP_DIR"
echo "  ✅ $HOOKS_DIR"
echo "  ✅ $TMP_DIR"

# ── Install statusline ─────────────────────────────────────────────────────────
echo ""
echo "📊 Installing statusline script..."
cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"
echo "  ✅ $CLAUDE_DIR/statusline.sh"

# ── Install hook ──────────────────────────────────────────────────────────────
echo ""
echo "🪝 Installing context display hook..."
cp "$SCRIPT_DIR/hooks/context-display.sh" "$HOOKS_DIR/context-display.sh"
chmod +x "$HOOKS_DIR/context-display.sh"
echo "  ✅ $HOOKS_DIR/context-display.sh"

# ── Install AI parser ─────────────────────────────────────────────────────────
echo ""
echo "🤖 Installing AI context parser..."
cp "$SCRIPT_DIR/context-parser.sh" "$CLAUDE_DIR/context-parser.sh"
chmod +x "$CLAUDE_DIR/context-parser.sh"
echo "  ✅ $CLAUDE_DIR/context-parser.sh"

# ── Merge settings.json ───────────────────────────────────────────────────────
echo ""
echo "⚙️  Configuring settings.json..."

NEW_SETTINGS='{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  },
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/context-display.sh"
          }
        ]
      }
    ]
  }
}'

if [ -f "$SETTINGS" ]; then
  echo "  Found existing settings.json — merging..."
  # Merge: preserve existing keys, add/overwrite statusLine and hooks
  MERGED=$(jq -s '.[0] * .[1]' "$SETTINGS" <(echo "$NEW_SETTINGS") 2>/dev/null || echo "$NEW_SETTINGS")
  echo "$MERGED" > "$SETTINGS"
  echo "  ✅ Merged into $SETTINGS"
else
  echo "$NEW_SETTINGS" > "$SETTINGS"
  echo "  ✅ Created $SETTINGS"
fi

# ── Test statusline ───────────────────────────────────────────────────────────
echo ""
echo "🧪 Testing statusline (dry run)..."
TEST_OUTPUT=$(echo '{"model":{"display_name":"Sonnet 4.6"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42,"remaining_percentage":58,"total_input_tokens":84000,"total_output_tokens":4200},"cost":{"total_cost_usd":0.0312},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":'"$(($(date +%s) + 7200))"'},"seven_day":{"used_percentage":41.2,"resets_at":'"$(($(date +%s) + 259200))"'}}}' \
  | bash "$CLAUDE_DIR/statusline.sh" 2>/dev/null)

if [ -n "$TEST_OUTPUT" ]; then
  echo ""
  echo "  Preview:"
  echo "  $TEST_OUTPUT"
  echo ""
  echo "  ✅ Statusline works"
else
  echo "  ⚠️  Statusline test produced no output (check jq is installed)"
fi

# ── macOS keychain check ───────────────────────────────────────────────────────
if [[ "$OSTYPE" == "darwin"* ]]; then
  echo ""
  echo "🔑 Checking macOS keychain for Claude Code credentials..."
  SCOPES=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.scopes | join(", ")' 2>/dev/null)
  if [ -n "$SCOPES" ]; then
    echo "  ✅ Found credentials with scopes: $SCOPES"
    if echo "$SCOPES" | grep -q "user:profile"; then
      echo "  ✅ Has user:profile scope — 5h/weekly limits will show"
    else
      echo "  ⚠️  Missing user:profile scope — rate limit bars won't appear"
      echo "     Fix: delete keychain entry + restart Claude Code"
      echo "     security delete-generic-password -s \"Claude Code-credentials\""
    fi
  else
    echo "  ⚠️  No Claude Code credentials in keychain (rate limits won't show)"
    echo "     This is normal if you haven't used Claude Code yet."
  fi
elif [ -f "$HOME/.claude/.credentials.json" ]; then
  echo ""
  echo "🔑 Found credentials file at ~/.claude/.credentials.json ✅"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Setup complete! Restart Claude Code to activate."
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  📊 Statusline shows: Model | Context% | 5h | Weekly | Cost | Git"
echo "  🪝 Hook warns Claude at: 60% (info), 75% (warning), 83% (critical)"
echo "  🤖 AI context parser: node ~/.claude/context-parser.sh --watch"
echo ""
echo "  Useful commands inside Claude Code:"
echo "    /compact        — compress context (run at ~75%)"
echo "    /clear          — fresh session (after saving AI summary)"
echo "    /context        — show current context usage"
echo "    /usage          — show rate limit status"
echo ""
echo "  Run AI context summary anytime:"
echo "    node ~/.claude/context-parser.sh --force"
echo "    node ~/.claude/context-parser.sh --watch   (auto, only at >70%)"
echo ""
