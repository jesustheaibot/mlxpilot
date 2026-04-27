#!/usr/bin/env bash
# MLX Pilot — one-shot installer for the router stack.
#
# What this does:
#   1. Creates ~/.mlxlm/{logs,models,conversations,memory,templates}
#   2. Copies router.py + maintenance.py + requirements.txt into ~/.mlxlm/
#   3. Renders config.example.json → ~/.mlxlm/config.json (substitutes $HOME)
#   4. Creates a Python 3.11 virtualenv at ~/.mlxlm/venv and installs deps
#   5. Renders + installs both launchd plists into ~/Library/LaunchAgents/
#   6. Loads the launchd jobs (router starts immediately)
#
# Idempotent: re-running won't re-pip-install if the venv is healthy and
# won't overwrite an existing config.json. Pass --force-config to clobber.
#
# Requires: macOS 13+ (Apple Silicon strongly recommended), Python 3.11.

set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-python3.11}"
FORCE_CONFIG=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
    case "$arg" in
        --force-config) FORCE_CONFIG=1 ;;
        --python) shift; PYTHON_BIN="$1" ;;
        -h|--help)
            sed -n '2,/^set/p' "${BASH_SOURCE[0]}" | grep -E '^# ?' | sed 's/^# ?//'
            exit 0
            ;;
    esac
done

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "ERROR: $PYTHON_BIN not found. Install Python 3.11 (e.g. 'brew install python@3.11')." >&2
    exit 1
fi

MLXLM="$HOME/.mlxlm"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

echo "→ creating $MLXLM/{logs,models,conversations,memory,templates}"
mkdir -p "$MLXLM"/{logs,models,conversations,memory,templates}

echo "→ installing router.py, maintenance.py, requirements.txt"
cp "$SCRIPT_DIR/router/router.py" "$MLXLM/"
cp "$SCRIPT_DIR/router/maintenance.py" "$MLXLM/"
cp "$SCRIPT_DIR/router/requirements.txt" "$MLXLM/"

CONFIG_DEST="$MLXLM/config.json"
if [[ -f "$CONFIG_DEST" && $FORCE_CONFIG -eq 0 ]]; then
    echo "→ keeping existing $CONFIG_DEST (pass --force-config to overwrite)"
else
    echo "→ rendering $CONFIG_DEST from config.example.json"
    sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/router/config.example.json" > "$CONFIG_DEST"
fi

if [[ ! -d "$MLXLM/venv" || ! -x "$MLXLM/venv/bin/python" ]]; then
    echo "→ creating venv at $MLXLM/venv with $PYTHON_BIN"
    "$PYTHON_BIN" -m venv "$MLXLM/venv"
fi

echo "→ installing requirements (mlx-vlm pinned at 0.4.3 — do not upgrade without testing)"
"$MLXLM/venv/bin/pip" install --quiet --upgrade pip
"$MLXLM/venv/bin/pip" install --quiet -r "$MLXLM/requirements.txt"

echo "→ rendering + installing launchd plists into $LAUNCH_DIR"
mkdir -p "$LAUNCH_DIR"
for src in "$SCRIPT_DIR"/launchagents/*.plist; do
    name="$(basename "$src")"
    dest="$LAUNCH_DIR/$name"
    sed "s|__HOME__|$HOME|g" "$src" > "$dest"
    label="${name%.plist}"
    # Unload first (no-op if not loaded), then load.
    launchctl unload "$dest" 2>/dev/null || true
    launchctl load "$dest"
    echo "  loaded $label"
done

echo
echo "Setup complete."
echo "  Router log:        tail -f $MLXLM/logs/router.log"
echo "  Health check:      curl -s http://127.0.0.1:8000/health | python3 -m json.tool"
echo "  Maintenance dry:   $MLXLM/venv/bin/python $MLXLM/maintenance.py"
echo
echo "Next: download a model into $MLXLM/models/ (e.g. with hf-mlx or huggingface-cli),"
echo "then build the GUI:    cd \"$SCRIPT_DIR/.."; echo "                       bash Scripts/build_app.sh"
