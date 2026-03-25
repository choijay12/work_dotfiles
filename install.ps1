# =============================================================================
# Dotfiles Installer — Windows
# Installs Claude Code natively, then sets up WSL2 with the full
# zsh / oh-my-zsh / neovim stack via the Linux installer.
# Run from an elevated (Administrator) PowerShell prompt.
# =============================================================================
#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$DOTFILES_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Helpers ───────────────────────────────────────────────────────────────────
function Log   { param([string]$msg) Write-Host "[✓] $msg" -ForegroundColor Green }
function Warn  { param([string]$msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Err   { param([string]$msg) Write-Host "[✗] $msg" -ForegroundColor Red; exit 1 }
function Step  { param([string]$msg) Write-Host "`n──▶ $msg" -ForegroundColor Cyan }
function Info  { param([string]$msg) Write-Host "    $msg" -ForegroundColor Gray }

function Test-Command { param([string]$cmd) return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ── Banner ────────────────────────────────────────────────────────────────────
function Show-Banner {
    Write-Host ""
    Write-Host "  DOTFILES INSTALLER — Windows" -ForegroundColor Blue
    Write-Host "  Sets up WSL2 + Claude Code" -ForegroundColor Gray
    Write-Host ""
}

# ── Winget ────────────────────────────────────────────────────────────────────
function Install-Winget {
    Step "Checking winget..."
    if (Test-Command "winget") {
        Log "winget is available"
    } else {
        Warn "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
        Start-Process "ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1"
        Err "Please install winget and re-run this script."
    }
}

# ── WSL2 ──────────────────────────────────────────────────────────────────────
function Install-WSL {
    Step "Setting up WSL2..."

    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    $vmFeature   = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue

    if ($wslFeature.State -ne "Enabled" -or $vmFeature.State -ne "Enabled") {
        Info "Enabling WSL2 features (requires reboot)..."
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart | Out-Null
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart | Out-Null

        # Download and install the WSL2 kernel update
        $kernelUrl = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
        $kernelMsi = "$env:TEMP\wsl_update_x64.msi"
        Info "Downloading WSL2 kernel update..."
        Invoke-WebRequest -Uri $kernelUrl -OutFile $kernelMsi -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$kernelMsi`" /quiet /norestart" -Wait
        wsl --set-default-version 2 | Out-Null

        Warn "A reboot is required to complete WSL2 setup."
        Warn "After rebooting, re-run this script to continue."
        $restart = Read-Host "Reboot now? [y/N]"
        if ($restart -ieq "y") { Restart-Computer }
        exit 0
    }

    # Set WSL2 as default
    wsl --set-default-version 2 2>$null | Out-Null
    Log "WSL2 is enabled"

    # Check for Ubuntu
    $distros = wsl --list --quiet 2>$null
    $hasUbuntu = $distros | Where-Object { $_ -match "Ubuntu" }
    if (-not $hasUbuntu) {
        Step "Installing Ubuntu 24.04 for WSL..."
        winget install --id Canonical.Ubuntu.2404 --silent --accept-package-agreements --accept-source-agreements
        Log "Ubuntu 24.04 installed"
        Info "Please complete Ubuntu first-run setup (set username/password) then re-run this script."
        wsl --distribution Ubuntu-24.04
        exit 0
    }
    Log "Ubuntu WSL distro found"
}

# ── Nerd Font ─────────────────────────────────────────────────────────────────
function Install-NerdFont {
    Step "Installing MesloLGS NF (Powerlevel10k font)..."
    $fontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    New-Item -ItemType Directory -Force -Path $fontDir | Out-Null

    $base = "https://github.com/romkatv/powerlevel10k-media/raw/master"
    $fonts = @(
        "MesloLGS NF Regular.ttf",
        "MesloLGS NF Bold.ttf",
        "MesloLGS NF Italic.ttf",
        "MesloLGS NF Bold Italic.ttf"
    )
    $registry = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
    foreach ($font in $fonts) {
        $dest = Join-Path $fontDir $font
        if (-not (Test-Path $dest)) {
            $url = "$base/$($font -replace ' ', '%20')"
            Info "Downloading $font..."
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        }
        # Register font for current user
        $fontName = [System.IO.Path]::GetFileNameWithoutExtension($font) + " (TrueType)"
        if (-not (Get-ItemProperty -Path $registry -Name $fontName -ErrorAction SilentlyContinue)) {
            New-ItemProperty -Path $registry -Name $fontName -Value $dest -PropertyType String -Force | Out-Null
        }
    }
    Log "MesloLGS NF fonts installed"
}

# ── Claude Code (Windows-native) ──────────────────────────────────────────────
function Install-ClaudeCode {
    Step "Installing Claude Code (Windows)..."

    # Ensure Node.js is available
    if (-not (Test-Command "node")) {
        Info "Installing Node.js LTS via winget..."
        winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("PATH", "User")
    }

    if (Test-Command "claude") {
        Log "Claude Code already installed"
    } else {
        npm install -g @anthropic-ai/claude-code
        Log "Claude Code installed"
    }
}

# ── Claude Code Config ────────────────────────────────────────────────────────
function Install-ClaudeConfig {
    Step "Installing Claude Code config..."
    $claudeDir = "$env:USERPROFILE\.claude"
    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    $src = Join-Path $DOTFILES_DIR "configs\claude\settings.json"
    $dst = Join-Path $claudeDir "settings.json"
    if ((Test-Path $dst) -and -not ((Get-Item $dst).LinkType -eq "SymbolicLink")) {
        $backup = "$dst.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item $dst $backup
        Warn "Backed up Claude settings → $backup"
    }
    try {
        New-Item -ItemType SymbolicLink -Path $dst -Target $src -Force | Out-Null
        Log "Claude Code config symlinked"
    } catch {
        Copy-Item $src $dst
        Log "Claude Code config copied"
    }
}

# ── Run Linux Installer in WSL ────────────────────────────────────────────────
function Invoke-WSLInstaller {
    Step "Running Linux dotfiles installer in WSL..."

    # Convert Windows path to WSL path
    $wslPath = (wsl wslpath -u "$($DOTFILES_DIR -replace '\\', '/')" 2>$null).Trim()
    if (-not $wslPath) {
        # Manual conversion fallback: C:\Users\... → /mnt/c/Users/...
        $wslPath = "/" + ($DOTFILES_DIR -replace "\\", "/" -replace "^([A-Za-z]):", { "/mnt/" + $Matches[1].ToLower() })
    }

    $linuxScript = "$wslPath/install.sh"
    Info "WSL path: $linuxScript"

    wsl bash -c "chmod +x '$linuxScript' && '$linuxScript'"

    if ($LASTEXITCODE -eq 0) {
        Log "WSL Linux setup complete"
    } else {
        Warn "WSL installer exited with code $LASTEXITCODE. Check the output above."
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────
function Main {
    Show-Banner

    if (-not (Test-Admin)) {
        Err "Please run this script as Administrator (right-click → 'Run as Administrator')."
    }

    Install-Winget
    Install-WSL
    Install-NerdFont
    Install-ClaudeCode
    Install-ClaudeConfig
    Invoke-WSLInstaller

    Write-Host ""
    Write-Host "  ✓ All done!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Post-install checklist:" -ForegroundColor Yellow
    Write-Host "  • Run 'claude' in PowerShell to log in to Claude Code" -ForegroundColor Gray
    Write-Host "  • Open WSL (Ubuntu) for your zsh/neovim environment" -ForegroundColor Gray
    Write-Host "  • Run 'p10k configure' inside WSL to tune the prompt" -ForegroundColor Gray
    Write-Host ""
}

Main
