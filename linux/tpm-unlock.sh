#!/usr/bin/env bash
# tpm-unlock.sh -- unlock a LUKS root volume from the TPM (sealed to PCR 7 = Secure Boot state),
# so the machine reboots without anyone typing a passphrase.
#
#   sudo tpm-unlock.sh --check                 read-only report (default)
#   sudo tpm-unlock.sh --enroll [--device D]   add recovery key + TPM unlock, rebuild initramfs
#   sudo tpm-unlock.sh --reseal [--device D]   after the passphrase prompt came back (PCR 7 changed)
#   options: --pcrs 7   --no-recovery-key   --yes (don't ask for confirmation)
#
# Picks the method from the initramfs generator:
#   dracut           -> systemd-cryptenroll + crypttab tpm2-device=auto (needs tpm2-tools in the image)
#   initramfs-tools  -> clevis (its crypttab ignores tpm2-device)
#   mkinitcpio       -> not automated: prints the manual steps
#
# Your passphrase keeps working. The TPM key slot is an addition, never a replacement.
# Protects a stolen DISK, not a stolen PC (which boots to the login screen).
set -euo pipefail

MODE=check DEV="" PCRS=7 RECOVERY=1 YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --enroll) MODE=enroll; shift ;;
    --reseal) MODE=reseal; shift ;;
    --device) DEV=$2; shift 2 ;;
    --pcrs) PCRS=$2; shift 2 ;;
    --no-recovery-key) RECOVERY=0; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
confirm() { [[ $YES -eq 1 ]] && return; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[yY] ]] || die "aborted"; }

[[ $EUID -eq 0 ]] || die "run with sudo"

# ---------------------------------------------------------------- detection
has_tpm() { [[ -e /dev/tpmrm0 || -e /sys/class/tpm/tpm0 ]]; }
secure_boot() {
  if command -v mokutil >/dev/null; then mokutil --sb-state 2>/dev/null | grep -qi 'enabled'
  else od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{exit !($NF==1)}'; fi
}
initramfs_gen() {
  if command -v dpkg-query >/dev/null && dpkg-query -W -f='${Status}' initramfs-tools 2>/dev/null | grep -q 'ok installed'; then
    echo initramfs-tools
  elif command -v dracut >/dev/null; then echo dracut
  elif command -v mkinitcpio >/dev/null; then echo mkinitcpio
  else echo unknown; fi
}
pick_device() {
  [[ -n "$DEV" ]] && { cryptsetup isLuks "$DEV" || die "$DEV is not a LUKS device"; return; }
  # The LUKS device that holds / : walk up from the root filesystem.
  local src; src=$(findmnt -no SOURCE /)
  DEV=$(lsblk -spno NAME,FSTYPE "$src" 2>/dev/null | awk '$2=="crypto_LUKS"{print $1; exit}')
  [[ -n "$DEV" ]] || die "could not find the LUKS device under / (pass --device /dev/...)"
}
has_tpm_slot() {
  case "$1" in
    clevis) clevis luks list -d "$DEV" 2>/dev/null | grep -q tpm2 ;;
    *) cryptsetup luksDump "$DEV" | grep -q 'systemd-tpm2' ;;
  esac
}
pkg_install() {
  if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null; then dnf install -y "$@"
  elif command -v pacman >/dev/null; then pacman -S --needed --noconfirm "$@"
  elif command -v zypper >/dev/null; then zypper --non-interactive install "$@"
  else die "install these packages yourself: $*"; fi
}

GEN=$(initramfs_gen)
pick_device
METHOD=$([[ $GEN == initramfs-tools ]] && echo clevis || echo systemd)

# ---------------------------------------------------------------- check
check() {
  log "TPM unlock check"
  has_tpm && ok "TPM 2.0 present" || bad "no TPM device (/dev/tpmrm0). Enable fTPM/PTT in the firmware"
  secure_boot && ok "Secure Boot on" || bad "Secure Boot off: PCR 7 then protects almost nothing. Turn it on first"
  ok "LUKS device: $DEV ($(cryptsetup luksDump "$DEV" | awk '/^Version/{print "LUKS"$2}'))"
  info "initramfs generator: $GEN  -> method: $METHOD"
  if has_tpm_slot "$METHOD"; then ok "TPM key slot already enrolled"; else info "no TPM key slot yet"; fi
  if cryptsetup luksDump "$DEV" | grep -q 'systemd-recovery'; then ok "recovery key slot present"
  else info "no recovery key slot (enroll adds one unless --no-recovery-key)"; fi
  if [[ $GEN == dracut ]]; then
    command -v tpm2 >/dev/null && ok "tpm2-tools installed" \
      || bad "tpm2-tools missing: dracut will silently build an image without TPM support"
    grep -E "^[^#]" /etc/crypttab 2>/dev/null | grep -q 'tpm2-device' && ok "crypttab has tpm2-device" \
      || info "crypttab has no tpm2-device option yet"
  fi
  [[ $GEN == mkinitcpio ]] && info "mkinitcpio: use the sd-encrypt hook + rd.luks.options=tpm2-device=auto (manual)"
  [[ $GEN == unknown ]] && bad "no known initramfs generator found"
  return 0
}

# ---------------------------------------------------------------- enroll
crypttab_add_tpm() {
  local uuid; uuid=$(cryptsetup luksUUID "$DEV")
  [[ -f /etc/crypttab ]] || die "/etc/crypttab not found"
  cp -a /etc/crypttab "/etc/crypttab.bak-$(date +%Y%m%d-%H%M%S)"
  awk -v u="$uuid" -v d="$DEV" 'BEGIN{OFS="\t"; hit=0}
    /^[[:space:]]*#/ || NF<2 {print; next}
    ($2=="UUID="u || $2==d || $2=="/dev/disk/by-uuid/"u) {
      hit=1
      if (NF<3) $3="none"
      if (NF<4 || $4=="") $4="luks"
      if ($4 !~ /tpm2-device=/) $4=$4",tpm2-device=auto"
    }
    {print}
    END{ if(!hit) exit 3 }' /etc/crypttab > /etc/crypttab.new \
    || { rm -f /etc/crypttab.new; die "no crypttab line for UUID=$uuid. Add tpm2-device=auto to it by hand"; }
  mv /etc/crypttab.new /etc/crypttab
  ok "crypttab: $(grep -F "$uuid" /etc/crypttab)"
}

enroll() {
  check
  [[ $GEN == mkinitcpio || $GEN == unknown ]] && die "automatic enrollment not supported for $GEN"
  has_tpm || die "no TPM"
  secure_boot || confirm "Secure Boot is OFF. Sealing to PCR $PCRS then protects very little. Continue anyway?"
  if has_tpm_slot "$METHOD"; then log "a TPM slot already exists, use --reseal to replace it"; exit 0; fi
  confirm "Enroll TPM unlock (PCR $PCRS) on $DEV using $METHOD? Your passphrase will be asked."

  if [[ $RECOVERY -eq 1 ]] && ! cryptsetup luksDump "$DEV" | grep -q 'systemd-recovery'; then
    log "recovery key: STORE IT in your password manager before continuing"
    systemd-cryptenroll --recovery-key "$DEV"
    confirm "Recovery key stored somewhere safe?"
  fi

  if [[ $METHOD == systemd ]]; then
    command -v tpm2 >/dev/null || { log "installing tpm2-tools"; pkg_install tpm2-tools; }
    systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs="$PCRS" "$DEV"
    crypttab_add_tpm
    log "rebuilding initramfs (dracut)"
    dracut -f --regenerate-all
    if command -v lsinitrd >/dev/null; then
      lsinitrd 2>/dev/null | grep -qiE 'tpm2|libtss2' && ok "initramfs contains TPM support" \
        || bad "initramfs has NO TPM support: check that tpm2-tools is installed, then rerun dracut -f --regenerate-all"
    fi
  else
    log "installing clevis"
    pkg_install clevis clevis-tpm2 clevis-luks clevis-initramfs
    clevis luks bind -d "$DEV" tpm2 "{\"pcr_ids\":\"$PCRS\"}"
    update-initramfs -u -k all
  fi
  has_tpm_slot "$METHOD" && ok "TPM slot enrolled" || die "enrollment did not produce a TPM slot"
  log "now reboot TWICE: no passphrase prompt expected. Recheck after the next kernel and GPU driver update."
}

# ---------------------------------------------------------------- reseal
reseal() {
  check
  confirm "Re-seal the TPM slot on $DEV to the CURRENT PCR $PCRS values?"
  if [[ $METHOD == systemd ]]; then
    systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="$PCRS" "$DEV"
  else
    local slot; slot=$(clevis luks list -d "$DEV" | awk -F: '/tpm2/{print $1; exit}')
    [[ -n "$slot" ]] || die "no clevis tpm2 binding found"
    clevis luks regen -q -d "$DEV" -s "$slot"
  fi
  ok "re-sealed. Reboot to confirm there is no prompt."
}

case "$MODE" in check) check ;; enroll) enroll ;; reseal) reseal ;; esac
