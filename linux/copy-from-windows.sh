#!/usr/bin/env bash
# copy-from-windows.sh -- copy a Windows user profile to Linux, with the Windows partition mounted READ-ONLY.
#
#   copy-from-windows.sh --win-user Alice [options]
#
# Options:
#   --win-user NAME     Windows profile folder name (C:\Users\NAME). Required.
#   --only "A B ..."    Profile folders to copy (default: Desktop Documents Pictures Music Videos Downloads)
#   --dest DIR          Copy into DIR/<Folder> instead of your XDG folders (~/Desktop or ~/Bureau, ...)
#   --device /dev/X     Windows partition (default: auto-detect the NTFS partition that has Users/NAME)
#   --mount DIR         Mount point (default: /mnt/windows)
#   --root DIR          Use an already-mounted Windows tree or a backup copy of C:\ (no mounting, no sudo)
#   --dotfiles          Also copy .ssh (no overwrite, perms fixed) and .gitconfig (Windows paths reported)
#   --exclude-from F    Extra rsync exclude patterns, one per line
#   --delete            Delete files on Linux that no longer exist on Windows (cutover re-sync)
#   --dry-run           Show what would be copied, change nothing
#   --keep-mounted      Leave the partition mounted afterwards
#
# Windows is never written to: it is mounted with -o ro. Safe to rerun.
set -euo pipefail

WIN_USER="" ONLY="Desktop Documents Pictures Music Videos Downloads" DEST="" DEVICE="" MNT=/mnt/windows
ROOT_DIR="" DOTFILES=0 DELETE=0 DRY=0 KEEP=0 EXTRA_EXCL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --win-user) WIN_USER=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --dest) DEST=$2; shift 2 ;;
    --device) DEVICE=$2; shift 2 ;;
    --mount) MNT=$2; shift 2 ;;
    --root) ROOT_DIR=$2; shift 2 ;;
    --dotfiles) DOTFILES=1; shift ;;
    --exclude-from) EXTRA_EXCL=$2; shift 2 ;;
    --delete) DELETE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --keep-mounted) KEEP=1; shift ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -n "$WIN_USER" ]] || { echo "--win-user is required (see --help)" >&2; exit 2; }
[[ $EUID -ne 0 ]] || { echo "run as your normal user; the script uses sudo only to mount" >&2; exit 2; }

log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

EXCLUDES=(
  --exclude='node_modules/' --exclude='.venv*/' --exclude='venv/' --exclude='__pycache__/' --exclude='*.pyc'
  --exclude='.tox/' --exclude='.mypy_cache/' --exclude='.pytest_cache/' --exclude='.gradle/' --exclude='target/'
  --exclude='desktop.ini' --exclude='Thumbs.db' --exclude='*.lnk' --exclude='~$*' --exclude='$RECYCLE.BIN/'
  --exclude='.cache/' --exclude='*.tmp'
)
[[ -n "$EXTRA_EXCL" ]] && EXCLUDES+=(--exclude-from="$EXTRA_EXCL")

WE_MOUNTED=0
cleanup() { if [[ $WE_MOUNTED -eq 1 && $KEEP -eq 0 ]]; then sudo umount "$MNT" && log "unmounted $MNT"; fi; }
trap cleanup EXIT

try_mount() {   # $1 = device
  sudo mount -t ntfs3 -o "ro,uid=$(id -u),gid=$(id -g)" "$1" "$MNT" 2>/dev/null \
    || sudo mount -t ntfs-3g -o "ro,uid=$(id -u),gid=$(id -g)" "$1" "$MNT" 2>/dev/null
}

mount_windows() {
  if mountpoint -q "$MNT"; then
    [[ -d "$MNT/Users/$WIN_USER" ]] || die "$MNT is mounted but has no Users/$WIN_USER"
    findmnt -no OPTIONS "$MNT" | grep -qw ro || warn "$MNT is mounted READ-WRITE by something else; remount it ro to be safe"
    return
  fi
  sudo mkdir -p "$MNT"
  local devs=() d
  if [[ -n "$DEVICE" ]]; then devs=("$DEVICE")
  else while read -r d fs; do [[ "$fs" == ntfs ]] && devs+=("$d"); done < <(lsblk -rpno NAME,FSTYPE); fi
  [[ ${#devs[@]} -gt 0 ]] || die "no NTFS partition found (BitLocker? see docs/PITFALLS.md)"
  for d in "${devs[@]}"; do
    if try_mount "$d"; then
      if [[ -d "$MNT/Users/$WIN_USER" ]]; then WE_MOUNTED=1; log "mounted $d read-only on $MNT"; return; fi
      sudo umount "$MNT"
    fi
  done
  die "could not mount a Windows partition with Users/$WIN_USER.
       If Windows was hibernated or Fast Startup is on: boot Windows, then run  shutdown /s /t 0"
}

xdg_dest() {    # Windows folder name -> Linux destination
  local f=$1 key=""
  if [[ -n "$DEST" ]]; then echo "$DEST/$f"; return; fi
  case "$f" in
    Desktop) key=DESKTOP ;; Documents) key=DOCUMENTS ;; Pictures) key=PICTURES ;;
    Music) key=MUSIC ;; Videos) key=VIDEOS ;; Downloads) key=DOWNLOAD ;;
  esac
  if [[ -n "$key" ]] && command -v xdg-user-dir >/dev/null; then
    local x; x=$(xdg-user-dir "$key")
    [[ "$x" != "$HOME" ]] && { echo "$x"; return; }
  fi
  echo "$HOME/$f"
}

if [[ -n "$ROOT_DIR" ]]; then
  [[ -d "$ROOT_DIR/Users/$WIN_USER" ]] || die "$ROOT_DIR has no Users/$WIN_USER"
  MNT=$ROOT_DIR
else
  mount_windows
fi
SRC="$MNT/Users/$WIN_USER"
RS=(rsync -rt --modify-window=2 --human-readable --info=stats1 --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r)
[[ $DRY -eq 1 ]] && RS+=(--dry-run --itemize-changes)
[[ $DELETE -eq 1 ]] && RS+=(--delete)

for f in $ONLY; do
  if [[ ! -d "$SRC/$f" ]]; then warn "skip $f: not found in $SRC"; continue; fi
  # OneDrive "known folder" redirection: the real files live under OneDrive\<Folder>
  if [[ -d "$SRC/OneDrive/$f" ]] && [[ -z "$(ls -A "$SRC/$f" 2>/dev/null)" ]]; then
    warn "$f is empty but OneDrive/$f exists: Windows redirected it. Files marked 'online-only' are NOT on disk."
  fi
  dst=$(xdg_dest "$f")
  log "$f -> $dst$([[ $DRY -eq 1 ]] && echo '  (dry run)')"
  [[ $DRY -eq 1 ]] || mkdir -p "$dst"
  "${RS[@]}" "${EXCLUDES[@]}" "$SRC/$f/" "$dst/"
done

if [[ $DOTFILES -eq 1 ]]; then
  if [[ -d "$SRC/.ssh" ]]; then
    log ".ssh -> ~/.ssh (existing files are kept)"
    if [[ $DRY -eq 0 ]]; then
      install -d -m 700 "$HOME/.ssh"
      rsync -rt --ignore-existing --exclude='known_hosts*' "$SRC/.ssh/" "$HOME/.ssh/"
      find "$HOME/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} +
      find "$HOME/.ssh" -type f -name '*.pub' -exec chmod 644 {} +
      grep -lis 'IdentityFile.*[A-Za-z]:\\' "$HOME/.ssh/config" 2>/dev/null \
        && warn "~/.ssh/config has Windows paths in IdentityFile: edit them"
    fi
  fi
  if [[ -f "$SRC/.gitconfig" ]]; then
    if [[ -f "$HOME/.gitconfig" ]]; then warn "~/.gitconfig exists, not overwritten (Windows copy: $SRC/.gitconfig)"
    elif [[ $DRY -eq 0 ]]; then cp "$SRC/.gitconfig" "$HOME/.gitconfig" && log ".gitconfig copied"; fi
    if grep -niE '\.exe|(^|[^a-z])[a-z]:[\\/]' "$SRC/.gitconfig" >/dev/null; then
      warn ".gitconfig has Windows paths. Lines:"
      grep -niE '\.exe|(^|[^a-z])[a-z]:[\\/]' "$SRC/.gitconfig" | sed 's/^/      /' >&2
      warn "fix: 'gh auth setup-git' for GitHub credential helpers, 'git config --global --edit' for the rest,"
      warn "     and 'git config --global core.autocrlf input'"
    fi
  fi
fi

log "done. The Windows side was only read, never modified."
[[ $DRY -eq 1 ]] && log "this was a dry run: rerun without --dry-run to copy"
exit 0
