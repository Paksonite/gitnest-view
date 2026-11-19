import CoreServices
import Foundation

/// Watches the clones' folders (FSEvents) and says which clone changed: a
/// save in the editor, a commit or a checkout in the terminal. The app reads
/// that clone again at once, whether or not its window is in front.
@MainActor
final class CloneWatcher {
    /// Called with a clone's path, at most a few times a second per clone.
    var changed: ((String) -> Void)?
    /// Off until the app starts it: models made by tests watch nothing.
    var enabled = false

    /// Stopped in deinit too: a stream left running would call a freed watcher.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var watched: Set<String> = []
    /// Each watched folder as the disk names it (FSEvents reports those,
    /// past any symbolic link), to the path the app knows it by.
    private var real: [String: String] = [:]
    /// Clones waiting out their short pause before they are read.
    private var pending: Set<String> = []
    /// When each clone was last read because of a change here: git writes
    /// its index while reading the state, which must not start it again.
    private var lastRead: [String: Date] = [:]

    /// Folders whose changes git does not show: build output, caches.
    private static let ignoredParts = ["/.terraform/", "/.terragrunt-cache/", "/node_modules/", "/.idea/", "/.DS_Store"]
    /// What changes in .git without anything the app shows changing.
    private static let ignoredGit = ["/.git/objects/", "/.git/logs/", "/.git/index.lock", "/.git/FETCH_HEAD", "/.git/gc.", "/.git/lfs/"]

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func watch(_ paths: Set<String>) {
        guard enabled, paths != watched else { return }
        stop()
        watched = paths
        real = Dictionary(paths.map { (Self.realPath($0), $0) }, uniquingKeysWith: { a, _ in a })
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<CloneWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            MainActor.assumeIsolated { watcher.received(Array(list.prefix(count))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, Array(paths) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        for path in paths {
            if Self.ignoredParts.contains(where: path.contains) || Self.ignoredGit.contains(where: path.contains) { continue }
            // The longest watched folder that holds the path: its clone.
            guard let folder = real.keys.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }),
                  let clone = real[folder] else { continue }
            // Reading the state touches the index; a change right after a read is that.
            if path.hasSuffix("/.git/index"), let last = lastRead[clone], Date.now.timeIntervalSince(last) < 1.5 { continue }
            schedule(clone)
        }
    }

    private func schedule(_ clone: String) {
        guard !pending.contains(clone) else { return }
        pending.insert(clone)
        Task { [weak self] in
            // A save or a checkout touches many files: read once they settle.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.pending.remove(clone)
            self.lastRead[clone] = .now
            self.changed?(clone)
        }
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
