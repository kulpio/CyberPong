#!/bin/bash
# sign-notarize.sh — Developer ID sign, notarize, staple, and package the release.
#
# Usage:
#   bash scripts/sign-notarize.sh              sign, notarize, staple, then zip
#   bash scripts/sign-notarize.sh --sign-only  sign and zip without notarizing (people
#                                              who download it need Open Anyway once)
#
# Inputs:
#   IDENTITY  env var — signing identity (default: auto-detect the sole
#             "Developer ID Application" identity in the keychain)
#   Notary credentials stored once as keychain profile "hermes-pong"
#             (not needed with --sign-only)
#
# Order: hygiene → sign the app (one Mach-O, nothing nested: the notch panel is part
# of the app since 2.1) → check every Mach-O → notarize → staple → Gatekeeper → zip.
# With --sign-only: hygiene → sign → check every Mach-O → Gatekeeper (printed; it is
# expected to say "not notarized") → zip. The release zip is made last, only when
# every step before it passed.
#
# Degrades gracefully when credentials are missing: hygiene checks still run,
# signing/notarizing no-op with a clear message, and a setup checklist prints.
# No release zip is made then. Never asks for, prints or stores credential values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Bundle folder must match build-app.sh (CyberPong.app — Dock/Finder name)
APP="$ROOT/dist/CyberPong.app"
ENTITLEMENTS="$ROOT/resources/entitlements.plist"
PROFILE="hermes-pong"
ZIP_NOTARIZE="$ROOT/dist/CyberPong-notarize.zip"
ZIP_RELEASE="$ROOT/dist/CyberPong-macOS.zip"

fail() { echo "FAIL: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: bash scripts/sign-notarize.sh [--sign-only]
  (no option)   sign with Developer ID, notarize, staple, then make dist/CyberPong-macOS.zip
  --sign-only   sign with Developer ID and make the zip without notarizing:
                people who download it need Open Anyway once
USAGE
}

SIGN_ONLY=0
if [[ $# -gt 1 ]]; then usage >&2; exit 2; fi
case "${1:-}" in
  "") ;;
  --sign-only) SIGN_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# The release zip holds CyberPong.app and nothing else.
package_release() {
  echo "→ Packaging release zip ($1)"
  rm -f "$ZIP_RELEASE"
  ditto -c -k --keepParent "$APP" "$ZIP_RELEASE"
  local listing outside
  listing="$(zipinfo -1 "$ZIP_RELEASE")" || fail "cannot list $ZIP_RELEASE"
  outside="$(grep -v "^CyberPong.app/" <<<"$listing" || true)"
  if [[ -n "$outside" ]]; then
    echo "$outside" >&2
    rm -f "$ZIP_RELEASE"
    fail "release zip contains entries outside CyberPong.app/"
  fi
  echo "  ✓ zip contains only CyberPong.app"
}

[[ -d "$APP" ]] || fail "no app at $APP — run: bash scripts/build-app.sh (without --dev)"
[[ -f "$ENTITLEMENTS" ]] || fail "missing $ENTITLEMENTS"

# A release zip left from an earlier run doesn't match this build: never leave one
# behind that this run didn't make and check.
rm -f "$ZIP_RELEASE"

# ---------- release hygiene (always runs, credentials or not) ----------
echo "→ Release hygiene check"
HYGIENE_BAD=0
# Compiled Python bytecode leaks absolute source paths (co_filename) and evades
# the text grep below (grep -I skips binaries) — reject it outright.
LEAKS="$(find "$APP" \( -name "venv" -o -name ".env*" -o -name ".wa-auth" -o -name "project_root" -o -name "__pycache__" -o -name "*.pyc" \) -print)"
if [[ -n "$LEAKS" ]]; then
  echo "  ✗ forbidden files in bundle:" >&2
  echo "$LEAKS" >&2
  HYGIENE_BAD=1
fi
# Text-file scan (source, plists, scripts).
if grep -rIq "/Users/" "$APP" 2>/dev/null; then
  echo "  ✗ absolute user paths in bundle (text):" >&2
  grep -rIl "/Users/" "$APP" >&2
  HYGIENE_BAD=1
fi
# Binary scan — the text grep skips Mach-O and any binary; strings-scan every
# file so a leak baked into the executable or bytecode can't slip through.
# FAIL on absolute /Users/ paths and the stale ~/src/Agent-Pong mirror.
BIN_LEAKS="$(find "$APP" -type f -exec sh -c 'strings "$1" 2>/dev/null | grep -q -e "/Users/" -e "src/Agent-Pong" && echo "$1"' _ {} \;)"
if [[ -n "$BIN_LEAKS" ]]; then
  echo "  ✗ absolute /Users/ or stale Agent-Pong paths in bundle (binary/strings):" >&2
  echo "$BIN_LEAKS" >&2
  HYGIENE_BAD=1
fi
# WARN on $HOME-relative dev-tree literals compiled into the Mach-O: the checkout's
# own folder (for a worktree, the main checkout's). Dev-only fallbacks belong behind
# #if DEBUG. Not a blocker — leaks layout, not the user.
MAIN_TREE="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN_TREE="${MAIN_TREE%/.git}"
DEV_REL="${MAIN_TREE:-$ROOT}"
DEV_REL="${DEV_REL#"$HOME"/}"
# A checkout straight in the home folder (~/CyberPong, as the README's clone makes)
# leaves one folder name: the app's own name, which nearly every file holds. Look for
# it as a path component (/CyberPong/) instead.
DEV_NEEDLE="$DEV_REL"
if [[ "$DEV_REL" != */* ]]; then DEV_NEEDLE="/$DEV_REL/"; fi
DEV_TREE="$(find "$APP" -type f -exec sh -c 'strings "$1" 2>/dev/null | grep -qF -- "$2" && echo "$1"' _ {} "$DEV_NEEDLE" \;)"
[[ -n "$DEV_TREE" ]] && echo "  ⚠ dev-tree path strings present (non-blocking):" && echo "$DEV_TREE"
[[ "$HYGIENE_BAD" == "0" ]] || fail "hygiene check failed — rebuild without --dev and inspect the files above"
echo "  ✓ bundle clean (no venv/.env*/.wa-auth/project_root/pyc, no /Users/ or Agent-Pong paths)"

find "$APP" -name ".DS_Store" -delete

# ---------- credential gate ----------
IDENTITY="${IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  MATCHES="$(security find-identity -v -p codesigning | grep "Developer ID Application" || true)"
  COUNT="$(printf '%s' "$MATCHES" | grep -c '"' || true)"
  if [[ "$COUNT" -eq 1 ]]; then
    IDENTITY="$(printf '%s' "$MATCHES" | sed -n 's/.*"\(.*\)".*/\1/p')"
  elif [[ "$COUNT" -gt 1 ]]; then
    echo "$MATCHES"
    fail "multiple Developer ID Application identities — set IDENTITY=\"...\" explicitly"
  fi
fi

# Ask notarytool whether the profile works, and keep its answer so Apple refusing it
# (HTTP 403: an agreement to accept) isn't reported as a missing profile. On success
# the answer (the submission history) is dropped unread; on an unknown failure only its
# first error line is shown. notarytool never echoes the password. --sign-only doesn't
# notarize, so it doesn't ask.
HAVE_PROFILE=0
NOTARY_WHY=""
NOTARY_ERR=""
if [[ "$SIGN_ONLY" == "0" ]]; then
  if NOTARY_OUT="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1)"; then
    HAVE_PROFILE=1
  elif grep -qiE 'status code: 403|required agreement' <<<"$NOTARY_OUT"; then
    NOTARY_WHY="agreement"
  elif grep -qi 'No Keychain password item found' <<<"$NOTARY_OUT"; then
    NOTARY_WHY="missing"
  else
    NOTARY_WHY="other"
    NOTARY_ERR="$(grep -im1 'error' <<<"$NOTARY_OUT" || head -n1 <<<"$NOTARY_OUT")"
    NOTARY_ERR="$(cut -c1-200 <<<"$NOTARY_ERR")"
  fi
  NOTARY_OUT=""
fi

if [[ -z "$IDENTITY" || ( "$SIGN_ONLY" == "0" && "$HAVE_PROFILE" == "0" ) ]]; then
  if [[ -z "$IDENTITY" ]]; then
    echo "→ Signing skipped: no \"Developer ID Application\" identity in keychain"
  fi
  case "$NOTARY_WHY" in
    agreement) echo "→ Notarization blocked: Apple refused (agreement). Profile \"$PROFILE\" is there, but Apple answered HTTP 403 (\"A required agreement is missing or has expired\")" ;;
    missing)   echo "→ Notarization skipped: no keychain profile \"$PROFILE\"" ;;
    other)     echo "→ Notarization skipped: notarytool could not use profile \"$PROFILE\": ${NOTARY_ERR:-no message}" ;;
  esac
  echo ""
  echo "BLOCKED — needs the Apple Developer account's owner:"
  STEP=0
  step() { STEP=$((STEP + 1)); echo "$STEP. $*"; }
  if [[ -z "$IDENTITY" ]]; then
    step "Enroll: developer.apple.com/programs (Apple Developer Program; one-time, ~\$99/yr, Apple's approval can take 1-2 days)"
    step "Create a \"Developer ID Application\" certificate (Xcode → Settings → Accounts → Manage Certificates, or developer portal) and install it in your login keychain"
  fi
  case "$NOTARY_WHY" in
    agreement)
      step "Accept the current agreement at developer.apple.com/account (the account holder signs in and accepts it)."
      echo "   The notary profile itself is fine: nothing to store again."
      ;;
    missing)
      step "Store notary credentials once:"
      echo "   xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id <TEAMID> --password <app-specific-password>"
      ;;
    other)
      step "Fix what notarytool said above. If the app-specific password changed, store the credentials again:"
      echo "   xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id <TEAMID> --password <app-specific-password>"
      ;;
  esac
  if [[ "$SIGN_ONLY" == "1" ]]; then
    echo "Then run: bash scripts/sign-notarize.sh --sign-only"
  else
    echo "Then run: bash scripts/sign-notarize.sh"
    if [[ -n "$IDENTITY" ]]; then
      echo "To share a build before then: bash scripts/sign-notarize.sh --sign-only (signed, not notarized)"
    fi
  fi
  cat <<'NOZIP'

No release zip was made. An app that isn't notarized is blocked by Gatekeeper on
download: people would have to use System Settings › Privacy & Security › Open Anyway.
NOZIP
  exit 0
fi

# ---------- sign (no --deep: the bundle holds one Mach-O, Contents/MacOS/Pong) ----------
# Since 2.1 the notch panel is part of the app, so nothing nested needs its own
# signature. The deep check below and the Mach-O check after it would still catch
# nested code that turned up unsigned or ad hoc: Apple's notary service rejects any.
echo "→ Signing with: $IDENTITY"
# Finder info and other extended attributes make codesign refuse ("detritus not allowed").
xattr -cr "$APP"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Every Mach-O in the bundle must now carry Developer ID + hardened runtime + a
# secure timestamp; one left ad hoc would otherwise only show up as Apple's verdict.
MACHO_COUNT=0
while IFS= read -r -d '' f; do
  kind="$(file -b "$f" 2>/dev/null || true)"
  [[ "$kind" == *Mach-O* ]] || continue
  MACHO_COUNT=$((MACHO_COUNT + 1))
  rel="${f#"$APP"/}"
  info="$(codesign -dv --verbose=4 "$f" 2>&1 || true)"
  if grep -q 'Signature=adhoc' <<<"$info"; then fail "still ad hoc: $rel"; fi
  grep -q 'flags=.*runtime' <<<"$info" || fail "no hardened runtime: $rel"
  grep -q '^Timestamp=' <<<"$info" || fail "no secure timestamp: $rel"
  grep -q '^Authority=Developer ID Application' <<<"$info" || fail "not signed with Developer ID: $rel"
done < <(find "$APP" -type f -print0)
[[ "$MACHO_COUNT" -gt 0 ]] || fail "no Mach-O found in $APP"
echo "  ✓ signed + verified ($MACHO_COUNT Mach-O files, each Developer ID + hardened runtime + timestamp, none ad hoc)"

# ---------- --sign-only: Gatekeeper's view, then the zip (no notarizing) ----------
if [[ "$SIGN_ONLY" == "1" ]]; then
  echo "→ Gatekeeper assessment (expected: rejected as not notarized)"
  SPCTL_OUT="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
  sed 's/^/  /' <<<"$SPCTL_OUT"
  if grep -q 'Unnotarized Developer ID' <<<"$SPCTL_OUT"; then
    echo "  ✓ as expected for $(basename "$APP"): Developer ID, not notarized"
  elif grep -q ': accepted' <<<"$SPCTL_OUT"; then
    echo "  ✓ $(basename "$APP") accepted"
  else
    echo "  ⚠ $(basename "$APP"): not the expected \"Unnotarized Developer ID\" answer (see above)"
  fi
  package_release "signed, not notarized"
  echo ""
  echo "Release zip: $ZIP_RELEASE"
  echo "Signed with Developer ID, NOT notarized: people will need Open Anyway once."
  exit 0
fi

# ---------- notarize ----------
echo "→ Notarizing"
rm -f "$ZIP_NOTARIZE"
ditto -c -k --keepParent "$APP" "$ZIP_NOTARIZE"
SUBMIT_LOG="$(mktemp)"
if ! xcrun notarytool submit "$ZIP_NOTARIZE" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$SUBMIT_LOG"; then
  echo "notarytool submit failed" >&2
fi
STATUS="$(awk '/status:/ {s=$2} END {print s}' "$SUBMIT_LOG")"
SUBMISSION_ID="$(awk '/id:/ {print $2; exit}' "$SUBMIT_LOG")"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "→ Notarization not accepted (status: ${STATUS:-unknown}) — fetching log" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2 || true
  fi
  exit 1
fi
echo "  ✓ notarization accepted (id: $SUBMISSION_ID)"

# ---------- staple + check ----------
echo "→ Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# The ticket sits beside the code; the seal must still hold.
codesign --verify --deep --strict "$APP"

echo "→ Gatekeeper assessment"
spctl --assess --type execute -vv "$APP"

# ---------- package (last: only a bundle that passed everything above) ----------
package_release "post-staple"

echo ""
echo "Release ready: $ZIP_RELEASE"
