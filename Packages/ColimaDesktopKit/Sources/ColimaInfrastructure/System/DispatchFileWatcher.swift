import ColimaDomain
import Foundation

/// Watches directories with `DispatchSource` vnode sources.
///
/// Directory sources fire when entries are created, deleted or renamed (e.g. `ha.pid`, `docker.sock`).
/// A missing directory is watched through its nearest existing parent. All sources are re-armed after
/// every event, so directories that appear or are replaced are picked up.
public struct DispatchFileWatcher: FileChangeObserving {
    /// Creates a watcher.
    public init() {}

    public func changes(in directories: [URL]) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watchSet = DirectoryWatchSet(directories: directories) {
                continuation.yield()
            }
            watchSet.start()
            continuation.onTermination = { _ in watchSet.stop() }
        }
    }
}

/// Owns the vnode sources. All mutable state is confined to `queue`.
private final class DirectoryWatchSet: @unchecked Sendable {
    private let directories: [URL]
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "ColimaDesktop.file-watcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var stopped = false

    init(directories: [URL], onChange: @escaping @Sendable () -> Void) {
        self.directories = directories
        self.onChange = onChange
    }

    func start() {
        queue.async { self.rearm() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.sources.forEach { $0.cancel() }
            self.sources = []
        }
    }

    private func rearm() {
        sources.forEach { $0.cancel() }
        sources = []
        guard !stopped else { return }
        let targets = Set(directories.compactMap(Self.nearestExistingDirectory))
        for path in targets {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .link, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                self.onChange()
                self.rearm()
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private static func nearestExistingDirectory(_ url: URL) -> String? {
        var current = url.standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            let path = current.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == path { return nil }
            current = parent
        }
    }
}
