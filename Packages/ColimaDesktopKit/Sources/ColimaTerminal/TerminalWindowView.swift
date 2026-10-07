import AppKit
import ColimaDomain
import ColimaFeatures
import ColimaUI
import SwiftTerm
import SwiftUI

/// Terminal window: an embedded terminal plus a status bar with reconnect.
public struct TerminalWindowView: View {
    @Bindable private var model: TerminalSessionModel
    private let textStyle: () -> ConsoleTextStyle

    /// Creates the view; the session connects once the terminal has a size.
    ///
    /// - Parameter textStyle: Font and line spacing of the terminal. Read during `body`, so a value from
    ///   an observable object (the settings) updates the open window.
    public init(model: TerminalSessionModel, textStyle: @escaping () -> ConsoleTextStyle = { .terminalDefault }) {
        self.model = model
        self.textStyle = textStyle
    }

    public var body: some View {
        VStack(spacing: 0) {
            ExecTerminalView(model: model, style: textStyle())
            if let status = statusText {
                Divider()
                HStack {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                    Text(status)
                        .lineLimit(2)
                    Spacer()
                    if canReconnect {
                        Button("Reconnect") { model.reconnect() }
                            .keyboardShortcut("r")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 400, minHeight: 200)
        .onDisappear { model.close() }
    }

    private var statusText: String? {
        switch model.state {
        case .idle, .connected: nil
        case .connecting: "Connecting…"
        case .exited(let code): code.map { "Process exited with code \($0)." } ?? "Process exited."
        case .failed(let message): "Could not open a shell: \(message)"
        }
    }

    private var canReconnect: Bool {
        switch model.state {
        case .exited, .failed: true
        default: false
        }
    }

    private var statusIcon: String {
        if case .failed = model.state { return "exclamationmark.triangle.fill" }
        return "info.circle"
    }

    private var statusColor: SwiftUI.Color {
        if case .failed = model.state { return .orange }
        return .secondary
    }
}

extension TerminalSessionModel {
    /// Connects again with the last known size.
    func reconnect() {
        connect(size: lastSize)
    }
}

/// Hosts a SwiftTerm `TerminalView` and wires it to a `TerminalSessionModel`.
struct ExecTerminalView: NSViewRepresentable {
    let model: TerminalSessionModel
    let style: ConsoleTextStyle

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = ConsoleTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: ConsoleFonts.font(for: style))
        view.lineSpacing = style.lineHeight
        context.coordinator.style = style
        view.terminalDelegate = context.coordinator
        view.optionAsMetaKey = true
        view.configureNativeColors()
        view.setAccessibilityLabel("Terminal for \(model.containerName)")
        context.coordinator.attach(view)
        return view
    }

    // A new font or line spacing resizes the grid; SwiftTerm reports it through sizeChanged.
    func updateNSView(_ view: TerminalView, context: Context) {
        guard context.coordinator.style != style else { return }
        context.coordinator.style = style
        let font = ConsoleFonts.font(for: style)
        if view.font != font { view.font = font }
        if view.lineSpacing != style.lineHeight { view.lineSpacing = style.lineHeight }
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: @MainActor TerminalViewDelegate {
        private let model: TerminalSessionModel
        /// Text style the view shows.
        var style: ConsoleTextStyle?
        private weak var view: TerminalView?
        private var connectFallback: Task<Void, Never>?

        init(model: TerminalSessionModel) {
            self.model = model
        }

        func attach(_ view: TerminalView) {
            self.view = view
            model.onOutput = { [weak view] bytes in
                view?.feed(byteArray: bytes[...])
            }
            // The first layout reports the real size; connect then. Fall back if no layout happens.
            connectFallback = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.connectIfIdle()
            }
            Task { @MainActor [weak view] in
                view?.window?.makeFirstResponder(view)
            }
        }

        func detach() {
            connectFallback?.cancel()
            model.onOutput = nil
            model.close()
        }

        private func connectIfIdle() {
            guard model.state == .idle, let view else { return }
            let terminal = view.getTerminal()
            model.connect(size: TerminalSize(columns: max(terminal.cols, 20), rows: max(terminal.rows, 5)))
            view.window?.makeFirstResponder(view)
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let size = TerminalSize(columns: newCols, rows: newRows)
            if model.state == .idle {
                connectFallback?.cancel()
                model.connect(size: size)
                source.window?.makeFirstResponder(source)
            } else {
                model.resize(size)
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            model.send(Array(data))
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            guard !title.isEmpty else { return }
            source.window?.subtitle = title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

/// Terminal view whose default colors follow its window's light or dark appearance.
///
/// SwiftTerm turns the system text colors into fixed values when they are set, so they are set again
/// whenever the appearance changes, resolved in the new appearance.
final class ConsoleTerminalView: TerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            configureNativeColors()
        }
    }
}
