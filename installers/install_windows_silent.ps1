param(
  [switch] $Portable,
  [string] $StatusFile,
  [string] $LogFile,
  [switch] $StartDashboard
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallScriptCandidates = @(
  (Join-Path $ScriptDir "install_windows.ps1"),
  (Join-Path $ScriptDir "installers\install_windows.ps1")
)
$InstallScript = $null
foreach ($Candidate in $InstallScriptCandidates) {
  if (Test-Path $Candidate) {
    $InstallScript = $Candidate
    break
  }
}
if (-not $InstallScript) {
  throw "Missing installer PowerShell script. Checked: $($InstallScriptCandidates -join ', ')"
}

function Resolve-FullPath {
  param(
    [string] $Path
  )

  $ExpandedPath = [Environment]::ExpandEnvironmentVariables($Path)
  try {
    return [System.IO.Path]::GetFullPath($ExpandedPath)
  } catch {
    return $ExpandedPath
  }
}

function Ensure-ParentDirectory {
  param(
    [string] $Path
  )

  $Parent = Split-Path -Parent $Path
  if ($Parent) {
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
  }
}

function Write-Utf8NoBomText {
  param(
    [string] $Path,
    [string] $Content
  )

  $Encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Write-StatusSnapshot {
  param(
    [string] $State,
    [AllowNull()] [object] $Ok,
    [int] $ExitCode,
    [string] $Message
  )

  if (-not $ResolvedStatusFile) {
    return
  }

  $Now = [DateTimeOffset]::Now.ToString("o")
  $Payload = [ordered]@{
    schema_version = 1
    state = $State
    ok = $Ok
    exit_code = $ExitCode
    message = $Message
    portable = [bool] $Portable
    pid = $PID
    started_at = $StartedAt
    updated_at = $Now
    finished_at = if ($State -eq "running") { $null } else { $Now }
    bundle_dir = $BundleDir
    log_file = $ResolvedLogFile
  }

  $Json = $Payload | ConvertTo-Json -Depth 4
  $TempPath = "{0}.{1}.tmp" -f $ResolvedStatusFile, [System.Guid]::NewGuid().ToString("N")
  Ensure-ParentDirectory -Path $ResolvedStatusFile
  Write-Utf8NoBomText -Path $TempPath -Content $Json
  Move-Item -Force $TempPath $ResolvedStatusFile
}

function Append-LogLine {
  param(
    [string] $Message
  )

  Ensure-ParentDirectory -Path $ResolvedLogFile
  $Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
  Add-Content -Path $ResolvedLogFile -Value ("[{0}] {1}" -f $Timestamp, $Message) -Encoding UTF8
}

$InstallScriptDir = Split-Path -Parent $InstallScript
$BundleDir = if ((Split-Path -Leaf $InstallScriptDir) -ieq "installers") {
  Split-Path -Parent $InstallScriptDir
} else {
  $InstallScriptDir
}
$StartedAt = [DateTimeOffset]::Now.ToString("o")
$ResolvedStatusFile = if ($StatusFile) {
  Resolve-FullPath -Path $StatusFile
} else {
  $null
}
$ResolvedLogFile = if ($LogFile) {
  Resolve-FullPath -Path $LogFile
} elseif ($ResolvedStatusFile) {
  [System.IO.Path]::ChangeExtension($ResolvedStatusFile, ".log")
} else {
  Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-{0}.log" -f ([System.Guid]::NewGuid().ToString("N")))
}

Write-StatusSnapshot -State "running" -Ok $null -ExitCode 259 -Message "Hermes install is running."
Append-LogLine -Message ("Starting silent install with script: {0}" -f $InstallScript)

$PreviousNoStartDashboard = $env:HERMES_NO_START_DASHBOARD
if (-not $StartDashboard) {
  $env:HERMES_NO_START_DASHBOARD = "1"
  Append-LogLine -Message "Dashboard auto-start disabled for silent install."
}

$InstallArgs = @()
if ($Portable) {
  $InstallArgs += "-Portable"
}

try {
  & $InstallScript @InstallArgs *>> $ResolvedLogFile
  Append-LogLine -Message "Hermes silent install finished successfully."
  Write-StatusSnapshot -State "succeeded" -Ok $true -ExitCode 0 -Message "Hermes install completed successfully."
  exit 0
} catch {
  $ExitCode = if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } else { 1 }
  $ErrorText = $_ | Out-String
  Append-LogLine -Message "Hermes silent install failed."
  if ($ErrorText) {
    Add-Content -Path $ResolvedLogFile -Value $ErrorText -Encoding UTF8
  }
  Write-StatusSnapshot -State "failed" -Ok $false -ExitCode $ExitCode -Message $_.Exception.Message
  exit $ExitCode
} finally {
  if ($null -eq $PreviousNoStartDashboard) {
    Remove-Item Env:HERMES_NO_START_DASHBOARD -ErrorAction SilentlyContinue
  } else {
    $env:HERMES_NO_START_DASHBOARD = $PreviousNoStartDashboard
  }
}
