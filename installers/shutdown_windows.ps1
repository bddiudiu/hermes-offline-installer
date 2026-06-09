$ErrorActionPreference = "Stop"

$InstallRoot = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
$RuntimeDir = Join-Path $InstallRoot "runtime"
$BinDir = Join-Path $InstallRoot "bin"
$LocalBinDir = Join-Path $env:USERPROFILE ".local\bin"
$UvToolsBinDir = if ($env:APPDATA) { Join-Path $env:APPDATA "uv\tools\bin" } else { $null }
$ClawPanelBinDir = if ($env:APPDATA) { Join-Path $env:APPDATA "clawpanel\bin" } else { $null }
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:USERPROFILE ".hermes" }
$ShimDirs = @($BinDir, $LocalBinDir, $UvToolsBinDir, $ClawPanelBinDir) | Where-Object { $_ } | Select-Object -Unique

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
