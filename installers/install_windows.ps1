$ErrorActionPreference = "Stop"

Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = Resolve-Path (Join-Path $ScriptDir "..")
$InstallRoot = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
$RuntimeDir = Join-Path $InstallRoot "runtime"
$BinDir = Join-Path $InstallRoot "bin"
$LocalBinDir = Join-Path $env:USERPROFILE ".local\bin"
$UvToolsBinDir = if ($env:APPDATA) { Join-Path $env:APPDATA "uv\tools\bin" } else { $null }
$ClawPanelBinDir = if ($env:APPDATA) { Join-Path $env:APPDATA "clawpanel\bin" } else { $null }
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:USERPROFILE ".hermes" }
$VenvDir = Join-Path $RuntimeDir "venv"
$RuntimeWheelhouse = Join-Path $RuntimeDir "wheelhouse"
$RuntimeTemplates = Join-Path $RuntimeDir "templates"
$RuntimeBundle = Join-Path $RuntimeDir "bundle-runtime"

$ShimDirs = @($BinDir, $LocalBinDir, $UvToolsBinDir, $ClawPanelBinDir) | Where-Object { $_ } | Select-Object -Unique
$InstallDirs = @($RuntimeDir, $HermesHome) + $ShimDirs
New-Item -ItemType Directory -Force -Path $InstallDirs | Out-Null

$Wheelhouse = Join-Path $BundleDir "wheelhouse"
if (-not (Test-Path $Wheelhouse)) {
  throw "Missing wheelhouse: $Wheelhouse"
}

Remove-Item -Recurse -Force $RuntimeWheelhouse, $RuntimeTemplates, $RuntimeBundle, $VenvDir -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force $Wheelhouse $RuntimeWheelhouse
Copy-Item -Recurse -Force (Join-Path $BundleDir "templates") $RuntimeTemplates
Copy-Item -Recurse -Force (Join-Path $BundleDir "runtime") $RuntimeBundle

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

& $PythonBin -c "import encodings"
if ($LASTEXITCODE -ne 0) {
  throw "Bundled Python failed to import the standard library encodings module. Check PYTHONHOME/PYTHONPATH and the bundled runtime."
}

& $PythonBin -m venv $VenvDir
if ($LASTEXITCODE -ne 0) {
  throw "Python venv creation failed with exit code $LASTEXITCODE."
}
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path (Join-Path $VenvDir "pyvenv.cfg")) -or -not (Test-Path $VenvPython)) {
  throw "Python venv was not created correctly: $VenvDir"
}
$RuntimePackages = @(
  "aiohttp==3.13.3",
  "fastapi==0.133.1",
  "uvicorn==0.41.0",
  "websockets"
)
& $VenvPython -m pip install --only-binary=:all: --no-index --find-links $RuntimeWheelhouse hermes-agent croniter @RuntimePackages
if ($LASTEXITCODE -ne 0) {
  throw "pip install failed with exit code $LASTEXITCODE."
}
& $VenvPython -c "import aiohttp, fastapi, uvicorn, websockets"
if ($LASTEXITCODE -ne 0) {
  throw "Gateway dependency check failed with exit code $LASTEXITCODE."
}

$HermesExe = Join-Path $VenvDir "Scripts\hermes.exe"
if (-not (Test-Path $HermesExe)) {
  throw "Hermes executable was not created: $HermesExe"
}
$ShimLines = @(
  "@echo off",
  ('set "HERMES_HOME={0}"' -f $HermesHome),
  ('set "HERMES_PYTHON={0}"' -f $VenvPython),
  ('"{0}" %*' -f $HermesExe)
)
foreach ($ShimDir in $ShimDirs) {
  Set-Content -Path (Join-Path $ShimDir "hermes.cmd") -Encoding ASCII -Value $ShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes.bat") -Encoding ASCII -Value $ShimLines
  Copy-Item -Force $HermesExe (Join-Path $ShimDir "hermes.exe")
}
$HermesCmd = Join-Path $BinDir "hermes.cmd"
$env:HERMES_HOME = $HermesHome
$env:HERMES_OFFLINE_HOME = $InstallRoot
$env:HERMES_PYTHON = $VenvPython
[Environment]::SetEnvironmentVariable("HERMES_HOME", $HermesHome, "User")
[Environment]::SetEnvironmentVariable("HERMES_OFFLINE_HOME", $InstallRoot, "User")
[Environment]::SetEnvironmentVariable("HERMES_PYTHON", $VenvPython, "User")

$ConfigPath = Join-Path $HermesHome "config.yaml"
if (-not (Test-Path $ConfigPath)) {
  Copy-Item (Join-Path $RuntimeTemplates "config.yaml") $ConfigPath
}

$EnvPath = Join-Path $HermesHome ".env"
if (-not (Test-Path $EnvPath)) {
  Copy-Item (Join-Path $RuntimeTemplates "env.template") $EnvPath
}

$EnvLines = Get-Content $EnvPath -ErrorAction SilentlyContinue
$CustomApiKeyLine = $EnvLines | Where-Object { $_ -match '^\s*CUSTOM_API_KEY\s*=' } | Select-Object -First 1
$OpenAiApiKeyLine = $EnvLines | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1
if ($CustomApiKeyLine -and -not $OpenAiApiKeyLine) {
  $CustomApiKeyValue = $CustomApiKeyLine -replace '^\s*CUSTOM_API_KEY\s*=', ''
  Add-Content -Path $EnvPath -Encoding UTF8 -Value "OPENAI_API_KEY=$CustomApiKeyValue"
  Write-Host "Added OPENAI_API_KEY from existing CUSTOM_API_KEY for Hermes provider detection."
}

$OpenAiBaseUrlLine = $EnvLines | Where-Object { $_ -match '^\s*OPENAI_BASE_URL\s*=' } | Select-Object -First 1
$CustomBaseUrlLine = $EnvLines | Where-Object { $_ -match '^\s*CUSTOM_BASE_URL\s*=' } | Select-Object -First 1
if ($OpenAiBaseUrlLine -and -not $CustomBaseUrlLine) {
  $OpenAiBaseUrlValue = $OpenAiBaseUrlLine -replace '^\s*OPENAI_BASE_URL\s*=', ''
  Add-Content -Path $EnvPath -Encoding UTF8 -Value "CUSTOM_BASE_URL=$OpenAiBaseUrlValue"
  Write-Host "Added CUSTOM_BASE_URL from existing OPENAI_BASE_URL for custom endpoint detection."
}

$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($UserPath -split ";") -notcontains $BinDir -or ($UserPath -split ";") -notcontains $LocalBinDir) {
  $PathParts = @()
  if ($UserPath) {
    $PathParts += ($UserPath -split ";") | Where-Object { $_ }
  }
  foreach ($PathDir in @($BinDir, $LocalBinDir)) {
    if ($PathParts -notcontains $PathDir) {
      $PathParts += $PathDir
    }
  }
  $NewUserPath = ($PathParts | Select-Object -Unique) -join ";"
  [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
}

& $HermesCmd version
if ($LASTEXITCODE -ne 0) {
  throw "Hermes version check failed with exit code $LASTEXITCODE."
}

Write-Host "Hermes Agent installed."
Write-Host "shim: $HermesCmd"
Write-Host "config: $ConfigPath"
Write-Host "Please reopen PowerShell for PATH changes to take effect."
