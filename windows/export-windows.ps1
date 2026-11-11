<#
.SYNOPSIS
  exodus-kit export: write this PC's scheduled tasks, services, apps and firewall rules to one JSON file.

.DESCRIPTION
  The output is the input for linux/tasks-to-systemd.py. It contains:
    scheduledTasks  third-party tasks (not \Microsoft\*), each with its full Task Scheduler XML
    services        non-Windows services with start type, account, binary; NSSM parameters when wrapped
    apps            installed programs (registry), plus winget IDs when winget is available
    firewall        enabled inbound allow rules that are not built-in Windows rules

  Arguments that look like secrets (passwords, tokens, "net use" credentials, user:pass@ URLs,
  Authorization headers, *_PASS= / *_KEY= variables) are replaced by <REDACTED> unless you pass
  -NoRedact. Read the file before sharing it anyway.

  The default output folder is %USERPROFILE%\exodus-kit, not the Desktop: OneDrive often
  redirects the Desktop, and the file should not be uploaded to the cloud.

  Run it from an admin PowerShell: without admin rights, tasks owned by SYSTEM or by other
  users are left out.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\export-windows.ps1
  powershell -ExecutionPolicy Bypass -File windows\export-windows.ps1 -OutFile D:\migration\exodus-inventory.json
#>
[CmdletBinding()]
param(
  [string]$OutFile = (Join-Path $env:USERPROFILE 'exodus-kit\exodus-inventory.json'),
  [switch]$IncludeMicrosoftTasks,
  [switch]$IncludeMicrosoftServices,
  [switch]$NoRedact
)
$ErrorActionPreference = 'Continue'
$script:redactions = 0

# Each rule captures the secret in the group named "s"; only that group is replaced.
$script:RedactRules = @(
  # net use [Z:|*] \\server\share PASSWORD ...
  '(?i)\bnet\s+use\s+(?:(?:[a-z]:|\*)\s+)?(?:"\\\\[^"]*"|\\\\\S+)\s+(?!/)(?<s>"[^"]*"|\S+)',
  # /user:DOMAIN\name PASSWORD
  '(?i)/user:\S+\s+(?!/)(?<s>"[^"]*"|\S+)',
  # -Password x, --password=x, /pass:x, -token x ...
  '(?i)(?:^|[\s;&|])-{0,2}/?(?:password|passwd|pwd|pass|token|secret|api[_-]?key|apikey)(?:[=:]|\s+)(?<s>"[^"]*"|''[^'']*''|[^\s"'']+)',
  # NAME=value where NAME looks secret: DB_PASS=x, AWS_SECRET_ACCESS_KEY=x, password = x   # leak-check: allow
  '(?i)\b[\w.-]*(?:pass|pwd|secret|token|key|cred|auth)[\w.-]*\s*=\s*(?<s>"[^"]*"|''[^'']*''|[^\s;&"'']+)',
  # scheme://user:PASSWORD@host
  '(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:(?<s>[^@\s]+)@',
  # ConvertTo-SecureString 'x' -AsPlainText
  '(?i)\bConvertTo-SecureString\s+(?:-String\s+)?(?<s>"[^"]*"|''[^'']*''|[^\s"''-]\S*)',
  # mysql / mysqldump / mysqladmin -pPASSWORD (lower-case -p glued to the value; -P is the port)
  '(?i:\bmysql(?:dump|admin|import|sh)?(?:\.exe)?\b)[^\r\n]*?\s-p(?<s>"[^"]*"|''[^'']*''|[^\s"'']+)',
  # curl -u user:PASSWORD, --user user:PASSWORD (but not docker -u 1000:1000)   # gitleaks:allow
  '(?:^|\s)(?:-u|--user)\s*["'']?[^\s:"'']+:(?!\d+(?:\s|$))(?<s>[^\s"'']+)',   # not uid:gid
  # Authorization: Bearer TOKEN, X-Api-Key: TOKEN
  '(?i)\b(?:proxy-)?authorization\s*:\s*(?:(?:bearer|basic|token|digest|negotiate|ntlm)\s+)?(?<s>[^\s"'']+)',
  '(?i)\bx-[\w-]*(?:key|token|secret|auth)[\w-]*\s*:\s*(?<s>[^\s"'']+)'
)
$script:SecretEnvName = '(?i)(pass|pwd|secret|token|key|cred|auth)'

function Protect-Text([string]$s) {
  if ($NoRedact -or [string]::IsNullOrEmpty($s)) { return $s }
  $out = $s
  foreach ($rx in $script:RedactRules) {
    $out = [regex]::Replace($out, $rx, {
        param($m)
        $g = $m.Groups['s']
        if ($g.Value.Trim('"', "'") -eq '<REDACTED>') { return $m.Value }   # already done by an earlier rule
        $script:redactions++
        $i = $g.Index - $m.Index
        $m.Value.Substring(0, $i) + '<REDACTED>' + $m.Value.Substring($i + $g.Length)
      })
  }
  return $out
}

# NSSM AppEnvironmentExtra entries are NAME=value: hide the whole value when the name looks secret.
function Protect-EnvEntry([string]$e) {
  if ($NoRedact -or [string]::IsNullOrEmpty($e)) { return $e }
  $i = $e.IndexOf('=')
  if ($i -gt 0 -and $e.Substring(0, $i) -match $script:SecretEnvName) {
    $script:redactions++
    return $e.Substring(0, $i + 1) + '<REDACTED>'
  }
  return Protect-Text $e
}

# Service PathName -> executable path ("C:\a b\x.exe" -k, C:\a b\x.exe -k, \??\C:\x.exe ...).
function Get-ServiceBinary([string]$PathName) {
  if ([string]::IsNullOrWhiteSpace($PathName)) { return $null }
  $p = [Environment]::ExpandEnvironmentVariables($PathName.Trim()) -replace '^\\\?\?\\', ''
  if ($p -match '^"([^"]+)"') { return $Matches[1] }
  if ($p -match '(?i)^(.+?\.(?:exe|com|bat|cmd))(?:\s|$)') { return $Matches[1] }
  return ($p -split '\s+')[0]
}

function Test-MicrosoftBinary([string]$exe) {
  if (-not $exe) { return $false }
  try { (Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo.CompanyName -match 'Microsoft' } catch { $false }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Warning 'Not elevated: scheduled tasks owned by SYSTEM or other users will be missing. Re-run from an admin PowerShell for a full export.'
}

# Resolve -OutFile against the PowerShell location (not the process directory) and check it is writable up front.
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$outDir = Split-Path -Parent $OutFile
try {
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction Stop | Out-Null }
} catch { Write-Error "cannot create $outDir : $_"; exit 1 }

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
  if ([string]::IsNullOrWhiteSpace($p)) { continue }   # e.g. LSM, NetSetupSvc
  if (-not $IncludeMicrosoftServices) {
    if ($p -match '(?i)\\Windows\\(System32|SysWOW64|servicing|Microsoft\.NET)\\' -or $p -match '(?i)svchost\.exe') { continue }
    if (Test-MicrosoftBinary (Get-ServiceBinary $p)) { continue }   # Defender, Edge update, ...
  }
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
        # Where-Object: with no AppEnvironmentExtra, $null would go through once and give [""].
        environment = @($pp.AppEnvironmentExtra | Where-Object { $_ } | ForEach-Object { Protect-EnvEntry "$_" })
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
  schema = 1; exportedAt = (Get-Date -Format o); os = "$($os.Caption) $($os.Version)"
  redacted = (-not $NoRedact)
  scheduledTasks = $tasks; services = $services
  apps = @($apps.Values | Sort-Object { $_.name }); firewall = $fw
}
$json = $inv | ConvertTo-Json -Depth 8
try {
  [IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding($false)))
} catch {
  Write-Error "could not write $OutFile : $($_.Exception.Message)"
  exit 1
}

Write-Host ''
Write-Host ("Wrote {0}: {1} task(s), {2} service(s), {3} app(s), {4} firewall rule(s)." -f `
  $OutFile, $tasks.Count, $services.Count, $inv.apps.Count, $fw.Count) -ForegroundColor Green
if (-not $isAdmin) { Write-Host 'Not elevated: tasks owned by SYSTEM or other users are missing.' -ForegroundColor Yellow }
if ($NoRedact) { Write-Host 'NOT redacted: treat this file as a secret.' -ForegroundColor Red }
else { Write-Host "$script:redactions value(s) redacted. Read the file before sharing it: redaction is best-effort." -ForegroundColor Yellow }
Write-Host "It also contains your user name, paths and machine name. Don't publish it as-is."
