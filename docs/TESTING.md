# Testing

## Automated

```sh
make test         # unit tests
make test-live    # plus live integration tests (COLIMA_DESKTOP_IT=1)
```

Swift Testing, one target per layer:

- **ColimaDomainTests:** lifecycle reducer tables, grouping, ports, path resolution, settings decoding
  (including appearance and console text styles, clamped to their ranges, and image sources), image
  references, search ranking, tag platforms, pull progress, shell-word splitting and container names.
- **ColimaInfrastructureTests:**
  - Process runner, including a >1 MB output deadlock regression, cancellation, timeout and grandchildren.
  - colima output parsing against fixtures captured from a real installation.
  - HTTP framing (whole, byte-by-byte and random splits) and log demuxing.
  - The Docker client against an in-memory transport (requests, errors, streaming logs, exec hijack, events,
    image search, pull streams including errors inside the stream, container create bodies).
  - The Docker Hub catalog against a recorded tag page (platforms, 404, 429, other registries).
  - File watcher and settings store.
- **ColimaFeaturesTests:**
  - `AppStore` with fakes and a `ManualClock`: refresh tiers, debouncing, profile switches, stale-result
    dropping, operations, notifications.
  - Menu model scenarios, including the Ports and Containers submenus.
  - The quit decision, remembered answers and their reset, and stopping Colima before quitting.
  - Shared menu and window content (status, information sections, container facts and commands), the menu
    bar's command state, the main window model (filter, details loading, actions), and live refreshes for
    several viewers.
  - Duration and status formatting; run times read by inspect once per container and state, and again
    after an event.
  - Which copy keeps running when several start (`SingleInstancePolicy`).
  - Logs, terminal and settings view models.
  - The New Container form's validation and its view model (debounced search, tags, pull on 404, always
    pull, start failure, cancel).
- **ColimaUITests:** `MenuRenderer` reconciliation on real `NSMenu` objects (identity is kept, items move and
  are removed), status icons, confirmation texts, console fonts (fallback, row height) and the appearance
  mapping.
- **ColimaIntegrationTests:** only with `COLIMA_DESKTOP_IT=1`. They need the default profile running with
  Docker and read real colima and Docker state. The exec test runs `echo` in the first running container.
  The new-container test searches Docker Hub, reads hello-world's tags, pulls `hello-world`, creates and
  starts a `colima-desktop-it-…` container and removes it.

Fixtures in `Tests/ColimaInfrastructureTests/Fixtures` were captured with colima 0.10.3 and Docker 29.5.2
(API 1.54). Container environment variables were removed. `images-search.json`, `pull-up-to-date.bin` and
`hub-tags-redis.json` are recorded too; `pull-layers.synthetic.ndjson` is written by hand in the engine's
message format, because a real pull of an uncached image varies too much to record.

## Manual checklist

Run the app (`make run`, or `make install` for launch at login) and check:

- [ ] The menu bar icon shows the state in every style (Settings → Menu bar icon). The choice applies at once.
      Check each style in a light and a dark menu bar. The status light style must switch its llama color when
      the menu bar changes between light and dark.
- [ ] Settings → Appearance → Interface Dark, with Terminal and Logs → Appearance on System. The menu,
      Settings, About and the Stop… alert are dark; open logs and terminal windows follow macOS and switch
      when macOS does. Then Terminal Light and Logs Dark: each switches at once and only its own windows,
      the terminal text and background too. Each setting on System follows macOS, including Auto.
- [ ] Upgrading from 0.7.0-beta.2 keeps its "Logs and terminal" appearance for both Terminal and Logs.
- [ ] Settings → Terminal and Logs: font, size and line height change open windows at once. The
      terminal keeps working after a change (the TTY gets the new size). A font that was uninstalled shows
      "(not installed)" and the window uses the system monospaced font.
- [ ] New Container… (menu, while Docker runs): typing "redis" lists Docker Hub results after a pause,
      official first; choosing one fills the image and the tag menu lists recent tags. A tag without an
      image for the VM's architecture is marked, and the form warns.
- [ ] Create with a port, a variable and a volume under the home folder: an image that is not there is
      pulled with progress, then the container appears in the menu and runs (`docker inspect` shows the
      port, variable and bind). Show Logs and Open Terminal work. Cancel during a pull stops it.
- [ ] Invalid fields (empty image, bad name, `70000` as a port, relative container path) show their
      messages only after Create, and nothing is created. A name already in use shows Docker's message.
- [ ] An image from another registry by name (for example `ghcr.io/…`) creates without a tag list.
      Settings → Image sources → Docker Hub off: the window says no source is on, and typing a name still
      works.
- [ ] One copy: with the app running, open it again from Finder, and open another copy (a Debug build, or
      `open -n`). No second icon appears, and the running copy shows its window.
- [ ] Quit (menu or ⌘Q) while Colima runs asks: Quit leaves Colima running; Stop Colima and Quit stops it
      (the icon shows the stop), then quits; Cancel keeps the app. With "Don't ask again", the next quit
      does the same without asking; Settings → General → Reset Confirmations brings the question back.
      With Colima stopped, quit does not ask.
- [ ] Window: no window and no Dock icon after launch. **Open Colima Desktop** (between separators above
      Start) opens it, with a Dock icon; closing it removes the icon. The header shows the status, profile
      and VM buttons; New Container… opens that window.
- [ ] Window: the panes start at two thirds and one third; dragging the divider keeps that ratio when
      the window resizes and on the next open. The list, not the filter field, has the focus on open.
- [ ] Window list: one list in project order, with a project tag; the filter matches name, image and
      project, and Escape clears it. Row buttons: start or stop (one toggle), restart… (with the menu's
      confirmations), show logs, open terminal; disabled ones are dimmed. Right-click has every action. A row expands to facts, ports with Open, command, health, restarts, networks and
      mounts, and Delete… for stopped containers. Durations count up.
- [ ] Window right side: Colima, VM usage, Docker and disk usage, kept fresh while the window is open
      (also with the menu closed).
- [ ] Menu bar (window active): Colima → Start / Stop… / Restart… / Refresh follow the VM state; Container
      → items act on the selected row and follow its state; ⌘L logs, ⌘T terminal, ⌘N New Container…;
      Window → Colima Desktop (⌘0).
- [ ] Durations: a container started a minute ago shows `Up 1m 5s` and counts up while the menu is open;
      exited ones show `Exited (0) 3h 8m ago`; the Created row ends in `(… ago)` in the same style. After
      `docker restart`, the uptime starts again from 0s.
- [ ] A container with several published ports has a **Ports (N)** submenu with copyable rows and Open items;
      a container with one port shows it inline, as before.
- [ ] With seven or more containers, the list sits in a **Containers (x of y running)** submenu; with six or
      fewer it is inline.
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
- [ ] With an older release installed and both update switches on, the background check
      downloads the update silently and the menu shows "Restart to Update to X"; choosing it
      installs and relaunches. Quitting instead installs it, and the next launch is the new version.
- [ ] Update channel: on Stable, a published beta is not offered; switching to Beta offers it at
      the next check (or Check Now); switching back to Stable keeps the beta installed.
- [ ] Settings → Updates: "Download and install updates automatically" is greyed out while
      automatic checks are off; both switches survive a relaunch.
- [ ] Quit closes the app and its windows.
