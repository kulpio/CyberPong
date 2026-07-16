#!/bin/bash
# One-shot install for Hermes Pong
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Checking prerequisites…"
command -v tmux >/dev/null || { echo "Installing tmux…"; brew install tmux; }
command -v swiftc >/dev/null || { echo "Need Xcode CLT: xcode-select --install"; exit 1; }

if [[ ! -x "$ROOT/venv/bin/python" ]]; then
  echo "→ Creating Python env (project)…"
  python3 -m venv venv
  venv/bin/pip install -q -U pip
  venv/bin/pip install -q 'pyobjc-core==10.3.2' 'pyobjc-framework-Cocoa==10.3.2' 'pyobjc-framework-Quartz==10.3.2'
else
  venv/bin/pip install -q 'pyobjc-framework-Quartz==10.3.2' 2>/dev/null || true
fi

# Portable runtime for the app when project path changes
echo "→ Installing user runtime (~/.hermes-pong/venv)…"
USER_VENV="$HOME/.hermes-pong/venv"
mkdir -p "$HOME/.hermes-pong"
if [[ ! -x "$USER_VENV/bin/python" ]]; then
  python3 -m venv "$USER_VENV"
  "$USER_VENV/bin/pip" install -q -U pip
fi
"$USER_VENV/bin/pip" install -q 'pyobjc-core==10.3.2' 'pyobjc-framework-Cocoa==10.3.2' 'pyobjc-framework-Quartz==10.3.2'

echo "→ Installing bridge CLIs to ~/bin…"
mkdir -p "$HOME/bin"
for f in claude-delegate.py claude-window-relay.py pong-gate.py; do
  if [[ -f "$ROOT/scripts/$f" ]]; then
    cp "$ROOT/scripts/$f" "$HOME/bin/$f"
    chmod 755 "$HOME/bin/$f"
  fi
done

echo "→ Building…"
bash "$ROOT/scripts/build-app.sh"

echo "→ Installing…"
bash "$ROOT/scripts/install.sh" "$@"

echo ""
echo "Done — Hermes Pong 1.2"
echo "  • App: /Applications/HermesPong.app"
echo "  • Menu bar bolt + control panel"
echo "  • Bridge: ~/bin/claude-delegate.py"
echo ""
echo "Repo: https://github.com/kulpio/Hermes-Pong"
echo "Site: https://kulpio.github.io/Hermes-Pong/"

# Optional Hermes Agent skill (bridge behavior + autonomy)
if [[ "${1:-}" == "--with-hermes-skill" || "${2:-}" == "--with-hermes-skill" || "${INSTALL_HERMES_SKILL:-}" == "1" ]]; then
  echo "→ Installing optional Hermes skill pack…"
  bash "$ROOT/scripts/install-hermes-skill.sh"
else
  echo ""
  echo "Optional: make Hermes always use the bridge + autonomy like a full setup:"
  echo "  bash scripts/install-hermes-skill.sh"
  echo "  # or: bash scripts/setup.sh --with-hermes-skill"
fi

