import XCTest
@testable import GitNestView

/// A read-only token against a real server (GNV_HOST, GNV_RO_TOKEN,
/// GNV_LAB_REPO): everything can be read, nothing can be changed, and the
/// app says so in words instead of failing quietly.
@MainActor
final class ReadOnlyTokenTests: XCTestCase {
    func testReadsEverythingAndChangesNothing() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["GNV_HOST"], let token = env["GNV_RO_TOKEN"],
              let lab = env["GNV_LAB_REPO"]?.split(separator: "/").map(String.init), lab.count == 2 else {
            throw XCTSkip("GNV_HOST, GNV_RO_TOKEN and GNV_LAB_REPO are not set")
        }
        let suite = "gnv-ro-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(FileManager.default.temporaryDirectory)
        try await model.connect(host: host, token: token)
        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner.lowercased() == lab[0].lowercased() })
        model.select(workspace)
        await model.loadRepos(quiet: false)
        XCTAssertFalse(model.repos.isEmpty, model.reposError ?? "")

        // Reading: repositories, pull requests, checks, pipelines, the Inbox.
        let repo = try XCTUnwrap(model.repos.first { $0.name == lab[1] })
        await model.refreshForge(repo, detailed: true)
        let state = model.forgeState(repo)
        XCTAssertTrue(state.loaded, state.error ?? "")
        let pull = try XCTUnwrap(state.pulls.first, "the lab repository has a pull request")
        await model.loadExtras(pull, in: repo)
        let slug = try XCTUnwrap(model.slug(repo))
        XCTAssertTrue(model.extras[AppModel.extrasKey(slug, pull.number)]?.loaded == true)
        await model.refreshInbox()
        await model.refreshMyPulls()

        // What the token allows, asked of the server.
        let checks = await model.permissions(host: host)
        XCTAssertEqual(checks.filter { !$0.writes }.map(\.answer), Array(repeating: .yes, count: 5), "every read works")
        let writes = checks.filter(\.writes).map(\.answer)
        XCTAssertFalse(writes.contains(.yes), "a read-only token must not look able to write: \(writes)")
        await model.learnWriteAccess()
        if writes.allSatisfy({ $0 == .no }) {
            // A server that answers honestly: the app knows, and greys the buttons out.
            XCTAssertFalse(model.mayWrite(host))
        }

        // Every change is refused in words, and nothing changes.
        func refused(_ name: String, _ work: () async -> Void) async {
            model.toasts.removeAll()
            await work()
            XCTAssertTrue(model.toasts.contains { $0.kind == .error }, "\(name) did not report the refusal")
            XCTAssertFalse(model.toasts.contains { $0.kind != .error && $0.kind != .info }, "\(name) claimed success: \(model.toasts.map(\.text))")
        }
        await refused("comment") { await model.comment(on: pull, in: repo, text: "must not appear") }
        await refused("draft") { await model.setDraft(!AppModel.isDraft(pull), pull, in: repo) }
        await refused("edit") { await model.edit(pull, in: repo, title: pull.title + " x", body: "x") }
        await refused("close") { await model.setOpen(pull.state != "open", pull, in: repo) }
        await refused("update branch") { await model.updateBranch(of: pull, in: repo, rebase: false) }
        await refused("labels") { await model.setLabels([], on: pull, in: repo) }
        await refused("assignees") { await model.setAssignees([], on: pull, in: repo) }

        await model.refreshForge(repo, detailed: true)
        let after = try XCTUnwrap(model.forgeState(repo).pulls.first { $0.number == pull.number })
        XCTAssertEqual(after.title, pull.title)
        XCTAssertEqual(after.state, pull.state)
        XCTAssertEqual(after.body, pull.body)
        XCTAssertEqual(after.head.sha, pull.head.sha)
    }
}
