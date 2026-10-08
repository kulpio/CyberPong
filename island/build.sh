#!/bin/bash
# Build PongIsland.app — notch island for CyberPong.
# Reads `pong snapshot`; never touches pong internals.
#
# Usage: build.sh [--dev]
# Universal (arm64 + x86_64, joined with lipo), like the app around it, so the
# island also runs on an Intel Mac. --dev (or DEV=1) enables #if DEBUG: the
# development-checkout fallback for `pong`. Release builds leave it out, so no
# local path lands in the Mach-O.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/../dist/PongIsland.app"
C="$APP/Contents"; M="$C/MacOS"
rm -rf "$APP"; mkdir -p "$M"

DEV="${DEV:-0}"
[[ "${1:-}" == "--dev" ]] && DEV=1
FLAGS=(-O -parse-as-library)
if [[ "$DEV" == "1" ]]; then
  FLAGS+=(-DDEBUG)
fi

for ARCH in arm64 x86_64; do
  swiftc "${FLAGS[@]}" \
    -target "$ARCH-apple-macos13.0" \
    -framework AppKit -framework SwiftUI \
    -o "$M/PongIsland-$ARCH" "$ROOT/PongIsland.swift"
done
lipo -create -output "$M/PongIsland" "$M/PongIsland-arm64" "$M/PongIsland-x86_64"
rm -f "$M/PongIsland-arm64" "$M/PongIsland-x86_64"
lipo -info "$M/PongIsland"

mkdir -p "$C/Resources"
cp -R "$ROOT/web" "$C/Resources/web"

cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PongIsland</string>
  <key>CFBundleDisplayName</key><string>Pong Island</string>
  <key>CFBundleIdentifier</key><string>com.owi.pongisland</string>
  <key>CFBundleExecutable</key><string>PongIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

echo "built $APP"
