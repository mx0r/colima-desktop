PROJECT  := ColimaDesktop.xcodeproj
SCHEME   := ColimaDesktop
BUILD    := .build
APP      := $(BUILD)/Build/Products/Debug/ColimaDesktop.app
PACKAGE  := Packages/ColimaDesktopKit

# -skipPackagePluginValidation: SwiftTerm ships a build tool plugin, which Xcode would otherwise
# ask to trust interactively.
XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
       -derivedDataPath $(BUILD) -skipPackagePluginValidation -quiet

.PHONY: all gen icon build test test-live run stop install release docs-images clean

all: build

## Regenerate the Xcode project from project.yml.
gen:
	xcodegen generate --quiet

## Redraw App/Assets.xcassets/AppIcon.appiconset from ColimaLlama.swift.
icon:
	scripts/generate-app-icon.sh

build: gen
	$(XCB) build

## Unit tests (no colima needed).
test:
	cd $(PACKAGE) && swift test

## Unit tests plus integration tests against the local colima (default profile running).
test-live:
	cd $(PACKAGE) && COLIMA_DESKTOP_IT=1 swift test

## Rebuild and relaunch from .build/.
run: build stop
	@open $(APP)

stop:
	@pkill -x ColimaDesktop 2>/dev/null || true

## Copy to /Applications and run from there. Launch at login registers the bundle path,
## so it should point at this copy rather than one in .build/ that the next build replaces.
install: build stop
	@trash /Applications/ColimaDesktop.app 2>/dev/null || true
	@ditto $(APP) /Applications/ColimaDesktop.app
	@open /Applications/ColimaDesktop.app
	@echo "Installed to /Applications and launched."

## Test, build Release, sign and package a DMG into builds/<date>-<version>/.
release:
	scripts/build-release.sh

## Re-render the README and site images from the real drawing code.
docs-images:
	cd $(PACKAGE) && COLIMA_DESKTOP_RENDER_DOCS="$(CURDIR)" swift test --filter DocumentationImages

clean: stop
	@trash $(BUILD) 2>/dev/null || true
	@trash $(PROJECT) 2>/dev/null || true
