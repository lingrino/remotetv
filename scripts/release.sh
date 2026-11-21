#!/bin/bash
# Build a RemoteTV release and the Homebrew cask that installs it (what CI publishes).
#   scripts/release.sh  →  build/release/RemoteTV.app, RemoteTV-<version>.zip, remotetv.rb, version
#
# Version and signing: see bundle.sh (REMOTETV_SIGN_IDENTITY; "-" for an unsigned dry run).
# Notarization runs when an App Store Connect API key is given: REMOTETV_NOTARY_KEY (path to
# the .p8), REMOTETV_NOTARY_KEY_ID, REMOTETV_NOTARY_ISSUER. The ticket is stapled to the app
# before zipping, so Gatekeeper accepts it offline.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

./scripts/swift.sh build -c release --product RemoteTV
./scripts/swift.sh build -c release --product tvctl
./scripts/bundle.sh release "$OUT/RemoteTV.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OUT/RemoteTV.app/Contents/Info.plist")"
ZIP="$OUT/RemoteTV-$VERSION.zip"
codesign --verify --strict --deep "$OUT/RemoteTV.app"

if [[ -n "${REMOTETV_NOTARY_KEY:-}" ]]; then
  ditto -c -k --keepParent "$OUT/RemoteTV.app" "$OUT/notarize.zip"
  result="$(xcrun notarytool submit "$OUT/notarize.zip" --wait --output-format json \
    --key "$REMOTETV_NOTARY_KEY" --key-id "$REMOTETV_NOTARY_KEY_ID" --issuer "$REMOTETV_NOTARY_ISSUER")"
  echo "$result"
  rm "$OUT/notarize.zip"
  if [[ "$(jq -r .status <<<"$result")" != Accepted ]]; then
    xcrun notarytool log "$(jq -r .id <<<"$result")" \
      --key "$REMOTETV_NOTARY_KEY" --key-id "$REMOTETV_NOTARY_KEY_ID" --issuer "$REMOTETV_NOTARY_ISSUER" || true
    echo "release: notarization failed" >&2
    exit 1
  fi
  xcrun stapler staple "$OUT/RemoteTV.app"
  spctl --assess --type execute --verbose "$OUT/RemoteTV.app"
fi

ditto -c -k --keepParent "$OUT/RemoteTV.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# Upgrades: brew swaps /Applications/RemoteTV.app under the running app, which notices
# (BundleWatcher) and restarts into the new version if its window is on screen, or quits
# if hidden. No `uninstall quit:`: brew runs uninstall stanzas on every upgrade too, and
# quitting through Apple Events asks for Automation access. tvctl reaches the PATH through
# a symlink the app makes at launch (~/.local/bin/tvctl → Contents/Helpers/tvctl); zap
# removes it with the pairings and preferences. The macOS minimum is
# LSMinimumSystemVersion's job.
cat > "$OUT/remotetv.rb" <<EOF
cask "remotetv" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/lingrino/remotetv/releases/download/v#{version}/RemoteTV-#{version}.zip"
  name "RemoteTV"
  desc "Apple TV remote"
  homepage "https://github.com/lingrino/remotetv"

  depends_on arch: :arm64

  app "RemoteTV.app"

  zap trash: [
    "~/.local/bin/tvctl",
    "~/Library/Application Support/RemoteTV",
    "~/Library/Preferences/com.lingrino.remotetv.plist",
  ]
end
EOF
echo "$VERSION" > "$OUT/version"
echo "release: $ZIP ($SHA)"
