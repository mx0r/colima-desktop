#!/usr/bin/env bash
#
# Signs a release DMG for Sparkle and writes appcast.xml next to it.
#
#   scripts/make-appcast.sh [--channel beta] <path/to/ColimaDesktop-X.Y.dmg>
#
# --channel puts the entry on a Sparkle channel (beta builds); without it the entry is stable.
# scripts/merge-appcast.swift then merges the result into the cumulative feed, site/appcast.xml.
#
# Sparkle's generate_appcast signs the DMG and reads version, build and minimum macOS from the app
# inside it. The private key comes from SPARKLE_ED_PRIVATE_KEY (CI) or the login keychain (account
# "colima-desktop"; README → Update signing key). The signature is then checked against the
# SUPublicEDKey of the app inside the DMG — what installed copies check — so a key mismatch fails
# here instead of on every user's machine.
#
# Release notes: release-notes/<version>.md (the most important changes, Markdown) is embedded in
# the entry, so Sparkle's update dialog shows it, followed by a link to the full release on GitHub.
#
# Environment:
#   SPARKLE_BIN            Directory with Sparkle's tools. CI passes the release archive it verified
#                          by checksum; locally the package's artifact is used.
#   REQUIRE_RELEASE_NOTES  1 to fail when release-notes/<version>.md is missing (tagged releases).
#                          Otherwise a missing file falls back to a plain link, with a warning.
#   RELEASE_NOTES_DIR      Where to look for <version>.md (default: release-notes/).
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER_REPO="mx0r/colima-desktop"
KEY_ACCOUNT="colima-desktop"

fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

CHANNEL=""
if [[ "${1:-}" == "--channel" ]]; then
  CHANNEL="${2:-}"
  [[ "$CHANNEL" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid channel name: $CHANNEL"
  shift 2
fi
[[ $# -eq 1 && -f "$1" ]] || fail "usage: $0 [--channel beta] <path/to/ColimaDesktop-X.Y.dmg>"
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
RELEASE_URL="https://github.com/$OWNER_REPO/releases/tag/$TAG"
NOTES="${RELEASE_NOTES_DIR:-$REPO/release-notes}/$VERSION.md"
if [[ -f "$NOTES" ]]; then
  # The highlights, then the way to everything else.
  { cat "$NOTES"; printf '\n[All changes in %s on GitHub](%s)\n' "$VERSION" "$RELEASE_URL"; } > "$WORK/${NAME%.dmg}.md"
elif [[ "${REQUIRE_RELEASE_NOTES:-}" == "1" ]]; then
  fail "missing $NOTES — write the most important changes of $VERSION there"
else
  printf '\033[1;33mWarning:\033[0m no %s; the update shows only a link\n' "$NOTES" >&2
  cat > "$WORK/${NAME%.dmg}.html" <<HTML
<p>Colima Desktop $VERSION. <a href="$RELEASE_URL">What changed</a>.</p>
HTML
fi

ARGS=(
  --download-url-prefix "https://github.com/$OWNER_REPO/releases/download/$TAG/"
  --full-release-notes-url "https://github.com/$OWNER_REPO/releases/tag/$TAG"
  --link "https://github.com/$OWNER_REPO"
  --embed-release-notes
  --maximum-deltas 0
  -o "$WORK/appcast.xml"
)
[[ -n "$CHANNEL" ]] && ARGS+=(--channel "$CHANNEL")
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

echo "Appcast: $(dirname "$DMG")/appcast.xml ($VERSION${CHANNEL:+, channel $CHANNEL})"
