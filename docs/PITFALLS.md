# Pitfalls

Each entry here happened during a real migration. They're grouped by area.

## Boot, disks, encryption

**Linux won't mount C:, or mounts it in a dirty state.**
Windows Fast Startup or hibernation left the NTFS volume "in use". Turn Fast Startup off and do a full shutdown with `shutdown /s /t 0`. Rebooting from Windows also works, because a restart doesn't hibernate.

**The clock is 1–2 hours off after switching OS.**
Windows stores the hardware clock in local time. Set `RealTimeIsUniversal=1` on Windows (see PLAYBOOK, Phase 0) rather than switching Linux to local time.

**The desktop file manager mounts C: read-write when you click it.**
GNOME (udisks) mounts NTFS read-write by default. Add an fstab entry that forces read-only and hides the drive:
`UUID=<NTFS-UUID> /mnt/windows ntfs3 ro,nofail,noauto,x-gvfs-hide 0 0`

**The installer's "hardware-backed / TPM" encryption breaks NVIDIA.**
On Ubuntu, TPM-backed full-disk encryption uses signed kernel snaps. With the NVIDIA userspace driver, the module loads but `nvidia-smi` sees no GPU. Use classic LUKS with a passphrase, then add TPM unlock yourself (`linux/tpm-unlock.sh`).

**TPM unlock is enrolled, but every boot still asks for the passphrase (dracut).**
dracut quietly leaves out its TPM module when the `tpm2` tools aren't installed. Install `tpm2-tools` *before* rebuilding the initramfs, then check with `lsinitrd | grep -i tpm2`.

**`tpm2-device=auto` in crypttab does nothing (initramfs-tools).**
Debian/Ubuntu's initramfs-tools ignores that option. Use clevis instead (`clevis luks bind … tpm2`). `tpm-unlock.sh` picks the right path automatically.

**The passphrase prompt comes back months later.**
PCR 7 changed: a firmware update, Microsoft's new Secure Boot certificates installed through Windows Update, a dbx update or a shim update. This is expected. Type the passphrase, then `tpm-unlock.sh --reseal`.

**An unattended reboot lands in the wrong OS.**
With two systems and one firmware boot order, a scheduled reboot on one side can come up in the other. To reboot into Linux once without changing the default, use `efibootmgr --bootnext <num>`.

**SSH clients shout "REMOTE HOST IDENTIFICATION HAS CHANGED".**
The new Linux install generated new host keys under the same IP/name. This is expected. Check the fingerprint on the console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`), then `ssh-keygen -R <host>` on each client.

## Copying files

**`.lnk` and `desktop.ini` files clutter Linux.**
Exclude them. And if your Linux side mirrors back to a shared folder, the first run with `--delete` removes the shortcuts there too.

**Virtualenvs and `node_modules` copied from Windows don't work.**
They contain Windows binaries and absolute paths. Exclude them and rebuild from lockfiles.

**Symlinks can't be stored on an SMB share.**
Linux virtualenvs (full of symlinks) fail when backed up to CIFS. Exclude them from backups. They're rebuildable anyway.

**The cutover re-sync wipes fixes you made on Linux.**
If the Linux port of a script lives inside a folder that you re-sync from Windows, cutover brings back the Windows copy. Keep Linux fixes on a git branch and check it out again after the re-sync, or keep them outside the re-synced tree.

## Dev tools

**`git` asks for credentials, or fails with a `.exe` path.**
A `.gitconfig` copied from Windows can hold `credential.<url>.helper = C:/Program Files/GitHub CLI/gh.exe`. Resetting the generic `credential.helper` isn't enough. Run `gh auth setup-git`, or delete the URL-scoped helper lines.

**Every file shows as modified in `git status`.**
Line endings. Set `git config --global core.autocrlf input`. Only renormalize a repo if you mean to.

**Playwright (or another tool shipping prebuilt binaries) says your OS isn't supported.**
New distribution releases often come out before vendor builds exist. For Playwright, `PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64` (the previous LTS) works.

**A "health check" passed on Windows but fails on Linux.**
Check what it actually tests. One check used to pick the first model in a list. On Linux that turned out to be an embedding-only model, which returned HTTP 400 to a generate call. Make health checks call the exact thing the job uses.

## Services and jobs

**A service fails at boot but works when started by hand.**
It binds a specific IP that doesn't exist yet: a VPN or tailnet address, or one that only moves over at cutover. Order it `After=` the interface's service, or bind `0.0.0.0` and limit access with the firewall.

**Jobs ran twice, once on each OS.**
Both sides were enabled at once. Install disabled, enable only at cutover, and disable Windows first.

**A database was copied mid-write at cutover.**
A Windows task missed during downtime started as soon as Windows booted, and was still running when you shut down. Check `Get-ScheduledTask | Where State -eq Running` before the final shutdown.

**Windows "run whether user is logged on or not" with no equivalent.**
That's a system service in systemd terms (`User=` in a system unit). "Run at logon" becomes a `systemd --user` unit or an XDG autostart entry instead. The converter flags these.

**Plaintext passwords in old Windows scripts.**
Launchers that map network drives (`net use … /user:x password`) or start apps often have credentials baked in. The export redacts what it can recognize, but read through your `.ps1`/`.bat` files too. Rotate those passwords after the migration and keep the new ones in root-only credential files.

## Apps

**A Flatpak browser plays nothing from a media server ("HLS stream error").**
Some Flatpak browser builds ship without H.264. Use a browser from the distribution or a Snap for media web UIs, or install the codec extension.

**The media server's database doesn't move between OSes.**
Media servers store absolute Windows paths (`\\server\share\…`, `D:\Movies`). Do a fresh install with new libraries. If you want the watch history, merge it afterwards by rewriting paths in a copy of the database while the server is stopped. Library IDs often match when the library names and paths line up.

**The media server tries to write to your NAS.**
On Linux it often runs as its own user. Turn off "save artwork/NFO into media folders" if the share is meant to be read-only for it.

**Torrent client leaks outside the VPN.**
Bind it to the VPN interface in its own config, not only in a launcher, so it stays bound however it's started. Local Peer Discovery and UPnP open sockets outside the binding; turn them off.
