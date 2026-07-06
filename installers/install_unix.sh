#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
unset PYTHONHOME PYTHONPATH
LOCAL_PORTABLE_ROOT="$BUNDLE_DIR/.hermes-offline"
if [ -n "${HERMES_OFFLINE_HOME:-}" ]; then
  INSTALL_ROOT="$HERMES_OFFLINE_HOME"
elif [ "${HERMES_PORTABLE_MODE:-}" = "1" ] || [ -x "$LOCAL_PORTABLE_ROOT/bin/hermes" ]; then
  INSTALL_ROOT="$LOCAL_PORTABLE_ROOT"
else
  INSTALL_ROOT="$HOME/.hermes-offline"
fi
RUNTIME_DIR="$INSTALL_ROOT/runtime"
if [ "${HERMES_PORTABLE_MODE:-}" = "1" ] || [ "$INSTALL_ROOT" = "$LOCAL_PORTABLE_ROOT" ]; then
  BIN_DIR="$INSTALL_ROOT/bin"
  HERMES_HOME="${HERMES_HOME:-$BUNDLE_DIR/.hermes}"
else
  BIN_DIR="$HOME/.local/bin"
  HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
fi
VENV_DIR="$RUNTIME_DIR/venv"
RUNTIME_WHEELHOUSE="$RUNTIME_DIR/wheelhouse"
RUNTIME_TEMPLATES="$RUNTIME_DIR/templates"
RUNTIME_BUNDLE="$RUNTIME_DIR/bundle-runtime"
RUNTIME_RESOURCES="$RUNTIME_DIR/hermes-resources"

mkdir -p "$BIN_DIR" "$HERMES_HOME"

RUNTIME_BACKUP_DIR=""
RUNTIME_INSTALL_COMMITTED=0

restore_runtime_on_error() {
  local exit_code=$?
  if [ "${RUNTIME_INSTALL_COMMITTED:-0}" = "1" ]; then
    exit "$exit_code"
  fi

  echo "Hermes install/upgrade failed. Restoring the previous runtime if one was backed up." >&2
  if [ -n "${RUNTIME_BACKUP_DIR:-}" ] && [ -d "$RUNTIME_BACKUP_DIR" ]; then
    rm -rf "$RUNTIME_DIR"
    mv "$RUNTIME_BACKUP_DIR" "$RUNTIME_DIR"
    echo "Restored previous Hermes runtime: $RUNTIME_DIR" >&2
  elif [ -z "${RUNTIME_BACKUP_DIR:-}" ] && [ -d "$RUNTIME_DIR" ]; then
    rm -rf "$RUNTIME_DIR"
  fi
  exit "$exit_code"
}

backup_existing_runtime() {
  if [ ! -d "$RUNTIME_DIR" ]; then
    mkdir -p "$RUNTIME_DIR"
    return
  fi

  local parent
  local name
  local timestamp
  local candidate
  local index
  parent="$(dirname "$RUNTIME_DIR")"
  name="$(basename "$RUNTIME_DIR")"
  timestamp="$(date +%Y%m%d%H%M%S)"
  candidate="$parent/$name.old.$timestamp"
  index=0
  while [ -e "$candidate" ]; do
    index=$((index + 1))
    candidate="$parent/$name.old.$timestamp.$index"
  done

  RUNTIME_BACKUP_DIR="$candidate"
  mv "$RUNTIME_DIR" "$RUNTIME_BACKUP_DIR"
  echo "Backed up previous Hermes runtime: $RUNTIME_BACKUP_DIR"
  mkdir -p "$RUNTIME_DIR"
}

generate_api_server_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
  printf '\n'
}

dotenv_value_is_weak() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [ "${#value}" -ge 2 ]; then
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
  fi
  [ -z "$value" ] || [ "$value" = "clawpanel-local" ] || [ "${#value}" -lt 16 ]
}

ensure_api_server_key() {
  local env_path="$1"
  local existing_value=""
  local line
  if [ -f "$env_path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*API_SERVER_KEY[[:space:]]*= ]]; then
        existing_value="${line#*=}"
      fi
    done < "$env_path"
  fi

  if ! dotenv_value_is_weak "$existing_value"; then
    return
  fi

  local new_key
  local tmp_path
  new_key="$(generate_api_server_key)"
  tmp_path="${env_path}.tmp.$$"
  if [ -f "$env_path" ]; then
    grep -vE '^[[:space:]]*API_SERVER_KEY[[:space:]]*=' "$env_path" > "$tmp_path" || true
  else
    : > "$tmp_path"
  fi
  if [ -s "$tmp_path" ] && [ "$(tail -c 1 "$tmp_path")" != "" ]; then
    printf '\n' >> "$tmp_path"
  fi
  printf 'API_SERVER_KEY=%s\n' "$new_key" >> "$tmp_path"
  mv "$tmp_path" "$env_path"
  echo "Generated a strong API_SERVER_KEY in $env_path."
}

sync_bundled_skills() {
  mkdir -p "$HERMES_HOME/skills"
  echo "Syncing bundled Agent Skills to $HERMES_HOME/skills ..."
  HERMES_HOME="$HERMES_HOME" \
    HERMES_OFFLINE_HOME="$INSTALL_ROOT" \
    HERMES_BUNDLED_SKILLS="$RUNTIME_RESOURCES/skills" \
    HERMES_OPTIONAL_SKILLS="$RUNTIME_RESOURCES/optional-skills" \
    HERMES_OPTIONAL_MCPS="$RUNTIME_RESOURCES/optional-mcps" \
    HERMES_BUNDLED_LOCALES="$RUNTIME_RESOURCES/locales" \
    HERMES_BUNDLED_PLUGINS="$RUNTIME_RESOURCES/plugins" \
    HERMES_WEB_DIST="$RUNTIME_RESOURCES/web_dist" \
    HERMES_TUI_DIR="$RUNTIME_RESOURCES/tui_dist" \
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

trap restore_runtime_on_error ERR
backup_existing_runtime
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
RUNTIME_REQUIREMENTS="$RUNTIME_WHEELHOUSE/requirements.txt"
if [ ! -f "$RUNTIME_REQUIREMENTS" ]; then
  echo "缺少 wheelhouse requirements: $RUNTIME_REQUIREMENTS" >&2
  exit 1
fi
echo "Installing Hermes requirements: $RUNTIME_REQUIREMENTS"
"$VENV_PYTHON" -m pip install --only-binary=:all: --no-index --find-links "$RUNTIME_WHEELHOUSE" -r "$RUNTIME_REQUIREMENTS"

if [ ! -x "$VENV_DIR/bin/hermes" ]; then
  echo "Hermes executable was not created: $VENV_DIR/bin/hermes" >&2
  exit 1
fi

HERMES_HOME_SH="$(printf '%q' "$HERMES_HOME")"
HERMES_OFFLINE_HOME_SH="$(printf '%q' "$INSTALL_ROOT")"
HERMES_BIN_SH="$(printf '%q' "$VENV_DIR/bin/hermes")"
HERMES_PYTHON_SH="$(printf '%q' "$VENV_PYTHON")"
HERMES_BUNDLED_SKILLS_SH="$(printf '%q' "$RUNTIME_RESOURCES/skills")"
HERMES_OPTIONAL_SKILLS_SH="$(printf '%q' "$RUNTIME_RESOURCES/optional-skills")"
HERMES_OPTIONAL_MCPS_SH="$(printf '%q' "$RUNTIME_RESOURCES/optional-mcps")"
HERMES_BUNDLED_LOCALES_SH="$(printf '%q' "$RUNTIME_RESOURCES/locales")"
HERMES_BUNDLED_PLUGINS_SH="$(printf '%q' "$RUNTIME_RESOURCES/plugins")"
HERMES_WEB_DIST_SH="$(printf '%q' "$RUNTIME_RESOURCES/web_dist")"
HERMES_TUI_DIR_SH="$(printf '%q' "$RUNTIME_RESOURCES/tui_dist")"
HERMES_CACHE_DIR="$HERMES_HOME/cache"
mkdir -p \
  "$HERMES_CACHE_DIR/huggingface/hub" \
  "$HERMES_CACHE_DIR/torch" \
  "$HERMES_CACHE_DIR/tiktoken" \
  "$HERMES_CACHE_DIR/matplotlib" \
  "$HERMES_CACHE_DIR/nltk" \
  "$HERMES_CACHE_DIR/playwright" \
  "$HERMES_CACHE_DIR/tmp"
HERMES_CACHE_DIR_SH="$(printf '%q' "$HERMES_CACHE_DIR")"

cat > "$BIN_DIR/hermes" <<EOF
#!/usr/bin/env bash
export HERMES_HOME=$HERMES_HOME_SH
export HERMES_OFFLINE_HOME=$HERMES_OFFLINE_HOME_SH
export HERMES_PYTHON=$HERMES_PYTHON_SH
export HERMES_BUNDLED_SKILLS=$HERMES_BUNDLED_SKILLS_SH
export HERMES_OPTIONAL_SKILLS=$HERMES_OPTIONAL_SKILLS_SH
export HERMES_OPTIONAL_MCPS=$HERMES_OPTIONAL_MCPS_SH
export HERMES_BUNDLED_LOCALES=$HERMES_BUNDLED_LOCALES_SH
export HERMES_BUNDLED_PLUGINS=$HERMES_BUNDLED_PLUGINS_SH
export HERMES_WEB_DIST=$HERMES_WEB_DIST_SH
export HERMES_TUI_DIR=$HERMES_TUI_DIR_SH
HERMES_CACHE_DIR=$HERMES_CACHE_DIR_SH
export HERMES_DESKTOP_MANAGED="\${HERMES_DESKTOP_MANAGED:-1}"
export PIP_INDEX_URL="\${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
export UV_DEFAULT_INDEX="\${UV_DEFAULT_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
export HF_ENDPOINT="\${HF_ENDPOINT:-https://hf-mirror.com}"
export PLAYWRIGHT_DOWNLOAD_HOST="\${PLAYWRIGHT_DOWNLOAD_HOST:-https://npmmirror.com/mirrors/playwright}"
export npm_config_registry="\${npm_config_registry:-https://registry.npmmirror.com}"
export HF_HOME="\${HF_HOME:-\${HERMES_CACHE_DIR}/huggingface}"
export HUGGINGFACE_HUB_CACHE="\${HUGGINGFACE_HUB_CACHE:-\${HERMES_CACHE_DIR}/huggingface/hub}"
export TORCH_HOME="\${TORCH_HOME:-\${HERMES_CACHE_DIR}/torch}"
export TIKTOKEN_CACHE_DIR="\${TIKTOKEN_CACHE_DIR:-\${HERMES_CACHE_DIR}/tiktoken}"
export MPLCONFIGDIR="\${MPLCONFIGDIR:-\${HERMES_CACHE_DIR}/matplotlib}"
export NLTK_DATA="\${NLTK_DATA:-\${HERMES_CACHE_DIR}/nltk}"
export PLAYWRIGHT_BROWSERS_PATH="\${PLAYWRIGHT_BROWSERS_PATH:-\${HERMES_CACHE_DIR}/playwright}"
export TMPDIR="\${TMPDIR:-\${HERMES_CACHE_DIR}/tmp}"
exec $HERMES_BIN_SH "\$@"
EOF
chmod +x "$BIN_DIR/hermes"

if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cp "$RUNTIME_TEMPLATES/config.yaml" "$HERMES_HOME/config.yaml"
fi
"$PYTHON_BIN" "$BUNDLE_DIR/scripts/configure_config.py" "$HERMES_HOME/config.yaml"

if [ ! -f "$HERMES_HOME/.env" ]; then
  cp "$RUNTIME_TEMPLATES/env.template" "$HERMES_HOME/.env"
fi
ensure_api_server_key "$HERMES_HOME/.env"

sync_bundled_skills
"$BIN_DIR/hermes" version
RUNTIME_INSTALL_COMMITTED=1
trap - ERR
if [ -n "$RUNTIME_BACKUP_DIR" ] && [ -d "$RUNTIME_BACKUP_DIR" ]; then
  rm -rf "$RUNTIME_BACKUP_DIR" || echo "Hermes was upgraded, but the previous runtime backup could not be removed: $RUNTIME_BACKUP_DIR" >&2
fi

echo "Hermes Agent 已安装。"
echo "shim: $BIN_DIR/hermes"
echo "config: $HERMES_HOME/config.yaml"
echo "skills: $HERMES_HOME/skills"
echo "resources: $RUNTIME_RESOURCES"
echo "如果当前终端找不到 hermes，请把 $BIN_DIR 加入 PATH 或重新打开终端。"
