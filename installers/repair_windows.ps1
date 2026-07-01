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

$LocalPortableRoot = Join-Path $BundleDirPath ".hermes-offline"
$LegacyInstallRoot = Join-Path $env:USERPROFILE ".hermes-offline"
$CustomInstallRoot = if ($env:HERMES_OFFLINE_HOME -and -not (Test-SamePath -Left $env:HERMES_OFFLINE_HOME -Right $LegacyInstallRoot)) {
  $env:HERMES_OFFLINE_HOME
} else {
  $null
}
$PortableMode = (Test-TruthyEnv -Value $env:HERMES_PORTABLE_MODE) -or ((-not $CustomInstallRoot) -and (Test-Path (Join-Path $LocalPortableRoot "bin\hermes.cmd")))

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
