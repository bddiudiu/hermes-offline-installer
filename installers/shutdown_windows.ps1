$ErrorActionPreference = "Stop"

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

function Get-WindowsDefaultHermesHome {
  $ProgramDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
  return (Join-Path $ProgramDataRoot "SSC\Hermes")
}

function Get-WindowsDefaultHermesOfflineHome {
  $ProgramFilesRoot = if ($env:ProgramFiles) { $env:ProgramFiles } else { "C:\Program Files" }
  return (Join-Path $ProgramFilesRoot "StarSoftComm\ZhanClaw\Hermes")
}

$LocalPortableRoot = Join-Path $BundleDirPath ".hermes-offline"
$LocalPortableHome = Join-Path $BundleDirPath ".hermes"
$LegacyInstallRoot = Join-Path $env:USERPROFILE ".hermes-offline"
$LegacyHermesHome = Join-Path $env:USERPROFILE ".hermes"
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
    if ($Name -in @("hermes.exe", "hermes-agent.exe") -and ($MatchesKnownPath -or (
      $CommandLine -and $CommandLine.IndexOf("hermes", [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    ))) {
      return $true
    }
    if ($Name -in @("python.exe", "pythonw.exe", "uv.exe", "uvicorn.exe") -and (
      $MatchesKnownPath -or
      ($CommandLine -and $CommandLine.IndexOf("hermes", [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    )) {
      return $true
    }
    return $false
  }
}

$Processes = @(Get-HermesProcesses -InstallRoot $InstallRoot -RuntimeDir $RuntimeDir -HermesHome $HermesHome -ShimDirs $ShimDirs)
if ($Processes.Count -eq 0) {
  Write-Host "No running Hermes processes found."
  exit 0
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
  exit 0
}

Write-Host "Forcing remaining Hermes processes to stop: $((@($StillRunning | Select-Object -ExpandProperty Id)) -join ', ')"
foreach ($Process in $StillRunning) {
  Stop-Process -Id $Process.Id -Force -ErrorAction Stop
}
Write-Host "Hermes processes stopped."
