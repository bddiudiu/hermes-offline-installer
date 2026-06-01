#!/usr/bin/env bash
set -euo pipefail

HERMES_BIN="${HOME}/.local/bin/hermes"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CONFIG="${HERMES_HOME}/config.yaml"
ENV_FILE="${HERMES_HOME}/.env"

[ -x "$HERMES_BIN" ] || { echo "缺少 hermes shim: $HERMES_BIN" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "缺少 config.yaml" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "缺少 .env" >&2; exit 1; }

"$HERMES_BIN" version
