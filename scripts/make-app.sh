#!/bin/sh
# Builds MacBeeb.app in .build/app.
#
#   scripts/make-app.sh            ad-hoc signed, this Mac's architecture
#   UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: ..." scripts/make-app.sh
#
# With a signing identity, everything is signed for notarisation: hardened
# runtime and secure timestamps, inside out (scripts/release.sh does this).
set -e
cd "$(dirname "$0")/.."

if [ -n "$UNIVERSAL" ]; then
    ARCHS="--arch arm64 --arch x86_64"
fi
swift build -c release $ARCHS --product MacBeeb
swift build -c release $ARCHS --product macbeeb-mcp
BIN=$(swift build -c release $ARCHS --show-bin-path)

APP=.build/app/MacBeeb.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/MacBeeb" "$APP/Contents/MacOS/"
# The MCP server, for agents: claude mcp add macbeeb -- .../MacBeeb.app/Contents/MacOS/macbeeb-mcp
cp "$BIN/macbeeb-mcp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R "$BIN/macbeeb_BeebROMs.bundle" "$APP/Contents/Resources/"
# The icon: Icon Composer's AppIcon.icon (drawn by Tools/icon/draw.py),
# compiled to Assets.car for macOS 26 and AppIcon.icns.
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist .build/app/AppIcon-partial.plist > /dev/null
rm .build/app/AppIcon-partial.plist
# BeebAsm, for assembling from VS Code and the agent tools (GPLv3, like
# MacBeeb; its source is the ThirdParty/beebasm submodule).
rm -f .build/beebasm/beebasm
make beebasm UNIVERSAL=$UNIVERSAL
cp .build/beebasm/beebasm "$APP/Contents/MacOS/"
cp ThirdParty/beebasm/COPYING.txt "$APP/Contents/Resources/BeebAsm-COPYING.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# ditto keeps the framework's symlinks.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [ -n "$SPARKLE_PUBLIC_KEY" ]; then
    plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi
if [ -n "$VERSION" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "$BUILD_NUMBER" ]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    # Ad hoc: no hardened runtime, whose library validation would reject
    # the (also ad hoc, so "different team") Sparkle framework.
    OPTIONS="--timestamp=none"
else
    OPTIONS="--options runtime --timestamp"
fi
sign() {
    codesign --force $OPTIONS --sign "$IDENTITY" "$@"
}

# Sparkle's helpers first (as Sparkle's documentation describes), then the
# framework, the MCP server and the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/MacOS/macbeeb-mcp"
sign "$APP/Contents/MacOS/beebasm"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
