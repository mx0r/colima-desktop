import Foundation
import Testing
@testable import ColimaDomain

@Suite("Domain models")
struct DomainModelTests {
    private func container(_ name: String, project: String? = nil, state: ContainerState = .running) -> Container {
        Container(
            id: name + "-id",
            name: name,
            image: "img",
            state: state,
            statusText: "",
            created: Date(timeIntervalSince1970: 0),
            labels: project.map { [Container.composeProjectLabel: $0] } ?? [:]
        )
    }

    @Test("Profile maps to its Lima instance ID")
    func limaInstanceID() {
        #expect(ProfileName.default.limaInstanceID == "colima")
        #expect(ProfileName("work").limaInstanceID == "colima-work")
    }

    @Test("Profiles sort with default first")
    func profileOrdering() {
        let sorted = [ProfileName("zeta"), .default, ProfileName("alpha")].sorted()
        #expect(sorted == [.default, ProfileName("alpha"), ProfileName("zeta")])
    }

    @Test("Unknown VM status is kept verbatim")
    func unknownStatus() {
        #expect(VMStatus(rawValue: "RUNNING") == .running)
        #expect(VMStatus(rawValue: "Paused") == .unknown("Paused"))
    }

    @Test("Containers group by Compose project, standalone last, alive first")
    func grouping() {
        let groups = ContainerGrouping.group([
            container("solo"),
            container("web", project: "shop", state: .exited),
            container("db", project: "shop"),
            container("cache", project: "api"),
        ])
        #expect(groups.map(\.project) == ["api", "shop", nil])
        #expect(groups[1].containers.map(\.name) == ["db", "web"])
        #expect(groups.map(\.id) == ["project:api", "project:shop", "standalone"])
    }

    @Test("Ports are de-duplicated across IPv4 and IPv6 and sorted")
    func portDedup() {
        let ports = PublishedPort.deduplicated([
            PublishedPort(privatePort: 6379, publicPort: 6379, proto: "tcp"),
            PublishedPort(privatePort: 80, publicPort: 8080, proto: "tcp"),
            PublishedPort(privatePort: 6379, publicPort: 6379, proto: "tcp"),
            PublishedPort(privatePort: 4369, publicPort: nil, proto: "tcp"),
        ])
        #expect(ports.map(\.displayText) == ["6379→6379/tcp", "8080→80/tcp", "4369/tcp"])
    }

    @Test("Only published TCP ports are browsable")
    func browsablePorts() {
        #expect(PublishedPort(privatePort: 80, publicPort: 8080, proto: "tcp").browsableURL?.absoluteString == "http://localhost:8080")
        #expect(PublishedPort(privatePort: 53, publicPort: 53, proto: "udp").browsableURL == nil)
        #expect(PublishedPort(privatePort: 80, publicPort: nil, proto: "tcp").browsableURL == nil)
    }

    @Test("Settings decode missing keys as defaults")
    func settingsTolerantDecoding() throws {
        let json = Data(#"{"heartbeatSeconds": 10, "terminalShell": {"bash": {}}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.heartbeatSeconds == 10)
        #expect(settings.terminalShell == .bash)
        #expect(settings.logTailLines == AppSettings.defaults.logTailLines)
        #expect(settings.notificationsEnabled)
    }

    @Test("Menu bar icon style defaults to the llama with cubes and survives unknown values")
    func iconStyleDecoding() throws {
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(missing.menuBarIconStyle == .llamaCubes)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"menuBarIconStyle": "sparkles", "logTailLines": 7}"#.utf8))
        #expect(unknown.menuBarIconStyle == .llamaCubes)
        #expect(unknown.logTailLines == 7)
        let stored = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"menuBarIconStyle": "llamaDot"}"#.utf8))
        #expect(stored.menuBarIconStyle == .llamaDot)
    }

    @Test("Every icon style has a name")
    func iconStyleNames() {
        #expect(MenuBarIconStyle.allCases == [.container, .llamaCubes, .llamaDot, .llamaSymbols])
        #expect(Set(MenuBarIconStyle.allCases.map(\.displayName)).count == 4)
    }

    @Test("Settings round-trip through JSON")
    func settingsRoundTrip() throws {
        let original = AppSettings(colimaHomePath: "~/x", terminalShell: .custom("zsh -l"), selectedProfile: ProfileName("work"), menuBarIconStyle: .llamaSymbols)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test("Blank socket overrides are ignored")
    func blankSocketOverride() {
        let settings = AppSettings(dockerSocketOverrides: ["default": "  ", "work": "/tmp/d.sock"])
        #expect(settings.dockerSocketOverride(for: .default) == nil)
        #expect(settings.dockerSocketOverride(for: ProfileName("work")) == "/tmp/d.sock")
    }
}

@Suite("ColimaPaths")
struct ColimaPathsTests {
    private let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)

    private func resolve(settings: AppSettings = .defaults, env: [String: String] = [:], dotColimaExists: Bool = true) -> ColimaPaths {
        ColimaPaths.resolve(settings: settings, environment: env, homeDirectory: home) { url in
            url.path(percentEncoded: false).hasSuffix("/.colima/") ? dotColimaExists : false
        }
    }

    @Test("Defaults to ~/.colima and its _lima folder")
    func defaults() {
        let paths = resolve()
        #expect(paths.colimaHome.path(percentEncoded: false) == "/Users/test/.colima/")
        #expect(paths.limaHome.path(percentEncoded: false) == "/Users/test/.colima/_lima/")
        #expect(paths.defaultDockerSocket(.default).path(percentEncoded: false) == "/Users/test/.colima/default/docker.sock")
        #expect(paths.limaInstanceDirectory(ProfileName("work")).path(percentEncoded: false) == "/Users/test/.colima/_lima/colima-work/")
    }

    @Test("Settings override wins over the environment, with tilde expansion")
    func settingsOverride() {
        let paths = resolve(settings: AppSettings(colimaHomePath: "~/custom"), env: ["COLIMA_HOME": "/env/colima"])
        #expect(paths.colimaHome.path(percentEncoded: false) == "/Users/test/custom/")
    }

    @Test("COLIMA_HOME wins over ~/.colima")
    func colimaHomeEnv() {
        #expect(resolve(env: ["COLIMA_HOME": "/env/colima"]).colimaHome.path(percentEncoded: false) == "/env/colima/")
    }

    @Test("XDG_CONFIG_HOME is used only when ~/.colima is missing")
    func xdgFallback() {
        let env = ["XDG_CONFIG_HOME": "/xdg"]
        #expect(resolve(env: env, dotColimaExists: true).colimaHome.path(percentEncoded: false) == "/Users/test/.colima/")
        #expect(resolve(env: env, dotColimaExists: false).colimaHome.path(percentEncoded: false) == "/xdg/colima/")
    }

    @Test("LIMA_HOME overrides the lima directory")
    func limaHome() {
        #expect(resolve(env: ["LIMA_HOME": "/lima"]).limaHome.path(percentEncoded: false) == "/lima/")
        #expect(resolve(settings: AppSettings(limaHomePath: "/set"), env: ["LIMA_HOME": "/lima"]).limaHome.path(percentEncoded: false) == "/set/")
    }
}
