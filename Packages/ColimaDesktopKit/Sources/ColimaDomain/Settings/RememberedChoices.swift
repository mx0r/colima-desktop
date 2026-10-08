import Foundation

/// What to do with Colima when the app quits while it runs.
public enum QuitChoice: String, Codable, CaseIterable, Hashable, Sendable {
    /// Quit the app only; Colima and its containers keep running.
    case leaveRunning
    /// Stop Colima, then quit.
    case stopColima
}

/// Answers the user asked to remember ("Don't ask again") instead of seeing a confirmation again.
/// Settings → Reset Confirmations clears them all.
public struct RememberedChoices: Codable, Hashable, Sendable {
    /// Answer to the quit confirmation.
    public var quit: QuitChoice?

    /// Creates remembered choices; none by default.
    public init(quit: QuitChoice? = nil) {
        self.quit = quit
    }

    /// Whether nothing is remembered.
    public var isEmpty: Bool { quit == nil }

    // An unknown value (from a newer version) is forgotten instead of failing the decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quit = try? c.decodeIfPresent(QuitChoice.self, forKey: .quit)
    }
}
