import Foundation

/// A Docker image reference: `[registry/]repository[:tag][@digest]`.
///
/// Follows Docker's reference grammar: lowercase path components, an optional registry host
/// (a first component with a dot or a port, or `localhost`), tags of up to 128 word characters.
public struct ImageReference: Hashable, Sendable, CustomStringConvertible {
    /// Repository including its registry host, e.g. `nginx` or `ghcr.io/owner/app`.
    public var repository: String
    /// Tag, e.g. `1.27-alpine`; nil when none was given.
    public var tag: String?
    /// Content digest, e.g. `sha256:…`; wins over the tag.
    public var digest: String?

    /// Tag Docker assumes when none is given.
    public static let defaultTag = "latest"

    /// Query values of a pull (`POST /images/create`).
    public struct PullParameters: Hashable, Sendable {
        public var fromImage: String
        /// Tag or digest. Never empty: an empty tag makes Docker pull every tag of the repository.
        public var tag: String
    }

    /// Parses a reference; nil for an empty or malformed one.
    public init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }

        var digest: String?
        if let at = rest.firstIndex(of: "@") {
            let value = String(rest[rest.index(after: at)...])
            guard value.wholeMatch(of: #/[a-z0-9]+(?:[.+_-][a-z0-9]+)*:[a-fA-F0-9]{32,}/#) != nil else { return nil }
            digest = value
            rest = String(rest[..<at])
        }

        var tag: String?
        let lastSlash = rest.lastIndex(of: "/")
        if let colon = rest.lastIndex(of: ":"), lastSlash.map({ colon > $0 }) ?? true {
            let value = String(rest[rest.index(after: colon)...])
            guard value.wholeMatch(of: #/[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}/#) != nil else { return nil }
            tag = value
            rest = String(rest[..<colon])
        }

        guard Self.isValidRepository(rest) else { return nil }
        self.repository = rest
        self.tag = tag
        self.digest = digest
    }

    /// Creates a reference from parts that are known to be valid.
    public init(repository: String, tag: String?, digest: String? = nil) {
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// `repository:tag` (with the default tag when none was given) or `repository@digest`.
    public var description: String {
        if let digest { return "\(repository)@\(digest)" }
        return "\(repository):\(tag ?? Self.defaultTag)"
    }

    /// What to send to the engine for a pull.
    public var pullParameters: PullParameters {
        PullParameters(fromImage: repository, tag: digest ?? tag ?? Self.defaultTag)
    }

    /// The same repository with another tag (and no digest).
    public func with(tag: String) -> ImageReference {
        ImageReference(repository: repository, tag: tag)
    }

    /// Namespace and name on Docker Hub (`library` for official images); nil for other registries.
    public var dockerHubRepository: (namespace: String, name: String)? {
        var components = repository.split(separator: "/").map(String.init)
        if let first = components.first, Self.isRegistryHost(first) {
            guard ["docker.io", "index.docker.io", "registry-1.docker.io"].contains(first) else { return nil }
            components.removeFirst()
        }
        switch components.count {
        case 1: return ("library", components[0])
        case 2: return (components[0], components[1])
        default: return nil
        }
    }

    // MARK: Grammar

    /// A first component is a registry host when it has a dot or a port, or is `localhost`.
    static func isRegistryHost(_ component: String) -> Bool {
        component.contains(".") || component.contains(":") || component == "localhost"
    }

    private static func isValidRepository(_ text: String) -> Bool {
        var components = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = components.first, !first.isEmpty else { return false }
        if components.count > 1, isRegistryHost(first) {
            guard first.wholeMatch(of: #/[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]+)?/#) != nil else { return false }
            components.removeFirst()
        }
        return components.allSatisfy { $0.wholeMatch(of: #/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*/#) != nil }
    }
}
