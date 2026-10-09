#!/usr/bin/env bash
# Standalone swiftc harness for how a graph reads (no Xcode / SwiftPM target exists).
#
#   tests/swift/run-island-graphs.sh
#
# Since 2.1 the notch panel lives inside CyberPong and reads graphs through the app's own model,
# so this compiles that model as it is: src/GraphStudioModel.swift (GGraph and the types it parses)
# and src/GraphWords.swift (pongStatus, pausedWords, plainStatus, waitsForTeam), with the real
# PongStatus sliced out of src/PongTokens.swift and island-graphs/Stubs.swift for the few app
# symbols they reach for. It checks what the notch panel's closed line and rows go by: a paused
# graph is paused, not working; one at a question or with a step asking needs you; one whose team
# is stopped waits for it. Nothing here reads ~/.pong or runs `pong`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/.out-island-graphs"
rm -rf "$out"; mkdir -p "$out"

model="$root/src/GraphStudioModel.swift"
words="$root/src/GraphWords.swift"
tokens="$root/src/PongTokens.swift"
grep -q '^struct GGraph {' "$model" || { echo "run-island-graphs.sh: 'struct GGraph {' not found in $model"; exit 2; }
grep -q '^extension GGraph {' "$words" || { echo "run-island-graphs.sh: 'extension GGraph {' not found in $words"; exit 2; }

# PongStatus, from its declaration to the first column-0 '}': everything inside it is indented.
start='enum PongStatus {'
grep -q "^$start" "$tokens" || { echo "run-island-graphs.sh: '$start' not found in $tokens"; exit 2; }
{
  echo "import AppKit"
  awk -v s="$start" '
    index($0, s) == 1 { inblk = 1 }
    inblk { print }
    inblk && $0 == "}" { exit }
  ' "$tokens"
} > "$out/PongStatus.swift"
grep -q 'case needsYou' "$out/PongStatus.swift" || { echo "slice lost PongStatus's cases"; exit 2; }

cache="${SWIFT_MODULE_CACHE:-$out/modcache}"
echo "compiling: swiftc GraphStudioModel.swift GraphWords.swift PongStatus.swift island-graphs/Stubs.swift island-graphs/main.swift"
swiftc -Onone -swift-version 5 -module-cache-path "$cache" \
  "$model" "$words" "$out/PongStatus.swift" "$here/island-graphs/Stubs.swift" "$here/island-graphs/main.swift" \
  -o "$out/island-graphs-harness"

echo "running:   $out/island-graphs-harness"
"$out/island-graphs-harness"
