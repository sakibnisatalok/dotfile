# Personal dotfiles

The source Mac's Zed settings, Zsh startup files, and Ghostty configuration are preserved byte-for-byte. Neovim has a fresh, empty `nvim/init.lua`. No repository has been initialized, no submodules are used, and VS Code is excluded.

## What is managed

`links.tsv` maps each repository path to its familiar home-directory location. Edit the repository copy after linking; the applications access it through the symlink.

- `zsh/.zshrc` and `.zprofile`: the existing startup files, without preference or alias changes.
- `zsh/oh-my-zsh/`: the existing working framework, ignored by the parent repository. Its pre-existing Git metadata is preserved on the source Mac; bootstrap never initializes Git. Another Mac downloads the recorded framework revision from an official archive.
- `zsh/envman-compat/`: the existing small PATH loader. The original `.zshrc` sources `~/.config/envman/load.sh`, so that compatibility path remains a symlink. Removing it would change the working shell.
- `zsh/completions/`: captured Docker and Kubernetes completion files, restored when bootstrap creates a new framework.
- `zsh/custom/`: an empty future customization area. The preserved `.zshrc` currently uses the framework's own `custom/` folder, which contains only its stock examples. This future area is not automatically sourced.
- `ghostty/config`: the existing Gruvbox-based theme, custom palette, font request, padding, opacity, clipboard behavior, and keybindings.
- `zed/settings.json`: original JSONC including comments and trailing commas. Conversations, prompt databases, sign-ins, caches, and extension work directories remain outside the repository.
- `zed/extensions.json`: all 42 installed extension IDs and captured versions. Theme extensions containing the word “neovim” are Zed extensions and are retained.
- `fonts/files/`: exact source-Mac JetBrains Mono and Hack Nerd font files needed to reproduce font availability. Existing source-Mac fonts are not modified.
- `vim/vimrc` and `tmux/tmux.conf`: small new starter configurations. Existing running tmux sessions are not reloaded or killed.
- `homebrew/Brewfile`: an explicit allowlist of Neovim, tmux, pyenv, zoxide, MySQL client, Ghostty, and Zed. This does not describe all installed software. The former standalone `~/Brewfile` is backed up and replaced by a symlink.

The requested Ghostty family `JetBrainsMono Nerd Font` was not present among the captured installed fonts. Its request is deliberately unchanged, and a newly matching font is not installed on the source Mac because that could change its current appearance.

## This Mac

The ignored `.local/preserve-current-host` marker keeps bootstrap from rewriting paths, adding Zed extension settings, or changing fonts here. Existing applications are left alone. To inspect or reapply links:

```sh
cd "$HOME/dotfile"
bash scripts/link.sh --dry-run
bash scripts/link.sh
```

The scripts use Bash 3.2-compatible syntax and can be launched from a Zsh terminal. They do not need executable permission when invoked with `bash`.

## Another Mac

1. Install Apple's command-line tools and Homebrew from their official sources. The scripts do not run a downloaded Homebrew installer for you. Python 3 is required for the portable host/font helpers; Apple's command-line tools normally supply it.
2. Download or clone this repository. Git initialization, commits, and publishing remain your decision. Do not copy the ignored `.local/` directory or downloaded framework from this Mac; those are local state.
3. Inspect the curated Brewfile, then run:

```sh
cd "$HOME/dotfile"
bash scripts/bootstrap.sh --dry-run
bash scripts/bootstrap.sh
bash scripts/link.sh --dry-run
bash scripts/link.sh
```

Bootstrap installs only missing selected packages. Existing Ghostty/Zed app bundles are recognized even if installed manually. It does not upgrade installed packages, start services, delete unlisted packages, or apply links automatically. Homebrew installs any dependencies its selected software needs.

On a new Mac, `prepare-host.py` creates ignored copies under `.local/`: it adapts the original home path and Homebrew prefix, uses the selected MySQL client's path, guards an unavailable GitButler completion command, and adds Zed's supported `auto_install_extensions` map. Raw configuration snapshots remain unchanged. `link.sh` automatically uses the generated `.local/links.tsv` when present. Zed restores extension IDs on launch; captured versions are inventory, not a guarantee that the extension gallery will still supply the same versions.

`restore-fonts.py` checks hashes and installs missing captured font files. It refuses to overwrite a different file with the same name. The font files retain their embedded upstream copyright/license metadata.

The shell also references separately installed NVM/Node, Go, GitButler, Antigravity, OpenCode, LM Studio, and JetBrains Toolbox. These applications and their versions, accounts, language runtimes, project files, and services are not copied or installed by this curated setup. Bootstrap reports missing prerequisites. Zed's account/model access needs a separate sign-in on another Mac.

For exact instructions about extension restoration, see https://zed.dev/docs/extensions/installing-extensions. The Brewfile is a software selection, not a complete version lock; app versions and OS rendering may differ on another Mac.

## Backups and restoration

Original destinations are moved, not erased, to `~/.local/state/dotfile/backups/<UTC-time>-<process-id>/`. The source/destination/backup journal is `~/.local/state/dotfile/links.tsv`. Neovim's old configuration, plugins, cache, and state are deliberately purged as requested, so those are not available to restore.

```sh
cd "$HOME/dotfile"
bash scripts/unlink.sh --dry-run
bash scripts/unlink.sh
```

Unlink removes only exact recorded symlinks into this checkout. It restores originals where safe, preserves user-replaced files, and retains records for unresolved conflicts. Do not move this repository while its absolute symlinks are active: unlink first, move it, and link again.

## Adding future configuration

Create an app folder and add a literal tab-separated source/destination row to `links.tsv`. Sources are repository-relative; destinations are home-relative. Avoid overlapping managed destinations. Preview `link.sh` before applying it. Secrets and private overrides belong in ignored local files, not Git. Review captured settings before your own first commit.

`metadata/original-configs.json` contains checksums for preservation verification. `metadata/source-host.json` records only the original home/prefix/architecture used for path adaptation. Neither initializes or configures Git.
