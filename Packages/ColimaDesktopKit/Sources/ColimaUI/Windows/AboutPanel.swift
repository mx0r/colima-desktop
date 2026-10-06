import AppKit
import ColimaFeatures

/// The standard About panel with colima and Docker versions in the credits.
public enum AboutPanel {
    /// Project page of this app.
    static let projectURL = URL(string: "https://github.com/mx0r/colima-desktop")!
    /// Project page of colima.
    static let colimaURL = URL(string: "https://github.com/abiosoft/colima")!

    /// Credits text for a snapshot.
    public static func creditsText(for snapshot: AppSnapshot) -> String {
        var lines = ["A menu bar app to control Colima and its containers."]
        var versions: [String] = []
        if let colima = snapshot.colimaVersion { versions.append("colima \(colima)") }
        if let engine = snapshot.engine { versions.append("Docker Engine \(engine.serverVersion)") }
        if !versions.isEmpty { lines.append(versions.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }

    /// Shows the panel.
    public static func show(snapshot: AppSnapshot) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: creditsText(for: snapshot) + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        let linkAttributes: (URL) -> [NSAttributedString.Key: Any] = { url in
            [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .link: url, .paragraphStyle: paragraph]
        }
        credits.append(NSAttributedString(string: "Colima Desktop on GitHub", attributes: linkAttributes(projectURL)))
        credits.append(NSAttributedString(string: " · ", attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: paragraph]))
        credits.append(NSAttributedString(string: "Colima", attributes: linkAttributes(colimaURL)))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
