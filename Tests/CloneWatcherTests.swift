import XCTest
@testable import GitNestView

/// The clones' folders are watched: a change says which clone it was in,
/// and what git writes on its own does not.
@MainActor
final class CloneWatcherTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "gnv-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        for name in ["one/.git/objects", "two"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A watcher let go while its stream runs: nothing calls it afterwards.
    func testAFreedWatcherIsNotCalled() async throws {
        var watcher: CloneWatcher? = CloneWatcher()
        watcher?.enabled = true
        watcher?.watch([folder.appending(path: "two").path])
        try await Task.sleep(for: .milliseconds(300))
        watcher = nil
        try Data("after".utf8).write(to: folder.appending(path: "two/late.tf"))
        try await Task.sleep(for: .milliseconds(1200))
    }

    /// Off until enabled: the models tests make watch nothing.
    func testOffUntilEnabled() async throws {
        let watcher = CloneWatcher()
        var seen: [String] = []
        watcher.changed = { seen.append($0) }
        watcher.watch([folder.appending(path: "two").path])
        try Data("edit".utf8).write(to: folder.appending(path: "two/main.tf"))
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(seen.isEmpty)
    }

    func testAChangeNamesItsClone() async throws {
        let watcher = CloneWatcher()
        watcher.enabled = true
        var seen: [String] = []
        watcher.changed = { seen.append($0) }
        let one = folder.appending(path: "one").path, two = folder.appending(path: "two").path
        watcher.watch([one, two])
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // git's own objects do not count.
        try Data("x".utf8).write(to: folder.appending(path: "one/.git/objects/blob"))
        try Data("edit".utf8).write(to: folder.appending(path: "two/main.tf"))
        for _ in 0..<40 where seen.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(seen, [two])
    }
}
