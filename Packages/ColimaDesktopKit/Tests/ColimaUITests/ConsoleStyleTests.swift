import AppKit
import ColimaDomain
import Testing
@testable import ColimaUI

@MainActor
@Suite("Console fonts and appearance")
struct ConsoleStyleTests {
    @Test("System leaves the appearance to macOS; Light and Dark force it")
    func appearanceMapping() {
        #expect(AppearanceMode.system.nsAppearance == nil)
        #expect(AppearanceMode.light.nsAppearance?.name == .aqua)
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }

    @Test("No family means the system monospaced font at the chosen size")
    func systemFont() {
        let font = ConsoleFonts.font(for: ConsoleTextStyle(fontFamily: nil, fontSize: 14, lineHeight: 1))
        #expect(font == NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
    }

    @Test("An installed family is used; a missing one falls back to the system font")
    func familyFont() {
        let menlo = ConsoleFonts.font(for: ConsoleTextStyle(fontFamily: "Menlo", fontSize: 12, lineHeight: 1))
        #expect(menlo.familyName == "Menlo")
        #expect(menlo.pointSize == 12)
        let missing = ConsoleFonts.font(for: ConsoleTextStyle(fontFamily: "No Such Font 4711", fontSize: 12, lineHeight: 1))
        #expect(missing == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        #expect(!ConsoleFonts.isInstalled("No Such Font 4711"))
    }

    @Test("The font list holds installed fixed-pitch families only")
    func families() {
        let families = ConsoleFonts.monospacedFamilies()
        #expect(families.contains("Menlo"))
        #expect(!families.contains("Helvetica"))
        #expect(families == families.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test("Default logs rows keep their height; line height scales them")
    func logRowHeight() {
        #expect(ConsoleFonts.logRowHeight(for: .logsDefault) == 16)
        var taller = ConsoleTextStyle.logsDefault
        taller.lineHeight = 1.5
        #expect(ConsoleFonts.logRowHeight(for: taller) > 16)
        var bigger = ConsoleTextStyle.logsDefault
        bigger.fontSize = 16
        #expect(ConsoleFonts.logRowHeight(for: bigger) > 16)
    }

    @Test("Marker rows use a bolder face of the same font")
    func markerFont() {
        let style = ConsoleTextStyle(fontFamily: "Menlo", fontSize: 12, lineHeight: 1)
        let bold = ConsoleFonts.emphasizedFont(for: style)
        #expect(bold.familyName == "Menlo")
        #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    }
}
