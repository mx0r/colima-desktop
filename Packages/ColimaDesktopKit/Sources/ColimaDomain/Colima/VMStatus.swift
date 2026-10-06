import Foundation

/// Status of a Colima VM as reported by `colima list` (Lima instance status).
public enum VMStatus: Hashable, Sendable {
    case running
    case stopped
    case broken
    case installing
    case uninitialized
    /// A status this app does not know. Kept verbatim instead of guessing.
    case unknown(String)

    /// Maps a status string case-insensitively. Unknown values are preserved.
    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "running": self = .running
        case "stopped": self = .stopped
        case "broken": self = .broken
        case "installing": self = .installing
        case "uninitialized", "": self = .uninitialized
        default: self = .unknown(rawValue)
        }
    }

    /// Human readable status.
    public var displayName: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .broken: "Broken"
        case .installing: "Installing"
        case .uninitialized: "Not created"
        case .unknown(let raw): raw
        }
    }
}
