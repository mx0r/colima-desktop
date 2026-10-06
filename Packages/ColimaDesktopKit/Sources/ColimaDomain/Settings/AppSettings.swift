import Foundation

/// User settings. Every override is optional; nil means "auto-detect".
public struct AppSettings: Codable, Hashable, Sendable {
    /// Path to the colima executable; nil to search PATH and Homebrew locations.
    public var colimaExecutablePath: String?
    /// Colima home directory; nil to resolve like colima does (`COLIMA_HOME`, `~/.colima`, …).
    public var colimaHomePath: String?
    /// Lima home directory; nil for `LIMA_HOME` or `<colima home>/_lima`.
    public var limaHomePath: String?
    /// Docker socket path per profile name; profiles without an entry use the socket colima reports.
    public var dockerSocketOverrides: [String: String]
    /// Background refresh interval in seconds while the menu is closed.
    public var heartbeatSeconds: Int
    /// Shell started by the container terminal.
    public var terminalShell: TerminalShell
    /// Number of log lines loaded when a logs window opens.
    public var logTailLines: Int
    /// Maximum number of log lines kept per logs window.
    public var logBufferCapacity: Int
    /// Post user notifications when VM operations finish.
    public var notificationsEnabled: Bool
    /// Profile the menu acts on; nil for `default` (or the first listed profile).
    public var selectedProfile: ProfileName?
    /// Look of the menu bar icon.
    public var menuBarIconStyle: MenuBarIconStyle

    /// Settings with all values auto-detected.
    public static let defaults = AppSettings()

    /// Creates settings; every parameter defaults to auto-detection or the documented default.
    public init(
        colimaExecutablePath: String? = nil,
        colimaHomePath: String? = nil,
        limaHomePath: String? = nil,
        dockerSocketOverrides: [String: String] = [:],
        heartbeatSeconds: Int = 30,
        terminalShell: TerminalShell = .auto,
        logTailLines: Int = 1000,
        logBufferCapacity: Int = 50_000,
        notificationsEnabled: Bool = true,
        selectedProfile: ProfileName? = nil,
        menuBarIconStyle: MenuBarIconStyle = .llamaCubes
    ) {
        self.colimaExecutablePath = colimaExecutablePath
        self.colimaHomePath = colimaHomePath
        self.limaHomePath = limaHomePath
        self.dockerSocketOverrides = dockerSocketOverrides
        self.heartbeatSeconds = heartbeatSeconds
        self.terminalShell = terminalShell
        self.logTailLines = logTailLines
        self.logBufferCapacity = logBufferCapacity
        self.notificationsEnabled = notificationsEnabled
        self.selectedProfile = selectedProfile
        self.menuBarIconStyle = menuBarIconStyle
    }

    // Tolerant decoding: missing keys fall back to defaults so stored settings survive app updates.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        colimaExecutablePath = try c.decodeIfPresent(String.self, forKey: .colimaExecutablePath)
        colimaHomePath = try c.decodeIfPresent(String.self, forKey: .colimaHomePath)
        limaHomePath = try c.decodeIfPresent(String.self, forKey: .limaHomePath)
        dockerSocketOverrides = try c.decodeIfPresent([String: String].self, forKey: .dockerSocketOverrides) ?? d.dockerSocketOverrides
        heartbeatSeconds = try c.decodeIfPresent(Int.self, forKey: .heartbeatSeconds) ?? d.heartbeatSeconds
        terminalShell = try c.decodeIfPresent(TerminalShell.self, forKey: .terminalShell) ?? d.terminalShell
        logTailLines = try c.decodeIfPresent(Int.self, forKey: .logTailLines) ?? d.logTailLines
        logBufferCapacity = try c.decodeIfPresent(Int.self, forKey: .logBufferCapacity) ?? d.logBufferCapacity
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        selectedProfile = try c.decodeIfPresent(ProfileName.self, forKey: .selectedProfile)
        // A style from a newer version falls back to the default instead of failing the whole decode.
        menuBarIconStyle = (try? c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle)) ?? d.menuBarIconStyle
    }

    /// Docker socket override for a profile, if one is set and not blank.
    public func dockerSocketOverride(for profile: ProfileName) -> String? {
        guard let path = dockerSocketOverrides[profile.rawValue]?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            return nil
        }
        return path
    }
}

/// Look of the menu bar icon.
public enum MenuBarIconStyle: String, Codable, CaseIterable, Hashable, Sendable {
    /// Shipping container whose ribs show the state.
    case container
    /// Colima llama whose cubes show the state.
    case llamaCubes
    /// Colima llama carrying a green, amber or red status light.
    case llamaDot
    /// Colima llama carrying a play, pause or stop symbol.
    case llamaSymbols

    /// Name shown in Settings.
    public var displayName: String {
        switch self {
        case .container: "Container"
        case .llamaCubes: "Llama with cubes"
        case .llamaDot: "Llama with status light"
        case .llamaSymbols: "Llama with play, pause and stop"
        }
    }
}

/// Shell the embedded terminal starts in a container.
public enum TerminalShell: Codable, Hashable, Sendable {
    /// bash when available, otherwise sh.
    case auto
    case bash
    case sh
    /// A custom command line, run through `/bin/sh -c`.
    case custom(String)

    /// Command passed to the Engine API exec endpoint.
    public var command: [String] {
        switch self {
        case .auto: ["/bin/sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"]
        case .bash: ["bash"]
        case .sh: ["sh"]
        case .custom(let line): ["/bin/sh", "-c", "exec \(line)"]
        }
    }
}
