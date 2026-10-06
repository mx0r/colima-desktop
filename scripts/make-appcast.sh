#!/usr/bin/env bash
#
# Signs a release DMG for Sparkle and writes appcast.xml next to it.
#
#   scripts/make-appcast.sh <path/to/ColimaDesktop.app> <path/to/ColimaDesktop-X.Y.dmg>
#
# The private key comes from SPARKLE_ED_PRIVATE_KEY (the CI secret) or, locally, from the login
# keychain (account "colima-desktop"; see README → Update signing key). The signature is then
# checked against the SUPublicEDKey inside the app: an update the installed app cannot verify is
# worse than no update, so a mismatch fails the release.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
DMG="$2"
OWNER_REPO="mx0r/colima-desktop"
KEY_ACCOUNT="colima-desktop"

fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Sparkle's tools come with the pinned package; use whichever checkout resolved it.
SIGN_UPDATE=""
for candidate in \
  "$REPO/.build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
  "$REPO/Packages/ColimaDesktopKit/.build/artifacts/sparkle/Sparkle/bin/sign_update"; do
  [[ -x "$candidate" ]] && { SIGN_UPDATE="$candidate"; break; }
done
[[ -n "$SIGN_UPDATE" ]] || fail "sign_update not found — resolve the package first (make test)"

plist() { defaults read "$APP/Contents/Info" "$1"; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MIN_OS=$(plist LSMinimumSystemVersion)
PUBLIC_KEY=$(plist SUPublicEDKey)
NAME=$(basename "$DMG")

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  # Base64 has no whitespace; strip any newline the secret picked up on the way in.
  attributes=$(printf '%s' "${SPARKLE_ED_PRIVATE_KEY//[[:space:]]/}" | "$SIGN_UPDATE" --ed-key-file - "$DMG")
else
  attributes=$("$SIGN_UPDATE" --account "$KEY_ACCOUNT" "$DMG")
fi
signature=$(sed -E 's/.*edSignature="([^"]+)".*/\1/' <<<"$attributes")
length=$(sed -E 's/.*length="([0-9]+)".*/\1/' <<<"$attributes")
[[ -n "$signature" && -n "$length" ]] || fail "could not read the signature from sign_update"

swift "$REPO/scripts/verify-ed-signature.swift" "$PUBLIC_KEY" "$signature" "$DMG" \
  || fail "the signing key does not match SUPublicEDKey in the app (SPARKLE_PUBLIC_ED_KEY in project.yml)"

PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
TAG="v$VERSION"

cat > "$(dirname "$DMG")/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Colima Desktop</title>
    <link>https://github.com/$OWNER_REPO</link>
    <item>
      <title>Colima Desktop $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$OWNER_REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>Colima Desktop $VERSION. <a href="https://github.com/$OWNER_REPO/releases/tag/$TAG">Release notes on GitHub</a>.</p>]]></description>
      <enclosure url="https://github.com/$OWNER_REPO/releases/download/$TAG/$NAME" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML

echo "Appcast: $(dirname "$DMG")/appcast.xml ($VERSION, build $BUILD)"
