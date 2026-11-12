import XCTest
@testable import GitNestView

/// What the user does on a pull request, and Jira, on the canned servers.
@MainActor
final class CollabTests: XCTestCase {
    func testDraftTitles() {
        XCTAssertEqual(AppModel.draftTitle("feat: x", draft: true), "WIP: feat: x")
        XCTAssertEqual(AppModel.draftTitle("WIP: feat: x", draft: true), "WIP: feat: x")
        XCTAssertEqual(AppModel.draftTitle("WIP: feat: x", draft: false), "feat: x")
        XCTAssertEqual(AppModel.draftTitle("[wip] feat: x", draft: false), "feat: x")
        XCTAssertEqual(AppModel.draftTitle("Draft: feat: x", draft: false), "feat: x")
    }

    private func issue(_ key: String, comments: Int = 0, lastBy: String? = nil, created: String? = nil) throws -> JiraIssue {
        let last = lastBy.map { #","comments":[{"id":"1","author":{"accountId":"\#($0)","displayName":"Ann"}}]"# } ?? ""
        let json = #"{"id":"1","key":"\#(key)","fields":{"summary":"S \#(key)","status":{"name":"To Do","statusCategory":{"key":"new"}},"comment":{"total":\#(comments)\#(last)}\#(created.map { #","created":"\#($0)""# } ?? "")}}"#
        return try JSONDecoder().decode(JiraIssue.self, from: Data(json.utf8))
    }

    func testJiraNewsIsOnlyWhatOthersDid() throws {
        let a = try issue("A-1"), b = try issue("B-2", comments: 1, lastBy: "other")
        // The first look only remembers.
        XCTAssertEqual(JiraWatch.events(old: nil, now: [a, b], me: "me"), [])
        let seen = JiraWatch.snapshot([a, b])
        XCTAssertEqual(JiraWatch.events(old: seen, now: [a, b], me: "me"), [], "nothing changed, nothing to say")

        // A ticket appears: assigned; made within the hour: new.
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        let fresh = try issue("C-3", created: formatter.string(from: now.addingTimeInterval(-120)))
        let old = try issue("D-4", created: formatter.string(from: now.addingTimeInterval(-86400 * 30)))
        XCTAssertEqual(JiraWatch.events(old: seen, now: [a, b, fresh, old], me: "me", at: now),
                       [.assigned(key: "C-3", summary: "S C-3", new: true), .assigned(key: "D-4", summary: "S D-4", new: false)])

        // Someone else's comment is news; the user's own is not.
        XCTAssertEqual(JiraWatch.events(old: seen, now: [try issue("A-1", comments: 1, lastBy: "other"), b], me: "me"),
                       [.commented(key: "A-1", summary: "S A-1", by: "Ann")])
        XCTAssertEqual(JiraWatch.events(old: seen, now: [try issue("A-1", comments: 1, lastBy: "me"), b], me: "me"), [])

        // A ticket leaves the list: looked at again (closed by whom?).
        XCTAssertEqual(JiraWatch.events(old: seen, now: [a], me: "me"), [.gone(key: "B-2")])
    }

    /// What changed among the tickets reaches the notification centre, named for Jira.
    func testJiraNewsIsPosted() async throws {
        let app = try await CannedApp(repos: 2)
        defer { app.cleanUp() }
        let model = app.model
        nonisolated(unsafe) var posted: [(String, String, String?)] = []
        Notifier.shared.deliver = { request in
            posted.append((request.content.title, request.content.subtitle, request.content.userInfo["jira"] as? String))
        }
        defer { Notifier.shared.deliver = nil }
        _ = try await model.connectJira(site: CannedForge.jiraHost, email: "me@example.test", token: "good")
        XCTAssertTrue(posted.isEmpty, "the first look only remembers")

        // The next look finds a ticket that was not there: assigned.
        model.defaults.set(try JSONEncoder().encode(["INFRA-80": JiraWatch.Seen(status: "To Do", comments: 0)]), forKey: "jiraSeen")
        await model.refreshJira()
        XCTAssertEqual(posted.map(\.0), ["Assigned to you · INFRA-77"])
        XCTAssertEqual(posted.first?.1, "Jira")
        XCTAssertEqual(posted.first?.2, "INFRA-77", "a click opens that ticket")

        // Switched off: nothing is posted, the state is still remembered.
        posted.removeAll()
        model.notifyJira = false
        model.defaults.removeObject(forKey: "jiraSeen")
        model.defaults.set(try JSONEncoder().encode([String: JiraWatch.Seen]()), forKey: "jiraSeen")
        await model.refreshJira()
        XCTAssertTrue(posted.isEmpty)
    }

    func testJiraTextBothWays() {
        XCTAssertEqual(JiraTicket.plain("<p>one<br/>two</p><ul><li>a &amp; b</li><li>c</li></ul><p>&lt;tag&gt;</p>"), "one\ntwo\n\n• a & b\n• c\n<tag>")
        XCTAssertEqual(JiraTicket.plain(nil), "")
        let document = JiraTicket.document("first\n\nthird")
        let content = document["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 2, "a blank line starts a new paragraph")
        let lines = JiraTicket.document("a\nb")["content"] as? [[String: Any]]
        XCTAssertEqual((lines?.first?["content"] as? [[String: Any]])?.map { $0["type"] as? String }, ["text", "hardBreak", "text"])
        XCTAssertNotNil(JiraTicket.date("2026-11-11T19:19:16.211+0100"))
    }

    func testTicketFromJiraJSON() throws {
        let json = #"""
        {"key":"X-1","fields":{"summary":"Sum","status":{"name":"W toku","statusCategory":{"key":"indeterminate"}},"issuetype":{"name":"Task"},
          "project":{"name":"Proj"},"assignee":{"displayName":"Me","accountId":"me"},"labels":["a","b"],"duedate":"2026-12-01",
          "timetracking":{"originalEstimate":"4h","timeSpent":"1h","remainingEstimate":"3h","originalEstimateSeconds":14400,"timeSpentSeconds":3600},
          "comment":{"comments":[{"id":"7","author":{"displayName":"Ann","accountId":"ann"},"created":"2026-11-11T10:00:00.000+0100"}]},
          "worklog":{"worklogs":[{"id":"9","author":{"displayName":"Me"},"timeSpent":"1h"}]}},
         "renderedFields":{"description":"<p>Hello</p>","comment":{"comments":[{"body":"<p>Why?</p>"}]}},
         "changelog":{"histories":[{"author":{"displayName":"Bob","accountId":"bob"},"created":"2026-11-11T12:00:00.000+0100","items":[{"field":"status","toString":"W toku"}]}]}}
        """#
        let ticket = try XCTUnwrap(JiraTicket(json: try JSONSerialization.jsonObject(with: Data(json.utf8))))
        XCTAssertEqual(ticket.summary, "Sum")
        XCTAssertEqual(ticket.description, "Hello")
        XCTAssertEqual(ticket.comments.map(\.body), ["Why?"])
        XCTAssertEqual(ticket.estimate, "4h")
        XCTAssertEqual(ticket.spentSeconds, 3600)
        XCTAssertEqual(ticket.worklogs.first?.timeSpent, "1h")
        XCTAssertEqual(ticket.statusChangedBy, "Bob")
        XCTAssertFalse(ticket.done)
        XCTAssertNil(JiraTicket(json: ["nothing": 1]))
    }

    func testNotificationNumber() throws {
        let json = #"{"id":1,"unread":true,"subject":{"title":"t","type":"Pull","html_url":"https://f/o/r/pulls/12#issuecomment-5"},"repository":{"full_name":"o/r"}}"#
        let item = try ForgejoClient.decoder.decode(ForgeNotification.self, from: Data(json.utf8))
        XCTAssertEqual(item.number, 12)
        XCTAssertEqual(item.repository?.fullName, "o/r")
    }

    func testReviewCommentContext() throws {
        let json = #"{"id":1,"body":"why?","path":"main.tf","diff_hunk":"@@ -1,3 +1,4 @@\n a\n b\n-c\n+d\n+e"}"#
        let comment = try ForgejoClient.decoder.decode(ReviewComment.self, from: Data(json.utf8))
        XCTAssertEqual(comment.context, [" b", "-c", "+d", "+e"])
    }

    /// Every change goes to the server as one request, and only when asked.
    func testChangesAreSentOnlyOnRequest() async throws {
        let app = try await CannedApp(repos: 4)
        defer { app.cleanUp() }
        let model = app.model
        let repo = model.repos[0]
        await model.refreshForge(repo, detailed: true)
        let pull = try XCTUnwrap(model.forgeState(repo).pulls.first)
        await model.loadExtras(pull, in: repo)
        XCTAssertEqual(CannedForge.writes, [])

        let base = "repos/Lab/\(repo.name)"
        let empty = await model.comment(on: pull, in: repo, text: "   ")
        XCTAssertFalse(empty, "an empty comment is not sent")
        XCTAssertEqual(CannedForge.writes, [])
        let sent = await model.comment(on: pull, in: repo, text: "Looks right.")
        XCTAssertTrue(sent)
        await model.setDraft(true, pull, in: repo)
        await model.updateBranch(of: pull, in: repo, rebase: false)
        await model.setOpen(false, pull, in: repo)
        await model.requestReview(of: pull, in: repo, from: ForgeUser(id: 9, login: "someone"))
        await model.requestReview(of: pull, in: repo, from: ForgeUser(id: 9, login: "someone"), withdraw: true)
        await model.setLabels([3, 4], on: pull, in: repo)
        XCTAssertEqual(CannedForge.writes, [
            "POST \(base)/issues/\(pull.number)/comments", "PATCH \(base)/pulls/\(pull.number)", "POST \(base)/pulls/\(pull.number)/update",
            "PATCH \(base)/pulls/\(pull.number)", "POST \(base)/pulls/\(pull.number)/requested_reviewers",
            "DELETE \(base)/pulls/\(pull.number)/requested_reviewers", "PUT \(base)/issues/\(pull.number)/labels",
        ])
    }

    func testAServerThatRefusesAChangeSaysSo() async throws {
        let app = try await CannedApp(repos: 4)
        defer { app.cleanUp() }
        let model = app.model
        let repo = model.repos[0]
        await model.refreshForge(repo, detailed: true)
        let pull = try XCTUnwrap(model.forgeState(repo).pulls.first)
        CannedForge.change { $0.failing = ["/comments": 403] }
        let sent = await model.comment(on: pull, in: repo, text: "hello")
        XCTAssertFalse(sent)
        XCTAssertTrue(model.toasts.contains { $0.kind == .error }, "a refused change must be told")
    }

    func testJiraIsOptionalAndReadOnly() async throws {
        let app = try await CannedApp(repos: 4)
        defer { app.cleanUp() }
        let model = app.model
        XCTAssertNil(model.jiraSettings, "Jira is off until connected")
        await model.refreshJira()
        XCTAssertFalse(CannedForge.hits.keys.contains { $0.hasPrefix("jira:") }, "nothing is asked of Jira before it is connected")

        do {
            try await model.connectJira(site: CannedForge.jiraHost, email: "me@example.test", token: "wrong")
            XCTFail("a wrong token connected")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Jira refused the e-mail and API token.")
        }
        XCTAssertNil(model.jiraSettings)

        let name = try await model.connectJira(site: "https://\(CannedForge.jiraHost)/", email: "me@example.test", token: "good")
        XCTAssertEqual(name, "Test User")
        XCTAssertEqual(model.jira.issues.map(\.key), ["INFRA-77", "INFRA-80"], "tickets in progress come first")
        XCTAssertEqual(model.jiraURL(model.jira.issues[0])?.absoluteString, "https://jira.example.test/browse/INFRA-77")
        XCTAssertEqual(CannedForge.writes, [], "Jira is only read")

        // A ticket in progress with nothing started for it is a step in To do.
        XCTAssertTrue(model.todo.contains { if case .ticket(let issue) = $0.action { return issue.key == "INFRA-77" } else { return false } })
        XCTAssertFalse(model.todo.contains { if case .ticket(let issue) = $0.action { return issue.key == "INFRA-80" } else { return false } },
                       "a ticket not started is backlog, not a step")

        // The status moves only when the user chooses where to.
        let moves = await model.transitions(for: model.jira.issues[0])
        XCTAssertEqual(moves.map { $0.to?.name }, ["Done", "To Do"])
        await model.move(model.jira.issues[0], by: moves[0])
        XCTAssertEqual(CannedForge.writes, ["JIRA POST /rest/api/3/issue/INFRA-77/transitions"])
        CannedForge.change { $0.writes = [] }

        // The user's own filter replaces the default.
        await model.setJiraFilter("project = X")
        XCTAssertEqual(model.jiraSettings?.filter, "project = X")
        await model.setJiraFilter("  ")
        XCTAssertNil(model.jiraSettings?.filter)

        model.disconnectJira()
        XCTAssertNil(model.jiraSettings)
        XCTAssertTrue(model.jira.issues.isEmpty)
    }
}
