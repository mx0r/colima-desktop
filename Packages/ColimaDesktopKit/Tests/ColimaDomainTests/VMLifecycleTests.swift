import Testing
@testable import ColimaDomain

@Suite("VMLifecycle")
struct VMLifecycleTests {
    private func lifecycle(_ status: VMStatus?) -> VMLifecycle {
        var lifecycle = VMLifecycle()
        if let status { _ = lifecycle.handle(.observed(status)) }
        return lifecycle
    }

    @Test("Initial state is unknown and allows nothing")
    func initialState() {
        let sut = VMLifecycle()
        #expect(sut.phase == .loading)
        #expect(sut.iconState == .unknown)
        #expect(!sut.canStart && !sut.canStop && !sut.canRestart)
    }

    @Test("Allowed actions follow the observed status", arguments: [
        (VMStatus.running, false, true, true),
        (VMStatus.stopped, true, false, false),
        (VMStatus.uninitialized, true, false, false),
        (VMStatus.broken, true, true, false),
        (VMStatus.installing, false, false, false),
        (VMStatus.unknown("Weird"), false, true, false),
    ])
    func allowedActions(status: VMStatus, start: Bool, stop: Bool, restart: Bool) {
        let sut = lifecycle(status)
        #expect(sut.canStart == start)
        #expect(sut.canStop == stop)
        #expect(sut.canRestart == restart)
    }

    @Test("Icon follows the observed status", arguments: [
        (VMStatus.running, IconState.running),
        (VMStatus.stopped, IconState.stopped),
        (VMStatus.uninitialized, IconState.stopped),
        (VMStatus.broken, IconState.error),
        (VMStatus.installing, IconState.transitioning),
        (VMStatus.unknown("Weird"), IconState.unknown),
    ])
    func iconState(status: VMStatus, icon: IconState) {
        #expect(lifecycle(status).iconState == icon)
    }

    @Test("Allowed request performs the operation and shows a transition")
    func requestPerforms() {
        var sut = lifecycle(.stopped)
        let effects = sut.handle(.requested(.start))
        #expect(effects == [.perform(.start)])
        #expect(sut.phase == .operating(.start))
        #expect(sut.iconState == .transitioning)
        #expect(!sut.canStart && !sut.canStop && !sut.canRestart)
    }

    @Test("Disallowed request is ignored")
    func disallowedRequestIgnored() {
        var sut = lifecycle(.running)
        let before = sut
        #expect(sut.handle(.requested(.start)).isEmpty)
        #expect(sut == before)
    }

    @Test("Second request while an operation runs is ignored")
    func requestDuringOperationIgnored() {
        var sut = lifecycle(.running)
        _ = sut.handle(.requested(.stop))
        #expect(sut.handle(.requested(.restart)).isEmpty)
        #expect(sut.operation == .stop)
    }

    @Test("Observations during an operation keep the transition")
    func observationDuringOperation() {
        var sut = lifecycle(.stopped)
        _ = sut.handle(.requested(.start))
        _ = sut.handle(.observed(.running))
        #expect(sut.phase == .operating(.start))
        #expect(sut.iconState == .transitioning)
    }

    @Test("Finished operation notifies and refreshes")
    func finished() {
        var sut = lifecycle(.stopped)
        _ = sut.handle(.requested(.start))
        let effects = sut.handle(.finished(.start))
        #expect(effects == [.notifySucceeded(.start), .refresh])
        #expect(sut.operation == nil)
    }

    @Test("Failed operation shows an error until a new request")
    func failedThenRetry() {
        var sut = lifecycle(.stopped)
        _ = sut.handle(.requested(.start))
        let effects = sut.handle(.failed(.start, "boom"))
        #expect(effects == [.notifyFailed(.start, "boom"), .refresh])
        #expect(sut.phase == .failed(.start, "boom"))
        #expect(sut.iconState == .error)
        #expect(sut.canStart)

        _ = sut.handle(.requested(.start))
        #expect(sut.failure == nil)
    }

    @Test("Failure clears when the goal is reached by other means")
    func failureClearsOnGoalReached() {
        var sut = lifecycle(.stopped)
        _ = sut.handle(.requested(.start))
        _ = sut.handle(.failed(.start, "boom"))
        _ = sut.handle(.observed(.stopped))
        #expect(sut.failure != nil)
        _ = sut.handle(.observed(.running))
        #expect(sut.failure == nil)
        #expect(sut.iconState == .running)
    }

    @Test("Missing colima disables everything and shows an error")
    func colimaMissing() {
        var sut = lifecycle(.stopped)
        _ = sut.handle(.colimaMissing)
        #expect(sut.phase == .colimaMissing)
        #expect(sut.iconState == .error)
        #expect(!sut.canStart)

        _ = sut.handle(.observed(.stopped))
        #expect(sut.canStart)
    }
}
