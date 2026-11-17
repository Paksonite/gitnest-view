import Foundation

/// One ticket as Jira's own page shows it: what it is, where it stands,
/// who has it, the time, the conversation.
struct JiraTicket: Equatable, Sendable {
    /// Someone on the ticket. `avatar` is set only for a picture the person
    /// chose; Jira's generated initials are drawn by the app instead.
    struct Person: Identifiable, Equatable, Hashable, Sendable {
        var accountID: String?
        var name: String
        var avatar: URL?
        var id: String { accountID ?? name }

        init(accountID: String?, name: String, avatar: URL? = nil) {
            self.accountID = accountID
            self.name = name
            self.avatar = avatar
        }

        init?(json: Any?) {
            guard let item = json as? [String: Any], let name = item["displayName"] as? String else { return nil }
            self.init(accountID: item["accountId"] as? String, name: name, avatar: JiraTicket.avatar(item["avatarUrls"]))
        }
    }

    struct Comment: Identifiable, Equatable, Sendable {
        var id: String
        var author: String
        var authorID: String?
        var authorAvatar: URL?
        var body: String
        var created: Date?
    }

    struct Worklog: Identifiable, Equatable, Sendable {
        var id: String
        var author: String
        var authorID: String?
        var authorAvatar: URL?
        var timeSpent: String
        var started: Date?
    }

    /// Another ticket this one points at: its parent, a sub-task, a blocker.
    struct Related: Identifiable, Equatable, Sendable {
        /// How it relates, in Jira's words: "blocks", "is blocked by", "sub-task".
        var relation: String
        var key: String
        var summary: String
        var status: String
        var statusCategory: String
        var type: String?
        var priority: String?
        var id: String { relation + key }

        /// The words Jira puts between two tickets, "is blocked by" and the like.
        var blocking: Bool { relation.lowercased().contains("block") }

        init(relation: String, key: String, summary: String, status: String, statusCategory: String, type: String? = nil, priority: String? = nil) {
            self.relation = relation
            self.key = key
            self.summary = summary
            self.status = status
            self.statusCategory = statusCategory
            self.type = type
            self.priority = priority
        }

        init?(relation: String, json: Any?) {
            guard let item = json as? [String: Any], let key = item["key"] as? String else { return nil }
            let fields = item["fields"] as? [String: Any] ?? [:]
            let status = fields["status"] as? [String: Any]
            self.init(relation: relation, key: key, summary: fields["summary"] as? String ?? "",
                      status: status?["name"] as? String ?? "", statusCategory: (status?["statusCategory"] as? [String: Any])?["key"] as? String ?? "",
                      type: (fields["issuetype"] as? [String: Any])?["name"] as? String,
                      priority: (fields["priority"] as? [String: Any])?["name"] as? String)
        }
    }

    /// A sprint the ticket was planned into.
    struct Sprint: Identifiable, Equatable, Sendable {
        var id: Int
        var name: String
        /// active, future or closed.
        var state: String
        var start: Date?
        var end: Date?
        var goal: String?

        var active: Bool { state == "active" }
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
    var assigneeAvatar: URL?
    var reporter: String?
    var reporterID: String?
    var reporterAvatar: URL?
    var description: String
    var labels: [String]
    var due: String?
    var parent: String?
    /// The parent as a ticket of its own, when Jira sent its summary.
    var parentTicket: Related?
    /// Blockers, duplicates, "relates to": both directions, as Jira lists them.
    var links: [Related] = []
    var subtasks: [Related] = []
    /// Read separately from the ticket; empty until then.
    var watchers: [Person] = []
    var watchCount: Int = 0
    var watching = false
    /// Every sprint the ticket was in, oldest first.
    var sprints: [Sprint] = []
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

    /// The sprint that matters now: the running one, else the next, else the last.
    var sprint: Sprint? {
        sprints.first(where: \.active) ?? sprints.first { $0.state == "future" } ?? sprints.last
    }

    /// A picture the person chose, or nil for Jira's generated initials.
    /// Gravatar is asked to answer 404 instead of falling back to them.
    static func avatar(_ urls: Any?) -> URL? {
        guard let urls = urls as? [String: Any], let text = (urls["48x48"] ?? urls["32x32"] ?? urls["24x24"]) as? String,
              var parts = URLComponents(string: text) else { return nil }
        if text.contains("/initials/") && !text.contains("gravatar.com") { return nil }
        if parts.host?.hasSuffix("gravatar.com") == true {
            parts.queryItems = [URLQueryItem(name: "d", value: "404"), URLQueryItem(name: "s", value: "96")]
        }
        return parts.url
    }

    /// Jira's sprint field: a list of {id, name, state, startDate, endDate, goal}.
    static func sprints(_ json: Any?) -> [Sprint] {
        let list = json as? [[String: Any]] ?? []
        func day(_ text: Any?) -> Date? {
            guard let text = text as? String else { return nil }
            return (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return list.compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            let goal = (item["goal"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return Sprint(id: id, name: name, state: (item["state"] as? String ?? "").lowercased(), start: day(item["startDate"]), end: day(item["endDate"]), goal: goal)
        }
    }

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

    init?(json: Any, sprintField: String? = nil) {
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
        assigneeAvatar = Self.avatar((fields["assignee"] as? [String: Any])?["avatarUrls"])
        reporter = name("reporter", "displayName")
        reporterID = name("reporter", "accountId")
        reporterAvatar = Self.avatar((fields["reporter"] as? [String: Any])?["avatarUrls"])
        description = Self.plain(rendered["description"])
        labels = fields["labels"] as? [String] ?? []
        due = fields["duedate"] as? String
        parent = name("parent", "key")
        parentTicket = Related(relation: "parent", json: fields["parent"])
        links = (fields["issuelinks"] as? [[String: Any]] ?? []).compactMap { link in
            let type = link["type"] as? [String: Any]
            if let other = link["outwardIssue"] { return Related(relation: type?["outward"] as? String ?? "relates to", json: other) }
            if let other = link["inwardIssue"] { return Related(relation: type?["inward"] as? String ?? "relates to", json: other) }
            return nil
        }
        subtasks = (fields["subtasks"] as? [[String: Any]] ?? []).compactMap { Related(relation: "sub-task", json: $0) }
        if let watches = fields["watches"] as? [String: Any] {
            watchCount = watches["watchCount"] as? Int ?? 0
            watching = watches["isWatching"] as? Bool ?? false
        }
        if let sprintField { sprints = Self.sprints(fields[sprintField]) }
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
                           authorID: author?["accountId"] as? String, authorAvatar: Self.avatar(author?["avatarUrls"]),
                           body: Self.plain(index < shown.count ? shown[index]["body"] : nil), created: Self.date(item["created"]))
        }
        let logs = (fields["worklog"] as? [String: Any])?["worklogs"] as? [[String: Any]] ?? []
        worklogs = logs.enumerated().map { index, item in
            let author = item["author"] as? [String: Any]
            return Worklog(id: item["id"] as? String ?? "\(index)", author: author?["displayName"] as? String ?? "someone",
                    authorID: author?["accountId"] as? String, authorAvatar: Self.avatar(author?["avatarUrls"]),
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
    private func call(_ method: String, _ path: String, json: Any? = nil, raw: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
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
        } else if let raw {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = raw
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
        let sprint = await sprintField()
        var fields = "summary,status,issuetype,priority,assignee,reporter,description,timetracking,labels,created,updated,duedate,parent,project,comment,worklog,issuelinks,subtasks,watches"
        if let sprint { fields += "," + sprint }
        async let reading = call("GET", "rest/api/3/issue/\(key)", query: [
            .init(name: "expand", value: "renderedFields,changelog"),
            .init(name: "fields", value: fields),
        ])
        async let watching = try? watchers(key)
        let data = try await reading
        guard var ticket = JiraTicket(json: (try? JSONSerialization.jsonObject(with: data)) as Any, sprintField: sprint) else { throw JiraError.notAnswer }
        if let people = await watching {
            ticket.watchers = people.list
            ticket.watching = people.watching
            ticket.watchCount = max(ticket.watchCount, people.list.count)
        }
        return ticket
    }

    /// Who follows the ticket, and whether the user does.
    func watchers(_ key: String) async throws -> (list: [JiraTicket.Person], watching: Bool) {
        let data = try await call("GET", "rest/api/3/issue/\(key)/watchers")
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let list = (root["watchers"] as? [Any] ?? []).compactMap { JiraTicket.Person(json: $0) }
        return (list, root["isWatching"] as? Bool ?? false)
    }

    func watch(_ key: String, accountID: String) async throws {
        // Jira takes the account id as a bare JSON string.
        _ = try await call("POST", "rest/api/3/issue/\(key)/watchers", raw: Data("\"\(accountID)\"".utf8))
    }

    func unwatch(_ key: String, accountID: String) async throws {
        _ = try await call("DELETE", "rest/api/3/issue/\(key)/watchers", query: [.init(name: "accountId", value: accountID)])
    }

    /// The id of the sprint field ("customfield_10020"): it differs between
    /// sites and is absent where Jira Software is not installed.
    func sprintField() async -> String? {
        if let known = await JiraFieldCache.shared.sprint(site) { return known }
        struct Field: Decodable {
            struct Schema: Decodable { var custom: String? }
            var id: String
            var schema: Schema?
        }
        let all: [Field]? = try? await get("rest/api/3/field")
        let id = all?.first { $0.schema?.custom == "com.pyxis.greenhopper.jira:gh-sprint" }?.id
        if all != nil { await JiraFieldCache.shared.remember(site, sprint: id) }
        return id
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

    /// Who the ticket can be assigned to.
    func assignable(_ key: String, query: String) async throws -> [JiraUser] {
        let all: [JiraUser] = try await get("rest/api/3/user/assignable/search", query: [
            .init(name: "issueKey", value: key), .init(name: "query", value: query), .init(name: "maxResults", value: "20"),
        ])
        return all.filter { $0.active != false && $0.accountType != "app" }
    }

    func priorities() async throws -> [String] {
        struct Priority: Decodable { var name: String }
        let all: [Priority] = try await get("rest/api/3/priority")
        return all.map(\.name)
    }

    func remove(comment id: String, of key: String) async throws { _ = try await call("DELETE", "rest/api/3/issue/\(key)/comment/\(id)") }
    func remove(worklog id: String, of key: String) async throws { _ = try await call("DELETE", "rest/api/3/issue/\(key)/worklog/\(id)") }
}

/// Field ids that differ between Jira sites, read once per site.
actor JiraFieldCache {
    static let shared = JiraFieldCache()
    private var sprints: [URL: String?] = [:]

    /// .some(nil): the site has no sprint field; nil: not read yet.
    func sprint(_ site: URL) -> String?? { sprints[site] }
    func remember(_ site: URL, sprint: String?) { sprints[site] = .some(sprint) }
}

/// Someone in Jira.
struct JiraUser: Decodable, Identifiable, Hashable, Sendable {
    var accountId: String
    var displayName: String
    var emailAddress: String?
    var active: Bool?
    var accountType: String?
    var avatarUrls: [String: String]?
    var id: String { accountId }
    var avatar: URL? { JiraTicket.avatar(avatarUrls) }

    init(accountId: String, displayName: String, emailAddress: String? = nil, active: Bool? = nil, accountType: String? = nil, avatarUrls: [String: String]? = nil) {
        self.accountId = accountId
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.active = active
        self.accountType = accountType
        self.avatarUrls = avatarUrls
    }
}

/// Jira's way of writing time: "1h 30m", "45m", "2d", "1.5h", "1w 2d".
enum JiraTime {
    static func valid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.range(of: #"^(\d+([.,]\d+)?\s*[wdhm]\s*)+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What Jira accepts: lower case, a dot for decimals.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
    }
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
