$ErrorActionPreference = "Stop"

$HermesCmd = Join-Path $env:USERPROFILE ".hermes-offline\bin\hermes.cmd"
$Config = Join-Path $env:USERPROFILE ".hermes\config.yaml"
$EnvFile = Join-Path $env:USERPROFILE ".hermes\.env"

if (-not (Test-Path $HermesCmd)) { throw "缺少 hermes shim: $HermesCmd" }
if (-not (Test-Path $Config)) { throw "缺少 config.yaml" }
if (-not (Test-Path $EnvFile)) { throw "缺少 .env" }

& $HermesCmd version
