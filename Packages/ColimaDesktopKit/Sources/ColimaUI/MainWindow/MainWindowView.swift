import AppKit
import ColimaDomain
import ColimaFeatures
import SwiftUI

/// The main window: VM status and controls on top, containers on the left, the environment on the right.
public struct MainWindowView: View {
    @Bindable private var model: MainWindowModel

    /// Creates the view.
    public init(model: MainWindowModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                containerColumn
                    .frame(minWidth: 460, idealWidth: 640)
                environmentColumn
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: 560)
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .onChange(of: model.snapshot.containers) { model.syncDetails() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            StatusDot(color: model.status.color, size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.status.title)
                    .font(.headline)
                Text(model.status.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Picker("Profile", selection: Binding(
                get: { model.snapshot.selectedProfile },
                set: { model.selectProfile($0) }
            )) {
                ForEach(model.profiles, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!model.canSwitchProfile)
            .help("Profile")
            HStack(spacing: 6) {
                commandButton("Start", systemImage: "play.fill", .startVM)
                commandButton("Stop…", systemImage: "stop.fill", .stopVM)
                commandButton("Restart…", systemImage: "arrow.clockwise", .restartVM)
            }
            commandButton("New Container…", systemImage: "plus.circle", .newContainer)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func commandButton(_ title: String, systemImage: String, _ command: MainMenuCommand) -> some View {
        let action = model.action(for: command)
        return Button {
            if let action { model.perform(action) }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(action == nil)
    }

    // MARK: Containers

    private var containerColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter by name, image or project", text: $model.filter)
                    .textFieldStyle(.plain)
                if !model.filter.isEmpty {
                    Button {
                        model.filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(10)
            Divider()
            containerContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.snapshot.containerActionError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
    }

    @ViewBuilder
    private var containerContent: some View {
        let state = model.listState
        switch state {
        case .ready where model.snapshot.containers.isEmpty:
            VStack(spacing: 10) {
                Text("No containers")
                    .foregroundStyle(.secondary)
                Button("New Container…") { model.perform(.newContainer) }
            }
        case .ready where model.groups.isEmpty:
            placeholder("No container matches “\(model.filter)”.")
        case .ready:
            List(selection: $model.selectedContainerID) {
                ForEach(model.groups) { group in
                    Section(group.project ?? "Other") {
                        ForEach(group.containers) { container in
                            ContainerRow(model: model, container: container)
                                .tag(container.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
        case .unreachable(let message):
            placeholder("\(state.message)\n\(message)")
        default:
            placeholder(state.message)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(20)
    }

    // MARK: Environment

    private var environmentColumn: some View {
        Form {
            ForEach(model.information) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        if let label = item.label {
                            LabeledContent(label) {
                                Text(item.value)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(item.value)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One container: state, name, status, actions; expands to its details.
private struct ContainerRow: View {
    let model: MainWindowModel
    let container: Container

    var body: some View {
        let commands = model.commands(for: container)
        let expanded = model.isExpanded(container.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.toggleExpanded(container.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(expanded ? "Hide details" : "Show details")
                StatusDot(color: commands.pending != nil ? .yellow : container.state.statusColor, size: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(container.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(subtitle(commands, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .opacity(container.state.isAlive ? 1 : 0.7)
                Spacer(minLength: 8)
                actionButtons(commands)
            }
            if expanded {
                ContainerDetailsView(model: model, container: container, commands: commands)
                    .padding(.leading, 31)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
    }

    private func subtitle(_ commands: ContainerCommands, now: Date) -> String {
        if let pending = commands.pending { return "\(pending.progressText)…" }
        return [Format.status(of: container, now: now), container.image].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func actionButtons(_ commands: ContainerCommands) -> some View {
        HStack(spacing: 2) {
            iconButton("Start", "play.fill", enabled: commands.canStart, .container(.start, containerID: container.id, name: container.name))
            iconButton("Stop…", "stop.fill", enabled: commands.canStop, .container(.stop, containerID: container.id, name: container.name))
            iconButton("Restart…", "arrow.clockwise", enabled: commands.canRestart, .container(.restart, containerID: container.id, name: container.name))
            Divider()
                .frame(height: 16)
                .padding(.horizontal, 6)
            iconButton("Show Logs", "doc.text.magnifyingglass", enabled: commands.canShowLogs, .showLogs(containerID: container.id, name: container.name))
            iconButton("Open Terminal", "terminal", enabled: commands.canOpenTerminal, .openTerminal(containerID: container.id, name: container.name))
        }
    }

    private func iconButton(_ label: String, _ systemImage: String, enabled: Bool, _ action: MenuAction) -> some View {
        Button {
            model.perform(action)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Facts, ports, inspect details and Delete of an expanded container.
private struct ContainerDetailsView: View {
    let model: MainWindowModel
    let container: Container
    let commands: ContainerCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(ContainerFacts.rows(container, now: context.date)) { item in
                        row(item.label ?? "", item.value)
                    }
                    if !container.ports.isEmpty {
                        GridRow {
                            label("Ports")
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(container.ports.enumerated()), id: \.offset) { _, port in
                                    HStack(spacing: 6) {
                                        Text(port.displayText)
                                            .textSelection(.enabled)
                                        if let url = port.browsableURL {
                                            Button("Open") { model.perform(.openURL(url)) }
                                                .buttonStyle(.link)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    inspectRows
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("Delete…", role: .destructive) {
                    model.perform(.container(.remove, containerID: container.id, name: container.name))
                }
                .disabled(!commands.canDelete)
                .help(commands.canDelete ? "Delete the container" : "Stop the container first")
            }
        }
    }

    @ViewBuilder
    private var inspectRows: some View {
        switch model.details[container.id] {
        case .loading, nil:
            GridRow {
                label("Details")
                ProgressView()
                    .controlSize(.small)
            }
        case .failed(let message):
            GridRow {
                label("Details")
                Text(message)
                    .foregroundStyle(.red)
            }
        case .loaded(let details):
            row("Command", details.command.joined(separator: " "))
            if let health = details.health {
                row("Health", health)
            }
            row("Restarts", String(details.restartCount))
            if !details.networks.isEmpty {
                row("Networks", details.networks.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
            }
            if !details.mounts.isEmpty {
                row("Mounts", details.mounts.joined(separator: "\n"))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// A colored status dot.
private struct StatusDot: View {
    let color: StatusColor
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(nsColor: MenuImages.nsColor(color)))
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
