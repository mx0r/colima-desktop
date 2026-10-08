import ColimaDomain
import ColimaTestSupport
import Foundation
import Testing
@testable import ColimaFeatures

@Suite("Quit decision")
struct QuitDecisionTests {
    private func snapshot(_ status: VMStatus) -> AppSnapshot {
        var snapshot = AppSnapshot()
        _ = snapshot.lifecycle.handle(.observed(status))
        return snapshot
    }

    @Test("Asks only while Colima runs, unless an answer is remembered")
    func plan() {
        var settings = AppSettings()
        #expect(QuitDecision.plan(snapshot: snapshot(.stopped), settings: settings) == .quit)
        #expect(QuitDecision.plan(snapshot: snapshot(.running), settings: settings) == .ask)
        settings.rememberedChoices.quit = .leaveRunning
        #expect(QuitDecision.plan(snapshot: snapshot(.running), settings: settings) == .quit)
        settings.rememberedChoices.quit = .stopColima
        #expect(QuitDecision.plan(snapshot: snapshot(.running), settings: settings) == .stopColimaThenQuit)
        #expect(QuitDecision.plan(snapshot: snapshot(.stopped), settings: settings) == .quit)
    }

    @Test("Remembered answers default to none and survive unknown values")
    func remembered() throws {
        let defaults = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(defaults.rememberedChoices.isEmpty)
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"rememberedChoices": {"quit": "explode"}}"#.utf8))
        #expect(odd.rememberedChoices.quit == nil)
        var settings = AppSettings()
        settings.rememberedChoices.quit = .stopColima
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.rememberedChoices.quit == .stopColima)
    }
}

@MainActor
@Suite("Quit flow")
struct QuitFlowTests {
    @Test("Reset Confirmations forgets remembered answers at once")
    func reset() async {
        var settings = AppSettings()
        settings.rememberedChoices.quit = .leaveRunning
        let harness = await StoreHarness(settings: settings).started()
        let sut = SettingsViewModel(store: harness.store, loginItem: FakeLoginItem(), clock: ManualClock())
        #expect(sut.hasRememberedChoices)
        sut.resetConfirmations()
        #expect(!sut.hasRememberedChoices)
        #expect(harness.store.settings.rememberedChoices.isEmpty)
        #expect(harness.settingsStore.saved.rememberedChoices.isEmpty)
    }

    @Test("Stopping for quit waits until the stop has ended")
    func stopAndWait() async {
        let harness = await StoreHarness().started()
        #expect(harness.store.snapshot.lifecycle.observed == .running)
        await harness.store.stopVMAndWait()
        #expect(harness.colima.current.performed.map(\.0) == [.stop])
        #expect(harness.store.snapshot.lifecycle.operation == nil)
    }
}
