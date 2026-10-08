import Foundation

/// One repository found by an image search.
public struct ImageSearchResult: Hashable, Sendable, Identifiable {
    /// Repository name, e.g. `redis` or `bitnami/redis`.
    public var name: String
    public var description: String
    public var starCount: Int
    /// Docker Official Image.
    public var isOfficial: Bool

    public var id: String { name }

    /// Creates a result.
    public init(name: String, description: String, starCount: Int, isOfficial: Bool) {
        self.name = name
        self.description = description
        self.starCount = starCount
        self.isOfficial = isOfficial
    }

    /// Results in display order: an exact name match first, then official images, then by stars.
    /// The engine returns them in no useful order.
    public static func ranked(_ results: [ImageSearchResult], for term: String) -> [ImageSearchResult] {
        let wanted = term.trimmingCharacters(in: .whitespaces).lowercased()
        func isExact(_ result: ImageSearchResult) -> Bool {
            result.name == wanted || result.name == "library/\(wanted)"
        }
        return results.sorted { lhs, rhs in
            if isExact(lhs) != isExact(rhs) { return isExact(lhs) }
            if lhs.isOfficial != rhs.isOfficial { return lhs.isOfficial }
            if lhs.starCount != rhs.starCount { return lhs.starCount > rhs.starCount }
            return lhs.name < rhs.name
        }
    }
}

/// Operating system and CPU an image runs on.
public struct ImagePlatform: Hashable, Sendable {
    public var os: String
    /// Docker's name, e.g. `arm64` or `amd64`.
    public var architecture: String
    public var variant: String?

    /// Creates a platform.
    public init(os: String, architecture: String, variant: String?) {
        self.os = os
        self.architecture = architecture
        self.variant = variant
    }

    /// Docker's architecture name for a VM architecture as colima reports it (`aarch64`, `x86_64`).
    public static func dockerArchitecture(forVM architecture: String) -> String {
        switch architecture {
        case "aarch64", "arm64": "arm64"
        case "x86_64", "amd64": "amd64"
        default: architecture
        }
    }
}

/// One tag of a repository.
public struct ImageTag: Hashable, Sendable, Identifiable {
    public var name: String
    public var lastUpdated: Date?
    /// Platforms the tag has images for; empty when the source does not say.
    public var platforms: [ImagePlatform]

    public var id: String { name }

    /// Creates a tag.
    public init(name: String, lastUpdated: Date?, platforms: [ImagePlatform]) {
        self.name = name
        self.lastUpdated = lastUpdated
        self.platforms = platforms
    }

    /// Whether the tag has a Linux image for a VM architecture; nil when its platforms are unknown.
    public func supports(vmArchitecture: String) -> Bool? {
        guard !platforms.isEmpty else { return nil }
        let wanted = ImagePlatform.dockerArchitecture(forVM: vmArchitecture)
        return platforms.contains { $0.os == "linux" && $0.architecture == wanted }
    }
}

/// A place to find images: searches repositories and lists their tags.
public protocol ImageCatalog: Sendable {
    /// Name shown with the results, e.g. "Docker Hub".
    var name: String { get }

    /// Repositories matching a search term.
    func search(_ term: String, limit: Int) async throws -> [ImageSearchResult]

    /// Recent tags of a repository; nil when the reference belongs to another registry.
    func tags(of reference: ImageReference) async throws -> [ImageTag]?
}
