import AppKit
import ColimaDomain
import ColimaFeatures
import SwiftUI
import UniformTypeIdentifiers

/// Logs window: control bar, virtualized log table, status bar.
public struct LogsWindowView: View {
    @Bindable private var model: LogsViewModel
    @FocusState private var searchFocused: Bool
    private let textStyle: () -> ConsoleTextStyle

    /// Creates the view; streaming starts when it appears.
    ///
    /// - Parameter textStyle: Font and spacing of the log lines. Read during `body`, so a value from an
    ///   observable object (the settings) updates the open window.
    public init(model: LogsViewModel, textStyle: @escaping () -> ConsoleTextStyle = { .logsDefault }) {
        self.model = model
        self.textStyle = textStyle
    }

    public var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let banner = bannerText {
                streamBanner(banner)
                Divider()
            }
            LogTableView(model: model, style: textStyle())
            Divider()
            statusBar
        }
        .frame(minWidth: 480, minHeight: 240)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    searchFocused = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut("f")
                .help("Filter (⌘F)")
                .accessibilityLabel("Focus filter")
                TextField("Filter", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Filter log lines")
                if !model.filterText.isEmpty {
                    Button {
                        model.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 320)

            Spacer()

            Toggle(isOn: $model.isFollowing) {
                Label(model.isFollowing ? "Following" : "Paused", systemImage: model.isFollowing ? "pause.fill" : "play.fill")
            }
            .toggleStyle(.button)
            .keyboardShortcut("p")
            .help("Follow new lines (⌘P)")

            Button {
                model.insertMarker()
            } label: {
                Label("Marker", systemImage: "bookmark")
            }
            .keyboardShortcut("m")
            .help("Insert a marker line (⌘M)")

            Toggle(isOn: $model.showsTimestamps) {
                Label("Timestamps", systemImage: "clock")
            }
            .toggleStyle(.button)
            .help("Show timestamps")

            Menu {
                Button("Copy Visible Lines") { copyAll() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Save Visible Lines…") { save() }
                    .keyboardShortcut("s")
                Divider()
                Button("Clear Window") { model.clear() }
                    .keyboardShortcut("k")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy, save or clear")
        }
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Banner and status

    private var bannerText: String? {
        switch model.state {
        case .ended: "The log stream ended. The container may have stopped."
        case .failed(let message): "Logs unavailable: \(message)"
        case .connecting, .streaming: nil
        }
    }

    private func streamBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(2)
            Spacer()
            Button("Reconnect") { model.reconnect() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(model.state == .connecting ? "Connecting…" : "\(model.rowCount.formatted()) lines")
            if model.droppedLineCount > 0 {
                Text("\(model.droppedLineCount.formatted()) older lines dropped")
                    .help("Raise the buffer size in Settings to keep more lines")
            }
            Spacer()
            if !model.isFollowing {
                Button {
                    model.isFollowing = true
                } label: {
                    Text(model.newLinesWhilePaused > 0 ? "\(model.newLinesWhilePaused.formatted()) new lines — Resume" : "Paused — Resume")
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: Export

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.visibleText(), forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: .current))
        panel.nameFieldStringValue = "\(model.containerName)-\(stamp).log"
        let text = model.visibleText()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
