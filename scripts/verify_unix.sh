#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_PORTABLE_ROOT="$BUNDLE_DIR/.hermes-offline"
if [ -n "${HERMES_OFFLINE_HOME:-}" ]; then
  HERMES_OFFLINE_HOME="$HERMES_OFFLINE_HOME"
elif [ "${HERMES_PORTABLE_MODE:-}" = "1" ] || [ -x "$LOCAL_PORTABLE_ROOT/bin/hermes" ]; then
  HERMES_OFFLINE_HOME="$LOCAL_PORTABLE_ROOT"
else
  HERMES_OFFLINE_HOME="$HOME/.hermes-offline"
fi
if [ "$HERMES_OFFLINE_HOME" = "$LOCAL_PORTABLE_ROOT" ]; then
  HERMES_BIN="$HERMES_OFFLINE_HOME/bin/hermes"
  HERMES_HOME="${HERMES_HOME:-$BUNDLE_DIR/.hermes}"
else
  HERMES_BIN="${HOME}/.local/bin/hermes"
  HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
fi
CONFIG="${HERMES_HOME}/config.yaml"
ENV_FILE="${HERMES_HOME}/.env"
SKILLS_DIR="${HERMES_HOME}/skills"
RESOURCES_DIR="${HERMES_OFFLINE_HOME}/runtime/hermes-resources"

[ -x "$HERMES_BIN" ] || { echo "缺少 hermes shim: $HERMES_BIN" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "缺少 config.yaml" >&2; exit 1; }
grep -qE '^[[:space:]]+default:[[:space:]]*[^#[:space:]][^#]*$' "$CONFIG" || { echo "config.yaml 缺少默认模型配置" >&2; exit 1; }
grep -qE '^[[:space:]]+provider:[[:space:]]*custom:zhan_ai([[:space:]]*#.*)?$' "$CONFIG" || { echo "config.yaml 未默认选择 zhan_ai 渠道" >&2; exit 1; }
grep -q 'zhan_ai:' "$CONFIG" || { echo "config.yaml 缺少 zhan_ai provider 配置" >&2; exit 1; }
grep -q 'ZHANCLAW_BASE_URL' "$CONFIG" || { echo "config.yaml 缺少 ZHANCLAW_BASE_URL 配置" >&2; exit 1; }
grep -q 'ZHANCLAW_API_KEY' "$CONFIG" || { echo "config.yaml 缺少 ZHANCLAW_API_KEY 配置" >&2; exit 1; }
grep -qE '^[[:space:]]+-[[:space:]]*qwen3([[:space:]]*#.*)?$|^[[:space:]]+models:[[:space:]]*\[[^]]*qwen3' "$CONFIG" || { echo "config.yaml 缺少 zhan_ai qwen3 模型兜底" >&2; exit 1; }
! grep -qE '^api_server_port:' "$CONFIG" || { echo "config.yaml 仍包含旧 api_server_port 配置" >&2; exit 1; }
grep -q 'api_server:' "$CONFIG" || { echo "config.yaml 缺少 api_server 配置" >&2; exit 1; }
grep -qE '^[[:space:]]+port:[[:space:]]*[^#[:space:]]+' "$CONFIG" || { echo "config.yaml 缺少 API server port 配置" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "缺少 .env" >&2; exit 1; }
api_server_key="$(
  { grep -E '^[[:space:]]*API_SERVER_KEY[[:space:]]*=' "$ENV_FILE" || true; } | tail -n 1 |
    sed -E "s/^[^=]*=//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^\"//; s/\"$//; s/^'//; s/'$//"
)"
if [ -z "$api_server_key" ] || [ "$api_server_key" = "clawpanel-local" ] || [ "${#api_server_key}" -lt 16 ]; then
  echo ".env 中 API_SERVER_KEY 缺失或仍为弱占位符" >&2
  exit 1
fi
[ -d "$SKILLS_DIR" ] || { echo "缺少 Agent Skills 目录: $SKILLS_DIR" >&2; exit 1; }
find "$SKILLS_DIR" -name SKILL.md -type f -print -quit | grep -q . || {
  echo "Agent Skills 目录中缺少 SKILL.md: $SKILLS_DIR" >&2
  exit 1
}
[ -f "$SKILLS_DIR/apple/imessage/SKILL.md" ] || { echo "缺少 apple Agent Skill" >&2; exit 1; }
[ -f "$SKILLS_DIR/autonomous-ai-agents/codex/SKILL.md" ] || { echo "缺少 autonomous-ai-agents Agent Skill" >&2; exit 1; }
[ -f "$RESOURCES_DIR/optional-skills/productivity/memento-flashcards/SKILL.md" ] || { echo "缺少 optional Agent Skills 资源" >&2; exit 1; }
[ -f "$RESOURCES_DIR/optional-mcps/linear/manifest.yaml" ] || { echo "缺少 optional MCP 资源" >&2; exit 1; }
[ -f "$RESOURCES_DIR/locales/en.yaml" ] || { echo "缺少 locales 资源" >&2; exit 1; }
[ -f "$RESOURCES_DIR/plugins/disk-cleanup/plugin.yaml" ] || { echo "缺少 bundled plugins 资源" >&2; exit 1; }
[ -f "$RESOURCES_DIR/web_dist/index.html" ] || { echo "缺少 Dashboard web_dist 资源" >&2; exit 1; }
[ -f "$RESOURCES_DIR/tui_dist/dist/entry.js" ] || { echo "缺少 Dashboard TUI dist 资源" >&2; exit 1; }
[ -f "$RESOURCES_DIR/tui_dist/package.json" ] || { echo "缺少 Dashboard TUI package.json 资源" >&2; exit 1; }
grep -q 'HERMES_OFFLINE_HOME' "$HERMES_BIN" || { echo "hermes shim 未设置 HERMES_OFFLINE_HOME" >&2; exit 1; }
grep -q 'HERMES_TUI_DIR' "$HERMES_BIN" || { echo "hermes shim 未设置 HERMES_TUI_DIR" >&2; exit 1; }
for mirror_env_name in PIP_INDEX_URL UV_DEFAULT_INDEX HF_ENDPOINT PLAYWRIGHT_DOWNLOAD_HOST npm_config_registry; do
  grep -q "$mirror_env_name" "$HERMES_BIN" || {
    echo "hermes shim 未设置大陆镜像默认环境变量: $mirror_env_name" >&2
    exit 1
  }
done

"$HERMES_BIN" version
