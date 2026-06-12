$ErrorActionPreference = "Stop"

Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

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
$CompatVenvDir = Join-Path $env:USERPROFILE ".hermes-venv"
$RuntimeWheelhouse = Join-Path $RuntimeDir "wheelhouse"
$RuntimeTemplates = Join-Path $RuntimeDir "templates"
$RuntimeCommands = Join-Path $RuntimeDir "commands"
$RuntimeBundle = Join-Path $RuntimeDir "bundle-runtime"
$RuntimeResources = Join-Path $RuntimeDir "hermes-resources"
$ExistingHermesCmd = Join-Path $BinDir "hermes.cmd"

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

function Stop-ExistingHermesProcesses {
  param(
    [string] $InstallRoot,
    [string] $RuntimeDir,
    [string] $HermesHome,
    [string[]] $ShimDirs
  )

  $MatchPaths = @($InstallRoot, $RuntimeDir, $HermesHome) + $ShimDirs | Where-Object { $_ } | Select-Object -Unique
  $CurrentPid = $PID
  $Processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
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

  if (-not $Processes) {
    return
  }

  $ProcessIds = @($Processes | Select-Object -ExpandProperty ProcessId -Unique)
  Write-Host "Stopping running Hermes processes before install/upgrade: $($ProcessIds -join ', ')"
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
    return
  }

  Write-Host "Forcing remaining Hermes processes to stop: $((@($StillRunning | Select-Object -ExpandProperty Id)) -join ', ')"
  foreach ($Process in $StillRunning) {
    try {
      Stop-Process -Id $Process.Id -Force -ErrorAction Stop
    } catch {
      throw "Could not stop running Hermes process $($Process.Id). Please close Hermes/ClawPanel and rerun install.cmd. Error: $($_.Exception.Message)"
    }
  }
}

function Remove-InstallPath {
  param(
    [string] $Path
  )

  if (-not (Test-Path $Path)) {
    return
  }

  try {
    Remove-Item -Recurse -Force $Path -ErrorAction Stop
  } catch {
    throw "Could not remove $Path. Please close Hermes/ClawPanel and rerun install.cmd. Error: $($_.Exception.Message)"
  }

  if (Test-Path $Path) {
    throw "Could not remove $Path. Please close Hermes/ClawPanel and rerun install.cmd."
  }
}

function Clear-PythonRuntimeEnvironment {
  Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
  Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
}

function Test-BundledPythonRuntime {
  param(
    [string] $PythonBin,
    [AllowNull()] [string] $PythonHome
  )

  Clear-PythonRuntimeEnvironment
  if ($PythonHome) {
    $env:PYTHONHOME = $PythonHome
  }

  & $PythonBin -c "import encodings, venv"
  $Succeeded = ($LASTEXITCODE -eq 0)
  Clear-PythonRuntimeEnvironment
  return $Succeeded
}

function New-HermesVenv {
  param(
    [string] $PythonBin,
    [string] $VenvDir,
    [AllowNull()] [string] $FallbackPythonHome
  )

  Clear-PythonRuntimeEnvironment
  Remove-InstallPath -Path $VenvDir
  & $PythonBin -m venv $VenvDir
  if ($LASTEXITCODE -eq 0) {
    return
  }

  $FirstExitCode = $LASTEXITCODE
  Write-Warning "Python venv creation failed with exit code $FirstExitCode using a clean Python environment. Retrying once after recreating $VenvDir."
  Clear-PythonRuntimeEnvironment
  Remove-InstallPath -Path $VenvDir
  Start-Sleep -Seconds 1
  & $PythonBin -m venv $VenvDir
  if ($LASTEXITCODE -eq 0) {
    return
  }

  $SecondExitCode = $LASTEXITCODE
  if ($FallbackPythonHome) {
    Write-Warning "Python venv creation failed again with exit code $SecondExitCode. Retrying with PYTHONHOME=$FallbackPythonHome for this process only."
    Clear-PythonRuntimeEnvironment
    $env:PYTHONHOME = $FallbackPythonHome
    Remove-InstallPath -Path $VenvDir
    & $PythonBin -m venv $VenvDir
    $ThirdExitCode = $LASTEXITCODE
    Clear-PythonRuntimeEnvironment
    if ($ThirdExitCode -eq 0) {
      return
    }
    throw "Python venv creation failed. clean exit codes: $FirstExitCode, $SecondExitCode; PYTHONHOME retry exit code: $ThirdExitCode; python: $PythonBin; target: $VenvDir"
  }

  throw "Python venv creation failed. clean exit codes: $FirstExitCode, $SecondExitCode; python: $PythonBin; target: $VenvDir"
}

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

function Start-HermesDashboard {
  param(
    [string] $HermesCmd,
    [int] $Port
  )

  if ($env:HERMES_NO_START_DASHBOARD -eq "1") {
    Write-Host "Skipping Dashboard startup because HERMES_NO_START_DASHBOARD=1."
    return
  }

  if (Test-LocalTcpPort -Port $Port) {
    Write-Host "Hermes Dashboard is already listening on http://127.0.0.1:$Port."
    return
  }

  Write-Host "Starting Hermes Dashboard on http://127.0.0.1:$Port ..."
  if ($env:HERMES_START_DASHBOARD_VISIBLE -eq "1" -or $env:HERMES_LAUNCH_VISIBLE -eq "1") {
    Start-Process -FilePath $env:ComSpec -ArgumentList @("/k", "title Hermes Agent Dashboard && `"$HermesCmd`" dashboard") | Out-Null
  } else {
    Start-Process -WindowStyle Hidden -FilePath $env:ComSpec -ArgumentList @("/c", "`"$HermesCmd`" dashboard") | Out-Null
  }
  Start-Sleep -Seconds 3
  if (Test-LocalTcpPort -Port $Port) {
    Write-Host "Hermes Dashboard started: http://127.0.0.1:$Port"
  } else {
    Write-Warning "Hermes Dashboard was launched but port $Port is not listening yet. Set HERMES_START_DASHBOARD_VISIBLE=1 and rerun install.cmd to inspect logs."
  }
}

function Ensure-HermesPythonCompatibilityPath {
  param(
    [string] $CompatVenvDir,
    [string] $VenvDir
  )

  $CompatPython = Join-Path $CompatVenvDir "Scripts\python.exe"
  if (Test-Path $CompatPython) {
    Write-Host "Hermes Python compatibility path is available: $CompatPython"
    return
  }

  if (Test-Path $CompatVenvDir) {
    Write-Warning "Hermes Python compatibility path exists but does not contain Scripts\python.exe: $CompatVenvDir"
    return
  }

  try {
    New-Item -ItemType Junction -Path $CompatVenvDir -Target $VenvDir -ErrorAction Stop | Out-Null
  } catch {
    Write-Warning "Could not create Hermes Python compatibility junction $CompatVenvDir -> $VenvDir. Error: $($_.Exception.Message)"
    return
  }

  if (Test-Path $CompatPython) {
    Write-Host "Created Hermes Python compatibility path: $CompatVenvDir"
  } else {
    Write-Warning "Hermes Python compatibility path was created but Scripts\python.exe is still unavailable: $CompatVenvDir"
  }
}

function Remove-HermesExeShim {
  param(
    [string] $ShimDir
  )

  $ShimExe = Join-Path $ShimDir "hermes.exe"
  if (-not (Test-Path $ShimExe)) {
    return
  }

  try {
    Remove-Item -Force $ShimExe -ErrorAction Stop
    Write-Host "Removed legacy Hermes exe shim: $ShimExe"
  } catch {
    throw "Could not remove legacy Hermes exe shim $ShimExe. Please close Hermes/ClawPanel and rerun install.cmd. Error: $($_.Exception.Message)"
  }
}

function Sync-BundledSkills {
  param(
    [string] $VenvPython,
    [string] $HermesHome,
    [string] $ResourcesDir
  )

  $SkillsDir = Join-Path $HermesHome "skills"
  New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
  Write-Host "Syncing bundled Agent Skills to $SkillsDir ..."

  $PreviousHermesHome = $env:HERMES_HOME
  $PreviousBundledSkills = $env:HERMES_BUNDLED_SKILLS
  $PreviousOptionalSkills = $env:HERMES_OPTIONAL_SKILLS
  $PreviousOptionalMcps = $env:HERMES_OPTIONAL_MCPS
  $PreviousBundledLocales = $env:HERMES_BUNDLED_LOCALES
  $PreviousBundledPlugins = $env:HERMES_BUNDLED_PLUGINS
  $PreviousWebDist = $env:HERMES_WEB_DIST
  $env:HERMES_HOME = $HermesHome
  $env:HERMES_BUNDLED_SKILLS = Join-Path $ResourcesDir "skills"
  $env:HERMES_OPTIONAL_SKILLS = Join-Path $ResourcesDir "optional-skills"
  $env:HERMES_OPTIONAL_MCPS = Join-Path $ResourcesDir "optional-mcps"
  $env:HERMES_BUNDLED_LOCALES = Join-Path $ResourcesDir "locales"
  $env:HERMES_BUNDLED_PLUGINS = Join-Path $ResourcesDir "plugins"
  $env:HERMES_WEB_DIST = Join-Path $ResourcesDir "web_dist"
  try {
    & $VenvPython -m tools.skills_sync
    if ($LASTEXITCODE -ne 0) {
      throw "Bundled Agent Skills sync failed with exit code $LASTEXITCODE."
    }
  } finally {
    if ($null -eq $PreviousHermesHome) {
      Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
    } else {
      $env:HERMES_HOME = $PreviousHermesHome
    }
    foreach ($EnvRestore in @(
      @("HERMES_BUNDLED_SKILLS", $PreviousBundledSkills),
      @("HERMES_OPTIONAL_SKILLS", $PreviousOptionalSkills),
      @("HERMES_OPTIONAL_MCPS", $PreviousOptionalMcps),
      @("HERMES_BUNDLED_LOCALES", $PreviousBundledLocales),
      @("HERMES_BUNDLED_PLUGINS", $PreviousBundledPlugins),
      @("HERMES_WEB_DIST", $PreviousWebDist)
    )) {
      if ($null -eq $EnvRestore[1]) {
        Remove-Item "Env:$($EnvRestore[0])" -ErrorAction SilentlyContinue
      } else {
        Set-Item -Path "Env:$($EnvRestore[0])" -Value $EnvRestore[1]
      }
    }
  }

  $OptOutMarker = Join-Path $HermesHome ".no-bundled-skills"
  if (Test-Path $OptOutMarker) {
    Write-Host "Bundled Agent Skills sync skipped because .no-bundled-skills is present."
    return
  }

  $SkillFiles = @(Get-ChildItem -Path $SkillsDir -Recurse -Filter "SKILL.md" -File -ErrorAction SilentlyContinue)
  if ($SkillFiles.Count -eq 0) {
    throw "Bundled Agent Skills were not installed into $SkillsDir."
  }
  foreach ($RequiredSkill in @(
    (Join-Path $SkillsDir "apple\imessage\SKILL.md"),
    (Join-Path $SkillsDir "autonomous-ai-agents\codex\SKILL.md")
  )) {
    if (-not (Test-Path $RequiredSkill)) {
      throw "Bundled Agent Skill is missing after sync: $RequiredSkill"
    }
  }
}

$ShimDirs = @($BinDir, $LocalBinDir, $UvToolsBinDir, $ClawPanelBinDir) | Where-Object { $_ } | Select-Object -Unique
$IsUpgrade = (Test-Path $VenvDir) -or (Test-Path $RuntimeBundle) -or (Test-Path $ExistingHermesCmd)
if ($IsUpgrade) {
  Write-Host "Existing Hermes offline installation detected. Running upgrade."
} else {
  Write-Host "No existing Hermes offline installation detected. Running install."
}
$InstallDirs = @($RuntimeDir, $HermesHome) + $ShimDirs
New-Item -ItemType Directory -Force -Path $InstallDirs | Out-Null

$Wheelhouse = Join-Path $BundleDir "wheelhouse"
if (-not (Test-Path $Wheelhouse)) {
  throw "Missing wheelhouse: $Wheelhouse"
}
$BundledResources = Join-Path $BundleDir "hermes-resources"
if (-not (Test-Path $BundledResources)) {
  throw "Missing Hermes runtime resources: $BundledResources"
}

Stop-ExistingHermesProcesses -InstallRoot $InstallRoot -RuntimeDir $RuntimeDir -HermesHome $HermesHome -ShimDirs $ShimDirs
foreach ($Path in @($RuntimeWheelhouse, $RuntimeTemplates, $RuntimeCommands, $RuntimeBundle, $RuntimeResources, $VenvDir)) {
  Remove-InstallPath -Path $Path
}
Copy-Item -Recurse -Force $Wheelhouse $RuntimeWheelhouse
Copy-Item -Recurse -Force (Join-Path $BundleDir "templates") $RuntimeTemplates
New-Item -ItemType Directory -Force -Path $RuntimeCommands | Out-Null
Copy-Item -Force (Join-Path $ScriptDir "launch_windows.ps1") (Join-Path $RuntimeCommands "launch_windows.ps1")
Copy-Item -Force (Join-Path $ScriptDir "shutdown_windows.ps1") (Join-Path $RuntimeCommands "shutdown_windows.ps1")
Copy-Item -Recurse -Force (Join-Path $BundleDir "runtime") $RuntimeBundle
Copy-Item -Recurse -Force $BundledResources $RuntimeResources

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

$BundledPythonHome = Split-Path -Parent $PythonBin
$PythonRuntimeNeedsPythonHome = $false
if (-not (Test-BundledPythonRuntime -PythonBin $PythonBin -PythonHome $null)) {
  $EncodingsDir = Get-ChildItem -Path $BundledPythonHome -Recurse -Directory -Filter "encodings" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (Test-BundledPythonRuntime -PythonBin $PythonBin -PythonHome $BundledPythonHome) {
    $PythonRuntimeNeedsPythonHome = $true
  } else {
    $PythonZip = Join-Path $BundledPythonHome "python311.zip"
    $LibEncodings = Join-Path $BundledPythonHome "Lib\encodings"
    throw "Bundled Python failed to import encodings. PYTHONHOME=$BundledPythonHome; python311.zip exists=$(Test-Path $PythonZip); Lib\encodings exists=$(Test-Path $LibEncodings); discovered encodings=$($EncodingsDir.FullName)"
  }
}

$FallbackPythonHome = if ($PythonRuntimeNeedsPythonHome) { $BundledPythonHome } else { $null }
New-HermesVenv -PythonBin $PythonBin -VenvDir $VenvDir -FallbackPythonHome $FallbackPythonHome
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path (Join-Path $VenvDir "pyvenv.cfg")) -or -not (Test-Path $VenvPython)) {
  throw "Python venv was not created correctly: $VenvDir"
}
$RuntimePackages = @(
  "aiohttp==3.13.4",
  "fastapi==0.133.1",
  "python-multipart",
  "uvicorn==0.41.0",
  "websockets"
)
& $VenvPython -m pip install --only-binary=:all: --no-index --find-links $RuntimeWheelhouse "hermes-agent[all]" croniter @RuntimePackages
if ($LASTEXITCODE -ne 0) {
  throw "pip install failed with exit code $LASTEXITCODE."
}
& $VenvPython -c "import aiohttp, fastapi, multipart, uvicorn, websockets"
if ($LASTEXITCODE -ne 0) {
  throw "Gateway dependency check failed with exit code $LASTEXITCODE."
}

$HermesExe = Join-Path $VenvDir "Scripts\hermes.exe"
if (-not (Test-Path $HermesExe)) {
  throw "Hermes executable was not created: $HermesExe"
}
$BundledSkillsDir = Join-Path $RuntimeResources "skills"
$OptionalSkillsDir = Join-Path $RuntimeResources "optional-skills"
$OptionalMcpsDir = Join-Path $RuntimeResources "optional-mcps"
$BundledLocalesDir = Join-Path $RuntimeResources "locales"
$BundledPluginsDir = Join-Path $RuntimeResources "plugins"
$WebDistDir = Join-Path $RuntimeResources "web_dist"
$ShimLines = @(
  "@echo off",
  "chcp 65001 >nul",
  'set "PYTHONUTF8=1"',
  'set "PYTHONIOENCODING=utf-8"',
  ('set "HERMES_HOME={0}"' -f $HermesHome),
  ('set "HERMES_PYTHON={0}"' -f $VenvPython),
  ('set "HERMES_BUNDLED_SKILLS={0}"' -f $BundledSkillsDir),
  ('set "HERMES_OPTIONAL_SKILLS={0}"' -f $OptionalSkillsDir),
  ('set "HERMES_OPTIONAL_MCPS={0}"' -f $OptionalMcpsDir),
  ('set "HERMES_BUNDLED_LOCALES={0}"' -f $BundledLocalesDir),
  ('set "HERMES_BUNDLED_PLUGINS={0}"' -f $BundledPluginsDir),
  ('set "HERMES_WEB_DIST={0}"' -f $WebDistDir),
  ('"{0}" %*' -f $HermesExe)
)
$DashboardShimLines = @(
  "@echo off",
  "title Hermes Agent Dashboard",
  "chcp 65001 >nul",
  'set "PYTHONUTF8=1"',
  'set "PYTHONIOENCODING=utf-8"',
  ('set "HERMES_HOME={0}"' -f $HermesHome),
  ('set "HERMES_PYTHON={0}"' -f $VenvPython),
  ('set "HERMES_BUNDLED_SKILLS={0}"' -f $BundledSkillsDir),
  ('set "HERMES_OPTIONAL_SKILLS={0}"' -f $OptionalSkillsDir),
  ('set "HERMES_OPTIONAL_MCPS={0}"' -f $OptionalMcpsDir),
  ('set "HERMES_BUNDLED_LOCALES={0}"' -f $BundledLocalesDir),
  ('set "HERMES_BUNDLED_PLUGINS={0}"' -f $BundledPluginsDir),
  ('set "HERMES_WEB_DIST={0}"' -f $WebDistDir),
  ('"{0}" dashboard %*' -f $HermesExe)
)
$LaunchShimLines = @(
  "@echo off",
  ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f (Join-Path $RuntimeCommands "launch_windows.ps1"))
)
$ShutdownShimLines = @(
  "@echo off",
  ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f (Join-Path $RuntimeCommands "shutdown_windows.ps1"))
)
foreach ($ShimDir in $ShimDirs) {
  Set-Content -Path (Join-Path $ShimDir "hermes.cmd") -Encoding ASCII -Value $ShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes.bat") -Encoding ASCII -Value $ShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-dashboard.cmd") -Encoding ASCII -Value $DashboardShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-dashboard.bat") -Encoding ASCII -Value $DashboardShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-launch.cmd") -Encoding ASCII -Value $LaunchShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-launch.bat") -Encoding ASCII -Value $LaunchShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-shutdown.cmd") -Encoding ASCII -Value $ShutdownShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-shutdown.bat") -Encoding ASCII -Value $ShutdownShimLines
  Remove-HermesExeShim -ShimDir $ShimDir
}
$HermesCmd = Join-Path $BinDir "hermes.cmd"
$env:HERMES_HOME = $HermesHome
$env:HERMES_OFFLINE_HOME = $InstallRoot
$env:HERMES_PYTHON = $VenvPython
$env:HERMES_BUNDLED_SKILLS = $BundledSkillsDir
$env:HERMES_OPTIONAL_SKILLS = $OptionalSkillsDir
$env:HERMES_OPTIONAL_MCPS = $OptionalMcpsDir
$env:HERMES_BUNDLED_LOCALES = $BundledLocalesDir
$env:HERMES_BUNDLED_PLUGINS = $BundledPluginsDir
$env:HERMES_WEB_DIST = $WebDistDir
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
[Environment]::SetEnvironmentVariable("HERMES_HOME", $HermesHome, "User")
[Environment]::SetEnvironmentVariable("HERMES_OFFLINE_HOME", $InstallRoot, "User")
[Environment]::SetEnvironmentVariable("HERMES_PYTHON", $VenvPython, "User")
[Environment]::SetEnvironmentVariable("HERMES_BUNDLED_SKILLS", $BundledSkillsDir, "User")
[Environment]::SetEnvironmentVariable("HERMES_OPTIONAL_SKILLS", $OptionalSkillsDir, "User")
[Environment]::SetEnvironmentVariable("HERMES_OPTIONAL_MCPS", $OptionalMcpsDir, "User")
[Environment]::SetEnvironmentVariable("HERMES_BUNDLED_LOCALES", $BundledLocalesDir, "User")
[Environment]::SetEnvironmentVariable("HERMES_BUNDLED_PLUGINS", $BundledPluginsDir, "User")
[Environment]::SetEnvironmentVariable("HERMES_WEB_DIST", $WebDistDir, "User")
[Environment]::SetEnvironmentVariable("PYTHONUTF8", "1", "User")
[Environment]::SetEnvironmentVariable("PYTHONIOENCODING", "utf-8", "User")
Ensure-HermesPythonCompatibilityPath -CompatVenvDir $CompatVenvDir -VenvDir $VenvDir

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

Sync-BundledSkills -VenvPython $VenvPython -HermesHome $HermesHome -ResourcesDir $RuntimeResources

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

Start-HermesDashboard -HermesCmd $HermesCmd -Port 9119

Write-Host "Hermes Agent installed."
Write-Host "shim: $HermesCmd"
$LaunchCmd = Join-Path $BinDir "hermes-launch.cmd"
$ShutdownCmd = Join-Path $BinDir "hermes-shutdown.cmd"
Write-Host "launch: $LaunchCmd"
Write-Host "shutdown: $ShutdownCmd"
Write-Host "config: $ConfigPath"
Write-Host "skills: $(Join-Path $HermesHome 'skills')"
Write-Host "resources: $RuntimeResources"
Write-Host "Please reopen PowerShell for PATH changes to take effect."
