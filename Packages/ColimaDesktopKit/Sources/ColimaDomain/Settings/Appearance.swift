import Foundation

/// Light or dark look of a group of windows.
public enum AppearanceMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Follow the macOS setting, including Auto.
    case system
    case light
    case dark

    /// Name shown in Settings.
    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Group of windows that shares one appearance setting.
public enum WindowRole: Hashable, Sendable {
    /// Menus, settings, About, alerts and update dialogs.
    case interface
    /// Terminal or logs windows.
    case console(ConsoleKind)
}

/// Window that shows container output in a text style of its own.
public enum ConsoleKind: Hashable, Sendable {
    case terminal
    case logs
}

/// Font and spacing of a logs or terminal window.
public struct ConsoleTextStyle: Codable, Hashable, Sendable {
    /// Font family name; nil for the system monospaced font (SF Mono).
    public var fontFamily: String?
    /// Font size in points.
    public var fontSize: Double
    /// Line height as a multiple of the font's own line height.
    public var lineHeight: Double

    /// Allowed font sizes.
    public static let fontSizeRange: ClosedRange<Double> = 8...32
    /// Allowed line heights.
    public static let lineHeightRange: ClosedRange<Double> = 0.8...2.0
    /// Default style of the terminal.
    public static let terminalDefault = ConsoleTextStyle(fontFamily: nil, fontSize: 13, lineHeight: 1.0)
    /// Default style of the logs.
    public static let logsDefault = ConsoleTextStyle(fontFamily: nil, fontSize: 11, lineHeight: 1.0)

    /// Creates a style; values are not clamped (see `clamped()`).
    public init(fontFamily: String?, fontSize: Double, lineHeight: Double) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }

    /// The style with sizes inside their ranges and a blank family turned into the system font.
    public func clamped() -> ConsoleTextStyle {
        let family = fontFamily?.trimmingCharacters(in: .whitespaces)
        return ConsoleTextStyle(
            fontFamily: family?.isEmpty == false ? family : nil,
            fontSize: min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound),
            lineHeight: min(max(lineHeight, Self.lineHeightRange.lowerBound), Self.lineHeightRange.upperBound)
        )
    }

    // Tolerant decoding: a missing or broken value takes the terminal default; the result is clamped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.terminalDefault
        self = ConsoleTextStyle(
            fontFamily: try? c.decodeIfPresent(String.self, forKey: .fontFamily),
            fontSize: (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize,
            lineHeight: (try? c.decodeIfPresent(Double.self, forKey: .lineHeight)) ?? d.lineHeight
        ).clamped()
    }
}

extension AppSettings {
    /// Appearance setting of a group of windows.
    public func appearance(for role: WindowRole) -> AppearanceMode {
        switch role {
        case .interface: interfaceAppearance
        case .console(.terminal): terminalAppearance
        case .console(.logs): logsAppearance
        }
    }

    /// Text style of the terminal or the logs.
    public func textStyle(for console: ConsoleKind) -> ConsoleTextStyle {
        switch console {
        case .terminal: terminalText
        case .logs: logsText
        }
    }

    /// Sets the text style of the terminal or the logs, clamped to the allowed ranges.
    public mutating func setTextStyle(_ style: ConsoleTextStyle, for console: ConsoleKind) {
        switch console {
        case .terminal: terminalText = style.clamped()
        case .logs: logsText = style.clamped()
        }
    }
}
