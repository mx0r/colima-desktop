import Foundation

/// Name of a Colima profile (one VM instance), e.g. `default` or `work`.
public struct ProfileName: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// The raw profile name as Colima prints it.
    public let rawValue: String

    /// The profile Colima uses when no `--profile` flag is given.
    public static let `default` = ProfileName("default")

    /// Creates a profile name.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Lima instance ID backing this profile (`colima` for `default`, `colima-<name>` otherwise).
    public var limaInstanceID: String {
        rawValue == Self.default.rawValue ? "colima" : "colima-\(rawValue)"
    }

    public var description: String { rawValue }

    public static func < (lhs: ProfileName, rhs: ProfileName) -> Bool {
        // `default` first, the rest alphabetically.
        if lhs == .default { return rhs != .default }
        if rhs == .default { return false }
        return lhs.rawValue.localizedStandardCompare(rhs.rawValue) == .orderedAscending
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
