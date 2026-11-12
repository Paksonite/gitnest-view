import Observation
import XCTest
@testable import GitNestView

/// The model against a server that lives in the test: scale, and the ways
/// a server goes wrong. No network, so these run everywhere.
@MainActor
final class CannedForgeTests: XCTestCase {
    func testThreeHundredRepositoriesLoadAndStayCheap() async throws {
        let app = try await CannedApp(repos: 300, clones: 4)
        defer { app.cleanUp() }
        let model = app.model
        XCTAssertEqual(model.repos.count, 300, model.reposError ?? "")
        let before = CannedForge.hits["orgs/Lab/repos"] ?? 0
        await model.loadRepos(quiet: true)
        XCTAssertEqual((CannedForge.hits["orgs/Lab/repos"] ?? 0) - before, 7, "300 repositories are read in pages of 50, plus the empty one")
        XCTAssertEqual(model.repos.count { model.clone(of: $0) != nil }, 4)

        // What the sidebar computes on every redraw must not grow into a pause.
        await model.refreshOverview()
        XCTAssertGreaterThan(model.forge.count, 250)
        let started = Date()
        for _ in 0..<20 {
            let reasons = model.attentionByRepo
            _ = model.sidebarGroups(reasons)
            _ = model.pinnedRepos
        }
        let each = Date().timeIntervalSince(started) / 20 * 1000
        XCTAssertLessThan(each, 25, "sidebar data for 300 repositories took \(each) ms per redraw")
    }

    func testAnUnchangedAnswerRedrawsNothing() async throws {
        let app = try await CannedApp(repos: 8)
        defer { app.cleanUp() }
        let model = app.model
        let repo = try XCTUnwrap(model.repos.first)
        await model.refreshForge(repo, detailed: true)
        let pull = try XCTUnwrap(model.forgeState(repo).pulls.first)
        await model.loadExtras(pull, in: repo)
        await model.refreshLocal()
        await model.refreshInbox()

        // The same answers again: nothing a view reads may be written.
        nonisolated(unsafe) var changed = false
        withObservationTracking {
            _ = model.forge; _ = model.extras; _ = model.local; _ = model.repos; _ = model.inbox; _ = model.protections
        } onChange: { changed = true }
        await model.refreshForge(repo, detailed: true)
        await model.refreshForge(repo, detailed: false)
        await model.loadExtras(pull, in: repo)
        await model.refreshLocal()
        await model.refreshInbox()
        await model.loadRepos(quiet: true)
        XCTAssertFalse(changed, "an unchanged answer was published again: every such write redraws the sidebar and the repository")
    }

    func testTheSecondVisitAsksForNothing() async throws {
        let app = try await CannedApp(repos: 8)
        defer { app.cleanUp() }
        let model = app.model
        let repo = try XCTUnwrap(model.repos.first)
        await model.refreshForge(repo, detailed: true, ifOlderThan: 30)
        let before = CannedForge.totalHits
        await model.refreshForge(repo, detailed: true, ifOlderThan: 30)
        XCTAssertEqual(CannedForge.totalHits, before, "a fresh answer was asked for again")
        // Two views asking at once share one round.
        CannedForge.change { $0.latency = 0.05 }
        let other = model.repos[4]
        let asked = CannedForge.hits["repos/Lab/\(other.name)/pulls"] ?? 0
        async let a: Void = model.refreshForge(other, detailed: true)
        async let b: Void = model.refreshForge(other, detailed: true)
        _ = await (a, b)
        XCTAssertEqual((CannedForge.hits["repos/Lab/\(other.name)/pulls"] ?? 0) - asked, 2, "one round: the open and the newest closed")
    }

    func testRefusedTokenSaysSo() async throws {
        CannedForge.reset { $0.failing = ["user": 401] }
        let suite = "gnv-canned-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.session = CannedForge.session()
        do {
            try await model.connect(host: CannedForge.host, token: "wrong")
            XCTFail("a refused token connected")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server refused the access token.")
        }
        XCTAssertTrue(model.accounts.isEmpty)
    }

    func testTokenRevokedWhileWorkingKeepsTheList() async throws {
        let app = try await CannedApp(repos: 10)
        defer { app.cleanUp() }
        let model = app.model
        CannedForge.change { $0.failing = ["repos": 401, "orgs": 401, "user": 401] }
        await model.loadRepos(quiet: true)
        XCTAssertEqual(model.repos.count, 10, "the list must stay when the server starts refusing")
        XCTAssertNotNil(model.offline, "the user must be told the server refuses")
        let repo = try XCTUnwrap(model.repos.first { model.clone(of: $0) != nil })
        await model.refreshForge(repo, detailed: true)
        XCTAssertEqual(model.forgeState(repo).error, "The server refused the access token.")
        // The clone still works.
        XCTAssertNotNil(model.clone(of: repo))
        let commits = await model.commits(of: repo)
        XCTAssertFalse(commits.isEmpty)
    }

    func testServerErrorsAndGarbageDoNotLoseWhatWasRead() async throws {
        let app = try await CannedApp(repos: 6)
        defer { app.cleanUp() }
        let model = app.model
        let repo = model.repos[0]
        await model.refreshForge(repo, detailed: true)
        let pulls = model.forgeState(repo).pulls
        XCTAssertFalse(pulls.isEmpty)

        CannedForge.change { $0.failing = ["/pulls": 502] }
        await model.refreshForge(repo, detailed: true)
        XCTAssertEqual(model.forgeState(repo).pulls, pulls, "a failed refresh must keep the last answer")
        XCTAssertNotNil(model.forgeState(repo).error)

        CannedForge.change { $0.failing = [:]; $0.garbage = ["/pulls"] }
        await model.refreshForge(repo, detailed: true)
        XCTAssertEqual(model.forgeState(repo).pulls, pulls)
        XCTAssertEqual(model.forgeState(repo).error, "The server sent an answer the app does not understand.")

        CannedForge.change { $0.garbage = [] }
        await model.refreshForge(repo, detailed: true)
        XCTAssertNil(model.forgeState(repo).error, "the error must clear once the server answers again")
    }

    /// The lab's ingress answers 500 where Forgejo says 404 (no branch
    /// protection, no such file): the pull request must still show.
    func testMissingPartsAnsweredAsServerErrors() async throws {
        let app = try await CannedApp(repos: 4) { $0.failing = ["branch_protections": 500, "/reviews": 500, "/status": 500] }
        defer { app.cleanUp() }
        let model = app.model
        let repo = model.repos[0]
        await model.refreshForge(repo, detailed: true)
        let state = model.forgeState(repo)
        XCTAssertTrue(state.loaded)
        let pull = try XCTUnwrap(state.pulls.first)
        await model.loadExtras(pull, in: repo)
        let extra = try XCTUnwrap(model.extras[AppModel.extrasKey(try XCTUnwrap(model.slug(repo)), pull.number)])
        XCTAssertTrue(extra.loaded)
        XCTAssertFalse(extra.commits.isEmpty)
        XCTAssertFalse(extra.files.isEmpty)
    }

    func testReadingNeverWrites() async throws {
        let app = try await CannedApp(repos: 12)
        defer { app.cleanUp() }
        let model = app.model
        await model.refreshOverview()
        await model.warmUp()
        for repo in model.repos.prefix(4) {
            await model.refreshForge(repo, detailed: true)
            if let pull = model.forgeState(repo).pulls.first { await model.loadExtras(pull, in: repo) }
        }
        await model.refreshInbox()
        await model.refreshMyPulls()
        _ = await model.releaseCandidates()
        XCTAssertEqual(CannedForge.writes, [], "looking around changed something on the server")
        // Forgejo 16 answers an unpaged list of runs with every run there is.
        XCTAssertEqual(CannedForge.unpagedRunLists, 0, "a list of runs was asked for without a page")
    }

    /// To do is personal: someone else's broken merge and scheduled runs
    /// stay out of it.
    func testToDoIsPersonal() async throws {
        let app = try await CannedApp(repos: 6)
        defer { app.cleanUp() }
        let model = app.model
        for repo in model.repos { await model.refreshForge(repo, detailed: true) }
        for item in model.todo {
            guard case .repo(let repo, let reason) = item.action else { continue }
            if case .scheduledFailing = reason { XCTFail("a scheduled run is nobody's own step") }
            if case .failedMain = reason { XCTAssertTrue(model.startedByMe(model.defaultBranchRun(of: repo))) }
        }
        var run = try XCTUnwrap(model.forgeState(model.repos[0]).runs.first)
        run.triggerUser?.login = model.accounts.first?.login ?? ""
        XCTAssertTrue(model.startedByMe(run))
        run.triggerUser?.login = "someone-else"
        XCTAssertFalse(model.startedByMe(run))
        XCTAssertFalse(model.startedByMe(nil))
    }

    func testTokenPermissionsAreAskedWithoutChangingAnything() async throws {
        let app = try await CannedApp(repos: 2) { $0.failing = ["notifications": 403, "gitnest-view-probe/none/pulls": 403, "gitnest-view-probe/none/issues": 404] }
        defer { app.cleanUp() }
        let checks = await app.model.permissions(host: CannedForge.host)
        func answer(_ id: String) -> PermissionCheck.Answer? { checks.first { $0.id == id }?.answer }
        XCTAssertEqual(answer("repos"), .yes)
        XCTAssertEqual(answer("notes"), .no, "a refused read is red")
        XCTAssertEqual(answer("write-repo"), .no, "forbidden means the scope is missing")
        XCTAssertEqual(answer("write-issue"), .yes, "not found means the token was let through")
        XCTAssertEqual(answer("write-notes"), .no)
        XCTAssertEqual(checks.count, 8)
    }

    func testClonesGoUnderTheServersFolder() async throws {
        let app = try await CannedApp(repos: 2)
        defer { app.cleanUp() }
        let repo = app.model.repos[0]
        XCTAssertEqual(app.model.cloneDestination(repo), app.workdir.appending(path: CannedForge.host).appending(path: "Lab").appending(path: repo.name).path)
        // A folder already named after the server keeps its shape.
        let named = app.workdir.appending(path: CannedForge.host)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        app.model.setWorkdir(named)
        XCTAssertEqual(app.model.cloneDestination(repo), named.appending(path: "Lab").appending(path: repo.name).path)
    }

    func testBranchesComeFromTheServer() async throws {
        let app = try await CannedApp(repos: 2)
        defer { app.cleanUp() }
        let names = await app.model.serverBranches(app.model.repos[0])
        XCTAssertEqual(names, ["main", "develop", "feat/a", "feat/b"], "the default branch and develop lead the list")
    }

    func testClosedPullRequestsComeOnRequest() async throws {
        let app = try await CannedApp(repos: 4)
        defer { app.cleanUp() }
        let model = app.model
        let repo = model.repos[0]
        XCTAssertFalse(model.hasHistory(repo))
        await model.loadHistory(repo)
        XCTAssertTrue(model.hasHistory(repo))
        let before = CannedForge.totalHits
        await model.loadHistory(repo)
        XCTAssertEqual(CannedForge.totalHits, before, "the history is asked for once")
    }
}
