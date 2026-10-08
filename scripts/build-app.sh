#!/bin/bash
# Build CyberPong.app — native Swift menu bar + control panel
# Usage: build-app.sh [--dev]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Executable binary name (CFBundleExecutable) — keep short/stable for pkill/compat.
APP_NAME="Pong"
# Bundle folder + Dock/Finder name. macOS uses the .app basename for Dock labels.
BUNDLE_NAME="CyberPong"
DISPLAY_NAME="CyberPong"
APP="$ROOT/dist/${BUNDLE_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
VERSION="2.0.0"

DEV=0
[[ "${1:-}" == "--dev" ]] && DEV=1

# Drop legacy dist names so we never ship the wrong Dock label
rm -rf "$APP" "$ROOT/dist/Pong.app"
mkdir -p "$MACOS" "$RES"

# Universal binary: compile per-arch, lipo together. Relative source path so
# no absolute build path lands in the Mach-O.
cd "$ROOT"
# Compile all Swift sources in src/ (panel split out for maintainability)
SWIFT_SRCS=(src/*.swift)
# --dev enables #if DEBUG (local checkout paths). Release builds omit -DDEBUG so
# the checkout's own folder never lands in the Mach-O.
SWIFT_FLAGS=(-O)
if [[ "$DEV" == "1" ]]; then
  SWIFT_FLAGS+=(-DDEBUG)
fi
swiftc "${SWIFT_FLAGS[@]}" -o "$MACOS/$APP_NAME-arm64" "${SWIFT_SRCS[@]}" \
  -framework AppKit -framework Foundation -framework SceneKit -framework QuartzCore -framework Metal -framework MetalKit \
  -target arm64-apple-macosx13.0
swiftc "${SWIFT_FLAGS[@]}" -o "$MACOS/$APP_NAME-x86_64" "${SWIFT_SRCS[@]}" \
  -framework AppKit -framework Foundation -framework SceneKit -framework QuartzCore -framework Metal -framework MetalKit \
  -target x86_64-apple-macosx13.0
lipo -create -output "$MACOS/$APP_NAME" "$MACOS/$APP_NAME-arm64" "$MACOS/$APP_NAME-x86_64"
rm -f "$MACOS/$APP_NAME-arm64" "$MACOS/$APP_NAME-x86_64"
lipo -info "$MACOS/$APP_NAME"

cp "$ROOT/resources/menubar-template.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/menubar-template@2x.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/AppIcon.icns" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/AppIcon-1024.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/pair-illustration.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-blue.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-orange.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-black.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-monochrome.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-accent.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-mono-128.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-accent-128.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-accent-256.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active-dim.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active-bright.png" "$RES/" 2>/dev/null || true
# Brand package (logo / wordmark / menubar states / favicon)
if [[ -d "$ROOT/resources/brand/pong" ]]; then
  mkdir -p "$RES/brand"
  cp -R "$ROOT/resources/brand/pong" "$RES/brand/" 2>/dev/null || true
  # Flatten state icons into Resources for NSImage(named:)
  if [[ -d "$ROOT/resources/brand/pong/macos-menubar/state" ]]; then
    cp "$ROOT/resources/brand/pong/macos-menubar/state/"*.png "$RES/" 2>/dev/null || true
  fi
  # Master mark SVG
  cp "$ROOT/resources/brand/pong/logo/"*.svg "$RES/" 2>/dev/null || true
fi
# CyberPong public wordmark (dark + light)
if [[ -d "$ROOT/resources/brand/cyberpong" ]]; then
  mkdir -p "$RES/brand"
  cp -R "$ROOT/resources/brand/cyberpong" "$RES/brand/" 2>/dev/null || true
  if [[ -d "$ROOT/resources/brand/cyberpong/wordmark" ]]; then
    cp "$ROOT/resources/brand/cyberpong/wordmark/"*.png "$RES/" 2>/dev/null || true
    cp "$ROOT/resources/brand/cyberpong/wordmark/"*.svg "$RES/" 2>/dev/null || true
  fi
fi
cp "$ROOT/resources/cyberpong-wordmark-dark.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/cyberpong-wordmark-light.png" "$RES/" 2>/dev/null || true
# Self-contained control plane (fresh zip installs must not need setup.sh).
# Exclude __pycache__/*.pyc: compiled bytecode embeds absolute source paths
# (co_filename), which would leak /Users/... into the bundle AND evade the
# sign-notarize hygiene grep (grep -I skips binary .pyc). Ship source only.
if [[ -d "$ROOT/python/pong" ]]; then
  mkdir -p "$RES/python"
  rsync -a --delete --exclude='__pycache__' --exclude='*.pyc' \
    "$ROOT/python/pong/" "$RES/python/pong/"
  # Belt-and-suspenders in case a stale cache slipped in before --exclude ran.
  find "$RES/python" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find "$RES/python" -name '*.pyc' -delete 2>/dev/null || true
  if [[ ! -f "$RES/python/pong/session_archive.py" ]]; then
    echo "error: bundle missing session_archive.py (vault)" >&2
    exit 2
  fi
  echo "→ Bundled python/pong into Resources (source only, no bytecode)"
  for need in review_init.py review_bar.py ticker.py groups.py; do
    if [[ ! -f "$RES/python/pong/$need" ]]; then
      echo "error: bundle missing $need" >&2
      exit 2
    fi
  done
  # Which build this engine is: at launch the app re-seeds ~/.pong/lib/pong when the copy
  # there came from another build of the same version (and never over a newer engine).
  PY_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$RES/python/pong/__init__.py" | head -1)"
  printf "version=%s\nbuilt_at=%s\n" "$PY_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RES/python/pong/BUILD_STAMP"
  # The graph kit next to the engine (dry runs, the limit guard, Perplexity research, the
  # watcher): the app copies it to ~/.pong/lib/graph-kit.
  rm -rf "$RES/graph-kit"
  mkdir -p "$RES/graph-kit"
  for kit in dryrun.py limit-guard.py pplx.py watch.py; do
    if [[ -f "$ROOT/scripts/graph-kit/$kit" ]]; then
      cp "$ROOT/scripts/graph-kit/$kit" "$RES/graph-kit/$kit"
      chmod 755 "$RES/graph-kit/$kit"
    else
      echo "error: graph kit missing $kit" >&2
      exit 2
    fi
  done
  echo "→ Bundled graph-kit into Resources/graph-kit"
  # Also refresh ~/.pong/lib so live `pong` CLI matches this build (app Save session uses it).
  if [[ -f "$ROOT/scripts/install-control-plane.sh" ]]; then
    bash "$ROOT/scripts/install-control-plane.sh" || echo "  (warn: control-plane install failed — app still built)"
  fi
fi
# The island ships INSIDE this app.
#
# It stays its own process — it is an accessory app that owns a borderless panel
# pinned to the notch, and folding that into the map process would mean one
# window server client doing two unrelated jobs. But it is not a second thing to
# find and launch: it lives in Contents/Helpers, CyberPong starts it, and there
# is one icon in the Dock.
if [[ -x "$ROOT/island/build.sh" ]]; then
  echo "→ Building the island helper …"
  bash "$ROOT/island/build.sh" >/dev/null
  if [[ -d "$ROOT/dist/PongIsland.app" ]]; then
    mkdir -p "$CONTENTS/Helpers"
    rm -rf "$CONTENTS/Helpers/PongIsland.app"
    cp -R "$ROOT/dist/PongIsland.app" "$CONTENTS/Helpers/PongIsland.app"
    echo "  bundled Helpers/PongIsland.app"
  else
    echo "error: island build produced no app" >&2
    exit 2
  fi
fi

# Abstract tactical module textures (Imagine — conductor / worker / canvas void)
cp "$ROOT/resources/tex-conductor.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/tex-worker.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/tex-canvas.png" "$RES/" 2>/dev/null || true
# Design fonts: IBM Plex Mono for data and terminals (the UI uses the system's SF Pro), with its licence
if [[ -d "$ROOT/resources/fonts" ]]; then
  mkdir -p "$RES/fonts"
  cp "$ROOT/resources/fonts/"*.ttf "$RES/fonts/" 2>/dev/null || true
  cp "$ROOT/resources/fonts/"*.txt "$RES/fonts/" 2>/dev/null || true
fi
# The About panel's credits (fonts and their licences)
cp "$ROOT/resources/Credits.rtf" "$RES/" 2>/dev/null || true
# Team install wizard templates (SOUL / SKILL / TEAM / POLICY)
if [[ -d "$ROOT/share/team-scaffold" ]]; then
  mkdir -p "$RES/team-scaffold"
  cp -R "$ROOT/share/team-scaffold/templates" "$RES/team-scaffold/" 2>/dev/null || true
fi
# Bridge CLIs bundled so the app works without relying only on ~/bin.
# (Stdlib-only Python — used by the Hermes side and the window relay.)
for f in claude-delegate.py pong-delegate.py claude-window-relay.py pong-ledger.py hermes_pong.py pong-pbcopy; do
  if [[ -f "$ROOT/scripts/$f" ]]; then
    cp "$ROOT/scripts/$f" "$RES/$f"
    chmod 755 "$RES/$f"
  fi
done
# Also keep ~/bin UTF-8 clipboard helper in sync (tmux copy-pipe)
if [[ -f "$ROOT/scripts/pong-pbcopy" ]]; then
  mkdir -p "$HOME/bin"
  cp "$ROOT/scripts/pong-pbcopy" "$HOME/bin/pong-pbcopy"
  chmod 755 "$HOME/bin/pong-pbcopy"
fi
# project_root embeds an absolute local path — dev builds only.
if [[ "$DEV" == "1" ]]; then
  echo "$ROOT" > "$RES/project_root"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.kulpio.pong</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>CyberPong controls Terminal windows to pair conductor and worker AI sessions.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$CONTENTS/PkgInfo"

# Ad-hoc sign for local open (executable name MUST match CFBundleExecutable).
# Fail the build if signing fails — unsigned/mismatched bundles show as "damaged".
# --deep reaches the island in Contents/Helpers; ad hoc is fine on this Mac only.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "hint: ad-hoc signed (this Mac only). Release builds: bash scripts/sign-notarize.sh"
echo "      (signs the island helper, then the app, with Developer ID; notarizes; makes the zip)"

# Release bundles must not leak the local user path (the home folder this was built in).
if [[ "$DEV" != "1" ]]; then
  if grep -rF -- "$HOME" "$APP" >/dev/null 2>&1; then
    echo "FAIL: release bundle contains local user path strings:" >&2
    grep -rlF -- "$HOME" "$APP" >&2
    exit 1
  fi
fi

echo "Built: $APP (v$VERSION, $([[ "$DEV" == "1" ]] && echo dev || echo release) build)"
file "$MACOS/$APP_NAME"
