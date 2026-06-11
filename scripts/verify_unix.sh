#!/usr/bin/env bash
set -euo pipefail

HERMES_BIN="${HOME}/.local/bin/hermes"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_OFFLINE_HOME="${HERMES_OFFLINE_HOME:-$HOME/.hermes-offline}"
CONFIG="${HERMES_HOME}/config.yaml"
ENV_FILE="${HERMES_HOME}/.env"
SKILLS_DIR="${HERMES_HOME}/skills"
RESOURCES_DIR="${HERMES_OFFLINE_HOME}/runtime/hermes-resources"

[ -x "$HERMES_BIN" ] || { echo "缺少 hermes shim: $HERMES_BIN" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "缺少 config.yaml" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "缺少 .env" >&2; exit 1; }
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

"$HERMES_BIN" version
