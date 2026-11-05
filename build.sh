#!/bin/bash
# Builds Guppy.app and a disk image to install it, without Xcode or an Apple Developer account.
#
#   ./build.sh            release build → build/Guppy.app and build/Guppy.dmg
#   ./build.sh debug      debug build (no disk image)
#
# The app is ad-hoc signed unless you pass a signing identity:
#
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Guppy.app"

# A universal app for Apple silicon and Intel Macs: build each architecture, then join them.
# (Building both in one `swift build --arch … --arch …` needs Xcode; this works with the Command Line Tools.)
BINARIES=()
for ARCH in arm64 x86_64; do
    swift build -c "$CONFIG" --triple "$ARCH-apple-macosx14.0"
    BINARIES+=("$(swift build -c "$CONFIG" --triple "$ARCH-apple-macosx14.0" --show-bin-path)/Guppy")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Guppy"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Generate the standard macOS icon sizes from the source icon on every build.
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" Resources/Branding/guppy-icon.png \
        --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$((SIZE * 2))" "$((SIZE * 2))" Resources/Branding/guppy-icon.png \
        --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${SIGN_IDENTITY:-ad-hoc})"

if [ "$CONFIG" = "release" ]; then
    # A disk image with the app and a link to Applications, the usual way to install a Mac app.
    STAGE="$ICON_TMP/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f build/Guppy.dmg
    hdiutil create -volname "Guppy" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet build/Guppy.dmg
    echo "Built build/Guppy.dmg"
fi
echo "Run it with: open $APP"
