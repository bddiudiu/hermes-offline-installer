$ErrorActionPreference = "Stop"

Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = (Resolve-Path (Join-Path $ScriptDir "..") -ErrorAction SilentlyContinue)
$BundleDirPath = if ($BundleDir) { $BundleDir.Path } else { $ScriptDir }

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

$LocalPortableRoot = Join-Path $BundleDirPath ".hermes-offline"
$LocalPortableHome = Join-Path $BundleDirPath ".hermes"
$DefaultProgramFilesRoot = if ($env:ProgramFiles) { $env:ProgramFiles } else { "C:\Program Files" }
$CurrentUserSid = Get-CurrentUserSid
$TargetUserSid = Get-InstallerTargetUserSid
$TargetUserProfile = Get-UserProfilePathFromSid -Sid $TargetUserSid
if ($TargetUserSid -ne $CurrentUserSid) {
  Write-Host "Removing User environment variables for original installer user SID: $TargetUserSid"
}
$LegacyInstallRoot = Join-Path $TargetUserProfile ".hermes-offline"
$LegacyHermesHome = Join-Path $TargetUserProfile ".hermes"
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
$PortableMode = (-not $CustomInstallRoot) -and (Test-Path (Join-Path $LocalPortableRoot "bin\hermes.cmd"))
$InstallRoot = if ($CustomInstallRoot) {
  $CustomInstallRoot
} elseif ($PortableMode) {
  $LocalPortableRoot
} else {
  Get-WindowsDefaultHermesOfflineHome
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
} elseif ($PortableMode -and (Test-Path $LocalPortableHome)) {
  $LocalPortableHome
} else {
  Get-WindowsDefaultHermesHome
}
$CompatVenvDir = Join-Path $env:USERPROFILE ".hermes-venv"
$ShimDirs = (@($BinDir) + $LegacyShimDirs) | Where-Object { $_ } | Select-Object -Unique

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

function Get-HermesProcesses {
  param(
    [string] $InstallRoot,
    [string] $RuntimeDir,
    [string] $HermesHome,
    [string[]] $ShimDirs
  )

  $MatchPaths = @($InstallRoot, $RuntimeDir, $HermesHome) + $ShimDirs | Where-Object { $_ } | Select-Object -Unique
  $CurrentPid = $PID
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
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
}

function Stop-HermesProcesses {
  param(
    [string] $InstallRoot,
    [string] $RuntimeDir,
    [string] $HermesHome,
    [string[]] $ShimDirs
  )

  $Processes = @(Get-HermesProcesses -InstallRoot $InstallRoot -RuntimeDir $RuntimeDir -HermesHome $HermesHome -ShimDirs $ShimDirs)
  if ($Processes.Count -eq 0) {
    Write-Host "No running Hermes processes found."
    return
  }

  $ProcessIds = @($Processes | Select-Object -ExpandProperty ProcessId -Unique)
  Write-Host "Stopping Hermes processes: $($ProcessIds -join ', ')"
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
    Write-Host "Hermes processes stopped."
    return
  }

  Write-Host "Forcing remaining Hermes processes to stop: $((@($StillRunning | Select-Object -ExpandProperty Id)) -join ', ')"
  foreach ($Process in $StillRunning) {
    Stop-Process -Id $Process.Id -Force -ErrorAction Stop
  }
  Write-Host "Hermes processes stopped."
}

function Remove-PathIfExists {
  param(
    [string] $Path
  )

  if (-not (Test-Path $Path)) {
    return
  }

  try {
    Remove-Item -Recurse -Force $Path -ErrorAction Stop
    Write-Host "Removed: $Path"
  } catch {
    throw "Could not remove $Path. Please close Hermes/ClawPanel and rerun uninstall.cmd. Error: $($_.Exception.Message)"
  }
}

function Remove-CompatVenvJunction {
  param(
    [string] $CompatVenvDir,
    [string] $VenvDir
  )

  if (-not (Test-Path $CompatVenvDir)) {
    return
  }

  $Item = Get-Item $CompatVenvDir -Force -ErrorAction Stop
  if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
    Write-Host "Preserved non-junction compatibility path: $CompatVenvDir"
    return
  }

  $ExpectedTarget = [System.IO.Path]::GetFullPath($VenvDir).TrimEnd('\')
  $ActualTarget = $null
  try {
    $ActualTarget = [System.IO.Path]::GetFullPath(($Item.Target | Select-Object -First 1)).TrimEnd('\')
  } catch {
  }

  if (-not $ActualTarget -or -not $ActualTarget.Equals($ExpectedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "Preserved compatibility junction with unexpected target: $CompatVenvDir"
    return
  }

  Remove-Item -Force $CompatVenvDir -ErrorAction Stop
  Write-Host "Removed compatibility junction: $CompatVenvDir"
}

function Remove-HermesShims {
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
    if (-not $ShimDir) {
      continue
    }
    foreach ($ShimName in $ShimNames) {
      $ShimPath = Join-Path $ShimDir $ShimName
      if (Test-Path $ShimPath) {
        try {
          Remove-Item -Force $ShimPath -ErrorAction Stop
          Write-Host "Removed shim: $ShimPath"
        } catch {
          Write-Warning "Could not remove shim ${ShimPath}: $($_.Exception.Message)"
        }
      }
    }
  }
}

function Remove-UserEnvironment {
  foreach ($Name in @(
    "HERMES_HOME",
    "HERMES_OFFLINE_HOME",
    "HERMES_PYTHON",
    "HERMES_BUNDLED_SKILLS",
    "HERMES_OPTIONAL_SKILLS",
    "HERMES_OPTIONAL_MCPS",
    "HERMES_BUNDLED_LOCALES",
    "HERMES_BUNDLED_PLUGINS",
    "HERMES_WEB_DIST",
    "HERMES_TUI_DIR",
    "PYTHONUTF8",
    "PYTHONIOENCODING"
  )) {
    Set-TargetUserEnvironmentVariable -Name $Name -Value $null
    Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
  }
}

function Remove-InstallRootFromUserPath {
  param(
    [string] $BinDir
  )

  $UserPath = Get-TargetUserEnvironmentVariable -Name "Path" -DoNotExpand
  if (-not $UserPath) {
    return
  }
  $UserPathKind = Get-TargetUserEnvironmentValueKind -Name "Path"

  $BinDirFull = ConvertTo-ComparablePath -Path $BinDir
  $PathParts = @()
  foreach ($Part in ($UserPath -split ";")) {
    if (-not $Part) {
      continue
    }
    $PartFull = ConvertTo-ComparablePath -Path $Part
    if (-not $PartFull.Equals($BinDirFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      $PathParts += $Part
    }
  }

  Set-TargetUserEnvironmentVariable -Name "Path" -Value (($PathParts | Select-Object -Unique) -join ";") -Kind $UserPathKind
}

if (-not $PortableMode -and (Test-PathUnderRoot -Path $InstallRoot -Root $DefaultProgramFilesRoot) -and -not (Test-IsAdministrator)) {
  throw "Windows default installation is stored under $InstallRoot and requires administrator rights to uninstall. Please right-click uninstall.cmd and choose Run as administrator."
}

Stop-HermesProcesses -InstallRoot $InstallRoot -RuntimeDir $RuntimeDir -HermesHome $HermesHome -ShimDirs $ShimDirs
Remove-HermesShims -ShimDirs $ShimDirs
Remove-CompatVenvJunction -CompatVenvDir $CompatVenvDir -VenvDir (Join-Path $RuntimeDir "venv")
Remove-PathIfExists -Path $InstallRoot
if ($env:HERMES_UNINSTALL_REMOVE_HOME -eq "1") {
  Remove-PathIfExists -Path $HermesHome
} else {
  Write-Host "Preserved Hermes user data: $HermesHome"
  Write-Host "Set HERMES_UNINSTALL_REMOVE_HOME=1 before running uninstall.cmd to remove it."
}
if (-not $PortableMode) {
  Remove-UserEnvironment
  Remove-InstallRootFromUserPath -BinDir $BinDir
  Remove-InstallRootFromUserPath -BinDir $LegacyOfflineBinDir
}

Write-Host "Hermes Agent uninstalled."
