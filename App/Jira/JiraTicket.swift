import Foundation

/// One ticket as Jira's own page shows it: what it is, where it stands,
/// who has it, the time, the conversation.
struct JiraTicket: Equatable, Sendable {
    struct Comment: Identifiable, Equatable, Sendable {
        var id: String
        var author: String
        var authorID: String?
        var body: String
        var created: Date?
    }

    struct Worklog: Identifiable, Equatable, Sendable {
        var id: String
        var author: String
        var timeSpent: String
        var started: Date?
    }

    var key: String
    var summary: String
    var status: String
    var statusCategory: String // new, indeterminate, done
    var type: String
    var project: String
    var priority: String?
    var assignee: String?
    var assigneeID: String?
    var reporter: String?
    var description: String
    var labels: [String]
    var due: String?
    var parent: String?
    var created: Date?
    var updated: Date?
    var estimate: String?
    var remaining: String?
    var spent: String?
    var estimateSeconds: Int
    var spentSeconds: Int
    var comments: [Comment]
    var worklogs: [Worklog]
    /// Who last changed the status, and when.
    var statusChangedBy: String?
    var statusChangedByID: String?
    var statusChangedAt: Date?

    var done: Bool { statusCategory == "done" }

    /// Jira's "2026-11-11T19:19:16.211+0100".
    static func date(_ text: Any?) -> Date? {
        guard let text = text as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Jira renders rich text as HTML; the app shows its words.
    static func plain(_ html: Any?) -> String {
        guard var text = html as? String else { return "" }
        // Line breaks in the HTML source mean nothing; only its tags do.
        text = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        for (pattern, with) in [("<br\\s*/?>", "\n"), ("</p>", "\n\n"), ("</div>|</h[1-6]>|</li>|</tr>", "\n"), ("<li[^>]*>", "• "), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
        }
        for (entity, with) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: with)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text as Jira's document format: a blank line starts a new
    /// paragraph, a single line break stays a line break.
    static func document(_ text: String) -> [String: Any] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let paragraphs = blocks.map { block -> [String: Any] in
            var content: [[String: Any]] = []
            for (index, line) in block.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                if index > 0 { content.append(["type": "hardBreak"]) }
                content.append(["type": "text", "text": String(line)])
            }
            return ["type": "paragraph", "content": content]
        }
        return ["type": "doc", "version": 1, "content": paragraphs]
    }

    init?(json: Any) {
        guard let root = json as? [String: Any], let key = root["key"] as? String, let fields = root["fields"] as? [String: Any] else { return nil }
        let rendered = root["renderedFields"] as? [String: Any] ?? [:]
        func name(_ field: String, _ part: String = "name") -> String? { (fields[field] as? [String: Any])?[part] as? String }
        self.key = key
        summary = fields["summary"] as? String ?? ""
        status = name("status") ?? ""
        statusCategory = ((fields["status"] as? [String: Any])?["statusCategory"] as? [String: Any])?["key"] as? String ?? ""
        type = name("issuetype") ?? ""
        project = name("project") ?? ""
        priority = name("priority")
        assignee = name("assignee", "displayName")
        assigneeID = name("assignee", "accountId")
        reporter = name("reporter", "displayName")
        description = Self.plain(rendered["description"])
        labels = fields["labels"] as? [String] ?? []
        due = fields["duedate"] as? String
        parent = name("parent", "key")
        created = Self.date(fields["created"])
        updated = Self.date(fields["updated"])
        let time = fields["timetracking"] as? [String: Any] ?? [:]
        estimate = time["originalEstimate"] as? String
        remaining = time["remainingEstimate"] as? String
        spent = time["timeSpent"] as? String
        estimateSeconds = time["originalEstimateSeconds"] as? Int ?? 0
        spentSeconds = time["timeSpentSeconds"] as? Int ?? 0
        let raw = (fields["comment"] as? [String: Any])?["comments"] as? [[String: Any]] ?? []
        let shown = ((rendered["comment"] as? [String: Any])?["comments"] as? [[String: Any]]) ?? []
        comments = raw.enumerated().map { index, item in
            let author = item["author"] as? [String: Any]
            return Comment(id: item["id"] as? String ?? "\(index)", author: author?["displayName"] as? String ?? "someone",
                           authorID: author?["accountId"] as? String,
                           body: Self.plain(index < shown.count ? shown[index]["body"] : nil), created: Self.date(item["created"]))
        }
        let logs = (fields["worklog"] as? [String: Any])?["worklogs"] as? [[String: Any]] ?? []
        worklogs = logs.enumerated().map { index, item in
            Worklog(id: item["id"] as? String ?? "\(index)", author: (item["author"] as? [String: Any])?["displayName"] as? String ?? "someone",
                    timeSpent: item["timeSpent"] as? String ?? "", started: Self.date(item["started"]))
        }
        // Newest first in Jira's answer: the first entry that changed the status.
        let histories = (root["changelog"] as? [String: Any])?["histories"] as? [[String: Any]] ?? []
        if let change = histories.first(where: { ($0["items"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == "status" } }) {
            let author = change["author"] as? [String: Any]
            statusChangedBy = author?["displayName"] as? String
            statusChangedByID = author?["accountId"] as? String
            statusChangedAt = Self.date(change["created"])
        }
    }
}

extension JiraClient {
    private func call(_ method: String, _ path: String, json: Any? = nil, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: site.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw JiraError.notAnswer }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic " + Data("\(email):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw JiraError.notAnswer }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw JiraError.refused
        case 404: throw JiraError.notFound
        default:
            // Jira explains: {"errorMessages": ["…"], "errors": {"field": "…"}}.
            if let said = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let messages = (said["errorMessages"] as? [String] ?? []) + ((said["errors"] as? [String: Any]) ?? [:]).values.compactMap { $0 as? String }
                if !messages.isEmpty { throw JiraError.rejected(messages.joined(separator: " ")) }
            }
            throw JiraError.http(http.statusCode)
        }
    }

    func ticket(_ key: String) async throws -> JiraTicket {
        let data = try await call("GET", "rest/api/3/issue/\(key)", query: [
            .init(name: "expand", value: "renderedFields,changelog"),
            .init(name: "fields", value: "summary,status,issuetype,priority,assignee,reporter,description,timetracking,labels,created,updated,duedate,parent,project,comment,worklog"),
        ])
        guard let ticket = JiraTicket(json: (try? JSONSerialization.jsonObject(with: data)) as Any) else { throw JiraError.notAnswer }
        return ticket
    }

    func myAccountID() async throws -> String {
        struct Me: Decodable { var accountId: String }
        let me: Me = try await get("rest/api/3/myself")
        return me.accountId
    }

    /// Moves a ticket along its workflow; Jira's reason comes back when it refuses.
    func moveTicket(_ key: String, transition id: String) async throws {
        _ = try await call("POST", "rest/api/3/issue/\(key)/transitions", json: ["transition": ["id": id]])
    }

    func addComment(_ key: String, text: String) async throws {
        _ = try await call("POST", "rest/api/3/issue/\(key)/comment", json: ["body": JiraTicket.document(text)])
    }

    /// "1h 30m", "45m", "2d": Jira's own way of writing time.
    func logWork(_ key: String, timeSpent: String, note: String) async throws {
        var body: [String: Any] = ["timeSpent": timeSpent]
        if !note.isEmpty { body["comment"] = JiraTicket.document(note) }
        _ = try await call("POST", "rest/api/3/issue/\(key)/worklog", json: body)
    }

    /// Changes fields: summary, description, priority, due date, labels, estimate.
    func update(_ key: String, fields: [String: Any]) async throws {
        _ = try await call("PUT", "rest/api/3/issue/\(key)", json: ["fields": fields])
    }

    func assign(_ key: String, to accountID: String?) async throws {
        _ = try await call("PUT", "rest/api/3/issue/\(key)/assignee", json: ["accountId": accountID as Any? ?? NSNull()])
    }

    func priorities() async throws -> [String] {
        struct Priority: Decodable { var name: String }
        let all: [Priority] = try await get("rest/api/3/priority")
        return all.map(\.name)
    }

    func remove(comment id: String, of key: String) async throws { _ = try await call("DELETE", "rest/api/3/issue/\(key)/comment/\(id)") }
    func remove(worklog id: String, of key: String) async throws { _ = try await call("DELETE", "rest/api/3/issue/\(key)/worklog/\(id)") }
}

/// What changed among the user's tickets between two looks, worth telling.
enum JiraWatch {
    struct Seen: Codable, Equatable, Sendable {
        var status: String
        var comments: Int
    }

    enum Event: Equatable, Sendable {
        case assigned(key: String, summary: String, new: Bool)
        case commented(key: String, summary: String, by: String)
        /// No longer among the user's open tickets: closed or taken away.
        case gone(key: String)
    }

    static func snapshot(_ issues: [JiraIssue]) -> [String: Seen] {
        Dictionary(issues.map { ($0.key, Seen(status: $0.fields.status.name, comments: $0.fields.comment?.total ?? 0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// `old` is nil on the very first look: nothing is news then.
    static func events(old: [String: Seen]?, now issues: [JiraIssue], me: String?, at time: Date = .now) -> [Event] {
        guard let old else { return [] }
        var events: [Event] = []
        for issue in issues {
            guard let before = old[issue.key] else {
                // Created within the hour: a new ticket, not an old one handed over.
                let created = JiraTicket.date(issue.fields.created)
                events.append(.assigned(key: issue.key, summary: issue.fields.summary, new: created.map { time.timeIntervalSince($0) < 3600 } ?? false))
                continue
            }
            let total = issue.fields.comment?.total ?? 0
            if total > before.comments, let last = issue.fields.comment?.comments?.last?.author, last.accountId != me {
                events.append(.commented(key: issue.key, summary: issue.fields.summary, by: last.displayName ?? "Someone"))
            }
        }
        let present = Set(issues.map(\.key))
        events += old.keys.filter { !present.contains($0) }.sorted().map { .gone(key: $0) }
        return events
    }
}
