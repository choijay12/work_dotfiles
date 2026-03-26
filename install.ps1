# =============================================================================
# Dotfiles Installer - Windows
# Installs Claude Code natively, then sets up WSL2 with the full
# zsh / oh-my-zsh / neovim stack via the Linux installer.
# Run from an elevated (Administrator) PowerShell prompt.
# =============================================================================
#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$SCRIPT_PATH = $MyInvocation.MyCommand.Path
$DOTFILES_DIR = Split-Path -Parent $SCRIPT_PATH
$TASK_NAME = "DotfilesInstallResume"
$REMOTE_URL = "https://github.com/choijay12/work_dotfiles.git"
$WSL_DOTFILES = "~/dotfiles"

# -- Helpers -------------------------------------------------------------------
function Log   { param([string]$msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn  { param([string]$msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Err   { param([string]$msg) Write-Host "[ERR] $msg" -ForegroundColor Red; exit 1 }
function Step  { param([string]$msg) Write-Host "`n--> $msg" -ForegroundColor Cyan }
function Info  { param([string]$msg) Write-Host "    $msg" -ForegroundColor Gray }

function Test-Command { param([string]$cmd) return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# -- Banner --------------------------------------------------------------------
function Show-Banner {
    Write-Host ""
    Write-Host "  DOTFILES INSTALLER - Windows" -ForegroundColor Blue
    Write-Host "  Sets up WSL2 + Claude Code" -ForegroundColor Gray
    Write-Host ""
}

# -- Execution policy ----------------------------------------------------------
function Set-ScriptExecutionPolicy {
    $current = Get-ExecutionPolicy -Scope CurrentUser
    if ($current -eq "Restricted" -or $current -eq "Undefined") {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Log "Execution policy set to RemoteSigned"
    } else {
        Log "Execution policy already allows scripts ($current)"
    }
}

function Restore-ExecutionPolicy {
    Set-ExecutionPolicy -ExecutionPolicy Restricted -Scope CurrentUser -Force
    Log "Execution policy restored to Restricted"
}

# -- Scheduled task: auto-resume after reboot ----------------------------------
function Register-ResumeTask {
    $action  = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$SCRIPT_PATH`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask `
        -TaskName $TASK_NAME `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -RunLevel Highest `
        -Force | Out-Null
    Log "Registered resume task - script will continue automatically after reboot"
}

function Remove-ResumeTask {
    if (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
        Log "Removed resume task"
    }
}

# -- Winget --------------------------------------------------------------------
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

# -- WSL2 ----------------------------------------------------------------------
function Install-WSL {
    Step "Setting up WSL2..."

    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    $vmFeature   = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue

    if ($wslFeature.State -ne "Enabled" -or $vmFeature.State -ne "Enabled") {
        Info "Enabling WSL2 features..."
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart | Out-Null
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart | Out-Null

        $kernelUrl = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
        $kernelMsi = "$env:TEMP\wsl_update_x64.msi"
        Info "Downloading WSL2 kernel update..."
        Invoke-WebRequest -Uri $kernelUrl -OutFile $kernelMsi -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$kernelMsi`" /quiet /norestart" -Wait
        wsl --set-default-version 2 | Out-Null

        Register-ResumeTask
        Warn "Reboot required to finish enabling WSL2."
        $restart = Read-Host "Reboot now? [y/N]"
        if ($restart -ieq "y") { Restart-Computer -Force }
        exit 0
    }

    wsl --set-default-version 2 2>$null | Out-Null
    Log "WSL2 is enabled"

    # Install Ubuntu if not present
    $distroName = Get-UbuntuDistroName
    if (-not $distroName) {
        Step "Installing Ubuntu 24.04 for WSL..."
        winget install --id Canonical.Ubuntu.2404 --silent --accept-package-agreements --accept-source-agreements
        Start-Sleep -Seconds 3
        $distroName = Get-UbuntuDistroName

        if (-not $distroName) {
            Err "Ubuntu installed but distro name could not be detected. Run 'wsl --list' to check, then re-run this script."
        }

        Log "Ubuntu installed as: $distroName"
        wsl --set-default $distroName
    }

    # Check if Ubuntu first-run is complete by seeing if a non-root default user exists
    $wslUser = (wsl -d $distroName bash -c "id -un" 2>$null).Trim()
    if ($wslUser -eq "root" -or [string]::IsNullOrEmpty($wslUser)) {
        Write-Host ""
        Write-Host "  Ubuntu needs a one-time setup before we can continue." -ForegroundColor Yellow
        Write-Host "  A new Ubuntu window will open. Please:" -ForegroundColor Yellow
        Write-Host "    1. Set your username and password" -ForegroundColor White
        Write-Host "    2. Type 'exit' when done" -ForegroundColor White
        Write-Host ""
        Read-Host "Press Enter to open Ubuntu"

        # Open Ubuntu in a new window and wait for it to close
        Start-Process "wsl.exe" -ArgumentList "--distribution $distroName" -Wait

        # Re-check the user after setup
        $wslUser = (wsl -d $distroName bash -c "id -un" 2>$null).Trim()
        if ($wslUser -eq "root" -or [string]::IsNullOrEmpty($wslUser)) {
            Warn "Ubuntu still running as root - setup may be incomplete."
            Warn "Re-run this script after completing Ubuntu first-run setup."
            Register-ResumeTask
            exit 0
        }
    }

    Log "Ubuntu ready - running as user: $wslUser"
    wsl --set-default $distroName
}

# Detect the actual Ubuntu distro name by probing common names directly.
# Avoids parsing wsl --list output, which can be garbled due to UTF-16 LE
# encoding or localized (non-English) Windows UI languages.
function Get-UbuntuDistroName {
    $candidates = @("Ubuntu", "Ubuntu-24.04", "Ubuntu-22.04", "Ubuntu-20.04")
    foreach ($name in $candidates) {
        wsl -d $name echo "ok" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $name }
    }
    return $null
}

# -- Nerd Font -----------------------------------------------------------------
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
        $fontName = [System.IO.Path]::GetFileNameWithoutExtension($font) + " (TrueType)"
        if (-not (Get-ItemProperty -Path $registry -Name $fontName -ErrorAction SilentlyContinue)) {
            New-ItemProperty -Path $registry -Name $fontName -Value $dest -PropertyType String -Force | Out-Null
        }
    }
    Log "MesloLGS NF fonts installed"
}

# -- Claude Code (Windows-native) ----------------------------------------------
function Install-ClaudeCode {
    Step "Installing Claude Code (Windows)..."

    if (-not (Test-Command "node")) {
        Info "Installing Node.js LTS via winget..."
        winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
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

# -- Claude Code Config --------------------------------------------------------
function Install-ClaudeConfig {
    Step "Installing Claude Code config..."
    $claudeDir = "$env:USERPROFILE\.claude"
    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    $src = Join-Path $DOTFILES_DIR "configs\claude\settings.json"
    $dst = Join-Path $claudeDir "settings.json"
    if ((Test-Path $dst) -and -not ((Get-Item $dst).LinkType -eq "SymbolicLink")) {
        $backup = "$dst.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item $dst $backup
        Warn "Backed up Claude settings -> $backup"
    }
    try {
        New-Item -ItemType SymbolicLink -Path $dst -Target $src -Force | Out-Null
        Log "Claude Code config symlinked"
    } catch {
        Copy-Item $src $dst
        Log "Claude Code config copied"
    }
}

# -- Run Linux installer inside WSL's own filesystem --------------------------
function Invoke-WSLInstaller {
    Step "Setting up Linux environment in WSL..."

    # Get the actual WSL username to ensure everything installs under their home
    $distroName = Get-UbuntuDistroName
    $wslUser = (wsl -d $distroName bash -c "id -un" 2>$null).Trim()
    Info "Installing as WSL user: $wslUser"

    # Ensure git is available inside WSL before trying to clone
    Info "Ensuring git is installed in WSL..."
    wsl -d $distroName -u $wslUser bash -c "command -v git >/dev/null 2>&1 || (sudo apt-get update -qq && sudo apt-get install -y git)"
    if ($LASTEXITCODE -ne 0) {
        Err "Failed to install git inside WSL. Run 'wsl' and check manually."
    }

    # Clone into the user's home directory inside WSL's Linux filesystem.
    # Avoids /mnt/c/ cross-filesystem issues (slow I/O, CRLF endings, no exec bits).
    Info "Cloning dotfiles into WSL Linux filesystem..."
    wsl -d $distroName -u $wslUser bash -c "git -C $WSL_DOTFILES rev-parse --git-dir >/dev/null 2>&1 && git -C $WSL_DOTFILES pull || (rm -rf $WSL_DOTFILES && git clone $REMOTE_URL $WSL_DOTFILES)"
    if ($LASTEXITCODE -ne 0) {
        Err "Failed to clone repo into WSL. Run 'wsl' and try: git clone $REMOTE_URL $WSL_DOTFILES"
    }

    Info "Running install.sh inside WSL..."
    wsl -d $distroName -u $wslUser bash -c "chmod +x $WSL_DOTFILES/install.sh && $WSL_DOTFILES/install.sh"

    if ($LASTEXITCODE -eq 0) {
        Log "WSL Linux setup complete"
    } else {
        Warn "WSL installer exited with code $LASTEXITCODE. Check the output above."
    }
}

# -- Main ----------------------------------------------------------------------
function Main {
    Show-Banner

    if (-not (Test-Admin)) {
        Err "Please run this script as Administrator (right-click -> 'Run as Administrator')."
    }

    # Allow scripts to run for this session and future re-runs
    Set-ScriptExecutionPolicy

    # Clean up the resume task if this is a post-reboot run
    Remove-ResumeTask

    Install-Winget
    Install-WSL
    Install-NerdFont
    Install-ClaudeCode
    Install-ClaudeConfig
    Invoke-WSLInstaller

    # Restore execution policy now that we're fully done
    Restore-ExecutionPolicy

    Write-Host ""
    Write-Host "  All done!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Post-install checklist:" -ForegroundColor Yellow
    Write-Host "  * Run 'claude' in PowerShell to log in to Claude Code" -ForegroundColor Gray
    Write-Host "  * Open WSL (Ubuntu) for your zsh/neovim environment" -ForegroundColor Gray
    Write-Host "  * Run 'p10k configure' inside WSL to tune the prompt" -ForegroundColor Gray
    Write-Host ""
}

Main
