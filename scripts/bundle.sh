#!/bin/bash
# Assemble and sign RemoteTV.app from a SwiftPM build.
#   scripts/bundle.sh <release|debug> <output.app>
#
# Version: 0.0.N where N = commits on HEAD; CFBundleVersion is N, RemoteTVRevision the
# short git hash. REMOTETV_VERSION overrides.
#
# Signing identity, REMOTETV_SIGN_IDENTITY:
#   unset  the Developer ID from the signing keychain (setup-signing.sh, shared with the
#          user's other apps), no timestamp. Privacy grants (Local Network, Accessibility)
#          are keyed on the designated requirement (bundle id + team), so they survive
#          rebuilds.
#   "-"    ad-hoc (CI-style build checks; grants would not stick)
#   other  that identity from the keychain search list, with a secure timestamp
set -euo pipefail

CONFIG="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/RemoteTV"
KC="$HOME/Library/Keychains/developer-id.keychain-db"   # setup-signing.sh (same paths)
PASS_FILE="$HOME/Library/Application Support/DeveloperID/keychain-password"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Helpers"
cp "$BIN" "$OUT/Contents/MacOS/RemoteTV"
cp "$ROOT/.build/$CONFIG/tvctl" "$OUT/Contents/Helpers/tvctl"
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi
REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
N="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
VERSION="${REMOTETV_VERSION:-0.0.$N}"
PLIST="$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $N" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :RemoteTVRevision string $REV" "$PLIST"

if [[ "$CONFIG" == "release" ]]; then
  strip -x "$OUT/Contents/MacOS/RemoteTV"   # drop local symbols: smaller binary, less to page in
  strip -x "$OUT/Contents/Helpers/tvctl"
fi

sign=(codesign --force --options runtime --entitlements "$ROOT/Resources/RemoteTV.entitlements"
      --identifier com.lingrino.remotetv)
# Nested code is signed first (same identity), then the app seals it.
helper=(codesign --force --options runtime --identifier com.lingrino.remotetv.tvctl)
case "${REMOTETV_SIGN_IDENTITY:-}" in
  "")
    security unlock-keychain -p "$(cat "$PASS_FILE")" "$KC"
    id="$(security find-identity -v -p codesigning "$KC" | awk '/"Developer ID Application: / { print $2; exit }')"
    [[ -n "$id" ]] || { echo "no Developer ID identity for local builds: run scripts/setup-signing.sh" >&2; exit 1; }
    "${helper[@]}" --timestamp=none --sign "$id" --keychain "$KC" "$OUT/Contents/Helpers/tvctl"
    "${sign[@]}" --timestamp=none --sign "$id" --keychain "$KC" "$OUT" ;;
  -)
    "${helper[@]}" --sign - "$OUT/Contents/Helpers/tvctl"
    "${sign[@]}" --sign - "$OUT" ;;
  *)
    "${helper[@]}" --timestamp --sign "$REMOTETV_SIGN_IDENTITY" "$OUT/Contents/Helpers/tvctl"
    "${sign[@]}" --timestamp --sign "$REMOTETV_SIGN_IDENTITY" "$OUT" ;;
esac
echo "built $OUT ($VERSION, $REV)"
