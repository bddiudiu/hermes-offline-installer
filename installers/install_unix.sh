#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_ROOT="${HERMES_OFFLINE_HOME:-$HOME/.hermes-offline}"
RUNTIME_DIR="$INSTALL_ROOT/runtime"
BIN_DIR="$HOME/.local/bin"
HERMES_HOME="$HOME/.hermes"
VENV_DIR="$RUNTIME_DIR/venv"

mkdir -p "$RUNTIME_DIR" "$BIN_DIR" "$HERMES_HOME"

if [ ! -d "$BUNDLE_DIR/wheelhouse" ]; then
  echo "缺少 wheelhouse：$BUNDLE_DIR/wheelhouse" >&2
  exit 1
fi

cp -R "$BUNDLE_DIR/wheelhouse" "$RUNTIME_DIR/"
cp -R "$BUNDLE_DIR/templates" "$RUNTIME_DIR/"
cp -R "$BUNDLE_DIR/runtime" "$RUNTIME_DIR/bundle-runtime"

PYTHON_BIN="${HERMES_PYTHON:-}"
if [ -z "$PYTHON_BIN" ]; then
  for candidate in \
    "$RUNTIME_DIR/bundle-runtime/python/bin/python3" \
    "$RUNTIME_DIR/bundle-runtime/python/bin/python" \
    "$RUNTIME_DIR/bundle-runtime/python/python"; do
    if [ -x "$candidate" ]; then
      PYTHON_BIN="$candidate"
      break
    fi
  done
fi

if [ -z "$PYTHON_BIN" ]; then
  echo "未找到包内 Python runtime。请确认 bundle/runtime/python 已包含 portable Python。" >&2
  exit 1
fi

"$PYTHON_BIN" -m venv "$VENV_DIR"
VENV_PYTHON="$VENV_DIR/bin/python"
"$VENV_PYTHON" -m pip install --no-index --find-links "$RUNTIME_DIR/wheelhouse" hermes-agent croniter

cat > "$BIN_DIR/hermes" <<EOF
#!/usr/bin/env bash
exec "$VENV_DIR/bin/hermes" "\$@"
EOF
chmod +x "$BIN_DIR/hermes"

if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cp "$RUNTIME_DIR/templates/config.yaml" "$HERMES_HOME/config.yaml"
fi

if [ ! -f "$HERMES_HOME/.env" ]; then
  cp "$RUNTIME_DIR/templates/env.template" "$HERMES_HOME/.env"
fi

"$BIN_DIR/hermes" version

echo "Hermes Agent 已安装。"
echo "shim: $BIN_DIR/hermes"
echo "config: $HERMES_HOME/config.yaml"
echo "如果当前终端找不到 hermes，请把 $BIN_DIR 加入 PATH 或重新打开终端。"
