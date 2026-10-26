#!/bin/bash
# Bash 3.2 compatible. Only configurations explicitly listed in links.tsv are managed.
set -euo pipefail
umask 077

fail() { printf 'link: %s\n' "$*" >&2; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
TAB=$(printf '\t')
DRY_RUN=0
case "${1-}" in
  '') ;;
  --dry-run) DRY_RUN=1; shift ;;
  -h|--help) printf 'Usage: bash scripts/link.sh [--dry-run]\n'; exit 0 ;;
  *) fail "Unknown argument: $1" ;;
esac
[ "$#" -eq 0 ] || fail 'Unexpected arguments.'
[ -n "${HOME-}" ] && [ -d "$HOME" ] || fail 'HOME must be an existing directory.'
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
HOME_DIR=$(cd "$HOME" && pwd -P)
[ "$HOME_DIR" != / ] || fail 'Refusing to use / as HOME.'
STATE_DIR="$HOME_DIR/.local/state/dotfile"
STATE_FILE="$STATE_DIR/links.tsv"
BACKUP_RUN="$STATE_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
MANIFEST=${DOTFILE_LINKS_FILE:-}
if [ -z "$MANIFEST" ]; then
  if [ -f "$ROOT/.local/links.tsv" ]; then MANIFEST="$ROOT/.local/links.tsv";
  else MANIFEST="$ROOT/links.tsv"; fi
fi
[ -f "$MANIFEST" ] || fail "Manifest not found: $MANIFEST"

safe_text() { case "$1" in *"$TAB"*|*$'\n'*|*$'\r'*) return 1 ;; esac; }
safe_relative() {
  safe_text "$1" || return 1
  case "$1" in ''|/*|*/|*//*|.|..|./*|../*|*/./*|*/../*|*/.|*/..) return 1 ;; esac
}
safe_absolute() {
  safe_text "$1" || return 1
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *//*|*/./*|*/../*|*/.|*/..) return 1 ;; esac
}
safe_text "$ROOT" && safe_text "$HOME_DIR" && safe_text "$MANIFEST" || fail 'Paths cannot contain tabs or newlines.'

# Refuse directory traversal through an existing symlink to a place outside HOME.
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
check_destination() {
  case "$1" in "$HOME_DIR/"*) ;; *) fail "Destination is outside HOME: $1" ;; esac
  case "$1/" in "$ROOT/"*) fail "Destination overlaps this repository: $1" ;; esac
  case "$ROOT/" in "$1/"*) fail "Destination contains this repository: $1" ;; esac
  case "$1/" in "$STATE_DIR/"*) fail "Destination overlaps linker state: $1" ;; esac
  case "$STATE_DIR/" in "$1/"*) fail "Destination contains linker state: $1" ;; esac
  check_parent "$1"
}
parse_record() {
  local rest
  case "$1" in *"$TAB"*) ;; *) fail 'Malformed linker journal.' ;; esac
  RECORD_SOURCE=${1%%"$TAB"*}; rest=${1#*"$TAB"}
  case "$rest" in *"$TAB"*) ;; *) fail 'Malformed linker journal.' ;; esac
  RECORD_DEST=${rest%%"$TAB"*}; RECORD_BACKUP=${rest#*"$TAB"}
  safe_absolute "$RECORD_SOURCE" && safe_absolute "$RECORD_DEST" || fail 'Unsafe path in linker journal.'
  check_destination "$RECORD_DEST"
  if [ -n "$RECORD_BACKUP" ]; then
    safe_absolute "$RECORD_BACKUP" || fail 'Unsafe backup path in linker journal.'
    case "$RECORD_BACKUP" in "$STATE_DIR/backups/"*) ;; *) fail 'Backup is outside linker backup storage.' ;; esac
  fi
}

# Preflight the complete manifest before any configuration is moved.
SOURCES=(); DESTINATIONS=(); REL_DESTINATIONS=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  case "$line" in *"$TAB"*) ;; *) fail 'Each manifest row needs two tab-separated fields.' ;; esac
  src_rel=${line%%"$TAB"*}; dest_rel=${line#*"$TAB"}
  safe_relative "$src_rel" && safe_relative "$dest_rel" || fail "Unsafe manifest row: $line"
  src="$ROOT/$src_rel"; dest="$HOME_DIR/$dest_rel"
  [ -e "$src" ] || fail "Source is missing or a dangling symlink: $src"
  check_destination "$dest"
  for previous in "${DESTINATIONS[@]+${DESTINATIONS[@]}}"; do
    [ "$previous" != "$dest" ] || fail "Duplicate manifest destination: $dest"
    case "$dest/" in "$previous/"*) fail "Overlapping manifest destinations: $previous and $dest" ;; esac
    case "$previous/" in "$dest/"*) fail "Overlapping manifest destinations: $previous and $dest" ;; esac
  done
  SOURCES[${#SOURCES[@]}]="$src"
  DESTINATIONS[${#DESTINATIONS[@]}]="$dest"
  REL_DESTINATIONS[${#REL_DESTINATIONS[@]}]="$dest_rel"
done < "$MANIFEST"
[ "${#SOURCES[@]}" -gt 0 ] || fail 'Manifest contains no links.'

find_record() {
  FOUND=0; FOUND_SOURCE=''; FOUND_BACKUP=''
  [ -f "$STATE_FILE" ] || return 0
  while IFS= read -r journal_line || [ -n "$journal_line" ]; do
    [ -n "$journal_line" ] || continue
    parse_record "$journal_line"
    if [ "$RECORD_DEST" = "$1" ]; then
      [ "$FOUND" -eq 0 ] || fail "Duplicate journal destination: $1"
      FOUND=1; FOUND_SOURCE="$RECORD_SOURCE"; FOUND_BACKUP="$RECORD_BACKUP"
    fi
  done < "$STATE_FILE"
}
[ ! -L "$STATE_FILE" ] || fail 'Refusing a symlink as the linker journal.'
for ((i=0; i<${#SOURCES[@]}; i++)); do
  find_record "${DESTINATIONS[$i]}"
  if [ "$FOUND" -eq 1 ]; then
    [ "$FOUND_SOURCE" = "${SOURCES[$i]}" ] || fail "Destination is already managed by another source: ${DESTINATIONS[$i]}"
    if exists "${DESTINATIONS[$i]}"; then
      [ -L "${DESTINATIONS[$i]}" ] && [ "$(readlink "${DESTINATIONS[$i]}")" = "${SOURCES[$i]}" ] || fail "A managed destination was replaced; preserving it: ${DESTINATIONS[$i]}"
    fi
  fi
done

if [ "$DRY_RUN" -eq 1 ]; then
  for ((i=0; i<${#SOURCES[@]}; i++)); do
    src=${SOURCES[$i]}; dest=${DESTINATIONS[$i]}
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
      printf 'Already linked: %s\n' "$dest"
    else
      exists "$dest" && printf 'Would back up: %s\n' "$dest"
      printf 'Would link: %s -> %s\n' "$dest" "$src"
    fi
  done
  exit 0
fi

check_parent "$STATE_DIR/links.tsv"
mkdir -p "$STATE_DIR"
[ ! -L "$STATE_DIR" ] || fail 'Refusing a symlink as the linker state directory.'
LOCK="$STATE_DIR/.lock"
mkdir "$LOCK" 2>/dev/null || fail "Another linker is running, or a stale lock exists: $LOCK"
STATE_TMP=''; ACTIVE=0; ACTIVE_SOURCE=''; ACTIVE_DEST=''; ACTIVE_BACKUP=''; ACTIVE_ORIGINAL=0

# Replace one destination's journal row atomically; an empty source removes it.
write_record() {
  local source destination backup current rest current_dest
  source=$1; destination=$2; backup=$3
  STATE_TMP=$(mktemp "$STATE_DIR/.links.XXXXXX") || return 1
  if [ -f "$STATE_FILE" ]; then
    while IFS= read -r current || [ -n "$current" ]; do
      [ -n "$current" ] || continue
      rest=${current#*"$TAB"}; current_dest=${rest%%"$TAB"*}
      [ "$current_dest" = "$destination" ] || printf '%s\n' "$current" >> "$STATE_TMP" || return 1
    done < "$STATE_FILE"
  fi
  if [ -n "$source" ]; then printf '%s\t%s\t%s\n' "$source" "$destination" "$backup" >> "$STATE_TMP" || return 1; fi
  mv -f "$STATE_TMP" "$STATE_FILE" || return 1
  STATE_TMP=''
}
cleanup() {
  local code=$? recoverable
  trap - EXIT INT TERM; set +e
  if [ "$ACTIVE" -eq 1 ]; then
    recoverable=1
    if [ -L "$ACTIVE_DEST" ] && [ "$(readlink "$ACTIVE_DEST")" = "$ACTIVE_SOURCE" ]; then
      rm "$ACTIVE_DEST" || recoverable=0
    fi
    if [ -n "$ACTIVE_BACKUP" ] && exists "$ACTIVE_BACKUP"; then
      if ! exists "$ACTIVE_DEST"; then mv "$ACTIVE_BACKUP" "$ACTIVE_DEST" || recoverable=0;
      else recoverable=0; fi
    elif [ "$ACTIVE_ORIGINAL" -eq 1 ]; then
      exists "$ACTIVE_DEST" || recoverable=0
    elif exists "$ACTIVE_DEST"; then recoverable=0
    fi
    if [ "$recoverable" -eq 1 ]; then write_record '' "$ACTIVE_DEST" '' || recoverable=0; fi
    [ "$recoverable" -eq 1 ] || printf 'Recovery needed; originals and journal retained under %s\n' "$STATE_DIR" >&2
    [ "$code" -ne 0 ] || code=1
  fi
  [ -z "$STATE_TMP" ] || rm -f "$STATE_TMP"
  rmdir "$LOCK" 2>/dev/null
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for ((i=0; i<${#SOURCES[@]}; i++)); do
  src=${SOURCES[$i]}; dest=${DESTINATIONS[$i]}
  find_record "$dest"
  if [ "$FOUND" -eq 1 ]; then
    [ "$FOUND_SOURCE" = "$src" ] || fail "Destination became managed by another source: $dest"
    if exists "$dest"; then
      [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ] || fail "Managed destination changed; preserving it: $dest"
    fi
  fi
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    [ "$FOUND" -eq 1 ] || write_record "$src" "$dest" ''
    printf 'Already linked: %s\n' "$dest"
    continue
  fi
  backup=''; original=0
  if [ "$FOUND" -eq 1 ]; then
    backup=$FOUND_BACKUP
    [ -z "$backup" ] || exists "$backup" || fail "Recorded backup is missing: $backup"
  elif exists "$dest"; then
    original=1; backup="$BACKUP_RUN/${REL_DESTINATIONS[$i]}"
    ! exists "$backup" || fail "Backup destination already exists: $backup"
  fi
  mkdir -p "$(dirname "$dest")"
  if [ -n "$backup" ]; then check_parent "$backup"; mkdir -p "$(dirname "$backup")"; fi
  # Write the recovery record before moving an original or installing a link.
  ACTIVE_SOURCE=$src; ACTIVE_DEST=$dest; ACTIVE_BACKUP=$backup; ACTIVE_ORIGINAL=$original
  ACTIVE=1
  write_record "$src" "$dest" "$backup"
  if [ "$original" -eq 1 ]; then mv "$dest" "$backup"; printf 'Backed up: %s\n' "$dest"; fi
  ! exists "$dest" || fail "Destination appeared during linking; preserving it: $dest"
  ln -s "$src" "$dest"
  [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ] || fail "Link was not installed at the expected path: $dest"
  ACTIVE=0
  printf 'Linked: %s -> %s\n' "$dest" "$src"
done
printf 'Link journal: %s\n' "$STATE_FILE"
