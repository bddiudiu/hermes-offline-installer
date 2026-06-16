$ErrorActionPreference = "Stop"

$InstallRoot = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:USERPROFILE ".hermes" }
$HermesCmd = Join-Path $InstallRoot "bin\hermes.cmd"
$ResourcesDir = Join-Path $InstallRoot "runtime\hermes-resources"
$Config = Join-Path $HermesHome "config.yaml"
$EnvFile = Join-Path $HermesHome ".env"
$SkillsDir = Join-Path $HermesHome "skills"
$LocalBinDir = Join-Path $env:USERPROFILE ".local\bin"
$UvToolsBinDir = if ($env:APPDATA) { Join-Path $env:APPDATA "uv\tools\bin" } else { $null }
$ClawPanelBinDir = if ($env:APPDATA) { Join-Path $env:APPDATA "clawpanel\bin" } else { $null }
$ShimDirs = @((Join-Path $InstallRoot "bin"), $LocalBinDir, $UvToolsBinDir, $ClawPanelBinDir) | Where-Object { $_ } | Select-Object -Unique

if (-not (Test-Path $HermesCmd)) { throw "缺少 hermes shim: $HermesCmd" }
$HermesUninstallCmd = Join-Path $InstallRoot "bin\hermes-uninstall.cmd"
if (-not (Test-Path $HermesUninstallCmd)) { throw "缺少 hermes uninstall shim: $HermesUninstallCmd" }
foreach ($ShimDir in $ShimDirs) {
  $HermesExeShim = Join-Path $ShimDir "hermes.exe"
  if (-not (Test-Path $HermesExeShim)) {
    throw "缺少 hermes.exe shim: $HermesExeShim"
  }
}
if (-not (Test-Path $Config)) { throw "缺少 config.yaml" }
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

$HermesCmdText = Get-Content -Raw -Path $HermesCmd
if ($HermesCmdText -notmatch 'HERMES_TUI_DIR') { throw "hermes.cmd 未设置 HERMES_TUI_DIR" }

& $HermesCmd version
