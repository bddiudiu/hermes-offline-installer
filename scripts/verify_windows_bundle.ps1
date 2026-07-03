param(
  [Parameter(Mandatory = $true)] [string] $Archive,
  [string] $WorkDir = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Archive)) {
  throw "Missing Windows bundle archive: $Archive"
}

$ArchivePath = (Resolve-Path $Archive).Path
$CleanupWorkDir = $false
if (-not $WorkDir) {
  $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-bundle-smoke-" + [System.Guid]::NewGuid().ToString("N"))
  $CleanupWorkDir = $true
}

try {
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $WorkDir -Force

  $ExtractedRoot = Get-ChildItem -Path $WorkDir -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "installers\install_windows.ps1") } |
    Select-Object -First 1
  if (-not $ExtractedRoot) {
    throw "Could not find extracted Windows installer root in $WorkDir"
  }

  $Root = $ExtractedRoot.FullName
  $InstallPs1 = Join-Path $Root "installers\install_windows.ps1"
  $VerifyPs1 = Join-Path $Root "scripts\verify_windows.ps1"
  $BundlePython = Join-Path $Root "runtime\python\python.exe"
  if (-not (Test-Path $BundlePython)) {
    $BundlePython = Join-Path $Root "runtime\python\bin\python.exe"
  }
  if (-not (Test-Path $BundlePython)) {
    throw "Bundled Python executable was not found in $Root\runtime\python"
  }

  & $BundlePython -c "import ctypes, encodings, ensurepip, venv; print('bundle python runtime ok')"
  if ($LASTEXITCODE -ne 0) {
    throw "Bundled Python runtime import check failed with exit code $LASTEXITCODE"
  }

  $previousNoStartDashboard = $env:HERMES_NO_START_DASHBOARD
  $previousPortableMode = $env:HERMES_PORTABLE_MODE
  try {
    $env:HERMES_NO_START_DASHBOARD = "1"
    $env:HERMES_PORTABLE_MODE = "1"

    & $InstallPs1 -Portable
    if ($LASTEXITCODE -ne 0) {
      throw "Portable install failed with exit code $LASTEXITCODE"
    }

    & $VerifyPs1
    if ($LASTEXITCODE -ne 0) {
      throw "Windows verification failed with exit code $LASTEXITCODE"
    }

    $VenvPython = Join-Path $Root ".hermes-offline\runtime\venv\Scripts\python.exe"
    if (-not (Test-Path $VenvPython)) {
      throw "Portable install did not create venv Python: $VenvPython"
    }
    & $VenvPython -c "import ctypes, pip; print('venv python and pip ok')"
    if ($LASTEXITCODE -ne 0) {
      throw "Venv Python import check failed with exit code $LASTEXITCODE"
    }
    & $VenvPython -m pip --version
    if ($LASTEXITCODE -ne 0) {
      throw "Venv pip version check failed with exit code $LASTEXITCODE"
    }
    & $VenvPython -m pip check
    if ($LASTEXITCODE -ne 0) {
      throw "Venv pip dependency check failed with exit code $LASTEXITCODE"
    }
  } finally {
    if ($null -ne $previousNoStartDashboard) {
      $env:HERMES_NO_START_DASHBOARD = $previousNoStartDashboard
    } else {
      Remove-Item Env:HERMES_NO_START_DASHBOARD -ErrorAction SilentlyContinue
    }
    if ($null -ne $previousPortableMode) {
      $env:HERMES_PORTABLE_MODE = $previousPortableMode
    } else {
      Remove-Item Env:HERMES_PORTABLE_MODE -ErrorAction SilentlyContinue
    }
  }
} finally {
  if ($CleanupWorkDir -and (Test-Path $WorkDir)) {
    Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
  }
}
