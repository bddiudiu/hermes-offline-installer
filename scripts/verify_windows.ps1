$ErrorActionPreference = "Stop"

$InstallRoot = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:USERPROFILE ".hermes" }
$HermesCmd = Join-Path $InstallRoot "bin\hermes.cmd"
$Config = Join-Path $HermesHome "config.yaml"
$EnvFile = Join-Path $HermesHome ".env"

if (-not (Test-Path $HermesCmd)) { throw "缺少 hermes shim: $HermesCmd" }
if (-not (Test-Path $Config)) { throw "缺少 config.yaml" }
if (-not (Test-Path $EnvFile)) { throw "缺少 .env" }

& $HermesCmd version
