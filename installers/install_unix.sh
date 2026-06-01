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

mkdir -p "$RUNTIME_DIR" "$BIN_DIR" "$HERMES_HOME"

if [ ! -d "$BUNDLE_DIR/wheelhouse" ]; then
  echo "缺少 wheelhouse：$BUNDLE_DIR/wheelhouse" >&2
  exit 1
fi

rm -rf "$RUNTIME_WHEELHOUSE" "$RUNTIME_TEMPLATES" "$RUNTIME_BUNDLE" "$VENV_DIR"
cp -R "$BUNDLE_DIR/wheelhouse" "$RUNTIME_WHEELHOUSE"
cp -R "$BUNDLE_DIR/templates" "$RUNTIME_TEMPLATES"
cp -R "$BUNDLE_DIR/runtime" "$RUNTIME_BUNDLE"

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
  "aiohttp==3.13.3"
  "fastapi==0.133.1"
  "uvicorn==0.41.0"
  "websockets"
)
"$VENV_PYTHON" -m pip install --only-binary=:all: --no-index --find-links "$RUNTIME_WHEELHOUSE" hermes-agent croniter "${RUNTIME_PACKAGES[@]}"

if [ ! -x "$VENV_DIR/bin/hermes" ]; then
  echo "Hermes executable was not created: $VENV_DIR/bin/hermes" >&2
  exit 1
fi

HERMES_HOME_SH="$(printf '%q' "$HERMES_HOME")"
HERMES_BIN_SH="$(printf '%q' "$VENV_DIR/bin/hermes")"
HERMES_PYTHON_SH="$(printf '%q' "$VENV_PYTHON")"

cat > "$BIN_DIR/hermes" <<EOF
#!/usr/bin/env bash
export HERMES_HOME=$HERMES_HOME_SH
export HERMES_PYTHON=$HERMES_PYTHON_SH
exec $HERMES_BIN_SH "\$@"
EOF
chmod +x "$BIN_DIR/hermes"

if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cp "$RUNTIME_TEMPLATES/config.yaml" "$HERMES_HOME/config.yaml"
fi

if [ ! -f "$HERMES_HOME/.env" ]; then
  cp "$RUNTIME_TEMPLATES/env.template" "$HERMES_HOME/.env"
fi

"$BIN_DIR/hermes" version

echo "Hermes Agent 已安装。"
echo "shim: $BIN_DIR/hermes"
echo "config: $HERMES_HOME/config.yaml"
echo "如果当前终端找不到 hermes，请把 $BIN_DIR 加入 PATH 或重新打开终端。"
