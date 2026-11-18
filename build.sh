#!/bin/bash
# Builds build/Retroamp.app with the Command Line Tools' swiftc (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Retroamp.app
ARCH=$(uname -m)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/ModuleCache

# The linker ad-hoc signs the binary. Deliberately no `codesign` step afterwards: re-signing
# changes the file hash, and binary-allowlisting tools (e.g. Santa) that trust compiler
# output then block the app. The linker names the signature after the output file, so link
# as the bundle ID and move the file into place (a move keeps the hash).
swiftc -O -swift-version 5 \
  -target "$ARCH-apple-macos14.2" \
  -module-cache-path build/ModuleCache \
  -o build/local.retroamp \
  Sources/*.swift \
  -framework AppKit -framework CoreAudio -framework AudioToolbox -framework Accelerate
mv build/local.retroamp "$APP/Contents/MacOS/Retroamp"

cp Info.plist "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/Retroamp" --make-icon "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || true

echo "Built $APP"
