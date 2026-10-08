#!/usr/bin/env bash
# Standalone swiftc harness for the first-run setup's plumbing (no Xcode / SwiftPM target exists).
#
#   tests/swift/run-setup.sh
#
# Compiles src/SetupCore.swift (Foundation only: settings.json, the key files, `pong doctor`,
# the ~/bin/pong launcher and the engine refresh) with setup/Stubs.swift + setup/main.swift,
# and runs it. Pong.stateDir and every "home" are temp folders: nothing here reads or writes
# ~/.pong, ~/bin or ~/Library, and nothing calls launchctl (the runner restart is injected).
# The ~/bin/pong text is run with bash from a temp folder, against a stand-in python3; its
# no-Python branch with a stand-in for xcode-select, so Apple's python3 is never started.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/.out-setup"
rm -rf "$out"; mkdir -p "$out"

# SETUP_SRC lets the runner compile an alternative copy of the file.
src="${SETUP_SRC:-$root/src/SetupCore.swift}"
grep -q 'enum EngineInstall' "$src" || { echo "run-setup.sh: EngineInstall not found in $src"; exit 2; }

cache="${SWIFT_MODULE_CACHE:-$out/modcache}"
echo "compiling: swiftc SetupCore.swift setup/Stubs.swift setup/main.swift"
swiftc -Onone -swift-version 5 -module-cache-path "$cache" \
  "$src" "$here/setup/Stubs.swift" "$here/setup/main.swift" \
  -o "$out/setup-harness"

echo "running:   $out/setup-harness"
# the checkout too: the harness compares install-control-plane.sh's launcher with the app's (it reads
# the script, never runs it)
"$out/setup-harness" "$out" "$root"
