import ColimaDomain
import ColimaTestSupport
import Foundation
import Testing
@testable import ColimaFeatures

@Suite("Durations")
struct DurationFormattingTests {
    @Test("Two units at most, the largest that makes sense", arguments: [
        (0.0, "0s"), (42, "42s"), (59.9, "59s"),
        (60, "1m 0s"), (330, "5m 30s"), (3599, "59m 59s"),
        (3600, "1h 0m"), (11_520, "3h 12m"), (86_399, "23h 59m"),
        (86_400, "1d 0h"), (187_200, "2d 4h"), (-5, "0s"),
    ])
    func duration(seconds: TimeInterval, text: String) {
        #expect(Format.duration(seconds) == text)
    }
}

@Suite("Container status text")
struct ContainerStatusTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func container(_ state: ContainerState, _ status: String, started: TimeInterval? = nil, finished: TimeInterval? = nil) -> Container {
        var container = Sample.container("web", state: state)
        container.statusText = status
        container.startedAt = started.map { now.addingTimeInterval(-$0) }
        container.finishedAt = finished.map { now.addingTimeInterval(-$0) }
        return container
    }

    @Test("Uptime comes from the start time; Docker's suffix is kept")
    func running() {
        #expect(Format.status(of: container(.running, "Up 5 minutes", started: 3725), now: now) == "Up 1h 2m")
        #expect(Format.status(of: container(.running, "Up About a minute (healthy)", started: 75), now: now) == "Up 1m 15s (healthy)")
        #expect(Format.status(of: container(.paused, "Up 2 hours (Paused)", started: 7200), now: now) == "Up 2h 0m (Paused)")
        #expect(Format.status(of: container(.running, "Up Less than a second", started: 0.4), now: now) == "Up 0s")
    }

    @Test("Exit and restart times come from the finish time")
    func finished() {
        #expect(Format.status(of: container(.exited, "Exited (137) 3 hours ago", finished: 10_800), now: now) == "Exited (137) 3h 0m ago")
        #expect(Format.status(of: container(.restarting, "Restarting (1) 5 seconds ago", finished: 5), now: now) == "Restarting (1) 5s ago")
    }

    @Test("Without times, or for other states, Docker's text stays")
    func unchanged() {
        #expect(Format.status(of: container(.running, "Up 5 minutes"), now: now) == "Up 5 minutes")
        #expect(Format.status(of: container(.created, "Created", started: 10), now: now) == "Created")
        #expect(Format.status(of: container(.exited, ""), now: now) == ContainerState.exited.displayName)
    }
}
