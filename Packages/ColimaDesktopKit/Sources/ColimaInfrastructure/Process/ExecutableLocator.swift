import ColimaDomain
import Foundation

/// Finds executables in PATH and common install locations.
///
/// GUI apps start with a minimal PATH, so Homebrew, MacPorts and Nix locations are searched as well.
public struct ExecutableLocator: ExecutableLocating {
    /// Directories searched after PATH.
    public static let fallbackDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/run/current-system/sw/bin",
        "/usr/bin",
    ]

    private let pathVariable: String
    private let homeDirectory: String
    private let isExecutable: @Sendable (String) -> Bool

    /// Creates a locator.
    ///
    /// - Parameters:
    ///   - pathVariable: The `PATH` value to search first.
    ///   - homeDirectory: Used to expand `~` in overrides and to search `~/.nix-profile/bin`.
    ///   - isExecutable: File check; injectable for tests.
    public init(
        pathVariable: String,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.pathVariable = pathVariable
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
    }

    public func locateColima(override: String?) -> URL? {
        locate("colima", override: override)
    }

    /// Finds a program by name. A non-empty override is used only if it is executable.
    public func locate(_ name: String, override: String?) -> URL? {
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let expanded = expandTilde(override)
            return isExecutable(expanded) ? URL(filePath: expanded) : nil
        }
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return URL(filePath: candidate) }
        }
        return nil
    }

    /// PATH entries followed by fallback directories, without duplicates.
    var searchDirectories: [String] {
        var seen = Set<String>()
        let all = pathVariable.split(separator: ":").map(String.init)
            + Self.fallbackDirectories
            + [(homeDirectory as NSString).appendingPathComponent(".nix-profile/bin")]
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func expandTilde(_ path: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }
}

/// Builds the environment for child processes.
public enum ChildEnvironment {
    /// Copies `base`, prepends the fallback directories (and the executable's own directory) to PATH,
    /// and sets `COLIMA_HOME` / `LIMA_HOME` when overridden.
    public static func make(
        base: [String: String],
        executable: URL?,
        colimaHome: String?,
        limaHome: String?
    ) -> [String: String] {
        var environment = base
        var prefix = ExecutableLocator.fallbackDirectories
        if let executable {
            prefix.insert(executable.deletingLastPathComponent().path(percentEncoded: false), at: 0)
        }
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (prefix + existing)
            .map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        if let colimaHome { environment["COLIMA_HOME"] = colimaHome }
        if let limaHome { environment["LIMA_HOME"] = limaHome }
        return environment
    }
}
