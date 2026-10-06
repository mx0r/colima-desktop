import Foundation

/// Filesystem locations colima uses, resolved the same way colima does.
public struct ColimaPaths: Hashable, Sendable {
    /// Colima home, e.g. `~/.colima`.
    public var colimaHome: URL
    /// Lima home, e.g. `~/.colima/_lima`.
    public var limaHome: URL

    /// Creates paths from explicit directories.
    public init(colimaHome: URL, limaHome: URL) {
        self.colimaHome = colimaHome
        self.limaHome = limaHome
    }

    /// Resolves the directories.
    ///
    /// Colima home order: settings override, `COLIMA_HOME`, `~/.colima` if it exists,
    /// `$XDG_CONFIG_HOME/colima`, then `~/.colima`. Mirrors `configBaseDir` in colima's `config/files.go`.
    /// Lima home order: settings override, `LIMA_HOME`, `<colima home>/_lima`.
    public static func resolve(
        settings: AppSettings,
        environment: [String: String],
        homeDirectory: URL,
        directoryExists: (URL) -> Bool
    ) -> ColimaPaths {
        let dotColima = homeDirectory.appending(path: ".colima", directoryHint: .isDirectory)
        let colimaHome: URL
        if let override = nonEmpty(settings.colimaHomePath) {
            colimaHome = expand(override, home: homeDirectory)
        } else if let env = nonEmpty(environment["COLIMA_HOME"]) {
            colimaHome = expand(env, home: homeDirectory)
        } else if directoryExists(dotColima) {
            colimaHome = dotColima
        } else if let xdg = nonEmpty(environment["XDG_CONFIG_HOME"]) {
            colimaHome = expand(xdg, home: homeDirectory).appending(path: "colima", directoryHint: .isDirectory)
        } else {
            colimaHome = dotColima
        }

        let limaHome: URL
        if let override = nonEmpty(settings.limaHomePath) {
            limaHome = expand(override, home: homeDirectory)
        } else if let env = nonEmpty(environment["LIMA_HOME"]) {
            limaHome = expand(env, home: homeDirectory)
        } else {
            limaHome = colimaHome.appending(path: "_lima", directoryHint: .isDirectory)
        }
        return ColimaPaths(colimaHome: colimaHome, limaHome: limaHome)
    }

    /// Per-profile directory holding `colima.yaml` and the sockets.
    public func profileDirectory(_ profile: ProfileName) -> URL {
        colimaHome.appending(path: profile.rawValue, directoryHint: .isDirectory)
    }

    /// Lima instance directory holding pid files and logs.
    public func limaInstanceDirectory(_ profile: ProfileName) -> URL {
        limaHome.appending(path: profile.limaInstanceID, directoryHint: .isDirectory)
    }

    /// Docker socket colima creates for a profile.
    public func defaultDockerSocket(_ profile: ProfileName) -> URL {
        profileDirectory(profile).appending(path: "docker.sock", directoryHint: .notDirectory)
    }

    /// Directories whose entries change when the profile's VM starts or stops.
    public func watchedDirectories(for profile: ProfileName) -> [URL] {
        [colimaHome, profileDirectory(profile), limaInstanceDirectory(profile)]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    private static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appending(path: String(path.dropFirst(2)), directoryHint: .isDirectory)
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
