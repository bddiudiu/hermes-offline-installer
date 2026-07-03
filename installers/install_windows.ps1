param(
  [switch] $Portable
)

$ErrorActionPreference = "Stop"

Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path

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

function Test-PathUnderRoot {
  param(
    [AllowNull()] [string] $Path,
    [AllowNull()] [string] $Root
  )

  $ComparablePath = ConvertTo-ComparablePath -Path $Path
  $ComparableRoot = ConvertTo-ComparablePath -Path $Root
  if (-not $ComparablePath -or -not $ComparableRoot) {
    return $false
  }
  return (
    $ComparablePath.Equals($ComparableRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $ComparablePath.StartsWith($ComparableRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)
  )
}

function Get-WindowsDefaultHermesHome {
  $ProgramDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
  return (Join-Path $ProgramDataRoot "SSC\Hermes")
}

function Get-WindowsDefaultHermesOfflineHome {
  $ProgramFilesRoot = if ($env:ProgramFiles) { $env:ProgramFiles } else { "C:\Program Files" }
  return (Join-Path $ProgramFilesRoot "StarSoftComm\ZhanClaw\Hermes")
}

function Test-IsAdministrator {
  $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = [System.Security.Principal.WindowsPrincipal]::new($Identity)
  return $Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Grant-HermesHomeAccess {
  param(
    [string] $Path
  )

  if (-not (Get-Command icacls.exe -ErrorAction SilentlyContinue)) {
    Write-Warning "icacls.exe was not found; could not grant standard Users modify access to $Path."
    return
  }

  & icacls.exe $Path /grant "*S-1-5-32-545:(OI)(CI)M" /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not grant standard Users modify access to $Path. Hermes may need administrator rights to write config, logs, or caches."
  }
}

$DefaultHermesHome = Get-WindowsDefaultHermesHome
$DefaultInstallRoot = Get-WindowsDefaultHermesOfflineHome
$DefaultProgramDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
$DefaultProgramFilesRoot = if ($env:ProgramFiles) { $env:ProgramFiles } else { "C:\Program Files" }
$LegacyHermesHome = Join-Path $env:USERPROFILE ".hermes"
$LegacyInstallRoot = Join-Path $env:USERPROFILE ".hermes-offline"
$LegacyOfflineBinDir = Join-Path $LegacyInstallRoot "bin"
$CustomInstallRoot = if ($env:HERMES_OFFLINE_HOME -and -not (Test-SamePath -Left $env:HERMES_OFFLINE_HOME -Right $LegacyInstallRoot)) {
  $env:HERMES_OFFLINE_HOME
} else {
  $null
}
$CustomHermesHome = if ($env:HERMES_HOME -and -not (Test-SamePath -Left $env:HERMES_HOME -Right $LegacyHermesHome)) {
  $env:HERMES_HOME
} else {
  $null
}

$LocalPortableRoot = Join-Path $BundleDir ".hermes-offline"
$ExistingPortableInstall = Test-Path (Join-Path $LocalPortableRoot "bin\hermes.cmd")
$PortableMode = [bool] $Portable -or (Test-TruthyEnv -Value $env:HERMES_PORTABLE_MODE) -or ((-not $CustomInstallRoot) -and $ExistingPortableInstall)
$InstallRoot = if ($CustomInstallRoot) {
  $CustomInstallRoot
} elseif ($PortableMode) {
  $LocalPortableRoot
} else {
  $DefaultInstallRoot
}
$RuntimeDir = Join-Path $InstallRoot "runtime"
$BinDir = Join-Path $InstallRoot "bin"
$LegacyShimDirs = @((Join-Path $env:USERPROFILE ".local\bin"), $LegacyOfflineBinDir)
if ($env:APPDATA) {
  $LegacyShimDirs += (Join-Path $env:APPDATA "uv\tools\bin")
  $LegacyShimDirs += (Join-Path $env:APPDATA "clawpanel\bin")
}
$LegacyShimDirs = $LegacyShimDirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
$HermesHome = if ($CustomHermesHome) {
  $CustomHermesHome
} elseif ($PortableMode) {
  Join-Path $BundleDir ".hermes"
} else {
  $DefaultHermesHome
}
$VenvDir = Join-Path $RuntimeDir "venv"
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

  & $PythonBin -c "import encodings, ensurepip, venv"
  $Succeeded = ($LASTEXITCODE -eq 0)
  Clear-PythonRuntimeEnvironment
  return $Succeeded
}

function Invoke-HermesVenvAttempt {
  param(
    [string] $PythonBin,
    [string] $VenvDir,
    [AllowNull()] [string] $PythonHome
  )

  Clear-PythonRuntimeEnvironment
  if ($PythonHome) {
    $env:PYTHONHOME = $PythonHome
  }
  Remove-InstallPath -Path $VenvDir
  & $PythonBin -m venv --without-pip $VenvDir
  $VenvExitCode = $LASTEXITCODE
  Clear-PythonRuntimeEnvironment
  if ($VenvExitCode -ne 0) {
    return [pscustomobject]@{
      Succeeded = $false
      Stage = "venv"
      Summary = "venv exit code $VenvExitCode"
      Details = ""
    }
  }

  $VenvPython = Join-Path $VenvDir "Scripts\python.exe"
  try {
    Invoke-HermesEnsurePip -VenvPython $VenvPython -PythonHome $PythonHome
    return [pscustomobject]@{
      Succeeded = $true
      Stage = "complete"
      Summary = "ok"
      Details = ""
    }
  } catch {
    $Message = $_.Exception.Message
    $FirstLine = $Message
    $LineBreakIndex = $FirstLine.IndexOf("`n")
    if ($LineBreakIndex -ge 0) {
      $FirstLine = $FirstLine.Substring(0, $LineBreakIndex).TrimEnd("`r")
    }
    return [pscustomobject]@{
      Succeeded = $false
      Stage = "ensurepip"
      Summary = "ensurepip failed: $FirstLine"
      Details = $Message
    }
  } finally {
    Clear-PythonRuntimeEnvironment
  }
}

function New-HermesVenv {
  param(
    [string] $PythonBin,
    [string] $VenvDir,
    [AllowNull()] [string] $FallbackPythonHome
  )

  $FirstResult = Invoke-HermesVenvAttempt -PythonBin $PythonBin -VenvDir $VenvDir -PythonHome $null
  if ($FirstResult.Succeeded) {
    return
  }

  Write-Warning "Python venv bootstrap failed using a clean Python environment ($($FirstResult.Summary)). Retrying once after recreating $VenvDir."
  Start-Sleep -Seconds 1
  $SecondResult = Invoke-HermesVenvAttempt -PythonBin $PythonBin -VenvDir $VenvDir -PythonHome $null
  if ($SecondResult.Succeeded) {
    return
  }

  if ($FallbackPythonHome) {
    Write-Warning "Python venv bootstrap failed again ($($SecondResult.Summary)). Retrying with PYTHONHOME=$FallbackPythonHome for this process only."
    $ThirdResult = Invoke-HermesVenvAttempt -PythonBin $PythonBin -VenvDir $VenvDir -PythonHome $FallbackPythonHome
    if ($ThirdResult.Succeeded) {
      return
    }
    throw "Python venv creation failed. clean attempts: $($FirstResult.Summary); $($SecondResult.Summary); PYTHONHOME retry: $($ThirdResult.Summary); python: $PythonBin; target: $VenvDir"
  }

  throw "Python venv creation failed. clean attempts: $($FirstResult.Summary); $($SecondResult.Summary); python: $PythonBin; target: $VenvDir"
}

function Invoke-NativeCommandCaptured {
  param(
    [string] $FilePath,
    [string[]] $Arguments
  )

  $StdoutPath = [System.IO.Path]::GetTempFileName()
  $StderrPath = [System.IO.Path]::GetTempFileName()
  try {
    $Process = Start-Process `
      -FilePath $FilePath `
      -ArgumentList $Arguments `
      -NoNewWindow `
      -Wait `
      -PassThru `
      -RedirectStandardOutput $StdoutPath `
      -RedirectStandardError $StderrPath
    $Output = @()
    if (Test-Path $StdoutPath) {
      $Output += @(Get-Content -Path $StdoutPath -ErrorAction SilentlyContinue)
    }
    if (Test-Path $StderrPath) {
      $Output += @(Get-Content -Path $StderrPath -ErrorAction SilentlyContinue)
    }
    return [pscustomobject]@{
      ExitCode = $Process.ExitCode
      Output = $Output
    }
  } finally {
    Remove-Item -Force $StdoutPath, $StderrPath -ErrorAction SilentlyContinue
  }
}

function Invoke-HermesEnsurePip {
  param(
    [string] $VenvPython,
    [AllowNull()] [string] $PythonHome
  )

  if (-not (Test-Path $VenvPython)) {
    throw "Python venv executable was not created: $VenvPython"
  }

  $LastResult = $null
  for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
    Clear-PythonRuntimeEnvironment
    if ($PythonHome) {
      $env:PYTHONHOME = $PythonHome
    }
    $LastResult = Invoke-NativeCommandCaptured `
      -FilePath $VenvPython `
      -Arguments @("-m", "ensurepip", "--upgrade", "--default-pip")
    Clear-PythonRuntimeEnvironment
    if ($LastResult.ExitCode -eq 0) {
      return
    }
    if ($Attempt -lt 3) {
      $NextAttempt = $Attempt + 1
      Write-Warning "Python ensurepip failed with exit code $($LastResult.ExitCode). Retrying attempt $NextAttempt of 3 ..."
      Start-Sleep -Seconds $Attempt
    }
  }

  $Details = ""
  if ($LastResult -and $LastResult.Output) {
    $Details = (($LastResult.Output | Select-Object -Last 30) -join "`n")
  }
  throw "Python ensurepip failed after 3 attempts with exit code $($LastResult.ExitCode). python: $VenvPython`n$Details"
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
    Start-Process -FilePath $env:ComSpec -ArgumentList @("/k", "title Hermes Agent Dashboard && `"$HermesCmd`" dashboard --no-open") | Out-Null
  } else {
    Start-Process -WindowStyle Hidden -FilePath $env:ComSpec -ArgumentList @("/c", "`"$HermesCmd`" dashboard --no-open") | Out-Null
  }
  Start-Sleep -Seconds 3
  if (Test-LocalTcpPort -Port $Port) {
    Write-Host "Hermes Dashboard started: http://127.0.0.1:$Port"
  } else {
    Write-Warning "Hermes Dashboard was launched but port $Port is not listening yet. Set HERMES_START_DASHBOARD_VISIBLE=1 and rerun install.cmd to inspect logs."
  }
}

function Start-HermesDashboardAfterInstall {
  param(
    [string] $HermesCmd,
    [int] $Port
  )

  Start-HermesDashboard -HermesCmd $HermesCmd -Port $Port
}

function Remove-HermesShimFiles {
  param(
    [string[]] $ShimDirs
  )

  $ShimNames = @(
    "hermes.cmd",
    "hermes.bat",
    "dashboard.cmd",
    "dashboard.bat",
    "hermes-dashboard.cmd",
    "hermes-dashboard.bat",
    "hermes-launch.cmd",
    "hermes-launch.bat",
    "hermes-repair.cmd",
    "hermes-repair.bat",
    "hermes-shutdown.cmd",
    "hermes-shutdown.bat",
    "hermes-uninstall.cmd",
    "hermes-uninstall.bat",
    "hermes.exe"
  )

  foreach ($ShimDir in $ShimDirs) {
    if (-not $ShimDir -or -not (Test-Path $ShimDir)) {
      continue
    }
    foreach ($ShimName in $ShimNames) {
      $ShimPath = Join-Path $ShimDir $ShimName
      if (Test-Path $ShimPath) {
        Remove-Item -Force $ShimPath -ErrorAction Stop
        Write-Host "Removed legacy shim: $ShimPath"
      }
    }
  }
}

function Remove-UserPathEntries {
  param(
    [string[]] $Paths
  )

  $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $UserPath) {
    return
  }

  $ComparablePaths = @($Paths | Where-Object { $_ } | ForEach-Object {
    ConvertTo-ComparablePath -Path $_
  } | Where-Object { $_ } | Select-Object -Unique)
  if ($ComparablePaths.Count -eq 0) {
    return
  }

  $PathParts = @()
  foreach ($Part in ($UserPath -split ";")) {
    if (-not $Part) {
      continue
    }
    $ComparablePart = ConvertTo-ComparablePath -Path $Part
    $ShouldRemove = $false
    foreach ($ComparablePath in $ComparablePaths) {
      if ($ComparablePart -and $ComparablePart.Equals($ComparablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $ShouldRemove = $true
        break
      }
    }
    if (-not $ShouldRemove) {
      $PathParts += $Part
    }
  }

  [Environment]::SetEnvironmentVariable("Path", ($PathParts | Select-Object -Unique) -join ";", "User")
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

function New-HermesExeShimTemplate {
  param(
    [string] $OutputPath
  )

  $Source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class HermesShim
{
    public static int Main(string[] args)
    {
        string exePath = Process.GetCurrentProcess().MainModule.FileName;
        string shimDir = Path.GetDirectoryName(exePath);
        string hermesCmd = Path.Combine(shimDir, "hermes.cmd");
        if (!File.Exists(hermesCmd))
        {
            Console.Error.WriteLine("Hermes command shim was not found: " + hermesCmd);
            return 1;
        }

        string comSpec = Environment.GetEnvironmentVariable("ComSpec");
        if (String.IsNullOrEmpty(comSpec))
        {
            comSpec = "cmd.exe";
        }

        StringBuilder command = new StringBuilder();
        command.Append(QuoteForCommandLine(hermesCmd));
        foreach (string arg in args)
        {
            command.Append(' ');
            command.Append(QuoteForCommandLine(arg));
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = comSpec;
        startInfo.Arguments = "/d /c \"" + command.ToString() + "\"";
        startInfo.UseShellExecute = false;

        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static string QuoteForCommandLine(string value)
    {
        if (value == null)
        {
            return "\"\"";
        }

        bool needsQuotes = value.Length == 0;
        for (int i = 0; i < value.Length; i++)
        {
            if (Char.IsWhiteSpace(value[i]) || value[i] == '"')
            {
                needsQuotes = true;
                break;
            }
        }

        if (!needsQuotes)
        {
            return value;
        }

        StringBuilder result = new StringBuilder();
        result.Append('"');
        int backslashes = 0;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\\')
            {
                backslashes++;
                continue;
            }

            if (c == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(c);
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
'@

  Add-Type -TypeDefinition $Source -Language CSharp -OutputType ConsoleApplication -OutputAssembly $OutputPath
}

function Install-HermesExeShim {
  param(
    [string] $ShimDir,
    [string] $TemplatePath
  )

  Remove-HermesExeShim -ShimDir $ShimDir
  $ShimExe = Join-Path $ShimDir "hermes.exe"
  Copy-Item -Force $TemplatePath $ShimExe
}

function Sync-BundledSkills {
  param(
    [string] $VenvPython,
    [string] $HermesHome,
    [string] $InstallRoot,
    [string] $ResourcesDir
  )

  $SkillsDir = Join-Path $HermesHome "skills"
  New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
  Write-Host "Syncing bundled Agent Skills to $SkillsDir ..."

  $PreviousHermesHome = $env:HERMES_HOME
  $PreviousHermesOfflineHome = $env:HERMES_OFFLINE_HOME
  $PreviousBundledSkills = $env:HERMES_BUNDLED_SKILLS
  $PreviousOptionalSkills = $env:HERMES_OPTIONAL_SKILLS
  $PreviousOptionalMcps = $env:HERMES_OPTIONAL_MCPS
  $PreviousBundledLocales = $env:HERMES_BUNDLED_LOCALES
  $PreviousBundledPlugins = $env:HERMES_BUNDLED_PLUGINS
  $PreviousWebDist = $env:HERMES_WEB_DIST
  $PreviousTuiDir = $env:HERMES_TUI_DIR
  $env:HERMES_HOME = $HermesHome
  $env:HERMES_OFFLINE_HOME = $InstallRoot
  $env:HERMES_BUNDLED_SKILLS = Join-Path $ResourcesDir "skills"
  $env:HERMES_OPTIONAL_SKILLS = Join-Path $ResourcesDir "optional-skills"
  $env:HERMES_OPTIONAL_MCPS = Join-Path $ResourcesDir "optional-mcps"
  $env:HERMES_BUNDLED_LOCALES = Join-Path $ResourcesDir "locales"
  $env:HERMES_BUNDLED_PLUGINS = Join-Path $ResourcesDir "plugins"
  $env:HERMES_WEB_DIST = Join-Path $ResourcesDir "web_dist"
  $env:HERMES_TUI_DIR = Join-Path $ResourcesDir "tui_dist"
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
      @("HERMES_OFFLINE_HOME", $PreviousHermesOfflineHome),
      @("HERMES_BUNDLED_SKILLS", $PreviousBundledSkills),
      @("HERMES_OPTIONAL_SKILLS", $PreviousOptionalSkills),
      @("HERMES_OPTIONAL_MCPS", $PreviousOptionalMcps),
      @("HERMES_BUNDLED_LOCALES", $PreviousBundledLocales),
      @("HERMES_BUNDLED_PLUGINS", $PreviousBundledPlugins),
      @("HERMES_WEB_DIST", $PreviousWebDist),
      @("HERMES_TUI_DIR", $PreviousTuiDir)
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

function New-StringList {
  param(
    [string[]] $Lines
  )

  $List = New-Object "System.Collections.Generic.List[string]"
  foreach ($Line in $Lines) {
    [void] $List.Add($Line)
  }
  return ,$List
}

function Write-Utf8NoBomLines {
  param(
    [string] $Path,
    [string[]] $Lines
  )

  $Encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($Path, $Lines, $Encoding)
}

function Find-TopLevelYamlKey {
  param(
    [System.Collections.Generic.List[string]] $Lines,
    [string] $Key
  )

  $Pattern = "^{0}:\s*(#.*)?$" -f [regex]::Escape($Key)
  for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
    if ($Lines[$Index] -match $Pattern) {
      return $Index
    }
  }
  return -1
}

function Get-TopLevelYamlBlockEnd {
  param(
    [System.Collections.Generic.List[string]] $Lines,
    [int] $StartIndex
  )

  for ($Index = $StartIndex + 1; $Index -lt $Lines.Count; $Index++) {
    $Line = $Lines[$Index]
    if ($Line -match '^\S' -and $Line -notmatch '^\s*#') {
      return $Index
    }
  }
  return $Lines.Count
}

function Get-YamlNestedBlockEnd {
  param(
    [System.Collections.Generic.List[string]] $Lines,
    [int] $StartIndex,
    [int] $Indent
  )

  for ($Index = $StartIndex + 1; $Index -lt $Lines.Count; $Index++) {
    $Line = $Lines[$Index]
    if ($Line -match '^\s*$' -or $Line -match '^\s*#') {
      continue
    }
    $Leading = ([regex]::Match($Line, '^\s*')).Value.Length
    if ($Leading -le $Indent) {
      return $Index
    }
  }
  return $Lines.Count
}

function Ensure-ModelProviderLine {
  param(
    [System.Collections.Generic.List[string]] $Lines
  )

  $ModelIndex = Find-TopLevelYamlKey -Lines $Lines -Key "model"
  if ($ModelIndex -lt 0) {
    $Lines.Insert(0, "")
    $Lines.Insert(0, "  provider: custom:zhan_ai")
    $Lines.Insert(0, "  default: qwen3")
    $Lines.Insert(0, "model:")
    return
  }

  $ModelEnd = Get-TopLevelYamlBlockEnd -Lines $Lines -StartIndex $ModelIndex
  $DefaultIndex = -1
  $ProviderIndex = -1
  for ($Index = $ModelIndex + 1; $Index -lt $ModelEnd; $Index++) {
    if ($Lines[$Index] -match '^\s+default\s*:') {
      $DefaultIndex = $Index
    }
    if ($Lines[$Index] -match '^\s+provider\s*:') {
      $ProviderIndex = $Index
    }
  }

  if ($DefaultIndex -lt 0) {
    $Lines.Insert($ModelIndex + 1, "  default: qwen3")
    $ModelEnd++
  } elseif (
    $Lines[$DefaultIndex] -match '^\s+default\s*:\s*([#].*)?$' -or
    $Lines[$DefaultIndex] -match '^\s+default\s*:\s*[''"]?gpt-4o-mini[''"]?\s*(#.*)?$'
  ) {
    $Lines[$DefaultIndex] = "  default: qwen3"
  }

  $ProviderIndex = -1
  for ($Index = $ModelIndex + 1; $Index -lt $ModelEnd; $Index++) {
    if ($Lines[$Index] -match '^\s+provider\s*:') {
      $ProviderIndex = $Index
      break
    }
  }

  if ($ProviderIndex -ge 0) {
    $Lines[$ProviderIndex] = "  provider: custom:zhan_ai"
  } else {
    $InsertIndex = if ($DefaultIndex -ge 0) { $DefaultIndex + 1 } else { $ModelIndex + 2 }
    $Lines.Insert($InsertIndex, "  provider: custom:zhan_ai")
  }
}

function Ensure-ZhanAiProviderBlock {
  param(
    [System.Collections.Generic.List[string]] $Lines
  )

  $ProvidersIndex = Find-TopLevelYamlKey -Lines $Lines -Key "providers"
  if ($ProvidersIndex -lt 0) {
    if ($Lines.Count -gt 0 -and $Lines[($Lines.Count - 1)] -ne "") {
      [void] $Lines.Add("")
    }
    [void] $Lines.Add("providers:")
    [void] $Lines.Add("  zhan_ai:")
    [void] $Lines.Add('    api: "${ZHANCLAW_BASE_URL}"')
    [void] $Lines.Add("    key_env: ZHANCLAW_API_KEY")
    [void] $Lines.Add("    models:")
    [void] $Lines.Add("      - qwen3")
    return
  }

  $ProvidersEnd = Get-TopLevelYamlBlockEnd -Lines $Lines -StartIndex $ProvidersIndex
  $ZhanIndex = -1
  for ($Index = $ProvidersIndex + 1; $Index -lt $ProvidersEnd; $Index++) {
    if ($Lines[$Index] -match '^\s{2}zhan_ai\s*:\s*(#.*)?$') {
      $ZhanIndex = $Index
      break
    }
  }

  if ($ZhanIndex -lt 0) {
    $Lines.Insert($ProvidersIndex + 1, "      - qwen3")
    $Lines.Insert($ProvidersIndex + 1, "    models:")
    $Lines.Insert($ProvidersIndex + 1, "    key_env: ZHANCLAW_API_KEY")
    $Lines.Insert($ProvidersIndex + 1, '    api: "${ZHANCLAW_BASE_URL}"')
    $Lines.Insert($ProvidersIndex + 1, "  zhan_ai:")
    return
  }

  $ZhanEnd = Get-YamlNestedBlockEnd -Lines $Lines -StartIndex $ZhanIndex -Indent 2
  $ApiIndex = -1
  $KeyEnvIndex = -1
  for ($Index = $ZhanIndex + 1; $Index -lt $ZhanEnd; $Index++) {
    if ($Lines[$Index] -match '^\s+api\s*:') {
      $ApiIndex = $Index
    }
    if ($Lines[$Index] -match '^\s+key_env\s*:') {
      $KeyEnvIndex = $Index
    }
  }

  if ($ApiIndex -ge 0) {
    $Lines[$ApiIndex] = '    api: "${ZHANCLAW_BASE_URL}"'
  } else {
    $Lines.Insert($ZhanIndex + 1, '    api: "${ZHANCLAW_BASE_URL}"')
    $ZhanEnd++
  }

  $KeyEnvIndex = -1
  for ($Index = $ZhanIndex + 1; $Index -lt $ZhanEnd; $Index++) {
    if ($Lines[$Index] -match '^\s+key_env\s*:') {
      $KeyEnvIndex = $Index
      break
    }
  }
  if ($KeyEnvIndex -ge 0) {
    $Lines[$KeyEnvIndex] = "    key_env: ZHANCLAW_API_KEY"
  } else {
    $Lines.Insert($ZhanIndex + 2, "    key_env: ZHANCLAW_API_KEY")
    $ZhanEnd++
  }

  $ZhanEnd = Get-YamlNestedBlockEnd -Lines $Lines -StartIndex $ZhanIndex -Indent 2
  $ModelsIndex = -1
  for ($Index = $ZhanIndex + 1; $Index -lt $ZhanEnd; $Index++) {
    if ($Lines[$Index] -match '^\s+models\s*:') {
      $ModelsIndex = $Index
      break
    }
  }
  if ($ModelsIndex -lt 0) {
    $ModelInsertIndex = $ZhanEnd
    for ($Index = $ZhanIndex + 1; $Index -lt $ZhanEnd; $Index++) {
      if ($Lines[$Index] -match '^\s+key_env\s*:') {
        $ModelInsertIndex = $Index + 1
        break
      }
      if ($Lines[$Index] -match '^\s+api\s*:') {
        $ModelInsertIndex = $Index + 1
      }
    }
    $Lines.Insert($ModelInsertIndex, "      - qwen3")
    $Lines.Insert($ModelInsertIndex, "    models:")
  } elseif ($Lines[$ModelsIndex] -match '^(\s+models\s*:\s*)\[(.*)\](\s*#.*)?$') {
    if ($Matches[2] -notmatch '(^|[^A-Za-z0-9_-])qwen3([^A-Za-z0-9_-]|$)') {
      $InlineModels = $Matches[2].Trim()
      $InlineComment = if ($Matches[3]) { $Matches[3] } else { "" }
      if ($InlineModels) {
        $Lines[$ModelsIndex] = "$($Matches[1])[$InlineModels, qwen3]$InlineComment"
      } else {
        $Lines[$ModelsIndex] = "$($Matches[1])[qwen3]$InlineComment"
      }
    }
  } elseif ($Lines[$ModelsIndex] -match '^\s+models\s*:\s*$') {
    $ModelsEnd = Get-YamlNestedBlockEnd -Lines $Lines -StartIndex $ModelsIndex -Indent 4
    $HasQwen3Model = $false
    for ($Index = $ModelsIndex + 1; $Index -lt $ModelsEnd; $Index++) {
      if ($Lines[$Index] -match '^\s+(?:-\s*)?[''"]?qwen3[''"]?\s*(?::|#.*)?$') {
        $HasQwen3Model = $true
        break
      }
    }
    if (-not $HasQwen3Model) {
      $Lines.Insert($ModelsIndex + 1, "      - qwen3")
    }
  }
}

function Get-DotEnvValue {
  param(
    [string] $Path,
    [string[]] $Names
  )

  if (-not (Test-Path $Path)) {
    return $null
  }

  $NameSet = @{}
  foreach ($Name in $Names) {
    if ($Name) {
      $NameSet[$Name.ToUpperInvariant()] = $true
    }
  }

  foreach ($Line in (Get-Content -Path $Path -ErrorAction SilentlyContinue)) {
    if ($Line -notmatch '^\s*([^#=\s]+)\s*=\s*(.*)$') {
      continue
    }
    $Key = $Matches[1].Trim().ToUpperInvariant()
    if (-not $NameSet.ContainsKey($Key)) {
      continue
    }
    $Value = $Matches[2].Trim()
    if ($Value.Length -ge 2) {
      $First = $Value.Substring(0, 1)
      $Last = $Value.Substring($Value.Length - 1, 1)
      if (($First -eq '"' -and $Last -eq '"') -or ($First -eq "'" -and $Last -eq "'")) {
        $Value = $Value.Substring(1, $Value.Length - 2)
      }
    }
    if ($Value) {
      return $Value
    }
  }

  return $null
}

function Import-ZhanClawEnvironmentFromLegacyDotEnv {
  param(
    [string[]] $EnvPaths,
    [bool] $PortableMode
  )

  $Mappings = @(
    @{
      Target = "ZHANCLAW_BASE_URL"
      Legacy = @("ZHANCLAW_BASE_URL", "CUSTOM_BASE_URL", "OPENAI_BASE_URL")
    },
    @{
      Target = "ZHANCLAW_API_KEY"
      Legacy = @("ZHANCLAW_API_KEY", "CUSTOM_API_KEY", "OPENAI_API_KEY")
    }
  )

  foreach ($Mapping in $Mappings) {
    $Target = [string] $Mapping["Target"]
    if ([Environment]::GetEnvironmentVariable($Target, "Process")) {
      continue
    }
    if (-not $PortableMode -and [Environment]::GetEnvironmentVariable($Target, "User")) {
      continue
    }
    $LegacyNames = [string[]] $Mapping["Legacy"]
    $Value = $null
    foreach ($EnvPath in $EnvPaths) {
      if (-not $EnvPath) {
        continue
      }
      $Value = Get-DotEnvValue -Path $EnvPath -Names $LegacyNames
      if ($Value) {
        break
      }
    }
    if (-not $Value) {
      continue
    }
    Set-Item -Path ("Env:{0}" -f $Target) -Value $Value
    if (-not $PortableMode) {
      [Environment]::SetEnvironmentVariable($Target, $Value, "User")
    }
    $SourceLabel = ($LegacyNames | Where-Object { $_ -ne $Target }) -join "/"
    Write-Host "Migrated $Target from legacy .env model setting ($SourceLabel)."
  }
}

function Copy-LegacyHermesHomeFileIfMissing {
  param(
    [string] $TargetPath,
    [string] $LegacyPath,
    [string] $Label
  )

  if ((Test-Path $TargetPath) -or -not (Test-Path $LegacyPath)) {
    return
  }
  Copy-Item -Force $LegacyPath $TargetPath
  Write-Host "Migrated legacy Hermes $Label from $LegacyPath to $TargetPath."
}

function Remove-LegacyApiServerPort {
  param(
    [System.Collections.Generic.List[string]] $Lines
  )

  $Port = $null
  for ($Index = $Lines.Count - 1; $Index -ge 0; $Index--) {
    if ($Lines[$Index] -match '^api_server_port\s*:\s*([^#]+)?') {
      $Candidate = $Matches[1]
      if ($Candidate -and $Candidate.Trim()) {
        $Port = $Candidate.Trim()
      }
      $Lines.RemoveAt($Index)
    }
  }
  return $Port
}

function Ensure-ApiServerPlatformConfig {
  param(
    [System.Collections.Generic.List[string]] $Lines,
    [AllowNull()] [string] $Port
  )

  $EffectivePort = if ($Port) { $Port } else { "8642" }

  $PlatformsIndex = Find-TopLevelYamlKey -Lines $Lines -Key "platforms"
  if ($PlatformsIndex -lt 0) {
    if ($Lines.Count -gt 0 -and $Lines[($Lines.Count - 1)] -ne "") {
      [void] $Lines.Add("")
    }
    [void] $Lines.Add("platforms:")
    [void] $Lines.Add("  api_server:")
    [void] $Lines.Add("    enabled: true")
    [void] $Lines.Add("    extra:")
    [void] $Lines.Add("      port: $EffectivePort")
    return
  }

  $PlatformsEnd = Get-TopLevelYamlBlockEnd -Lines $Lines -StartIndex $PlatformsIndex
  $ApiServerIndex = -1
  for ($Index = $PlatformsIndex + 1; $Index -lt $PlatformsEnd; $Index++) {
    if ($Lines[$Index] -match '^\s{2}api_server\s*:\s*(#.*)?$') {
      $ApiServerIndex = $Index
      break
    }
  }

  if ($ApiServerIndex -lt 0) {
    $Lines.Insert($PlatformsIndex + 1, "      port: $EffectivePort")
    $Lines.Insert($PlatformsIndex + 1, "    extra:")
    $Lines.Insert($PlatformsIndex + 1, "    enabled: true")
    $Lines.Insert($PlatformsIndex + 1, "  api_server:")
    return
  }

  $ApiServerEnd = Get-YamlNestedBlockEnd -Lines $Lines -StartIndex $ApiServerIndex -Indent 2
  $EnabledIndex = -1
  for ($Index = $ApiServerIndex + 1; $Index -lt $ApiServerEnd; $Index++) {
    if ($Lines[$Index] -match '^\s{4}enabled\s*:') {
      $EnabledIndex = $Index
      break
    }
  }
  if ($EnabledIndex -ge 0) {
    $Lines[$EnabledIndex] = "    enabled: true"
  } else {
    $Lines.Insert($ApiServerIndex + 1, "    enabled: true")
    $EnabledIndex = $ApiServerIndex + 1
  }

  $ApiServerEnd = Get-YamlNestedBlockEnd -Lines $Lines -StartIndex $ApiServerIndex -Indent 2
  $ExtraIndex = -1
  for ($Index = $ApiServerIndex + 1; $Index -lt $ApiServerEnd; $Index++) {
    if ($Lines[$Index] -match '^\s{4}extra\s*:\s*(#.*)?$') {
      $ExtraIndex = $Index
      break
    }
  }

  if ($ExtraIndex -lt 0) {
    $InsertIndex = $EnabledIndex + 1
    $Lines.Insert($InsertIndex, "    extra:")
    $Lines.Insert($InsertIndex + 1, "      port: $EffectivePort")
    return
  }

  $ExtraEnd = Get-YamlNestedBlockEnd -Lines $Lines -StartIndex $ExtraIndex -Indent 4
  $PortIndex = -1
  for ($Index = $ExtraIndex + 1; $Index -lt $ExtraEnd; $Index++) {
    if ($Lines[$Index] -match '^\s{6}port\s*:') {
      $PortIndex = $Index
      break
    }
  }
  if ($PortIndex -ge 0) {
    if ($Port) {
      $Lines[$PortIndex] = "      port: $Port"
    }
  } else {
    $Lines.Insert($ExtraIndex + 1, "      port: $EffectivePort")
  }
}

function Get-ApiServerPlatformPort {
  param(
    [System.Collections.Generic.List[string]] $Lines
  )

  $PlatformsIndex = Find-TopLevelYamlKey -Lines $Lines -Key "platforms"
  if ($PlatformsIndex -lt 0) {
    return $null
  }

  $PlatformsEnd = Get-TopLevelYamlBlockEnd -Lines $Lines -StartIndex $PlatformsIndex
  $ApiServerIndex = -1
  for ($Index = $PlatformsIndex + 1; $Index -lt $PlatformsEnd; $Index++) {
    if ($Lines[$Index] -match '^\s{2}api_server\s*:\s*(#.*)?$') {
      $ApiServerIndex = $Index
      break
    }
  }
  if ($ApiServerIndex -lt 0) {
    return $null
  }

  $ApiServerEnd = Get-YamlNestedBlockEnd -Lines $Lines -StartIndex $ApiServerIndex -Indent 2
  $ExtraIndex = -1
  for ($Index = $ApiServerIndex + 1; $Index -lt $ApiServerEnd; $Index++) {
    if ($Lines[$Index] -match '^\s{4}extra\s*:\s*(#.*)?$') {
      $ExtraIndex = $Index
      break
    }
  }
  if ($ExtraIndex -lt 0) {
    return $null
  }

  $ExtraEnd = Get-YamlNestedBlockEnd -Lines $Lines -StartIndex $ExtraIndex -Indent 4
  for ($Index = $ExtraIndex + 1; $Index -lt $ExtraEnd; $Index++) {
    if ($Lines[$Index] -match '^\s{6}port\s*:\s*([^#]+)?') {
      $Candidate = $Matches[1]
      if ($Candidate -and $Candidate.Trim()) {
        return $Candidate.Trim()
      }
      return $null
    }
  }
  return $null
}

function Set-OfflineInstallerDefaultConfig {
  param(
    [string] $ConfigPath
  )

  $ConfigLines = @()
  if (Test-Path $ConfigPath) {
    $ConfigLines = @(Get-Content -Path $ConfigPath -ErrorAction Stop)
  }
  $MutableLines = New-StringList -Lines $ConfigLines
  $LegacyApiServerPort = Remove-LegacyApiServerPort -Lines $MutableLines
  Ensure-ModelProviderLine -Lines $MutableLines
  Ensure-ZhanAiProviderBlock -Lines $MutableLines
  Ensure-ApiServerPlatformConfig -Lines $MutableLines -Port $LegacyApiServerPort
  $ApiServerPort = Get-ApiServerPlatformPort -Lines $MutableLines
  $OutputLines = $MutableLines.ToArray()
  Write-Utf8NoBomLines -Path $ConfigPath -Lines $OutputLines
  Write-Host "Configured default model provider: custom:zhan_ai"
  Write-Host "Configured API server platform port: $ApiServerPort"
}

$ShimDirs = @($BinDir)
$ProcessShimDirs = (@($BinDir) + $LegacyShimDirs) | Where-Object { $_ } | Select-Object -Unique
if ($env:HERMES_OFFLINE_HOME -and -not $CustomInstallRoot) {
  Write-Host "Ignoring legacy HERMES_OFFLINE_HOME=$env:HERMES_OFFLINE_HOME; using $InstallRoot."
}
if ($env:HERMES_HOME -and -not $CustomHermesHome) {
  Write-Host "Ignoring legacy HERMES_HOME=$env:HERMES_HOME; using $HermesHome."
}
if (-not $PortableMode -and (Test-PathUnderRoot -Path $InstallRoot -Root $DefaultProgramFilesRoot) -and -not (Test-IsAdministrator)) {
  throw "Windows default installation writes to $InstallRoot and requires administrator rights. Run install.cmd again and accept the UAC prompt, or extract the bundle to a writable folder and run install.cmd -Portable."
}
$ExistingConfigPath = Join-Path $HermesHome "config.yaml"
$ExistingEnvPath = Join-Path $HermesHome ".env"
$ExistingSkillsDir = Join-Path $HermesHome "skills"
$ExistingRuntimeResources = Join-Path $RuntimeDir "hermes-resources"
$IsUpgrade = (
  (Test-Path $VenvDir) -or
  (Test-Path $RuntimeBundle) -or
  (Test-Path $ExistingHermesCmd) -or
  (Test-Path $ExistingRuntimeResources) -or
  (Test-Path $ExistingConfigPath) -or
  (Test-Path $ExistingEnvPath) -or
  (Test-Path $ExistingSkillsDir)
)
if ($IsUpgrade) {
  Write-Host "Existing Hermes offline installation detected. Running upgrade."
} else {
  Write-Host "No existing Hermes offline installation detected. Running install."
}
if ($PortableMode) {
  Write-Host "Portable mode enabled. Runtime and Hermes home will stay inside: $BundleDir"
} else {
  Write-Host "Windows install root: $InstallRoot"
  Write-Host "Windows Hermes home: $HermesHome"
}
$InstallDirs = @($RuntimeDir, $HermesHome) + $ShimDirs
New-Item -ItemType Directory -Force -Path $InstallDirs | Out-Null
if (-not $PortableMode -and (Test-PathUnderRoot -Path $HermesHome -Root $DefaultProgramDataRoot)) {
  Grant-HermesHomeAccess -Path $HermesHome
}

$Wheelhouse = Join-Path $BundleDir "wheelhouse"
if (-not (Test-Path $Wheelhouse)) {
  throw "Missing wheelhouse: $Wheelhouse"
}
$BundledResources = Join-Path $BundleDir "hermes-resources"
if (-not (Test-Path $BundledResources)) {
  throw "Missing Hermes runtime resources: $BundledResources"
}

Stop-ExistingHermesProcesses -InstallRoot $InstallRoot -RuntimeDir $RuntimeDir -HermesHome $HermesHome -ShimDirs $ProcessShimDirs
Remove-HermesShimFiles -ShimDirs $LegacyShimDirs
foreach ($Path in @($RuntimeWheelhouse, $RuntimeTemplates, $RuntimeCommands, $RuntimeBundle, $RuntimeResources, $VenvDir)) {
  Remove-InstallPath -Path $Path
}
Copy-Item -Recurse -Force $Wheelhouse $RuntimeWheelhouse
Copy-Item -Recurse -Force (Join-Path $BundleDir "templates") $RuntimeTemplates
New-Item -ItemType Directory -Force -Path $RuntimeCommands | Out-Null
Copy-Item -Force (Join-Path $ScriptDir "launch_windows.ps1") (Join-Path $RuntimeCommands "launch_windows.ps1")
Copy-Item -Force (Join-Path $ScriptDir "shutdown_windows.ps1") (Join-Path $RuntimeCommands "shutdown_windows.ps1")
Copy-Item -Force (Join-Path $ScriptDir "uninstall_windows.ps1") (Join-Path $RuntimeCommands "uninstall_windows.ps1")
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
    $PythonZip = Get-ChildItem -Path $BundledPythonHome -Filter "python*.zip" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $LibEncodings = Join-Path $BundledPythonHome "Lib\encodings"
    $PythonZipStatus = if ($PythonZip) { "$($PythonZip.FullName) exists=True" } else { "python*.zip exists=False" }
    throw "Bundled Python failed to import encodings, ensurepip, and venv. PYTHONHOME=$BundledPythonHome; $PythonZipStatus; Lib\encodings exists=$(Test-Path $LibEncodings); discovered encodings=$($EncodingsDir.FullName)"
  }
}

$FallbackPythonHome = if ($PythonRuntimeNeedsPythonHome) { $BundledPythonHome } else { $null }
New-HermesVenv -PythonBin $PythonBin -VenvDir $VenvDir -FallbackPythonHome $FallbackPythonHome
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path (Join-Path $VenvDir "pyvenv.cfg")) -or -not (Test-Path $VenvPython)) {
  throw "Python venv was not created correctly: $VenvDir"
}
$RuntimePackages = @(
  "aiohttp==3.14.1",
  "fastapi==0.133.1",
  "python-multipart",
  "uvicorn==0.41.0",
  "websockets"
)
$HermesInstallSpec = "hermes-agent[all]"
$WheelhouseManifest = Join-Path $RuntimeWheelhouse "manifest.json"
if (Test-Path $WheelhouseManifest) {
  try {
    $WheelhouseMeta = Get-Content -Raw -Path $WheelhouseManifest | ConvertFrom-Json
    $Extras = @($WheelhouseMeta.extras) | Where-Object { $_ }
    if ($Extras.Count -gt 0) {
      $HermesInstallSpec = "hermes-agent[$($Extras -join ',')]"
    } else {
      $HermesInstallSpec = "hermes-agent"
    }
  } catch {
    Write-Warning "Could not parse wheelhouse manifest. Falling back to $HermesInstallSpec. Error: $($_.Exception.Message)"
  }
}
Write-Host "Installing Hermes package spec: $HermesInstallSpec"
& $VenvPython -m pip install --only-binary=:all: --no-index --find-links $RuntimeWheelhouse $HermesInstallSpec croniter @RuntimePackages
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
$TuiDir = Join-Path $RuntimeResources "tui_dist"
$HermesCacheDir = Join-Path $HermesHome "cache"
$HermesDefaultEnvironment = [ordered]@{
  "HERMES_DESKTOP_MANAGED" = "1"
  "HF_HOME" = (Join-Path $HermesCacheDir "huggingface")
  "HUGGINGFACE_HUB_CACHE" = (Join-Path $HermesCacheDir "huggingface\hub")
  "TORCH_HOME" = (Join-Path $HermesCacheDir "torch")
  "TIKTOKEN_CACHE_DIR" = (Join-Path $HermesCacheDir "tiktoken")
  "MPLCONFIGDIR" = (Join-Path $HermesCacheDir "matplotlib")
  "NLTK_DATA" = (Join-Path $HermesCacheDir "nltk")
  "PLAYWRIGHT_BROWSERS_PATH" = (Join-Path $HermesCacheDir "playwright")
  "TEMP" = (Join-Path $HermesCacheDir "tmp")
  "TMP" = (Join-Path $HermesCacheDir "tmp")
}
$HermesDefaultEnvironmentPathValues = @($HermesDefaultEnvironment.GetEnumerator() | Where-Object {
  $_.Key -ne "HERMES_DESKTOP_MANAGED"
} | ForEach-Object { $_.Value })
New-Item -ItemType Directory -Force -Path $HermesDefaultEnvironmentPathValues | Out-Null
$HermesInstallerEnvironment = [ordered]@{
  "PYTHONUTF8" = "1"
  "PYTHONIOENCODING" = "utf-8"
  "HERMES_HOME" = $HermesHome
  "HERMES_OFFLINE_HOME" = $InstallRoot
  "HERMES_PYTHON" = $VenvPython
  "HERMES_BUNDLED_SKILLS" = $BundledSkillsDir
  "HERMES_OPTIONAL_SKILLS" = $OptionalSkillsDir
  "HERMES_OPTIONAL_MCPS" = $OptionalMcpsDir
  "HERMES_BUNDLED_LOCALES" = $BundledLocalesDir
  "HERMES_BUNDLED_PLUGINS" = $BundledPluginsDir
  "HERMES_WEB_DIST" = $WebDistDir
  "HERMES_TUI_DIR" = $TuiDir
}
$HermesShimEnvironmentLines = @($HermesInstallerEnvironment.GetEnumerator() | ForEach-Object {
  'set "{0}={1}"' -f $_.Key, $_.Value
})
$HermesShimDefaultEnvironmentLines = @($HermesDefaultEnvironment.GetEnumerator() | ForEach-Object {
  'if not defined {0} set "{0}={1}"' -f $_.Key, $_.Value
})
$HermesShimUserEnvironmentLines = @(
  'for /f "tokens=2,*" %%A in (''reg query HKCU\Environment /v ZHANCLAW_BASE_URL 2^>nul ^| findstr /I "ZHANCLAW_BASE_URL"'') do set "ZHANCLAW_BASE_URL=%%B"',
  'for /f "tokens=2,*" %%A in (''reg query HKCU\Environment /v ZHANCLAW_API_KEY 2^>nul ^| findstr /I "ZHANCLAW_API_KEY"'') do set "ZHANCLAW_API_KEY=%%B"'
)
$ShimLines = @(
  "@echo off",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('"{0}" %*' -f $HermesExe)
)
$DashboardShimLines = @(
  "@echo off",
  "title Hermes Agent Dashboard",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('"{0}" dashboard --no-open %*' -f $HermesExe)
)
$LaunchShimLines = @(
  "@echo off",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f (Join-Path $RuntimeCommands "launch_windows.ps1"))
)
$ShutdownShimLines = @(
  "@echo off",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f (Join-Path $RuntimeCommands "shutdown_windows.ps1"))
)
$UninstallShimLines = @(
  "@echo off",
  "chcp 65001 >nul"
) + $HermesShimEnvironmentLines + $HermesShimDefaultEnvironmentLines + $HermesShimUserEnvironmentLines + @(
  ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %*' -f (Join-Path $RuntimeCommands "uninstall_windows.ps1"))
)
$ExeShimTemplate = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-exe-shim-{0}.exe" -f ([System.Guid]::NewGuid().ToString("N")))
New-HermesExeShimTemplate -OutputPath $ExeShimTemplate
foreach ($ShimDir in $ShimDirs) {
  Set-Content -Path (Join-Path $ShimDir "hermes.cmd") -Encoding ASCII -Value $ShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes.bat") -Encoding ASCII -Value $ShimLines
  Set-Content -Path (Join-Path $ShimDir "dashboard.cmd") -Encoding ASCII -Value $DashboardShimLines
  Set-Content -Path (Join-Path $ShimDir "dashboard.bat") -Encoding ASCII -Value $DashboardShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-dashboard.cmd") -Encoding ASCII -Value $DashboardShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-dashboard.bat") -Encoding ASCII -Value $DashboardShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-launch.cmd") -Encoding ASCII -Value $LaunchShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-launch.bat") -Encoding ASCII -Value $LaunchShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-shutdown.cmd") -Encoding ASCII -Value $ShutdownShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-shutdown.bat") -Encoding ASCII -Value $ShutdownShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-uninstall.cmd") -Encoding ASCII -Value $UninstallShimLines
  Set-Content -Path (Join-Path $ShimDir "hermes-uninstall.bat") -Encoding ASCII -Value $UninstallShimLines
  Install-HermesExeShim -ShimDir $ShimDir -TemplatePath $ExeShimTemplate
}
Remove-Item -Force $ExeShimTemplate -ErrorAction SilentlyContinue
$HermesCmd = Join-Path $BinDir "hermes.cmd"
foreach ($Entry in $HermesInstallerEnvironment.GetEnumerator()) {
  Set-Item -Path ("Env:{0}" -f $Entry.Key) -Value $Entry.Value
  if (-not $PortableMode) {
    [Environment]::SetEnvironmentVariable($Entry.Key, $Entry.Value, "User")
  }
}
foreach ($Entry in $HermesDefaultEnvironment.GetEnumerator()) {
  if (-not [Environment]::GetEnvironmentVariable($Entry.Key, "Process")) {
    Set-Item -Path ("Env:{0}" -f $Entry.Key) -Value $Entry.Value
  }
}
foreach ($ZhanEnvName in @("ZHANCLAW_BASE_URL", "ZHANCLAW_API_KEY")) {
  if (-not [Environment]::GetEnvironmentVariable($ZhanEnvName, "Process")) {
    $ZhanEnvValue = [Environment]::GetEnvironmentVariable($ZhanEnvName, "User")
    if ($ZhanEnvValue) {
      Set-Item -Path ("Env:{0}" -f $ZhanEnvName) -Value $ZhanEnvValue
    }
  }
}

$ConfigPath = Join-Path $HermesHome "config.yaml"
$LegacyConfigPath = Join-Path $LegacyHermesHome "config.yaml"
if (-not $PortableMode -and -not (Test-SamePath -Left $HermesHome -Right $LegacyHermesHome)) {
  Copy-LegacyHermesHomeFileIfMissing -TargetPath $ConfigPath -LegacyPath $LegacyConfigPath -Label "config.yaml"
}
if (-not (Test-Path $ConfigPath)) {
  Copy-Item (Join-Path $RuntimeTemplates "config.yaml") $ConfigPath
}
Set-OfflineInstallerDefaultConfig -ConfigPath $ConfigPath

$EnvPath = Join-Path $HermesHome ".env"
$LegacyEnvPath = Join-Path $LegacyHermesHome ".env"
if (-not $PortableMode -and -not (Test-SamePath -Left $HermesHome -Right $LegacyHermesHome)) {
  Copy-LegacyHermesHomeFileIfMissing -TargetPath $EnvPath -LegacyPath $LegacyEnvPath -Label ".env"
}
if (-not (Test-Path $EnvPath)) {
  Copy-Item (Join-Path $RuntimeTemplates "env.template") $EnvPath
}
$ZhanEnvImportPaths = @($EnvPath)
if (-not $PortableMode -and -not (Test-SamePath -Left $EnvPath -Right $LegacyEnvPath)) {
  $ZhanEnvImportPaths += $LegacyEnvPath
}
Import-ZhanClawEnvironmentFromLegacyDotEnv -EnvPaths $ZhanEnvImportPaths -PortableMode $PortableMode

Sync-BundledSkills -VenvPython $VenvPython -HermesHome $HermesHome -InstallRoot $InstallRoot -ResourcesDir $RuntimeResources

if (-not $PortableMode) {
  Remove-UserPathEntries -Paths @($LegacyOfflineBinDir)
  $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (($UserPath -split ";") -notcontains $BinDir) {
    $PathParts = @()
    if ($UserPath) {
      $PathParts += ($UserPath -split ";") | Where-Object { $_ }
    }
    if ($PathParts -notcontains $BinDir) {
      $PathParts += $BinDir
    }
    $NewUserPath = ($PathParts | Select-Object -Unique) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
  }
}

& $HermesCmd version
if ($LASTEXITCODE -ne 0) {
  throw "Hermes version check failed with exit code $LASTEXITCODE."
}

Start-HermesDashboardAfterInstall -HermesCmd $HermesCmd -Port 9119

Write-Host "Hermes Agent installed."
Write-Host "shim: $HermesCmd"
$LaunchCmd = Join-Path $BinDir "hermes-launch.cmd"
$ShutdownCmd = Join-Path $BinDir "hermes-shutdown.cmd"
$UninstallCmd = Join-Path $BinDir "hermes-uninstall.cmd"
Write-Host "launch: $LaunchCmd"
Write-Host "repair: $(Join-Path $BundleDir 'repair.cmd')"
Write-Host "shutdown: $ShutdownCmd"
Write-Host "uninstall: $UninstallCmd"
Write-Host "config: $ConfigPath"
Write-Host "skills: $(Join-Path $HermesHome 'skills')"
Write-Host "resources: $RuntimeResources"
if ($PortableMode) {
  Write-Host "portable: enabled"
  Write-Host "Use launch.cmd from this extracted folder to start Hermes without changing User PATH."
} else {
  Write-Host "Please reopen PowerShell for PATH changes to take effect."
}
