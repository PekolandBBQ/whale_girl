#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_ROOT="${1:-$HOME/Library/Application Support/WhaleGirl}"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'macOS is required.' >&2; exit 1
fi
UV="$(command -v uv || true)"
for candidate in "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
  if [[ -z "$UV" && -x "$candidate" ]]; then UV="$candidate"; fi
done
if [[ -z "$UV" ]]; then
  echo '请先安装 uv：https://docs.astral.sh/uv/getting-started/installation/' >&2
  exit 1
fi
mkdir -p "$DATA_ROOT"
chmod 700 "$DATA_ROOT"
if [[ ! -x "$DATA_ROOT/bridge-venv/bin/python" ]]; then
  "$UV" venv --python 3.12 "$DATA_ROOT/bridge-venv"
fi
"$UV" pip install --python "$DATA_ROOT/bridge-venv/bin/python" -r "$SOURCE_ROOT/macos/bridge-requirements.txt"
echo '桥接环境已安装。请在系统设置中为桥接 Python 授权辅助功能和屏幕录制，然后重新打开鲸鲸。实际文件：'
"$DATA_ROOT/bridge-venv/bin/python" -c 'import os,sys; print(os.path.realpath(sys.executable))'
