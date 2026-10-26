#!/bin/bash
# Install missing selected software. This script never initializes Git or links configs.
set -euo pipefail

DOTFILES_BOOT_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES_BOOT_REPO="$(CDPATH= cd -- "$DOTFILES_BOOT_SCRIPT_DIR/.." && pwd -P)"
DOTFILES_BOOT_DRY_RUN=0
DOTFILES_BOOT_TMP=''
DOTFILES_BOOT_LOCK=''
DOTFILES_BOOT_BREW=''
DOTFILES_BOOT_OMZ_REVISION=''

usage() {
  cat <<'USAGE'
Usage: bash scripts/bootstrap.sh [--dry-run] [--help]

Install only missing brew/cask entries from homebrew/Brewfile. Existing
packages and manually installed Ghostty/Zed app bundles are left alone.
Existing Oh My Zsh is left untouched; a missing framework is restored from
the pinned official archive without cloning or initializing a Git repository.

On another Mac, prepare-host.py adapts copied paths and restore-fonts.py
restores captured fonts. Both are skipped on the preserved current Mac,
identified by the ignored .local/preserve-current-host marker.

--dry-run  Show the plan and run helpers in read-only preview mode.
--help     Show this help.

Homebrew must already be installed: https://brew.sh/
Run bash scripts/link.sh separately after reviewing the setup.
USAGE
}

say() { printf '%s\n' "$*"; }
die() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$DOTFILES_BOOT_TMP" ] && [ -d "$DOTFILES_BOOT_TMP" ]; then
    rm -rf -- "$DOTFILES_BOOT_TMP"
  fi
  if [ -n "$DOTFILES_BOOT_LOCK" ] && [ -d "$DOTFILES_BOOT_LOCK" ]; then
    rmdir -- "$DOTFILES_BOOT_LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for argument in "$@"; do
  case "$argument" in
    --dry-run) DOTFILES_BOOT_DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $argument" ;;
  esac
done

# Parsing, rather than sourcing the Brewfile, prevents arbitrary Ruby execution.
# Validate the complete manifest before any installation begins.
parse_brewfile() {
  local line='' line_number=0
  local entry_pattern='^[[:space:]]*(brew|cask)[[:space:]]+"([A-Za-z0-9][A-Za-z0-9@+._-]*(/[A-Za-z0-9][A-Za-z0-9@+._-]*)*)"[[:space:]]*(#.*)?$'
  local blank_pattern='^[[:space:]]*(#.*)?$'
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    if [[ "$line" =~ $blank_pattern ]]; then
      continue
    elif [[ "$line" =~ $entry_pattern ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      printf 'bootstrap: Unsupported Brewfile syntax at line %s. Only brew "name" and cask "name" entries are supported.\n' "$line_number" >&2
      return 1
    fi
  done < "$DOTFILES_BOOT_REPO/homebrew/Brewfile"
}

[ -f "$DOTFILES_BOOT_REPO/homebrew/Brewfile" ] || die 'homebrew/Brewfile is missing.'
DOTFILES_BOOT_MANIFEST="$(parse_brewfile)" || exit 1

if command -v brew >/dev/null 2>&1; then
  DOTFILES_BOOT_BREW="$(command -v brew)"
elif [ -x /opt/homebrew/bin/brew ]; then
  DOTFILES_BOOT_BREW=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
  DOTFILES_BOOT_BREW=/usr/local/bin/brew
else
  die 'Homebrew is required. Install it from https://brew.sh/ and rerun this script. No installer has been downloaded or executed.'
fi

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_INSTALL_UPGRADE=1
DOTFILES_BOOT_BREW_PREFIX="$("$DOTFILES_BOOT_BREW" --prefix)" || die 'Cannot determine the Homebrew prefix.'
[ -n "$DOTFILES_BOOT_BREW_PREFIX" ] || die 'Homebrew returned an empty installation prefix.'
export PATH="$DOTFILES_BOOT_BREW_PREFIX/bin:$DOTFILES_BOOT_BREW_PREFIX/sbin:$PATH"

DOTFILES_BOOT_OMZ_DIR="$DOTFILES_BOOT_REPO/zsh/oh-my-zsh"
if [ -e "$DOTFILES_BOOT_OMZ_DIR" ] || [ -L "$DOTFILES_BOOT_OMZ_DIR" ]; then
  [ -f "$DOTFILES_BOOT_OMZ_DIR/oh-my-zsh.sh" ] || die 'zsh/oh-my-zsh exists but is not a complete framework; it will not be replaced.'
else
  [ -f "$DOTFILES_BOOT_REPO/zsh/oh-my-zsh-version.txt" ] || die 'The pinned Oh My Zsh revision file is missing.'
  DOTFILES_BOOT_OMZ_REVISION="$(tr -d '[:space:]' < "$DOTFILES_BOOT_REPO/zsh/oh-my-zsh-version.txt")"
  [[ "$DOTFILES_BOOT_OMZ_REVISION" =~ ^[0-9a-f]{40}$ ]] || die 'The Oh My Zsh revision must be a full lowercase 40-character commit ID.'
  command -v curl >/dev/null 2>&1 || die 'curl is required to download the pinned framework.'
  command -v tar >/dev/null 2>&1 || die 'tar is required to unpack the pinned framework.'
fi

if [ ! -f "$DOTFILES_BOOT_REPO/.local/preserve-current-host" ]; then
  [ -f "$DOTFILES_BOOT_SCRIPT_DIR/prepare-host.py" ] || die 'scripts/prepare-host.py is missing.'
  [ -f "$DOTFILES_BOOT_SCRIPT_DIR/restore-fonts.py" ] || die 'scripts/restore-fonts.py is missing.'
fi

formula_present() {
  local installed=''
  installed="$("$DOTFILES_BOOT_BREW" list --formula --versions "$1" 2>/dev/null)" || return 1
  [ -n "$installed" ]
}

manual_app_present() {
  local bundle=''
  case "${1##*/}" in
    ghostty) bundle=Ghostty.app ;;
    zed) bundle=Zed.app ;;
    *) return 1 ;;
  esac
  [ -f "/Applications/$bundle/Contents/Info.plist" ] ||
    [ -f "$HOME/Applications/$bundle/Contents/Info.plist" ]
}

cask_present() {
  local installed=''
  if manual_app_present "$1"; then return 0; fi
  installed="$("$DOTFILES_BOOT_BREW" list --cask --versions "$1" 2>/dev/null)" || return 1
  [ -n "$installed" ]
}

while IFS=$'\t' read -r kind package; do
  [ -n "$kind" ] || continue
  case "$kind" in
    brew)
      if formula_present "$package"; then
        say "Already installed: $package"
      elif [ "$DOTFILES_BOOT_DRY_RUN" -eq 1 ]; then
        say "Would install formula: $package"
      else
        say "Installing missing formula: $package"
        "$DOTFILES_BOOT_BREW" install --formula "$package"
      fi
      ;;
    cask)
      if cask_present "$package"; then
        say "Already available: $package"
      elif [ "$DOTFILES_BOOT_DRY_RUN" -eq 1 ]; then
        say "Would install cask: $package"
      else
        say "Installing missing cask: $package"
        "$DOTFILES_BOOT_BREW" install --cask "$package"
      fi
      ;;
    *) die 'Internal manifest parsing error.' ;;
  esac
done <<< "$DOTFILES_BOOT_MANIFEST"

restore_omz() {
  local archive='' expected='' candidate='' captured='' destination=''
  if [ -f "$DOTFILES_BOOT_OMZ_DIR/oh-my-zsh.sh" ]; then
    say 'Existing Oh My Zsh framework left untouched.'
    return
  fi
  if [ "$DOTFILES_BOOT_DRY_RUN" -eq 1 ]; then
    say "Would restore official Oh My Zsh archive at revision $DOTFILES_BOOT_OMZ_REVISION."
    say 'Would restore captured completions only where the new framework has no file.'
    return
  fi

  # Stage beside the destination so the final move stays on one filesystem.
  mkdir -p -- "$DOTFILES_BOOT_REPO/zsh"
  if ! mkdir -- "$DOTFILES_BOOT_REPO/zsh/.oh-my-zsh-bootstrap.lock"; then
    die 'An Oh My Zsh bootstrap lock already exists; another setup may be running.'
  fi
  DOTFILES_BOOT_LOCK="$DOTFILES_BOOT_REPO/zsh/.oh-my-zsh-bootstrap.lock"
  if [ -e "$DOTFILES_BOOT_OMZ_DIR" ] || [ -L "$DOTFILES_BOOT_OMZ_DIR" ]; then
    die 'The framework appeared during setup; it has not been replaced.'
  fi
  DOTFILES_BOOT_TMP="$(mktemp -d "$DOTFILES_BOOT_REPO/zsh/.oh-my-zsh-bootstrap.XXXXXX")"
  archive="$DOTFILES_BOOT_TMP/framework.tar.gz"
  expected="ohmyzsh-$DOTFILES_BOOT_OMZ_REVISION"
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$archive" "https://github.com/ohmyzsh/ohmyzsh/archive/$DOTFILES_BOOT_OMZ_REVISION.tar.gz"

  tar -tzf "$archive" | awk -v expected="$expected" '
    BEGIN { count = 0; invalid = 0 }
    { count++; split($0, parts, "/"); if (parts[1] != expected || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /^\//) invalid = 1 }
    END { if (count == 0 || invalid) exit 1 }
  ' || die 'The downloaded archive has an unexpected layout; nothing was installed.'
  tar -xzf "$archive" -C "$DOTFILES_BOOT_TMP" --no-same-owner
  candidate="$DOTFILES_BOOT_TMP/$expected"
  [ -f "$candidate/oh-my-zsh.sh" ] || die 'The archive does not contain a complete framework.'

  if [ -d "$DOTFILES_BOOT_REPO/zsh/completions" ]; then
    mkdir -p -- "$candidate/completions"
    for captured in "$DOTFILES_BOOT_REPO/zsh/completions/"*; do
      [ -f "$captured" ] || continue
      destination="$candidate/completions/$(basename -- "$captured")"
      if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
        cp -p -- "$captured" "$destination"
      fi
    done
  fi
  if [ -e "$DOTFILES_BOOT_OMZ_DIR" ] || [ -L "$DOTFILES_BOOT_OMZ_DIR" ]; then
    die 'The framework appeared during download; it has not been replaced.'
  fi
  mv -n -- "$candidate" "$DOTFILES_BOOT_OMZ_DIR"
  [ -f "$DOTFILES_BOOT_OMZ_DIR/oh-my-zsh.sh" ] || die 'Could not place the restored framework.'
  say 'Restored the pinned Oh My Zsh framework without Git initialization.'
}

restore_omz

if [ -f "$DOTFILES_BOOT_REPO/.local/preserve-current-host" ]; then
  say 'Current-host preservation marker found; path adaptation and font restoration skipped.'
else
  command -v python3 >/dev/null 2>&1 || die 'python3 is required for host preparation and font restoration. Install it explicitly and rerun bootstrap.'
  if [ "$DOTFILES_BOOT_DRY_RUN" -eq 1 ]; then
    python3 -B "$DOTFILES_BOOT_SCRIPT_DIR/prepare-host.py" --dry-run
    python3 -B "$DOTFILES_BOOT_SCRIPT_DIR/restore-fonts.py" --dry-run
  else
    python3 -B "$DOTFILES_BOOT_SCRIPT_DIR/prepare-host.py"
    python3 -B "$DOTFILES_BOOT_SCRIPT_DIR/restore-fonts.py"
  fi
fi

# These were found in the captured shell configuration but are intentionally
# outside the curated Homebrew selection. Report them without running installers.
if [ ! -f "$HOME/.nvm/nvm.sh" ]; then
  say 'Optional shell prerequisite missing: NVM (~/.nvm/nvm.sh); install it separately if needed.'
fi
if ! command -v go >/dev/null 2>&1 && [ ! -x "$HOME/.local/opt/go/bin/go" ] && [ ! -x /usr/local/go/bin/go ]; then
  say 'Optional shell prerequisite missing: Go; install it separately if needed.'
fi
if ! command -v but >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/but" ]; then
  say 'Optional shell prerequisite missing: GitButler CLI (but); install it separately if needed.'
fi
for optional_path in \
  "$HOME/.antigravity-ide/antigravity-ide/bin" \
  "$HOME/.opencode/bin" \
  "$HOME/.lmstudio/bin" \
  "$HOME/Library/Application Support/JetBrains/Toolbox/scripts" \
  /usr/local/mysql-9.6.0-macos15-arm64/bin; do
  if [ ! -d "$optional_path" ]; then
    say "Optional machine-specific PATH directory unavailable: $optional_path"
  fi
done

if [ "$DOTFILES_BOOT_DRY_RUN" -eq 1 ]; then
  say 'Dry run complete. No installations, downloads, links, or configuration changes were made.'
else
  say 'Bootstrap complete. Review the host setup, then run: bash scripts/link.sh'
fi
