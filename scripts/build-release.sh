#!/usr/bin/env bash
#
# Test, build, sign and package Colima Desktop as a DMG.
#
#   ./scripts/build-release.sh      (or: make release)
#
# Output lands in builds/<date>-<version>/: the .dmg, a readme for whoever installs it, and a
# SHA-256 checksum.
#
# Environment:
#   SIGN_IDENTITY           Signing identity. Defaults to "-" (ad hoc), which is all the
#                           development machine has. Set a "Developer ID Application: …" identity
#                           and the script signs with the hardened runtime and prints how to notarise.
#   MARKETING_VERSION       Override the version in project.yml — CI sets both from the git tag
#   CURRENT_PROJECT_VERSION and the run number.
#   SKIP_TESTS=1            Package without running the unit tests. Deliberately loud.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SCHEME=ColimaDesktop
CONFIG=Release
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DERIVED="$REPO/.build/derived"
STAGE="$REPO/.build/stage"

# Version overrides, if any. Built as an array so an unset one passes nothing; the `[@]+` guard
# is for bash 3.2, which macOS ships and which errors on expanding an empty array under `set -u`.
VERSION_SETTINGS=()
[[ -n "${MARKETING_VERSION:-}" ]] && VERSION_SETTINGS+=("MARKETING_VERSION=$MARKETING_VERSION")
[[ -n "${CURRENT_PROJECT_VERSION:-}" ]] \
  && VERSION_SETTINGS+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found — brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found — install Xcode"
mkdir -p "$REPO/.build"

# SwiftTerm compiles a Metal shader, and Xcode 26 ships the Metal compiler as a separate download.
xcrun metal -v >/dev/null 2>&1 \
  || fail "Metal Toolchain missing — xcodebuild -downloadComponent MetalToolchain"

# --- test -------------------------------------------------------------------

if [[ "${SKIP_TESTS:-}" == "1" ]]; then
  warn "SKIP_TESTS=1: packaging without running the tests"
else
  info "Running unit tests"
  # Integration tests stay off (they need a running colima); see docs/TESTING.md.
  ( cd Packages/ColimaDesktopKit && swift test ) >"$REPO/.build/test.log" 2>&1 \
    || { tail -40 "$REPO/.build/test.log" >&2; fail "tests failed (full log: .build/test.log)"; }
  grep -E "Test run with" "$REPO/.build/test.log" | tail -1
fi

# --- build ------------------------------------------------------------------

# The project is generated, never committed.
info "Generating Xcode project"
xcodegen generate --quiet

info "Building $CONFIG"
# -skipPackagePluginValidation: SwiftTerm's build tool plugin would otherwise need an
# interactive "Trust & Enable" in Xcode.
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation \
  ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} \
  clean build >"$REPO/.build/xcodebuild.log" 2>&1 \
  || { grep -E "error:" "$REPO/.build/xcodebuild.log" | head -20 >&2; fail "build failed (full log: .build/xcodebuild.log)"; }

APP="$DERIVED/Build/Products/$CONFIG/$SCHEME.app"
[[ -d "$APP" ]] || fail "no app at $APP"
APP_NAME=$(basename "$APP" .app)

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$APP/Contents/Info" CFBundleVersion)
BUNDLE_ID=$(defaults read "$APP/Contents/Info" CFBundleIdentifier)
# The bundle on disk is ColimaDesktop.app; everything a user reads says "Colima Desktop".
DISPLAY_NAME=$(defaults read "$APP/Contents/Info" CFBundleName)
ARCHS=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
DATE=$(date +%Y-%m-%d)
OUT="$REPO/builds/$DATE-$VERSION"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

info "$DISPLAY_NAME $VERSION (build $BUILD), $BUNDLE_ID, $ARCHS"

# --- stage ------------------------------------------------------------------

reset_dir() {
  local dir="$1"
  if [[ -e "$dir" ]]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$dir"
    else
      fail "$dir already exists and 'trash' is unavailable — move it aside yourself"
    fi
  fi
  mkdir -p "$dir"
}

reset_dir "$STAGE"
reset_dir "$OUT"

# ditto, not cp -R: it preserves the code signature and extended attributes.
ditto "$APP" "$STAGE/$APP_NAME.app"
# Drag-to-install target.
ln -s /Applications "$STAGE/Applications"

# --- sign -------------------------------------------------------------------

# No entitlements: the app is not sandboxed (it runs colima and connects to the Docker socket in
# the user's home). There is no nested code; SwiftTerm's resource bundle is sealed as a resource.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  info "Signing ad hoc (no Developer ID on this machine)"
  codesign --force --sign - "$STAGE/$APP_NAME.app"
else
  info "Signing as $SIGN_IDENTITY"
  # Notarisation requires the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE/$APP_NAME.app"
fi

codesign --verify --strict --verbose=1 "$STAGE/$APP_NAME.app" \
  || fail "signature did not verify"

# --- readme for whoever installs it -----------------------------------------

cat > "$STAGE/Read Me.txt" <<EOF
$DISPLAY_NAME $VERSION (build $BUILD)
$(date '+%-d %B %Y')

A menu bar app for Colima: start, stop and restart the VM, switch profiles,
and manage containers — logs, a terminal, ports — without the docker CLI.

REQUIREMENTS
  macOS 26 or later, and Colima (https://github.com/abiosoft/colima):
      brew install colima
  Container features need a profile with the Docker runtime (Colima's default).
  The docker CLI is not needed: the app talks to the Docker Engine API directly.

INSTALL
  Drag $APP_NAME to the Applications folder in this window.

FIRST LAUNCH
  This app is signed ad hoc rather than with an Apple Developer ID, so macOS
  will refuse to open it on the first try. Right-click it in Applications and
  choose Open, then confirm. You only need to do this once.

  If macOS still refuses, clear the download flag:
      xattr -d com.apple.quarantine "/Applications/$APP_NAME.app"

USING IT
  The llama in the menu bar shows the VM state. Click it for the menu:
  status, information, profiles, Start / Stop / Restart, and every container
  grouped by Compose project, each with Logs, Terminal, open ports, start,
  stop, restart and delete.

  Settings has the menu bar icon style, launch at login, notifications and
  path overrides. Nothing needs configuring: colima, its home directory and
  the Docker socket are detected the way colima itself finds them.

LAUNCH AT LOGIN
  Turn it on from the copy in /Applications. macOS registers the app's path,
  so a copy elsewhere stops opening once it moves.

THIRD-PARTY NOTICES
  See "Third-Party Notices.txt".

With help from Claude.
EOF

cp "$REPO/THIRD_PARTY_NOTICES.md" "$STAGE/Third-Party Notices.txt"

# --- dmg --------------------------------------------------------------------

info "Building DMG"
hdiutil create \
  -volname "$DISPLAY_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

cp "$STAGE/Read Me.txt" "$OUT/Read Me.txt"
( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

if command -v trash >/dev/null 2>&1; then trash "$STAGE"; fi

info "Done"
echo
echo "  $DMG"
echo "  $(du -h "$DMG" | cut -f1)   $(cut -d' ' -f1 < "$DMG.sha256")"
echo

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  cat <<'EOF'
Signed with a real identity, so you can notarise it — which removes the
right-click-to-open step for everyone else:

    xcrun notarytool submit "<the .dmg>" --keychain-profile "<profile>" --wait
    xcrun stapler staple "<the .dmg>"

Set the profile up once with:
    xcrun notarytool store-credentials "<profile>" \
      --apple-id "<you@example.com>" --team-id "<TEAMID>"
EOF
fi
