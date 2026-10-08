#!/usr/bin/env bash
# Standalone swiftc harness for CronSchedule (no Xcode / SwiftPM target exists).
#
#   tests/swift/run.sh
#
# Slices the `enum CronSchedule` block out of src/CronSchedule.swift (the rest of
# that file is AppKit sheet code that would drag in the whole app), compiles it
# with Stubs.swift + main.swift, and runs it. Pong.stateDir is
# stubbed to a temp dir: this never reads or writes ~/.pong/cron-schedules.json
# and never fires a live cron.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/.out"
rm -rf "$out"; mkdir -p "$out"

# CRON_SRC lets the runner compile an alternative copy of the file — used to
# show these tests going red against the pre-fix source.
src="${CRON_SRC:-$root/src/CronSchedule.swift}"
# The enum ends where the sheet's private helper class begins. If that marker
# ever moves, this fails loudly at compile time rather than testing nothing.
marker='// MARK: - end of CronSchedule'
grep -q "^$marker" "$src" || { echo "run.sh: marker '$marker' not found in $src"; exit 2; }
awk -v m="$marker" 'index($0, m) == 1 { exit } { print }' "$src" > "$out/CronScheduleCore.swift"
grep -q 'static func tick' "$out/CronScheduleCore.swift"       || { echo "slice lost tick()"; exit 2; }
grep -q 'private static func file' "$out/CronScheduleCore.swift" || { echo "slice lost file()"; exit 2; }

echo "compiling: swiftc CronScheduleCore.swift Stubs.swift main.swift"
swiftc -Onone -swift-version 5 \
  "$out/CronScheduleCore.swift" "$here/Stubs.swift" "$here/main.swift" \
  -o "$out/cron-harness"

echo "running:   $out/cron-harness"
"$out/cron-harness" "$out"
