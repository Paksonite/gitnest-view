import XCTest
@testable import GitNestView

/// Against a real Jira Cloud site; skipped unless the environment names one:
/// GNV_JIRA_SITE, GNV_JIRA_EMAIL, GNV_JIRA_TOKEN. With GNV_JIRA_ISSUE (a
/// ticket that may be moved, e.g. a test ticket) the status is moved along
/// its workflow and back.
@MainActor
final class LiveJiraTests: XCTestCase {
    private func connected() async throws -> AppModel {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["GNV_JIRA_SITE"], let email = env["GNV_JIRA_EMAIL"], let token = env["GNV_JIRA_TOKEN"] else {
            throw XCTSkip("no Jira configured")
        }
        let suite = "gnv-jira-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        let name = try await model.connectJira(site: site, email: email, token: token)
        XCTAssertFalse(name.isEmpty)
        return model
    }

    func testConnectsAndReadsTickets() async throws {
        let model = try await connected()
        XCTAssertTrue(model.jira.loaded)
        XCTAssertNil(model.jira.error)
        // Whatever is assigned, none of the default list is finished.
        XCTAssertFalse(model.jira.issues.contains { $0.done })
        await model.setJiraFilter("assignee = currentUser() ORDER BY updated DESC")
        XCTAssertNil(model.jira.error, "a filter of the user's own must be accepted")
        await model.setJiraFilter("this is not jql (")
        XCTAssertNotNil(model.jira.error, "a broken filter must be told, not swallowed")
    }

    func testWrongTokenIsRefused() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["GNV_JIRA_SITE"], let email = env["GNV_JIRA_EMAIL"] else { throw XCTSkip("no Jira configured") }
        let suite = "gnv-jira-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        do {
            try await model.connectJira(site: site, email: email, token: "not-a-token")
            XCTFail("a wrong token connected")
        } catch {}
        XCTAssertNil(model.jiraSettings)
    }

    /// The ticket window's reads and writes on a test ticket; what the test
    /// adds, it removes again.
    func testTicketDetailsCommentAndTime() async throws {
        guard let key = ProcessInfo.processInfo.environment["GNV_JIRA_ISSUE"] else { throw XCTSkip("GNV_JIRA_ISSUE is not set") }
        let env = ProcessInfo.processInfo.environment
        let model = try await connected()
        let client = JiraClient(site: try XCTUnwrap(JiraClient.siteURL(env["GNV_JIRA_SITE"] ?? "")), email: env["GNV_JIRA_EMAIL"] ?? "", token: env["GNV_JIRA_TOKEN"] ?? "")
        let before = try await model.ticket(key)
        XCTAssertEqual(before.key, key)
        XCTAssertFalse(before.summary.isEmpty)
        XCTAssertFalse(before.status.isEmpty)
        XCTAssertNotNil(before.statusChangedBy, "the last status change names who did it")
        let priorities = await model.jiraPriorities()
        XCTAssertFalse(priorities.isEmpty)

        let text = "GitNest View test \(Int(Date().timeIntervalSince1970))\nsecond line\n\nnew paragraph"
        let refusedComment = await model.jira("Commented") { try await $0.addComment(key, text: text) }
        XCTAssertNil(refusedComment)
        var now = try await model.ticket(key)
        let added = try XCTUnwrap(now.comments.last)
        XCTAssertEqual(added.body, text, "a comment comes back as it was written, line breaks kept")
        try await client.remove(comment: added.id, of: key)

        let refusedTime = await model.jira("Logged") { try await $0.logWork(key, timeSpent: "1m", note: "GitNest View test") }
        if let refusedTime {
            // Time tracking may be off in a project: Jira must say so in words.
            XCTAssertFalse(refusedTime.isEmpty)
        } else {
            now = try await model.ticket(key)
            let log = try XCTUnwrap(now.worklogs.last)
            XCTAssertEqual(log.timeSpent, "1m")
            XCTAssertGreaterThanOrEqual(now.spentSeconds, before.spentSeconds + 60)
            try await client.remove(worklog: log.id, of: key)
        }

        // A change Jira refuses comes back with Jira's reason, not a silent failure.
        let refused = await model.jira("Moved") { try await $0.moveTicket(key, transition: "999999") }
        XCTAssertNotNil(refused)
        let after = try await model.ticket(key)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.comments.count, before.comments.count, "the test's comment was removed again")
    }

    func testMovesATicketAndBack() async throws {
        guard let key = ProcessInfo.processInfo.environment["GNV_JIRA_ISSUE"] else { throw XCTSkip("GNV_JIRA_ISSUE is not set") }
        let model = try await connected()
        await model.setJiraFilter("key = \(key)")
        let issue = try XCTUnwrap(model.jira.issues.first, model.jira.error ?? "the ticket was not found")
        let original = issue.fields.status.name
        let moves = await model.transitions(for: issue)
        let forward = try XCTUnwrap(moves.first, "the ticket cannot move anywhere")
        await model.move(issue, by: forward)
        let moved = try XCTUnwrap(model.jira.issues.first)
        XCTAssertEqual(moved.fields.status.name, forward.to?.name, model.toasts.map(\.text).joined(separator: "; "))

        // And back where it was, when the workflow allows it.
        let back = await model.transitions(for: moved)
        if let home = back.first(where: { $0.to?.name == original }) {
            await model.move(moved, by: home)
            XCTAssertEqual(model.jira.issues.first?.fields.status.name, original)
        } else {
            XCTFail("\(key) is now \(moved.fields.status.name); no way back to \(original): \(back.map { $0.to?.name ?? $0.name })")
        }
    }
}
