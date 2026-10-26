#!/bin/bash
# Remove only this checkout's recorded links, preserving user replacements.
set -euo pipefail
umask 077

fail() { printf 'unlink: %s\n' "$*" >&2; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
TAB=$(printf '\t')
DRY_RUN=0
case "${1-}" in
  '') ;;
  --dry-run) DRY_RUN=1; shift ;;
  -h|--help) printf 'Usage: bash scripts/unlink.sh [--dry-run]\n'; exit 0 ;;
  *) fail "Unknown argument: $1" ;;
esac
[ "$#" -eq 0 ] || fail 'Unexpected arguments.'
[ -n "${HOME-}" ] && [ -d "$HOME" ] || fail 'HOME must be an existing directory.'
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
HOME_DIR=$(cd "$HOME" && pwd -P)
[ "$HOME_DIR" != / ] || fail 'Refusing to use / as HOME.'
STATE_DIR="$HOME_DIR/.local/state/dotfile"
STATE_FILE="$STATE_DIR/links.tsv"
LOCK="$STATE_DIR/.lock"
STATE_TMP=''

safe_text() { case "$1" in *"$TAB"*|*$'\n'*|*$'\r'*) return 1 ;; esac; }
safe_absolute() {
  safe_text "$1" || return 1
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *//*|*/./*|*/../*|*/.|*/..) return 1 ;; esac
}
safe_text "$ROOT" && safe_text "$HOME_DIR" || fail 'Paths cannot contain tabs or newlines.'
check_parent() {
  local p resolved
  p=$(dirname "$1")
  while ! [ -d "$p" ]; do
    exists "$p" && fail "Parent is not an accessible directory: $p"
    [ "$p" != / ] || fail "Cannot resolve parent of $1"
    p=$(dirname "$p")
  done
  resolved=$(cd "$p" && pwd -P) || fail "Cannot inspect parent: $p"
  case "$resolved/" in "$HOME_DIR/"*) ;; *) fail "Parent resolves outside HOME: $1" ;; esac
}
parse_record() {
  local rest
  case "$1" in *"$TAB"*) ;; *) fail 'Malformed linker journal.' ;; esac
  RECORD_SOURCE=${1%%"$TAB"*}; rest=${1#*"$TAB"}
  case "$rest" in *"$TAB"*) ;; *) fail 'Malformed linker journal.' ;; esac
  RECORD_DEST=${rest%%"$TAB"*}; RECORD_BACKUP=${rest#*"$TAB"}
  safe_absolute "$RECORD_SOURCE" && safe_absolute "$RECORD_DEST" || fail 'Unsafe path in linker journal.'
  case "$RECORD_DEST" in "$HOME_DIR/"*) ;; *) fail 'Journal destination is outside HOME.' ;; esac
  case "$RECORD_DEST/" in "$ROOT/"*) fail 'Journal destination overlaps this repository.' ;; esac
  case "$ROOT/" in "$RECORD_DEST/"*) fail 'Journal destination contains this repository.' ;; esac
  case "$RECORD_DEST/" in "$STATE_DIR/"*) fail 'Journal destination overlaps linker state.' ;; esac
  case "$STATE_DIR/" in "$RECORD_DEST/"*) fail 'Journal destination contains linker state.' ;; esac
  check_parent "$RECORD_DEST"
  if [ -n "$RECORD_BACKUP" ]; then
    safe_absolute "$RECORD_BACKUP" || fail 'Unsafe backup path in linker journal.'
    case "$RECORD_BACKUP" in "$STATE_DIR/backups/"*) ;; *) fail 'Backup is outside linker backup storage.' ;; esac
    check_parent "$RECORD_BACKUP"
  fi
}
[ ! -L "$STATE_FILE" ] || fail 'Refusing a symlink as the linker journal.'
if [ ! -f "$STATE_FILE" ]; then printf 'No managed links recorded.\n'; exit 0; fi
SOURCES=(); DESTINATIONS=(); BACKUPS=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  parse_record "$line"
  case "$RECORD_SOURCE" in "$ROOT/"*) ;; *) continue ;; esac
  for previous in "${DESTINATIONS[@]+${DESTINATIONS[@]}}"; do
    [ "$previous" != "$RECORD_DEST" ] || fail "Duplicate journal destination: $RECORD_DEST"
  done
  SOURCES[${#SOURCES[@]}]=$RECORD_SOURCE
  DESTINATIONS[${#DESTINATIONS[@]}]=$RECORD_DEST
  BACKUPS[${#BACKUPS[@]}]=$RECORD_BACKUP
done < "$STATE_FILE"

write_without() {
  local destination current rest current_dest
  destination=$1
  STATE_TMP=$(mktemp "$STATE_DIR/.links.XXXXXX") || return 1
  while IFS= read -r current || [ -n "$current" ]; do
    [ -n "$current" ] || continue
    rest=${current#*"$TAB"}; current_dest=${rest%%"$TAB"*}
    [ "$current_dest" = "$destination" ] || printf '%s\n' "$current" >> "$STATE_TMP" || return 1
  done < "$STATE_FILE"
  mv -f "$STATE_TMP" "$STATE_FILE" || return 1
  STATE_TMP=''
}
cleanup() {
  local code=$?
  trap - EXIT INT TERM; set +e
  [ -z "$STATE_TMP" ] || rm -f "$STATE_TMP"
  [ "$DRY_RUN" -eq 1 ] || rmdir "$LOCK" 2>/dev/null
  exit "$code"
}
if [ "$DRY_RUN" -eq 0 ]; then
  [ ! -L "$STATE_DIR" ] || fail 'Refusing a symlink as the linker state directory.'
  check_parent "$STATE_FILE"
  mkdir "$LOCK" 2>/dev/null || fail "Another linker is running, or a stale lock exists: $LOCK"
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

conflicts=0
for ((i=${#SOURCES[@]}-1; i>=0; i--)); do
  src=${SOURCES[$i]}; dest=${DESTINATIONS[$i]}; backup=${BACKUPS[$i]}
  if exists "$dest"; then
    if ! [ -L "$dest" ] || [ "$(readlink "$dest")" != "$src" ]; then
      printf 'Preserving user replacement; journal retained: %s\n' "$dest" >&2
      conflicts=1; continue
    fi
  fi
  if [ -n "$backup" ] && ! exists "$backup"; then
    printf 'Backup missing; destination and journal retained: %s\n' "$backup" >&2
    conflicts=1; continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    exists "$dest" && printf 'Would unlink: %s\n' "$dest"
    [ -z "$backup" ] || printf 'Would restore: %s -> %s\n' "$backup" "$dest"
    continue
  fi
  if exists "$dest"; then rm "$dest"; printf 'Unlinked: %s\n' "$dest"; fi
  if [ -n "$backup" ]; then
    ! exists "$dest" || fail "Destination reappeared; refusing to replace it: $dest"
    mkdir -p "$(dirname "$dest")"
    mv "$backup" "$dest"
    printf 'Restored original: %s\n' "$dest"
  fi
  write_without "$dest"
done
exit "$conflicts"
