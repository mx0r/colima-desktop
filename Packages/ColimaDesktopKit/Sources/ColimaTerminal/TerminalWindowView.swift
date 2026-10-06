import AppKit
import ColimaDomain
import ColimaFeatures
import SwiftTerm
import SwiftUI

/// Terminal window: an embedded terminal plus a status bar with reconnect.
public struct TerminalWindowView: View {
    @Bindable private var model: TerminalSessionModel

    /// Creates the view; the session connects once the terminal has a size.
    public init(model: TerminalSessionModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ExecTerminalView(model: model)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> TerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: font)
        view.terminalDelegate = context.coordinator
        view.optionAsMetaKey = true
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        view.setAccessibilityLabel("Terminal for \(model.containerName)")
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: @MainActor TerminalViewDelegate {
        private let model: TerminalSessionModel
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
