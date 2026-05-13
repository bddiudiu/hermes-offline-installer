$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = Resolve-Path (Join-Path $ScriptDir "..")
$InstallRoot = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
$RuntimeDir = Join-Path $InstallRoot "runtime"
$BinDir = Join-Path $InstallRoot "bin"
$HermesHome = Join-Path $env:USERPROFILE ".hermes"
$VenvDir = Join-Path $RuntimeDir "venv"

New-Item -ItemType Directory -Force -Path $RuntimeDir, $BinDir, $HermesHome | Out-Null

$Wheelhouse = Join-Path $BundleDir "wheelhouse"
if (-not (Test-Path $Wheelhouse)) {
  throw "缺少 wheelhouse：$Wheelhouse"
}

Copy-Item -Recurse -Force $Wheelhouse (Join-Path $RuntimeDir "wheelhouse")
Copy-Item -Recurse -Force (Join-Path $BundleDir "templates") (Join-Path $RuntimeDir "templates")
Copy-Item -Recurse -Force (Join-Path $BundleDir "runtime") (Join-Path $RuntimeDir "bundle-runtime")

$PythonBin = $env:HERMES_PYTHON
if (-not $PythonBin) {
  $Candidates = @(
    (Join-Path $RuntimeDir "bundle-runtime\python\python.exe"),
    (Join-Path $RuntimeDir "bundle-runtime\python\bin\python.exe")
  )
  foreach ($Candidate in $Candidates) {
    if (Test-Path $Candidate) {
      $PythonBin = $Candidate
      break
    }
  }
}

if (-not $PythonBin) {
  throw "未找到包内 Python runtime。请确认 bundle\runtime\python 已包含 portable Python。"
}

& $PythonBin -m venv $VenvDir
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
& $VenvPython -m pip install --no-index --find-links (Join-Path $RuntimeDir "wheelhouse") hermes-agent croniter

$HermesCmd = Join-Path $BinDir "hermes.cmd"
$HermesExe = Join-Path $VenvDir "Scripts\hermes.exe"
Set-Content -Path $HermesCmd -Encoding ASCII -Value "@echo off`r`n`"$HermesExe`" %*`r`n"

$ConfigPath = Join-Path $HermesHome "config.yaml"
if (-not (Test-Path $ConfigPath)) {
  Copy-Item (Join-Path $RuntimeDir "templates\config.yaml") $ConfigPath
}

$EnvPath = Join-Path $HermesHome ".env"
if (-not (Test-Path $EnvPath)) {
  Copy-Item (Join-Path $RuntimeDir "templates\env.template") $EnvPath
}

$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($UserPath -split ";") -notcontains $BinDir) {
  [Environment]::SetEnvironmentVariable("Path", "$UserPath;$BinDir", "User")
}

& $HermesCmd version

Write-Host "Hermes Agent 已安装。"
Write-Host "shim: $HermesCmd"
Write-Host "config: $ConfigPath"
Write-Host "请重新打开 PowerShell 让 PATH 生效。"
