#!/bin/bash
# =============================================================================
# Claude Code Hook: context-display.sh
# Triggered on: UserPromptSubmit
# Purpose:
#   1. Read context state saved by statusline.sh
#   2. Inject a context warning into Claude's context when usage is high
#   3. Prompt user to /compact if context is critical (>75%)
#
# stdout → injected directly into Claude Code's context
# exit 1 + stderr → blocks the request (use for critical warnings)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$SCRIPT_DIR/../tmp/context-state.json"
LOG_FILE="$SCRIPT_DIR/../tmp/hook-debug.log"

# ── Read saved context state ──────────────────────────────────────────────────
if [ ! -f "$STATE_FILE" ]; then
  exit 0  # No state yet, pass through silently
fi

CTX_PCT=$(jq -r '.ctx_pct // 0' "$STATE_FILE" 2>/dev/null | cut -d. -f1)
FIVE_HR=$(jq -r '.five_hr_pct // "N/A"' "$STATE_FILE" 2>/dev/null)
SEVEN_DAY=$(jq -r '.seven_day_pct // "N/A"' "$STATE_FILE" 2>/dev/null)
MODEL=$(jq -r '.model // "?"' "$STATE_FILE" 2>/dev/null)
COST=$(jq -r '.cost // 0' "$STATE_FILE" 2>/dev/null)

# ── Determine warning level ───────────────────────────────────────────────────
# Claude Code auto-compacts at ~83% context usage
# We warn progressively before that

if [ "$CTX_PCT" -ge 83 ]; then
  # CRITICAL: Block and ask to compact
  # Output to stderr to show in Claude Code UI
  echo "⚠️  CONTEXT CRITICAL (${CTX_PCT}%): Auto-compact may trigger mid-response." >&2
  echo "Run /compact now to preserve conversation quality." >&2
  # Inject into context so Claude knows too
  echo "[SYSTEM CONTEXT ALERT] Context window is ${CTX_PCT}% full. You are approaching auto-compaction. Consider summarizing progress and key decisions before continuing."
  exit 0

elif [ "$CTX_PCT" -ge 75 ]; then
  # WARNING: Inject advisory into context
  echo "[CONTEXT ADVISORY] Context window is ${CTX_PCT}% used. Consider running /compact proactively to maintain quality. 5h usage: ${FIVE_HR}%, weekly: ${SEVEN_DAY}%."
  exit 0

elif [ "$CTX_PCT" -ge 60 ]; then
  # INFO: Light nudge in context
  echo "[CONTEXT INFO] Context at ${CTX_PCT}%. Session cost: \$${COST}."
  exit 0
fi

# Below 60%: pass through with no injection
exit 0
