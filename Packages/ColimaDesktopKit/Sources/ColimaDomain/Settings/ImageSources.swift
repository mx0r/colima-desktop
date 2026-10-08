import Foundation

/// A kind of place the New Container window searches for images.
public enum ImageSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// Docker Hub: search through the engine, tags from hub.docker.com.
    case dockerHub

    /// Name shown in Settings and with search results.
    public var displayName: String {
        switch self {
        case .dockerHub: "Docker Hub"
        }
    }
}

/// One configured image source.
public struct ImageSourceSetting: Codable, Hashable, Sendable {
    public var kind: ImageSourceKind
    public var isEnabled: Bool

    /// Creates a setting.
    public init(kind: ImageSourceKind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }

    /// Every known source, enabled.
    public static let defaults = ImageSourceKind.allCases.map { ImageSourceSetting(kind: $0, isEnabled: true) }

    /// Stored sources with duplicates removed and sources this version knows but the list lacks
    /// appended (enabled), so sources added by an update show up.
    public static func normalized(_ sources: [ImageSourceSetting]) -> [ImageSourceSetting] {
        var seen = Set<ImageSourceKind>()
        var result = sources.filter { seen.insert($0.kind).inserted }
        result += defaults.filter { !seen.contains($0.kind) }
        return result
    }
}

/// Decodes one stored source; a kind from a newer version decodes as nil instead of failing the list.
struct LossyImageSourceSetting: Decodable {
    let value: ImageSourceSetting?

    init(from decoder: Decoder) throws {
        value = try? ImageSourceSetting(from: decoder)
    }
}
