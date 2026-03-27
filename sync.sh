#!/usr/bin/env bash
# =============================================================================
# Dotfiles Sync — copy current system configs into the repo and push to remote
# Usage:
#   ./sync.sh           — copy configs + commit + push
#   ./sync.sh --dry-run — show what would change, no writes
# =============================================================================
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
step() { echo -e "\n${BOLD}${BLUE}──▶${NC} $1"; }
info() { echo -e "${CYAN}    $1${NC}"; }

dry() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[dry-run]${NC} would run: $*"
    else
        "$@"
    fi
}

# ── Config map: system path → repo path ──────────────────────────────────────
# Format: "SOURCE_ON_SYSTEM|DEST_IN_REPO"
declare -a CONFIG_MAP=(
    "$HOME/.zshrc|configs/zsh/.zshrc"
    "$HOME/.p10k.zsh|configs/zsh/.p10k.zsh"
    "$HOME/.config/nvim/init.vim|configs/nvim/init.vim"
    "$HOME/.claude/settings.json|configs/claude/settings.json"
    "$HOME/.claude/statusline.sh|configs/claude/statusline.sh"
    "$HOME/.claude/hooks/context-display.sh|configs/claude/hooks/context-display.sh"
    "$HOME/.claude/context-parser.sh|configs/claude/context-parser.sh"
    "$HOME/.config/ghostty/config|configs/ghostty/config"
    "$HOME/.tmux.conf|configs/tmux/.tmux.conf"
)

# ── Detect OS (for context in commit message) ─────────────────────────────────
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macOS" ;;
        Linux)
            if [[ -f /etc/os-release ]]; then
                # shellcheck source=/dev/null
                source /etc/os-release
                echo "${PRETTY_NAME:-Linux}"
            else
                echo "Linux"
            fi
            ;;
        *) echo "Unknown" ;;
    esac
}

# ── Copy configs from system → repo ──────────────────────────────────────────
copy_configs() {
    step "Copying configs from system..."
    local changed=0

    for entry in "${CONFIG_MAP[@]}"; do
        local src="${entry%%|*}"
        local rel="${entry##*|}"
        local dst="$DOTFILES_DIR/$rel"

        if [[ ! -f "$src" ]]; then
            warn "Skipping (not found): $src"
            continue
        fi

        # Show diff if file already exists
        if [[ -f "$dst" ]]; then
            if diff -q "$src" "$dst" &>/dev/null; then
                info "No change: $rel"
                continue
            else
                info "Changed:   $rel"
                if $DRY_RUN; then
                    diff --color=always "$dst" "$src" || true
                fi
            fi
        else
            info "New file:  $rel"
        fi

        dry mkdir -p "$(dirname "$dst")"
        dry cp "$src" "$dst"
        (( changed++ )) || true
    done

    if [[ $changed -eq 0 ]]; then
        log "All configs are already up to date"
        return 1   # signal: nothing to commit
    fi

    log "$changed file(s) updated in repo"
    return 0
}

# ── Check git state ───────────────────────────────────────────────────────────
check_git() {
    if ! git -C "$DOTFILES_DIR" rev-parse --git-dir &>/dev/null; then
        warn "Not a git repository. Initializing..."
        dry git -C "$DOTFILES_DIR" init
        dry git -C "$DOTFILES_DIR" add -A
        warn "No remote configured. Set one with:"
        warn "  git -C $DOTFILES_DIR remote add origin <url>"
        return 1
    fi
    return 0
}

# ── Commit & push ─────────────────────────────────────────────────────────────
commit_and_push() {
    step "Committing changes..."

    local os host date_str
    os="$(detect_os)"
    host="$(hostname -s 2>/dev/null || echo 'unknown')"
    date_str="$(date '+%Y-%m-%d %H:%M')"

    local msg="sync: update configs from $os ($host) on $date_str"

    cd "$DOTFILES_DIR"

    # Stage only the configs directory (avoids accidentally staging scripts)
    dry git add configs/

    # Check if there's anything staged
    if git diff --cached --quiet; then
        log "Nothing staged to commit (configs unchanged in git)"
        return
    fi

    dry git commit -m "$msg"
    log "Committed: $msg"

    # Push if a remote exists
    local remote
    remote="$(git remote 2>/dev/null | head -1)"
    if [[ -z "$remote" ]]; then
        warn "No git remote configured — skipping push."
        warn "Add one with: git remote add origin <url>"
        return
    fi

    # Determine current branch
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'main')"

    # Check if upstream is set; if not, set it on first push
    if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" &>/dev/null; then
        step "Pushing to $remote/$branch..."
        dry git push
    else
        step "Pushing to $remote/$branch (setting upstream)..."
        dry git push --set-upstream "$remote" "$branch"
    fi

    log "Pushed to $remote/$branch"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${CYAN}  Dotfiles Sync${NC}  $(detect_os) · $(hostname -s 2>/dev/null)"
    $DRY_RUN && echo -e "  ${YELLOW}[DRY RUN — no changes will be written]${NC}"
    echo ""

    copy_configs || { log "Nothing changed — nothing to push."; exit 0; }

    if $DRY_RUN; then
        echo ""
        warn "Dry run complete. Run without --dry-run to apply."
        exit 0
    fi

    check_git || exit 0
    commit_and_push
}

main "$@"
