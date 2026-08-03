#!/bin/bash
# Install CyberPong — control plane CLIs + optional macOS app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Checking prerequisites…"
command -v tmux >/dev/null || { echo "Installing tmux…"; brew install tmux; }
command -v python3 >/dev/null || { echo "Need python3"; exit 1; }

# Shared path: always refresh ~/.pong/lib (includes session_archive / continuity CLI)
bash "$ROOT/scripts/install-control-plane.sh"

echo "→ Migrate legacy state if needed…"
"$HOME/bin/pong" migrate 2>/dev/null || true

if command -v swiftc >/dev/null 2>&1; then
  echo "→ Building macOS app…"
  if bash "$ROOT/scripts/build-app.sh"; then
    if [[ -f "$ROOT/scripts/install.sh" ]]; then
      # install.sh may still reference HermesPong.app — copy Pong.app if present
      if [[ -d "$ROOT/dist/Pong.app" ]]; then
        rm -rf "/Applications/Pong.app"
        cp -R "$ROOT/dist/Pong.app" "/Applications/Pong.app"
        echo "→ Installed /Applications/Pong.app"
      fi
    fi
  else
    echo "  (app build failed — CLIs still installed)"
  fi
else
  echo "→ Skipping app build (no swiftc)"
fi

if [[ "${1:-}" == "--with-skills" || "${INSTALL_SKILLS:-}" == "1" ]]; then
  bash "$ROOT/scripts/install-skills.sh" all
fi

echo ""
echo "Done — Pong 2.0.0-alpha"
echo "  pong status | pong gate | pong job create --worker w1 --task '…'"
echo "  State: ~/.pong   Docs: docs/ARCHITECTURE.md"
echo "  Repo:  https://github.com/kulpio/hermes-pong"
