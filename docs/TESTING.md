# Testing

## Automated

```sh
make test         # unit tests
make test-live    # plus live integration tests (COLIMA_DESKTOP_IT=1)
```

Swift Testing, one target per layer:

- **ColimaDomainTests:** lifecycle reducer tables, grouping, ports, path resolution, settings decoding.
- **ColimaInfrastructureTests:**
  - Process runner, including a >1 MB output deadlock regression, cancellation, timeout and grandchildren.
  - colima output parsing against fixtures captured from a real installation.
  - HTTP framing (whole, byte-by-byte and random splits) and log demuxing.
  - The Docker client against an in-memory transport (requests, errors, streaming logs, exec hijack, events).
  - File watcher and settings store.
- **ColimaFeaturesTests:**
  - `AppStore` with fakes and a `ManualClock`: refresh tiers, debouncing, profile switches, stale-result
    dropping, operations, notifications.
  - Menu model scenarios.
  - Logs, terminal and settings view models.
- **ColimaUITests:** `MenuRenderer` reconciliation on real `NSMenu` objects (identity is kept, items move and
  are removed), status icons and confirmation texts.
- **ColimaIntegrationTests:** only with `COLIMA_DESKTOP_IT=1`. They need the default profile running with
  Docker and read real colima and Docker state. The exec test runs `echo` in the first running container.

Fixtures in `Tests/ColimaInfrastructureTests/Fixtures` were captured with colima 0.10.3 and Docker 29.5.2
(API 1.54). Container environment variables were removed.

## Manual checklist

Run the app (`make run`, or `make install` for launch at login) and check:

- [ ] The menu bar icon shows the state in every style (Settings → Menu bar icon). The choice applies at once.
      Check each style in a light and a dark menu bar. The status light style must switch its llama color when
      the menu bar changes between light and dark.
- [ ] `colima stop` / `colima start` in a shell updates the icon without opening the menu.
- [ ] With the menu open, `docker run --rm -d nginx` in a shell adds the container to the open menu, and an
      open container submenu stays open.
- [ ] Stop… and Restart… ask first. Cancel does nothing.
- [ ] The status row shows progress while starting. The notification arrives when done.
- [ ] The Information submenu shows VM usage and Docker facts within a few seconds. Clicking a row copies the value.
- [ ] Profile switch: containers and information change to the other profile.
- [ ] Logs: follow, pause ("N new lines"), filter with highlighting, timestamps toggle, marker (⌘M),
      copy (⌘⇧C), save (⌘S), clear (⌘K). Scrolling up pauses following.
- [ ] Logs under load: run `yes | head -n 2000000` in a container and check that the window stays responsive.
- [ ] Logs after the container stops: banner with Reconnect.
- [ ] Terminal: `vim` and `htop` render correctly, resizing the window resizes the TTY, `exit` shows the exit
      code, and Reconnect opens a new shell.
- [ ] Open localhost:PORT opens the browser.
- [ ] Delete… is disabled for running containers ("Stop the container first" tooltip). For a stopped container it
      asks first, then the container disappears from the menu.
- [ ] Settings: a wrong colima path shows a warning and the menu shows "Colima not found". Clearing the field
      restores auto-detection.
- [ ] Launch at login: with the app in `/Applications`, enable it, log out and log in.
- [ ] Updates need a Release build (a published DMG or `make release`); Debug builds show no
      "Check for Updates…" and no Updates section in Settings.
- [ ] Check for Updates… (menu and app menu) opens Sparkle's window: "up to date" on the newest
      release; an older installed release offers the newest, installs it and relaunches.
- [ ] With an older release installed and automatic checks on, the menu shows "Update to X…"
      after the background check — also right after launch at login — and no window opens by
      itself.
- [ ] Settings → Updates: the switch survives a relaunch.
- [ ] Quit closes the app and its windows.
