# work_dotfiles

Personal dotfiles for macOS, Linux, and Windows (WSL2). One script sets everything up from scratch.

## What's included

| Config | Path on system |
|---|---|
| zsh + oh-my-zsh | `~/.zshrc` |
| Powerlevel10k prompt | `~/.p10k.zsh` |
| Neovim | `~/.config/nvim/init.vim` |
| Ghostty terminal | `~/.config/ghostty/config` |
| Claude Code | `~/.claude/settings.json` |

**Shell:** zsh + [oh-my-zsh](https://ohmyz.sh) · theme: [Powerlevel10k](https://github.com/romkatv/powerlevel10k) · plugins: `git`, `tmux`, `zsh-autosuggestions`, `zsh-syntax-highlighting`

**Editor:** Neovim with [vim-plug](https://github.com/junegunn/vim-plug) + [gruvbox](https://github.com/morhetz/gruvbox)

**Terminal:** [Ghostty](https://ghostty.org) (macOS / Linux only)

---

## Fresh install

### macOS / Linux

```bash
git clone https://github.com/choijay12/work_dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

The script will:
1. Detect your OS and package manager (`brew`, `apt`, `pacman`, `dnf`)
2. Install: `git`, `zsh`, `neovim`, `tmux`, `node`, `ghostty`
3. Install [MesloLGS NF](https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k) (Nerd Font required for the prompt)
4. Install oh-my-zsh, Powerlevel10k, and zsh plugins
5. Install vim-plug and run `:PlugInstall` for Neovim
6. Install Claude Code (`npm install -g @anthropic-ai/claude-code`)
7. Symlink all configs (existing files are backed up with a `.bak` timestamp)
8. Set zsh as your default shell

After it finishes, restart your terminal.

> If prompt icons look wrong, make sure your terminal font is set to **MesloLGS NF**.
> Run `p10k configure` any time to reconfigure the prompt.

---

### Windows

> The Windows installer sets up Claude Code natively and runs the Linux installer inside WSL2 (Ubuntu). Ghostty is **not** used on Windows — use Windows Terminal or another emulator of your choice.

**Requirements:** Run PowerShell as Administrator.

Since scripts are blocked by default on Windows, the first run requires a bypass flag. The script will set the execution policy automatically from that point on and restore it when done.

```powershell
git clone https://github.com/choijay12/work_dotfiles.git $HOME\dotfiles
cd $HOME\dotfiles
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The script will:
1. Check for `winget` (install via Microsoft Store if missing)
2. Enable WSL2 + install Ubuntu 24.04 — **a reboot may be required** after this step; re-run the script after rebooting
3. Install MesloLGS NF fonts to Windows
4. Install Node.js and Claude Code natively
5. Symlink the Claude Code config
6. Run `install.sh` inside WSL to finish the Linux setup

After setup, open WSL (Ubuntu) for your zsh/neovim environment.

---

## Keeping configs in sync

After changing any config on a machine, run:

```bash
./sync.sh
```

This copies your live configs into the repo, commits with an auto-generated message (OS + hostname + timestamp), and pushes to `origin/main`.

**Preview changes without writing anything:**

```bash
./sync.sh --dry-run
```

On Windows, run `sync.sh` from inside WSL to sync the Linux-side configs.

---

## Repo structure

```
dotfiles/
├── configs/
│   ├── zsh/
│   │   ├── .zshrc
│   │   └── .p10k.zsh
│   ├── nvim/
│   │   └── init.vim
│   ├── ghostty/
│   │   └── config
│   └── claude/
│       └── settings.json
├── install.sh      # macOS + Linux installer
├── install.ps1     # Windows installer (run as Admin)
├── sync.sh         # copy live configs → repo → push
└── README.md
```

---

## Adding a new config

1. Add the file to `configs/` in the appropriate subdirectory.
2. Add a `link_config` line in the `install_configs()` function of `install.sh` (and `install.ps1` if needed on Windows).
3. Add a corresponding entry to the `CONFIG_MAP` array in `sync.sh`.
4. Run `./sync.sh` to push the update.
