import ColimaDomain
import ColimaTestSupport
import Foundation
import Testing
@testable import ColimaFeatures

@Suite("LogRingBuffer")
struct LogRingBufferTests {
    private func line(_ text: String) -> LogLine { LogLine(stream: .stdout, timestamp: nil, text: text) }

    @Test("Keeps the newest entries with contiguous IDs")
    func wraps() {
        var buffer = LogRingBuffer(capacity: 3)
        for index in 0..<5 { buffer.append(line("\(index)")) }
        #expect(buffer.count == 3)
        #expect(buffer.firstID == 2)
        #expect(buffer.entries.map(\.line.text) == ["2", "3", "4"])
        #expect(buffer.entry(id: 1) == nil)
        #expect(buffer.entry(id: 3)?.line.text == "3")
        #expect(buffer.entry(id: 5) == nil)
    }

    @Test("Clearing keeps IDs increasing")
    func clear() {
        var buffer = LogRingBuffer(capacity: 3)
        buffer.append(line("a"))
        buffer.removeAll()
        let entry = buffer.append(line("b"))
        #expect(entry.id == 1)
        #expect(buffer.entry(id: 1)?.line.text == "b")
    }
}

@MainActor
@Suite("LogsViewModel")
struct LogsViewModelTests {
    private let clock = ManualClock()
    private let engine = FakeDockerEngine()

    private func model(capacity: Int = 100) -> LogsViewModel {
        LogsViewModel(
            containerID: "abc",
            containerName: "web",
            engine: engine,
            tailLines: 10,
            capacity: capacity,
            clock: clock,
            now: { Date(timeIntervalSince1970: 1_791_003_600) }
        )
    }

    private func lines(_ texts: String..., stream: LogStream = .stdout) -> [LogLine] {
        texts.map { LogLine(stream: stream, timestamp: Date(timeIntervalSince1970: 1_791_003_600), text: $0) }
    }

    /// Emits lines and fires the flush timer.
    private func emit(_ lines: [LogLine]) async {
        engine.emitLogs(lines)
        await clock.waitForSleepers()
        await clock.advance(by: LogsViewModel.flushInterval)
    }

    /// Fires the filter debounce timer.
    private func applyFilter(_ sut: LogsViewModel, _ text: String) async {
        sut.filterText = text
        await clock.waitForSleepers()
        await clock.advance(by: LogsViewModel.filterDebounce)
    }

    @Test("Lines appear in batches after the flush interval")
    func batching() async {
        let sut = model()
        sut.start()
        await ManualClock.settle()
        #expect(engine.current.logRequests.first?.tail == 10)
        engine.emitLogs(lines("one"))
        engine.emitLogs(lines("two"))
        await clock.waitForSleepers()
        #expect(sut.rowCount == 0)
        await clock.advance(by: LogsViewModel.flushInterval)
        #expect(sut.rowCount == 2)
        #expect(sut.state == .streaming)
        #expect(sut.entry(atRow: 1)?.line.text == "two")
    }

    @Test("Pausing freezes rows and counts new lines; resuming shows them")
    func pause() async {
        let sut = model()
        sut.start()
        await emit(lines("one"))
        sut.isFollowing = false
        await emit(lines("two", "three"))
        #expect(sut.rowCount == 1)
        #expect(sut.newLinesWhilePaused == 2)
        sut.isFollowing = true
        #expect(sut.rowCount == 3)
        #expect(sut.newLinesWhilePaused == 0)
    }

    @Test("Filter matches case-insensitively and keeps markers")
    func filter() async {
        let sut = model()
        sut.start()
        await emit(lines("GET /health", "error: boom", "GET /api"))
        sut.insertMarker()
        await emit(lines("another Error"))
        await applyFilter(sut, "error")
        #expect((0..<sut.rowCount).compactMap { sut.entry(atRow: $0)?.line.text } == ["error: boom", "Marker \(Format.time(Date(timeIntervalSince1970: 1_791_003_600)))", "another Error"])
        await applyFilter(sut, "")
        #expect(sut.rowCount == 5)
    }

    @Test("A full buffer drops the oldest lines")
    func capacity() async {
        let sut = model(capacity: 3)
        sut.start()
        await emit(lines("1", "2", "3", "4", "5"))
        #expect(sut.rowCount == 3)
        #expect(sut.droppedLineCount == 2)
        #expect(sut.entry(atRow: 0)?.line.text == "3")
    }

    @Test("End of stream is reported and reconnect continues after the last line")
    func endAndReconnect() async {
        let sut = model()
        sut.start()
        await emit(lines("one"))
        engine.endLogs()
        #expect(await eventually { sut.state == .ended })

        sut.reconnect()
        await ManualClock.settle()
        let request = engine.current.logRequests.last
        #expect(request?.tail == nil)
        #expect(request?.since != nil)
        #expect(sut.entry(atRow: sut.rowCount - 1)?.line.text == "Reconnected")
    }

    @Test("Stream errors are reported")
    func failure() async {
        let sut = model()
        sut.start()
        await ManualClock.settle()
        engine.endLogs(throwing: DockerError.api(status: 404, message: "No such container"))
        #expect(await eventually { sut.state == .failed("No such container") })
    }

    @Test("Export respects the timestamp toggle and marks stderr")
    func export() async throws {
        let sut = model()
        sut.start()
        await emit(lines("boom", stream: .stderr))
        sut.showsTimestamps = false
        #expect(sut.visibleText() == "[stderr] boom\n")
        sut.showsTimestamps = true
        #expect(sut.visibleText().hasSuffix(" [stderr] boom\n"))
        let first = try #require(sut.entry(atRow: 0))
        #expect(sut.text(forRows: [0]) == sut.format(first))
    }
}

@MainActor
@Suite("TerminalSessionModel")
struct TerminalSessionModelTests {
    private let clock = ManualClock()
    private let engine = FakeDockerEngine()

    @Test("Connects, forwards output and input in order, debounces resizes, reports exit")
    func session() async {
        let sut = TerminalSessionModel(containerID: "abc", containerName: "web", engine: engine, command: ["sh"], clock: clock)
        var output: [UInt8] = []
        sut.onOutput = { output += $0 }
        sut.connect(size: TerminalSize(columns: 80, rows: 24))
        #expect(await eventually { sut.state == .connected })
        #expect(engine.current.execCommands == [["sh"]])

        engine.execSession.emit(Array("$ ".utf8))
        #expect(await eventually { output == Array("$ ".utf8) })

        sut.send([0x6c])
        sut.send([0x73])
        sut.send([0x0d])
        #expect(await eventually { engine.execSession.writes == [[0x6c], [0x73], [0x0d]] })

        sut.resize(TerminalSize(columns: 100, rows: 30))
        sut.resize(TerminalSize(columns: 120, rows: 40))
        await clock.waitForSleepers()
        await clock.advance(by: TerminalSessionModel.resizeDebounce)
        #expect(await eventually { engine.execSession.sizes == [TerminalSize(columns: 120, rows: 40)] })

        engine.execSession.exit(0)
        #expect(await eventually { sut.state == .exited(0) })
    }

    @Test("Exec errors are shown")
    func failure() async {
        final class FailingEngine: DockerEngine, @unchecked Sendable {
            let base = FakeDockerEngine()
            func verifyCompatibility() async throws {}
            func summary() async throws -> EngineSummary { try await base.summary() }
            func diskUsage() async throws -> DiskUsageSummary { try await base.diskUsage() }
            func containers() async throws -> [Container] { [] }
            func inspect(containerID: String) async throws -> ContainerDetails { try await base.inspect(containerID: containerID) }
            func perform(_ action: ContainerAction, containerID: String) async throws {}
            func logs(containerID: String, options: LogOptions) -> AsyncThrowingStream<[LogLine], Error> { base.logs(containerID: containerID, options: options) }
            func events() -> AsyncThrowingStream<DockerEvent, Error> { base.events() }
            func exec(containerID: String, command: [String], size: TerminalSize) async throws -> any ExecSession {
                throw DockerError.api(status: 409, message: "container is not running")
            }
            func searchImages(term: String, limit: Int) async throws -> [ImageSearchResult] { [] }
            func pullImage(_ reference: ImageReference) -> AsyncThrowingStream<PullMessage, Error> { base.pullImage(reference) }
            func createContainer(_ spec: ContainerSpec) async throws -> CreatedContainer { try await base.createContainer(spec) }
        }
        let sut = TerminalSessionModel(containerID: "abc", containerName: "web", engine: FailingEngine(), command: ["sh"], clock: clock)
        sut.connect(size: TerminalSize(columns: 80, rows: 24))
        #expect(await eventually { sut.state == .failed("container is not running") })
    }
}

@MainActor
@Suite("SettingsViewModel")
struct SettingsViewModelTests {
    @Test("Edits are applied after a pause and persisted")
    func debouncedApply() async {
        let harness = await StoreHarness().started()
        let clock = ManualClock()
        let sut = SettingsViewModel(store: harness.store, loginItem: FakeLoginItem(), clock: clock)
        sut.draft.logTailLines = 200
        sut.draft.logTailLines = 300
        await clock.waitForSleepers()
        #expect(harness.store.settings.logTailLines == 1000)
        await clock.advance(by: SettingsViewModel.applyDelay)
        #expect(harness.store.settings.logTailLines == 300)
        #expect(harness.settingsStore.saved.logTailLines == 300)
    }

    @Test("Choosing a menu bar icon style applies at once")
    func iconStyleAppliesImmediately() async {
        let harness = await StoreHarness().started()
        let sut = SettingsViewModel(store: harness.store, loginItem: FakeLoginItem(), clock: ManualClock())
        sut.selectMenuBarIconStyle(.llamaDot)
        #expect(harness.store.settings.menuBarIconStyle == .llamaDot)
        #expect(harness.settingsStore.saved.menuBarIconStyle == .llamaDot)
    }

    @Test("Appearance and text style apply at once, so open windows follow the change")
    func appearanceAppliesImmediately() async {
        let harness = await StoreHarness().started()
        let sut = SettingsViewModel(store: harness.store, loginItem: FakeLoginItem(), clock: ManualClock())
        sut.selectAppearance(.dark, for: .interface)
        sut.selectAppearance(.light, for: .console(.terminal))
        sut.selectAppearance(.system, for: .console(.logs))
        #expect(harness.store.settings.interfaceAppearance == .dark)
        #expect(harness.store.settings.terminalAppearance == .light)
        #expect(harness.store.settings.logsAppearance == .system)

        let style = ConsoleTextStyle(fontFamily: "Menlo", fontSize: 14, lineHeight: 1.2)
        sut.setTextStyle(style, for: .terminal)
        sut.setTextStyle(ConsoleTextStyle(fontFamily: nil, fontSize: 1, lineHeight: 1), for: .logs)
        #expect(harness.store.settings.terminalText == style)
        #expect(harness.store.settings.logsText.fontSize == ConsoleTextStyle.fontSizeRange.lowerBound)
        #expect(harness.settingsStore.saved.terminalText == style)
    }

    @Test("Update settings forward to the updater")
    func updater() async {
        let harness = await StoreHarness().started()
        let updater = FakeUpdater()
        let sut = SettingsViewModel(store: harness.store, loginItem: FakeLoginItem(), updater: updater, clock: ManualClock())
        #expect(sut.hasUpdater)
        #expect(sut.automaticallyChecksForUpdates)
        sut.automaticallyChecksForUpdates = false
        #expect(!updater.automaticallyChecksForUpdates)
        sut.checkForUpdates()
        #expect(updater.checkCount == 1)

        #expect(sut.automaticallyDownloadsUpdates)
        #expect(sut.canChangeAutomaticDownloads)
        sut.automaticallyDownloadsUpdates = false
        #expect(!updater.automaticallyDownloadsUpdates)
        updater.allowsAutomaticUpdates = false
        #expect(!sut.canChangeAutomaticDownloads)

        let without = SettingsViewModel(store: harness.store, loginItem: FakeLoginItem(), clock: ManualClock())
        #expect(!without.hasUpdater)
    }

    @Test("Blank overrides mean auto-detect")
    func blankOverrides() async {
        let harness = await StoreHarness().started()
        let sut = SettingsViewModel(store: harness.store, loginItem: FakeLoginItem(), clock: ManualClock())
        sut.setOptional(\.colimaHomePath, "   ")
        #expect(sut.draft.colimaHomePath == nil)
        sut.setSocketOverride("/x.sock", for: .default)
        #expect(sut.draft.dockerSocketOverrides == ["default": "/x.sock"])
        sut.setSocketOverride("", for: .default)
        #expect(sut.draft.dockerSocketOverrides.isEmpty)
    }

    @Test("The login item hint shows only outside an Applications folder", arguments: [
        ("/Applications/ColimaDesktop.app", false),
        ("/Users/test/Applications/ColimaDesktop.app", false),
        ("/Users/test/Work/colima-desktop/.build/Build/Products/Debug/ColimaDesktop.app", true),
        ("/Applications Old/ColimaDesktop.app", true),
    ])
    func applicationsHint(path: String, showsHint: Bool) async {
        let harness = await StoreHarness().started()
        let sut = SettingsViewModel(
            store: harness.store,
            loginItem: FakeLoginItem(),
            appURL: URL(filePath: path),
            applicationDirectories: [URL(filePath: "/Applications"), URL(filePath: "/Users/test/Applications")],
            clock: ManualClock()
        )
        #expect(sut.isOutsideApplicationsFolder == showsHint)
    }

    @Test("Launch at login toggles and reports errors")
    func loginItem() async {
        struct Denied: LocalizedError { var errorDescription: String? { "Operation not permitted" } }
        let harness = await StoreHarness().started()
        let loginItem = FakeLoginItem()
        let sut = SettingsViewModel(store: harness.store, loginItem: loginItem, clock: ManualClock())
        sut.setLaunchAtLogin(true)
        #expect(sut.loginItemStatus == .enabled)
        loginItem.error = Denied()
        sut.setLaunchAtLogin(false)
        #expect(sut.loginItemError == "Operation not permitted")
        #expect(sut.loginItemStatus == .enabled)
    }
}
