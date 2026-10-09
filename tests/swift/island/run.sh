#!/usr/bin/env bash
# Standalone swiftc harness for the notch panel's model layer (2.1; no Xcode / SwiftPM target exists).
#
#   tests/swift/island/run.sh
#
# Compiles the island's pure files whole (src/IslandSettings.swift, IslandGeometry.swift,
# IslandHover.swift, IslandModel.swift) with the app types they read, sliced out of their files the
# way tests/swift/questions does (each from its declaration to the first `}` in column 0): the graph
# feed's types and GraphTime (src/GraphStudioModel.swift), Words, RunState, StepPlaces and the
# GGraph / GNode / GArchitect word extensions (src/GraphWords.swift), PongStatus (src/PongTokens.swift).
# Stubs.swift stands in for the rest (AppSettings in memory, PongUI's time words, which teams are up).
# main.swift's last section also reads the tooltips (on screen, but never drawn text) off the lines that
# set one in src/QuestionCard.swift and the panel's view files, as text.
# Nothing here reads ~/.pong, runs `pong`, opens a window or touches the live notch panel.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="$here/.out"
rm -rf "$out"; mkdir -p "$out"

slice() {  # slice <file> <declaration prefix>: one top-level type, declaration to closing brace
  awk -v d="$2" 'index($0, d) == 1 { on = 1 } on { print } on && $0 == "}" { exit }' "$1"
}

model="$root/src/GraphStudioModel.swift"
words="$root/src/GraphWords.swift"
tokens="$root/src/PongTokens.swift"
{
  echo "import AppKit"
  for d in "enum GJ {" "struct GJevLine {" "struct GJev {" "struct GAdvice {" "struct GNode {" "struct GLoop {" \
           "struct GEdge: Hashable {" "struct GGate {" "struct GDetail: Hashable {" "struct GAsk {" "struct GEvent {" \
           "struct GFile {" "struct GRefusal {" "struct GArchitect {" "struct GChatAsk {" "struct GLimits {" \
           "struct GNow {" "struct GGraph {" "enum GraphTime {"; do
    grep -q "^$d" "$model" || { echo "run.sh: '$d' not found in GraphStudioModel.swift"; exit 2; }
    slice "$model" "$d"
  done
  for d in "enum Words {" "enum RunState {" "enum StepPlaces {" "extension GGraph {" "extension GNode {" "extension GArchitect {"; do
    grep -q "^$d" "$words" || { echo "run.sh: '$d' not found in GraphWords.swift"; exit 2; }
    slice "$words" "$d"
  done
  slice "$tokens" "enum PongStatus {"
} > "$out/AppModel.swift"
for want in "static func doing" "static func compute" "var displayName" "func stepWords" "var pausedWords" \
            "init?(_ a: Any?)" "static func comesBack" "var symbol: String"; do
  grep -q "$want" "$out/AppModel.swift" || { echo "run.sh: the slice lost '$want'"; exit 2; }
done
# the stubs copy PongUI's time words: fail loudly if the real ones change shape
for want in "static func duration(_ seconds: Double) -> String" "static func clock(_ t: Double) -> String" \
            "static func dayStamp(_ t: Double) -> String" "static func ago(_ t: Double, now: Double"; do
  grep -qF "$want" "$root/src/PongComponents.swift" || { echo "run.sh: PongUI changed: '$want'"; exit 2; }
done

cache="${SWIFT_MODULE_CACHE:-$out/modcache}"
echo "compiling: swiftc AppModel.swift Island{Settings,Geometry,Hover,Model}.swift Stubs.swift main.swift"
swiftc -Onone -swift-version 5 -module-cache-path "$cache" \
  "$out/AppModel.swift" "$root/src/IslandSettings.swift" "$root/src/IslandGeometry.swift" \
  "$root/src/IslandHover.swift" "$root/src/IslandModel.swift" "$here/Stubs.swift" "$here/main.swift" \
  -o "$out/island-harness"

echo "running:   $out/island-harness"
"$out/island-harness"
