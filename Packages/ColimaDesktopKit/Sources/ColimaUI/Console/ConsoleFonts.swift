import AppKit
import ColimaDomain

/// Fonts and metrics for logs and terminal windows.
public enum ConsoleFonts {
    /// Space above and below a log line at line height 1.0, in points.
    static let logRowPadding: CGFloat = 3

    /// Font for a style: the chosen family, or the system monospaced font when none is set or it is not installed.
    public static func font(for style: ConsoleTextStyle) -> NSFont {
        let size = CGFloat(style.fontSize)
        if let family = style.fontFamily,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Bolder face of the style's font, for marker lines.
    public static func emphasizedFont(for style: ConsoleTextStyle) -> NSFont {
        let regular = font(for: style)
        if style.fontFamily == nil || regular.familyName != style.fontFamily {
            return NSFont.monospacedSystemFont(ofSize: regular.pointSize, weight: .semibold)
        }
        return NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
    }

    /// Whether a font family is installed.
    public static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }

    /// Installed fixed-pitch font families, sorted by name. The system monospaced font is not listed;
    /// it is the default (no family).
    public static func monospacedFamilies() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }.filter { !$0.hasPrefix(".") })
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Height of one log row: the font's line height times the style's line height, plus padding.
    public static func logRowHeight(for style: ConsoleTextStyle) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font(for: style))
        return (lineHeight * CGFloat(style.lineHeight)).rounded(.up) + logRowPadding
    }
}

extension AppearanceMode {
    /// AppKit appearance for this mode; nil inherits it, which follows macOS.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
