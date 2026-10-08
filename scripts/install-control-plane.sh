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
for need in session_archive.py cli/main.py paths.py jobs.py flow.py state.py traces.py waitroom.py seat_status.py \
            claim_harvest.py claims.py groups.py loops.py work_graph.py graph_engine.py examples.py \
            mailbox.py drain.py cron.py runtime.py install.py models.py wiring.py settings.py limits.py doctor.py \
            architect.py architect_playbook.md architect_playbook_dev.md \
            jev.py jev_quality.py graph_loops.py loops/rubrics/document.json loops/rubrics/code-change.json loops/rubrics/code-change-spec.json \
            loops/rubrics/document.status.json loops/rubrics/document.probes.json \
            loops/gauntlet.json models/catalog.json review/bars/code.json; do
  if [[ ! -e "${LIB_ROOT}/pong/${need}" ]]; then
    echo "error: install incomplete — missing ${LIB_ROOT}/pong/${need}" >&2
    exit 2
  fi
done
# One import per subsystem: a file that copied but does not import is the same
# outcome as a file that never copied.
PYTHONPATH="${LIB_ROOT}" python3 -c "import pong.cli.main, pong.mailbox, pong.drain, pong.cron, pong.runtime, pong.models, pong.wiring, pong.work_graph, pong.graph_engine, pong.jev, pong.jev_quality, pong.install, pong.settings, pong.limits, pong.doctor" \
  || { echo "error: installed package does not import" >&2; exit 2; }
VERSION="$(PYTHONPATH="${LIB_ROOT}" python3 -c "import pong; print(pong.__version__)")"
printf "version=%s\nsource=%s\ninstalled_at=%s\n" "$VERSION" "$ROOT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${LIB_ROOT}/pong/INSTALL_STAMP"

# The graph kit the architect's playbook runs as {KIT} (dryrun, Perplexity research, the hand-run limit
# guard, the watcher).
KIT_SRC="$ROOT/scripts/graph-kit"
KIT_DEST="${LIB_ROOT}/graph-kit"
echo "→ Installing the graph kit to ${KIT_DEST} …"
mkdir -p "$KIT_DEST"
for tool in dryrun.py limit-guard.py pplx.py watch.py; do
  if [[ ! -f "$KIT_SRC/$tool" ]]; then
    echo "error: missing graph-kit source: $KIT_SRC/$tool" >&2
    exit 2
  fi
  cp "$KIT_SRC/$tool" "$KIT_DEST/$tool"
  chmod 755 "$KIT_DEST/$tool"
done

echo "→ Installing ~/bin/pong launcher …"
# The same text as the app's EngineInstall.launcherText (src/SetupCore.swift), to the byte.
cat > "$HOME/bin/pong" <<'EOF'
#!/usr/bin/env bash
export PYTHONPATH="${HOME}/.pong/lib${PYTHONPATH:+:$PYTHONPATH}"
# Apple's /usr/bin/python3 is only a stub until the command line tools are installed: say so instead.
if [ "$(command -v python3)" = /usr/bin/python3 ] && [ ! -d "$(/usr/bin/xcode-select -p 2>/dev/null)" ]; then
  echo "pong: Python isn't installed yet. Install Apple's command line tools (xcode-select --install), then try again." >&2
  exit 127
fi
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

# The launchd runner is one long-lived Python process: it keeps the package it
# started with in memory. Restart it so the next tick runs what was just
# installed (it ran the 1.6.0 engine for days after 1.6.1 was installed).
if launchctl print "gui/$(id -u)/com.cyberpong.runtime" >/dev/null 2>&1; then
  if launchctl kickstart -k "gui/$(id -u)/com.cyberpong.runtime" >/dev/null 2>&1; then
    echo "→ Restarted the runner (com.cyberpong.runtime) on the new package"
  else
    echo "  (warn: could not restart the runner — run: launchctl kickstart -k gui/$(id -u)/com.cyberpong.runtime)"
  fi
fi
