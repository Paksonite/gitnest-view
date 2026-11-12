import XCTest
@testable import GitNestView

/// Clones in the states that break tools: diverged, detached, mid-merge,
/// without commits, gone from the disk. Each is read by the engine, judged
/// by the model, and drawn in the window.
@MainActor
final class CloneEdgeCaseTests: XCTestCase {
    private var app: CannedApp!
    private var flow: FlowWindow?

    override func setUp() async throws {
        app = try await CannedApp(repos: 6, clones: 1)
    }

    override func tearDown() async throws {
        await MainActor.run { flow?.close(); flow = nil; app?.cleanUp(); app = nil }
    }

    private var repo: ForgeRepo { app.model.repos.first { app.model.clone(of: $0) != nil }! }
    private var directory: URL { URL(fileURLWithPath: app.model.clone(of: repo)!.path) }

    private func git(_ arguments: String...) throws { try CannedApp.git(arguments, in: directory) }

    private func output(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func write(_ text: String, to file: String) throws {
        try text.write(to: directory.appending(path: file), atomically: true, encoding: .utf8)
    }

    /// Makes origin/main point at `sha` and main track it, as after a fetch.
    private func pretendRemote(at sha: String) throws {
        try git("update-ref", "refs/remotes/origin/main", sha)
        try git("config", "branch.main.remote", "origin")
        try git("config", "branch.main.merge", "refs/heads/main")
    }

    /// Reads the clone again and draws every tab of it.
    private func drawAll(_ name: String) async {
        await app.model.refreshLocal()
        if flow == nil { flow = FlowWindow(app.model) }
        let id = repo.id
        await flow!.step("\(name): select", wait: 0.3) {
            app.model.selection = id
            app.model.section = .repositories
        }
        for tab in [RepoTab.changes, .history, .resources, .overview] {
            await flow!.step("\(name): \(tab.rawValue)", wait: 0.3) { app.model.repoTab = tab }
        }
    }

    func testDivergedBehindAndAhead() async throws {
        let first = try output("rev-parse", "HEAD")
        // The server moved on: a commit that is not here.
        try git("checkout", "-q", "-b", "theirs")
        try write("theirs\n", to: "theirs.txt")
        try git("add", "."); try git("commit", "-q", "-m", "theirs")
        let theirs = try output("rev-parse", "HEAD")
        try git("checkout", "-q", "main")
        try pretendRemote(at: theirs)
        await drawAll("behind")
        XCTAssertEqual(app.model.attention(repo), [.behind(1)])

        try write("mine\n", to: "mine.txt")
        try git("add", "."); try git("commit", "-q", "-m", "mine")
        await drawAll("diverged")
        XCTAssertEqual(app.model.attention(repo), [.diverged(ahead: 1, behind: 1)])

        try pretendRemote(at: first)
        await drawAll("ahead")
        XCTAssertEqual(app.model.attention(repo), [.ahead(1)])
        flow?.report(budget: 400)
    }

    func testDetachedHead() async throws {
        try write("second\n", to: "second.txt")
        try git("add", "."); try git("commit", "-q", "-m", "second")
        try git("checkout", "-q", "--detach", "HEAD~1")
        await drawAll("detached")
        let clone = try XCTUnwrap(app.model.clone(of: repo))
        XCTAssertNotEqual(clone.branch, "main", "a detached HEAD must not be shown as the branch")
        let commits = await app.model.commits(of: repo)
        XCTAssertEqual(commits.count, 1)
        XCTAssertFalse(app.model.toasts.contains { $0.kind == .error }, app.model.toasts.map(\.text).joined(separator: "; "))
        flow?.report(budget: 400)
    }

    func testMergeWithConflictsIsTheFirstThingSaid() async throws {
        try git("checkout", "-q", "-b", "other")
        try write("# theirs\n", to: "main.tf")
        try git("commit", "-q", "-am", "theirs")
        try git("checkout", "-q", "main")
        try write("# mine\n", to: "main.tf")
        try git("commit", "-q", "-am", "mine")
        XCTAssertThrowsError(try git("merge", "other"), "the merge must stop on the conflict")
        await drawAll("conflict")
        let reasons = app.model.attention(repo)
        guard case .conflict = try XCTUnwrap(reasons.first) else { return XCTFail("a conflict is the most urgent thing: \(reasons)") }
        XCTAssertEqual(app.model.todo.first?.title, repo.name, "the conflict leads the To do list")
        // The viewer shows the file with its conflict markers instead of failing.
        await flow!.step("conflict: file", wait: 0.4) { app.model.fileTarget = FileTarget(repo: repo, file: "main.tf", line: 1) }
        await flow!.step("conflict: file closed") { app.model.fileTarget = nil }
        flow?.report(budget: 400)
    }

    func testUncommittedWork() async throws {
        try write("# changed\n", to: "main.tf")
        try write("new\n", to: "new file with spaces.tf")
        try write("zażółć\n", to: "zażółć.tf")
        await drawAll("changes")
        XCTAssertEqual(app.model.attention(repo), [.changes(3)])
        flow?.report(budget: 400)
    }

    func testCloneWithoutCommits() async throws {
        let empty = app.workdir.appending(path: CannedForge.org).appending(path: CannedForge.repoName(1))
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try CannedApp.git(["init", "-q", "-b", "main"], in: empty)
        try CannedApp.git(["remote", "add", "origin", "https://\(CannedForge.host)/\(CannedForge.org)/\(CannedForge.repoName(1)).git"], in: empty)
        await app.model.scan(full: true)
        let unborn = try XCTUnwrap(app.model.repos.first { $0.name == CannedForge.repoName(1) })
        XCTAssertNotNil(app.model.clone(of: unborn), "a clone without commits is still a clone")
        flow = FlowWindow(app.model)
        await flow!.step("unborn: select", wait: 0.3) {
            app.model.selection = unborn.id
            app.model.section = .repositories
        }
        for tab in RepoTab.allCases {
            await flow!.step("unborn: \(tab.rawValue)", wait: 0.3) { app.model.repoTab = tab }
        }
        let commits = await app.model.commits(of: unborn)
        XCTAssertTrue(commits.isEmpty)
        flow?.report(budget: 400)
    }

    func testCloneDeletedWhileTheAppRuns() async throws {
        let gone = directory
        let id = repo.id
        await drawAll("before")
        // The views may still have git at work in the folder (a lock file
        // appears and goes): removing it can need a second try.
        var removed = false
        for _ in 0..<20 where !removed {
            do {
                try FileManager.default.removeItem(at: gone)
                removed = true
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "the folder could not be removed")
        await app.model.refreshLocal()
        let same = try XCTUnwrap(app.model.repos.first { $0.id == id })
        XCTAssertNil(app.model.clone(of: same), "a deleted folder must stop being a clone")
        for tab in RepoTab.allCases {
            await flow!.step("deleted: \(tab.rawValue)", wait: 0.3) { app.model.repoTab = tab }
        }
        await flow!.step("deleted: file", wait: 0.3) { app.model.fileTarget = FileTarget(repo: same, file: "main.tf", line: 1) }
        await flow!.step("deleted: file closed") { app.model.fileTarget = nil }
        flow?.report(budget: 400)
    }
}
