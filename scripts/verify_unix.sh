#!/usr/bin/env bash
set -euo pipefail

HERMES_BIN="${HOME}/.local/bin/hermes"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CONFIG="${HERMES_HOME}/config.yaml"
ENV_FILE="${HERMES_HOME}/.env"
SKILLS_DIR="${HERMES_HOME}/skills"

[ -x "$HERMES_BIN" ] || { echo "缺少 hermes shim: $HERMES_BIN" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "缺少 config.yaml" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "缺少 .env" >&2; exit 1; }
[ -d "$SKILLS_DIR" ] || { echo "缺少 Agent Skills 目录: $SKILLS_DIR" >&2; exit 1; }
find "$SKILLS_DIR" -name SKILL.md -type f -print -quit | grep -q . || {
  echo "Agent Skills 目录中缺少 SKILL.md: $SKILLS_DIR" >&2
  exit 1
}

"$HERMES_BIN" version
