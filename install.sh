#!/usr/bin/env bash
# =============================================================================
# Dotfiles Installer — macOS & Linux
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}──▶${NC} $1"; }
info() { echo -e "${CYAN}    $1${NC}"; }

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
    step "Detecting OS..."
    case "$(uname -s)" in
        Darwin)
            OS="macos"
            ARCH="$(uname -m)"
            log "macOS detected (arch: $ARCH)"
            ;;
        Linux)
            OS="linux"
            ARCH="$(uname -m)"
            if   command -v apt-get &>/dev/null; then PKG="apt"
            elif command -v pacman  &>/dev/null; then PKG="pacman"
            elif command -v dnf     &>/dev/null; then PKG="dnf"
            elif command -v zypper  &>/dev/null; then PKG="zypper"
            else err "Unsupported Linux package manager"; fi
            log "Linux detected — package manager: $PKG (arch: $ARCH)"
            ;;
        *)
            err "Unsupported OS. Use install.ps1 on Windows."
            ;;
    esac
}

# ── Package Manager ───────────────────────────────────────────────────────────
install_pkg_manager() {
    if [[ "$OS" == "macos" ]]; then
        if ! command -v brew &>/dev/null; then
            step "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            # Apple Silicon: add brew to PATH for this session
            [[ "$ARCH" == "arm64" ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            log "Homebrew already installed"
        fi
    fi
}

# ── Core Packages ─────────────────────────────────────────────────────────────
install_packages() {
    step "Installing core packages..."
    if [[ "$OS" == "macos" ]]; then
        local pkgs=(git zsh neovim tmux curl wget node)
        local missing=()
        for p in "${pkgs[@]}"; do
            command -v "$p" &>/dev/null || missing+=("$p")
        done
        [[ ${#missing[@]} -gt 0 ]] && brew install "${missing[@]}"
        log "Core packages ready"
        install_ghostty_macos
    elif [[ "$OS" == "linux" ]]; then
        install_packages_linux
    fi
}

# Returns 0 (true) if a package is NOT installed
pkg_missing() {
    local pkg="$1"
    case "$PKG" in
        apt)    ! dpkg -s "$pkg" &>/dev/null ;;
        pacman) ! pacman -Q "$pkg" &>/dev/null ;;
        dnf)    ! rpm -q "$pkg" &>/dev/null ;;
        zypper) ! rpm -q "$pkg" &>/dev/null ;;
        *)      return 0 ;;
    esac
}

install_packages_linux() {
    local pkgs=(git zsh curl wget tmux build-essential unzip)
    local missing=()
    for p in "${pkgs[@]}"; do
        pkg_missing "$p" && missing+=("$p")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Missing packages: ${missing[*]}"
        case "$PKG" in
            apt)
                sudo apt-get update -qq 2>&1 | grep -v "^W:" || true
                sudo apt-get install -y "${missing[@]}"
                ;;
            pacman) sudo pacman -S --noconfirm "${missing[@]}" ;;
            dnf)    sudo dnf install -y "${missing[@]}" ;;
            zypper) sudo zypper install -y "${missing[@]}" ;;
        esac
    else
        info "All base packages already installed"
    fi

    install_neovim_linux
    install_node_linux
    log "Core packages ready"
    install_ghostty_linux
}

install_neovim_linux() {
    if command -v nvim &>/dev/null; then
        log "Neovim already installed ($(nvim --version | head -1))"
        return
    fi
    step "Installing Neovim..."
    local url arch
    case "$ARCH" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="arm64"  ;;
        *)        warn "Unknown arch $ARCH, trying x86_64"; arch="x86_64" ;;
    esac
    url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${arch}.appimage"
    curl -Lo /tmp/nvim.appimage "$url"
    chmod +x /tmp/nvim.appimage
    sudo mv /tmp/nvim.appimage /usr/local/bin/nvim
    log "Neovim installed"
}

install_node_linux() {
    if command -v node &>/dev/null; then
        log "Node.js already installed"
        return
    fi
    step "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
}

install_ghostty_macos() {
    if [[ -d "/Applications/Ghostty.app" ]] || command -v ghostty &>/dev/null; then
        log "Ghostty already installed"
        return
    fi
    step "Installing Ghostty..."
    brew install --cask ghostty 2>/dev/null || \
        warn "Could not install Ghostty via Homebrew. Download from https://ghostty.org"
}

install_ghostty_linux() {
    if command -v ghostty &>/dev/null; then
        log "Ghostty already installed"
        return
    fi
    step "Installing Ghostty (Linux)..."
    # Try Flatpak first
    if command -v flatpak &>/dev/null; then
        flatpak install -y flathub com.mitchellh.ghostty 2>/dev/null \
            && log "Ghostty installed via Flatpak" && return
    fi
    # Try .deb for apt-based systems
    if [[ "$PKG" == "apt" ]]; then
        local deb_url arch
        case "$ARCH" in
            x86_64)  arch="amd64" ;;
            aarch64) arch="arm64" ;;
            *)        arch="amd64" ;;
        esac
        # Ghostty provides a .deb via their GitHub releases
        local latest
        latest=$(curl -s https://api.github.com/repos/ghostty-org/ghostty/releases/latest \
                 | grep "browser_download_url.*${arch}\.deb" | cut -d'"' -f4 | head -1) 2>/dev/null || true
        if [[ -n "$latest" ]]; then
            curl -Lo /tmp/ghostty.deb "$latest"
            sudo dpkg -i /tmp/ghostty.deb && log "Ghostty installed via .deb" && return
        fi
    fi
    warn "Could not auto-install Ghostty. See: https://ghostty.org/docs/install/binary"
    warn "Install manually and re-run this script if needed."
}

# ── Nerd Fonts ────────────────────────────────────────────────────────────────
install_nerd_font() {
    step "Installing MesloLGS NF (required for Powerlevel10k)..."
    if [[ "$OS" == "macos" ]]; then
        if brew list --cask font-meslo-lg-nerd-font &>/dev/null; then
            log "MesloLGS NF already installed"
            return
        fi
        brew install --cask font-meslo-lg-nerd-font 2>/dev/null \
            || brew install font-meslo-lg-nerd-font 2>/dev/null \
            || warn "Could not install font via Homebrew — install 'MesloLGS NF' manually"
    else
        local font_dir="$HOME/.local/share/fonts/MesloLGS"
        mkdir -p "$font_dir"
        local base="https://github.com/romkatv/powerlevel10k-media/raw/master"
        local fonts=("MesloLGS NF Regular" "MesloLGS NF Bold" "MesloLGS NF Italic" "MesloLGS NF Bold Italic")
        for font in "${fonts[@]}"; do
            local file="${font}.ttf"
            local url_encoded="${file// /%20}"
            [[ -f "$font_dir/$file" ]] || curl -fLo "$font_dir/$file" "$base/$url_encoded"
        done
        fc-cache -fv "$font_dir" &>/dev/null
        log "MesloLGS NF fonts installed"
    fi
}

# ── Oh My Zsh ─────────────────────────────────────────────────────────────────
install_omz() {
    step "Setting up Oh My Zsh..."
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
        log "Oh My Zsh installed"
    else
        log "Oh My Zsh already installed"
    fi

    local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    # Powerlevel10k theme
    if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
        info "Cloning Powerlevel10k..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
            "$ZSH_CUSTOM/themes/powerlevel10k"
    else
        log "Powerlevel10k already installed"
    fi

    # zsh-autosuggestions
    if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
        info "Cloning zsh-autosuggestions..."
        git clone https://github.com/zsh-users/zsh-autosuggestions \
            "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    else
        log "zsh-autosuggestions already installed"
    fi

    # zsh-syntax-highlighting
    if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]]; then
        info "Cloning zsh-syntax-highlighting..."
        git clone https://github.com/zsh-users/zsh-syntax-highlighting \
            "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    else
        log "zsh-syntax-highlighting already installed"
    fi
}

# ── vim-plug ──────────────────────────────────────────────────────────────────
install_vim_plug() {
    step "Installing vim-plug for Neovim..."
    local plug_path="$HOME/.local/share/nvim/site/autoload/plug.vim"
    if [[ ! -f "$plug_path" ]]; then
        curl -fLo "$plug_path" --create-dirs \
            https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
        log "vim-plug installed"
    else
        log "vim-plug already installed"
    fi
}

# ── Claude Code ───────────────────────────────────────────────────────────────
install_claude_code() {
    step "Installing Claude Code..."
    if command -v claude &>/dev/null; then
        log "Claude Code already installed ($(claude --version 2>/dev/null || echo 'version unknown'))"
    else
        npm install -g @anthropic-ai/claude-code
        log "Claude Code installed"
    fi
}

# ── Symlink Configs ───────────────────────────────────────────────────────────
install_configs() {
    step "Symlinking configs..."

    link_config "$DOTFILES_DIR/configs/zsh/.zshrc"      "$HOME/.zshrc"
    link_config "$DOTFILES_DIR/configs/zsh/.p10k.zsh"   "$HOME/.p10k.zsh"

    mkdir -p "$HOME/.config/nvim"
    link_config "$DOTFILES_DIR/configs/nvim/init.vim"   "$HOME/.config/nvim/init.vim"

    mkdir -p "$HOME/.claude"
    link_config "$DOTFILES_DIR/configs/claude/settings.json" "$HOME/.claude/settings.json"

    mkdir -p "$HOME/.config/ghostty"
    link_config "$DOTFILES_DIR/configs/ghostty/config"  "$HOME/.config/ghostty/config"
}

link_config() {
    local src="$1" dst="$2"
    # Backup existing file if it's not already our symlink
    if [[ -e "$dst" && ! -L "$dst" ]]; then
        local backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$dst" "$backup"
        warn "Backed up existing $(basename "$dst") → $backup"
    fi
    ln -sf "$src" "$dst"
    log "Linked: $dst"
}

# ── Default Shell ─────────────────────────────────────────────────────────────
set_default_shell() {
    local zsh_path
    zsh_path="$(command -v zsh)"
    if [[ "$SHELL" == "$zsh_path" ]]; then
        log "zsh is already the default shell"
        return
    fi
    step "Setting zsh as default shell..."
    if ! grep -qxF "$zsh_path" /etc/shells; then
        echo "$zsh_path" | sudo tee -a /etc/shells
    fi
    chsh -s "$zsh_path"
    log "Default shell set to zsh (takes effect on next login)"
}

# ── Neovim Plugins ────────────────────────────────────────────────────────────
install_nvim_plugins() {
    step "Installing Neovim plugins (gruvbox via vim-plug)..."
    local gruvbox_dir="$HOME/.local/share/nvim/plugged/gruvbox"
    if [[ -d "$gruvbox_dir" ]]; then
        log "Neovim plugins already installed"
        return
    fi
    nvim --headless +PlugInstall +qall 2>/dev/null && log "Neovim plugins installed" \
        || warn "Neovim plugin install encountered an issue — run :PlugInstall manually"
}

# ── Banner ────────────────────────────────────────────────────────────────────
banner() {
    echo -e "${BOLD}${BLUE}"
    echo "  ██████╗  ██████╗ ████████╗███████╗██╗██╗     ███████╗███████╗"
    echo "  ██╔══██╗██╔═══██╗╚══██╔══╝██╔════╝██║██║     ██╔════╝██╔════╝"
    echo "  ██║  ██║██║   ██║   ██║   █████╗  ██║██║     █████╗  ███████╗"
    echo "  ██║  ██║██║   ██║   ██║   ██╔══╝  ██║██║     ██╔══╝  ╚════██║"
    echo "  ██████╔╝╚██████╔╝   ██║   ██║     ██║███████╗███████╗███████║"
    echo "  ╚═════╝  ╚═════╝    ╚═╝   ╚═╝     ╚═╝╚══════╝╚══════╝╚══════╝"
    echo -e "${NC}"
    echo -e "  ${CYAN}Dotfiles Installer${NC} · macOS & Linux"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    banner
    detect_os
    install_pkg_manager
    install_packages
    install_nerd_font
    install_omz
    install_vim_plug
    install_claude_code
    install_configs
    set_default_shell
    install_nvim_plugins

    echo ""
    echo -e "${BOLD}${GREEN}  ✓ All done!${NC} Restart your terminal to apply changes."
    echo ""
    echo -e "  ${YELLOW}Post-install checklist:${NC}"
    echo -e "  • Set your Ghostty font to ${CYAN}MesloLGS NF${NC} (already in config if using this dotfiles)"
    echo -e "  • Run ${CYAN}p10k configure${NC} if you want to reconfigure the prompt"
    echo -e "  • Run ${CYAN}claude${NC} to log in to Claude Code"
    echo ""
}

main "$@"
