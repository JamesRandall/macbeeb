#!/bin/sh
# Builds MacBeeb.app in .build/app.
#
#   scripts/make-app.sh            ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/make-app.sh
set -e
cd "$(dirname "$0")/.."

swift build -c release --product MacBeeb
BIN=$(swift build -c release --show-bin-path)

APP=.build/app/MacBeeb.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacBeeb" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R "$BIN/macbeeb_BeebROMs.bundle" "$APP/Contents/Resources/"

codesign --force --deep --options runtime --timestamp=none \
    --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
