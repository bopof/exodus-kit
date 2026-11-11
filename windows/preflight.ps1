<#
.SYNOPSIS
  exodus-kit preflight: checks a Windows PC before installing Linux next to it. Read-only by default.

.DESCRIPTION
  Reports PASS / WARN / FAIL for: Fast Startup, hibernation, BitLocker, hardware clock mode,
  UEFI + Secure Boot, TPM, disks, free space, OneDrive folder redirection, WSL, third-party
  scheduled tasks (running ones and ones whose arguments look like they hold a password).

  -Fix applies the two safe settings: hardware clock in UTC and Fast Startup off.

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
if (-not $isAdmin) { Add-Result 'WARN' 'Administrator' 'not elevated' 'BitLocker, TPM and -Fix need an admin PowerShell' }

$os = Get-CimInstance Win32_OperatingSystem
Add-Result 'INFO' 'Windows' "$($os.Caption) $($os.Version)"

# --- Fast Startup / hibernation ------------------------------------------------
$hiberboot = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
if ($hiberboot -eq 0) { Add-Result 'PASS' 'Fast Startup' 'off' }
else {
  Add-Result 'FAIL' 'Fast Startup' 'on' 'Linux cannot safely mount C: after a hybrid shutdown. -Fix turns it off'
  if ($Fix -and $isAdmin) {
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
    Add-Result 'FIXED' 'Fast Startup' 'HiberbootEnabled set to 0'
  }
}
if (Test-Path "$env:SystemDrive\hiberfil.sys" -ErrorAction SilentlyContinue) {
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
$fw = Get-RegValue 'HKLM:\System\CurrentControlSet\Control' 'PEFirmwareType'
if ($fw -eq 2) { Add-Result 'PASS' 'Firmware' 'UEFI' }
elseif ($fw -eq 1) { Add-Result 'FAIL' 'Firmware' 'legacy BIOS' 'install Linux in the same mode; this kit assumes UEFI' }
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
          'Linux needs the recovery key to read it. Back it up: manage-bde -protectors -get C:'
      } else { Add-Result 'PASS' "BitLocker $($v.MountPoint)" 'not encrypted' }
    }
  } catch { Add-Result 'INFO' 'BitLocker' 'not available on this edition, or query failed' }
}

# --- Disks -------------------------------------------------------------------------------
$sysDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).DiskNumber
foreach ($d in Get-Disk) {
  $role = if ($d.Number -eq $sysDisk) { 'WINDOWS - do not touch' } else { 'candidate for Linux?' }
  Add-Result 'INFO' "Disk $($d.Number)" ("{0} | {1:N0} GB | {2} | {3}" -f $d.FriendlyName, ($d.Size / 1GB), $d.PartitionStyle, $role)
}
$c = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
Add-Result 'INFO' 'Free space C:' ("{0:N0} GB free" -f ($c.Free / 1GB))

# --- Profile -------------------------------------------------------------------------------
$usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
foreach ($n in 'Desktop', 'Personal', 'My Pictures') {
  $p = Get-RegValue $usf $n
  if ($p -and $p -match 'OneDrive') {
    Add-Result 'WARN' "Folder redirection: $n" $p 'files set to online-only are not on disk: make them "Always keep on this device" before copying'
  }
}
$wsl = Get-ChildItem "$env:LOCALAPPDATA\Packages\*\LocalState\ext4.vhdx" -ErrorAction SilentlyContinue
if ($wsl) { Add-Result 'INFO' 'WSL' "$($wsl.Count) distro disk(s)" 'files inside WSL are not in your profile: copy them out (or wsl --export) first' }

# --- Scheduled tasks ----------------------------------------------------------------------
$tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
Add-Result 'INFO' 'Third-party scheduled tasks' "$($tasks.Count)" 'export them with export-windows.ps1'
$running = @($tasks | Where-Object State -eq 'Running')
foreach ($t in $running) { Add-Result 'WARN' 'Task running now' "$($t.TaskPath)$($t.TaskName)" 'let it finish before the final shutdown' }
$secretRx = '(?i)(password|passwd|/pass|-pwd|token|secret|apikey|/user:\S+\s+\S+|net\s+use\s+\S+\s+[^/\s]+)'
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
if ($fails) { Write-Host "$fails blocking issue(s). Fix them before installing Linux." -ForegroundColor Red }
else { Write-Host 'No blocking issue. Next: export-windows.ps1, then a FULL shutdown (shutdown /s /t 0).' -ForegroundColor Green }
