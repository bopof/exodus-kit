# Pester 5+ tests for the redaction in windows/export-windows.ps1.
# Run (Windows PowerShell 5.1 or pwsh 7, from the repo root):
#   Invoke-Pester tests/Protect-Text.Tests.ps1
# The script itself queries Windows when run, so only its helper functions and rule tables
# are loaded here, straight from its syntax tree.

BeforeAll {
  $path = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows') 'export-windows.ps1'
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
  $wanted = 'Protect-Text', 'Protect-EnvEntry', 'Get-ServiceBinary'
  $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $false)
  $vars = $ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Left.Extent.Text -in '$script:RedactRules', '$script:SecretEnvName' }
  foreach ($n in @($vars) + @($funcs)) { . ([scriptblock]::Create($n.Extent.Text)) }
  $NoRedact = $false
  function Redact([string]$s) { $script:redactions = 0; Protect-Text $s }
}

Describe 'Protect-Text redacts' {
  It '<name>' -ForEach @(
    @{ name = 'net use with drive letter'; in = 'net use Z: \\srv\share S3cret /user:dom\bob'; out = 'net use Z: \\srv\share <REDACTED> /user:dom\bob' }
    @{ name = 'net use with *';            in = 'net use * \\srv\share S3cret /persistent:no';  out = 'net use * \\srv\share <REDACTED> /persistent:no' }
    @{ name = 'net use without drive';     in = 'net use \\srv\share S3cret /user:bob';         out = 'net use \\srv\share <REDACTED> /user:bob' }
    @{ name = 'net use quoted share';      in = 'net use Z: "\\srv\my share" S3cret';           out = 'net use Z: "\\srv\my share" <REDACTED>' }
    @{ name = '/user: then password';      in = 'net use Z: \\srv\share /user:bob S3cret';      out = 'net use Z: \\srv\share /user:bob <REDACTED>' }
    @{ name = 'ConvertTo-SecureString';    in = "ConvertTo-SecureString 'S3cret' -AsPlainText -Force"; out = 'ConvertTo-SecureString <REDACTED> -AsPlainText -Force' }
    @{ name = 'ConvertTo-SecureString -String'; in = 'ConvertTo-SecureString -String "S3cret" -AsPlainText'; out = 'ConvertTo-SecureString -String <REDACTED> -AsPlainText' }
    @{ name = 'mysql -p';                  in = 'mysql -u root -pS3cret -P 3306 db';           out = 'mysql -u root -p<REDACTED> -P 3306 db' }
    @{ name = 'mysqldump.exe -p';          in = 'C:\x\mysqldump.exe -h h -pS3cret db';         out = 'C:\x\mysqldump.exe -h h -p<REDACTED> db' }
    @{ name = 'curl -u';                   in = 'curl -u bob:S3cret https://h';                out = 'curl -u bob:<REDACTED> https://h' }   # gitleaks:allow (fake fixture)
    @{ name = 'curl --user quoted';        in = 'curl --user "bob:S3cret" https://h';          out = 'curl --user "bob:<REDACTED>" https://h' }
    @{ name = 'Authorization Bearer';      in = 'curl -H "Authorization: Bearer abc123" https://h'; out = 'curl -H "Authorization: Bearer <REDACTED>" https://h' }
    @{ name = 'Authorization Basic';       in = "curl -H 'Authorization: Basic Ym9iOnM='";     out = "curl -H 'Authorization: Basic <REDACTED>'" }
    @{ name = 'X-Api-Key header';          in = 'curl -H "X-Api-Key: abc123" https://h';       out = 'curl -H "X-Api-Key: <REDACTED>" https://h' }   # leak-check: allow (fake fixture)
    @{ name = 'DB_PASS=';                  in = 'set DB_PASS=S3cret&& run.exe';                out = 'set DB_PASS=<REDACTED>&& run.exe' }
    @{ name = 'AWS_SECRET_ACCESS_KEY=';    in = 'AWS_SECRET_ACCESS_KEY=S3cret';                out = 'AWS_SECRET_ACCESS_KEY=<REDACTED>' }
    @{ name = '-Password "two words"';     in = 'app.ps1 -Password "two words" -X';            out = 'app.ps1 -Password <REDACTED> -X' }
    @{ name = '--password=x';              in = 'tool --password=x --verbose';                 out = 'tool --password=<REDACTED> --verbose' }
    @{ name = '/pass:x';                   in = 'tool /pass:x';                                out = 'tool /pass:<REDACTED>' }
    @{ name = '-token x';                  in = 'tool -token abc';                             out = 'tool -token <REDACTED>' }
    @{ name = 'URL credentials';           in = 'rclone https://u:p@host/path';                out = 'rclone https://u:<REDACTED>@host/path' }
  ) {
    Redact $in | Should -BeExactly $out
  }
}

Describe 'Protect-Text leaves alone' {
  It '<in>' -ForEach @(
    @{ in = 'msiexec /i app.msi /passive /norestart' }
    @{ in = 'net use Z: \\srv\share /persistent:yes' }
    @{ in = 'mysql -u root -p db' }
    @{ in = 'mysql -u root -P 3306 db' }
    @{ in = 'docker run -u 1000:1000 img' }
    @{ in = 'robocopy C:\src D:\dst /MIR /R:1' }
    @{ in = 'python C:\jobs\backup.py --dest \\nas\backup' }
    @{ in = 'https://host/path?x=1' }
  ) {
    Redact $in | Should -BeExactly $in
  }
}

Describe 'Redaction counter' {
  It 'counts values, not rules' {
    Redact 'a --password=x -token y' | Out-Null
    $script:redactions | Should -Be 2
  }
  It 'does not count the same value twice' {
    Redact 'tool --password=x' | Out-Null   # rule 3 and the NAME=value rule both match
    $script:redactions | Should -Be 1
  }
  It 'does nothing with -NoRedact' {
    $NoRedact = $true
    Redact 'tool --password=x' | Should -BeExactly 'tool --password=x'
    $script:redactions | Should -Be 0
  }
}

Describe 'Protect-EnvEntry (NSSM AppEnvironmentExtra)' {
  It '<in>' -ForEach @(
    @{ in = 'DB_PASSWORD=S3cret';  out = 'DB_PASSWORD=<REDACTED>' }
    @{ in = 'API_KEY=a b c';       out = 'API_KEY=<REDACTED>' }
    @{ in = 'GH_TOKEN=x=y';        out = 'GH_TOKEN=<REDACTED>' }
    @{ in = 'MY_CREDS=x';          out = 'MY_CREDS=<REDACTED>' }
    @{ in = 'PATH=C:\bin';         out = 'PATH=C:\bin' }
    @{ in = 'URL=https://u:p@h';   out = 'URL=https://u:<REDACTED>@h' }
  ) {
    Protect-EnvEntry $in | Should -BeExactly $out
  }
}

Describe 'Get-ServiceBinary' {
  It '<in>' -ForEach @(
    @{ in = '"C:\Program Files\App\svc.exe" -k run'; out = 'C:\Program Files\App\svc.exe' }
    @{ in = 'C:\Program Files\App\svc.exe -k run';   out = 'C:\Program Files\App\svc.exe' }
    @{ in = '\??\C:\drv\x.exe';                      out = 'C:\drv\x.exe' }
    @{ in = 'C:\tools\nssm.exe';                     out = 'C:\tools\nssm.exe' }
    @{ in = '';                                      out = $null }
  ) {
    Get-ServiceBinary $in | Should -Be $out
  }
}
