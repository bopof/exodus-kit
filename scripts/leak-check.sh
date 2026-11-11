#!/usr/bin/env bash
# leak-check.sh -- look for secrets and personal identifiers before you share an export or push.
#
#   scripts/leak-check.sh [PATH]        default PATH = repository root
#
# Two layers:
#   1. generic patterns: private keys, common token formats, password assignments,
#      tailnet (100.64/10) and private LAN IPs, e-mail addresses, SSH fingerprints
#   2. YOUR patterns: one extended regex per line in .leakcheck-patterns (git-ignored)
#      or in the file named by $EXODUS_LEAK_PATTERNS -- your names, hostnames, IPs, domain...
#
# A line containing "leak-check: allow" is ignored. Runs gitleaks too when installed.
# Exit code 1 if anything is found.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:-$ROOT}
PATTERNS_FILE=${EXODUS_LEAK_PATTERNS:-$ROOT/.leakcheck-patterns}
hits=0

# In a git repo, scan exactly what would be committed (tracked + untracked-not-ignored).
FILES=()
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do FILES+=("$TARGET/$f"); done \
    < <(git -C "$TARGET" ls-files -z --cached --others --exclude-standard)
  printf '· scanning %d file(s) git would commit\n' "${#FILES[@]}"
else
  while IFS= read -r -d '' f; do FILES+=("$f"); done \
    < <(find "$TARGET" -type f ! -path '*/.git/*' ! -name '.leakcheck-patterns' -print0)
fi
[[ ${#FILES[@]} -gt 0 ]] || { echo "nothing to scan"; exit 0; }

grep_files() {   # grep flags..., pattern -> matches across FILES
  grep -nHI "$@" -- "${FILES[@]}" 2>/dev/null | grep -v 'leak-check: allow' || true
}

scan() {   # $1 label, $2 PCRE
  local out
  out=$(grep_files -P -e "$2")
  if [[ -n "$out" ]]; then
    printf '\033[31m✗ %s\033[0m\n%s\n' "$1" "$(sed 's/^/    /' <<<"$out" | head -20)"
    hits=1
  fi
}

scan "private key"          '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan "token-like string"    '\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|tskey-[A-Za-z0-9-]{20,})'
scan "password assignment"  '(?i)\b(password|passwd|pwd|secret|token|api[_-]?key)\b\s*[:=]\s*["'"'"']?(?!<|/|\$|\{|%|\*|REDACTED|xxx|changeme)[^\s"'"'"'<>]{6,}'
scan "tailnet IP"           '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b(?!/)'
scan "private LAN IP"       '\b(192\.168|10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b(?!/)'
scan "e-mail address"       '\b[A-Za-z0-9._%+-]+@(?!example\.(com|org)|anthropic\.com\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'
scan "SSH fingerprint"      'SHA256:[A-Za-z0-9+/]{43}'

if [[ -f "$PATTERNS_FILE" ]]; then
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    out=$(grep_files -iE -e "$p")
    if [[ -n "$out" ]]; then printf '\033[31m✗ personal pattern\033[0m\n%s\n' "$(sed 's/^/    /' <<<"$out" | head -20)"; hits=1; fi
  done < "$PATTERNS_FILE"
else
  printf '\033[33m!\033[0m no %s: only generic patterns checked. Add your names/hosts/IPs there.\n' "$PATTERNS_FILE"
fi

if command -v gitleaks >/dev/null; then
  if [[ -d "$TARGET/.git" ]]; then gitleaks git --no-banner --redact "$TARGET" || hits=1
  else gitleaks dir --no-banner --redact "$TARGET" || hits=1; fi
else
  printf '\033[33m!\033[0m gitleaks not installed: skipped (https://github.com/gitleaks/gitleaks)\n'
fi

if [[ $hits -eq 0 ]]; then printf '\033[32m✓ nothing found\033[0m\n'; fi
exit $hits
