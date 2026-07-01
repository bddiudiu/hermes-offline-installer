$ErrorActionPreference = "Stop"

Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = (Resolve-Path (Join-Path $ScriptDir "..") -ErrorAction SilentlyContinue)
$BundleDirPath = if ($BundleDir) { $BundleDir.Path } else { $ScriptDir }
$LocalPortableRoot = Join-Path $BundleDirPath ".hermes-offline"
$InstallRoot = if ($env:HERMES_OFFLINE_HOME) {
  $env:HERMES_OFFLINE_HOME
} elseif (Test-Path (Join-Path $LocalPortableRoot "bin\hermes.cmd")) {
  $LocalPortableRoot
} else {
  Join-Path $env:USERPROFILE ".hermes-offline"
}
$BinDir = Join-Path $InstallRoot "bin"
$HermesCmd = Join-Path $BinDir "hermes.cmd"
$DashboardPort = if ($env:HERMES_DASHBOARD_PORT) { [int] $env:HERMES_DASHBOARD_PORT } else { 9119 }

function Test-LocalTcpPort {
  param(
    [int] $Port
  )

  $Client = $null
  try {
    $Client = New-Object System.Net.Sockets.TcpClient
    $Async = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
    if (-not $Async.AsyncWaitHandle.WaitOne(500, $false)) {
      return $false
    }
    $Client.EndConnect($Async)
    return $true
  } catch {
    return $false
  } finally {
    if ($Client) {
      $Client.Close()
    }
  }
}

if (-not (Test-Path $HermesCmd)) {
  throw "Hermes command was not found: $HermesCmd. Please run install.cmd first."
}

if (Test-LocalTcpPort -Port $DashboardPort) {
  Write-Host "Hermes Dashboard is already listening on http://127.0.0.1:$DashboardPort."
  exit 0
}

Write-Host "Starting Hermes Dashboard on http://127.0.0.1:$DashboardPort ..."
if ($env:HERMES_LAUNCH_VISIBLE -eq "1" -or $env:HERMES_START_DASHBOARD_VISIBLE -eq "1") {
  Start-Process -FilePath $env:ComSpec -ArgumentList @("/k", "title Hermes Agent Dashboard && `"$HermesCmd`" dashboard --no-open") | Out-Null
} else {
  Start-Process -WindowStyle Hidden -FilePath $env:ComSpec -ArgumentList @("/c", "`"$HermesCmd`" dashboard --no-open") | Out-Null
}

Start-Sleep -Seconds 3
if (Test-LocalTcpPort -Port $DashboardPort) {
  Write-Host "Hermes Dashboard started: http://127.0.0.1:$DashboardPort"
} else {
  Write-Warning "Hermes Dashboard was launched but port $DashboardPort is not listening yet. Set HERMES_LAUNCH_VISIBLE=1 and rerun launch.cmd to inspect logs."
}
