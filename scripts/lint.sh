#!/bin/bash
# Zero compiler warnings in debug (incl. tests) and release. Builds in its own scratch
# dir with -warnings-as-errors, so a warning can't hide behind an incremental build
# (a file that warns never compiles "successfully"). Swift 6 concurrency warnings become
# errors in newer language modes: fixing them now keeps a future toolchain building.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for cfg in debug release; do
  extra=()
  [[ $cfg == debug ]] && extra=(--build-tests)
  if ! out=$(./scripts/swift.sh build -c "$cfg" --scratch-path .build/lint ${extra[@]+"${extra[@]}"} -Xswiftc -warnings-as-errors 2>&1); then
    echo "$out" | grep -E "^/.*(error|warning):" | sed "s|$PWD/||" | sort -u
    echo "lint: $cfg build failed (warnings are errors here)"
    exit 1
  fi
done
echo "lint: debug + release, zero warnings"
