#!/bin/bash
# Signs a release DMG for Sparkle and writes build/appcast.xml (a single-item feed for that release).
# Usage: Scripts/make-appcast.sh <dmg> <version> <owner/repo> [ed-key-file]
# Without a key file, the signing key is read from the login keychain (as created by generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="$1"; VERSION="$2"; REPO="$3"; KEYFILE="${4:-}"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "Run 'swift package resolve' first"; exit 1; }

if [ -n "$KEYFILE" ]; then
    SIG="$("$SIGN_UPDATE" --ed-key-file "$KEYFILE" "$DMG")"
else
    SIG="$("$SIGN_UPDATE" "$DMG")"
fi
# SIG looks like: sparkle:edSignature="…" length="…"

BUNDLE_VERSION="${VERSION%%-*}"
TAG="v$VERSION"
DATE="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"
mkdir -p build
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tock</title>
    <item>
      <title>Version $BUNDLE_VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUNDLE_VERSION</sparkle:version>
      <sparkle:shortVersionString>$BUNDLE_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "Wrote build/appcast.xml"
