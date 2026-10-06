import ColimaDomain
import ServiceManagement
import Testing
@testable import ColimaInfrastructure

/// Scriptable stand-in for `SMAppService.mainApp`.
@MainActor
final class FakeAppService: AppServiceControlling {
    var status: SMAppService.Status
    var registerCalls = 0
    var unregisterCalls = 0

    init(_ status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .notRegistered
    }
}

@MainActor
@Suite("SMAppServiceLoginItem")
struct LoginItemTests {
    @Test("A never-registered app reports notFound; that means off, not unavailable")
    func notFoundMeansOff() {
        // Measured: an ad-hoc signed app that never registered gets .notFound from mainApp.status.
        #expect(SMAppServiceLoginItem.map(.notFound) == .disabled)
        #expect(SMAppServiceLoginItem.map(.notRegistered) == .disabled)
        #expect(SMAppServiceLoginItem.map(.enabled) == .enabled)
        #expect(SMAppServiceLoginItem.map(.requiresApproval) == .requiresApproval)
    }

    @Test("Enabling from notFound registers")
    func enableFromNotFound() throws {
        let service = FakeAppService(.notFound)
        let sut = SMAppServiceLoginItem(service: service)
        try sut.setEnabled(true)
        #expect(service.registerCalls == 1)
        #expect(sut.status == .enabled)
    }

    @Test("Enabling when already enabled does not register again (it would throw)")
    func enableWhenEnabled() throws {
        let service = FakeAppService(.enabled)
        try SMAppServiceLoginItem(service: service).setEnabled(true)
        #expect(service.registerCalls == 0)
    }

    @Test("Disabling unregisters only what is registered", arguments: [
        (SMAppService.Status.enabled, 1),
        (.requiresApproval, 1),
        (.notRegistered, 0),
        (.notFound, 0),
    ])
    func disable(status: SMAppService.Status, expectedCalls: Int) throws {
        let service = FakeAppService(status)
        try SMAppServiceLoginItem(service: service).setEnabled(false)
        #expect(service.unregisterCalls == expectedCalls)
    }
}
