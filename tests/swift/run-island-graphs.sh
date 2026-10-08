#!/usr/bin/env bash
# Standalone swiftc harness for the island's graph lines (no Xcode / SwiftPM target exists).
#
#   tests/swift/run-island-graphs.sh
#
# Slices `struct GraphLine` out of island/PongIsland.swift (the rest of that file is SwiftUI and
# AppKit that would drag in the whole island), compiles it with island-graphs/main.swift, and runs
# it. It checks the island reads a graph the way the app does: a paused graph is paused, not
# working; one at a question needs you. Nothing here reads ~/.pong or runs `pong`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/.out-island-graphs"
rm -rf "$out"; mkdir -p "$out"

# ISLAND_SRC lets the runner compile an alternative copy of the file.
src="${ISLAND_SRC:-$root/island/PongIsland.swift}"
start='struct GraphLine: Identifiable {'
grep -q "^$start" "$src" || { echo "run-island-graphs.sh: '$start' not found in $src"; exit 2; }
# From the struct's opening line to the first column-0 '}': everything inside it is indented.
{
  echo "import Foundation"
  awk -v s="$start" '
    index($0, s) == 1 { inblk = 1 }
    inblk { print }
    inblk && $0 == "}" { exit }
  ' "$src"
} > "$out/GraphLine.swift"
grep -q 'static func from' "$out/GraphLine.swift"        || { echo "slice lost from()"; exit 2; }
grep -q 'static func pausedWords' "$out/GraphLine.swift" || { echo "slice lost pausedWords()"; exit 2; }

cache="${SWIFT_MODULE_CACHE:-$out/modcache}"
echo "compiling: swiftc GraphLine.swift island-graphs/main.swift"
swiftc -Onone -swift-version 5 -module-cache-path "$cache" \
  "$out/GraphLine.swift" "$here/island-graphs/main.swift" \
  -o "$out/island-graphs-harness"

echo "running:   $out/island-graphs-harness"
"$out/island-graphs-harness"
