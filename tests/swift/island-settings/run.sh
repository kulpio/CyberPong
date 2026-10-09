#!/usr/bin/env bash
# Standalone swiftc harness for Settings › Notch panel's words and choices (2.1; no Xcode / SwiftPM target).
#
#   tests/swift/island-settings/run.sh
#
# Compiles src/IslandSettings.swift whole with `enum IslandSettingsWords` and `enum IslandShortcutHold`
# sliced out of src/IslandSettingsPane.swift (declaration to the first `}` in column 0, as
# tests/swift/island does), and Stubs.swift (settings.json in memory). Checks every pop-up's choices
# against the values the settings keep, the points fields, the shortcut words and refusals, the "Try it
# here" lines, the preview guard of [Show me], that no word on the page is one the app keeps off screen,
# and that a recording holds the panel's shortcut (made-up presses sent inside this process only; no hot
# key is registered). Nothing here reads ~/.pong, opens a window or touches the live notch panel.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="$here/.out"
rm -rf "$out"; mkdir -p "$out"

pane="$root/src/IslandSettingsPane.swift"
for d in "enum IslandSettingsWords {" "enum IslandShortcutHold {"; do
  grep -q "^$d" "$pane" || { echo "run.sh: '$d' not found in IslandSettingsPane.swift"; exit 2; }
done
{
  echo "import AppKit"
  echo "import Carbon.HIToolbox"
  for d in "enum IslandSettingsWords {" "enum IslandShortcutHold {"; do
    awk -v d="$d" 'index($0, d) == 1 { on = 1 } on { print } on && $0 == "}" { exit }' "$pane"
  done
} > "$out/Words.swift"
for want in "static func tryStatus" "static func shortcutRefusal" "static func touchesRealTop" "static let fullScreenChoices" \
            "static func hold" "static func release()"; do
  grep -q "$want" "$out/Words.swift" || { echo "run.sh: the slice lost '$want'"; exit 2; }
done
# the hold holds the hot key the panel registers ("CNPL"; main.swift checks the hold's side)
grep -qF 'EventHotKeyID(signature: OSType(0x434E_504C)' "$root/src/IslandController.swift" || {
  echo "run.sh: IslandController no longer registers its hot key as \"CNPL\": change IslandShortcutHold.signature with it"; exit 2; }

cache="${SWIFT_MODULE_CACHE:-$out/modcache}"
echo "compiling: swiftc IslandSettings.swift Words.swift Stubs.swift main.swift"
swiftc -Onone -swift-version 5 -module-cache-path "$cache" \
  "$root/src/IslandSettings.swift" "$out/Words.swift" "$here/Stubs.swift" "$here/main.swift" \
  -o "$out/island-settings-harness"

echo "running:   $out/island-settings-harness"
"$out/island-settings-harness"
