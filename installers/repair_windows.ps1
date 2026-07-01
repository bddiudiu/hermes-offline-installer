$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = (Resolve-Path (Join-Path $ScriptDir "..") -ErrorAction SilentlyContinue)
$BundleDirPath = if ($BundleDir) { $BundleDir.Path } else { $ScriptDir }
$InstallPs1 = Join-Path $ScriptDir "install_windows.ps1"

if (-not (Test-Path $InstallPs1)) {
  $InstallPs1 = Join-Path $BundleDirPath "installers\install_windows.ps1"
}
if (-not (Test-Path $InstallPs1)) {
  throw "Missing installer PowerShell script: $InstallPs1"
}

function Test-TruthyEnv {
  param(
    [AllowNull()] [string] $Value
  )

  if (-not $Value) {
    return $false
  }
  return @("1", "true", "yes", "on") -contains $Value.Trim().ToLowerInvariant()
}

$LocalPortableRoot = Join-Path $BundleDirPath ".hermes-offline"
$PortableMode = (Test-TruthyEnv -Value $env:HERMES_PORTABLE_MODE) -or ((-not $env:HERMES_OFFLINE_HOME) -and (Test-Path (Join-Path $LocalPortableRoot "bin\hermes.cmd")))

$PreviousNoStart = $env:HERMES_NO_START_DASHBOARD
if (-not (Test-TruthyEnv -Value $env:HERMES_REPAIR_START_DASHBOARD)) {
  $env:HERMES_NO_START_DASHBOARD = "1"
}

try {
  $ForwardArgs = @($args)
  if ($PortableMode -and ($ForwardArgs -notcontains "-Portable")) {
    $ForwardArgs = @("-Portable") + $ForwardArgs
  }

  Write-Host "Repairing Hermes offline installation..."
  if ($PortableMode) {
    Write-Host "Portable mode detected: $LocalPortableRoot"
  }
  & $InstallPs1 @ForwardArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Repair install failed with exit code $LASTEXITCODE."
  }
} finally {
  if ($null -eq $PreviousNoStart) {
    Remove-Item Env:HERMES_NO_START_DASHBOARD -ErrorAction SilentlyContinue
  } else {
    $env:HERMES_NO_START_DASHBOARD = $PreviousNoStart
  }
}

Write-Host "Hermes repair finished."
