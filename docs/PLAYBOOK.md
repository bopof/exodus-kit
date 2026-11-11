# Playbook

The whole migration in 7 phases. Windows keeps doing its job until Phase 6. Every step before that can be abandoned by simply booting Windows.

> **Assumed setup.** A UEFI PC with two disks: Windows on one, Linux going on the other (an empty one, or one you're happy to erase). A single disk shared between both systems works too, but the "Windows is untouched" guarantee gets weaker: you'll be resizing partitions and sharing one EFI partition. Wherever this guide says `<WINDOWS_DISK>` / `<LINUX_DISK>`, check your own device names with `lsblk` and never copy them from here.

---

## Phase 0: Prepare on Windows

Run `windows/preflight.ps1` from an admin PowerShell. It changes nothing and reports:

| Check | Why it matters | Fix |
|---|---|---|
| Fast Startup off | With Fast Startup on, Windows "shuts down" by hibernating the kernel. Linux then refuses to mount C:, or worse, mounts a filesystem that's in an inconsistent state | `powercfg /h off`, or Control Panel → Power → "Turn on fast startup" off |
| Clock stored in UTC | Linux keeps the hardware clock in UTC and Windows in local time, so the clock jumps every time you switch | `reg add HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation /v RealTimeIsUniversal /t REG_DWORD /d 1 /f` |
| BitLocker status | Linux can only read a BitLocker volume if you have the recovery key (via `dislocker` or `cryptsetup` with BitLocker support) | Back up the recovery key, or decrypt C: before you start |
| Secure Boot / UEFI | Decides how the NVIDIA driver gets signed and whether TPM unlock is possible | Keep Secure Boot **on** |
| Running scheduled tasks | Shows what's currently doing work on this machine. Those are the jobs you'll be porting | — |

Then:

1. **Export the inventory:** `windows/export-windows.ps1` (from an admin PowerShell; it writes to `%USERPROFILE%\exodus-kit\` unless you pass `-OutFile`). It writes the scheduled tasks (full XML), third-party services, installed apps and inbound firewall rules. Arguments that look like secrets are redacted. **Read the file anyway** (see PITFALLS: plaintext passwords in old scripts).
2. **Download the ISO and check its hash** against the distribution's `SHA256SUMS` (`Get-FileHash -Algorithm SHA256`). Write it to a USB stick with Rufus (GPT/UEFI) or balenaEtcher.
3. **Prepare the target disk.** If the Linux disk has old partitions, clear it from Windows. Select it by **model name**, never by number:
   ```powershell
   Get-Disk | Format-Table Number, FriendlyName, Size, PartitionStyle
   Get-Disk | Where-Object FriendlyName -eq '<TARGET MODEL>' | Clear-Disk -RemoveData -RemoveOEM -Confirm:$true
   ```
4. **Do a full shutdown:** `shutdown /s /t 0`.

## Phase 1: Install

- Boot the USB stick from the firmware boot menu (often F8, F11, F12 or Esc). Pick the entry labelled **UEFI:**.
- Choose **third-party drivers** and **media codecs**. With Secure Boot on, the installer asks for a **MOK password**. Pick something simple and keep it for the first reboot.
- Disk: **erase the target disk only**, with *LVM + encryption (passphrase)*.
  - Do **not** pick the installer's "hardware-backed / TPM" encryption if you use an NVIDIA GPU (see PITFALLS). Plain LUKS now and TPM unlock in Phase 3 gives you the same result without that problem.
  - Install the boot loader on the **target disk**. Each disk then has its own EFI partition, and Windows' boot files are never touched.
- Store the LUKS passphrase in your password manager. It's your fallback whenever TPM unlock fails.

## Phase 2: First boot checks

1. On the blue **MOK management** screen: *Enroll MOK* → *Continue* → type the MOK password. If you skip this, the NVIDIA driver won't load under Secure Boot.
2. Check:
   ```bash
   nvidia-smi                                   # if you have NVIDIA: the GPU is listed
   lsblk -o NAME,MODEL,SIZE,FSTYPE,MOUNTPOINTS  # / and /boot/efi are on the Linux disk
   findmnt /boot/efi                            # its source is a partition of the Linux disk
   sudo efibootmgr -v                           # a Linux boot entry pointing at that EFI partition
   ```
3. **Check Windows is untouched:** boot it from the firmware menu, and check that its EFI partition has no Linux folder in it.
4. **Boot order:** decide what boots by default. During testing it's usually Windows (it's still your live machine), with Linux picked from the firmware menu.
5. Fully update the system, then reboot.

## Phase 3: TPM unlock (needed for unattended reboots)

If the machine has to come back by itself after a power cut or an update reboot, no one will be there to type the passphrase. `linux/tpm-unlock.sh` binds the LUKS volume to the TPM, sealed to **PCR 7** (the Secure Boot state):

```bash
sudo linux/tpm-unlock.sh --check            # read-only: shows TPM, Secure Boot, LUKS device, initramfs generator
sudo linux/tpm-unlock.sh --enroll           # adds a recovery key + TPM key slot, edits crypttab, rebuilds the initramfs
```

- **What it protects against:** someone stealing the **disk**. It does **not** protect against someone stealing the whole PC, which will boot to the login screen.
- **When the passphrase prompt comes back:** that's expected after a firmware update, a Secure Boot key or dbx update, or some shim updates. Type the passphrase, then run `sudo linux/tpm-unlock.sh --reseal`.
- **Test it:** reboot twice with no prompt. Check again after the next kernel update and the next GPU driver update.

## Phase 4: Port

### Data
```bash
linux/copy-from-windows.sh --win-user <WindowsUser> --dry-run
linux/copy-from-windows.sh --win-user <WindowsUser>
```
This mounts C: **read-only**. It copies the profile folders and leaves out what can be rebuilt (`node_modules`, virtualenvs, caches, `.lnk`, `desktop.ini`). It's safe to rerun.

- **Python virtualenvs:** rebuild them from lockfiles (`uv sync` / `pip install -r`). Never copy them, because Windows-only wheels won't install on Linux.
- **Git repos:** check `~/.gitconfig` for Windows paths (see PITFALLS) and set `core.autocrlf input`.

### Apps
Go through the `apps` section of the inventory and pick a Linux equivalent for each app (see [winuxdb](https://github.com/LucasFormiga/winuxdb)). Keep a column for **"stays on Windows"**. Some apps will never move (CAD tools, some vendor utilities, some games with anti-cheat), and that's the reason to keep dual-boot.

### Jobs and services
```bash
cp examples/exodus.config.example.json exodus.config.json   # edit it
python3 linux/tasks-to-systemd.py exodus-inventory.json -c exodus.config.json -o out/
```
- `exec_map` tells the converter which Linux command replaces each Windows action (`.bat`/`.ps1` launchers can't run as-is). Anything you don't map becomes a unit that **fails loudly** with "not ported yet". It never runs the wrong thing quietly.
- Read `out/REPORT.md`. Every trigger that was approximated or skipped is listed there (logon triggers, event triggers, repeating every N days…).
- Install the units **disabled**:
  ```bash
  sudo cp out/*.service out/*.timer /etc/systemd/system/ && sudo systemctl daemon-reload
  sudo systemctl start <prefix>-job-<name>.service      # run one job by hand
  journalctl -u <prefix>-job-<name> -e
  ```

### Network shares
For SMB shares, use **systemd automounts** that wait for the network (or your VPN) and never block boot, with credentials in a root-only file:
```
//nas/share  /mnt/nas/share  cifs  credentials=/etc/<name>/nas.cred,uid=<user>,gid=<group>,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600  0 0
```
If a service needs the share, give it `After=` and `RequiresMountsFor=` on that path.

### Firewall
Default to `ufw default deny incoming`. Open each app port **only on the interface you trust** (for example your VPN or tailnet interface), so you're not relying on the app's own bind address.

## Phase 5: Test (Windows is still live)

- Use it as your desktop: browser, editor, notes, password manager, games.
- Start each **read-only** service by hand, check it, stop it. **Don't** start anything that writes shared state (trading, publishing, syncing to a remote) before cutover.
- Run each job once with `systemctl start`, then read its journal.
- Reboot unattended: no passphrase, and the services come back.
- Plan for the phase to be cut short. A short "must-pass" list is fine as long as the rollback path exists.

## Phase 6: Cutover

`tasks-to-systemd.py` writes four scripts into `out/` for the units it generated: `cutover-windows.ps1` (step 1), `cutover-linux.sh` (step 4), `rollback-linux.sh` and `rollback-windows.ps1`. Run each one with `-DryRun` / `--dry-run` first. `cutover-linux.sh` refuses to run while a unit is missing from systemd or still "not ported yet". Below is what they do, so you can also do it by hand.

1. **On Windows:** stop and disable the services and scheduled tasks you ported. Then check that **none are still running**: `Disable-ScheduledTask` doesn't stop a run already in progress, and copying a half-written database is how you lose data.
   ```powershell
   Get-ScheduledTask | Where-Object State -eq 'Running' | Select-Object TaskPath, TaskName
   ```
2. `shutdown /s /t 0`. A full shutdown, so Linux can mount C:.
3. **On Linux:** re-sync from Windows with delete (Windows is still the source of truth):
   `linux/copy-from-windows.sh --win-user <WindowsUser> --delete --only <folders that hold live data>`.
   Anything you changed on Linux during testing in those folders is **overwritten**. Commit or push it before this step.
4. Enable everything: `sudo systemctl enable --now <prefix>-*.timer <prefix>-*.service`.
5. **Swap the identity:** hostname, static DHCP lease, DNS name, or VPN/tailnet IP. That way clients, monitors and bookmarks keep working without changes. Restart any service that binds a specific IP **after** the swap.
6. Watch your monitoring for a day. Weekly and monthly jobs go green on their next run.
7. Set the firmware boot order to Linux first. Windows stays one key away.

### Rollback

1. On Linux: `sudo out/rollback-linux.sh` (or `sudo systemctl disable --now '<prefix>-*'`). Linux first, so the two machines never run the same jobs.
2. Boot Windows. Re-enable its services and tasks with `out/rollback-windows.ps1` from an admin PowerShell (the reverse of step 1; tasks that were already disabled at export stay disabled).
3. Swap the identity back.
4. **Data written on Linux after cutover has to be copied back by hand.** Linux had Windows mounted read-only, so use a network share or SSH.

### When you're done

- Rotate every password that was ever in a Windows script or task argument.
- Keep the Windows disk for a few weeks before you reuse it.
