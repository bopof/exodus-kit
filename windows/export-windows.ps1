<#
.SYNOPSIS
  exodus-kit export: write this PC's scheduled tasks, services, apps and firewall rules to one JSON file.

.DESCRIPTION
  The output is the input for linux/tasks-to-systemd.py. It contains:
    scheduledTasks  third-party tasks (not \Microsoft\*), each with its full Task Scheduler XML
    services        non-Windows services with start type, account, binary; NSSM parameters when wrapped
    apps            installed programs (registry), plus winget IDs when winget is available
    firewall        enabled inbound allow rules that are not built-in Windows rules

  Arguments that look like secrets (passwords, tokens, "net use" credentials, user:pass@ URLs)
  are replaced by <REDACTED> unless you pass -NoRedact. Read the file before sharing it anyway.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\export-windows.ps1 -OutFile $HOME\Desktop\exodus-inventory.json
#>
[CmdletBinding()]
param(
  [string]$OutFile = "$HOME\Desktop\exodus-inventory.json",
  [switch]$IncludeMicrosoftTasks,
  [switch]$NoRedact
)
$ErrorActionPreference = 'Continue'
$script:redactions = 0

function Protect-Text([string]$s) {
  if ($NoRedact -or [string]::IsNullOrEmpty($s)) { return $s }
  $rules = @(
    @('(?i)(\bnet\s+use\s+\S+\s+)(?!/)("[^"]*"|\S+)(?=.*?/user:)', '$1<REDACTED>'),
    @('(?i)(/user:\S+\s+)(?!/)("[^"]*"|\S+)', '$1<REDACTED>'),
    @('(?i)((?:^|[\s;&|])-{0,2}/?(?:password|passwd|pwd|pass|token|secret|api[_-]?key|apikey)(?:[=:]|\s+))("[^"]*"|''[^'']*''|[^\s"'']+)', '$1<REDACTED>'),
    @('(?i)((?:password|passwd|pwd|token|secret|api[_-]?key)\s*=\s*)("[^"]*"|[^\s;&"]+)', '$1<REDACTED>'),
    @('(?i)(\b[a-z][a-z0-9+.-]*://[^/\s:@]+:)[^@\s]+@', '$1<REDACTED>@')
  )
  $out = $s
  foreach ($r in $rules) {
    $new = [regex]::Replace($out, $r[0], $r[1])
    if ($new -ne $out) { $script:redactions++ ; $out = $new }
  }
  return $out
}

# --- Scheduled tasks ---------------------------------------------------------------------
Write-Host '==> scheduled tasks'
$tasks = @()
foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
  if (-not $IncludeMicrosoftTasks -and $t.TaskPath -like '\Microsoft\*') { continue }
  try {
    $xml = Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
  } catch { Write-Warning "cannot export $($t.TaskPath)$($t.TaskName): $_"; continue }
  # Redact inside <Arguments> and <Command> only, so the XML stays valid.
  $xml = [regex]::Replace($xml, '(?s)(<(Arguments|Command)>)(.*?)(</\2>)', {
      param($m) $m.Groups[1].Value + (Protect-Text $m.Groups[3].Value) + $m.Groups[4].Value })
  $tasks += [ordered]@{ name = $t.TaskName; path = $t.TaskPath; state = "$($t.State)"; xml = $xml }
}

# --- Services ----------------------------------------------------------------------------------
Write-Host '==> services'
$services = @()
foreach ($s in Get-CimInstance Win32_Service) {
  $p = "$($s.PathName)"
  if ($p -match '(?i)\\Windows\\(System32|SysWOW64|servicing|Microsoft\.NET)\\' -or $p -match '(?i)svchost\.exe') { continue }
  $start = switch ($s.StartMode) { 'Auto' { if ($s.DelayedAutoStart) { 'AutomaticDelayedStart' } else { 'Automatic' } } default { "$($s.StartMode)" } }
  $nssm = $null
  if ($p -match '(?i)nssm(\.exe)?') {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)\Parameters"
    $pp = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if ($pp) {
      $nssm = [ordered]@{
        application = "$($pp.Application)"
        parameters  = Protect-Text "$($pp.AppParameters)"
        directory   = "$($pp.AppDirectory)"
        environment = @($pp.AppEnvironmentExtra | ForEach-Object { Protect-Text "$_" })
      }
    }
  }
  $services += [ordered]@{
    name = $s.Name; displayName = $s.DisplayName; startType = $start; state = "$($s.State)"
    binaryPath = Protect-Text $p; account = "$($s.StartName)"; nssm = $nssm
  }
}

# --- Apps -----------------------------------------------------------------------------------
Write-Host '==> installed apps'
$apps = @{}
$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
foreach ($a in Get-ItemProperty $keys -ErrorAction SilentlyContinue) {
  if (-not $a.DisplayName -or $a.SystemComponent -eq 1 -or $a.ParentKeyName -or $a.ReleaseType) { continue }
  $apps[$a.DisplayName] = [ordered]@{ name = $a.DisplayName; version = "$($a.DisplayVersion)"; publisher = "$($a.Publisher)"; source = 'registry' }
}
if (Get-Command winget -ErrorAction SilentlyContinue) {
  $tmp = Join-Path $env:TEMP "exodus-winget-$PID.json"
  winget export -o $tmp --accept-source-agreements --disable-interactivity *> $null
  if (Test-Path $tmp) {
    foreach ($src in (Get-Content $tmp -Raw | ConvertFrom-Json).Sources) {
      foreach ($pkg in $src.Packages) {
        $id = $pkg.PackageIdentifier
        if (-not $apps.ContainsKey($id)) { $apps[$id] = [ordered]@{ name = $id; version = ''; publisher = ''; source = "winget:$($src.SourceDetails.Name)" } }
      }
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }
}
foreach ($x in Get-AppxPackage -PackageTypeFilter Main -ErrorAction SilentlyContinue) {
  if ($x.SignatureKind -ne 'Store' -or $x.Name -like 'Microsoft.*') { continue }
  $apps[$x.Name] = [ordered]@{ name = $x.Name; version = "$($x.Version)"; publisher = "$($x.PublisherId)"; source = 'store' }
}

# --- Firewall ---------------------------------------------------------------------------------
Write-Host '==> firewall rules (inbound allow, custom)'
$fw = @()
foreach ($r in Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue) {
  if ($r.DisplayGroup -or $r.Group) { continue }   # built-in groups
  $port = $r | Get-NetFirewallPortFilter
  $addr = $r | Get-NetFirewallAddressFilter
  $app  = $r | Get-NetFirewallApplicationFilter
  $fw += [ordered]@{
    name = $r.DisplayName; protocol = "$($port.Protocol)"; localPort = ($port.LocalPort -join ',')
    remoteAddress = ($addr.RemoteAddress -join ','); program = "$($app.Program)"
  }
}

# --- Write ----------------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$inv = [ordered]@{
  schema = 1; exportedAt = (Get-Date -Format s); os = "$($os.Caption) $($os.Version)"
  redacted = (-not $NoRedact)
  scheduledTasks = $tasks; services = $services
  apps = @($apps.Values | Sort-Object { $_.name }); firewall = $fw
}
$json = $inv | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("Wrote {0}: {1} task(s), {2} service(s), {3} app(s), {4} firewall rule(s)." -f `
  $OutFile, $tasks.Count, $services.Count, $inv.apps.Count, $fw.Count) -ForegroundColor Green
if ($NoRedact) { Write-Host 'NOT redacted: treat this file as a secret.' -ForegroundColor Red }
else { Write-Host "$script:redactions value(s) redacted. Read the file before sharing it: redaction is best-effort." -ForegroundColor Yellow }
Write-Host "It also contains your user name, paths and machine name. Don't publish it as-is."
