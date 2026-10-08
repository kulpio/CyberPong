#!/bin/bash
# Set up CyberPong from a checkout: check what it needs, install the engine, the
# `pong` command and the graph runner, then build and install the app when this
# Mac can build it (Xcode's command line tools). Safe to run again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Checking what CyberPong needs…"

# Python 3.9 or newer. /usr/bin/python3 exists even without Apple's command line
# tools, as a stub that only opens an install dialog, so `command -v` proves nothing:
# run it.
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
  echo "CyberPong needs Python 3.9 or newer."
  echo "  Install Apple's command line tools, then run this again:  xcode-select --install"
  exit 1
fi

# tmux: every AI runs in a tmux terminal. Homebrew installs it.
if ! command -v tmux >/dev/null 2>&1; then
  BREW="$(command -v brew || true)"
  [[ -z "$BREW" && -x /opt/homebrew/bin/brew ]] && BREW=/opt/homebrew/bin/brew
  [[ -z "$BREW" && -x /usr/local/bin/brew ]] && BREW=/usr/local/bin/brew
  if [[ -n "$BREW" ]]; then
    echo "→ Installing tmux with Homebrew…"
    "$BREW" install tmux
  else
    echo "CyberPong needs tmux, and tmux comes from Homebrew, which is not installed."
    echo "  1. Install Homebrew: see https://brew.sh (one line in Terminal)"
    echo "  2. Then: brew install tmux"
    echo "  3. Then run this again."
    exit 1
  fi
fi

# The engine (~/.pong/lib) and the `pong` command (~/bin/pong).
bash "$ROOT/scripts/install-control-plane.sh"

echo "→ Moving older state over if there is any…"
"$HOME/bin/pong" migrate 2>/dev/null || true

if command -v swiftc >/dev/null 2>&1; then
  # install.sh refreshes the engine, installs the graph runner, builds the app when the
  # sources are newer than the last build, copies it to /Applications and opens it.
  echo "→ Installing the graph runner and the app…"
  bash "$ROOT/scripts/install.sh"
else
  # The graph runner (launchd): without it a graph never moves past its first step.
  "$HOME/bin/pong" runtime install-agent \
    || echo "  (warn: the graph runner could not be installed — run: pong runtime install-agent)"
  echo "→ Skipping the app build (no swiftc): download the app from https://github.com/kulpio/CyberPong/releases/latest"
fi

if [[ "${1:-}" == "--with-skills" || "${INSTALL_SKILLS:-}" == "1" ]]; then
  bash "$ROOT/scripts/install-skills.sh" all
fi

VERSION="$(PYTHONPATH="$HOME/.pong/lib" python3 -c 'import pong; print(pong.__version__)' 2>/dev/null || echo "?")"
echo ""
echo "Done — CyberPong ${VERSION}"
case ":${PATH}:" in
  *":$HOME/bin:"*) ;;
  *)
    echo "  To use \`pong\` in your own Terminal, add ~/bin to your PATH:"
    echo "    echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zprofile   (then open a new Terminal window)"
    ;;
esac
echo "  Check this Mac:  pong doctor"
echo "  State: ~/.pong   Docs: docs/ARCHITECTURE.md"
echo "  Repo:  https://github.com/kulpio/CyberPong"
