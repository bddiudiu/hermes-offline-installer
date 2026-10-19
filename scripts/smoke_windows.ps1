#requires -Version 5.1
param(
  [Parameter(Mandatory = $true)] [string] $Archive,
  [Parameter(Mandatory = $true)] [string] $LegacyTag
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Shell = Join-Path $PSHOME 'powershell.exe'
$SystemPython = (Get-Command python).Source
$Archive = (Resolve-Path $Archive).Path
$Work = Join-Path ([IO.Path]::GetTempPath()) ('hermes smoke ' + [char]0x9a8c + [char]0x6536 + '-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
$Gateway = $null
$PortHolder = $null
$SavedUserEnv = @{}
foreach ($Name in @('Path', 'HERMES_HOME', 'HERMES_OFFLINE_HOME', 'ZHANCLAW_BASE_URL', 'ZHANCLAW_API_KEY')) {
  $SavedUserEnv[$Name] = [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Expand-Bundle([string] $Zip, [string] $Destination) {
  New-Item -ItemType Directory -Path $Destination | Out-Null
  & $SystemPython -m zipfile -e $Zip $Destination
  if ($LASTEXITCODE -ne 0) { throw 'Archive extraction failed.' }
  return (Join-Path $Destination 'hermes-offline-installer-win-x64')
}

function Set-SmokeContext([string] $Name) {
  $Root = Join-Path $Work ($Name + '-runtime')
  $Data = Join-Path $Work ($Name + '-home')
  $Resources = Join-Path $Root 'runtime\hermes-resources'
  $env:HERMES_OFFLINE_HOME = $Root
  $env:HERMES_HOME = $Data
  $env:HERMES_PYTHON = Join-Path $Root 'runtime\venv\Scripts\python.exe'
  $env:HERMES_PORTABLE_MODE = '1'
  $env:HERMES_DISABLE_LAZY_INSTALLS = '1'
  $env:HERMES_NO_START_DASHBOARD = '1'
  $env:HERMES_NO_RELAUNCH = '1'
  $env:HERMES_NO_PAUSE = '1'
  $env:PYTHONUTF8 = '1'
  $env:PYTHONIOENCODING = 'utf-8'
  $env:PIP_NO_INDEX = '1'
  $env:UV_OFFLINE = '1'
  $env:ZHANCLAW_BASE_URL = 'https://example.invalid/v1'
  $env:ZHANCLAW_API_KEY = 'fixture-model-key-not-a-real-credential'
  foreach ($Pair in @(
    @('HERMES_BUNDLED_SKILLS', 'skills'), @('HERMES_OPTIONAL_SKILLS', 'optional-skills'),
    @('HERMES_OPTIONAL_MCPS', 'optional-mcps'), @('HERMES_BUNDLED_LOCALES', 'locales'),
    @('HERMES_BUNDLED_PLUGINS', 'plugins'), @('HERMES_WEB_DIST', 'web_dist'), @('HERMES_TUI_DIR', 'tui_dist')
  )) { [Environment]::SetEnvironmentVariable($Pair[0], (Join-Path $Resources $Pair[1]), 'Process') }
  return [pscustomobject]@{ Root = $Root; Data = $Data; Python = $env:HERMES_PYTHON; Source = (Join-Path $Root 'runtime\hermes-agent') }
}

function Install-Portable([string] $Bundle, [string] $Label) {
  $Status = Join-Path $Work ($Label + '-status.json')
  $Log = Join-Path $Work ($Label + '-install.log')
  & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Bundle 'installers\install_windows_silent.ps1') -Portable -StatusFile $Status -LogFile $Log
  if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $Log -Tail 60
    throw ($Label + ' offline install failed.')
  }
  $Result = Get-Content -LiteralPath $Status -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($Result.state -ne 'succeeded' -or -not $Result.ok) { throw 'Silent installer did not report success.' }
  Write-Host ($Label + ' offline install passed.')
}

function Verify-Runtime($Context, [string] $Version) {
  & $Context.Python $script:Helper verify --source $Context.Source --version $Version --home $Context.Data
  if ($LASTEXITCODE -ne 0) { throw 'Runtime/source/release identity verification failed.' }
  & $Context.Python -m pip check
  if ($LASTEXITCODE -ne 0) { throw 'Offline runtime dependency consistency failed.' }
}

function Stop-SmokeProcess($Process) {
  if ($Process -and -not $Process.HasExited) {
    & taskkill.exe /PID $Process.Id /T /F *> $null
    $Process.WaitForExit()
  }
}

function Read-Journal($Context) {
  return (Get-Content -LiteralPath (Join-Path $Context.Root '.hermes-upgrade.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

try {
  $NewBundle = Expand-Bundle $Archive (Join-Path $Work 'new-source')
  $Manifest = Get-Content -LiteralPath (Join-Path $NewBundle 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $Version = $Manifest.hermes_version
  $script:Helper = Join-Path $NewBundle 'scripts\upgrade_support.py'
  $Fresh = Set-SmokeContext 'fresh'
  Install-Portable $NewBundle 'fresh'
  Verify-Runtime $Fresh $Version
  & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $NewBundle 'scripts\verify_windows.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'Windows installation verifier failed.' }
  & $Fresh.Python -c "from hermes_cli.config import load_config, validate_config_structure; from hermes_cli.runtime_provider import resolve_runtime_provider; c=load_config(); assert not validate_config_structure(c); assert c['model']['default']=='qwen3'; assert c['security']['allow_lazy_installs'] is False; r=resolve_runtime_provider(requested='custom:zhan_ai'); assert r['api_mode']=='chat_completions'; assert r['base_url']=='https://example.invalid/v1'"
  if ($LASTEXITCODE -ne 0) { throw 'Default configuration/provider verification failed.' }
  $Gateway = Start-Process -FilePath $Fresh.Python -ArgumentList @('-m', 'hermes_cli.main', 'gateway', 'run') -WorkingDirectory $Fresh.Source -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Work 'gateway.stdout.log') -RedirectStandardError (Join-Path $Work 'gateway.stderr.log')
  & $Fresh.Python $script:Helper health --home $Fresh.Data --version $Version --timeout 180
  if ($LASTEXITCODE -ne 0) {
    Get-Content (Join-Path $Work 'gateway.stderr.log') -Tail 40
    throw 'Fresh runtime authenticated readiness failed.'
  }
  Stop-SmokeProcess $Gateway
  $Gateway = $null
  Remove-Item -LiteralPath $Fresh.Root, $Fresh.Data -Recurse -Force
  Write-Host 'Fresh portable install, configuration and authenticated readiness passed.'

  # The previous published installer is a real upgrade fixture, verified before extraction.
  $LegacyZip = Join-Path $Work 'legacy.zip'
  $LegacyHash = Join-Path $Work 'legacy.sha256'
  $LegacyUrl = 'https://github.com/bddiudiu/hermes-offline-installer/releases/download/' + $LegacyTag + '/hermes-offline-installer-win-x64.zip'
  & curl.exe --fail --location --silent --show-error --max-time 180 $LegacyUrl -o $LegacyZip
  if ($LASTEXITCODE -ne 0) { throw 'Legacy fixture download failed.' }
  & curl.exe --fail --location --silent --show-error --max-time 60 ($LegacyUrl + '.sha256') -o $LegacyHash
  if ($LASTEXITCODE -ne 0) { throw 'Legacy fixture checksum download failed.' }
  $ExpectedHash = ((Get-Content -LiteralPath $LegacyHash -Raw).Trim() -split '\s+')[0]
  if ((Get-FileHash -LiteralPath $LegacyZip -Algorithm SHA256).Hash -ne $ExpectedHash) { throw 'Legacy fixture checksum mismatch.' }
  $LegacyBundle = Expand-Bundle $LegacyZip (Join-Path $Work 'legacy-source')
  $Old = Set-SmokeContext 'existing'
  Install-Portable $LegacyBundle 'legacy'
  Verify-Runtime $Old '0.21.5'
  # Exercise preservation of a non-default selected model and a user-owned file.
  & $Old.Python -c "import os; from pathlib import Path; import yaml; p=Path(os.environ['HERMES_HOME'])/'config.yaml'; c=yaml.safe_load(p.read_text(encoding='utf-8')); c['model']['default']='upgrade-fixture-model'; c['providers']['zhan_ai']['models'].append('upgrade-fixture-model'); c['security']={'allow_lazy_installs':False}; p.write_text(yaml.safe_dump(c,sort_keys=False),encoding='utf-8')"
  if ($LASTEXITCODE -ne 0) { throw 'Legacy configuration fixture failed.' }
  $UserAsset = Join-Path $Old.Data 'USER.md'
  [IO.File]::WriteAllText($UserAsset, 'preserve this user-owned fixture', (New-Object Text.UTF8Encoding($false)))
  $ConfigBefore = (Get-FileHash (Join-Path $Old.Data 'config.yaml') -Algorithm SHA256).Hash
  $EnvBefore = (Get-FileHash (Join-Path $Old.Data '.env') -Algorithm SHA256).Hash
  $Upgrade = Join-Path $NewBundle 'installers\upgrade.ps1'
  & $Shell -NoProfile -ExecutionPolicy Bypass -File $Upgrade -InstallDir $Old.Root -HermesHome $Old.Data -SupervisorStopped -KeepStopped -WhatIf
  if ($LASTEXITCODE -ne 0) { throw 'Legacy upgrade WhatIf failed.' }

  # Occupy the API port with an unrelated process: the upgrade must roll back
  # after replacing its runtime, then succeed after that listener is removed.
  $PortHolder = Start-Process -FilePath $SystemPython -ArgumentList @('-m', 'http.server', '8642', '--bind', '127.0.0.1') -WorkingDirectory $Work -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Work 'port.stdout.log') -RedirectStandardError (Join-Path $Work 'port.stderr.log')
  Start-Sleep -Seconds 2
  if ($PortHolder.HasExited) { throw 'Could not create the occupied-port rollback fixture.' }
  $RollbackLog = Join-Path $Work 'rollback.log'
  & $Shell -NoProfile -ExecutionPolicy Bypass -File $Upgrade -InstallDir $Old.Root -HermesHome $Old.Data -SupervisorStopped -KeepStopped *> $RollbackLog
  $RollbackExit = $LASTEXITCODE
  Stop-SmokeProcess $PortHolder
  $PortHolder = $null
  if ($RollbackExit -eq 0 -or (Read-Journal $Old).phase -ne 'rolled-back') {
    Get-Content -LiteralPath $RollbackLog -Tail 30
    throw 'Occupied-port upgrade did not complete a rollback.'
  }
  if ((Get-Content -LiteralPath $RollbackLog -Raw) -notmatch 'preserved API port is occupied') {
    Get-Content -LiteralPath $RollbackLog -Tail 30
    throw 'Rollback did not reach the intended post-install failure point.'
  }
  Verify-Runtime $Old '0.21.5'
  if ((Get-FileHash (Join-Path $Old.Data 'config.yaml') -Algorithm SHA256).Hash -ne $ConfigBefore -or
      (Get-FileHash (Join-Path $Old.Data '.env') -Algorithm SHA256).Hash -ne $EnvBefore) { throw 'Rollback changed preserved configuration.' }
  Write-Host 'Real legacy runtime and home rollback passed.'

  & $Shell -NoProfile -ExecutionPolicy Bypass -File $Upgrade -InstallDir $Old.Root -HermesHome $Old.Data -SupervisorStopped -KeepStopped
  if ($LASTEXITCODE -ne 0 -or (Read-Journal $Old).phase -ne 'committed') { throw 'Legacy-to-new offline upgrade failed.' }
  Verify-Runtime $Old $Version
  & $Old.Python -c "import os; from pathlib import Path; import yaml; h=Path(os.environ['HERMES_HOME']); c=yaml.safe_load((h/'config.yaml').read_text(encoding='utf-8')); assert c['model']['default']=='upgrade-fixture-model'; assert 'upgrade-fixture-model' in c['providers']['zhan_ai']['models']; assert (h/'USER.md').read_text()=='preserve this user-owned fixture'"
  if ($LASTEXITCODE -ne 0) { throw 'Upgrade did not preserve model selection and user assets.' }
  foreach ($Name in $SavedUserEnv.Keys) {
    if ([Environment]::GetEnvironmentVariable($Name, 'User') -ne $SavedUserEnv[$Name]) { throw ('Portable validation changed user environment: ' + $Name) }
  }
  Write-Host ('PASS: Windows offline install, authenticated readiness, 0.21.5 rollback and upgrade to ' + $Version + '; config and credentials preserved.')
} finally {
  Stop-SmokeProcess $Gateway
  Stop-SmokeProcess $PortHolder
}
