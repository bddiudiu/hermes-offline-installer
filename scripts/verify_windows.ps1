$ErrorActionPreference = "Stop"

$InstallRoot = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:USERPROFILE ".hermes" }
$HermesCmd = Join-Path $InstallRoot "bin\hermes.cmd"
$ResourcesDir = Join-Path $InstallRoot "runtime\hermes-resources"
$Config = Join-Path $HermesHome "config.yaml"
$EnvFile = Join-Path $HermesHome ".env"
$SkillsDir = Join-Path $HermesHome "skills"

if (-not (Test-Path $HermesCmd)) { throw "缺少 hermes shim: $HermesCmd" }
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

& $HermesCmd version
