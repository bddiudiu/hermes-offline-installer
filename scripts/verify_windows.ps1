$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = (Resolve-Path (Join-Path $ScriptDir "..") -ErrorAction SilentlyContinue)
$BundleDirPath = if ($BundleDir) { $BundleDir.Path } else { $ScriptDir }

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

function Get-WindowsDefaultHermesHome {
  $ProgramDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
  return (Join-Path $ProgramDataRoot "SSC\Hermes")
}

function Get-WindowsDefaultHermesOfflineHome {
  $ProgramFilesRoot = if ($env:ProgramFiles) { $env:ProgramFiles } else { "C:\Program Files" }
  return (Join-Path $ProgramFilesRoot "StarSoftComm\ZhanClaw\Hermes")
}

$LocalPortableRoot = Join-Path $BundleDirPath ".hermes-offline"
$LocalPortableHome = Join-Path $BundleDirPath ".hermes"
$LegacyInstallRoot = Join-Path $env:USERPROFILE ".hermes-offline"
$LegacyHermesHome = Join-Path $env:USERPROFILE ".hermes"
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
$PortableMode = (-not $CustomInstallRoot) -and (Test-Path (Join-Path $LocalPortableRoot "bin\hermes.cmd"))
$InstallRoot = if ($CustomInstallRoot) {
  $CustomInstallRoot
} elseif ($PortableMode) {
  $LocalPortableRoot
} else {
  Get-WindowsDefaultHermesOfflineHome
}
$HermesHome = if ($CustomHermesHome) {
  $CustomHermesHome
} elseif ($PortableMode -and (Test-Path $LocalPortableHome)) {
  $LocalPortableHome
} else {
  Get-WindowsDefaultHermesHome
}
$BinDir = Join-Path $InstallRoot "bin"
$HermesCmd = Join-Path $BinDir "hermes.cmd"
$ResourcesDir = Join-Path $InstallRoot "runtime\hermes-resources"
$Config = Join-Path $HermesHome "config.yaml"
$EnvFile = Join-Path $HermesHome ".env"
$SkillsDir = Join-Path $HermesHome "skills"
$LegacyShimDirs = @((Join-Path $env:USERPROFILE ".local\bin"), $LegacyOfflineBinDir)
if ($env:APPDATA) {
  $LegacyShimDirs += (Join-Path $env:APPDATA "uv\tools\bin")
  $LegacyShimDirs += (Join-Path $env:APPDATA "clawpanel\bin")
}
$LegacyShimDirs = $LegacyShimDirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

if (-not (Test-Path $HermesCmd)) { throw "缺少 hermes shim: $HermesCmd" }
$HermesUninstallCmd = Join-Path $InstallRoot "bin\hermes-uninstall.cmd"
if (-not (Test-Path $HermesUninstallCmd)) { throw "缺少 hermes uninstall shim: $HermesUninstallCmd" }
$HermesExeShim = Join-Path $BinDir "hermes.exe"
if (-not (Test-Path $HermesExeShim)) { throw "缺少 hermes.exe shim: $HermesExeShim" }
if (-not (Test-Path $Config)) { throw "缺少 config.yaml" }
$ConfigText = Get-Content -Raw -Path $Config
if ($ConfigText -notmatch '(?m)^\s+default\s*:\s*qwen3\s*(#.*)?$') { throw "config.yaml 未默认选择 qwen3 模型" }
if ($ConfigText -notmatch 'provider:\s*custom:zhan_ai') { throw "config.yaml 未默认选择 zhan_ai 渠道" }
if ($ConfigText -notmatch 'zhan_ai:' -or $ConfigText -notmatch 'ZHANCLAW_BASE_URL' -or $ConfigText -notmatch 'ZHANCLAW_API_KEY') { throw "config.yaml 缺少 zhan_ai provider 配置" }
if ($ConfigText -match '(?m)^api_server_port\s*:') { throw "config.yaml 仍包含旧 api_server_port 配置" }
if ($ConfigText -notmatch '(?s)platforms:.*api_server:.*enabled:\s*true.*extra:.*port\s*:\s*[^#\r\n]+') { throw "config.yaml 缺少 platforms.api_server.extra.port 配置" }
if (-not (Test-Path $EnvFile)) { throw "缺少 .env" }
if (-not (Test-Path $SkillsDir)) { throw "缺少 Agent Skills 目录: $SkillsDir" }
$SkillFiles = @(Get-ChildItem -Path $SkillsDir -Recurse -Filter "SKILL.md" -File -ErrorAction SilentlyContinue)
if ($SkillFiles.Count -eq 0) { throw "Agent Skills 目录中缺少 SKILL.md: $SkillsDir" }
if (-not (Test-Path (Join-Path $SkillsDir "apple\imessage\SKILL.md"))) { throw "缺少 apple Agent Skill" }
if (-not (Test-Path (Join-Path $SkillsDir "autonomous-ai-agents\codex\SKILL.md"))) { throw "缺少 autonomous-ai-agents Agent Skill" }
if (-not (Test-Path (Join-Path $ResourcesDir "optional-skills\productivity\memento-flashcards\SKILL.md"))) { throw "缺少 optional Agent Skills 资源" }
if (-not (Test-Path (Join-Path $ResourcesDir "optional-mcps\linear\manifest.yaml"))) { throw "缺少 optional MCP 资源" }
if (-not (Test-Path (Join-Path $ResourcesDir "locales\en.yaml"))) { throw "缺少 locales 资源" }
if (-not (Test-Path (Join-Path $ResourcesDir "plugins\disk-cleanup\plugin.yaml"))) { throw "缺少 bundled plugins 资源" }
if (-not (Test-Path (Join-Path $ResourcesDir "web_dist\index.html"))) { throw "缺少 Dashboard web_dist 资源" }
if (-not (Test-Path (Join-Path $ResourcesDir "tui_dist\dist\entry.js"))) { throw "缺少 Dashboard TUI dist 资源" }
if (-not (Test-Path (Join-Path $ResourcesDir "tui_dist\package.json"))) { throw "缺少 Dashboard TUI package.json 资源" }

foreach ($RequiredShimName in @("hermes.cmd", "dashboard.cmd", "hermes-launch.cmd", "hermes-shutdown.cmd", "hermes-uninstall.cmd")) {
  $RequiredShim = Join-Path $BinDir $RequiredShimName
  if (-not (Test-Path $RequiredShim)) { throw "缺少 shim: $RequiredShim" }
  $RequiredShimText = Get-Content -Raw -Path $RequiredShim
  if ($RequiredShimText -notmatch 'HERMES_OFFLINE_HOME') { throw "$RequiredShimName 未设置 HERMES_OFFLINE_HOME" }
  if ($RequiredShimText -notmatch 'HERMES_TUI_DIR') { throw "$RequiredShimName 未设置 HERMES_TUI_DIR" }
}
if (-not $PortableMode) {
  foreach ($LegacyShimDir in $LegacyShimDirs) {
    foreach ($LegacyShimName in @("hermes.cmd", "dashboard.cmd", "hermes-launch.cmd", "hermes-repair.cmd", "hermes-shutdown.cmd", "hermes-uninstall.cmd", "hermes.exe")) {
      $LegacyShim = Join-Path $LegacyShimDir $LegacyShimName
      if (Test-Path $LegacyShim) { throw "旧 user shim 未清理: $LegacyShim" }
    }
  }
}

& $HermesCmd version
