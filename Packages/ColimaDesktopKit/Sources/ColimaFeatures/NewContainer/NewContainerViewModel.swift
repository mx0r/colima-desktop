import ColimaDomain
import Foundation
import Observation

/// The New Container window: search images, fill in the form, then pull, create and start.
@MainActor
@Observable
public final class NewContainerViewModel {
    /// Search results of one catalog.
    public struct SearchSection: Hashable, Sendable, Identifiable {
        public var source: String
        public var results: [ImageSearchResult]
        public var id: String { source }

        /// Creates a section.
        public init(source: String, results: [ImageSearchResult]) {
            self.source = source
            self.results = results
        }
    }

    /// Image search state.
    public enum SearchState: Hashable, Sendable {
        /// Not enough text to search.
        case idle
        case searching
        case results([SearchSection])
        case failed(String)
    }

    /// Tags of the image in the form.
    public enum TagsState: Hashable, Sendable {
        /// No valid image yet.
        case none
        case loading
        case loaded([ImageTag])
        /// The image's registry has no catalog here; the tag is typed by hand.
        case notListed
        case unavailable(String)
    }

    /// What happened to a created container.
    public struct Outcome: Hashable, Sendable {
        public var containerID: String
        public var name: String
        public var started: Bool
        /// Why the start failed; the container exists anyway.
        public var startError: String?
        public var warnings: [String]

        /// Creates an outcome.
        public init(containerID: String, name: String, started: Bool, startError: String?, warnings: [String]) {
            self.containerID = containerID
            self.name = name
            self.started = started
            self.startError = startError
            self.warnings = warnings
        }
    }

    /// Where the creation is.
    public enum Phase: Hashable, Sendable {
        case editing
        case pulling(PullProgress)
        case creating
        case starting
        case finished(Outcome)
        case failed(String)
    }

    /// Search text; searches after a pause in typing.
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    /// Container settings being edited. A changed image loads its tags after a pause in typing.
    public var form = ContainerForm() {
        didSet {
            guard form.image != oldValue.image else { return }
            scheduleTagLoad()
        }
    }
    public private(set) var search: SearchState = .idle
    public private(set) var tags: TagsState = .none
    public private(set) var phase: Phase = .editing
    /// Issues are shown once the user tried to create the container.
    public private(set) var showsIssues = false
    /// Architecture of the VM, e.g. `aarch64`; nil when unknown.
    public let vmArchitecture: String?
    /// Whether any image source is enabled.
    public var canSearch: Bool { !catalogs.isEmpty }
    /// Names of the enabled image sources.
    public var catalogNames: [String] { catalogs.map(\.name) }

    @ObservationIgnored private let engine: any DockerEngine
    @ObservationIgnored private let catalogs: [any ImageCatalog]
    @ObservationIgnored private let homeDirectory: String
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let onAction: (MenuAction) -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var tagsTask: Task<Void, Never>?
    @ObservationIgnored private var createTask: Task<Void, Never>?

    /// Pause between the last keystroke and the search.
    static let searchDelay = Duration.milliseconds(400)
    /// Shorter text is not searched.
    static let minimumQueryLength = 2
    /// Results asked for per catalog.
    static let searchLimit = 25

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - catalogs: Enabled image sources, in order.
    ///   - homeDirectory: Replaces `~` in host paths.
    ///   - onAction: Opens logs or a terminal for the new container.
    public init(
        engine: any DockerEngine,
        catalogs: [any ImageCatalog],
        vmArchitecture: String?,
        homeDirectory: String = NSHomeDirectory(),
        clock: any Clock<Duration> = ContinuousClock(),
        onAction: @escaping (MenuAction) -> Void = { _ in }
    ) {
        self.engine = engine
        self.catalogs = catalogs
        self.vmArchitecture = vmArchitecture
        self.homeDirectory = homeDirectory
        self.clock = clock
        self.onAction = onAction
    }

    // MARK: Search and tags

    /// Takes a search result into the form and loads its tags.
    public func select(_ result: ImageSearchResult) {
        form.image = result.name
        form.tag = ""
        loadTags()
    }

    /// Loads the tags of the image in the form.
    public func loadTags() {
        tagsTask?.cancel()
        guard let reference = ImageReference(form.image) else {
            tags = .none
            return
        }
        tags = .loading
        let catalogs = catalogs
        tagsTask = Task { [weak self] in
            var result = TagsState.notListed
            for catalog in catalogs {
                do {
                    if let list = try await catalog.tags(of: reference) {
                        result = .loaded(list)
                        break
                    }
                } catch {
                    result = .unavailable(Self.message(error))
                    break
                }
            }
            guard !Task.isCancelled else { return }
            self?.tags = result
        }
    }

    /// The tag the form will use, if it is in the loaded list.
    public var selectedTag: ImageTag? {
        guard case .loaded(let list) = tags else { return nil }
        let name = form.tag.trimmingCharacters(in: .whitespaces)
        let wanted = name.isEmpty ? (ImageReference(form.image)?.tag ?? ImageReference.defaultTag) : name
        return list.first { $0.name == wanted }
    }

    /// Whether the selected tag has an image for the VM; nil when unknown.
    public var tagSupportsVM: Bool? {
        guard let vmArchitecture else { return nil }
        return selectedTag?.supports(vmArchitecture: vmArchitecture)
    }

    private func scheduleTagLoad() {
        tagsTask?.cancel()
        tags = .none
        let clock = clock
        tagsTask = Task { [weak self] in
            do { try await clock.sleep(for: Self.searchDelay) } catch { return }
            self?.loadTags()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= Self.minimumQueryLength, !catalogs.isEmpty else {
            search = .idle
            return
        }
        let clock = clock
        let catalogs = catalogs
        searchTask = Task { [weak self] in
            do { try await clock.sleep(for: Self.searchDelay) } catch { return }
            self?.search = .searching
            var sections: [SearchSection] = []
            var firstError: Error?
            for catalog in catalogs {
                do {
                    sections.append(SearchSection(source: catalog.name, results: try await catalog.search(term, limit: Self.searchLimit)))
                } catch {
                    firstError = firstError ?? error
                }
            }
            guard !Task.isCancelled, let self else { return }
            if sections.isEmpty, let firstError {
                search = .failed(Self.message(firstError))
            } else {
                search = .results(sections)
            }
        }
    }

    // MARK: Create

    /// Issues of a field; empty until the user first tries to create the container.
    public func issues(for field: ContainerForm.Field) -> [String] {
        guard showsIssues else { return [] }
        return form.validate(homeDirectory: homeDirectory).issues.filter { $0.field == field }.map(\.message)
    }

    /// Whether the form has issues the user has been shown.
    public var hasIssues: Bool {
        showsIssues && !form.validate(homeDirectory: homeDirectory).issues.isEmpty
    }

    /// Whether a pull, create or start is running.
    public var isBusy: Bool {
        switch phase {
        case .pulling, .creating, .starting: true
        default: false
        }
    }

    /// Pulls the image if needed (or always, if asked), creates the container and starts it.
    public func create() {
        guard !isBusy else { return }
        showsIssues = true
        guard let spec = form.validate(homeDirectory: homeDirectory).spec else { return }
        let alwaysPull = form.alwaysPull
        let start = form.startAfterCreating
        phase = alwaysPull ? .pulling(PullProgress()) : .creating
        createTask = Task { [weak self] in
            await self?.run(spec, alwaysPull: alwaysPull, start: start)
        }
    }

    /// Stops a running pull and returns to the form. A container that is already being created is
    /// finished, since it exists in Docker either way.
    public func cancel() {
        createTask?.cancel()
    }

    /// Back to the form after a result, to create another container.
    public func editAgain() {
        guard !isBusy else { return }
        phase = .editing
    }

    /// Opens the logs of the created container.
    public func showLogs() {
        guard case .finished(let outcome) = phase else { return }
        onAction(.showLogs(containerID: outcome.containerID, name: outcome.name))
    }

    /// Opens a terminal in the created container.
    public func openTerminal() {
        guard case .finished(let outcome) = phase, outcome.started else { return }
        onAction(.openTerminal(containerID: outcome.containerID, name: outcome.name))
    }

    /// Stops everything when the window closes.
    public func close() {
        searchTask?.cancel()
        tagsTask?.cancel()
        createTask?.cancel()
    }

    private func run(_ spec: ContainerSpec, alwaysPull: Bool, start: Bool) async {
        do {
            if alwaysPull { try await pull(spec.image) }
            phase = .creating
            let created: CreatedContainer
            do {
                created = try await engine.createContainer(spec)
            } catch let DockerError.api(status, _) where status == 404 && !alwaysPull {
                // Like `docker run`: pull a missing image, then try again.
                try await pull(spec.image)
                phase = .creating
                created = try await engine.createContainer(spec)
            }
            let name = (try? await engine.inspect(containerID: created.id).name) ?? spec.name ?? String(created.id.prefix(12))
            var started = false
            var startError: String?
            if start {
                phase = .starting
                do {
                    try await engine.perform(.start, containerID: created.id)
                    started = true
                } catch {
                    startError = Self.message(error)
                }
            }
            phase = .finished(Outcome(containerID: created.id, name: name, started: started, startError: startError, warnings: created.warnings))
        } catch is CancellationError {
            phase = .editing
        } catch {
            phase = Task.isCancelled ? .editing : .failed(Self.message(error))
        }
    }

    private func pull(_ image: ImageReference) async throws {
        var progress = PullProgress()
        phase = .pulling(progress)
        for try await message in engine.pullImage(image) {
            progress.apply(message)
            phase = .pulling(progress)
        }
        // A cancelled stream ends without an error.
        try Task.checkCancellation()
    }

    private static func message(_ error: Error) -> String {
        error.localizedDescription
    }
}
