#!/bin/bash
# Usage:
#   ./build.sh            build build/Tock.app (universal, ad-hoc signed)
#   ./build.sh test       run the self-tests
#   ./build.sh install    build and copy to /Applications (or ~/Applications if that isn't writable)
#   ./build.sh dmg        build and create build/Tock-<version>.dmg
#
# Distribution: set SIGN_ID="Developer ID Application: Your Name (TEAMID)" to sign with the
# hardened runtime, and to notarize and staple the DMG either
#   NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`>
# or (CI)
#   NOTARY_KEY_PATH=<AuthKey.p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER_ID=<uuid>
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"          # may carry a suffix, e.g. 1.1.0-rc1 (used for the DMG name)
BUNDLE_VERSION="${VERSION%%-*}"   # Info.plist wants plain 1.1.0
APP=build/Tock.app

build_app() {
    if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
        BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tock"
    else
        echo "Universal build unavailable, building for this Mac only"
        swift build -c release
        BIN="$(swift build -c release --show-bin-path)/Tock"
    fi

    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN" "$APP/Contents/MacOS/Tock"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.tock</string>
  <key>CFBundleName</key><string>Tock</string>
  <key>CFBundleDisplayName</key><string>Tock</string>
  <key>CFBundleExecutable</key><string>Tock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    if [ -n "${SIGN_ID:-}" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    else
        codesign --force --sign - "$APP"
    fi
    echo "Built $APP ($VERSION)"
}

case "${1:-build}" in
    build) build_app ;;
    test)
        swift build >/dev/null
        "$(swift build --show-bin-path)/Tock" --selftest
        ;;
    install)
        build_app
        if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
        mkdir -p "$DEST"
        pkill -x Tock 2>/dev/null || true
        rm -rf "$DEST/Tock.app"
        cp -R "$APP" "$DEST/Tock.app"
        echo "Installed $DEST/Tock.app"
        open "$DEST/Tock.app"
        ;;
    dmg)
        build_app
        STAGE=build/dmg
        DMG="build/Tock-$VERSION.dmg"
        rm -rf "$STAGE" "$DMG"
        mkdir -p "$STAGE"
        cp -R "$APP" "$STAGE/"
        ln -s /Applications "$STAGE/Applications"
        hdiutil create -volname "Tock" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
        rm -rf "$STAGE"
        if [ -n "${SIGN_ID:-}" ]; then
            codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
            if [ -n "${NOTARY_KEY_PATH:-}" ]; then
                xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
                    --issuer "$NOTARY_ISSUER_ID" --wait
            elif [ -n "${NOTARY_PROFILE:-}" ]; then
                xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
            else
                echo "Signed but not notarized (set NOTARY_PROFILE or NOTARY_KEY_PATH)"
                echo "Created $DMG"
                exit 0
            fi
            xcrun stapler staple "$DMG"
        fi
        echo "Created $DMG"
        ;;
    *) echo "Unknown command: $1"; exit 2 ;;
esac
