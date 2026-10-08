#!/usr/bin/env bash
# Standalone swiftc harness for LoopArgs (no Xcode / SwiftPM target exists).
#
#   tests/swift/run-loop-args.sh
#
# Slices `enum LoopArgs` out of island/PongIsland.swift — the rest of that file
# is SwiftUI and AppKit that would drag in the whole island — compiles it with
# loop-args/main.swift, and runs it. Nothing here touches ~/.pong, tmux, or a
# live session: LoopArgs only builds an argv, it never runs one.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/.out-loop-args"
rm -rf "$out"; mkdir -p "$out"

# ISLAND_SRC lets the runner compile an alternative copy of the file — used to
# show these tests going red against the pre-Who-row source.
src="${ISLAND_SRC:-$root/island/PongIsland.swift}"
start='enum LoopArgs {'
grep -q "^$start" "$src" || { echo "run-loop-args.sh: '$start' not found in $src"; exit 2; }
# From the enum's opening line to the first column-0 '}' — the enum is written
# flush left with everything inside it indented, so that brace is its end.
awk -v s="$start" '
  index($0, s) == 1 { inblk = 1 }
  inblk { print }
  inblk && $0 == "}" { exit }
' "$src" > "$out/LoopArgs.swift"
grep -q 'static func goalStart' "$out/LoopArgs.swift" || { echo "slice lost goalStart()"; exit 2; }
grep -q 'static func lead' "$out/LoopArgs.swift"      || { echo "slice lost lead()"; exit 2; }

echo "compiling: swiftc LoopArgs.swift loop-args/main.swift"
swiftc -Onone -swift-version 5 \
  "$out/LoopArgs.swift" "$here/loop-args/main.swift" \
  -o "$out/loop-args-harness"

echo "running:   $out/loop-args-harness"
"$out/loop-args-harness"
