#!/usr/bin/env bash
# Standalone swiftc harness for the question card's data (2.0): the app's GDetail, GLimits, GLoop
# and EngineCheck (src/GraphStudioModel.swift), QuestionWords (src/QuestionCard.swift), Words and
# RunState (src/GraphWords.swift), EngineReply (src/GraphStore.swift) and the island's DetailPoint
# (island/PongIsland.swift).
#
#   tests/swift/questions/run.sh
#
# There is no Swift test target, and both files drag in the whole app, so this slices the
# top-level types it tests out of them (each from its declaration to the first `}` in column 0),
# compiles them with main.swift, and runs the result. Nothing here reads ~/.pong or runs `pong`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="$here/.out"
rm -rf "$out"; mkdir -p "$out"

slice() {  # slice <file> <declaration prefix>: one top-level type, declaration to closing brace
  awk -v d="$2" 'index($0, d) == 1 { on = 1 } on { print } on && $0 == "}" { exit }' "$1"
}

model="$root/src/GraphStudioModel.swift"
card="$root/src/QuestionCard.swift"
words="$root/src/GraphWords.swift"
store="$root/src/GraphStore.swift"
island="$root/island/PongIsland.swift"
{
  echo "import Foundation"
  slice "$model" "enum GJ {"
  slice "$model" "struct GDetail: Hashable {"
  slice "$model" "struct GLimits {"
  slice "$model" "struct GLoop {"
  slice "$model" "enum EngineCheck {"
  slice "$card" "enum QuestionWords {"
  slice "$words" "enum Words {"
  slice "$words" "enum RunState {"
  slice "$store" "enum EngineReply {"
} > "$out/AppModel.swift"
{
  echo "import Foundation"
  slice "$island" "struct DetailPoint: Hashable {"
  slice "$island" "enum PongCheck {"
} > "$out/IslandModel.swift"
for want in "static func parse" "func pausedWords" "var weekWords" "static func attribution" \
            "static func notificationBody" "static func holdNotification" "static func fileRow" \
            "static func fileTitles" "static func cleanCut" "static func launchesPathPython" "static func runnerOK" \
            "static func report" "static func outcome" "static func resume" "var label: String" \
            "static func engineSentence" "static func answerRefusal" "static func jevNotAsked" \
            "static func holdStill" "static func waitsForTeam"; do
  grep -q "$want" "$out/AppModel.swift" || { echo "run.sh: the slice lost '$want'"; exit 2; }
done
for want in "static func parse" "static func sentence" "static func launchesPathPython" "static func answerRefusal"; do
  grep -q "$want" "$out/IslandModel.swift" || { echo "run.sh: the island slice lost '$want'"; exit 2; }
done

echo "compiling: swiftc AppModel.swift IslandModel.swift main.swift"
swiftc -Onone -swift-version 5 "$out/AppModel.swift" "$out/IslandModel.swift" "$here/main.swift" \
  -o "$out/questions-harness"

echo "running:   $out/questions-harness"
"$out/questions-harness"
