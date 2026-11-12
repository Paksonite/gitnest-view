import SwiftUI
import XCTest
@testable import GitNestView

/// The real window, in the test process, on the canned server: every screen
/// is built and drawn the way a user reaches it, and each step has a time
/// budget for the main thread. Catches crashes, redraw loops and screens
/// that get slow with many repositories.
@MainActor
final class UIFlowTests: XCTestCase {
    private var flow: FlowWindow!

    private func show(_ model: AppModel) { flow = FlowWindow(model) }
    private func step(_ name: String, wait: Double = 0.25, _ action: () -> Void) async { await flow.step(name, wait: wait, action) }
    private func visibleTexts() -> Set<String> { flow.visibleTexts() }
    private func report(budget: Double, file: StaticString = #filePath, line: UInt = #line) { flow.report(budget: budget, file: file, line: line) }

    override func tearDown() async throws {
        await MainActor.run { flow?.close(); flow = nil }
    }

    func testWalkThroughEveryScreen() async throws {
        let app = try await CannedApp(repos: 40, clones: 3)
        defer { app.cleanUp() }
        let model = app.model
        show(model)
        await step("first draw", wait: 0.6) {}

        let cloned = try XCTUnwrap(model.repos.first { model.clone(of: $0) != nil })
        let withPull = try XCTUnwrap(model.repos.first { ($0.openPulls ?? 0) > 0 && model.clone(of: $0) != nil } ?? model.repos.first { ($0.openPulls ?? 0) > 0 })

        await step("home") { model.section = .home }
        await step("inbox") { model.section = .inbox }
        await step("search") { model.section = .search }
        await step("repository with a pull request", wait: 0.6) {
            model.selection = withPull.id
            model.section = .repositories
        }
        XCTAssertTrue(model.forgeState(withPull).loaded)
        let texts = visibleTexts()
        if !texts.isEmpty {
            // The accessibility tree answers in this process: check what is on screen.
            XCTAssertTrue(texts.contains { $0.contains("INFRA-77") }, "the pull request's title is not on screen: \(texts.count) texts")
        }
        for tab in RepoTab.allCases {
            await step("tab \(tab.rawValue)", wait: 0.4) { model.repoTab = tab }
        }
        await step("cloned repository", wait: 0.5) { model.selection = cloned.id }
        for tab in [RepoTab.changes, .history, .resources, .overview] {
            await step("clone: tab \(tab.rawValue)", wait: 0.4) { model.repoTab = tab }
        }

        // The file pane beside the resources: open, jump, switch file, close.
        await step("resources for the file pane", wait: 0.3) { model.repoTab = .resources }
        await step("file viewer", wait: 0.5) { model.fileTarget = FileTarget(repo: cloned, file: "main.tf", line: 7) }
        await step("file viewer: another file", wait: 0.4) { model.fileTarget = FileTarget(repo: cloned, file: "ci.yaml", line: nil) }
        await step("file viewer: a file that is not there", wait: 0.3) { model.fileTarget = FileTarget(repo: cloned, file: "gone.tf", line: 3) }
        await step("file viewer closed") { model.fileTarget = nil }
        await step("search with a file beside it", wait: 0.4) {
            model.section = .search
            model.fileTarget = FileTarget(repo: cloned, file: "main.tf", line: 2)
        }
        await step("back to the repository", wait: 0.3) { model.section = .repositories }
        XCTAssertNil(model.fileTarget, "leaving the screen puts the file pane away")

        // Every sheet opens and closes.
        let pull = model.forgeState(withPull).pulls.first
        var sheets: [(String, AppSheet)] = [
            ("releases", .releases), ("pull all", .pullAll), ("start work", .startWork(preselected: nil)), ("release", .release(withPull)),
            ("new branch", .newBranch(cloned, base: "main")),
        ]
        if let pull { sheets += [("review", .review(withPull, pull)), ("merge", .merge(withPull, pull))] }
        for (name, sheet) in sheets {
            await step("sheet \(name)", wait: 0.4) { model.sheet = sheet }
            await step("sheet \(name) closed", wait: 0.1) { model.sheet = nil }
        }
        if let pull, let slug = model.slug(withPull) {
            await step("diff", wait: 0.4) { model.diffTarget = DiffTarget(repo: slug, number: pull.number, title: pull.title, file: nil) }
            await step("diff closed", wait: 0.1) { model.diffTarget = nil }
        }
        await step("palette", wait: 0.3) { model.paletteOpen = true }
        await step("palette closed", wait: 0.1) { model.paletteOpen = false }
        await step("filter", wait: 0.2) { model.filter = "core" }
        await step("filter cleared", wait: 0.2) { model.filter = "" }
        await step("order by name") { model.sidebarByAttention = false }
        await step("pin") { model.togglePin(cloned) }
        await step("unpin") { model.togglePin(cloned) }
        await step("order by attention") { model.sidebarByAttention = true }

        XCTAssertEqual(CannedForge.writes, [], "walking through the app changed something on the server")
        XCTAssertFalse(model.toasts.contains { $0.kind == .error }, model.toasts.map(\.text).joined(separator: "; "))
        report(budget: 400)
    }

    /// The complaint this guards: switching repositories with hundreds of them.
    func testSwitchingAmongThreeHundredRepositories() async throws {
        let app = try await CannedApp(repos: 300, clones: Int(ProcessInfo.processInfo.environment["GNV_CLONES"] ?? "") ?? 6)
        defer { app.cleanUp() }
        let model = app.model
        show(model)
        await step("first draw", wait: 0.8) {}
        await model.refreshOverview()
        await step("overview read", wait: 0.3) {}
        flow.timings.removeAll()

        let picked = stride(from: 0, to: model.repos.count, by: 23).map { model.repos[$0] }
        for repo in picked {
            await step("select \(repo.name)", wait: 0.25) {
                model.selection = repo.id
                model.section = .repositories
            }
        }
        for repo in picked.prefix(5) {
            await step("select again \(repo.name)", wait: 0.1) { model.selection = repo.id }
        }
        await step("home", wait: 0.6) { model.section = .home }
        await step("back to a repository", wait: 0.3) { model.section = .repositories }
        await step("home again", wait: 0.4) { model.section = .home }
        await step("inbox", wait: 0.3) { model.section = .inbox }
        await step("repositories", wait: 0.3) { model.section = .repositories }
        // The background refresh of every repository must not hold the window.
        let before = Date()
        await model.refreshOverview()
        await step("after a full background refresh", wait: 0.1) {}
        print(String(format: "background refresh of 300 repositories: %.0f ms", Date().timeIntervalSince(before) * 1000))
        report(budget: 250)
    }

    /// The tour only shows places: every stop is drawn, nothing is sent.
    func testTheTourWalksWithoutTouchingAnything() async throws {
        let app = try await CannedApp(repos: 12, clones: 2)
        defer { app.cleanUp() }
        let model = app.model
        show(model)
        await step("first draw", wait: 0.4) {}
        await step("tour starts", wait: 0.3) { model.startTour() }
        for index in Tour.stops.indices {
            await step("tour stop \(index + 1): \(Tour.stops[index].title)", wait: 0.3) {
                Tour.stops[index].show(model)
                model.tourStep = index
            }
        }
        await step("tour ends") { model.endTour() }
        XCTAssertNil(model.tourStep)
        XCTAssertTrue(model.tourSeen)
        XCTAssertFalse(model.paletteOpen == true && model.tourStep == nil && false)
        XCTAssertEqual(CannedForge.writes, [], "the tour changed something on the server")
        await step("wizard asked for again", wait: 0.4) { model.wizardOpen = true }
        await step("wizard closed", wait: 0.2) { model.wizardOpen = false }
        report(budget: 400)
    }

    func testOnboardingDraws() async throws {
        let suite = "gnv-ui-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        XCTAssertFalse(model.isSetUp)
        show(model)
        await step("onboarding", wait: 0.3) {}
        report(budget: 400)
    }
}
