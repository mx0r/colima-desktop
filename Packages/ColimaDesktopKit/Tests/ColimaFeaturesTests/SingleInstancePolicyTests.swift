import Foundation
import Testing
@testable import ColimaFeatures

@Suite("SingleInstancePolicy")
struct SingleInstancePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func instance(_ pid: Int32, _ secondsAgo: TimeInterval?) -> SingleInstancePolicy.Instance {
        SingleInstancePolicy.Instance(processID: pid, launchDate: secondsAgo.map { now.addingTimeInterval(-$0) })
    }

    @Test("Alone, the app keeps running")
    func alone() {
        #expect(!SingleInstancePolicy.shouldQuit(instance(10, 1), others: [], now: now))
    }

    @Test("A copy that started earlier wins")
    func olderRuns() {
        #expect(SingleInstancePolicy.shouldQuit(instance(20, 1), others: [instance(10, 3600)], now: now))
    }

    @Test("A copy that started later yields, so two simultaneous launches leave one")
    func newerStarts() {
        #expect(!SingleInstancePolicy.shouldQuit(instance(10, 5), others: [instance(20, 1)], now: now))
    }

    @Test("Same launch time: the lower process ID wins")
    func tie() {
        #expect(SingleInstancePolicy.shouldQuit(instance(20, 1), others: [instance(10, 1)], now: now))
        #expect(!SingleInstancePolicy.shouldQuit(instance(10, 1), others: [instance(20, 1)], now: now))
    }

    @Test("A running copy without a launch date counts as older; this one without a date counts as starting now")
    func unknownDates() {
        #expect(SingleInstancePolicy.shouldQuit(instance(20, 1), others: [instance(10, nil)], now: now))
        #expect(SingleInstancePolicy.shouldQuit(instance(20, nil), others: [instance(10, 60)], now: now))
    }
}
