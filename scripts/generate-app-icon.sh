#!/bin/sh
# Regenerates App/Assets.xcassets/AppIcon.appiconset from the vector llama (ColimaLlama.swift).
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'trash "$work" 2>/dev/null || true' EXIT
swiftc -parse-as-library -O \
  -o "$work/generate-app-icon" \
  scripts/AppIconGenerator.swift \
  Packages/ColimaDesktopKit/Sources/ColimaUI/Branding/ColimaLlama.swift
"$work/generate-app-icon" App/Assets.xcassets/AppIcon.appiconset
