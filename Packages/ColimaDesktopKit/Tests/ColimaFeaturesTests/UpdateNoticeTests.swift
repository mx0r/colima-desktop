import Testing
@testable import ColimaFeatures

@Suite("Update notice")
struct UpdateNoticeTests {
    private let beta = AppVersion(version: "0.8.0-beta.3", build: 44)
    private let stable = AppVersion(version: "0.8", build: 48)

    @Test("A higher build than last time is an update")
    func updated() {
        #expect(UpdateNotice.message(previous: beta, current: stable, launchedBefore: true) == UpdateNotice.Message(
            title: "Colima Desktop updated",
            body: "Version 0.8 is installed (was 0.8.0-beta.3)."
        ))
    }

    @Test("Same build, a downgrade, or the very first launch say nothing")
    func silent() {
        #expect(UpdateNotice.message(previous: stable, current: stable, launchedBefore: true) == nil)
        #expect(UpdateNotice.message(previous: stable, current: beta, launchedBefore: true) == nil)
        #expect(UpdateNotice.message(previous: nil, current: stable, launchedBefore: false) == nil)
    }

    @Test("An earlier launch without a recorded version was an older version")
    func firstVersionThatRecords() {
        #expect(UpdateNotice.message(previous: nil, current: stable, launchedBefore: true) == UpdateNotice.Message(
            title: "Colima Desktop updated",
            body: "Version 0.8 is installed."
        ))
    }
}
