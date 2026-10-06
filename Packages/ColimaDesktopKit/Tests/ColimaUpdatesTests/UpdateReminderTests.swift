import Testing
@testable import ColimaUpdates

@MainActor
@Suite("Update reminders")
struct UpdateReminderTests {
    @Test("Sparkle never shows a scheduled update by itself, even right after launch")
    func neverShowsScheduledUpdates() {
        #expect(!UpdateReminderState.sparkleShowsScheduledUpdate(immediateFocus: true))
        #expect(!UpdateReminderState.sparkleShowsScheduledUpdate(immediateFocus: false))
    }

    @Test("An update Sparkle leaves to us becomes pending; one it shows itself does not")
    func pendingOnlyWhenLeftToUs() {
        var state = UpdateReminderState()
        state.willShowUpdate(version: "0.7", handledBySparkle: true)
        #expect(state.pendingVersion == nil)
        state.willShowUpdate(version: "0.7", handledBySparkle: false)
        #expect(state.pendingVersion == "0.7")
    }

    @Test("Pending clears when the user looks at the update or the session ends", arguments: [true, false])
    func pendingClears(byAttention: Bool) {
        var state = UpdateReminderState()
        state.willShowUpdate(version: "0.7", handledBySparkle: false)
        if byAttention { state.userAttended() } else { state.sessionFinished() }
        #expect(state.pendingVersion == nil)
    }

    @Test("Updates run only when the build enables them")
    func enabledFlag() {
        // Info.plist build-setting substitution yields strings; a literal plist value is a Bool.
        #expect(SparkleUpdater.isEnabled(infoValue: "YES"))
        #expect(SparkleUpdater.isEnabled(infoValue: "yes"))
        #expect(SparkleUpdater.isEnabled(infoValue: true))
        #expect(!SparkleUpdater.isEnabled(infoValue: "NO"))
        #expect(!SparkleUpdater.isEnabled(infoValue: false))
        #expect(!SparkleUpdater.isEnabled(infoValue: nil))
    }
}
