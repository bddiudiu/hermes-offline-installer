#requires -Version 5.1
# Runs selected function definitions against temporary fixtures only. Never invoke
# the upgrader entrypoint, stop a process/service, or inspect a real Hermes home.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($env:OS -ne 'Windows_NT') { throw 'These function tests require Windows PowerShell 5.1.' }

$Repository = Split-Path -Parent $PSScriptRoot
$UpgradePath = Join-Path $Repository 'installers\upgrade.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($UpgradePath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) { throw ($ParseErrors | Out-String) }
$SelectedFunctions = @(
  'Full-Path', 'Test-Within', 'Assert-Separate', 'Assert-NoLinks',
  'Quote-Argument', 'Split-Command', 'Get-RestartSpecs', 'Assert-RestartSpec',
  'Write-Journal', 'New-PrivateDirectory', 'Copy-Tree'
)
$Definitions = @($Ast.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($Name in $SelectedFunctions) {
  $Definition = @($Definitions | Where-Object { $_.Name -eq $Name })
  if ($Definition.Count -ne 1) { throw "Expected one upgrade function: $Name" }
  # Import only this named function definition, never the top-level script body.
  . ([ScriptBlock]::Create($Definition[0].Extent.Text))
}

if (-not ('HermesUpgrade.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace HermesUpgrade { public static class Native {
 [DllImport("shell32.dll", SetLastError=true)] public static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cmd, out int argc);
 [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr ptr);
} }
'@
}

$script:Passed = 0
function Assert-Condition([bool] $Condition, [string] $Label) {
  if (-not $Condition) { throw "FAIL: $Label" }
  $script:Passed++
}
function Assert-Throws([scriptblock] $Action, [string] $Label) {
  $Thrown = $false
  try { & $Action | Out-Null } catch { $Thrown = $true }
  Assert-Condition $Thrown $Label
}
function New-FakeProcess([int] $Id, [int] $ParentId, [string] $File, [string[]] $Arguments) {
  $Command = (@(@($File) + @($Arguments) | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
  return [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $ParentId; ExecutablePath = $File; CommandLine = $Command }
}
function Write-Fixture([string] $Path, [byte[]] $Bytes) {
  [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
  [IO.File]::WriteAllBytes($Path, $Bytes)
}

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-upgrade-unit-' + [Guid]::NewGuid().ToString('N'))
$Lock = $null
try {
  New-PrivateDirectory $TestRoot
  $PrivateAcl = Get-Acl -LiteralPath $TestRoot
  Assert-Condition $PrivateAcl.AreAccessRulesProtected 'temporary backup ACL does not inherit broad permissions'
  $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $AllowedSids = @($CurrentSid, 'S-1-5-18', 'S-1-5-32-544')
  foreach ($Rule in $PrivateAcl.Access) {
    $Sid = $Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    Assert-Condition ($Sid -in $AllowedSids) 'private backup ACL contains only owner, SYSTEM and administrators'
  }

  $script:InstallRoot = Join-Path $TestRoot '安装 with spaces'
  $script:Runtime = Join-Path $script:InstallRoot 'runtime'
  [IO.Directory]::CreateDirectory($script:Runtime) | Out-Null
  Assert-Condition (Test-Within (Join-Path $script:Runtime 'venv\Scripts\python.exe') $script:Runtime) 'runtime child is contained'
  Assert-Condition (-not (Test-Within ($script:Runtime + '-unrelated\python.exe') $script:Runtime)) 'runtime sibling is not contained by prefix'
  Assert-Condition (Test-Within ($script:Runtime.ToUpperInvariant()) $script:Runtime) 'Windows path comparison is case insensitive'
  Assert-Throws { Full-Path ([IO.Path]::GetPathRoot($TestRoot)) } 'volume root is rejected'
  Assert-Throws { Assert-Separate $script:Runtime (Join-Path $script:Runtime 'nested') } 'nested snapshot/install trees are rejected'
  Assert-NoLinks $script:InstallRoot
  Assert-NoLinks (Join-Path $TestRoot 'does-not-exist\home') -AllowMissing
  $script:Passed += 2

  $Arguments = @('', 'with spaces', '中文 目录', 'a"b', 'C:\trailing path\', 'ends\\', 'before\"after', '| & % !', '--literal=a b')
  $Line = (Quote-Argument 'C:\fixture\program.exe') + ' ' + (@($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
  $Parsed = @(Split-Command $Line)
  Assert-Condition ($Parsed.Count -eq $Arguments.Count + 1) 'Windows quoting preserves argument count including empty strings'
  for ($Index = 0; $Index -lt $Arguments.Count; $Index++) {
    Assert-Condition ($Parsed[$Index + 1] -ceq $Arguments[$Index]) "Windows quoting round trip argument $Index"
  }

  $Python = Join-Path $script:Runtime 'venv\Scripts\python.exe'
  $Hermes = Join-Path $script:Runtime 'venv\Scripts\hermes.exe'
  $Gateway = New-FakeProcess 101 100 $Python @('-m', 'hermes_cli.main', 'gateway', 'run', '--quiet')
  $Specs = @(Get-RestartSpecs @($Gateway))
  Assert-Condition ($Specs.Count -eq 1 -and $Specs[0].kind -eq 'gateway' -and $Specs[0].file -eq $Python) 'explicit Hermes Python gateway launcher is recognized'
  Assert-RestartSpec $Specs[0]
  $script:Passed++
  $Dashboard = New-FakeProcess 201 200 $Hermes @('dashboard', '--no-open', '--port', '8080', '--host', '::1')
  $DashboardSpecs = @(Get-RestartSpecs @($Dashboard))
  Assert-Condition ($DashboardSpecs.Count -eq 1 -and $DashboardSpecs[0].kind -eq 'dashboard') 'Hermes console dashboard launcher is recognized'
  Assert-RestartSpec $DashboardSpecs[0]
  $script:Passed++
  Assert-Throws { Get-RestartSpecs @((New-FakeProcess 301 300 $Python @('gateway', 'run'))) } 'arbitrary Python script cannot be replayed as Hermes'
  Assert-Throws { Get-RestartSpecs @((New-FakeProcess 301 300 $Python @('-m', 'other.module', 'gateway', 'run'))) } 'non-Hermes Python module is rejected'
  Assert-Throws { Get-RestartSpecs @((New-FakeProcess 301 300 (Join-Path $script:Runtime 'other\python.exe') @('-m', 'hermes_cli.main', 'gateway', 'run'))) } 'same-named executable outside final venv is rejected'
  Assert-Throws { Get-RestartSpecs @((New-FakeProcess 301 300 $Hermes @('gateway', 'run', '--profile', 'work'))) } 'profile-specific gateway topology requires review'
  Assert-Throws { Get-RestartSpecs @((New-FakeProcess 301 300 $Hermes @('dashboard', '--port', '65536'))) } 'invalid dashboard port is rejected'
  Assert-Throws { Get-RestartSpecs @((New-FakeProcess 301 300 $Hermes @('dashboard', '--host', '0.0.0.0'))) } 'new non-loopback dashboard binding is rejected'
  Assert-Throws { Get-RestartSpecs @($Gateway, (New-FakeProcess 401 400 $Python @('-m', 'hermes_cli.main', 'gateway', 'run'))) } 'multiple independent gateways require topology review'
  $Child = New-FakeProcess 102 101 $Python @('-c', 'never executed')
  Assert-Condition (@(Get-RestartSpecs @($Gateway, $Child)).Count -eq 1) 'owned descendants are not independently replayed'
  Assert-Throws { Assert-RestartSpec ([pscustomobject]@{ file = (Join-Path $TestRoot 'outside\python.exe'); args = @('-m', 'hermes_cli.main', 'gateway', 'run'); kind = 'gateway' }) } 'tampered journal cannot run an outside executable'
  Assert-Throws { Assert-RestartSpec ([pscustomobject]@{ file = $Hermes; args = @('dashboard'); kind = 'gateway' }) } 'tampered journal kind must match reconstructed command'

  $script:JournalPath = Join-Path $TestRoot 'journal.json'
  $script:Journal = [ordered]@{ schema = 1; phase = 'prepared'; updatedUtc = ''; home = '中文 home'; runtimeMoved = $false }
  Write-Journal 'prepared'
  $First = Get-Content -LiteralPath $script:JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Condition ($First.phase -eq 'prepared' -and $First.home -ceq '中文 home') 'first journal write preserves UTF-8 content'
  $script:Journal.runtimeMoved = $true
  Write-Journal 'replacing-runtime'
  $Second = Get-Content -LiteralPath $script:JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Condition ($Second.phase -eq 'replacing-runtime' -and $Second.runtimeMoved -eq $true) 'atomic journal replacement records new intent'
  Assert-Condition (-not (Test-Path -LiteralPath ($script:JournalPath + '.tmp'))) 'atomic journal leaves no temporary replacement file'
  $LockPath = Join-Path $TestRoot 'exclusive.lock'
  $Lock = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None')
  Assert-Throws { $Other = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None'); $Other.Dispose() } 'live lock handle excludes concurrent writer'
  $Lock.Dispose()
  $Lock = $null
  $Again = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None')
  $Again.Dispose()
  $script:Passed++

  $Cold = Join-Path $TestRoot 'cold home'
  $Copy = Join-Path $TestRoot 'verified copy'
  $Utf8 = [Text.UTF8Encoding]::new($false)
  foreach ($Relative in @('config.yaml', '.env', 'state.db', 'state.db-wal', 'state.db-shm', 'profiles\工作\config.yaml', 'profiles\工作\state.db-wal', 'profiles\工作\sessions\conversation.jsonl', 'skills\custom\SKILL.md')) {
    Write-Fixture (Join-Path $Cold $Relative) ($Utf8.GetBytes("fixture bytes: $Relative`r`n"))
  }
  [IO.File]::SetAttributes((Join-Path $Cold '.env'), [IO.FileAttributes]::Hidden)
  [IO.Directory]::CreateDirectory((Join-Path $Cold 'profiles\empty')) | Out-Null
  Copy-Tree $Cold $Copy
  foreach ($File in @(Get-ChildItem -LiteralPath $Cold -Recurse -Force -File)) {
    $Relative = $File.FullName.Substring($Cold.Length).TrimStart('\')
    $Saved = Join-Path $Copy $Relative
    Assert-Condition ((Test-Path -LiteralPath $Saved) -and (Get-FileHash -LiteralPath $File.FullName).Hash -eq (Get-FileHash -LiteralPath $Saved).Hash) "cold copy preserves bytes: $Relative"
  }
  Assert-Condition (Test-Path -LiteralPath (Join-Path $Copy 'profiles\empty') -PathType Container) 'cold copy preserves empty profile directories'
  Assert-Condition ((Get-Item -LiteralPath (Join-Path $Copy '.env') -Force).Attributes -band [IO.FileAttributes]::Hidden) 'cold copy preserves hidden .env attribute'
  Write-Fixture (Join-Path $Copy 'post-upgrade-only.db') ([byte[]](1, 2, 3))
  Copy-Tree $Cold $Copy -Mirror
  Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $Copy 'post-upgrade-only.db'))) 'mirror restore removes post-snapshot state only within fixture'
  Write-Host "Passed $script:Passed isolated Windows upgrade function checks. No live Hermes upgrade was run."
} finally {
  if ($Lock) { $Lock.Dispose() }
  if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}

# Robocopy success codes can be nonzero; do not leak LASTEXITCODE to CI.
exit 0
