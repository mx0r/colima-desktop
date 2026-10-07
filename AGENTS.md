# Colima Desktop — notes for coding agents

Native macOS 26 menu bar app for [Colima](https://github.com/abiosoft/colima): VM status and
control, profiles, and container management (logs, embedded terminal, ports, start/stop/restart/
delete) over the Docker Engine API, with self-update through Sparkle. Read `README.md` for what it
does and `docs/ARCHITECTURE.md` for how; this file is for working on it.

- Repository: <https://github.com/mx0r/colima-desktop> (GitHub user `mx0r`)
- Site: <https://mx0r.github.io/colima-desktop/> (`site/`)
- License: MIT. Third-party notices: `THIRD_PARTY_NOTICES.md` (shipped in the DMG).

## Stack

- Swift 6 language mode with strict concurrency, `@Observable`, Swift Testing.
- AppKit for the status item and menu (`NSStatusItem` + `NSMenu`); SwiftUI for the windows.
- Dependencies (pinned exactly in `Package.swift`): SwiftTerm 1.20.0 (terminal), Sparkle 2.10.0
  (updates). Nothing else.
- Colima through its CLI; Docker through HTTP/1.1 on the profile's unix socket (Network.framework),
  API pinned to v1.44. The docker CLI is not used.
- XcodeGen: `project.yml` is the source of truth. `ColimaDesktop.xcodeproj` **and**
  `App/Info.plist` are generated — edit `project.yml`, never those two.

## Layout

```
App/                             main.swift, entitlements, asset catalog
Packages/ColimaDesktopKit/       all code (local Swift package)
  Sources/ColimaDomain/          models, VMLifecycle reducer, ports (protocols), settings; Foundation only
  Sources/ColimaInfrastructure/  processes, colima CLI, unix-socket HTTP, Docker client, system services
  Sources/ColimaFeatures/        AppStore, MenuModelBuilder, logs/terminal/settings view models
  Sources/ColimaUI/              status item, MenuRenderer, icons (Branding/ColimaLlama.swift), windows
  Sources/ColimaTerminal/        SwiftTerm bridge (isolates the dependency; uses ColimaUI for console fonts)
  Sources/ColimaUpdates/         Sparkle updater (isolates the dependency)
  Sources/ColimaAppShell/        composition root: live dependencies, ActionRouter, AppDelegate
  Sources/ColimaTestSupport/     fakes, ManualClock
  Tests/                         one target per layer, plus live integration tests
scripts/                         build-release.sh, make-appcast.sh, verify-ed-signature.swift, icons
.github/workflows/               ci.yml, release.yml (build + publish jobs), pages.yml
docs/                            ARCHITECTURE.md, DOCKER_API.md, TESTING.md, README images
site/                            landing page (static, no scripts)
```

**Dependency rule (compiler-enforced):** Features and UI never import Infrastructure. Only
`ColimaAppShell` sees concrete adapters. The app target only calls `ColimaDesktopApplication.run()`.

**Appearance:** never set `NSApp.appearance`. It stays at the macOS setting, so a window group set
to System follows macOS while another group is forced light or dark (macOS has no reliable API
for the system appearance once the app overrides it). `WindowManager` sets each window's appearance
by role: `.console(.terminal)` or `.console(.logs)` (those windows and their sheets) or interface
(all other windows, including About, alerts and Sparkle's, caught when they become key). The status menu and alerts set the
interface appearance themselves. Colors that AppKit or SwiftTerm resolve once (layer colors,
`TerminalView` default colors) must be resolved again when the effective appearance changes.

## Build, test, run

```sh
make test         # unit tests (swift test in the package)
make test-live    # plus integration tests against the local colima (COLIMA_DESKTOP_IT=1)
make build        # xcodegen + Debug build into .build/
make run          # build + relaunch from .build/
make install      # copy the Debug build to /Applications and launch it
make release      # tests + Release build + DMG into builds/ (+ appcast with the signing key)
make docs-images  # re-render README/site images from the real drawing code
make icon         # redraw the app icon from ColimaLlama.swift
```

Xcode builds need the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) for
SwiftTerm's shader; command line builds pass `-skipPackagePluginValidation` for its plugin.

## Releasing

A release is a tag; the workflow does the rest. **In this order:**

1. Bump `MARKETING_VERSION` in `project.yml`. The tag overrides it anyway, but local builds should
   not keep calling themselves the old version.
2. **Write `release-notes/X.Y.md`**: the most important changes, user-facing, a few Markdown
   bullets. Sparkle embeds it in the update dialog (followed by a link to the full release), and
   it heads the GitHub release above GitHub's generated change list. Never just a link: a tagged
   release without this file fails.
3. **Update `site/index.html`** — the download button hardcodes the DMG URL
   (`…/releases/download/vX.Y/ColimaDesktop-X.Y.dmg`), and the version appears in the eyebrow line,
   the button and under the buttons. A tagged release with a stale page points everyone at the
   previous build. This is the step that gets forgotten. If the menu changed, update the menu
   illustrations on the page too.
4. Commit, push, then `git tag vX.Y && git push origin vX.Y`. A beta is any version with a "-"
   (`v0.8.0-beta.1`): it becomes a GitHub prerelease on Sparkle's beta channel, and step 3 does
   not apply (the site keeps pointing at the newest stable release).
5. Watch it: `gh run watch <id> -R mx0r/colima-desktop`. The **build** job tests, builds and
   packages without secrets; the **publish** job (environment `release`, `v*` tags only) signs the
   DMG for Sparkle, checks the signature against the app's public key and creates the release.
6. Verify what shipped rather than assuming: download the DMG, `shasum -c` it, mount it, and read
   `CFBundleShortVersionString` out of the app. The release must carry `appcast.xml`, and
   `curl -sL https://github.com/mx0r/colima-desktop/releases/latest/download/appcast.xml` must
   show the new version (stable) — that is what 0.6.x installs read. The feed
   `https://mx0r.github.io/colima-desktop/appcast.xml` must list it too — that is what 0.7+
   installs read.

**The release workflow commits `site/appcast.xml` to `main`** (the cumulative update feed; the
first release creates it). It exists only on `main`, never on feature or `release/x.y` branches —
a copy there would conflict when the branch merges. Pull before starting work after a release, and
never edit the feed by hand: `scripts/merge-appcast.swift` maintains it (`--self-test` runs in CI).

Releases can be tagged on `main` or on a `release/x.y` integration branch (betas usually are): the
publish job runs the tagged commit's scripts and release notes, and writes the feed on `main`.

Build numbers are the commit count of `HEAD` (the release job checks out full history).

**The update signing key never passes through an agent.** The private key lives in the user's
login keychain (account `colima-desktop`) and in the `SPARKLE_ED_PRIVATE_KEY` secret of the
`release` environment. Never print it, export it, write it to a file, or ask for it; the user runs
the steps in README → Update signing key. The public key (`SPARKLE_PUBLIC_ED_KEY` in
`project.yml`) is fine to read and change.

`.github/workflows/pages.yml` publishes `site/` on every push to main that touches it (a
force-push may not trigger it — run it with `gh workflow run pages.yml`).
`.github/workflows/ci.yml` runs tests and a Debug build on pushes and pull requests.

## Naming

The bundle is `ColimaDesktop.app` and `PRODUCT_NAME` is `ColimaDesktop`; that name is load bearing
in the Makefile, the scheme, the release scripts and `pkill -x`. Everything a user reads says
**Colima Desktop**, with a space.

## Conventions

- Tests first for parsers, framing, reducers, the menu model and view models. Fakes live in
  `ColimaTestSupport`.
- Time-based logic takes an injected `Clock`. Tests use `ManualClock` and call `waitForSleepers()`
  before `advance(by:)` — advancing before the sleeper registered makes the test flaky.
- Both icons come from `ColimaUI/Branding/ColimaLlama.swift`. Keep it free of module imports:
  `scripts/generate-app-icon.sh` compiles it standalone. Re-render README/site images with
  `make docs-images` after changing any drawing code.
- Docblocks on public members, short comments that say why. Keep README, `docs/`, the site and
  this file up to date.
- Conventional commits.
- **Never use `rm`** in any form, in commands, scripts or docs. Use `trash`.

## Facts that cost real debugging — do not re-derive

- **Never name a menu item action `perform(_:)`.** `#selector(MenuActionTarget.perform(_:))`
  resolves to NSObject's `performSelector:`, and every click crashes.
- **Never present a modal (`NSAlert.runModal`) from inside a `Task`.** Do it synchronously in the
  `@objc` menu action. A modal inside a main-queue job stalls every MainActor task.
- **Never replace `menu` or `submenu` objects while the menu is open.** `MenuRenderer` reconciles
  items in place by ID; that is what keeps an open submenu open while data refreshes.
- **SwiftTerm 1.12+ needs the Metal Toolchain in Xcode builds** (`swift build` skips the shader,
  so the package builds without it and the app does not). The workflows install it.
- **Unknown colima statuses are not "stopped".** `VMStatus.unknown` keeps the raw value.
- **`colima status` for a stopped profile exits 1** with "is not running". That is a state.
- **`colima list --json` is NDJSON**, one object per profile per line.
- **`SMAppService.mainApp.status` is `.notFound` for a never-registered app** (measured, ad-hoc
  signed). It means "off", not "unsupported".
- **Fill animations start at frame 1**: frame 0 of the cube/rib animation looks exactly like
  "stopped".
- **Hardened runtime is off in `project.yml`**: with ad-hoc signing, library validation refuses
  to load `Sparkle.framework`. `build-release.sh` adds the runtime only for a real identity.
- **Sparkle's nested code is signed inside-out** (XPC services, Autoupdate, Updater.app, the
  framework, then the app) and verified with `codesign --verify --deep`.
- **A menu bar app never lets Sparkle show a scheduled update** (`UpdateReminderState`):
  `immediateFocus` is true right after launch, which would pop a window. The found version
  becomes "Update to X…" in the menu instead.
- **Never mirror Sparkle's `automaticallyChecksForUpdates` into a stored property**: writing it
  persists a user choice and resets the schedule. `SparkleUpdater` reads and writes it directly.
- **Debug builds have no updater** (`COLIMA_DESKTOP_UPDATES`): they share the bundle ID and
  Sparkle's settings with the published app and would be offered it as an update.
- **Update channels are Sparkle channels.** Entries tagged `<sparkle:channel>beta</sparkle:channel>`
  are offered only when the user picks Beta (`allowedChannels(for:)` reads the setting at every
  check). Sparkle never downgrades when switching back to Stable.
- **Background installs keep Sparkle's install-now handler** (`willInstallUpdateOnQuit`, returning
  `true`): that stalls Sparkle's update cycle until the app relaunches, and Sparkle still installs
  on quit. The menu shows "Restart to Update to X" from `readyToInstallVersion`.
- **Read plists with `plutil -extract … raw`, not `defaults read`**, which can answer from a cache.
- **A pull with an empty `tag` pulls every tag of the repository.** `ImageReference.pullParameters`
  always sends a digest, the tag, or `latest`.
- **Pull errors can come inside a 200 response** (as an `error` message once the pull started);
  `pullImage` turns them into `DockerError.pullFailed`. A cancelled `AsyncThrowingStream` ends without
  an error, so the view model checks for cancellation after the loop.
- **Image tags are not in the Engine API.** The Docker Hub catalog reads them from hub.docker.com;
  other registries have no search (OCI distribution spec) and are typed by name.

## Verifying changes

Agents here have had **no Screen Recording or Apple Events permission**: they cannot open the
menu, click anything, or screenshot the UI. Say what you actually verified and what needs the
user's eyes — never claim a UI behaviour works because the code looks right.

What works headlessly: `make build`, `make test`, `make test-live`, `plutil` on the built
`Info.plist`, `pgrep -x ColimaDesktop`, rendering icons and views to PNG from a test or a
`swiftc`-compiled script, WebKit snapshots of `site/` (`WKWebView.takeSnapshot`), and actionlint
in a throwaway container for the workflows.
