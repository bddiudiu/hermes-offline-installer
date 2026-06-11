#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
unset PYTHONHOME PYTHONPATH
INSTALL_ROOT="${HERMES_OFFLINE_HOME:-$HOME/.hermes-offline}"
RUNTIME_DIR="$INSTALL_ROOT/runtime"
BIN_DIR="$HOME/.local/bin"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
VENV_DIR="$RUNTIME_DIR/venv"
RUNTIME_WHEELHOUSE="$RUNTIME_DIR/wheelhouse"
RUNTIME_TEMPLATES="$RUNTIME_DIR/templates"
RUNTIME_BUNDLE="$RUNTIME_DIR/bundle-runtime"
RUNTIME_RESOURCES="$RUNTIME_DIR/hermes-resources"

mkdir -p "$RUNTIME_DIR" "$BIN_DIR" "$HERMES_HOME"

sync_bundled_skills() {
  mkdir -p "$HERMES_HOME/skills"
  echo "Syncing bundled Agent Skills to $HERMES_HOME/skills ..."
  HERMES_HOME="$HERMES_HOME" \
    HERMES_BUNDLED_SKILLS="$RUNTIME_RESOURCES/skills" \
    HERMES_OPTIONAL_SKILLS="$RUNTIME_RESOURCES/optional-skills" \
    HERMES_OPTIONAL_MCPS="$RUNTIME_RESOURCES/optional-mcps" \
    HERMES_BUNDLED_LOCALES="$RUNTIME_RESOURCES/locales" \
    HERMES_BUNDLED_PLUGINS="$RUNTIME_RESOURCES/plugins" \
    HERMES_WEB_DIST="$RUNTIME_RESOURCES/web_dist" \
    "$VENV_PYTHON" -m tools.skills_sync

  if [ -f "$HERMES_HOME/.no-bundled-skills" ]; then
    echo "Bundled Agent Skills sync skipped because .no-bundled-skills is present."
    return
  fi

  if ! find "$HERMES_HOME/skills" -name SKILL.md -type f -print -quit | grep -q .; then
    echo "Bundled Agent Skills were not installed into $HERMES_HOME/skills" >&2
    exit 1
  fi
  for required_skill in \
    "$HERMES_HOME/skills/apple/imessage/SKILL.md" \
    "$HERMES_HOME/skills/autonomous-ai-agents/codex/SKILL.md"; do
    if [ ! -f "$required_skill" ]; then
      echo "Bundled Agent Skill is missing after sync: $required_skill" >&2
      exit 1
    fi
  done
}

if [ ! -d "$BUNDLE_DIR/wheelhouse" ]; then
  echo "缺少 wheelhouse：$BUNDLE_DIR/wheelhouse" >&2
  exit 1
fi
if [ ! -d "$BUNDLE_DIR/hermes-resources" ]; then
  echo "缺少 Hermes runtime resources：$BUNDLE_DIR/hermes-resources" >&2
  exit 1
fi

rm -rf "$RUNTIME_WHEELHOUSE" "$RUNTIME_TEMPLATES" "$RUNTIME_BUNDLE" "$RUNTIME_RESOURCES" "$VENV_DIR"
cp -R "$BUNDLE_DIR/wheelhouse" "$RUNTIME_WHEELHOUSE"
cp -R "$BUNDLE_DIR/templates" "$RUNTIME_TEMPLATES"
cp -R "$BUNDLE_DIR/runtime" "$RUNTIME_BUNDLE"
cp -R "$BUNDLE_DIR/hermes-resources" "$RUNTIME_RESOURCES"

PYTHON_BIN=""
REQUESTED_PYTHON="${HERMES_PYTHON:-}"
for candidate in \
  "$RUNTIME_BUNDLE/python/bin/python3" \
  "$RUNTIME_BUNDLE/python/bin/python" \
  "$RUNTIME_BUNDLE/python/python"; do
  if [ -z "$PYTHON_BIN" ] && [ -x "$candidate" ]; then
    PYTHON_BIN="$candidate"
    break
  fi
done

if [ -z "$PYTHON_BIN" ] && [ -n "$REQUESTED_PYTHON" ] && [ -x "$REQUESTED_PYTHON" ]; then
  requested_real="$(cd "$(dirname "$REQUESTED_PYTHON")" && pwd -P)/$(basename "$REQUESTED_PYTHON")"
  venv_real="$(mkdir -p "$VENV_DIR" && cd "$VENV_DIR" && pwd -P)"
  if [[ "$requested_real" != "$venv_real"/* ]]; then
    PYTHON_BIN="$requested_real"
  else
    echo "Ignoring HERMES_PYTHON because it points inside the install venv: $requested_real"
  fi
elif [ -z "$PYTHON_BIN" ] && [ -n "$REQUESTED_PYTHON" ]; then
  echo "Ignoring unavailable HERMES_PYTHON: $REQUESTED_PYTHON"
fi

if [ -z "$PYTHON_BIN" ]; then
  echo "未找到包内 Python runtime。请确认 bundle/runtime/python 已包含 portable Python。" >&2
  exit 1
fi

"$PYTHON_BIN" -m venv "$VENV_DIR"
VENV_PYTHON="$VENV_DIR/bin/python"
RUNTIME_PACKAGES=(
  "aiohttp==3.13.4"
  "fastapi==0.133.1"
  "python-multipart"
  "uvicorn==0.41.0"
  "websockets"
)
"$VENV_PYTHON" -m pip install --only-binary=:all: --no-index --find-links "$RUNTIME_WHEELHOUSE" "hermes-agent[all]" croniter "${RUNTIME_PACKAGES[@]}"

if [ ! -x "$VENV_DIR/bin/hermes" ]; then
  echo "Hermes executable was not created: $VENV_DIR/bin/hermes" >&2
  exit 1
fi

HERMES_HOME_SH="$(printf '%q' "$HERMES_HOME")"
HERMES_BIN_SH="$(printf '%q' "$VENV_DIR/bin/hermes")"
HERMES_PYTHON_SH="$(printf '%q' "$VENV_PYTHON")"
HERMES_BUNDLED_SKILLS_SH="$(printf '%q' "$RUNTIME_RESOURCES/skills")"
HERMES_OPTIONAL_SKILLS_SH="$(printf '%q' "$RUNTIME_RESOURCES/optional-skills")"
HERMES_OPTIONAL_MCPS_SH="$(printf '%q' "$RUNTIME_RESOURCES/optional-mcps")"
HERMES_BUNDLED_LOCALES_SH="$(printf '%q' "$RUNTIME_RESOURCES/locales")"
HERMES_BUNDLED_PLUGINS_SH="$(printf '%q' "$RUNTIME_RESOURCES/plugins")"
HERMES_WEB_DIST_SH="$(printf '%q' "$RUNTIME_RESOURCES/web_dist")"

cat > "$BIN_DIR/hermes" <<EOF
#!/usr/bin/env bash
export HERMES_HOME=$HERMES_HOME_SH
export HERMES_PYTHON=$HERMES_PYTHON_SH
export HERMES_BUNDLED_SKILLS=$HERMES_BUNDLED_SKILLS_SH
export HERMES_OPTIONAL_SKILLS=$HERMES_OPTIONAL_SKILLS_SH
export HERMES_OPTIONAL_MCPS=$HERMES_OPTIONAL_MCPS_SH
export HERMES_BUNDLED_LOCALES=$HERMES_BUNDLED_LOCALES_SH
export HERMES_BUNDLED_PLUGINS=$HERMES_BUNDLED_PLUGINS_SH
export HERMES_WEB_DIST=$HERMES_WEB_DIST_SH
exec $HERMES_BIN_SH "\$@"
EOF
chmod +x "$BIN_DIR/hermes"

if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cp "$RUNTIME_TEMPLATES/config.yaml" "$HERMES_HOME/config.yaml"
fi

if [ ! -f "$HERMES_HOME/.env" ]; then
  cp "$RUNTIME_TEMPLATES/env.template" "$HERMES_HOME/.env"
fi

sync_bundled_skills
"$BIN_DIR/hermes" version

echo "Hermes Agent 已安装。"
echo "shim: $BIN_DIR/hermes"
echo "config: $HERMES_HOME/config.yaml"
echo "skills: $HERMES_HOME/skills"
echo "resources: $RUNTIME_RESOURCES"
echo "如果当前终端找不到 hermes，请把 $BIN_DIR 加入 PATH 或重新打开终端。"
