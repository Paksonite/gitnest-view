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

    /// Hands the ticket to nobody and back: the assignee picker's two calls.
    func testAssignablePeopleAndReassign() async throws {
        guard let key = ProcessInfo.processInfo.environment["GNV_JIRA_ISSUE"] else { throw XCTSkip("GNV_JIRA_ISSUE is not set") }
        let model = try await connected()
        let before = try await model.ticket(key)
        let me = try XCTUnwrap(model.jiraAccountID, "reading a ticket learns who the user is")
        let people = await model.jiraAssignable(key, query: "")
        XCTAssertFalse(people.isEmpty, "someone can take the ticket")
        XCTAssertTrue(people.allSatisfy { !$0.displayName.isEmpty })
        let unassign = await model.jira("Unassigned") { try await $0.assign(key, to: nil) }
        XCTAssertNil(unassign)
        let nobody = try await model.ticket(key)
        XCTAssertNil(nobody.assignee)
        let back = await model.jira("Back") { try await $0.assign(key, to: before.assigneeID ?? me) }
        XCTAssertNil(back)
        let after = try await model.ticket(key)
        XCTAssertEqual(after.assigneeID, before.assigneeID ?? me)
    }

    /// A raw call for what the app itself never does (making a link).
    private func raw(_ method: String, _ path: String, body: Any? = nil) async throws -> Any? {
        let env = ProcessInfo.processInfo.environment
        let site = try XCTUnwrap(JiraClient.siteURL(env["GNV_JIRA_SITE"] ?? ""))
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var components = try XCTUnwrap(URLComponents(url: site.appending(path: parts[0]), resolvingAgainstBaseURL: false))
        if parts.count > 1 { components.query = parts[1] }
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.httpMethod = method
        request.setValue("Basic " + Data("\(env["GNV_JIRA_EMAIL"] ?? ""):\(env["GNV_JIRA_TOKEN"] ?? "")".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue((200..<300).contains(code), "\(method) \(path): HTTP \(code) \(String(decoding: data, as: UTF8.self))")
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }

    func testBlockerLinkWatchersAndAvatars() async throws {
        guard let key = ProcessInfo.processInfo.environment["GNV_JIRA_ISSUE"] else { throw XCTSkip("GNV_JIRA_ISSUE is not set") }
        let model = try await connected()
        let project = String(key.split(separator: "-").first ?? "")
        await model.setJiraFilter("project = \(project) AND key != \(key) ORDER BY created ASC")
        let other = try XCTUnwrap(model.jira.issues.first?.key, "the project needs a second ticket")

        // The other ticket blocks this one (Jira: the inward ticket is the
        // one the outward words apply to); the link goes away at the end.
        _ = try await raw("POST", "rest/api/3/issueLink", body: ["type": ["name": "Blocks"], "inwardIssue": ["key": other], "outwardIssue": ["key": key]])
        let ticket = try await model.ticket(key)
        let link = try XCTUnwrap(ticket.links.first { $0.key == other }, "the link is read back: \(ticket.links)")
        XCTAssertEqual(link.relation, "is blocked by")
        XCTAssertFalse(link.summary.isEmpty)
        let fields = try await raw("GET", "rest/api/3/issue/\(key)?fields=issuelinks") as? [String: Any]
        for item in (fields?["fields"] as? [String: Any])?["issuelinks"] as? [[String: Any]] ?? []
        where ((item["outwardIssue"] ?? item["inwardIssue"]) as? [String: Any])?["key"] as? String == other {
            if let id = item["id"] as? String { _ = try await raw("DELETE", "rest/api/3/issueLink/\(id)") }
        }
        let unlinked = try await model.ticket(key)
        XCTAssertFalse(unlinked.links.contains { $0.key == other })

        // Watching: off and on again, ending where it started.
        let me = try XCTUnwrap(model.jiraAccountID)
        let wasWatching = ticket.watching
        let first = await model.jira("toggle") { wasWatching ? try await $0.unwatch(key, accountID: me) : try await $0.watch(key, accountID: me) }
        XCTAssertNil(first)
        let toggled = try await model.ticket(key)
        XCTAssertEqual(toggled.watching, !wasWatching)
        XCTAssertEqual(toggled.watchers.contains { $0.accountID == me }, !wasWatching)
        let second = await model.jira("back") { wasWatching ? try await $0.watch(key, accountID: me) : try await $0.unwatch(key, accountID: me) }
        XCTAssertNil(second)
        let restored = try await model.ticket(key)
        XCTAssertEqual(restored.watching, wasWatching)
        XCTAssertTrue(restored.watchers.allSatisfy { !$0.name.isEmpty })
        // Jira's generated initials are no picture; only a chosen one becomes an avatar URL.
        XCTAssertFalse(restored.watchers.contains { $0.avatar?.absoluteString.contains("/initials/") == true })
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
