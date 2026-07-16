#!/bin/bash
# Optional: install Hermes Agent skill + bridge CLIs so Hermes uses Pong like a full setup.
# No personal data. Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_SRC="$ROOT/share/hermes-pong-bridge"
SKILL_DST="${HERMES_HOME:-$HOME/.hermes}/skills/workflow/hermes-pong-bridge"
BIN_DIR="${HERMES_PONG_BIN:-$HOME/bin}"

echo "Hermes Pong — optional Hermes skill install"
echo "  skill → $SKILL_DST"
echo "  CLIs  → $BIN_DIR"
echo ""

if [[ ! -d "$SKILL_SRC" ]]; then
  echo "Missing skill pack at $SKILL_SRC" >&2
  exit 1
fi

# Bridge CLIs
mkdir -p "$BIN_DIR"
for f in claude-delegate.py claude-window-relay.py pong-gate.py; do
  if [[ -f "$ROOT/scripts/$f" ]]; then
    cp "$ROOT/scripts/$f" "$BIN_DIR/$f"
    chmod 755 "$BIN_DIR/$f"
    echo "  ✓ $BIN_DIR/$f"
  fi
done

# Skill pack (anonymized)
mkdir -p "$(dirname "$SKILL_DST")"
rm -rf "$SKILL_DST"
cp -R "$SKILL_SRC" "$SKILL_DST"
# ensure readable
chmod -R u+rwX,go+rX "$SKILL_DST" 2>/dev/null || true
echo "  ✓ skill installed: hermes-pong-bridge"

# Optional tiny reminder file for agents that scan ~/.hermes-pong
mkdir -p "$HOME/.hermes-pong"
cat > "$HOME/.hermes-pong/AGENT-HINT.md" <<'EOF'
# Hermes Pong active?

If `active-pair.json` has a `session`, load skill **hermes-pong-bridge** and run:

```bash
python3 ~/bin/pong-gate.py
```

If `BRIDGE_ON`, all coding goes through:

```bash
python3 ~/bin/claude-delegate.py --no-wait '… ##CLAUDE_DONE##'
```

Autonomy (Every / Done / Full) is set in the Hermes Pong control panel per pair.
EOF
echo "  ✓ ~/.hermes-pong/AGENT-HINT.md"

# Pin if hermes curator exists
if command -v hermes >/dev/null 2>&1; then
  hermes curator pin hermes-pong-bridge 2>/dev/null && echo "  ✓ skill pinned (hermes curator)" || true
fi

echo ""
echo "Done. Restart Hermes (or start a new session) so it picks up the skill."
echo "Test: python3 ~/bin/pong-gate.py"
