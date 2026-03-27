#!/bin/bash
# =============================================================================
# Claude Code Statusline Script
# Shows: Model | Context % | 5h limit | Weekly limit | Cost | Git branch
# Saves context state to ~/.claude/tmp/context-state.json for hooks
# =============================================================================

input=$(cat)

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[91m'
CYAN=$'\033[96m'
MAGENTA=$'\033[95m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
RESET=$'\033[0m'
HOT_PINK=$'\033[38;5;199m'

# ── Extract fields from JSON ──────────────────────────────────────────────────
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
CTX_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
CTX_REMAINING=$(echo "$input" | jq -r '.context_window.remaining_percentage // 0' | cut -d. -f1)
IN_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
OUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
LINES_ADDED=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
LINES_REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Rate limits (only available for Pro/Max/claude.ai users)
FIVE_HR_PCT=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_HR_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
SEVEN_DAY_PCT=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
SEVEN_DAY_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')

# ── Save state for hooks ──────────────────────────────────────────────────────
mkdir -p ~/.claude/tmp
echo "$input" | jq "{
  ctx_pct: (.context_window.used_percentage // 0),
  ctx_remaining: (.context_window.remaining_percentage // 0),
  five_hr_pct: (.rate_limits.five_hour.used_percentage // null),
  seven_day_pct: (.rate_limits.seven_day.used_percentage // null),
  cost: (.cost.total_cost_usd // 0),
  model: (.model.display_name // \"?\"),
  ts: $(date +%s)
}" > ~/.claude/tmp/context-state.json 2>/dev/null

# ── Progress bar builder ───────────────────────────────────────────────────────
make_bar() {
  local pct=$1
  local width=${2:-10}
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar=""
  [ "$filled" -gt 0 ] && bar=$(printf "%${filled}s" | tr ' ' '▓')
  [ "$empty"  -gt 0 ] && bar="${bar}$(printf "%${empty}s" | tr ' ' '░')"
  echo "$bar"
}

# ── Color by threshold ────────────────────────────────────────────────────────
color_by_pct() {
  local pct=$1
  if   [ "$pct" -lt 50 ]; then echo "$GREEN"
  elif [ "$pct" -lt 80 ]; then echo "$YELLOW"
  else                         echo "$RED"
  fi
}

# ── Pacing marker (where you SHOULD be at this point in window) ───────────────
pacing_marker() {
  local reset_ts=$1
  local bar_width=${2:-10}
  if [ -z "$reset_ts" ]; then echo ""; return; fi
  local now
  now=$(date +%s)
  # Figure out window length from reset (5h = 18000s, 7d = 604800s)
  # We detect based on which reset this is
  local window_secs=$3
  local elapsed=$(( window_secs - (reset_ts - now) ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  local pacing_pos=$(( elapsed * bar_width / window_secs ))
  [ "$pacing_pos" -gt "$bar_width" ] && pacing_pos=$bar_width
  echo "$pacing_pos"
}

# ── Insert pacing marker into bar ─────────────────────────────────────────────
bar_with_marker() {
  local pct=$1
  local bar_width=${2:-10}
  local marker_pos=$3
  local filled=$(( pct * bar_width / 100 ))
  local result=""
  for (( i=0; i<bar_width; i++ )); do
    if [ "$i" -eq "$marker_pos" ] && [ -n "$marker_pos" ]; then
      result="${result}${HOT_PINK}│${RESET}"
    elif [ "$i" -lt "$filled" ]; then
      result="${result}▓"
    else
      result="${result}░"
    fi
  done
  echo "$result"
}

# ── Format reset time ─────────────────────────────────────────────────────────
fmt_reset() {
  local ts=$1
  if [ -z "$ts" ]; then echo ""; return; fi
  local now
  now=$(date +%s)
  local diff=$(( ts - now ))
  if [ "$diff" -le 0 ]; then echo "now"; return; fi
  local h=$(( diff / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then
    echo "${h}h${m}m"
  else
    echo "${m}m"
  fi
}

# ── Format cost ───────────────────────────────────────────────────────────────
fmt_cost() {
  local cost=$1
  printf '\$%.4f' "$cost" 2>/dev/null || echo "\$0"
}

# ── Git info ──────────────────────────────────────────────────────────────────
GIT_INFO=""
if git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
  STAGED=$(git -C "$DIR" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  MODIFIED=$(git -C "$DIR" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
  GIT_INFO="${CYAN}${BRANCH}${RESET}"
  [ "$STAGED"   -gt 0 ] && GIT_INFO="${GIT_INFO} ${GREEN}+${STAGED}${RESET}"
  [ "$MODIFIED" -gt 0 ] && GIT_INFO="${GIT_INFO} ${YELLOW}~${MODIFIED}${RESET}"
fi

# ── Build context bar ─────────────────────────────────────────────────────────
CTX_COLOR=$(color_by_pct "$CTX_PCT")
CTX_BAR=$(make_bar "$CTX_PCT" 10)
CTX_DISPLAY="${CTX_COLOR}${CTX_BAR}${RESET} ${CTX_COLOR}${CTX_PCT}%${RESET}"

# ── Build 5h bar ──────────────────────────────────────────────────────────────
FIVE_HR_DISPLAY=""
if [ -n "$FIVE_HR_PCT" ]; then
  FIVE_HR_PCT_INT=$(echo "$FIVE_HR_PCT" | cut -d. -f1)
  FIVE_HR_COLOR=$(color_by_pct "$FIVE_HR_PCT_INT")
  FIVE_HR_RESET_FMT=$(fmt_reset "$FIVE_HR_RESET")
  FIVE_HR_BAR=$(make_bar "$FIVE_HR_PCT_INT" 10)
  FIVE_HR_DISPLAY="${DIM}5h↺${FIVE_HR_RESET_FMT}${RESET} ${FIVE_HR_COLOR}${FIVE_HR_BAR} ${FIVE_HR_PCT_INT}%${RESET}"
fi

# ── Build 7d bar ──────────────────────────────────────────────────────────────
SEVEN_DAY_DISPLAY=""
if [ -n "$SEVEN_DAY_PCT" ]; then
  SEVEN_DAY_PCT_INT=$(echo "$SEVEN_DAY_PCT" | cut -d. -f1)
  SEVEN_DAY_COLOR=$(color_by_pct "$SEVEN_DAY_PCT_INT")
  SEVEN_DAY_RESET_FMT=$(fmt_reset "$SEVEN_DAY_RESET")
  SEVEN_DAY_BAR=$(make_bar "$SEVEN_DAY_PCT_INT" 10)
  SEVEN_DAY_DISPLAY="${DIM}7d↺${SEVEN_DAY_RESET_FMT}${RESET} ${SEVEN_DAY_COLOR}${SEVEN_DAY_BAR} ${SEVEN_DAY_PCT_INT}%${RESET}"
fi

# ── Build cost display ────────────────────────────────────────────────────────
COST_DISPLAY="${DIM}$(fmt_cost $COST)${RESET}"

# ── Auto-compact warning overlay ──────────────────────────────────────────────
WARN=""
if [ "$CTX_PCT" -ge 75 ] && [ "$CTX_PCT" -lt 83 ]; then
  WARN="${YELLOW}${BOLD} ⚡ /compact soon${RESET}"
elif [ "$CTX_PCT" -ge 83 ]; then
  WARN="${RED}${BOLD} 🔴 /compact NOW${RESET}"
fi

# ── Assemble status line ──────────────────────────────────────────────────────
SEP="${DIM} │ ${RESET}"

LINE="${BOLD}${MAGENTA}${MODEL}${RESET}${SEP}"
LINE="${LINE}ctx ${CTX_DISPLAY}"
[ -n "$FIVE_HR_DISPLAY"   ] && LINE="${LINE}${SEP}${FIVE_HR_DISPLAY}"
[ -n "$SEVEN_DAY_DISPLAY" ] && LINE="${LINE}${SEP}${SEVEN_DAY_DISPLAY}"
LINE="${LINE}${SEP}${COST_DISPLAY}"
[ -n "$GIT_INFO" ]          && LINE="${LINE}${SEP}${GIT_INFO}"
[ -n "$WARN"     ]          && LINE="${LINE}${WARN}"

echo -e "$LINE"
