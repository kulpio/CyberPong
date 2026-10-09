#!/bin/bash
# Install CyberPong to /Applications and relaunch so the new binary is always running.
#   --login       also open CyberPong at login
#   --developer   the owner's own Mac only: the graph-planning chat may fix CyberPong itself
#                 (merges "developer": true into the state folder's settings.json; nothing else changes)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGIN=0
DEVELOPER=0
for arg in "$@"; do
  case "$arg" in
    --login) LOGIN=1 ;;
    --developer) DEVELOPER=1 ;;
    *) echo "  (warn: unknown option $arg ignored; known: --login, --developer)" >&2 ;;
  esac
done

# settings.json "developer": true, merged in: every other key is kept, the file is written through a
# temp file created at 0600 in the same folder and renamed into place, and a file that can't be read
# is left alone (said so) rather than replaced. The app has no switch for it; nobody else's default changes.
write_developer_setting() {
  local state="${PONG_HOME:-$HOME/.pong}"
  mkdir -p "$state"
  chmod 700 "$state" 2>/dev/null || true
  python3 - "$state/settings.json" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except (OSError, ValueError) as e:
    sys.exit(f"  (warn: {path} could not be read ({type(e).__name__}); developer not set. "
             "Fix or move the file, then run install.sh --developer again)")
if not isinstance(data, dict):
    sys.exit(f"  (warn: {path} is not a settings object; developer not set)")
data["developer"] = True
fd, tmp = tempfile.mkstemp(prefix=".settings.json.", suffix=".tmp", dir=os.path.dirname(path))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("  developer: on (the graph-planning chat may fix CyberPong itself on this Mac)")
PY
}

# Dock / Finder name comes from the .app basename — must be CyberPong.app
BUNDLE_NAME="CyberPong"
APP_NAME="${BUNDLE_NAME}.app"
SRC_APP="$ROOT/dist/$APP_NAME"
DEST="/Applications/$APP_NAME"

# Keep control-plane CLI in sync with this checkout (Save session / continuity vault).
# App binary alone is not enough — SessionArchive shells out to ~/bin/pong → ~/.pong/lib.
if [[ -f "$ROOT/scripts/install-control-plane.sh" ]]; then
  bash "$ROOT/scripts/install-control-plane.sh"
fi

# The graph runner (launchd agent com.cyberpong.runtime): without it a graph never
# moves past its first step. Written by the installed engine; a loaded runner is
# restarted on the engine just installed.
if [[ -x "$HOME/bin/pong" ]]; then
  "$HOME/bin/pong" runtime install-agent \
    || echo "  (warn: the graph runner could not be installed — run: pong runtime install-agent)"
fi

# Quit any running copy (including legacy names) so we never leave an old binary alive.
# Without this, `open` can attach to the already-running process and the install
# appears to “do nothing” until you quit by hand.
quit_apps() {
  local name
  for name in CyberPong Pong HermesPong Hermes_Pairing HermesClaude; do
    osascript -e "tell application \"$name\" to quit" 2>/dev/null || true
  done
  # Give graceful quit a moment, then force leftover processes.
  sleep 0.6
  for name in CyberPong Pong HermesPong Hermes_Pairing HermesClaude; do
    pkill -x "$name" 2>/dev/null || true
  done
  # Bundle executable paths (covers renamed/stale launches)
  # Executable inside the bundle is still "Pong" for binary-name stability.
  pkill -f "/Applications/CyberPong.app/Contents/MacOS/Pong" 2>/dev/null || true
  pkill -f "/Applications/Pong.app/Contents/MacOS/Pong" 2>/dev/null || true
  pkill -f "/Applications/HermesPong.app/Contents/MacOS/HermesPong" 2>/dev/null || true
  pkill -f "$ROOT/dist/CyberPong.app/Contents/MacOS/Pong" 2>/dev/null || true
  pkill -f "$ROOT/dist/Pong.app/Contents/MacOS/Pong" 2>/dev/null || true
  sleep 0.2
}

quit_apps

# With the app quit, so nothing writes settings.json at the same moment
if [[ "$DEVELOPER" == 1 ]]; then
  write_developer_setting || echo "  (warn: developer not set)"
fi

# Remove old app bundle names from /Applications (legacy Dock labels)
rm -rf \
  /Applications/Pong.app \
  /Applications/Hermes_Pairing.app \
  /Applications/HermesClaude.app \
  /Applications/HermesPong.app \
  2>/dev/null || true

# Build when there is no build, or when a Swift source is newer than it: the
# old check reinstalled a stale dist/ build as if it were this checkout. Every
# Swift source is in src/ (the notch panel too, since 2.1).
if [[ ! -d "$SRC_APP" ]] || [[ -n "$(find "$ROOT/src" -name '*.swift' -newer "$SRC_APP/Contents/MacOS/Pong" 2>/dev/null | head -1)" ]]; then
  bash "$ROOT/scripts/build-app.sh"
fi

rm -rf "$DEST"
cp -R "$SRC_APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
# Re-sign ad-hoc (no --deep) only if the bundle isn't Developer ID signed —
# re-signing a notarized app would strip its valid signature.
if ! codesign -dv "$DEST" 2>&1 | grep -q "Authority=Developer ID"; then
  codesign -s - --force "$DEST" 2>/dev/null || true
fi

# Refresh Launch Services so Dock/Spotlight pick up CyberPong (not cached "Pong")
if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" 2>/dev/null || true
fi

echo "Installed: $DEST (CyberPong)"

if [[ "$LOGIN" == 1 ]]; then
  osascript <<EOF
tell application "System Events"
  try
    delete login item "HermesPong"
  end try
  try
    delete login item "Hermes_Pairing"
  end try
  try
    delete login item "HermesClaude"
  end try
  try
    delete login item "Pong"
  end try
  try
    delete login item "CyberPong"
  end try
  make login item at end with properties {path:"$DEST", hidden:false}
end tell
EOF
  echo "Login item enabled."
fi

# Fresh launch only (never reuse a lingering instance)
open -n -a "$DEST"
echo "Launched CyberPong (fresh process)."
