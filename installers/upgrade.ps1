#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [Parameter(Mandatory = $true, Position = 0)] [string] $InstallDir,
  [string] $SourceDir,
  [string] $HermesHome,
  [switch] $SupervisorStopped,
  [switch] $KeepStopped,
  [switch] $AllowSameVersion,
  [switch] $Recover,
  [ValidateRange(15, 600)] [int] $HealthTimeoutSeconds = 90
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ExitCode = 2
$script:Lock = $null
$script:Journal = $null
$script:Started = @()
$script:SavedEnvironment = @{}
$script:HadMutation = $false
$script:RuntimeTouched = $false
$script:HomeTouched = $false
$script:StoppedExisting = $false

function Full-Path([string] $Path) {
  if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).Path $Path }
  $Full = [IO.Path]::GetFullPath($Path)
  if ($Full.TrimEnd([char[]]'\/') -eq [IO.Path]::GetPathRoot($Full).TrimEnd([char[]]'\/')) { throw 'Volume/share roots are not valid upgrade targets.' }
  return $Full.TrimEnd([char[]]'\/')
}
function Test-Within([string] $Path, [string] $Root) {
  if (-not $Path) { return $false }
  $P = Full-Path $Path
  $R = Full-Path $Root
  return $P.Equals($R, [StringComparison]::OrdinalIgnoreCase) -or $P.StartsWith($R + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Assert-Separate([string] $Left, [string] $Right) {
  if ((Test-Within $Left $Right) -or (Test-Within $Right $Left)) {
    throw 'Source, installation and home directories must be separate, non-nested trees.'
  }
}
function Assert-NoLinks([string] $Path, [switch] $AllowMissing) {
  $Existing = $Path
  if ($AllowMissing) {
    while (-not (Test-Path -LiteralPath $Existing)) {
      $Parent = Split-Path -Parent $Existing
      if (-not $Parent -or $Parent -eq $Existing) { throw 'Cannot validate the restore destination ancestry.' }
      $Existing = $Parent
    }
  }
  $Item = Get-Item -LiteralPath $Existing -Force
  while ($Item) {
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse points are unsupported: $($Item.FullName)" }
    $Item = $Item.Parent
  }
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $Link = Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
  if ($Link) { throw "Resolve linked/external data before upgrading: $($Link.FullName)" }
}
function Set-ProcessEnv([string] $Name, [AllowNull()] [string] $Value) {
  if (-not $script:SavedEnvironment.ContainsKey($Name)) {
    $script:SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
  }
  [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}
function Assert-BundleIntegrity {
  $InventoryPath = Join-Path $script:Source 'upgrade-manifest.json'
  $Inventory = Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($Inventory.schema -ne 1 -or $Inventory.algorithm -ne 'sha256') { throw 'Unsupported bundle checksum inventory.' }
  $Entries = @($Inventory.files.PSObject.Properties)
  $Actual = @(Get-ChildItem -LiteralPath $script:Source -Recurse -Force -File | Where-Object { $_.FullName -ne $InventoryPath })
  if ($Entries.Count -eq 0 -or $Entries.Count -ne $Actual.Count) { throw 'Bundle inventory is incomplete. Extract a clean verified ZIP.' }
  $Seen = @{}
  foreach ($Entry in $Entries) {
    if ($Entry.Name -match '(^/|:|\\|(^|/)\.\.?(/|$)|//)' -or $Entry.Value -notmatch '^[a-f0-9]{64}$') { throw 'Unsafe checksum inventory entry.' }
    $Path = Full-Path (Join-Path $script:Source $Entry.Name)
    if (-not (Test-Within $Path $script:Source) -or $Seen.ContainsKey($Path)) { throw 'Checksum inventory escaped or duplicated a path.' }
    $Seen[$Path] = $true
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Entry.Value) { throw 'Bundle checksum mismatch. Re-extract the trusted release ZIP.' }
  }
}
function Invoke-Helper([string] $Python, [string[]] $Arguments) {
  $Output = @(& $Python $script:Helper @Arguments 2>$null)
  if ($LASTEXITCODE -ne 0) {
    $Message = 'Upgrade helper failed; no user configuration or credential contents are logged.'
    try { $Message = (($Output -join "`n") | ConvertFrom-Json).error } catch {}
    throw $Message
  }
  try { return (($Output -join "`n") | ConvertFrom-Json) } catch { throw 'Upgrade helper returned invalid JSON.' }
}
function Invoke-Checked([string] $File, [string[]] $Arguments, [string] $Label) {
  # Do not stream dependency/setup/migration stderr: third-party hooks may print credentials.
  & $File @Arguments *> $null
  if ($LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE)." }
}
function Write-Journal([string] $Phase) {
  $script:Journal.phase = $Phase
  $script:Journal.updatedUtc = [DateTime]::UtcNow.ToString('o')
  $Tmp = $script:JournalPath + '.tmp'
  $Bytes = [Text.UTF8Encoding]::new($false).GetBytes(($script:Journal | ConvertTo-Json -Depth 12))
  $Stream = [IO.File]::Open($Tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) } finally { $Stream.Dispose() }
  if (Test-Path -LiteralPath $script:JournalPath) {
    # PS5.1 coerces $null to an empty string for .NET string parameters.
    # File.Replace requires a real null (no backup filename), not an empty path.
    [IO.File]::Replace($Tmp, $script:JournalPath, [NullString]::Value)
  } else { [IO.File]::Move($Tmp, $script:JournalPath) }
}
function New-PrivateDirectory([string] $Path) {
  $Security = New-Object System.Security.AccessControl.DirectorySecurity
  $Security.SetAccessRuleProtection($true, $false)
  $Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  foreach ($Owner in @($Sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $Rule = [Security.AccessControl.FileSystemAccessRule]::new($Owner, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $Security.AddAccessRule($Rule)
  }
  [IO.Directory]::CreateDirectory($Path, $Security) | Out-Null
}
function Copy-Tree([string] $From, [string] $To, [switch] $Mirror) {
  $Options = @('/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
  if ($Mirror) { $Options += '/MIR' }
  & robocopy.exe $From $To @Options *> $null
  if ($LASTEXITCODE -ge 8) { throw 'A complete filesystem copy failed; the transaction is not committed.' }
}
function Get-TreeSize([string] $Path) {
  $Size = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum
  if ($null -eq $Size) { return [int64]0 }
  return [int64]$Size
}
function Assert-FreeSpace([string] $Path, [int64] $Required) {
  $Root = [IO.Path]::GetPathRoot($Path)
  if ($Root.StartsWith('\\')) { throw 'UNC/network installations are unsupported for transactional upgrades.' }
  $Drive = [IO.DriveInfo]::new($Root)
  if ($Drive.AvailableFreeSpace -lt $Required) { throw "Insufficient free space on $Root for retained backups and rebuilding." }
}
function Quote-Argument([string] $Value) {
  # CommandLineToArgvW / MS CRT quoting, including trailing backslashes.
  return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Split-Command([string] $Line) {
  $Count = 0
  $Pointer = [HermesUpgrade.Native]::CommandLineToArgvW($Line, [ref]$Count)
  if ($Pointer -eq [IntPtr]::Zero) { throw 'Cannot parse a process command line.' }
  try {
    $Args = @()
    for ($I = 0; $I -lt $Count; $I++) { $Args += [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($Pointer, $I * [IntPtr]::Size)) }
    return $Args
  } finally { [HermesUpgrade.Native]::LocalFree($Pointer) | Out-Null }
}
function Get-Inventory {
  $Items = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  foreach ($Item in $Items) {
    if ($Item.Name -match '^(pythonw?|hermes|node|uv)\.exe$' -and (-not $Item.ExecutablePath -or -not $Item.CommandLine)) { throw 'Cannot inspect the owner of a runtime-like process. Rerun as the original user with sufficient rights.' }
  }
  return $Items
}
function Get-OwnedProcesses([object[]] $Inventory) {
  $Owned = @{}
  foreach ($P in $Inventory) {
    if ($P.ProcessId -ne $PID -and $P.ExecutablePath -and (Test-Within $P.ExecutablePath $script:Runtime)) { $Owned[[int]$P.ProcessId] = $P }
  }
  do {
    $Changed = $false
    foreach ($P in $Inventory) {
      if ($P.ProcessId -ne $PID -and -not $Owned.ContainsKey([int]$P.ProcessId) -and $Owned.ContainsKey([int]$P.ParentProcessId)) {
        $Owned[[int]$P.ProcessId] = $P
        $Changed = $true
      }
    }
  } while ($Changed)
  return @($Owned.Values)
}
function Test-CommandOwnsPath([string] $Line, [string] $Root) {
  if (-not $Line) { return $false }
  foreach ($Token in (Split-Command $Line)) {
    $Candidate = $Token
    if ($Token -match '^--[\w-]+=(.+)$') { $Candidate = $Matches[1] }
    if ([IO.Path]::IsPathRooted($Candidate)) {
      try { if (Test-Within $Candidate $Root) { return $true } } catch {}
    }
  }
  return $false
}
function Assert-NoSupervisors([object[]] $Inventory, [object[]] $Owned) {
  $Ids = @($Owned | ForEach-Object { [int]$_.ProcessId })
  $Ancestors = @{}
  $AncestorId = $PID
  while ($AncestorId -and -not $Ancestors.ContainsKey([int]$AncestorId)) {
    $Ancestors[[int]$AncestorId] = $true
    $Ancestor = $Inventory | Where-Object { $_.ProcessId -eq $AncestorId } | Select-Object -First 1
    if (-not $Ancestor) { break }
    $AncestorId = $Ancestor.ParentProcessId
  }
  foreach ($Service in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
    if ((Test-CommandOwnsPath $Service.PathName $script:InstallRoot) -or ($Ids -contains [int]$Service.ProcessId)) {
      if ($Service.State -ne 'Stopped' -or $Service.StartMode -ne 'Disabled') { throw 'A service owns this installation. Stop it and disable automatic restart before upgrading.' }
      if (-not $SupervisorStopped) { throw 'A disabled service was detected; confirm its owner is stopped with -SupervisorStopped.' }
    }
  }
  foreach ($Task in @(Get-ScheduledTask -ErrorAction Stop)) {
    foreach ($Action in $Task.Actions) {
      $Command = (Quote-Argument ([string]$Action.Execute)) + ' ' + ([string]$Action.Arguments)
      if ((Test-CommandOwnsPath $Command $script:InstallRoot) -or (Test-CommandOwnsPath $Command $script:Home)) {
        if ([string]$Task.State -ne 'Disabled') { throw 'A scheduled task owns this installation. Disable/stop it before upgrading.' }
        if (-not $SupervisorStopped) { throw 'A disabled scheduled task was detected; use -SupervisorStopped after checking its owner.' }
      }
    }
  }
  foreach ($P in $Inventory) {
    if ($P.ProcessId -eq $PID -or $Ids -contains [int]$P.ProcessId) { continue }
    # Only this invocation's actual ancestors are exempt. Unrelated shell supervisors
    # can respawn Hermes and cannot be treated as harmless just by executable name.
    if ($Ancestors.ContainsKey([int]$P.ProcessId)) { continue }
    if ($P.Name -match '^(cmd|powershell|pwsh)\.exe$' -and (Test-CommandOwnsPath $P.CommandLine $script:InstallRoot)) { throw 'Another shell references this installation; close its launcher/supervisor first.' }
    if ((Test-CommandOwnsPath $P.CommandLine $script:Runtime) -or (Test-CommandOwnsPath $P.CommandLine $script:Home)) {
      throw "External process $($P.ProcessId) references this runtime/home. Stop its owning client first."
    }
  }
  foreach ($P in $Owned) {
    if ($Ids -contains [int]$P.ParentProcessId) { continue }
    $Parent = $Inventory | Where-Object { $_.ProcessId -eq $P.ParentProcessId } | Select-Object -First 1
    if ($Parent -and $Parent.Name -notmatch '^(cmd|powershell|pwsh|explorer|conhost|OpenConsole)\.exe$') {
      throw "Process $($P.ProcessId) has an external supervisor. Close that client/supervisor before upgrading."
    }
  }
}
function Get-RestartSpecs([object[]] $Owned) {
  $Ids = @($Owned | ForEach-Object { [int]$_.ProcessId })
  $Specs = @()
  foreach ($P in $Owned) {
    if ($Ids -contains [int]$P.ParentProcessId) { continue }
    $Tokens = @(Split-Command $P.CommandLine)
    if ($Tokens.Count -lt 2) { throw 'Unrecognized runtime process; stop it manually before upgrading.' }
    $Entry = [string]$Tokens[0]
    $AllowedEntries = @((Join-Path $script:Runtime 'venv\Scripts\python.exe'), (Join-Path $script:Runtime 'venv\Scripts\pythonw.exe'), (Join-Path $script:Runtime 'venv\Scripts\hermes.exe'))
    if (-not [IO.Path]::IsPathRooted($Entry) -or (Full-Path $Entry) -notin $AllowedEntries) { throw 'Original runtime invocation is not a recognized final-path venv entrypoint.' }
    $Args = @($Tokens | Select-Object -Skip 1)
    if ([IO.Path]::GetFileName($Entry) -in @('python.exe', 'pythonw.exe')) {
      if ($Args.Count -lt 3 -or $Args[0] -ne '-m' -or $Args[1] -ne 'hermes_cli.main') { throw 'Only the explicit Hermes Python module launcher can be restarted automatically.' }
      $Args = @($Args | Select-Object -Skip 2)
    }
    if ($Args.Count -eq 0) { throw 'Interactive Hermes is still open. Close it before upgrading.' }
    $Kind = $Args[0]
    if ($Kind -eq 'gateway') {
      if ($Args.Count -lt 2 -or $Args[1] -ne 'run') { throw 'Unsupported gateway launch; stop its owner first.' }
      foreach ($Arg in @($Args | Select-Object -Skip 2)) { if ($Arg -notin @('-v', '-vv', '-q', '--quiet')) { throw 'Custom gateway arguments need a reviewed restart adapter.' } }
    } elseif ($Kind -in @('dashboard', 'serve')) {
      for ($I = 1; $I -lt $Args.Count; $I++) {
        if ($Args[$I] -in @('--no-open', '--skip-build', '--tui')) { continue }
        if ($Args[$I] -eq '--port' -and $I + 1 -lt $Args.Count -and $Args[$I + 1] -match '^\d+$' -and [int]$Args[$I + 1] -ge 1 -and [int]$Args[$I + 1] -le 65535) { $I++; continue }
        if ($Args[$I] -eq '--host' -and $I + 1 -lt $Args.Count -and $Args[$I + 1] -in @('127.0.0.1', 'localhost', '::1')) { $I++; continue }
        throw 'Custom dashboard/profile arguments need a reviewed restart adapter.'
      }
    } else { throw 'Other Hermes activity is still running. Close all sessions/workers before upgrading.' }
    if ([IO.Path]::GetFileName([string]$P.ExecutablePath) -notin @('python.exe', 'pythonw.exe', 'hermes.exe')) { throw 'Unsupported runtime entry executable; close its owner first.' }
    $Specs += [pscustomobject]@{ file = $Entry; args = @($Tokens | Select-Object -Skip 1); kind = $Kind }
  }
  if (@($Specs | Where-Object { $_.kind -eq 'gateway' }).Count -gt 1 -or @($Specs | Where-Object { $_.kind -in @('dashboard', 'serve') }).Count -gt 1) {
    throw 'Multiple gateways/backends require topology review; no multiplex migration is performed.'
  }
  return $Specs
}
function Assert-RestartSpec([object] $Spec) {
  if (-not $Spec.file -or -not [IO.Path]::IsPathRooted($Spec.file) -or -not (Test-Within $Spec.file $script:Runtime) -or [IO.Path]::GetFileName($Spec.file) -notin @('python.exe', 'pythonw.exe', 'hermes.exe')) { throw 'Journal restart executable is outside the original runtime.' }
  $Tokens = @($Spec.file) + @($Spec.args)
  $Line = (@($Tokens | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
  $Fake = [pscustomobject]@{ ProcessId = -1; ParentProcessId = -2; CommandLine = $Line; ExecutablePath = $Spec.file }
  $Valid = @(Get-RestartSpecs @($Fake))
  if ($Valid.Count -ne 1 -or $Valid[0].kind -ne $Spec.kind) { throw 'Journal restart specification is invalid.' }
}
function Stop-Owned {
  # Refresh exact executable ownership each pass; never kill all python.exe processes.
  $Owned = @(Get-OwnedProcesses (Get-Inventory))
  foreach ($P in $Owned) {
    $Now = Get-CimInstance Win32_Process -Filter "ProcessId=$($P.ProcessId)" -ErrorAction Stop
    if ($Now -and $Now.CreationDate -eq $P.CreationDate) { Stop-Process -Id $P.ProcessId -Force -ErrorAction Stop }
  }
  $Until = [DateTime]::UtcNow.AddSeconds(15)
  do {
    if (@(Get-OwnedProcesses (Get-Inventory)).Count -eq 0) { return }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $Until)
  throw 'Runtime owners are still running; no cold backup can be taken.'
}
function Assert-Quiescent {
  if (@(Get-OwnedProcesses (Get-Inventory)).Count) { throw 'A supervisor restarted Hermes during maintenance.' }
}
function Start-Spec([object] $Spec) {
  $Info = New-Object Diagnostics.ProcessStartInfo
  $Info.FileName = $Spec.file
  $Info.Arguments = (@($Spec.args | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
  $Info.WorkingDirectory = $script:InstallRoot
  $Info.UseShellExecute = $false
  $Info.CreateNoWindow = $true
  # Inherit the resolved original shim environment; do not serialize secrets to disk.
  $P = [Diagnostics.Process]::Start($Info)
  $script:Started += $P.Id
  return $P
}
function Restore-Transaction {
  Set-ProcessEnv 'HERMES_HOME' $script:Home
  Set-ProcessEnv 'HERMES_OFFLINE_HOME' $script:InstallRoot
  Set-ProcessEnv 'HERMES_PYTHON' (Join-Path $script:Runtime 'venv\Scripts\python.exe')
  Set-ProcessEnv 'PYTHONHOME' $null
  Set-ProcessEnv 'PYTHONPATH' $null
  if ($script:Journal.homeBackupComplete) {
    $RecoveryPython = Join-Path $script:Source 'runtime\python\python.exe'
    if (-not (Test-Path -LiteralPath $RecoveryPython)) { $RecoveryPython = Join-Path $script:Source 'runtime\python\bin\python.exe' }
    & $RecoveryPython -c 'import encodings' *> $null
    if ($LASTEXITCODE -ne 0) { Set-ProcessEnv 'PYTHONHOME' (Split-Path -Parent $RecoveryPython) }
    try { Invoke-Helper $RecoveryPython @('snapshot-check', '--backup', $script:Journal.backup) | Out-Null } finally { Set-ProcessEnv 'PYTHONHOME' $null }
  }
  Write-Journal 'rolling-back'
  Stop-Owned
  Assert-Quiescent
  if ($script:Journal.runtimeMoved -and (Test-Path -LiteralPath (Join-Path $script:Journal.backup 'runtime'))) {
    # Preserve failed files for diagnosis. Restore the old venv at its original fixed path.
    if (Test-Path -LiteralPath $script:Runtime) {
      $Failed = Join-Path $script:Journal.backup ('failed-runtime-' + [Guid]::NewGuid().ToString('N'))
      Move-Item -LiteralPath $script:Runtime -Destination $Failed
    }
    Copy-Tree (Join-Path $script:Journal.backup 'runtime') $script:Runtime -Mirror
  }
  if ($script:Journal.homeBackupComplete) {
    if (-not (Test-Path -LiteralPath $script:Home)) {
      $HomeSecurity = New-Object Security.AccessControl.DirectorySecurity
      $HomeSecurity.SetSecurityDescriptorSddlForm($script:Journal.homeSddl)
      [IO.Directory]::CreateDirectory($script:Home, $HomeSecurity) | Out-Null
    }
    Copy-Tree (Join-Path $script:Journal.backup 'home') $script:Home -Mirror
    Copy-Tree (Join-Path $script:Journal.backup 'bin') (Join-Path $script:InstallRoot 'bin') -Mirror
  }
  $RestoredPython = Join-Path $script:Runtime 'venv\Scripts\python.exe'
  if (-not (Test-Path -LiteralPath $RestoredPython)) { throw 'Restored runtime is incomplete.' }
  if ($script:Journal.homeBackupComplete) {
    Invoke-Helper $RestoredPython @('compare', '--home', $script:Home, '--backup', (Join-Path $script:Journal.backup 'home')) | Out-Null
    Invoke-Helper $RestoredPython @('compare', '--home', $script:Runtime, '--backup', (Join-Path $script:Journal.backup 'runtime')) | Out-Null
  }
  Write-Journal 'restored'
  # Original shims and registry/User environment were never modified. Restart only
  # recognized original launch commands, never invent a supervisor/service topology.
  if (-not $KeepStopped) {
    foreach ($Spec in @($script:Journal.restart)) { Start-Spec $Spec | Out-Null }
  }
  Write-Journal 'rolled-back'
}

try {
  if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Run 64-bit Windows PowerShell 5.1 or newer on Windows.' }
  $script:InstallRoot = Full-Path $InstallDir
  $script:Runtime = Join-Path $script:InstallRoot 'runtime'
  $OldPython = Join-Path $script:Runtime 'venv\Scripts\python.exe'
  $OldShim = Join-Path $script:InstallRoot 'bin\hermes.cmd'
  if (-not $SourceDir) {
    $SourceDir = $PSScriptRoot
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'manifest.json'))) { $SourceDir = Split-Path -Parent $PSScriptRoot }
  }
  $script:Source = Full-Path $SourceDir
  Assert-Separate $script:Source $script:InstallRoot
  Assert-NoLinks $script:Source
  Assert-NoLinks $script:InstallRoot
  $script:Helper = Join-Path $script:Source 'scripts\upgrade_support.py'
  $script:JournalPath = Join-Path $script:InstallRoot '.hermes-upgrade.json'
  Assert-BundleIntegrity
  $RecoveryPrior = $null
  if ($Recover) {
    if (-not (Test-Path -LiteralPath $script:JournalPath)) { throw 'No interrupted transaction journal exists.' }
    $RecoveryPrior = Get-Content -LiteralPath $script:JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($RecoveryPrior.schema -ne 1 -or $RecoveryPrior.actorSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $RecoveryPrior.install -ne $script:InstallRoot -or (Split-Path -Parent $RecoveryPrior.backup) -ne (Join-Path $script:InstallRoot '.upgrade-backups') -or $RecoveryPrior.runtimeMoved -isnot [bool] -or $RecoveryPrior.homeBackupComplete -isnot [bool] -or ($RecoveryPrior.runtimeMoved -and -not $RecoveryPrior.homeBackupComplete)) { throw 'Invalid recovery journal identity, paths or flags.' }
    Assert-NoLinks $RecoveryPrior.backup
    if ($RecoveryPrior.homeBackupComplete) { $OldShim = Join-Path $RecoveryPrior.backup 'bin\hermes.cmd' }
  }
  if (-not (Test-Path -LiteralPath $OldShim)) { throw 'Original bin\hermes.cmd is missing from the installation and verified recovery point.' }

  # Add-Type on Windows PowerShell compiles in TEMP. Keep that outside user data,
  # including when the caller inherited the old shim's home/cache TEMP override.
  $CompileTemp = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'
  $BeforeTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
  $BeforeTmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
  Set-ProcessEnv 'TEMP' $CompileTemp
  Set-ProcessEnv 'TMP' $CompileTemp
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace HermesUpgrade { public static class Native {
 [DllImport("shell32.dll", SetLastError=true)] public static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cmd, out int argc);
 [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr ptr);
} }
'@
  Set-ProcessEnv 'TEMP' $BeforeTemp
  Set-ProcessEnv 'TMP' $BeforeTmp

  # Read only the known generated shim's assignments; never execute a hand-edited script.
  $Shim = Get-Content -LiteralPath $OldShim -Raw -Encoding UTF8
  foreach ($Match in [regex]::Matches($Shim, '(?im)reg query HKU\\(S-1-[0-9-]+)\\Environment')) {
    if ($Match.Groups[1].Value -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Run upgrade as the original installation user; another user owns the launcher environment.' }
  }
  $AssignedHome = @([regex]::Matches($Shim, '(?im)^set "HERMES_HOME=([^"\r\n]+)"\s*$') | ForEach-Object { $_.Groups[1].Value })
  if ($AssignedHome.Count -ne 1) { throw 'Cannot resolve the original HERMES_HOME from its shim; provide a supported original launcher.' }
  if ($AssignedHome[0] -match '[%!]') { throw 'Variable-expanded HERMES_HOME needs a reviewed launcher adapter.' }
  $script:Home = Full-Path $AssignedHome[0]
  if ($HermesHome -and -not (Full-Path $HermesHome).Equals($script:Home, [StringComparison]::OrdinalIgnoreCase)) { throw '-HermesHome differs from the actual old shim. Resolve the launch configuration first.' }
  Assert-Separate $script:Home $script:InstallRoot
  Assert-Separate $script:Home $script:Source
  if (-not $Recover -and -not (Test-Path -LiteralPath (Join-Path $script:Home 'config.yaml'))) { throw 'Resolved original home is missing config.yaml.' }
  Assert-NoLinks $script:Home -AllowMissing:$Recover
  if ($RecoveryPrior -and $RecoveryPrior.home -ne $script:Home) { throw 'Journal home differs from the original backup launcher.' }
  $KnownEnvironment = @('PYTHONUTF8', 'PYTHONIOENCODING', 'HERMES_HOME', 'HERMES_OFFLINE_HOME', 'HERMES_PYTHON', 'HERMES_BUNDLED_SKILLS', 'HERMES_OPTIONAL_SKILLS', 'HERMES_OPTIONAL_MCPS', 'HERMES_BUNDLED_LOCALES', 'HERMES_BUNDLED_PLUGINS', 'HERMES_WEB_DIST', 'HERMES_TUI_DIR', 'HERMES_DESKTOP_MANAGED', 'PIP_INDEX_URL', 'UV_DEFAULT_INDEX', 'HF_ENDPOINT', 'PLAYWRIGHT_DOWNLOAD_HOST', 'npm_config_registry', 'HF_HOME', 'HUGGINGFACE_HUB_CACHE', 'TORCH_HOME', 'TIKTOKEN_CACHE_DIR', 'MPLCONFIGDIR', 'NLTK_DATA', 'PLAYWRIGHT_BROWSERS_PATH', 'TEMP', 'TMP')
  foreach ($Line in ($Shim -split '\r?\n')) {
    if ($Line -match '^set "([A-Za-z_][A-Za-z0-9_]*)=([^"\r\n]*)"\s*$') {
      if ($Matches[1] -notin $KnownEnvironment) { throw 'Unknown shim environment assignment; use a reviewed environment adapter.' }
      if ($Matches[2] -match '[%!]') { throw 'A variable-expanded shim assignment requires a reviewed environment adapter.' }
      Set-ProcessEnv $Matches[1] $Matches[2]
    } elseif ($Line -match '^if not defined ([A-Za-z_][A-Za-z0-9_]*) set "\1=([^"\r\n]*)"\s*$') {
      if ($Matches[1] -notin $KnownEnvironment -or $Matches[2] -match '[%!]') { throw 'Unsupported shim default environment assignment.' }
      if (-not [Environment]::GetEnvironmentVariable($Matches[1], 'Process')) { Set-ProcessEnv $Matches[1] $Matches[2] }
    }
  }
  foreach ($Name in @('ZHANCLAW_BASE_URL', 'ZHANCLAW_API_KEY')) {
    if (-not [Environment]::GetEnvironmentVariable($Name, 'Process')) { Set-ProcessEnv $Name ([Environment]::GetEnvironmentVariable($Name, 'User')) }
  }
  Set-ProcessEnv 'HERMES_HOME' $script:Home
  Set-ProcessEnv 'HERMES_OFFLINE_HOME' $script:InstallRoot
  Set-ProcessEnv 'PYTHONHOME' $null
  Set-ProcessEnv 'PYTHONPATH' $null
  Set-ProcessEnv 'PYTHONDONTWRITEBYTECODE' '1'
  Set-ProcessEnv 'PYTHONUTF8' '1'
  Set-ProcessEnv 'PYTHONIOENCODING' 'utf-8'
  Set-ProcessEnv 'HERMES_NO_START_DASHBOARD' '1'
  Set-ProcessEnv 'PIP_NO_INDEX' '1'
  Set-ProcessEnv 'UV_OFFLINE' '1'
  Set-ProcessEnv 'HF_HUB_OFFLINE' '1'
  Set-ProcessEnv 'PIP_CONFIG_FILE' 'NUL'
  Set-ProcessEnv 'PIP_DISABLE_PIP_VERSION_CHECK' '1'


  $Inventory = Get-Inventory
  $Owned = @(Get-OwnedProcesses $Inventory)
  Assert-NoSupervisors $Inventory $Owned
  $Restart = @(Get-RestartSpecs $Owned)

  if (Test-Path -LiteralPath $script:JournalPath) {
    $Prior = Get-Content -LiteralPath $script:JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Prior.phase -notin @('committed', 'rolled-back', 'aborted')) {
      if (-not $Recover) { throw 'An interrupted transaction exists. Inspect its backup and rerun with -Recover.' }
      if ($Prior.schema -ne 1 -or $Prior.actorSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $Prior.install -ne $script:InstallRoot -or $Prior.home -ne $script:Home -or -not (Test-Within $Prior.backup (Join-Path $script:InstallRoot '.upgrade-backups'))) { throw 'Recovery journal paths/user identity are invalid.' }
      if ((Split-Path -Parent $Prior.backup) -ne (Join-Path $script:InstallRoot '.upgrade-backups') -or $Prior.runtimeMoved -isnot [bool] -or $Prior.homeBackupComplete -isnot [bool] -or ($Prior.runtimeMoved -and -not $Prior.homeBackupComplete)) { throw 'Recovery snapshot flags or transaction directory are invalid.' }
      Assert-NoLinks $Prior.backup
      foreach ($Spec in @($Prior.restart)) { Assert-RestartSpec $Spec }

      if (-not $PSCmdlet.ShouldProcess($script:InstallRoot, 'Restore interrupted runtime + full home snapshot')) { $script:ExitCode = 0; return }
      $script:Lock = [IO.File]::Open((Join-Path $script:InstallRoot '.hermes-upgrade.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
      # The recovery plan is stale if any transaction changed while we awaited the lock.
      $LockedRecovery = Get-Content -LiteralPath $script:JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if (($LockedRecovery | ConvertTo-Json -Depth 12 -Compress) -cne ($Prior | ConvertTo-Json -Depth 12 -Compress) -or $LockedRecovery.phase -in @('committed', 'rolled-back', 'aborted')) { throw 'Recovery journal changed while acquiring the lock; inspect the current transaction.' }
      $script:Journal = $LockedRecovery
      Restore-Transaction
      Write-Host "Previous runtime and data restored. Backup retained: $($Prior.backup)"
      $script:ExitCode = 0
      return
    }
  }
  if ($Recover) { throw 'No interrupted upgrade needs recovery.' }
  if (-not (Test-Path -LiteralPath $OldPython)) { throw 'Original Python runtime is missing; use -Recover if an upgrade was interrupted.' }
  $Inspect = Invoke-Helper $OldPython @('inspect', '--home', $script:Home)
  $BundleArgs = @('bundle', '--bundle', $script:Source, '--version', $Inspect.version)
  if ($AllowSameVersion) { $BundleArgs += '--allow-same' }
  $Bundle = Invoke-Helper $OldPython $BundleArgs
  $HomeSize = Get-TreeSize $script:Home
  $RuntimeSize = Get-TreeSize $script:Runtime
  $SourceSize = Get-TreeSize $script:Source
  Assert-FreeSpace $script:InstallRoot ($HomeSize + $RuntimeSize + 3 * $SourceSize + 1GB)
  Assert-FreeSpace $script:Home ($HomeSize + 512MB)
  Write-Host "Hermes $($Inspect.version) -> $($Bundle.version)"
  Write-Host "Install: $script:InstallRoot"
  Write-Host "Preserved home: $script:Home ($(@($Inspect.homes).Count) profile(s))"
  Write-Host "Plan: stop exact runtime owners, cold backup, rebuild offline at final path, official migration, authenticated readiness, retain rollback backup."
  if (-not $PSCmdlet.ShouldProcess($script:InstallRoot, 'Upgrade Hermes with a paired runtime/data rollback point')) { $script:ExitCode = 0; return }

  # The exclusive handle, not the existence of a stale lock file, owns the lock.
  $script:Lock = [IO.File]::Open((Join-Path $script:InstallRoot '.hermes-upgrade.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  # Close the plan-to-lock race before stopping anything or creating a new journal.
  if (Test-Path -LiteralPath $script:JournalPath) {
    $LockedPrior = Get-Content -LiteralPath $script:JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($LockedPrior.phase -notin @('committed', 'rolled-back', 'aborted')) { throw 'Another transaction is unresolved; use -Recover.' }
  }
  $Inspect = Invoke-Helper $OldPython @('inspect', '--home', $script:Home)
  $BundleArgs = @('bundle', '--bundle', $script:Source, '--version', $Inspect.version)
  if ($AllowSameVersion) { $BundleArgs += '--allow-same' }
  $Bundle = Invoke-Helper $OldPython $BundleArgs
  $Inventory = Get-Inventory
  $Owned = @(Get-OwnedProcesses $Inventory)
  Assert-NoSupervisors $Inventory $Owned
  $Restart = @(Get-RestartSpecs $Owned)
  $BackupParent = Join-Path $script:InstallRoot '.upgrade-backups'
  if (-not (Test-Path -LiteralPath $BackupParent)) { New-PrivateDirectory $BackupParent }
  $Backup = Join-Path $BackupParent ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N'))
  New-PrivateDirectory $Backup
  $script:Journal = [ordered]@{ schema = 1; phase = 'prepared'; updatedUtc = ''; install = $script:InstallRoot; home = $script:Home; backup = $Backup; fromVersion = $Inspect.version; toVersion = $Bundle.version; actorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; runtimeMoved = $false; homeBackupComplete = $false; homeSddl = ''; restart = @($Restart) }
  Write-Journal 'prepared'
  $script:StoppedExisting = $true
  Write-Journal 'stopping'
  Stop-Owned
  Start-Sleep -Seconds 2
  Assert-Quiescent
  Assert-NoSupervisors (Get-Inventory) @()
  $script:Journal.homeSddl = (Get-Acl -LiteralPath $script:Home).Sddl
  Write-Journal 'backing-up'
  Copy-Tree $script:Home (Join-Path $Backup 'home')
  Copy-Tree (Join-Path $script:InstallRoot 'bin') (Join-Path $Backup 'bin')
  Copy-Tree $script:Runtime (Join-Path $Backup 'runtime')
  Invoke-Helper $OldPython @('compare', '--home', $script:Home, '--backup', (Join-Path $Backup 'home')) | Out-Null
  Invoke-Helper $OldPython @('compare', '--home', $script:Runtime, '--backup', (Join-Path $Backup 'runtime')) | Out-Null
  Invoke-Helper $OldPython @('compare', '--home', (Join-Path $script:InstallRoot 'bin'), '--backup', (Join-Path $Backup 'bin')) | Out-Null
  Assert-Quiescent
  Invoke-Helper $OldPython @('snapshot', '--backup', $Backup) | Out-Null
  $script:Journal.homeBackupComplete = $true
  Write-Journal 'backed-up'
  # Even read-oriented upstream imports run only after the restore point is durable.
  $OriginalEndpoint = Invoke-Helper $OldPython @('endpoint', '--home', $script:Home)
  Invoke-Helper $OldPython @('compare', '--home', $script:Home, '--backup', (Join-Path $Backup 'home')) | Out-Null
  # Intent is flushed BEFORE replacement; the verified private snapshot is complete.
  $script:Journal.runtimeMoved = $true
  Write-Journal 'replacing-runtime'
  Remove-Item -LiteralPath $script:Runtime -Recurse -Force
  $script:RuntimeTouched = $true
  New-Item -ItemType Directory -Path $script:Runtime | Out-Null
  foreach ($Pair in @(@('wheelhouse', 'wheelhouse'), @('runtime', 'bundle-runtime'), @('hermes-agent', 'hermes-agent'), @('hermes-resources', 'hermes-resources'), @('templates', 'templates'))) {
    Copy-Tree (Join-Path $script:Source $Pair[0]) (Join-Path $script:Runtime $Pair[1])
  }
  # Keep original launcher behavior and original bin/shims/environment bindings.
  Copy-Tree (Join-Path $Backup 'runtime\commands') (Join-Path $script:Runtime 'commands')
  $Python = Join-Path $script:Runtime 'bundle-runtime\python\python.exe'
  if (-not (Test-Path -LiteralPath $Python)) { $Python = Join-Path $script:Runtime 'bundle-runtime\python\bin\python.exe' }
  $Venv = Join-Path $script:Runtime 'venv'
  $VenvPython = Join-Path $Venv 'Scripts\python.exe'
  Write-Journal 'building-runtime'
  & $Python -c 'import encodings, ensurepip, venv' *> $null
  if ($LASTEXITCODE -ne 0) { Set-ProcessEnv 'PYTHONHOME' (Split-Path -Parent $Python) }
  Invoke-Checked $Python @('-m', 'venv', '--without-pip', $Venv) 'venv creation at final path'
  Invoke-Checked $VenvPython @('-m', 'ensurepip', '--upgrade', '--default-pip') 'ensurepip'
  Set-ProcessEnv 'PYTHONHOME' $null
  $Wheelhouse = Join-Path $script:Runtime 'wheelhouse'
  Invoke-Checked $VenvPython @('-m', 'pip', 'install', '--only-binary=:all:', '--no-index', '--find-links', $Wheelhouse, '-r', (Join-Path $Wheelhouse 'requirements.txt')) 'Offline dependency installation'
  $SourceTree = Join-Path $script:Runtime 'hermes-agent'
  $Editable = (Get-Content -LiteralPath (Join-Path $Wheelhouse 'hermes-editable-requirement.txt') -Raw).Trim()
  Push-Location $SourceTree
  try { Invoke-Checked $VenvPython @('-m', 'pip', 'install', '--only-binary=:all:', '--no-index', '--find-links', $Wheelhouse, '--no-build-isolation', '-e', $Editable) 'Offline editable source installation' } finally { Pop-Location }
  Invoke-Checked $VenvPython @('-m', 'pip', 'check') 'Dependency consistency check'
  Set-ProcessEnv 'HERMES_PYTHON' $VenvPython
  Invoke-Helper $VenvPython @('verify', '--source', $SourceTree, '--version', $Bundle.version, '--home', $script:Home) | Out-Null
  Assert-Quiescent
  Write-Journal 'migrating-home'
  foreach ($Profile in @($Inspect.homes)) {
    Set-ProcessEnv 'HERMES_HOME' $Profile
    $Relative = $Profile.Substring($script:Home.Length).TrimStart('\')
    $SavedProfile = Join-Path $Backup 'home'
    if ($Relative) { $SavedProfile = Join-Path $SavedProfile $Relative }
    Invoke-Helper $VenvPython @('migrate', '--home', $Profile, '--backup', $SavedProfile) | Out-Null
    Invoke-Helper $VenvPython @('sync-skills', '--home', $Profile) | Out-Null
  }
  Set-ProcessEnv 'HERMES_HOME' $script:Home
  $Endpoint = Invoke-Helper $VenvPython @('endpoint', '--home', $script:Home)
  if ($Endpoint.url -ne $OriginalEndpoint.url -or $Endpoint.auth_fingerprint -ne $OriginalEndpoint.auth_fingerprint) { throw 'Migration changed the effective API endpoint/authentication identity.' }
  if (@(Get-NetTCPConnection -State Listen -LocalPort $Endpoint.port -ErrorAction SilentlyContinue).Count) { throw 'The preserved API port is occupied by another owner.' }
  Write-Journal 'validating'
  $Gateway = [pscustomobject]@{ file = $VenvPython; args = @('-m', 'hermes_cli.main', 'gateway', 'run'); kind = 'gateway' }
  Start-Spec $Gateway | Out-Null
  $Health = Invoke-Helper $VenvPython @('health', '--home', $script:Home, '--version', $Bundle.version, '--timeout', [string]$HealthTimeoutSeconds)
  $HealthProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($Health.pid)" -ErrorAction Stop
  if (-not $HealthProcess -or -not (Test-Within $HealthProcess.ExecutablePath $script:Runtime)) { throw 'Health response did not come from this runtime.' }
  foreach ($Profile in @($Inspect.homes)) {
    $Relative = $Profile.Substring($script:Home.Length).TrimStart('\')
    $SavedProfile = Join-Path $Backup 'home'
    if ($Relative) { $SavedProfile = Join-Path $SavedProfile $Relative }
    Invoke-Helper $VenvPython @('preserved', '--home', $Profile, '--backup', $SavedProfile) | Out-Null
  }
  # Stop the test gateway before restoring the caller's original launch mode.
  Stop-Owned
  Assert-Quiescent
  if (-not $KeepStopped) {
    foreach ($Spec in @($Restart)) { Start-Spec $Spec | Out-Null }
    if (@($Restart).Count) {
      $Health = Invoke-Helper $VenvPython @('health', '--home', $script:Home, '--version', $Bundle.version, '--timeout', [string]$HealthTimeoutSeconds)
      $HealthProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($Health.pid)" -ErrorAction Stop
      if (-not $HealthProcess -or -not (Test-Within $HealthProcess.ExecutablePath $script:Runtime)) { throw 'Restart health came from another runtime.' }
      foreach ($Spec in @($Restart | Where-Object { $_.kind -in @('dashboard', 'serve') })) {
        $WebPort = 9119
        for ($I = 0; $I -lt $Spec.args.Count - 1; $I++) { if ($Spec.args[$I] -eq '--port') { $WebPort = [int]$Spec.args[$I + 1] } }
        $Listeners = @(Get-NetTCPConnection -State Listen -LocalPort $WebPort -ErrorAction Stop)
        $LiveIds = @(Get-OwnedProcesses (Get-Inventory) | ForEach-Object { [int]$_.ProcessId })
        if (-not @($Listeners | Where-Object { $LiveIds -contains [int]$_.OwningProcess }).Count) { throw 'The original dashboard/backend port was not restored by this runtime.' }
      }

    }
  }
  foreach ($Profile in @($Inspect.homes)) {
    $Relative = $Profile.Substring($script:Home.Length).TrimStart('\')
    $SavedProfile = Join-Path $Backup 'home'
    if ($Relative) { $SavedProfile = Join-Path $SavedProfile $Relative }
    Invoke-Helper $VenvPython @('preserved', '--home', $Profile, '--backup', $SavedProfile) | Out-Null
  }
  Write-Journal 'committed'
  Copy-Item -LiteralPath $script:JournalPath -Destination (Join-Path $Backup 'transaction.json')
  Write-Host "Upgrade verified. Backup retained: $Backup"
  if ($KeepStopped -or @($Restart).Count -eq 0) { Write-Host 'Hermes is stopped. Start it with the original launcher when ready.' }
  $script:ExitCode = 0
} catch {
  Write-Warning $_.Exception.Message
  if ($script:Journal -and $script:Lock -and $script:Journal.phase -notin @('committed', 'rolled-back')) {
    try {
      if ($script:Journal.runtimeMoved -or $script:Journal.homeBackupComplete) { Restore-Transaction; $script:ExitCode = 10; Write-Warning 'Upgrade failed; original runtime and home restored. Backups retained.' }
      else {
        if ($script:StoppedExisting) {
          Stop-Owned
          Assert-Quiescent
          if (-not $KeepStopped) { foreach ($Spec in @($script:Journal.restart)) { Start-Spec $Spec | Out-Null } }
        }
        Write-Journal 'aborted'
        $script:ExitCode = 2
      }
    } catch { $script:ExitCode = 11; Write-Warning 'Rollback incomplete. Keep clients stopped and rerun -Recover after resolving filesystem/process permissions.' }
  }
} finally {
  if ($script:Lock) { $script:Lock.Dispose() }
  foreach ($Name in $script:SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($Name, $script:SavedEnvironment[$Name], 'Process') }
}
exit $script:ExitCode
