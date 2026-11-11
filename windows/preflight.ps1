<#
.SYNOPSIS
  exodus-kit preflight: checks a Windows PC before installing Linux next to it. Read-only by default.

.DESCRIPTION
  Reports PASS / WARN / FAIL for: Fast Startup, hibernation, BitLocker, hardware clock mode,
  UEFI + Secure Boot, TPM, Intel RST/VMD storage mode, disks, free space, OneDrive folder
  redirection, WSL / Docker disks, third-party scheduled tasks (scheduled ones running now and
  ones whose arguments look like they hold a password).

  -Fix applies the two safe settings: hardware clock in UTC and Fast Startup off. Needs admin.

  Run it from an admin PowerShell. Without admin rights some checks are skipped and the verdict
  says so. Exit code: 1 if there is a FAIL, else 0.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\preflight.ps1
  powershell -ExecutionPolicy Bypass -File windows\preflight.ps1 -Fix
#>
[CmdletBinding()]
param([switch]$Fix)

$ErrorActionPreference = 'Continue'
$results = New-Object System.Collections.Generic.List[object]
function Add-Result($Status, $Check, $Detail, $Hint = '') {
  $results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail; Hint = $Hint })
}
function Get-RegValue($Path, $Name) {
  try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Add-Result 'WARN' 'Administrator' 'not elevated' 'TPM, BitLocker details, Secure Boot and -Fix need an admin PowerShell' }
if ($Fix -and -not $isAdmin) { Add-Result 'WARN' '-Fix' 'skipped: not elevated, nothing was changed' 're-run from an admin PowerShell' }
$sys = $env:SystemDrive   # usually C:

$os = Get-CimInstance Win32_OperatingSystem
Add-Result 'INFO' 'Windows' "$($os.Caption) $($os.Version)"

# --- Fast Startup / hibernation ------------------------------------------------
$hiberboot = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
$hibernateOn = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
$hiberfil = Test-Path "$sys\hiberfil.sys" -ErrorAction SilentlyContinue
if ($hiberboot -eq 0) { Add-Result 'PASS' 'Fast Startup' 'off' }
elseif ($hibernateOn -eq 0 -or ($null -eq $hiberboot -and -not $hiberfil)) {
  # Fast Startup is a hibernation of the kernel session: with hibernation disabled it cannot happen.
  Add-Result 'PASS' 'Fast Startup' 'unavailable (hibernation is off)'
}
else {
  Add-Result 'FAIL' 'Fast Startup' 'on' 'Linux cannot safely mount C: after a hybrid shutdown. -Fix turns it off'
  if ($Fix -and $isAdmin) {
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
    Add-Result 'FIXED' 'Fast Startup' 'HiberbootEnabled set to 0'
  }
}
if ($hiberfil) {
  Add-Result 'INFO' 'Hibernation file' 'present' 'fine as long as you shut down fully (shutdown /s /t 0) before booting Linux'
}

# --- Clock -----------------------------------------------------------------------
$rtu = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal'
if ($rtu -eq 1) { Add-Result 'PASS' 'Hardware clock' 'UTC' }
else {
  Add-Result 'WARN' 'Hardware clock' 'local time' 'the clock jumps when switching OS. -Fix sets RealTimeIsUniversal=1'
  if ($Fix -and $isAdmin) {
    New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name RealTimeIsUniversal -Value 1 -PropertyType DWord -Force | Out-Null
    Add-Result 'FIXED' 'Hardware clock' 'RealTimeIsUniversal=1 (takes effect after reboot)'
  }
}

# --- Firmware / Secure Boot / TPM -----------------------------------------------------
# $env:firmware_type is set by Windows itself (UEFI / Legacy); PEFirmwareType is gone on recent Windows 11.
$fw = "$env:firmware_type"
if (-not $fw) {
  switch (Get-RegValue 'HKLM:\System\CurrentControlSet\Control' 'PEFirmwareType') { 1 { $fw = 'Legacy' } 2 { $fw = 'UEFI' } }
}
if ($fw -eq 'UEFI') { Add-Result 'PASS' 'Firmware' 'UEFI' }
elseif ($fw -eq 'Legacy') { Add-Result 'FAIL' 'Firmware' 'legacy BIOS' 'install Linux in the same mode; this kit assumes UEFI' }
else { Add-Result 'WARN' 'Firmware' 'unknown' 'check msinfo32 -> "BIOS Mode"; this kit assumes UEFI' }
try {
  if (Confirm-SecureBootUEFI -ErrorAction Stop) { Add-Result 'PASS' 'Secure Boot' 'on' }
  else { Add-Result 'WARN' 'Secure Boot' 'off' 'TPM unlock sealed to PCR 7 protects little without it' }
} catch { Add-Result 'INFO' 'Secure Boot' 'could not read (not elevated, or not UEFI)' }
if ($isAdmin) {
  try {
    $tpm = Get-Tpm -ErrorAction Stop
    if ($tpm.TpmPresent -and $tpm.TpmReady) { Add-Result 'PASS' 'TPM' 'present and ready' }
    elseif ($tpm.TpmPresent) { Add-Result 'WARN' 'TPM' 'present, not ready' }
    else { Add-Result 'WARN' 'TPM' 'none' 'unattended LUKS unlock will not be possible (enable fTPM/PTT in firmware?)' }
  } catch { Add-Result 'INFO' 'TPM' 'could not query' }
}

# --- BitLocker -----------------------------------------------------------------------
if ($isAdmin) {
  try {
    foreach ($v in Get-BitLockerVolume -ErrorAction Stop) {
      if ($v.ProtectionStatus -eq 'On' -or $v.VolumeStatus -ne 'FullyDecrypted') {
        Add-Result 'WARN' "BitLocker $($v.MountPoint)" "$($v.VolumeStatus), protection $($v.ProtectionStatus)" `
          "Linux needs the recovery key to read it. Back it up: manage-bde -protectors -get $($v.MountPoint)"
      } else { Add-Result 'PASS' "BitLocker $($v.MountPoint)" 'not encrypted' }
    }
  } catch { Add-Result 'INFO' 'BitLocker' 'not available on this edition, or query failed' }
} else {
  # Without admin, Explorer's shell property still tells encrypted from not encrypted.
  # Known values: 1 = on, 2 = off, 3 = encrypting, 4 = decrypting, 5 = suspended, 6 = on (locked);
  # anything but 2 is reported as "encrypted or unknown" so a wrong mapping cannot give a false PASS.
  try {
    $shell = New-Object -ComObject Shell.Application
    foreach ($ld in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
      $code = $shell.NameSpace("$($ld.DeviceID)\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
      if ($code -eq 2) { Add-Result 'PASS' "BitLocker $($ld.DeviceID)" 'not encrypted' }
      elseif ($null -eq $code -or $code -eq 0) { Add-Result 'INFO' "BitLocker $($ld.DeviceID)" 'unknown' 're-run as admin' }
      else {
        Add-Result 'WARN' "BitLocker $($ld.DeviceID)" "encrypted or in transition (code $code)" `
          "Linux needs the recovery key to read it. Back it up (admin): manage-bde -protectors -get $($ld.DeviceID)"
      }
    }
  } catch { Add-Result 'INFO' 'BitLocker' 'could not read without admin' 're-run as admin' }
}

# --- Storage mode --------------------------------------------------------------------
# Intel RST / VMD ("RAID" mode) hides NVMe drives from most Linux installers.
$rst = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^iaStor' -and $_.State -eq 'Running' })
if ($rst) {
  # INFO, not WARN: the only real-hardware data point (Ubuntu 26.04 behind VMD) installed fine.
  Add-Result 'INFO' 'Storage mode' "Intel RST/VMD driver active ($(($rst.Name) -join ', '))" `
    'Linux has a vmd driver and a recent installer may work as is (Ubuntu 26.04 did on the reference machine); older installers may not see the drives or may refuse. If the installer lists no disk or complains about RST, switch the firmware to AHCI / disable VMD, booting Windows once in Safe Mode first so it loads the AHCI driver'
} else { Add-Result 'PASS' 'Storage mode' 'no Intel RST/VMD driver running' }

# --- Disks -------------------------------------------------------------------------------
$sysDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).DiskNumber
foreach ($d in Get-Disk) {
  # GPT types: 0fc63daf... = Linux filesystem (also used for LUKS), 0657fd6d... = Linux swap, e6d6d379... = LVM.
  $linuxParts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
    Where-Object { $_.GptType -match '0fc63daf-8483-4772-8e79-3d69d8477de4|0657fd6d-a4ab-43c4-84e5-0933c84b4f4f|e6d6d379-f507-44c2-a23c-238f2a3df928' })
  $role = if ($d.Number -eq $sysDisk) { 'WINDOWS - do not touch' }
          elseif ($linuxParts.Count) { "already has $($linuxParts.Count) Linux partition(s)" }
          else { 'candidate for Linux?' }
  Add-Result 'INFO' "Disk $($d.Number)" ("{0} | {1:N0} GB | {2} | {3}" -f $d.FriendlyName, ($d.Size / 1GB), $d.PartitionStyle, $role)
}
$c = Get-PSDrive -Name ($sys.TrimEnd(':'))
Add-Result 'INFO' "Free space $sys" ("{0:N0} GB free" -f ($c.Free / 1GB))

# --- Profile -------------------------------------------------------------------------------
$usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
foreach ($n in 'Desktop', 'Personal', 'My Pictures') {
  $p = Get-RegValue $usf $n
  if ($p -and $p -match 'OneDrive') {
    Add-Result 'WARN' "Folder redirection: $n" $p 'files set to online-only are not on disk: make them "Always keep on this device" before copying'
  }
}
# Every registered WSL distro (Store, wsl --install, wsl --import, Docker Desktop) has a BasePath here.
$distros = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
  ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.BasePath })
$vhdx = @(Get-ChildItem "$env:LOCALAPPDATA\Packages\*\LocalState\ext4.vhdx", "$env:LOCALAPPDATA\wsl\*\ext4.vhdx" -ErrorAction SilentlyContinue)
if ($distros.Count -or $vhdx.Count) {
  $names = if ($distros.Count) { ($distros | ForEach-Object { $_.DistributionName }) -join ', ' } else { "$($vhdx.Count) disk(s)" }
  $hint = 'files inside WSL are not in your profile: copy them out (or wsl --export <name> file.tar) first'
  if ($names -match 'docker-desktop') { $hint += '. Docker Desktop volumes and images live there too: docker save / back up volumes' }
  Add-Result 'INFO' 'WSL' $names $hint
}

# --- Scheduled tasks ----------------------------------------------------------------------
$tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
Add-Result 'INFO' 'Third-party scheduled tasks' "$($tasks.Count)" 'export them with export-windows.ps1'
# Only scheduled jobs matter here (a backup mid-run); always-running agents started at logon do not.
function Test-TimeTriggered($t) {
  foreach ($tr in @($t.Triggers)) {
    if (-not $tr) { continue }
    if ($tr.CimClass.CimClassName -match 'Time|Daily|Weekly|Monthly') { return $true }
    if ($tr.Repetition -and $tr.Repetition.Interval) { return $true }
  }
  return $false
}
$running = @($tasks | Where-Object { $_.State -eq 'Running' -and (Test-TimeTriggered $_) })
foreach ($t in $running) { Add-Result 'WARN' 'Task running now' "$($t.TaskPath)$($t.TaskName)" 'let it finish before the final shutdown' }
$secretRx = '(?i)(password|passwd|/pass\b|/pass:|-pwd|token|secret|api[_-]?key|/user:\S+\s+\S+|net\s+use\s+(?:\S+\s+)?\\\\\S+\s+[^/\s]+|AsPlainText|authorization:|mysql\S*\s.*\s-p\S|\s-u\s+\S+:\S)'
foreach ($t in $tasks) {
  foreach ($a in $t.Actions) {
    if ("$($a.Execute) $($a.Arguments)" -match $secretRx) {
      Add-Result 'WARN' 'Possible secret in task' "$($t.TaskPath)$($t.TaskName)" 'rotate it after the migration; never copy it into a Linux unit'
    }
  }
}

# --- Output ----------------------------------------------------------------------------------
$color = @{ PASS = 'Green'; FIXED = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }
foreach ($r in $results) {
  Write-Host ("[{0,-5}] {1,-30} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color[$r.Status]
  if ($r.Hint -and $r.Status -ne 'PASS') { Write-Host ("        -> {0}" -f $r.Hint) -ForegroundColor DarkGray }
}
$fails = @($results | Where-Object Status -eq 'FAIL').Count
Write-Host ''
if ($fails) { Write-Host "$fails blocking issue(s). Fix them before installing Linux." -ForegroundColor Red; exit 1 }
elseif (-not $isAdmin) {
  Write-Host 'INCOMPLETE: no blocking issue in what could be checked, but TPM and parts of BitLocker/Secure Boot need admin. Re-run from an admin PowerShell.' -ForegroundColor Yellow
}
else { Write-Host 'No blocking issue. Next: export-windows.ps1, then a FULL shutdown (shutdown /s /t 0).' -ForegroundColor Green }
exit 0
