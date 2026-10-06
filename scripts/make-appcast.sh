#!/usr/bin/env bash
#
# Signs a release DMG for Sparkle and writes appcast.xml next to it.
#
#   scripts/make-appcast.sh <path/to/ColimaDesktop-X.Y.dmg>
#
# Sparkle's generate_appcast signs the DMG and reads version, build and minimum macOS from the app
# inside it. The private key comes from SPARKLE_ED_PRIVATE_KEY (CI) or the login keychain (account
# "colima-desktop"; README → Update signing key). The signature is then checked against the
# SUPublicEDKey of the app inside the DMG — what installed copies check — so a key mismatch fails
# here instead of on every user's machine.
#
# Environment:
#   SPARKLE_BIN   Directory with Sparkle's tools. CI passes the release archive it verified by
#                 checksum; locally the package's artifact is used.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER_REPO="mx0r/colima-desktop"
KEY_ACCOUNT="colima-desktop"

fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 && -f "$1" ]] || fail "usage: $0 <path/to/ColimaDesktop-X.Y.dmg>"
DMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
NAME=$(basename "$DMG")

if [[ -z "${SPARKLE_BIN:-}" ]]; then
  for candidate in \
    "$REPO/.build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    "$REPO/Packages/ColimaDesktopKit/.build/artifacts/sparkle/Sparkle/bin"; do
    [[ -x "$candidate/generate_appcast" ]] && { SPARKLE_BIN="$candidate"; break; }
  done
fi
[[ -x "${SPARKLE_BIN:-}/generate_appcast" ]] || fail "generate_appcast not found — set SPARKLE_BIN or run make test"

# --- read the app that ships ------------------------------------------------

# plutil reads the file itself; `defaults read` can answer from a cache for a rewritten path.
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
INFO="$MOUNT/ColimaDesktop.app/Contents/Info.plist"
read_info() { plutil -extract "$1" raw -o - "$INFO"; }
if [[ -f "$INFO" ]]; then
  VERSION=$(read_info CFBundleShortVersionString)
  PUBLIC_KEY=$(read_info SUPublicEDKey)
fi
hdiutil detach "$MOUNT" -quiet
[[ -n "${VERSION:-}" && -n "${PUBLIC_KEY:-}" ]] || fail "no ColimaDesktop.app with a version and SUPublicEDKey in $NAME"
TAG="v$VERSION"

# --- generate ---------------------------------------------------------------

# generate_appcast works on a folder: this release and its release note, nothing else.
WORK=$(mktemp -d)
cp "$DMG" "$WORK/"
cat > "$WORK/${NAME%.dmg}.html" <<HTML
<p>Colima Desktop $VERSION. <a href="https://github.com/$OWNER_REPO/releases/tag/$TAG">What changed</a>.</p>
HTML

ARGS=(
  --download-url-prefix "https://github.com/$OWNER_REPO/releases/download/$TAG/"
  --full-release-notes-url "https://github.com/$OWNER_REPO/releases/tag/$TAG"
  --link "https://github.com/$OWNER_REPO"
  --embed-release-notes
  --maximum-deltas 0
  -o "$WORK/appcast.xml"
)
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  # Base64 has no whitespace; strip any newline the secret picked up on the way in.
  printf '%s' "${SPARKLE_ED_PRIVATE_KEY//[[:space:]]/}" \
    | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${ARGS[@]}" "$WORK" >/dev/null
else
  "$SPARKLE_BIN/generate_appcast" --account "$KEY_ACCOUNT" "${ARGS[@]}" "$WORK" >/dev/null
fi

# --- check ------------------------------------------------------------------

APPCAST="$WORK/appcast.xml"
xmllint --noout "$APPCAST" || fail "generate_appcast wrote invalid XML"
signature=$(xmllint --xpath 'string(//item/enclosure/@*[local-name()="edSignature"])' "$APPCAST")
url=$(xmllint --xpath 'string(//item/enclosure/@url)' "$APPCAST")
[[ -n "$signature" ]] || fail "the appcast has no EdDSA signature"
[[ "$url" == "https://github.com/$OWNER_REPO/releases/download/$TAG/$NAME" ]] \
  || fail "unexpected download URL in the appcast: $url"

swift "$REPO/scripts/verify-ed-signature.swift" "$PUBLIC_KEY" "$signature" "$DMG" \
  || fail "the signing key does not match SUPublicEDKey in the app (SPARKLE_PUBLIC_ED_KEY in project.yml)"

cp "$APPCAST" "$(dirname "$DMG")/appcast.xml"
# Nothing secret in either folder; trash them where trash exists (CI runners are discarded).
if command -v trash >/dev/null 2>&1; then trash "$WORK" "$MOUNT"; fi

echo "Appcast: $(dirname "$DMG")/appcast.xml ($VERSION)"
