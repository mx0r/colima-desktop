# Architecture

## Layout

```
project.yml                      XcodeGen spec: thin app target + local package
App/                             main.swift, Info.plist, entitlements, assets
Packages/ColimaDesktopKit/
  Sources/
    ColimaDomain/                models, VMLifecycle reducer, ports (protocols), errors; Foundation only
    ColimaInfrastructure/        process runner, colima CLI client, unix-socket HTTP, Docker Engine client,
                                 file watcher, settings store, login item, notifications
    ColimaFeatures/              AppStore, menu model builder, logs/terminal/settings view models
    ColimaUI/                    NSStatusItem, NSMenu renderer, windows, SwiftUI views
    ColimaTerminal/              SwiftTerm bridge (isolates the dependency; uses ColimaUI for console fonts)
    ColimaUpdates/               Sparkle updater (isolates the dependency)
    ColimaAppShell/              composition root: live dependencies, action router, app delegate
    ColimaTestSupport/           fakes and ManualClock for tests
  Tests/                         one test target per layer, plus live integration tests
```

## Dependency rule

```
ColimaAppShell ──► ColimaUI ──► ColimaFeatures ──► ColimaDomain
       │         ColimaTerminal ─┘  (also ► ColimaUI)  ▲
       ├──────► ColimaUpdates ─────────────────────────┤
       └──────► ColimaInfrastructure ──────────────────┘
```

Features and UI never import Infrastructure. Only `ColimaAppShell` knows the concrete adapters. The package
manifest enforces this: a forbidden import does not compile.

## Concurrency

- Swift 6 language mode, strict concurrency.
- `ColimaUI`, `ColimaTerminal` and `ColimaAppShell` use `defaultIsolation(MainActor.self)`.
- Stores and view models are `@MainActor @Observable`.
- Adapters are `Sendable` and run their work off the main actor: process pipes, `NWConnection` callbacks,
  stream decoding in detached tasks.
- The menu renders from `Observations { store.snapshot }`. MainActor tasks run while an `NSMenu` is tracking,
  so the open menu updates live.
- Confirmation alerts run synchronously in the `@objc` menu action, never inside a task (a modal inside a
  main-queue job would stall all MainActor work).

## State and refresh

`AppStore` holds one immutable `AppSnapshot`. `MenuModelBuilder` turns it into a `[MenuNode]` tree, and
`MenuRenderer` reconciles that tree into `NSMenu` items by ID. Items and submenus are updated in place, so an
open submenu stays open.

`VMLifecycle` is a pure reducer `(state, event) -> effects` for start/stop/restart. It decides which actions are
allowed and what the icon shows. Unknown statuses are never treated as "stopped".

| Tier | Work | When |
|---|---|---|
| T0 | `colima list --json`, `GET /containers/json?all=1` | heartbeat (30 s by default), every 2 s while the menu is open, 250 ms after file changes in the colima/lima directories, 200 ms after Docker events, every 1 s during own VM operations |
| T1 | `colima status --json`, Docker connect and version check | VM became running, profile switch, settings change |
| T2 | VM usage over `colima ssh`, `/info`, `/version`, `/system/df` | only while the Information submenu is open (every 3 s) |

Each tier is single-flight: concurrent requests coalesce into one re-run. A generation counter drops results
that started before a profile switch or a settings change.

## Processes

`FoundationProcessRunner` runs programs without a shell. It drains both pipes while the process runs, so large
output cannot deadlock it. It terminates the process on cancellation and timeout. It stops waiting for EOF
2 s after exit, because daemonized grandchildren (lima host agents) may keep the pipe open.

GUI apps start with a minimal `PATH`. The child `PATH` gets the colima directory and the usual install
locations prepended.

## Container durations

`GET /containers/json` has no start or finish time, only Docker's rounded text ("Up 2 hours"). `AppStore`
inspects each container once for `StartedAt` and `FinishedAt` and caches them with the state it saw; it
inspects again when the state changes or a Docker event names the container (a restart keeps "running"). A
failed inspect is cached as unknown, and Docker's text is shown then. `Format.status(of:now:)` swaps Docker's
duration for an exact one, keeping its prefix and suffix ("Exited (0) … ago", "(healthy)"). While the menu is
open, `StatusItemController` rebuilds it every second so the durations count up.

## Launch

`ColimaDesktopApplication.run()` first checks for another running copy with the same bundle ID
(`NSRunningApplication`). `SingleInstancePolicy` keeps the oldest copy: a newer one posts a distributed
notification and returns before `NSApplication.run()`, so it never shows an icon. The running copy opens its
main window when it gets the notification, and on a reopen (Finder, Spotlight) while no window is open. No
window opens at a normal launch.

## Main window

`MainWindowView` / `MainWindowModel` show what the menu shows. Both read shared, pure builders in
`ColimaFeatures/Overview/SharedContent.swift`, so they cannot disagree:

- `StatusSummary` (the status line), `InformationSections` (the Information submenu and the window's right
  side), `ContainerFacts` (a container's first facts), `ContainerCommands` (what a container allows now),
  `ContainerListState` (why there is no list).
- `MainMenuState` maps the menu bar's commands (Colima and Container menus) to `MenuAction`s or nil
  (disabled); Container commands act on the window's selected container.

Actions from the window go through `ActionRouter.handle`, so confirmations are the same as in the menu. The
store refreshes for every visible viewer (`LiveViewer.menu`, `.mainWindow`): live refreshes while either is
open, VM usage and engine facts while the Information submenu or the window is open. An expanded container
reads its inspect details, again when its state or start time changes. Durations in the window count up
with a one-second `TimelineView`.

## Windows

`WindowManager` hosts SwiftUI views in `NSWindow`s and remembers frames per window kind. While any window is
open, the app switches to the `.regular` activation policy (Dock icon, ⌘-Tab). It goes back to `.accessory`
when the last window closes.

**Appearance.** Three settings: the interface, terminal windows and logs windows. Each is System, Light or
Dark. `NSApp.appearance` is never set, so System always means the macOS setting, also while another group is
forced. `WindowManager` gives each window the appearance of its role:

- terminal and logs windows, opened with `role: .console(.terminal)` or `.console(.logs)`, and their sheets
  get that setting;
- every other window gets the interface setting: Settings, and windows it does not create (About, alerts,
  Sparkle) when they become key;
- the status menu and its submenus, and the confirmation alerts, set the interface appearance themselves.

The terminal and the logs each have a text style: font family (nil for the system monospaced font), size and
line height. The views read it from the settings during `body`, so open windows follow a change. SwiftTerm's
`lineSpacing` takes the line height; log rows are the font's line height times it, plus padding.

- **Logs:** a bounded ring buffer (50 000 lines by default) and a virtualized `NSTableView`. The UI updates are
  batched every 100 ms.
- **Terminal:** SwiftTerm `TerminalView` fed by a Docker exec session. Input is serialized through an
  `AsyncStream`, and resizes are debounced.
- **New Container:** `NewContainerViewModel` searches every enabled `ImageCatalog` after a pause in typing,
  loads the tags of the chosen image, and validates `ContainerForm` into a `ContainerSpec`. Creating runs
  create → (404: pull, create again) → start, with the pull's `PullProgress` in the window; Cancel stops the
  pull. Image sources are a setting (`imageSources`); `ActionRouter` builds a catalog per enabled kind. The
  only kind is Docker Hub (`DockerHubCatalog`: search through the engine's `ImageSearching`, tags over HTTPS
  from hub.docker.com). A new registry is a new `ImageSourceKind` and an `ImageCatalog` implementation.
