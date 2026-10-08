import AppKit
import ColimaDomain
import ColimaFeatures
import SwiftUI

/// The main window: VM status and controls on top, containers on the left, the environment on the right.
public struct MainWindowView: View {
    @Bindable private var model: MainWindowModel
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case list
        case filter
    }

    /// Shade of the header and the inspector, which frame the plain container list. Works in light and dark.
    static let paneShade = Color.primary.opacity(0.045)

    /// Creates the view.
    public init(model: MainWindowModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ProportionalSplit(minLeading: 440, minTrailing: 280) {
                containerColumn
            } trailing: {
                EnvironmentInspector(sections: model.information)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        // The list, not the filter field, starts with the focus: typing should not be needed to look.
        .defaultFocus($focus, .list)
        .onAppear { focus = .list }
        .onChange(of: model.snapshot.containers) { model.syncDetails() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: model.status.color, size: 10)
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
            if model.vmToggle == .stopVM {
                commandButton("Stop…", systemImage: "stop.fill", .stopVM)
            } else {
                commandButton("Start", systemImage: "play.fill", .startVM)
            }
            commandButton("Restart…", systemImage: "arrow.clockwise", .restartVM)
            Divider()
                .frame(height: 18)
            commandButton("New Container…", systemImage: "plus", .newContainer)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Self.paneShade)
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
                    .autocorrectionDisabled()
                    .focused($focus, equals: .filter)
                    .onExitCommand {
                        model.filter = ""
                        focus = .list
                    }
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
                if model.listState == .ready, !model.snapshot.containers.isEmpty {
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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

    private var countText: String {
        let all = model.snapshot.containers
        return "\(all.filter { $0.state == .running }.count) of \(all.count) running"
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
        case .ready where model.containers.isEmpty:
            placeholder("No container matches “\(model.filter)”.")
        case .ready:
            List(selection: $model.selectedContainerID) {
                ForEach(model.containers) { container in
                    ContainerRow(model: model, container: container)
                        .tag(container.id)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .focused($focus, equals: .list)
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
                // No animation: list rows resize unevenly while animating.
                Button {
                    model.toggleExpanded(container.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(expanded ? "Hide details" : "Show details")
                StatusDot(color: commands.pending != nil ? .yellow : container.state.statusColor, size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(container.name)
                            .lineLimit(1)
                        if let project = container.composeProject {
                            Text(project)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .help("Compose project")
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(subtitle(commands, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                actionButtons(commands)
            }
            if expanded {
                ContainerDetailsView(model: model, container: container, commands: commands)
                    .padding(.leading, 28)
                    .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 2)
        .contextMenu { contextMenu(commands) }
    }

    private func subtitle(_ commands: ContainerCommands, now: Date) -> String {
        if let pending = commands.pending { return "\(pending.progressText)…" }
        return [Format.status(of: container, now: now), container.image].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func action(_ containerAction: ContainerAction) -> MenuAction {
        .container(containerAction, containerID: container.id, name: container.name)
    }

    private func actionButtons(_ commands: ContainerCommands) -> some View {
        HStack(spacing: 0) {
            if commands.toggle == .stop {
                iconButton("Stop…", "stop.fill", enabled: commands.canToggle, action(.stop))
            } else {
                iconButton("Start", "play.fill", enabled: commands.canToggle, action(.start))
            }
            iconButton("Restart…", "arrow.clockwise", enabled: commands.canRestart, action(.restart))
            Spacer()
                .frame(width: 12)
            iconButton("Show Logs", "text.alignleft", enabled: commands.canShowLogs, .showLogs(containerID: container.id, name: container.name))
            iconButton("Open Terminal", "apple.terminal", enabled: commands.canOpenTerminal, .openTerminal(containerID: container.id, name: container.name))
        }
    }

    private func iconButton(_ label: String, _ systemImage: String, enabled: Bool, _ action: MenuAction) -> some View {
        Button {
            model.perform(action)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // An explicit style would hide the disabled look, so it is chosen per state.
        .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func contextMenu(_ commands: ContainerCommands) -> some View {
        Button("Start") { model.perform(action(.start)) }.disabled(!commands.canStart)
        Button("Stop…") { model.perform(action(.stop)) }.disabled(!commands.canStop)
        Button("Restart…") { model.perform(action(.restart)) }.disabled(!commands.canRestart)
        Divider()
        Button("Show Logs") { model.perform(.showLogs(containerID: container.id, name: container.name)) }
        Button("Open Terminal") { model.perform(.openTerminal(containerID: container.id, name: container.name)) }
            .disabled(!commands.canOpenTerminal)
        Divider()
        Button(model.isExpanded(container.id) ? "Hide Details" : "Show Details") { model.toggleExpanded(container.id) }
        Button("Copy ID") { model.perform(.copy(container.id)) }
        Divider()
        Button("Delete…") { model.perform(action(.remove)) }.disabled(!commands.canDelete)
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
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(ContainerFacts.rows(container, now: context.date)) { item in
                        DetailRow(label: item.label ?? "", lines: [item.value])
                    }
                    if !container.ports.isEmpty {
                        GridRow {
                            FactLabel(text: "Ports")
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(container.ports.enumerated()), id: \.offset) { _, port in
                                    HStack(spacing: 6) {
                                        Text(port.displayText)
                                            .lineLimit(1)
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
            Button("Delete…", role: .destructive) {
                model.perform(.container(.remove, containerID: container.id, name: container.name))
            }
            .controlSize(.small)
            .disabled(!commands.canDelete)
            .help(commands.canDelete ? "Delete the container" : "Stop the container first")
        }
    }

    @ViewBuilder
    private var inspectRows: some View {
        switch model.details[container.id] {
        case .loading, nil:
            GridRow {
                FactLabel(text: "Details")
                ProgressView()
                    .controlSize(.small)
            }
        case .failed(let message):
            DetailRow(label: "Details", lines: [message])
        case .loaded(let details):
            DetailRow(label: "Command", lines: [details.command.joined(separator: " ")])
            if let health = details.health {
                DetailRow(label: "Health", lines: [health])
            }
            DetailRow(label: "Restarts", lines: [String(details.restartCount)])
            if !details.networks.isEmpty {
                DetailRow(label: "Networks", lines: details.networks.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
            }
            if !details.mounts.isEmpty {
                DetailRow(label: "Mounts", lines: details.mounts)
            }
        }
    }
}

/// A fact in an expanded list row: one line per entry, truncated in the middle, the full text in a
/// tooltip and selectable. Lines never wrap, so the list measures the row's height correctly; wrapped
/// text made the row too short and ate its padding.
private struct DetailRow: View {
    let label: String
    let lines: [String]

    var body: some View {
        GridRow {
            FactLabel(text: label)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(line)
                }
            }
        }
    }
}

/// The environment: Colima, VM usage, Docker and its disk usage, in compact label/value columns.
private struct EnvironmentInspector: View {
    let sections: [InfoSection]

    var body: some View {
        ScrollView {
            // One grid for all sections, so the label column lines up across them.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    GridRow {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.top, index == 0 ? 0 : 14)
                            .padding(.bottom, 3)
                            .gridCellColumns(2)
                    }
                    ForEach(section.items) { item in
                        if let label = item.label {
                            FactRow(label: label, value: item.value)
                        } else {
                            GridRow {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                Text(item.value)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .font(.callout)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MainWindowView.paneShade)
    }
}

/// A label and a copyable value in a two-column grid.
private struct FactRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            FactLabel(text: label)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The label column of a fact grid.
private struct FactLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// Two panes side by side, split at a fraction of the width (two thirds at first). The user drags the
/// divider; the fraction is kept, so the split stays proportional when the window resizes.
private struct ProportionalSplit<Leading: View, Trailing: View>: View {
    let minLeading: CGFloat
    let minTrailing: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @AppStorage("MainWindowSplitFraction") private var fraction = 2.0 / 3.0

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            HStack(spacing: 0) {
                leading
                    .frame(width: leadingWidth(total))
                divider(total)
                trailing
                    .frame(maxWidth: .infinity)
            }
            .coordinateSpace(.named("split"))
        }
    }

    private func leadingWidth(_ total: CGFloat) -> CGFloat {
        let upper = max(minLeading, total - minTrailing - 1)
        return min(max(total * fraction, minLeading), upper)
    }

    private func divider(_ total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                            .onChanged { value in
                                guard total > 0 else { return }
                                fraction = Double(min(max(value.location.x, minLeading), total - minTrailing) / total)
                            }
                    )
            }
            .accessibilityHidden(true)
    }
}

/// A colored status dot.
private struct StatusDot: View {
    let color: StatusColor
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(nsColor: MenuImages.nsColor(color)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
