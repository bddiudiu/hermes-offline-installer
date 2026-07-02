param(
  [switch] $Portable
)

$ErrorActionPreference = "Stop"

Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path

function Test-TruthyEnv {
  param(
    [AllowNull()] [string] $Value
  )

  if (-not $Value) {
    return $false
  }
  return @("1", "true", "yes", "on") -contains $Value.Trim().ToLowerInvariant()
}

function ConvertTo-ComparablePath {
  param(
    [AllowNull()] [string] $Path
  )

  if (-not $Path) {
    return $null
  }

  try {
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd([char[]]"\/")
  } catch {
    return $Path.TrimEnd([char[]]"\/")
  }
}

function Test-SamePath {
  param(
    [AllowNull()] [string] $Left,
    [AllowNull()] [string] $Right
  )

  $LeftPath = ConvertTo-ComparablePath -Path $Left
  $RightPath = ConvertTo-ComparablePath -Path $Right
  if (-not $LeftPath -or -not $RightPath) {
    return $false
  }
  return $LeftPath.Equals($RightPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathUnderRoot {
  param(
    [AllowNull()] [string] $Path,
    [AllowNull()] [string] $Root
  )

  $ComparablePath = ConvertTo-ComparablePath -Path $Path
  $ComparableRoot = ConvertTo-ComparablePath -Path $Root
  if (-not $ComparablePath -or -not $ComparableRoot) {
    return $false
  }
  return (
    $ComparablePath.Equals($ComparableRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $ComparablePath.StartsWith($ComparableRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)
  )
}

function Get-WindowsDefaultHermesHome {
  $ProgramDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
  return (Join-Path $ProgramDataRoot "SSC\Hermes")
}

function Get-WindowsDefaultHermesOfflineHome {
  $ProgramFilesRoot = if ($env:ProgramFiles) { $env:ProgramFiles } else { "C:\Program Files" }
  return (Join-Path $ProgramFilesRoot "StarSoftComm\ZhanClaw\Hermes")
}

function Test-IsAdministrator {
  $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = [System.Security.Principal.WindowsPrincipal]::new($Identity)
  return $Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentUserSid {
  return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-InstallerTargetUserSid {
  $Sid = $env:HERMES_INSTALLER_USER_SID
  if ($Sid -and $Sid -match '^S-\d-\d+-.+') {
    return $Sid
  }
  return Get-CurrentUserSid
}

function Get-UserProfilePathFromSid {
  param(
    [string] $Sid
  )

  try {
    $ProfileListPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    $ProfileImagePath = (Get-ItemProperty -Path $ProfileListPath -Name "ProfileImagePath" -ErrorAction Stop).ProfileImagePath
    if ($ProfileImagePath) {
      return [Environment]::ExpandEnvironmentVariables($ProfileImagePath)
    }
  } catch {
  }
  return $env:USERPROFILE
}

function Open-TargetUserEnvironmentKey {
  param(
    [bool] $Writable
  )

  $UsersRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::Users,
    [Microsoft.Win32.RegistryView]::Default
  )
  try {
    $KeyPath = "$TargetUserSid\Environment"
    $Key = if ($Writable) {
      $UsersRoot.CreateSubKey($KeyPath)
    } else {
      $UsersRoot.OpenSubKey($KeyPath, $false)
    }
    if (-not $Key) {
      throw "Could not open HKEY_USERS\$KeyPath"
    }
    return $Key
  } finally {
    $UsersRoot.Dispose()
  }
}

function Get-TargetUserEnvironmentVariable {
  param(
    [string] $Name,
    [switch] $DoNotExpand
  )

  $Key = Open-TargetUserEnvironmentKey -Writable $false
  try {
    if ($DoNotExpand) {
      return $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    return $Key.GetValue($Name, $null)
  } finally {
    $Key.Dispose()
  }
}

function Get-TargetUserEnvironmentValueKind {
  param(
    [string] $Name
  )

  $Key = Open-TargetUserEnvironmentKey -Writable $false
  try {
    try {
      return $Key.GetValueKind($Name)
    } catch {
      return [Microsoft.Win32.RegistryValueKind]::String
    }
  } finally {
    $Key.Dispose()
  }
}

function Set-TargetUserEnvironmentVariable {
  param(
    [string] $Name,
    [AllowNull()] [string] $Value,
    [Microsoft.Win32.RegistryValueKind] $Kind = [Microsoft.Win32.RegistryValueKind]::String
  )

  $Key = Open-TargetUserEnvironmentKey -Writable $true
  try {
    if ($null -eq $Value) {
      try {
        $Key.DeleteValue($Name, $false)
      } catch {
      }
      return
    }
    $Key.SetValue($Name, $Value, $Kind)
  } finally {
    $Key.Dispose()
  }
}

function Set-HermesHomeAccess {
  param(
    [string] $Path,
    [string] $UserSid,
    [string] $CurrentSid
  )

  if (-not (Get-Command icacls.exe -ErrorAction SilentlyContinue)) {
    Write-Warning "icacls.exe was not found; could not update Hermes home ACLs for $Path."
    return
  }

  & icacls.exe $Path /inheritance:r /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not disable inherited ACLs under $Path."
  }

  & icacls.exe $Path /remove:g "*S-1-5-32-545" /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not remove broad standard Users ACLs from $Path."
  }

  $SystemGrant = "*S-1-5-18:(OI)(CI)F"
  $AdminGrant = "*S-1-5-32-544:(OI)(CI)F"
  & icacls.exe $Path /grant:r $SystemGrant $AdminGrant /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not grant system and administrator access to $Path."
  }

  $UserSids = @($UserSid, $CurrentSid) | Where-Object { $_ } | Select-Object -Unique
  foreach ($Sid in $UserSids) {
    $UserGrant = "*{0}:(OI)(CI)M" -f $Sid
    & icacls.exe $Path /grant:r $UserGrant /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Could not grant Hermes home access to user SID $Sid. Hermes may not be able to read config or .env for that user."
    }
  }

  & icacls.exe $Path /grant "*S-1-5-32-545:RX" /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not grant standard Users traverse access to $Path."
  }

  foreach ($WritableName in @("cache", "logs", "state")) {
    $WritablePath = Join-Path $Path $WritableName
    New-Item -ItemType Directory -Force -Path $WritablePath | Out-Null
    & icacls.exe $WritablePath /grant "*S-1-5-32-545:(OI)(CI)M" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Could not grant standard Users modify access to runtime writable directory $WritablePath."
    }
  }
}

$DefaultHermesHome = Get-WindowsDefaultHermesHome
$DefaultInstallRoot = Get-WindowsDefaultHermesOfflineHome
$DefaultProgramDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
$DefaultProgramFilesRoot = if ($env:ProgramFiles) { $env:ProgramFiles } else { "C:\Program Files" }
$CurrentUserSid = Get-CurrentUserSid
$TargetUserSid = Get-InstallerTargetUserSid
$TargetUserProfile = Get-UserProfilePathFromSid -Sid $TargetUserSid
if ($TargetUserSid -ne $CurrentUserSid) {
  Write-Host "Writing User environment variables for original installer user SID: $TargetUserSid"
}
$LegacyHermesHome = Join-Path $TargetUserProfile ".hermes"
$LegacyInstallRoot = Join-Path $TargetUserProfile ".hermes-offline"
$LegacyOfflineBinDir = Join-Path $LegacyInstallRoot "bin"
$CustomInstallRoot = if ($env:HERMES_OFFLINE_HOME -and -not (Test-SamePath -Left $env:HERMES_OFFLINE_HOME -Right $LegacyInstallRoot)) {
  $env:HERMES_OFFLINE_HOME
} else {
  $null
}
$CustomHermesHome = if ($env:HERMES_HOME -and -not (Test-SamePath -Left $env:HERMES_HOME -Right $LegacyHermesHome)) {
  $env:HERMES_HOME
} else {
  $null
}

$LocalPortableRoot = Join-Path $BundleDir ".hermes-offline"
$ExistingPortableInstall = Test-Path (Join-Path $LocalPortableRoot "bin\hermes.cmd")
$PortableMode = [bool] $Portable -or (Test-TruthyEnv -Value $env:HERMES_PORTABLE_MODE) -or ((-not $CustomInstallRoot) -and $ExistingPortableInstall)
$InstallRoot = if ($CustomInstallRoot) {
  $CustomInstallRoot
} elseif ($PortableMode) {
  $LocalPortableRoot
} else {
  $DefaultInstallRoot
}
$RuntimeDir = Join-Path $InstallRoot "runtime"
$BinDir = Join-Path $InstallRoot "bin"
$LegacyShimDirs = @((Join-Path $env:USERPROFILE ".local\bin"), $LegacyOfflineBinDir)
if ($env:APPDATA) {
  $LegacyShimDirs += (Join-Path $env:APPDATA "uv\tools\bin")
  $LegacyShimDirs += (Join-Path $env:APPDATA "clawpanel\bin")
}
$LegacyShimDirs = $LegacyShimDirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
$HermesHome = if ($CustomHermesHome) {
  $CustomHermesHome
} elseif ($PortableMode) {
  Join-Path $BundleDir ".hermes"
} else {
  $DefaultHermesHome
}
$VenvDir = Join-Path $RuntimeDir "venv"
$RuntimeWheelhouse = Join-Path $RuntimeDir "wheelhouse"
$RuntimeTemplates = Join-Path $RuntimeDir "templates"
$RuntimeCommands = Join-Path $RuntimeDir "commands"
$RuntimeBundle = Join-Path $RuntimeDir "bundle-runtime"
$RuntimeResources = Join-Path $RuntimeDir "hermes-resources"
$ExistingHermesCmd = Join-Path $BinDir "hermes.cmd"

function Test-ProcessMatchesPath {
  param(
    [AllowNull()] [string] $Value,
    [string[]] $Paths
  )

  if (-not $Value) {
    return $false
  }

  foreach ($Path in $Paths) {
    if ($Path -and $Value.IndexOf($Path, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      return $true
    }
  }
  return $false
}

function Stop-ExistingHermesProcesses {
  param(
    [string] $InstallRoot,
    [string] $RuntimeDir,
    [string] $HermesHome,
    [string[]] $ShimDirs
  )

  $MatchPaths = @($InstallRoot, $RuntimeDir, $HermesHome) + $ShimDirs | Where-Object { $_ } | Select-Object -Unique
  $CurrentPid = $PID
  $Processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    if ($_.ProcessId -eq $CurrentPid) {
      return $false
    }

    $Name = $_.Name
    $ExecutablePath = $_.ExecutablePath
    $CommandLine = $_.CommandLine
    $MatchesKnownPath = (
      (Test-ProcessMatchesPath -Value $ExecutablePath -Paths $MatchPaths) -or
      (Test-ProcessMatchesPath -Value $CommandLine -Paths $MatchPaths)
    )
    if ($Name -in @("hermes.exe", "hermes-agent.exe") -and $MatchesKnownPath) {
      return $true
    }
    if ($Name -in @("python.exe", "pythonw.exe", "uv.exe", "uvicorn.exe") -and $MatchesKnownPath) {
      return $true
    }
    return $false
  }

  if (-not $Processes) {
    return
  }

  $ProcessIds = @($Processes | Select-Object -ExpandProperty ProcessId -Unique)
  Write-Host "Stopping running Hermes processes before install/upgrade: $($ProcessIds -join ', ')"
  foreach ($ProcessId in $ProcessIds) {
    try {
      Stop-Process -Id $ProcessId -ErrorAction Stop
    } catch {
      Write-Warning "Could not stop process $ProcessId gracefully: $($_.Exception.Message)"
    }
  }

  Start-Sleep -Seconds 2
  $StillRunning = @()
  foreach ($ProcessId in $ProcessIds) {
    try {
      $Process = Get-Process -Id $ProcessId -ErrorAction Stop
      $StillRunning += $Process
    } catch {
    }
  }

  if ($StillRunning.Count -eq 0) {
    return
  }

  Write-Host "Forcing remaining Hermes processes to stop: $((@($StillRunning | Select-Object -ExpandProperty Id)) -join ', ')"
  foreach ($Process in $StillRunning) {
    try {
      Stop-Process -Id $Process.Id -Force -ErrorAction Stop
    } catch {
      throw "Could not stop running Hermes process $($Process.Id). Please close Hermes/ClawPanel and rerun install.cmd. Error: $($_.Exception.Message)"
    }
  }
}

function Remove-InstallPath {
  param(
    [string] $Path
  )

  if (-not (Test-Path $Path)) {
    return
  }

  try {
    Remove-Item -Recurse -Force $Path -ErrorAction Stop
  } catch {
    throw "Could not remove $Path. Please close Hermes/ClawPanel and rerun install.cmd. Error: $($_.Exception.Message)"
  }

  if (Test-Path $Path) {
    throw "Could not remove $Path. Please close Hermes/ClawPanel and rerun install.cmd."
  }
}

function New-BackupPath {
  param(
    [string] $Path,
    [string] $Label
  )

  $Parent = Split-Path -Parent $Path
  $Name = Split-Path -Leaf $Path
  $Timestamp = Get-Date -Format "yyyyMMddHHmmss"
  $Candidate = Join-Path $Parent "$Name.$Label.$Timestamp"
  $Index = 0
  while (Test-Path $Candidate) {
    $Index++
    $Candidate = Join-Path $Parent "$Name.$Label.$Timestamp.$Index"
  }
  return $Candidate
}

function Restore-RuntimeBackup {
  param(
    [string] $RuntimeDir,
    [AllowNull()] [string] $RuntimeBackupDir
  )

  if (-not $RuntimeBackupDir -or -not (Test-Path $RuntimeBackupDir)) {
    return
  }
  if (Test-Path $RuntimeDir) {
    Remove-InstallPath -Path $RuntimeDir
  }
  Move-Item -Force $RuntimeBackupDir $RuntimeDir
  Write-Host "Restored previous Hermes runtime: $RuntimeDir"
}

function Clear-PythonRuntimeEnvironment {
  Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
  Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
}

function Test-BundledPythonRuntime {
  param(
    [string] $PythonBin,
    [AllowNull()] [string] $PythonHome
  )

  Clear-PythonRuntimeEnvironment
  if ($PythonHome) {
    $env:PYTHONHOME = $PythonHome
  }

  & $PythonBin -c "import encodings, ensurepip, venv"
  $Succeeded = ($LASTEXITCODE -eq 0)
  Clear-PythonRuntimeEnvironment
  return $Succeeded
}

function Invoke-HermesVenvAttempt {
  param(
    [string] $PythonBin,
    [string] $VenvDir,
    [AllowNull()] [string] $PythonHome
  )

  Clear-PythonRuntimeEnvironment
  if ($PythonHome) {
    $env:PYTHONHOME = $PythonHome
  }
  Remove-InstallPath -Path $VenvDir
  & $PythonBin -m venv --without-pip $VenvDir
  $VenvExitCode = $LASTEXITCODE
  Clear-PythonRuntimeEnvironment
  if ($VenvExitCode -ne 0) {
    return [pscustomobject]@{
      Succeeded = $false
      Stage = "venv"
      Summary = "venv exit code $VenvExitCode"
      Details = ""
    }
  }

  $VenvPython = Join-Path $VenvDir "Scripts\python.exe"
  try {
    Invoke-HermesEnsurePip -VenvPython $VenvPython -PythonHome $PythonHome
    return [pscustomobject]@{
      Succeeded = $true
      Stage = "complete"
      Summary = "ok"
      Details = ""
    }
  } catch {
    $Message = $_.Exception.Message
    $FirstLine = $Message
    $LineBreakIndex = $FirstLine.IndexOf("`n")
    if ($LineBreakIndex -ge 0) {
      $FirstLine = $FirstLine.Substring(0, $LineBreakIndex).TrimEnd("`r")
    }
    return [pscustomobject]@{
      Succeeded = $false
      Stage = "ensurepip"
      Summary = "ensurepip failed: $FirstLine"
      Details = $Message
    }
  } finally {
    Clear-PythonRuntimeEnvironment
  }
}

function New-HermesVenv {
  param(
    [string] $PythonBin,
    [string] $VenvDir,
    [AllowNull()] [string] $FallbackPythonHome
  )

  $FirstResult = Invoke-HermesVenvAttempt -PythonBin $PythonBin -VenvDir $VenvDir -PythonHome $null
  if ($FirstResult.Succeeded) {
    return
  }

  Write-Warning "Python venv bootstrap failed using a clean Python environment ($($FirstResult.Summary)). Retrying once after recreating $VenvDir."
  Start-Sleep -Seconds 1
  $SecondResult = Invoke-HermesVenvAttempt -PythonBin $PythonBin -VenvDir $VenvDir -PythonHome $null
  if ($SecondResult.Succeeded) {
    return
  }

  if ($FallbackPythonHome) {
    Write-Warning "Python venv bootstrap failed again ($($SecondResult.Summary)). Retrying with PYTHONHOME=$FallbackPythonHome for this process only."
    $ThirdResult = Invoke-HermesVenvAttempt -PythonBin $PythonBin -VenvDir $VenvDir -PythonHome $FallbackPythonHome
    if ($ThirdResult.Succeeded) {
      return
    }
    throw "Python venv creation failed. clean attempts: $($FirstResult.Summary); $($SecondResult.Summary); PYTHONHOME retry: $($ThirdResult.Summary); python: $PythonBin; target: $VenvDir"
  }

  throw "Python venv creation failed. clean attempts: $($FirstResult.Summary); $($SecondResult.Summary); python: $PythonBin; target: $VenvDir"
}

function Invoke-NativeCommandCaptured {
  param(
    [string] $FilePath,
    [string[]] $Arguments
  )

  $StdoutPath = [System.IO.Path]::GetTempFileName()
  $StderrPath = [System.IO.Path]::GetTempFileName()
  try {
    $Process = Start-Process `
      -FilePath $FilePath `
      -ArgumentList $Arguments `
      -NoNewWindow `
      -Wait `
      -PassThru `
      -RedirectStandardOutput $StdoutPath `
      -RedirectStandardError $StderrPath
    $Output = @()
    if (Test-Path $StdoutPath) {
      $Output += @(Get-Content -Path $StdoutPath -ErrorAction SilentlyContinue)
    }
    if (Test-Path $StderrPath) {
      $Output += @(Get-Content -Path $StderrPath -ErrorAction SilentlyContinue)
    }
    return [pscustomobject]@{
      ExitCode = $Process.ExitCode
      Output = $Output
    }
  } finally {
    Remove-Item -Force $StdoutPath, $StderrPath -ErrorAction SilentlyContinue
  }
}

function Invoke-HermesEnsurePip {
  param(
    [string] $VenvPython,
    [AllowNull()] [string] $PythonHome
  )

  if (-not (Test-Path $VenvPython)) {
    throw "Python venv executable was not created: $VenvPython"
  }

  $LastResult = $null
  for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
    Clear-PythonRuntimeEnvironment
    if ($PythonHome) {
      $env:PYTHONHOME = $PythonHome
    }
    $LastResult = Invoke-NativeCommandCaptured `
      -FilePath $VenvPython `
      -Arguments @("-m", "ensurepip", "--upgrade", "--default-pip")
    Clear-PythonRuntimeEnvironment
    if ($LastResult.ExitCode -eq 0) {
      return
    }
    if ($Attempt -lt 3) {
      $NextAttempt = $Attempt + 1
      Write-Warning "Python ensurepip failed with exit code $($LastResult.ExitCode). Retrying attempt $NextAttempt of 3 ..."
      Start-Sleep -Seconds $Attempt
    }
  }

  $Details = ""
  if ($LastResult -and $LastResult.Output) {
    $Details = (($LastResult.Output | Select-Object -Last 30) -join "`n")
  }
  throw "Python ensurepip failed after 3 attempts with exit code $($LastResult.ExitCode). python: $VenvPython`n$Details"
}

function Test-LocalTcpPort {
  param(
    [int] $Port
  )

  $Client = $null
  try {
    $Client = New-Object System.Net.Sockets.TcpClient
    $Async = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
    if (-not $Async.AsyncWaitHandle.WaitOne(500, $false)) {
      return $false
    }
    $Client.EndConnect($Async)
    return $true
  } catch {
    return $false
  } finally {
    if ($Client) {
      $Client.Close()
    }
  }
}

function Start-HermesDashboard {
  param(
    [string] $HermesCmd,
    [int] $Port
  )

  if ($env:HERMES_NO_START_DASHBOARD -eq "1") {
    Write-Host "Skipping Dashboard startup because HERMES_NO_START_DASHBOARD=1."
    return
  }

  if (Test-LocalTcpPort -Port $Port) {
    Write-Host "Hermes Dashboard is already listening on http://127.0.0.1:$Port."
    return
  }

  Write-Host "Starting Hermes Dashboard on http://127.0.0.1:$Port ..."
  if ($env:HERMES_START_DASHBOARD_VISIBLE -eq "1" -or $env:HERMES_LAUNCH_VISIBLE -eq "1") {
    Start-Process -FilePath $env:ComSpec -ArgumentList @("/k", "title Hermes Agent Dashboard && `"$HermesCmd`" dashboard --no-open") | Out-Null
  } else {
    Start-Process -WindowStyle Hidden -FilePath $env:ComSpec -ArgumentList @("/c", "`"$HermesCmd`" dashboard --no-open") | Out-Null
  }
  Start-Sleep -Seconds 3
  if (Test-LocalTcpPort -Port $Port) {
    Write-Host "Hermes Dashboard started: http://127.0.0.1:$Port"
  } else {
    Write-Warning "Hermes Dashboard was launched but port $Port is not listening yet. Set HERMES_START_DASHBOARD_VISIBLE=1 and rerun install.cmd to inspect logs."
  }
}

function Start-HermesDashboardAfterInstall {
  param(
    [string] $HermesCmd,
    [int] $Port
  )

  Start-HermesDashboard -HermesCmd $HermesCmd -Port $Port
}

function Remove-HermesShimFiles {
  param(
    [string[]] $ShimDirs
  )

  $ShimNames = @(
    "hermes.cmd",
    "hermes.bat",
    "dashboard.cmd",
    "dashboard.bat",
    "hermes-dashboard.cmd",
    "hermes-dashboard.bat",
    "hermes-launch.cmd",
    "hermes-launch.bat",
    "hermes-repair.cmd",
    "hermes-repair.bat",
    "hermes-shutdown.cmd",
    "hermes-shutdown.bat",
    "hermes-uninstall.cmd",
    "hermes-uninstall.bat",
    "hermes.exe"
  )

  foreach ($ShimDir in $ShimDirs) {
    if (-not $ShimDir -or -not (Test-Path $ShimDir)) {
      continue
    }
    foreach ($ShimName in $ShimNames) {
      $ShimPath = Join-Path $ShimDir $ShimName
      if (Test-Path $ShimPath) {
        Remove-Item -Force $ShimPath -ErrorAction Stop
        Write-Host "Removed legacy shim: $ShimPath"
      }
    }
  }
}

function Remove-UserPathEntries {
  param(
    [string[]] $Paths
  )

  $UserPath = Get-TargetUserEnvironmentVariable -Name "Path" -DoNotExpand
  if (-not $UserPath) {
    return
  }
  $UserPathKind = Get-TargetUserEnvironmentValueKind -Name "Path"

  $ComparablePaths = @($Paths | Where-Object { $_ } | ForEach-Object {
    ConvertTo-ComparablePath -Path $_
  } | Where-Object { $_ } | Select-Object -Unique)
  if ($ComparablePaths.Count -eq 0) {
    return
  }

  $PathParts = @()
  foreach ($Part in ($UserPath -split ";")) {
    if (-not $Part) {
      continue
    }
    $ComparablePart = ConvertTo-ComparablePath -Path $Part
    $ShouldRemove = $false
    foreach ($ComparablePath in $ComparablePaths) {
      if ($ComparablePart -and $ComparablePart.Equals($ComparablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $ShouldRemove = $true
        break
      }
    }
    if (-not $ShouldRemove) {
      $PathParts += $Part
    }
  }

  Set-TargetUserEnvironmentVariable -Name "Path" -Value (($PathParts | Select-Object -Unique) -join ";") -Kind $UserPathKind
}

function Remove-HermesExeShim {
  param(
    [string] $ShimDir
  )

  $ShimExe = Join-Path $ShimDir "hermes.exe"
  if (-not (Test-Path $ShimExe)) {
    return
  }

  try {
    Remove-Item -Force $ShimExe -ErrorAction Stop
    Write-Host "Removed legacy Hermes exe shim: $ShimExe"
  } catch {
    throw "Could not remove legacy Hermes exe shim $ShimExe. Please close Hermes/ClawPanel and rerun install.cmd. Error: $($_.Exception.Message)"
  }
}

function New-HermesExeShimTemplate {
  param(
    [string] $OutputPath
  )

  $Source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class HermesShim
{
    public static int Main(string[] args)
    {
        string exePath = Process.GetCurrentProcess().MainModule.FileName;
        string shimDir = Path.GetDirectoryName(exePath);
        string hermesCmd = Path.Combine(shimDir, "hermes.cmd");
        if (!File.Exists(hermesCmd))
        {
            Console.Error.WriteLine("Hermes command shim was not found: " + hermesCmd);
            return 1;
        }

        string comSpec = Environment.GetEnvironmentVariable("ComSpec");
        if (String.IsNullOrEmpty(comSpec))
        {
            comSpec = "cmd.exe";
        }

        StringBuilder command = new StringBuilder();
        command.Append(QuoteForCommandLine(hermesCmd));
        foreach (string arg in args)
        {
            command.Append(' ');
            command.Append(QuoteForCommandLine(arg));
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = comSpec;
        startInfo.Arguments = "/d /c \"" + command.ToString() + "\"";
        startInfo.UseShellExecute = false;

        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static string QuoteForCommandLine(string value)
    {
        if (value == null)
        {
            return "\"\"";
        }

        bool needsQuotes = value.Length == 0;
        for (int i = 0; i < value.Length; i++)
        {
            if (Char.IsWhiteSpace(value[i]) || value[i] == '"')
            {
                needsQuotes = true;
                break;
            }
        }

        if (!needsQuotes)
        {
            return value;
        }

        StringBuilder result = new StringBuilder();
        result.Append('"');
        int backslashes = 0;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\\')
            {
                backslashes++;
                continue;
            }

            if (c == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(c);
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
'@

  Add-Type -TypeDefinition $Source -Language CSharp -OutputType ConsoleApplication -OutputAssembly $OutputPath
}

function Install-HermesExeShim {
  param(
    [string] $ShimDir,
    [string] $TemplatePath
  )

  Remove-HermesExeShim -ShimDir $ShimDir
  $ShimExe = Join-Path $ShimDir "hermes.exe"
  Copy-Item -Force $TemplatePath $ShimExe
}

function Sync-BundledSkills {
  param(
    [string] $VenvPython,
    [string] $HermesHome,
    [string] $InstallRoot,
    [string] $ResourcesDir
  )

  $SkillsDir = Join-Path $HermesHome "skills"
  New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
  Write-Host "Syncing bundled Agent Skills to $SkillsDir ..."

  $PreviousHermesHome = $env:HERMES_HOME
  $PreviousHermesOfflineHome = $env:HERMES_OFFLINE_HOME
  $PreviousBundledSkills = $env:HERMES_BUNDLED_SKILLS
  $PreviousOptionalSkills = $env:HERMES_OPTIONAL_SKILLS
  $PreviousOptionalMcps = $env:HERMES_OPTIONAL_MCPS
  $PreviousBundledLocales = $env:HERMES_BUNDLED_LOCALES
  $PreviousBundledPlugins = $env:HERMES_BUNDLED_PLUGINS
  $PreviousWebDist = $env:HERMES_WEB_DIST
  $PreviousTuiDir = $env:HERMES_TUI_DIR
  $env:HERMES_HOME = $HermesHome
  $env:HERMES_OFFLINE_HOME = $InstallRoot
  $env:HERMES_BUNDLED_SKILLS = Join-Path $ResourcesDir "skills"
  $env:HERMES_OPTIONAL_SKILLS = Join-Path $ResourcesDir "optional-skills"
  $env:HERMES_OPTIONAL_MCPS = Join-Path $ResourcesDir "optional-mcps"
  $env:HERMES_BUNDLED_LOCALES = Join-Path $ResourcesDir "locales"
  $env:HERMES_BUNDLED_PLUGINS = Join-Path $ResourcesDir "plugins"
  $env:HERMES_WEB_DIST = Join-Path $ResourcesDir "web_dist"
  $env:HERMES_TUI_DIR = Join-Path $ResourcesDir "tui_dist"
  try {
    & $VenvPython -m tools.skills_sync
    if ($LASTEXITCODE -ne 0) {
      throw "Bundled Agent Skills sync failed with exit code $LASTEXITCODE."
    }
  } finally {
    if ($null -eq $PreviousHermesHome) {
      Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
    } else {
      $env:HERMES_HOME = $PreviousHermesHome
    }
    foreach ($EnvRestore in @(
      @("HERMES_OFFLINE_HOME", $PreviousHermesOfflineHome),
      @("HERMES_BUNDLED_SKILLS", $PreviousBundledSkills),
      @("HERMES_OPTIONAL_SKILLS", $PreviousOptionalSkills),
      @("HERMES_OPTIONAL_MCPS", $PreviousOptionalMcps),
      @("HERMES_BUNDLED_LOCALES", $PreviousBundledLocales),
      @("HERMES_BUNDLED_PLUGINS", $PreviousBundledPlugins),
      @("HERMES_WEB_DIST", $PreviousWebDist),
      @("HERMES_TUI_DIR", $PreviousTuiDir)
    )) {
      if ($null -eq $EnvRestore[1]) {
        Remove-Item "Env:$($EnvRestore[0])" -ErrorAction SilentlyContinue
      } else {
        Set-Item -Path "Env:$($EnvRestore[0])" -Value $EnvRestore[1]
      }
    }
  }

  $OptOutMarker = Join-Path $HermesHome ".no-bundled-skills"
  if (Test-Path $OptOutMarker) {
    Write-Host "Bundled Agent Skills sync skipped because .no-bundled-skills is present."
    return
  }

  $SkillFiles = @(Get-ChildItem -Path $SkillsDir -Recurse -Filter "SKILL.md" -File -ErrorAction SilentlyContinue)
  if ($SkillFiles.Count -eq 0) {
    throw "Bundled Agent Skills were not installed into $SkillsDir."
  }
  foreach ($RequiredSkill in @(
    (Join-Path $SkillsDir "apple\imessage\SKILL.md"),
    (Join-Path $SkillsDir "autonomous-ai-agents\codex\SKILL.md")
  )) {
    if (-not (Test-Path $RequiredSkill)) {
      throw "Bundled Agent Skill is missing after sync: $RequiredSkill"
    }
  }
}

function Write-Utf8NoBomLines {
  param(
    [string] $Path,
    [string[]] $Lines
  )

  $Encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($Path, $Lines, $Encoding)
}

function Get-DotEnvValue {
  param(
    [string] $Path,
    [string[]] $Names
  )

  if (-not (Test-Path $Path)) {
    return $null
  }

  $NameSet = @{}
  foreach ($Name in $Names) {
    if ($Name) {
      $NameSet[$Name.ToUpperInvariant()] = $true
    }
  }

  foreach ($Line in (Get-Content -Path $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    if ($Line -notmatch '^\s*([^#=\s]+)\s*=\s*(.*)$') {
      continue
    }
    $Key = $Matches[1].Trim().ToUpperInvariant()
    if (-not $NameSet.ContainsKey($Key)) {
      continue
    }
    $Value = $Matches[2].Trim()
    if ($Value.Length -ge 2) {
      $First = $Value.Substring(0, 1)
      $Last = $Value.Substring($Value.Length - 1, 1)
      if (($First -eq '"' -and $Last -eq '"') -or ($First -eq "'" -and $Last -eq "'")) {
        $Value = $Value.Substring(1, $Value.Length - 2)
      }
    }
    if ($Value) {
      return $Value
    }
  }

  return $null
}

function New-HexSecret {
  $Bytes = New-Object byte[] 32
  $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $Rng.GetBytes($Bytes)
  } finally {
    $Rng.Dispose()
  }
  return ([System.BitConverter]::ToString($Bytes)).Replace("-", "").ToLowerInvariant()
}

function Test-WeakApiServerKey {
  param(
    [AllowNull()] [string] $Value
  )

  if (-not $Value) {
    return $true
  }
  $Trimmed = $Value.Trim()
  if ($Trimmed.Length -ge 2) {
    $First = $Trimmed.Substring(0, 1)
    $Last = $Trimmed.Substring($Trimmed.Length - 1, 1)
    if (($First -eq '"' -and $Last -eq '"') -or ($First -eq "'" -and $Last -eq "'")) {
      $Trimmed = $Trimmed.Substring(1, $Trimmed.Length - 2)
    }
  }
  return ($Trimmed -eq "clawpanel-local" -or $Trimmed.Length -lt 16)
}

function Ensure-ApiServerKey {
  param(
    [string] $EnvPath
  )

  $Lines = @()
  if (Test-Path $EnvPath) {
    $Lines = @(Get-Content -Path $EnvPath -Encoding UTF8 -ErrorAction Stop)
  }

  $ExistingValue = $null
  foreach ($Line in $Lines) {
    if ($Line -match '^\s*API_SERVER_KEY\s*=\s*(.*)$') {
      $ExistingValue = $Matches[1].Trim()
    }
  }

  if (-not (Test-WeakApiServerKey -Value $ExistingValue)) {
    return
  }

  $FilteredLines = @($Lines | Where-Object { $_ -notmatch '^\s*API_SERVER_KEY\s*=' })
  $NewKey = New-HexSecret
  $OutputLines = @()
  $OutputLines += $FilteredLines
  if ($OutputLines.Count -gt 0 -and $OutputLines[$OutputLines.Count - 1] -ne "") {
    $OutputLines += ""
  }
  $OutputLines += "API_SERVER_KEY=$NewKey"
  Write-Utf8NoBomLines -Path $EnvPath -Lines $OutputLines
  Write-Host "Generated a strong API_SERVER_KEY in $EnvPath."
}

function Import-ZhanClawEnvironmentFromLegacyDotEnv {
  param(
    [string[]] $EnvPaths,
    [bool] $PortableMode
  )

  $Mappings = @(
    @{
      Target = "ZHANCLAW_BASE_URL"
      Legacy = @("ZHANCLAW_BASE_URL", "CUSTOM_BASE_URL", "OPENAI_BASE_URL")
    },
    @{
      Target = "ZHANCLAW_API_KEY"
      Legacy = @("ZHANCLAW_API_KEY", "CUSTOM_API_KEY", "OPENAI_API_KEY")
    }
  )

  foreach ($Mapping in $Mappings) {
    $Target = [string] $Mapping["Target"]
    if ([Environment]::GetEnvironmentVariable($Target, "Process")) {
      continue
    }
    if (-not $PortableMode -and (Get-TargetUserEnvironmentVariable -Name $Target)) {
      continue
    }
    $LegacyNames = [string[]] $Mapping["Legacy"]
    $Value = $null
    foreach ($EnvPath in $EnvPaths) {
      if (-not $EnvPath) {
        continue
      }
      $Value = Get-DotEnvValue -Path $EnvPath -Names $LegacyNames
      if ($Value) {
        break
      }
    }
    if (-not $Value) {
      continue
    }
    Set-Item -Path ("Env:{0}" -f $Target) -Value $Value
    if (-not $PortableMode) {
      Set-TargetUserEnvironmentVariable -Name $Target -Value $Value
    }
    $SourceLabel = ($LegacyNames | Where-Object { $_ -ne $Target }) -join "/"
    Write-Host "Migrated $Target from legacy .env model setting ($SourceLabel)."
  }
}

function Copy-LegacyHermesHomeFileIfMissing {
  param(
    [string] $TargetPath,
    [string] $LegacyPath,
    [string] $Label
  )

  if ((Test-Path $TargetPath) -or -not (Test-Path $LegacyPath)) {
    return
  }
  Copy-Item -Force $LegacyPath $TargetPath
  Write-Host "Migrated legacy Hermes $Label from $LegacyPath to $TargetPath."
}

$ShimDirs = @($BinDir)
$ProcessShimDirs = (@($BinDir) + $LegacyShimDirs) | Where-Object { $_ } | Select-Object -Unique
if ($env:HERMES_OFFLINE_HOME -and -not $CustomInstallRoot) {
  Write-Host "Ignoring legacy HERMES_OFFLINE_HOME=$env:HERMES_OFFLINE_HOME; using $InstallRoot."
}
if ($env:HERMES_HOME -and -not $CustomHermesHome) {
  Write-Host "Ignoring legacy HERMES_HOME=$env:HERMES_HOME; using $HermesHome."
}
if (-not $PortableMode -and (Test-PathUnderRoot -Path $InstallRoot -Root $DefaultProgramFilesRoot) -and -not (Test-IsAdministrator)) {
  throw "Windows default installation writes to $InstallRoot and requires administrator rights. Run install.cmd again and accept the UAC prompt, or extract the bundle to a writable folder and run install.cmd -Portable."
}
$ExistingConfigPath = Join-Path $HermesHome "config.yaml"
$ExistingEnvPath = Join-Path $HermesHome ".env"
$ExistingSkillsDir = Join-Path $HermesHome "skills"
$ExistingRuntimeResources = Join-Path $RuntimeDir "hermes-resources"
$IsUpgrade = (
  (Test-Path $VenvDir) -or
  (Test-Path $RuntimeBundle) -or
  (Test-Path $ExistingHermesCmd) -or
  (Test-Path $ExistingRuntimeResources) -or
  (Test-Path $ExistingConfigPath) -or
  (Test-Path $ExistingEnvPath) -or
  (Test-Path $ExistingSkillsDir)
)
if ($IsUpgrade) {
  Write-Host "Existing Hermes offline installation detected. Running upgrade."
} else {
  Write-Host "No existing Hermes offline installation detected. Running install."
}
if ($PortableMode) {
  Write-Host "Portable mode enabled. Runtime and Hermes home will stay inside: $BundleDir"
} else {
  Write-Host "Windows install root: $InstallRoot"
  Write-Host "Windows Hermes home: $HermesHome"
}
$InstallDirs = @($HermesHome) + $ShimDirs
New-Item -ItemType Directory -Force -Path $InstallDirs | Out-Null

$Wheelhouse = Join-Path $BundleDir "wheelhouse"
if (-not (Test-Path $Wheelhouse)) {
  throw "Missing wheelhouse: $Wheelhouse"
}
$BundledResources = Join-Path $BundleDir "hermes-resources"
if (-not (Test-Path $BundledResources)) {
  throw "Missing Hermes runtime resources: $BundledResources"
}

$RuntimeBackupDir = $null
$RuntimeInstallCommitted = $false
$RuntimeRebuildStarted = $false
try {
Stop-ExistingHermesProcesses -InstallRoot $InstallRoot -RuntimeDir $RuntimeDir -HermesHome $HermesHome -ShimDirs $ProcessShimDirs
Remove-HermesShimFiles -ShimDirs $LegacyShimDirs
if (Test-Path $RuntimeDir) {
  $RuntimeBackupDir = New-BackupPath -Path $RuntimeDir -Label "old"
  Move-Item -Force $RuntimeDir $RuntimeBackupDir
  $RuntimeRebuildStarted = $true
  Write-Host "Backed up previous Hermes runtime: $RuntimeBackupDir"
} else {
  $RuntimeRebuildStarted = $true
}
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
foreach ($Path in @($RuntimeWheelhouse, $RuntimeTemplates, $RuntimeCommands, $RuntimeBundle, $RuntimeResources, $VenvDir)) {
  Remove-InstallPath -Path $Path
}
Copy-Item -Recurse -Force $Wheelhouse $RuntimeWheelhouse
Copy-Item -Recurse -Force (Join-Path $BundleDir "templates") $RuntimeTemplates
New-Item -ItemType Directory -Force -Path $RuntimeCommands | Out-Null
Copy-Item -Force (Join-Path $ScriptDir "launch_windows.ps1") (Join-Path $RuntimeCommands "launch_windows.ps1")
Copy-Item -Force (Join-Path $ScriptDir "shutdown_windows.ps1") (Join-Path $RuntimeCommands "shutdown_windows.ps1")
Copy-Item -Force (Join-Path $ScriptDir "uninstall_windows.ps1") (Join-Path $RuntimeCommands "uninstall_windows.ps1")
Copy-Item -Recurse -Force (Join-Path $BundleDir "runtime") $RuntimeBundle
Copy-Item -Recurse -Force $BundledResources $RuntimeResources

$Candidates = @(
  (Join-Path $RuntimeBundle "python\python.exe"),
  (Join-Path $RuntimeBundle "python\bin\python.exe")
)
$PythonBin = $null
foreach ($Candidate in $Candidates) {
  if (-not $PythonBin -and (Test-Path $Candidate)) {
    $PythonBin = $Candidate
    break
  }
}

$RequestedPython = $env:HERMES_PYTHON
if (-not $PythonBin -and $RequestedPython -and (Test-Path $RequestedPython)) {
  $RequestedPythonPath = (Resolve-Path $RequestedPython).Path
  $VenvDirPath = [System.IO.Path]::GetFullPath($VenvDir).TrimEnd('\')
  if (-not $RequestedPythonPath.StartsWith($VenvDirPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    $PythonBin = $RequestedPythonPath
  } else {
    Write-Host "Ignoring HERMES_PYTHON because it points inside the install venv: $RequestedPythonPath"
  }
} elseif (-not $PythonBin -and $RequestedPython) {
  Write-Host "Ignoring unavailable HERMES_PYTHON: $RequestedPython"
}

if (-not $PythonBin) {
  throw "Bundled Python runtime was not found. Please ensure bundle\runtime\python contains portable Python."
}

$BundledPythonHome = Split-Path -Parent $PythonBin
$PythonRuntimeNeedsPythonHome = $false
if (-not (Test-BundledPythonRuntime -PythonBin $PythonBin -PythonHome $null)) {
  $EncodingsDir = Get-ChildItem -Path $BundledPythonHome -Recurse -Directory -Filter "encodings" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (Test-BundledPythonRuntime -PythonBin $PythonBin -PythonHome $BundledPythonHome) {
    $PythonRuntimeNeedsPythonHome = $true
  } else {
    $PythonZip = Get-ChildItem -Path $BundledPythonHome -Filter "python*.zip" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $LibEncodings = Join-Path $BundledPythonHome "Lib\encodings"
    $PythonZipStatus = if ($PythonZip) { "$($PythonZip.FullName) exists=True" } else { "python*.zip exists=False" }
    throw "Bundled Python failed to import encodings, ensurepip, and venv. PYTHONHOME=$BundledPythonHome; $PythonZipStatus; Lib\encodings exists=$(Test-Path $LibEncodings); discovered encodings=$($EncodingsDir.FullName)"
  }
}

$FallbackPythonHome = if ($PythonRuntimeNeedsPythonHome) { $BundledPythonHome } else { $null }
New-HermesVenv -PythonBin $PythonBin -VenvDir $VenvDir -FallbackPythonHome $FallbackPythonHome
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path (Join-Path $VenvDir "pyvenv.cfg")) -or -not (Test-Path $VenvPython)) {
  throw "Python venv was not created correctly: $VenvDir"
}
$HermesInstallSpec = "hermes-agent[all]"
$InstallRequirements = @()
$WheelhouseManifest = Join-Path $RuntimeWheelhouse "manifest.json"
if (-not (Test-Path $WheelhouseManifest)) {
  throw "Missing wheelhouse manifest: $WheelhouseManifest"
}
try {
  $WheelhouseMeta = Get-Content -Raw -Path $WheelhouseManifest -Encoding UTF8 | ConvertFrom-Json
  $Extras = @($WheelhouseMeta.extras) | Where-Object { $_ }
  if ($Extras.Count -gt 0) {
    $HermesInstallSpec = "hermes-agent[$($Extras -join ',')]"
  } else {
    $HermesInstallSpec = "hermes-agent"
  }
  $InstallRequirements = @($WheelhouseMeta.install_requirements) | Where-Object { $_ }
  if ($InstallRequirements.Count -eq 0) {
    throw "wheelhouse manifest has no install_requirements"
  }
} catch {
  throw "Could not parse wheelhouse manifest. Error: $($_.Exception.Message)"
}
Write-Host "Installing Hermes package spec: $HermesInstallSpec"
& $VenvPython -m pip install --only-binary=:all: --no-index --find-links $RuntimeWheelhouse $HermesInstallSpec @InstallRequirements
if ($LASTEXITCODE -ne 0) {
  throw "pip install failed with exit code $LASTEXITCODE."
}
& $VenvPython -c "import aiohttp, fastapi, multipart, uvicorn, websockets"
if ($LASTEXITCODE -ne 0) {
  throw "Gateway dependency check failed with exit code $LASTEXITCODE."
}

$HermesExe = Join-Path $VenvDir "Scripts\hermes.exe"
if (-not (Test-Path $HermesExe)) {
  throw "Hermes executable was not created: $HermesExe"
}
$BundledSkillsDir = Join-Path $RuntimeResources "skills"
$OptionalSkillsDir = Join-Path $RuntimeResources "optional-skills"
$OptionalMcpsDir = Join-Path $RuntimeResources "optional-mcps"
$BundledLocalesDir = Join-Path $RuntimeResources "locales"
$BundledPluginsDir = Join-Path $RuntimeResources "plugins"
$WebDistDir = Join-Path $RuntimeResources "web_dist"
$TuiDir = Join-Path $RuntimeResources "tui_dist"
$HermesCacheDir = Join-Path $HermesHome "cache"
$HermesDefaultEnvironment = [ordered]@{
  "HERMES_DESKTOP_MANAGED" = "1"
  "HF_HOME" = (Join-Path $HermesCacheDir "huggingface")
  "HUGGINGFACE_HUB_CACHE" = (Join-Path $HermesCacheDir "huggingface\hub")
  "TORCH_HOME" = (Join-Path $HermesCacheDir "torch")
  "TIKTOKEN_CACHE_DIR" = (Join-Path $HermesCacheDir "tiktoken")
  "MPLCONFIGDIR" = (Join-Path $HermesCacheDir "matplotlib")
  "NLTK_DATA" = (Join-Path $HermesCacheDir "nltk")
  "PLAYWRIGHT_BROWSERS_PATH" = (Join-Path $HermesCacheDir "playwright")
  "TEMP" = (Join-Path $HermesCacheDir "tmp")
  "TMP" = (Join-Path $HermesCacheDir "tmp")
}
$HermesDefaultEnvironmentPathValues = @($HermesDefaultEnvironment.GetEnumerator() | Where-Object {
  $_.Key -ne "HERMES_DESKTOP_MANAGED"
} | ForEach-Object { $_.Value })
New-Item -ItemType Directory -Force -Path $HermesDefaultEnvironmentPathValues | Out-Null
$HermesInstallerEnvironment = [ordered]@{
  "PYTHONUTF8" = "1"
  "PYTHONIOENCODING" = "utf-8"
  "HERMES_HOME" = $HermesHome
  "HERMES_OFFLINE_HOME" = $InstallRoot
  "HERMES_PYTHON" = $VenvPython
  "HERMES_BUNDLED_SKILLS" = $BundledSkillsDir
  "HERMES_OPTIONAL_SKILLS" = $OptionalSkillsDir
  "HERMES_OPTIONAL_MCPS" = $OptionalMcpsDir
  "HERMES_BUNDLED_LOCALES" = $BundledLocalesDir
  "HERMES_BUNDLED_PLUGINS" = $BundledPluginsDir
  "HERMES_WEB_DIST" = $WebDistDir
  "HERMES_TUI_DIR" = $TuiDir
}
$HermesShimEnvironmentLines = @($HermesInstallerEnvironment.GetEnumerator() | ForEach-Object {
  'set "{0}={1}"' -f $_.Key, $_.Value
})
$HermesShimDefaultEnvironmentLines = @($HermesDefaultEnvironment.GetEnumerator() | ForEach-Object {
  'if not defined {0} set "{0}={1}"' -f $_.Key, $_.Value
})
$HermesShimUserEnvironmentLines = @(
  'if not defined ZHANCLAW_BASE_URL for /f "tokens=2,*" %%A in (''reg query HKCU\Environment /v ZHANCLAW_BASE_URL 2^>nul ^| findstr /I "ZHANCLAW_BASE_URL"'') do set "ZHANCLAW_BASE_URL=%%B"',
  'if not defined ZHANCLAW_API_KEY for /f "tokens=2,*" %%A in (''reg query HKCU\Environment /v ZHANCLAW_API_KEY 2^>nul ^| findstr /I "ZHANCLAW_API_KEY"'') do set "ZHANCLAW_API_KEY=%%B"'
)
$ShimLines = @(
  "@echo off",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('"{0}" %*' -f $HermesExe)
)
$DashboardShimLines = @(
  "@echo off",
  "title Hermes Agent Dashboard",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('"{0}" dashboard --no-open %*' -f $HermesExe)
)
$LaunchShimLines = @(
  "@echo off",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f (Join-Path $RuntimeCommands "launch_windows.ps1"))
)
$ShutdownShimLines = @(
  "@echo off",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f (Join-Path $RuntimeCommands "shutdown_windows.ps1"))
)
$UninstallShimLines = @(
  "@echo off",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f (Join-Path $RuntimeCommands "uninstall_windows.ps1"))
)
$ExeShimTemplate = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-exe-shim-{0}.exe" -f ([System.Guid]::NewGuid().ToString("N")))
New-HermesExeShimTemplate -OutputPath $ExeShimTemplate
foreach ($ShimDir in $ShimDirs) {
  # UTF-8 without BOM: cmd.exe misparses a BOM on the first line, and the
  # shims switch to code page 65001 before any line that embeds a path, so
  # non-ASCII install locations survive intact.
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes.cmd") -Lines $ShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes.bat") -Lines $ShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "dashboard.cmd") -Lines $DashboardShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "dashboard.bat") -Lines $DashboardShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes-dashboard.cmd") -Lines $DashboardShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes-dashboard.bat") -Lines $DashboardShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes-launch.cmd") -Lines $LaunchShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes-launch.bat") -Lines $LaunchShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes-shutdown.cmd") -Lines $ShutdownShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes-shutdown.bat") -Lines $ShutdownShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes-uninstall.cmd") -Lines $UninstallShimLines
  Write-Utf8NoBomLines -Path (Join-Path $ShimDir "hermes-uninstall.bat") -Lines $UninstallShimLines
  Install-HermesExeShim -ShimDir $ShimDir -TemplatePath $ExeShimTemplate
}
Remove-Item -Force $ExeShimTemplate -ErrorAction SilentlyContinue
$HermesCmd = Join-Path $BinDir "hermes.cmd"
foreach ($Entry in $HermesInstallerEnvironment.GetEnumerator()) {
  Set-Item -Path ("Env:{0}" -f $Entry.Key) -Value $Entry.Value
  if (-not $PortableMode) {
    Set-TargetUserEnvironmentVariable -Name $Entry.Key -Value $Entry.Value
  }
}
foreach ($Entry in $HermesDefaultEnvironment.GetEnumerator()) {
  if (-not [Environment]::GetEnvironmentVariable($Entry.Key, "Process")) {
    Set-Item -Path ("Env:{0}" -f $Entry.Key) -Value $Entry.Value
  }
}
foreach ($ZhanEnvName in @("ZHANCLAW_BASE_URL", "ZHANCLAW_API_KEY")) {
  if (-not [Environment]::GetEnvironmentVariable($ZhanEnvName, "Process")) {
    $ZhanEnvValue = Get-TargetUserEnvironmentVariable -Name $ZhanEnvName
    if ($ZhanEnvValue) {
      Set-Item -Path ("Env:{0}" -f $ZhanEnvName) -Value $ZhanEnvValue
    }
  }
}

$ConfigPath = Join-Path $HermesHome "config.yaml"
$LegacyConfigPath = Join-Path $LegacyHermesHome "config.yaml"
if (-not $PortableMode -and -not (Test-SamePath -Left $HermesHome -Right $LegacyHermesHome)) {
  Copy-LegacyHermesHomeFileIfMissing -TargetPath $ConfigPath -LegacyPath $LegacyConfigPath -Label "config.yaml"
}
if (-not (Test-Path $ConfigPath)) {
  Copy-Item (Join-Path $RuntimeTemplates "config.yaml") $ConfigPath
}
$ConfigureConfigScript = Join-Path $BundleDir "scripts\configure_config.py"
if (-not (Test-Path $ConfigureConfigScript)) {
  throw "Missing config migration script: $ConfigureConfigScript"
}
& $VenvPython $ConfigureConfigScript $ConfigPath
if ($LASTEXITCODE -ne 0) {
  throw "Config migration failed with exit code $LASTEXITCODE."
}

$EnvPath = Join-Path $HermesHome ".env"
$LegacyEnvPath = Join-Path $LegacyHermesHome ".env"
if (-not $PortableMode -and -not (Test-SamePath -Left $HermesHome -Right $LegacyHermesHome)) {
  Copy-LegacyHermesHomeFileIfMissing -TargetPath $EnvPath -LegacyPath $LegacyEnvPath -Label ".env"
}
if (-not (Test-Path $EnvPath)) {
  Copy-Item (Join-Path $RuntimeTemplates "env.template") $EnvPath
}
Ensure-ApiServerKey -EnvPath $EnvPath
$ZhanEnvImportPaths = @($EnvPath)
if (-not $PortableMode -and -not (Test-SamePath -Left $EnvPath -Right $LegacyEnvPath)) {
  $ZhanEnvImportPaths += $LegacyEnvPath
}
Import-ZhanClawEnvironmentFromLegacyDotEnv -EnvPaths $ZhanEnvImportPaths -PortableMode $PortableMode

Sync-BundledSkills -VenvPython $VenvPython -HermesHome $HermesHome -InstallRoot $InstallRoot -ResourcesDir $RuntimeResources
if (-not $PortableMode -and (Test-PathUnderRoot -Path $HermesHome -Root $DefaultProgramDataRoot)) {
  Set-HermesHomeAccess -Path $HermesHome -UserSid $TargetUserSid -CurrentSid $CurrentUserSid
}

if (-not $PortableMode) {
  Remove-UserPathEntries -Paths @($LegacyOfflineBinDir)
  $UserPath = Get-TargetUserEnvironmentVariable -Name "Path" -DoNotExpand
  $UserPathKind = Get-TargetUserEnvironmentValueKind -Name "Path"
  if (($UserPath -split ";") -notcontains $BinDir) {
    $PathParts = @()
    if ($UserPath) {
      $PathParts += ($UserPath -split ";") | Where-Object { $_ }
    }
    if ($PathParts -notcontains $BinDir) {
      $PathParts += $BinDir
    }
    $NewUserPath = ($PathParts | Select-Object -Unique) -join ";"
    Set-TargetUserEnvironmentVariable -Name "Path" -Value $NewUserPath -Kind $UserPathKind
  }
}

& $HermesCmd version
if ($LASTEXITCODE -ne 0) {
  throw "Hermes version check failed with exit code $LASTEXITCODE."
}

Start-HermesDashboardAfterInstall -HermesCmd $HermesCmd -Port 9119

$RuntimeInstallCommitted = $true
if ($RuntimeBackupDir -and (Test-Path $RuntimeBackupDir)) {
  try {
    Remove-InstallPath -Path $RuntimeBackupDir
  } catch {
    Write-Warning "Hermes was upgraded, but the previous runtime backup could not be removed: $RuntimeBackupDir. Error: $($_.Exception.Message)"
  }
}

Write-Host "Hermes Agent installed."
Write-Host "shim: $HermesCmd"
$LaunchCmd = Join-Path $BinDir "hermes-launch.cmd"
$ShutdownCmd = Join-Path $BinDir "hermes-shutdown.cmd"
$UninstallCmd = Join-Path $BinDir "hermes-uninstall.cmd"
Write-Host "launch: $LaunchCmd"
Write-Host "repair: $(Join-Path $BundleDir 'repair.cmd')"
Write-Host "shutdown: $ShutdownCmd"
Write-Host "uninstall: $UninstallCmd"
Write-Host "config: $ConfigPath"
Write-Host "skills: $(Join-Path $HermesHome 'skills')"
Write-Host "resources: $RuntimeResources"
if ($PortableMode) {
  Write-Host "portable: enabled"
  Write-Host "Use launch.cmd from this extracted folder to start Hermes without changing User PATH."
} else {
  Write-Host "Please reopen PowerShell for PATH changes to take effect."
}
} catch {
  if (-not $RuntimeInstallCommitted) {
    Write-Warning "Hermes install/upgrade failed. Restoring the previous runtime if one was backed up."
    if ($RuntimeBackupDir) {
      Restore-RuntimeBackup -RuntimeDir $RuntimeDir -RuntimeBackupDir $RuntimeBackupDir
    } elseif ($RuntimeRebuildStarted -and (Test-Path $RuntimeDir)) {
      Remove-InstallPath -Path $RuntimeDir
    }
  }
  throw
}
