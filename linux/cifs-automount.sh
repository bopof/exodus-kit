#!/usr/bin/env bash
# cifs-automount.sh -- mount an SMB share (NAS, another PC) the way a server needs it:
# on first access, never blocking boot, with the password in a root-only file.
# This replaces Windows "net use" at logon and the wait-for-the-NAS-then-start-the-app scripts.
#
#   cifs-automount.sh --server nas.lan --share Media --mount /mnt/nas/media [options]
#
#   --server HOST        NAS host name or IP
#   --share NAME         share name (spaces and accents are fine)
#   --mount DIR          local mount point (absolute)
#   --cred FILE          credentials file (default /etc/exodus-kit/cifs/<server>.cred). Created on --apply
#                        if missing: you're asked for the user name and password, it's written mode 600
#   --owner USER         local user that owns the files (default: the user who ran sudo). Files 0644,
#                        dirs 0755. With --group-write, 0664/0775, for a service user whose group you're in
#   --group-write        see --owner
#   --after UNIT         mount only after this unit (repeatable), e.g. tailscaled.service for a NAS on a VPN
#   --for UNIT           this service needs the share: writes a drop-in giving it Wants= + After= on the mount
#                        (repeatable). Wants, not Requires: the service still starts if the NAS is down
#   --idle-timeout SEC   unmount after SEC idle seconds (default 0 = stay mounted; media servers watching
#                        the folder need that)
#   --opts LIST          extra mount options, comma-separated (e.g. vers=3.1.1,ro)
#   --apply              write it (needs root). Without it: print what would be written, change nothing
#
# Testing without root: --fstab FILE and --dropin-dir DIR redirect the writes, and --no-reload skips
# systemctl. The credentials file must exist already in that case (no prompt without a terminal).
set -euo pipefail

server="" share="" mnt="" cred="" owner="${SUDO_USER:-$(id -un)}" gwrite=0 idle=0 extra="" apply=0
after=() needed_by=()
fstab=/etc/fstab dropin_dir=/etc/systemd/system reload=1

die() { echo "cifs-automount: $*" >&2; exit 1; }
while (( $# )); do
  case "$1" in
    --server) server="$2"; shift ;;
    --share) share="$2"; shift ;;
    --mount) mnt="${2%/}"; shift ;;
    --cred) cred="$2"; shift ;;
    --owner) owner="$2"; shift ;;
    --group-write) gwrite=1 ;;
    --after) after+=("$2"); shift ;;
    --for) needed_by+=("$2"); shift ;;
    --idle-timeout) idle="$2"; shift ;;
    --opts) extra="$2"; shift ;;
    --apply) apply=1 ;;
    --fstab) fstab="$2"; shift ;;
    --dropin-dir) dropin_dir="$2"; shift ;;
    --no-reload) reload=0 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ -n $server && -n $share && -n $mnt ]] || die "--server, --share and --mount are required (see --help)"
[[ $mnt == /* ]] || die "--mount must be an absolute path"
[[ $idle =~ ^[0-9]+$ ]] || die "--idle-timeout takes seconds"
[[ $server =~ ^[A-Za-z0-9._:-]+$ ]] || die "--server: host name or IP only"
for x in "$share" "$mnt" "$cred"; do [[ $x != *[,\"\'\\]* ]] || die "commas, quotes and backslashes aren't supported in '$x'"; done
cred="${cred:-/etc/exodus-kit/cifs/${server}.cred}"
uid=$(id -u "$owner" 2>/dev/null) || die "no local user '$owner'"
gid=$(id -g "$owner")

# fstab fields are space-separated: spaces in the share or mount point are written as \040.
fs_escape() { local s="${1//\\/\\134}"; s="${s// /\\040}"; printf '%s' "${s//$'\t'/\\011}"; }
perm="file_mode=0644,dir_mode=0755"; (( gwrite )) && perm="file_mode=0664,dir_mode=0775"
opts="credentials=$cred,uid=$uid,gid=$gid,$perm,iocharset=utf8,_netdev,nofail,x-systemd.automount"
opts+=",x-systemd.idle-timeout=$idle,x-systemd.mount-timeout=60"
for u in "${after[@]}"; do opts+=",x-systemd.after=$u"; done
[[ -n $extra ]] && opts+=",$extra"
line="$(fs_escape "//$server/$share") $(fs_escape "$mnt") cifs $opts 0 0"

if command -v systemd-escape >/dev/null; then mount_unit=$(systemd-escape --path --suffix=mount "$mnt")
else mount_unit="$(printf '%s' "${mnt#/}" | sed 's/-/\\x2d/g; s|/|-|g').mount"; fi
dropin_name="exodus-cifs-$(printf %s "${mnt#/}" | tr -c "A-Za-z0-9" "-").conf"
dropin_body="# Written by exodus-kit cifs-automount.sh: start after $mnt is mounted (if it can be)
[Unit]
Wants=$mount_unit
After=$mount_unit remote-fs.target"

# Is this mount point already in fstab? Compare the 2nd field, unescaped.
existing=""
if [[ -r $fstab ]]; then
  existing=$(M="$(fs_escape "$mnt")" awk '$1 !~ /^#/ && $2 == ENVIRON["M"]' "$fstab")
fi

if (( ! apply )); then
  echo "fstab line ($fstab):"; echo "  $line"
  if [[ -n $existing && $existing != "$line" ]]; then echo "  (an entry for $mnt already exists and differs: left alone)"
  elif [[ -n $existing ]]; then echo "  (already there)"; fi
  echo "credentials file: $cred $( [[ -e $cred ]] && echo '(exists)' || echo '(would be created, mode 600, you would be asked for user + password)')"
  echo "mount unit: $mount_unit"
  for u in "${needed_by[@]}"; do echo "drop-in: $dropin_dir/$u.d/$dropin_name"; done
  (( ${#needed_by[@]} )) && { echo "---"; echo "$dropin_body"; }
  echo "Dry run: nothing changed. Add --apply to write it."
  exit 0
fi

if [[ $fstab == /etc/fstab || $dropin_dir == /etc/systemd/system ]]; then
  (( EUID == 0 )) || die "--apply writes /etc: run it with sudo"
fi

if [[ ! -e $cred ]]; then
  [[ -t 0 ]] || die "$cred does not exist and there's no terminal to ask for the password"
  # IFS= keeps leading/trailing spaces: a password is taken exactly as typed.
  IFS= read -rp "SMB user for //$server/$share: " smb_user || die "no user name given"
  [[ -n $smb_user ]] || die "no user name given"
  IFS= read -rsp "Password (not shown): " smb_pass || { echo; die "no password given"; }; echo
  # Create the folder 700 only if it's new: never chmod an existing one (e.g. --cred /etc/samba/x.cred).
  [[ -d $(dirname "$cred") ]] || install -d -m 700 "$(dirname "$cred")"
  ( umask 077; printf 'username=%s\npassword=%s\n' "$smb_user" "$smb_pass" > "$cred" )
  unset smb_pass
  echo "wrote $cred (mode 600)"
fi
[[ $(stat -c %a "$cred") == 600 || $(stat -c %a "$cred") == 400 ]] || echo "warning: $cred is not mode 600" >&2

if [[ -n $existing && $existing != "$line" ]]; then
  echo "warning: $fstab already has an entry for $mnt that differs, left alone:" >&2
  echo "  $existing" >&2
  echo "  wanted: $line" >&2
elif [[ -z $existing ]]; then
  [[ -e $fstab ]] && cp -p "$fstab" "$fstab.bak-$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$line" >> "$fstab"
  echo "added to $fstab"
fi
mkdir -p "$mnt"

for u in "${needed_by[@]}"; do
  d="$dropin_dir/$u.d"; mkdir -p "$d"
  printf '%s\n' "$dropin_body" > "$d/$dropin_name"
  echo "wrote $d/$dropin_name"
done

if (( reload )); then
  systemctl daemon-reload
  systemctl restart remote-fs.target || true
  if timeout 70 ls "$mnt" >/dev/null 2>&1; then echo "$mnt: reachable"
  else echo "warning: $mnt not reachable yet (network/VPN up? password right? journalctl -u '$mount_unit')" >&2; fi
fi
