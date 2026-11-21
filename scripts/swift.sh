#!/bin/bash
# `swift` wrapper used by the Makefile and scripts, so the same commands work with Xcode
# (CI, and this Mac since 2026-11) and with the Command Line Tools alone.
#
# With Xcode active it is plain `swift`. With the Command Line Tools active (xcode-select,
# or DEVELOPER_DIR), it works around two CLT problems seen on 2026-11-14:
# - the CLT shipped stale (Feb 2024) PackageDescription *.private.swiftinterface files
#   that shadow the current API, so every manifest failed to link: SwiftPM gets a copy
#   of the manifest/plugin API without them;
# - SwiftPM didn't find the swift-testing macro plugin: test builds get its path.
# Drop the CLT branch once a CLT-only `swift test` works without it.
set -euo pipefail
CLT=/Library/Developer/CommandLineTools
if [[ "${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}" != "$CLT" ]]; then
  exec swift "$@"
fi

SRC=$CLT/usr/lib/swift/pm
DST="$HOME/Library/Application Support/RemoteTVDev/swiftpm-libs"
STAMP="$DST/.source-mtime"
cur="$(stat -f %m "$SRC/ManifestAPI/libPackageDescription.dylib")"
if [[ ! -f "$STAMP" || "$(cat "$STAMP")" != "$cur" ]]; then
  mkdir -p "$DST"
  for d in ManifestAPI PluginAPI; do
    rsync -a --delete --exclude '*.private.swiftinterface' "$SRC/$d/" "$DST/$d/"
  done
  echo "$cur" > "$STAMP"
fi
export SWIFTPM_CUSTOM_LIBS_DIR="$DST"

args=("$@")
if [[ "${1:-}" == test || " $* " == *" --build-tests "* ]]; then
  args+=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
fi
exec swift "${args[@]}"
