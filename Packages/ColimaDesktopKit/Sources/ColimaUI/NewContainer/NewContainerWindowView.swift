import AppKit
import ColimaDomain
import ColimaFeatures
import SwiftUI

/// New Container window: image search on the left, the container form on the right, progress and
/// the result at the bottom.
public struct NewContainerWindowView: View {
    @Bindable private var model: NewContainerViewModel
    @FocusState private var searchFocused: Bool

    /// Creates the view.
    public init(model: NewContainerViewModel) {
        self.model = model
    }

    public var body: some View {
        HSplitView {
            searchColumn
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 440)
            VStack(spacing: 0) {
                formColumn
                Divider()
                bottomBar
            }
            .frame(minWidth: 460)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { searchFocused = true }
        .onDisappear { model.close() }
    }

    // MARK: Search

    private var searchColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(searchPrompt, text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .disabled(!model.canSearch)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            Divider()
            searchContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchPrompt: String {
        model.canSearch ? "Search \(model.catalogNames.joined(separator: ", "))" : "Search"
    }

    @ViewBuilder
    private var searchContent: some View {
        if !model.canSearch {
            placeholder("No image source is on. Turn one on in Settings → Image sources, or type an image name in the form.")
        } else {
            switch model.search {
            case .idle:
                placeholder("Type at least two characters to search. Any image name also works in the form, for example ghcr.io/owner/app.")
            case .searching:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder(message, systemImage: "exclamationmark.triangle")
            case .results(let sections) where sections.allSatisfy(\.results.isEmpty):
                placeholder("No images found.")
            case .results(let sections):
                List(selection: selection(in: sections)) {
                    ForEach(sections) { section in
                        Section(section.source) {
                            ForEach(section.results) { result in
                                SearchResultRow(result: result).tag(result.name)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// The list selection follows the image in the form; choosing a row fills the form.
    private func selection(in sections: [NewContainerViewModel.SearchSection]) -> Binding<String?> {
        Binding(
            get: { ImageReference(model.form.image)?.repository },
            set: { name in
                guard let name, let result = sections.lazy.flatMap(\.results).first(where: { $0.name == name }) else { return }
                model.select(result)
            }
        )
    }

    private func placeholder(_ text: String, systemImage: String? = nil) -> some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Form

    private var formColumn: some View {
        Form {
            imageSection
            containerSection
            portsSection
            environmentSection
            volumesSection
            Section {
                Toggle("Start the container after creating it", isOn: $model.form.startAfterCreating)
                Toggle("Pull the image even if it is already there", isOn: $model.form.alwaysPull)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
    }

    private var imageSection: some View {
        Section("Image") {
            TextField("Image", text: $model.form.image, prompt: Text("nginx or ghcr.io/owner/app"))
                .autocorrectionDisabled()
                .onSubmit { model.loadTags() }
            issueRows(.image)
            LabeledContent("Tag") {
                HStack(spacing: 6) {
                    TextField("Tag", text: $model.form.tag, prompt: Text(defaultTag))
                        .labelsHidden()
                        .autocorrectionDisabled()
                    tagMenu
                }
            }
            if model.tagSupportsVM == false, let architecture = model.vmArchitecture {
                Label(
                    "This tag has no linux/\(ImagePlatform.dockerArchitecture(forVM: architecture)) image, so the pull may fail.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
            issueRows(.tag)
        }
    }

    private var defaultTag: String {
        ImageReference(model.form.image)?.tag ?? ImageReference.defaultTag
    }

    private var tagMenu: some View {
        Menu {
            switch model.tags {
            case .loaded(let list) where !list.isEmpty:
                ForEach(list) { tag in
                    Button(tagTitle(tag)) { model.form.tag = tag.name }
                }
            case .loaded:
                Text("No tags found")
            case .loading:
                Text("Loading tags…")
            case .notListed:
                Text("Tags are listed for Docker Hub images only")
            case .unavailable(let message):
                Text(message)
            case .none:
                Text("Enter an image first")
            }
        } label: {
            Image(systemName: "tag")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Recent tags")
        .accessibilityLabel("Recent tags")
    }

    private func tagTitle(_ tag: ImageTag) -> String {
        guard let architecture = model.vmArchitecture, tag.supports(vmArchitecture: architecture) == false else { return tag.name }
        return "\(tag.name) — no \(ImagePlatform.dockerArchitecture(forVM: architecture)) image"
    }

    private var containerSection: some View {
        Section("Container") {
            TextField("Name", text: $model.form.name, prompt: Text("Docker picks one"))
                .autocorrectionDisabled()
            issueRows(.name)
            TextField("Command", text: $model.form.command, prompt: Text("The image's default"))
                .autocorrectionDisabled()
            issueRows(.command)
            Picker("Restart", selection: $model.form.restartPolicy) {
                ForEach(RestartPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
    }

    private var portsSection: some View {
        Section {
            ForEach($model.form.ports) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("Host port", text: $row.hostPort, prompt: Text("Host (random)"))
                            .labelsHidden()
                            .frame(width: 110)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Container port", text: $row.containerPort, prompt: Text("Container port"))
                            .labelsHidden()
                        Picker("Protocol", selection: $row.proto) {
                            ForEach(PortProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        removeButton("Remove port") { model.form.ports.removeAll { $0.id == row.id } }
                    }
                    issueRows(.port(row.id))
                }
            }
            Button("Add Port", systemImage: "plus") { model.form.ports.append(ContainerForm.PortRow()) }
            Toggle("Also publish every port the image exposes, on random host ports", isOn: $model.form.publishAllPorts)
        } header: {
            Text("Ports")
        }
    }

    private var environmentSection: some View {
        Section("Environment") {
            ForEach($model.form.environment) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("Name", text: $row.name, prompt: Text("NAME"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                            .frame(width: 160)
                        Text("=")
                            .foregroundStyle(.secondary)
                        TextField("Value", text: $row.value, prompt: Text("value"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                        removeButton("Remove variable") { model.form.environment.removeAll { $0.id == row.id } }
                    }
                    issueRows(.environment(row.id))
                }
            }
            Button("Add Variable", systemImage: "plus") { model.form.environment.append(ContainerForm.EnvironmentRow()) }
        }
    }

    private var volumesSection: some View {
        Section {
            ForEach($model.form.volumes) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("Host folder or volume", text: $row.source, prompt: Text("~/folder or volume"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                        Button("Choose…") { chooseFolder(for: row.id) }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Container path", text: $row.target, prompt: Text("/path/in/container"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                        Toggle("Read-only", isOn: $row.readOnly)
                            .toggleStyle(.checkbox)
                        removeButton("Remove volume") { model.form.volumes.removeAll { $0.id == row.id } }
                    }
                    issueRows(.volume(row.id))
                }
            }
            Button("Add Volume", systemImage: "plus") { model.form.volumes.append(ContainerForm.VolumeRow()) }
        } header: {
            Text("Volumes")
        } footer: {
            Text("Host folders must be in a folder Colima shares with the VM; by default, that is your home folder.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func issueRows(_ field: ContainerForm.Field) -> some View {
        ForEach(model.issues(for: field), id: \.self) { message in
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    /// Lets the user pick a host folder or file for a volume row.
    private func chooseFolder(for rowID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let home = NSHomeDirectory()
            var path = url.path(percentEncoded: false)
            if path.hasSuffix("/"), path.count > 1 { path.removeLast() }
            if path == home || path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
            if let index = model.form.volumes.firstIndex(where: { $0.id == rowID }) {
                model.form.volumes[index].source = path
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            status
                .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .editing:
            if model.hasIssues {
                Label("Fix the marked fields.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let reference = model.form.imageReference {
                Text(reference.description)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .pulling(let progress):
            HStack(spacing: 8) {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(pullText(progress))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .creating:
            busy("Creating the container…")
        case .starting:
            busy("Starting the container…")
        case .finished(let outcome):
            Label(finishedText(outcome), systemImage: outcome.startError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(outcome.startError == nil ? Color.green : Color.orange)
                .lineLimit(3)
                .help(outcome.warnings.joined(separator: "\n"))
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.phase {
        case .editing, .failed:
            Button("Create") { model.create() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Create the container (⌘↩)")
        case .pulling:
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
        case .creating, .starting:
            EmptyView()
        case .finished(let outcome):
            Button("Show Logs") { model.showLogs() }
            if outcome.started {
                Button("Open Terminal") { model.openTerminal() }
            }
            Button("Create Another") { model.editAgain() }
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
        }
    }

    private func pullText(_ progress: PullProgress) -> String {
        guard progress.layerCount > 0 else { return progress.status ?? "Pulling the image…" }
        return "Pulling the image: \(progress.completedLayers) of \(progress.layerCount) layers"
    }

    private func finishedText(_ outcome: NewContainerViewModel.Outcome) -> String {
        if let error = outcome.startError {
            return "Created \(outcome.name), but it did not start: \(error)"
        }
        return outcome.started ? "Created and started \(outcome.name)." : "Created \(outcome.name)."
    }
}

/// One search result: name, official badge, stars and description.
private struct SearchResultRow: View {
    let result: ImageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(result.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if result.isOfficial {
                    Text("Official")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 4)
                Label(result.starCount.formatted(.number.notation(.compactName)), systemImage: "star")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            if !result.description.isEmpty {
                Text(result.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
