#!/bin/bash
# Install/sync Pong control-plane package → ~/.pong/lib and ~/bin/pong.
# Safe to re-run after any python/pong change (e.g. session vault / continuity CLI).
# Does not build the macOS app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_ROOT="${HOME}/.pong/lib"
PKG_SRC="$ROOT/python/pong"

if [[ ! -d "$PKG_SRC" ]]; then
  echo "error: missing package source: $PKG_SRC" >&2
  exit 1
fi

echo "→ Installing control-plane package to ${LIB_ROOT}/pong …"
mkdir -p "$HOME/bin" "$LIB_ROOT"
rm -rf "${LIB_ROOT}/pong"
# Source only — no bytecode (avoids stale .pyc / absolute co_filename leaks)
rsync -a --delete \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  "$PKG_SRC/" "${LIB_ROOT}/pong/"
find "${LIB_ROOT}/pong" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "${LIB_ROOT}/pong" -name '*.pyc' -delete 2>/dev/null || true

# Ensure new modules are present (fail loud if rsync missed)
for need in session_archive.py cli/main.py paths.py; do
  if [[ ! -f "${LIB_ROOT}/pong/${need}" ]]; then
    echo "error: install incomplete — missing ${LIB_ROOT}/pong/${need}" >&2
    exit 2
  fi
done

echo "→ Installing ~/bin/pong launcher …"
cat > "$HOME/bin/pong" <<'EOF'
#!/usr/bin/env bash
export PYTHONPATH="${HOME}/.pong/lib${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m pong.cli.main "$@"
EOF
chmod 755 "$HOME/bin/pong"

# Thin wrappers that share the same package
for pair in "pong-gate.py:gate" "pong-delegate.py:delegate" "claude-delegate.py:delegate" "pong-ledger.py:ledger"; do
  name="${pair%%:*}"
  sub="${pair##*:}"
  cat > "$HOME/bin/$name" <<EOF
#!/usr/bin/env bash
export PYTHONPATH="\${HOME}/.pong/lib\${PYTHONPATH:+:\$PYTHONPATH}"
exec python3 -m pong.cli.main $sub "\$@"
EOF
  chmod 755 "$HOME/bin/$name"
done

# hermes_pong.py status / session / write-bind (compat)
cat > "$HOME/bin/hermes_pong.py" <<'EOF'
#!/usr/bin/env python3
import sys
from pathlib import Path
sys.path.insert(0, str(Path.home() / ".pong" / "lib"))
from pong.state import (
    detect_bound_session, format_team_roster, gate_text,
    load_session_state, write_bind_card,
)
from pong.paths import state_dir
import argparse
ap = argparse.ArgumentParser()
ap.add_argument("cmd", choices=("status", "session", "write-bind"))
ap.add_argument("--session", "-s", default=None)
args = ap.parse_args()
sess = detect_bound_session(args.session)
if args.cmd == "session":
    print(sess or ""); raise SystemExit(0 if sess else 1)
if args.cmd == "write-bind":
    if not sess:
        print("no session", file=sys.stderr); raise SystemExit(2)
    print(write_bind_card(sess)); raise SystemExit(0)
st = load_session_state(sess)
g, _ = gate_text(sess)
print(f"state_dir={state_dir()}")
print(f"bound_session={sess or ''}")
print(f"gate={g}")
if st:
    print(f"roster={format_team_roster(st)}")
EOF
chmod 755 "$HOME/bin/hermes_pong.py"

echo "→ Verifying continuity CLI …"
export PATH="${HOME}/bin:${PATH}"
export PYTHONPATH="${HOME}/.pong/lib${PYTHONPATH:+:$PYTHONPATH}"
if ! pong continuity --help >/dev/null 2>&1; then
  echo "error: pong continuity not available after install" >&2
  pong --help 2>&1 | head -20 || true
  exit 3
fi

echo "  OK: session_archive.py + continuity CLI installed"
echo "  $HOME/bin/pong"
echo "  ${LIB_ROOT}/pong/session_archive.py"
