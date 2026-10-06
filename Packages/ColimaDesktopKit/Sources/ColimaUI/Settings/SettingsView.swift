import ColimaDomain
import ColimaFeatures
import SwiftUI

/// Settings window. Every field is optional; placeholders show the auto-detected value.
public struct SettingsView: View {
    @Bindable private var model: SettingsViewModel

    /// Creates the view.
    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            iconSection
            colimaSection
            socketSection
            generalSection
            terminalSection
            logsSection
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .onDisappear { model.applyNow() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItemStatus()
        }
    }

    // MARK: Sections

    private var colimaSection: some View {
        Section {
            pathField(
                "colima executable",
                keyPath: \.colimaExecutablePath,
                placeholder: model.detected.autoColimaExecutable ?? "Not found"
            )
            if let warning = model.colimaPathWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            pathField("Colima home (COLIMA_HOME)", keyPath: \.colimaHomePath, placeholder: autoPath(\.colimaHomePath, model.detected.paths.colimaHome))
            pathField("Lima home (LIMA_HOME)", keyPath: \.limaHomePath, placeholder: autoPath(\.limaHomePath, model.detected.paths.limaHome))
        } header: {
            Text("Colima")
        } footer: {
            Text("Leave empty to detect automatically. Apps started from Finder do not see variables from your shell profile.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var iconSection: some View {
        Section {
            ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                IconStyleRow(style: style, isSelected: model.draft.menuBarIconStyle == style) {
                    model.selectMenuBarIconStyle(style)
                }
            }
        } header: {
            Text("Menu bar icon")
        } footer: {
            Text("Running, changing, stopped, error.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var socketSection: some View {
        Section {
            ForEach(model.profiles, id: \.self) { profile in
                TextField(
                    profile.rawValue,
                    text: Binding(
                        get: { model.draft.dockerSocketOverrides[profile.rawValue] ?? "" },
                        set: { model.setSocketOverride($0, for: profile) }
                    ),
                    prompt: Text(model.detectedSocket(for: profile))
                )
                .textContentType(.none)
                .autocorrectionDisabled()
            }
        } header: {
            Text("Docker socket per profile")
        } footer: {
            Text("Leave empty to use the socket colima reports.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(
                get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
                set: { model.setLaunchAtLogin($0) }
            ))
            if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
                Text("macOS registers this copy of the app. Turn this on from the copy in Applications, so the login item keeps working after updates.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.loginItemStatus == .requiresApproval {
                HStack {
                    Text("Allow Colima Desktop in System Settings → Login Items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { model.openLoginItemSettings() }
                }
            }
            if let error = model.loginItemError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Toggle("Notify when Colima starts, stops or fails", isOn: $model.draft.notificationsEnabled)
            Picker("Background refresh", selection: $model.draft.heartbeatSeconds) {
                Text("Every 10 seconds").tag(10)
                Text("Every 30 seconds").tag(30)
                Text("Every minute").tag(60)
                Text("Every 5 minutes").tag(300)
            }
        }
    }

    private var terminalSection: some View {
        Section("Terminal") {
            Picker("Shell", selection: shellKind) {
                Text("Automatic (bash, else sh)").tag(ShellKind.auto)
                Text("bash").tag(ShellKind.bash)
                Text("sh").tag(ShellKind.sh)
                Text("Custom").tag(ShellKind.custom)
            }
            if case .custom(let command) = model.draft.terminalShell {
                TextField("Command", text: Binding(
                    get: { command },
                    set: { model.draft.terminalShell = .custom($0) }
                ), prompt: Text("e.g. zsh -l"))
                .autocorrectionDisabled()
            }
        }
    }

    private var logsSection: some View {
        Section("Logs") {
            Picker("Initial lines", selection: $model.draft.logTailLines) {
                ForEach([100, 500, 1000, 5000, 10000], id: \.self) { Text($0.formatted()).tag($0) }
            }
            Picker("Keep at most", selection: $model.draft.logBufferCapacity) {
                ForEach([10000, 50000, 100_000, 250_000], id: \.self) { Text("\($0.formatted()) lines").tag($0) }
            }
        }
    }

    // MARK: Helpers

    private func pathField(_ title: String, keyPath: WritableKeyPath<AppSettings, String?>, placeholder: String) -> some View {
        TextField(title, text: Binding(
            get: { model.draft[keyPath: keyPath] ?? "" },
            set: { model.setOptional(keyPath, $0) }
        ), prompt: Text(placeholder))
        .autocorrectionDisabled()
    }

    /// Placeholder showing the automatic value when no override is set.
    private func autoPath(_ keyPath: WritableKeyPath<AppSettings, String?>, _ url: URL) -> String {
        model.draft[keyPath: keyPath] == nil ? url.path(percentEncoded: false) : ""
    }

    private enum ShellKind: Hashable {
        case auto, bash, sh, custom
    }

    private var shellKind: Binding<ShellKind> {
        Binding(
            get: {
                switch model.draft.terminalShell {
                case .auto: .auto
                case .bash: .bash
                case .sh: .sh
                case .custom: .custom
                }
            },
            set: { kind in
                switch kind {
                case .auto: model.draft.terminalShell = .auto
                case .bash: model.draft.terminalShell = .bash
                case .sh: model.draft.terminalShell = .sh
                case .custom:
                    if case .custom = model.draft.terminalShell { return }
                    model.draft.terminalShell = .custom("")
                }
            }
        )
    }
}

/// One selectable icon style with previews of its main states.
private struct IconStyleRow: View {
    let style: MenuBarIconStyle
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// States shown in the preview, with the animation frame that best represents them.
    private static let previews: [(state: IconState, frame: Int)] = [(.running, 0), (.transitioning, 2), (.stopped, 0), (.error, 0)]

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(style.displayName)
                Spacer()
                HStack(spacing: 12) {
                    ForEach(Self.previews, id: \.state) { preview in
                        icon(preview.state, frame: preview.frame)
                            .help(StatusIconRenderer.accessibilityText(for: preview.state))
                    }
                }
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(_ state: IconState, frame: Int) -> some View {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let image = StatusIconRenderer.image(for: state, style: style, frame: frame, appearance: appearance)
        if image.isTemplate {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(.primary)
        } else {
            Image(nsImage: image)
                .renderingMode(.original)
        }
    }
}
