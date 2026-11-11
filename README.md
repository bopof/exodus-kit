# exodus-kit

Move a Windows machine to Linux **without a leap of faith**. You keep Windows as a working fallback until the very last step. If the switch goes wrong, rolling back means rebooting.

Most Windows-to-Linux tools are for desktops. They copy your files and suggest replacement apps. exodus-kit covers what they skip, the work it takes when your PC also **runs things**: scheduled jobs, background services, encrypted disks that must boot unattended, and a cutover you can undo.

It started from a real migration (a Windows 11 desktop that also acted as a home server, moved to Ubuntu). Everything machine-specific has been removed. What's left is the method, the pitfalls we hit, and the scripts.

## What's inside

| Path | What it is |
|---|---|
| [`docs/PLAYBOOK.md`](docs/PLAYBOOK.md) | The method in 7 phases: prepare on Windows, install, first boot, TPM unlock, port, test, cutover, plus the rollback |
| [`docs/PITFALLS.md`](docs/PITFALLS.md) | Problems we actually hit, each with its fix |
| [`windows/preflight.ps1`](windows/preflight.ps1) | Read-only checks before you install anything: Fast Startup, hibernation, BitLocker, clock, Secure Boot, disks, running tasks |
| [`windows/export-windows.ps1`](windows/export-windows.ps1) | Exports your scheduled tasks (full XML), third-party services (including NSSM wrappers), installed apps and inbound firewall rules to one JSON file. Secrets are redacted |
| [`linux/tasks-to-systemd.py`](linux/tasks-to-systemd.py) | Turns that export into systemd `.service` and `.timer` files, a report of anything it couldn't translate exactly, and cutover/rollback scripts for both sides, for exactly those units |
| [`linux/copy-from-windows.sh`](linux/copy-from-windows.sh) | Mounts the Windows partition **read-only** and copies your profile folders, skipping what can be rebuilt. Can re-sync at cutover |
| [`linux/cifs-automount.sh`](linux/cifs-automount.sh) | Mounts an SMB share on first access, never blocking boot, with the password in a root-only file; can make a service wait for it. Prints everything first, writes only with `--apply` |
| [`linux/run-monitored.sh`](linux/run-monitored.sh) | Runs a job and pushes the result to Uptime Kuma, healthchecks.io or any ping URL. The converter wraps jobs mapped with `"heartbeat": true` |
| [`linux/jellyfin-carry-userdata.py`](linux/jellyfin-carry-userdata.py) | Carries Jellyfin watch state (played, resume position, favorites) from the old server to the new one by matching file paths. Dry-run by default; backs up first |
| [`linux/tpm-unlock.sh`](linux/tpm-unlock.sh) | Unlocks LUKS from the TPM so the machine can reboot without anyone typing a passphrase. Works with dracut and with initramfs-tools |
| [`scripts/leak-check.sh`](scripts/leak-check.sh) | Scans for secrets and personal identifiers before you share an export or push a fork |

## Quick start

```powershell
# On Windows, in an admin PowerShell, from the repo folder
powershell -ExecutionPolicy Bypass -File windows\preflight.ps1
powershell -ExecutionPolicy Bypass -File windows\export-windows.ps1   # writes %USERPROFILE%\exodus-kit\exodus-inventory.json
```

The export goes to `%USERPROFILE%\exodus-kit` by default, not the Desktop, because OneDrive often syncs the Desktop. `preflight.ps1` exits with code 1 on a FAIL; without admin it says its verdict is incomplete.

Then install Linux (see the playbook) and, on Linux:

```bash
linux/copy-from-windows.sh --win-user <WindowsUser> --dry-run       # see what would be copied
linux/copy-from-windows.sh --win-user <WindowsUser>                 # copy for real (Windows stays read-only)
cp examples/exodus.config.example.json exodus.config.json           # then edit: paths, users, commands
python3 linux/tasks-to-systemd.py /path/to/exodus-inventory.json -c exodus.config.json -o out/
less out/REPORT.md                                                  # read this before installing anything
sudo linux/tpm-unlock.sh --check                                    # optional, needed for unattended reboots
```

The units generated in `out/` are **never enabled by the generator**. You install them disabled, test each one by hand, and enable them all at cutover with the generated `out/cutover-windows.ps1` and `out/cutover-linux.sh` (both have a dry-run mode; `rollback-*` undo them). The playbook explains why.

Vendor housekeeping (browser and driver updaters, OEM utilities, telemetry helpers) is **left out by default**. REPORT.md lists everything left out and the pattern that matched it. Everyone ports different things, so it's all config: `exclude_extra` leaves out more, `keep` ports something the defaults leave out, and `exclude` replaces the defaults entirely. Patterns use `*`, ignore case, match tasks on their full path (`\\Vendor\\Task`) and services as `service:<name>`.

## Tested on

| | Status |
|---|---|
| Ubuntu 26.04 LTS · NVIDIA (signed prebuilt driver) · Secure Boot on · dracut · LUKS+LVM | ✅ used for a real migration |
| Ubuntu 24.04 / 25.x · initramfs-tools + clevis path | ⚠️ written, not yet verified end-to-end |
| Fedora, Linux Mint, Debian, Arch, AMD GPUs | ❓ untested. The method applies; package names and the initramfs step differ. Reports welcome |
| `jellyfin-carry-userdata.py`, Jellyfin 10.11+ database (EF Core `jellyfin.db`) | ✅ checked against a real Windows → Linux move: identical result to the hand-made import |
| `run-monitored.sh` via systemd `LoadCredential` | ✅ run live against Uptime Kuma (push monitor) and self-hosted Healthchecks 5.0: up, down with the exit code, and a wrong URL reported without changing the job's exit code. Hosted healthchecks.io checked live too: up → down (exit status 3 shown) → up on a real check, and a wrong URL (HTTP 200 "OK (not found)") reported as a failed push |
| `cifs-automount.sh` on Ubuntu 26.04 against a Synology NAS | ✅ applied for real (automount, read-only, path with space + accent, `--for` drop-in). The user/password prompt is tested under a pseudo-terminal. A local Samba test confirmed `mount.cifs` keeps leading/trailing spaces in a credentials-file password, so the file must hold it exactly |
| `windows/*.ps1` on Windows 11, PowerShell 5.1, elevated | ✅ run on a real machine (preflight, export, Pester 43/43); Windows 10 untested, no CI |
| Task or service names with accents or other non-ASCII characters | ⚠️ untested on real Windows (none on the test machine). The generated `.ps1` files are written UTF-8 with BOM so PowerShell 5.1 should read them correctly; reports welcome |

`copy-from-windows.sh --root DIR` works from an already-mounted C: or a backup copy, without needing sudo.

## Development

```bash
python3 -m unittest discover -s tests      # converter, heartbeat, cifs-automount and Jellyfin tests
pwsh -c 'Invoke-Pester tests'              # redaction tests for export-windows.ps1 (Pester 5+; pwsh 7 or PS 5.1)
scripts/leak-check.sh                      # before every push; add your own identifiers to .leakcheck-patterns
```

## Principles

1. **Windows is never written to.** It's mounted read-only, and its disk and boot loader are left alone. It stays your rollback until you decide otherwise.
2. **Install everything disabled; enable it all at once.** Two machines running the same jobs against the same data (a trading bot, a publishing job, a database) is the worst outcome. A clean single cutover avoids it.
3. **Re-sync at cutover.** Windows stays the source of truth until the last minute. Anything written on Linux during testing is overwritten.
4. **Secrets never go in scripts.** Ask for them at install time and store them root-only (`/etc/<something>/*.cred`, mode 600). Pass them to services with `LoadCredential=`.
5. **Be honest about approximations.** The converter reports every trigger it couldn't translate exactly instead of guessing quietly.

## Related projects

- [LucasFormiga/winuxdb](https://github.com/LucasFormiga/winuxdb): which Linux app replaces which Windows app
- [dennishilk/linux-migration-companion](https://github.com/dennishilk/linux-migration-companion): a local advisor that assesses your setup
- [AlexP11223/qBTConverter](https://github.com/AlexP11223/qBTConverter): rewrites Windows paths in qBittorrent `.fastresume` files
- [KeyofBlueS/bt-keys-sync](https://github.com/KeyofBlueS/bt-keys-sync): keeps Bluetooth pairings working on a dual-boot machine

## License

MIT. See [LICENSE](LICENSE).
