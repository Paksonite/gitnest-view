import AppKit
import Foundation

@MainActor func NSWorkspaceOpen(_ url: URL) -> Bool { openExternal(url) }

/// A ticket assigned to the user.
struct JiraIssue: Decodable, Identifiable, Hashable, Sendable {
    struct Person: Decodable, Hashable, Sendable {
        var accountId: String?
        var displayName: String?
    }
    struct Comments: Decodable, Hashable, Sendable {
        struct Item: Decodable, Hashable, Sendable {
            var id: String
            var author: Person?
        }
        var total: Int?
        var comments: [Item]?
    }
    struct Fields: Decodable, Hashable, Sendable {
        struct Status: Decodable, Hashable, Sendable {
            struct Category: Decodable, Hashable, Sendable { var key: String? } // new, indeterminate, done
            var name: String
            var statusCategory: Category?
        }
        struct Named: Decodable, Hashable, Sendable { var name: String }

        var summary: String
        var status: Status
        var issuetype: Named?
        var priority: Named?
        var updated: String?
        var created: String?
        var comment: Comments?
    }

    var id: String
    var key: String
    var fields: Fields

    var inProgress: Bool { fields.status.statusCategory?.key == "indeterminate" }
    var done: Bool { fields.status.statusCategory?.key == "done" }
}

/// Jira Cloud's REST API, read-only: who am I, and what is assigned to me.
struct JiraClient: Sendable {
    enum JiraError: LocalizedError {
        case refused, notFound, http(Int), notAnswer
        /// Jira said why it will not do it ("Time Spent is required").
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let why): why
            case .refused: "Jira refused the e-mail and API token."
            case .notFound: "No Jira at this address."
            case .http(let code): "Jira answered with an error (HTTP \(code))."
            case .notAnswer: "Jira sent an answer the app does not understand."
            }
        }
    }

    let site: URL
    let email: String
    let token: String
    var session: URLSession = .shared

    /// "team.atlassian.net" or a full URL.
    static func siteURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        guard var parts = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed), parts.host != nil else { return nil }
        // The token goes in a header: never over plain http, and only to the site's root.
        parts.scheme = "https"
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: site.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw JiraError.notAnswer }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic " + Data("\(email):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw JiraError.notAnswer }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw JiraError.refused
        case 404: throw JiraError.notFound
        default: throw JiraError.http(http.statusCode)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw JiraError.notAnswer }
        return value
    }

    /// The account's display name: proves the address and the token.
    func me() async throws -> String {
        struct Me: Decodable { var displayName: String }
        let me: Me = try await get("rest/api/3/myself")
        return me.displayName
    }

    static let defaultFilter = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"

    /// The tickets a filter (JQL) finds, the ones in progress first. Without
    /// one: the open tickets assigned to the account.
    func myIssues(filter: String? = nil) async throws -> [JiraIssue] {
        struct Page: Decodable { var issues: [JiraIssue] }
        let jql = filter.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? Self.defaultFilter
        let page: Page = try await get("rest/api/3/search/jql", query: [
            .init(name: "jql", value: jql),
            .init(name: "fields", value: "summary,status,issuetype,priority,updated,created,comment"),
            .init(name: "maxResults", value: "50"),
        ])
        return page.issues.sorted { ($0.inProgress ? 0 : 1) < ($1.inProgress ? 0 : 1) }
    }
}

/// A status a ticket can move to from where it is.
struct JiraTransition: Decodable, Identifiable, Hashable, Sendable {
    struct Target: Decodable, Hashable, Sendable { var name: String }
    var id: String
    var name: String
    var to: Target?
}

extension JiraClient {
    func transitions(_ key: String) async throws -> [JiraTransition] {
        struct Page: Decodable { var transitions: [JiraTransition] }
        let page: Page = try await get("rest/api/3/issue/\(key)/transitions")
        return page.transitions
    }

    /// Moves a ticket along its workflow. The one thing the app writes to Jira.
    func move(_ key: String, transition id: String) async throws {
        var request = URLRequest(url: site.appending(path: "rest/api/3/issue/\(key)/transitions"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(email):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["transition": ["id": id]])
        let (_, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw JiraError.notAnswer }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw JiraError.refused
        case 404: throw JiraError.notFound
        default: throw JiraError.http(http.statusCode)
        }
    }
}

/// What the app shows of Jira.
struct JiraState: Equatable, Sendable {
    var issues: [JiraIssue] = []
    var error: String?
    var loaded = false
}

/// Where Jira is and who asks; the token is kept with the other tokens.
struct JiraSettings: Codable, Equatable, Sendable {
    var site: String
    var email: String
    /// The user's own filter (JQL); nil shows the open tickets assigned to them.
    var filter: String?
    var tokenKey: String { "jira:" + site.lowercased() }
}

extension AppModel {
    /// nil when Jira is not connected: everything about it then stays hidden.
    var jiraSettings: JiraSettings? {
        _ = settingsRevision
        return defaults.data(forKey: "jira").flatMap { try? JSONDecoder().decode(JiraSettings.self, from: $0) }
    }

    private func jiraClient(_ settings: JiraSettings, token: String? = nil) -> JiraClient? {
        guard let site = JiraClient.siteURL(settings.site), let token = token ?? jiraToken(settings) else { return nil }
        return JiraClient(site: site, email: settings.email, token: token, session: session)
    }

    private func jiraToken(_ settings: JiraSettings) -> String? {
        if let cached = jiraTokenCache, cached.key == settings.tokenKey { return cached.token }
        guard let token = tokenStore.token(for: settings.tokenKey) else { return nil }
        jiraTokenCache = (settings.tokenKey, token)
        return token
    }

    /// Checks the address, e-mail and token, and remembers them. Returns
    /// the account's name.
    @discardableResult
    func connectJira(site: String, email: String, token: String) async throws -> String {
        let settings = JiraSettings(site: site.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces))
        guard let client = jiraClient(settings, token: token) else { throw JiraClient.JiraError.notFound }
        let name = try await client.me()
        try tokenStore.setToken(token, for: settings.tokenKey)
        jiraTokenCache = (settings.tokenKey, token)
        defaults.set(try? JSONEncoder().encode(settings), forKey: "jira")
        settingsRevision += 1
        await refreshJira()
        return name
    }

    func disconnectJira() {
        if let settings = jiraSettings { try? tokenStore.setToken(nil, for: settings.tokenKey) }
        jiraTokenCache = nil
        defaults.removeObject(forKey: "jira")
        settingsRevision += 1
        jira = JiraState()
    }

    func refreshJira() async {
        guard let settings = jiraSettings else { return }
        guard let client = jiraClient(settings) else {
            let state = JiraState(issues: jira.issues, error: "The Jira token is missing: connect again in Settings.", loaded: true)
            if jira != state { jira = state }
            return
        }
        var state = jira
        do {
            state.issues = try await client.myIssues(filter: settings.filter)
            state.error = nil
            // News is judged on the open tickets assigned to the user, whatever the card shows.
            let assigned = settings.filter == nil ? state.issues : ((try? await client.myIssues()) ?? [])
            await announceJira(assigned, client: client)
        } catch {
            state.error = error.localizedDescription
        }
        state.loaded = true
        if jira != state { jira = state }
    }

    /// Changes which tickets are shown (JQL); empty goes back to the default.
    func setJiraFilter(_ text: String) async {
        guard var settings = jiraSettings else { return }
        let filter = text.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.filter = filter.isEmpty ? nil : filter
        defaults.set(try? JSONEncoder().encode(settings), forKey: "jira")
        settingsRevision += 1
        await refreshJira()
    }

    func transitions(for issue: JiraIssue) async -> [JiraTransition] {
        guard let settings = jiraSettings, let client = jiraClient(settings) else { return [] }
        return (try? await client.transitions(issue.key)) ?? []
    }

    /// Moves a ticket to another status, because the user chose it.
    func move(_ issue: JiraIssue, by transition: JiraTransition) async {
        guard let settings = jiraSettings, let client = jiraClient(settings) else { return }
        do {
            try await client.move(issue.key, transition: transition.id)
            toast("\(issue.key) is now \(transition.to?.name ?? transition.name)")
            await refreshJira()
        } catch {
            toast("\(issue.key): \(error.localizedDescription)", .error)
        }
    }

    func jiraURL(_ issue: JiraIssue) -> URL? {
        jiraSettings.flatMap { JiraClient.siteURL($0.site) }?.appending(path: "browse/\(issue.key)")
    }

    /// Branches checked out and the user's pull requests that name the ticket.
    func work(for issue: JiraIssue) -> (branches: [(repo: ForgeRepo, branch: String)], pulls: [MyPull]) {
        let key = issue.key.lowercased()
        var branches: [(ForgeRepo, String)] = []
        for repo in repos {
            if let branch = clone(of: repo)?.branch, branch.lowercased().contains(key) { branches.append((repo, branch)) }
        }
        return (branches.map { (repo: $0.0, branch: $0.1) }, myPulls.filter { $0.title.lowercased().contains(key) })
    }
}

// MARK: - One ticket, in the app's own window

extension AppModel {
    private var jiraNow: JiraClient? { jiraSettings.flatMap { jiraClient($0) } }

    func ticket(_ key: String) async throws -> JiraTicket {
        guard let client = jiraNow else { throw JiraClient.JiraError.notFound }
        return try await client.ticket(key)
    }

    func ticketTransitions(_ key: String) async -> [JiraTransition] {
        guard let client = jiraNow else { return [] }
        return (try? await client.transitions(key)) ?? []
    }

    func jiraPriorities() async -> [String] {
        guard let client = jiraNow else { return [] }
        return (try? await client.priorities()) ?? []
    }

    /// Does one change in Jira. Returns Jira's reason when it refuses
    /// (a field the workflow wants first, for one), nil when it worked.
    func jira(_ what: String, _ work: (JiraClient) async throws -> Void) async -> String? {
        guard let client = jiraNow else { return "Jira is not connected." }
        do {
            try await work(client)
            toast(what)
            Task { await self.refreshJira() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var notifyJira: Bool {
        get { _ = settingsRevision; return defaults.object(forKey: "notifyJira") as? Bool ?? true }
        set { guard newValue != notifyJira else { return }; defaults.set(newValue, forKey: "notifyJira"); settingsRevision += 1 }
    }

    /// Tells the user what changed among their tickets since the last look:
    /// assigned, commented by someone else, closed by someone else.
    func announceJira(_ assigned: [JiraIssue], client: JiraClient) async {
        let old = defaults.data(forKey: "jiraSeen").flatMap { try? JSONDecoder().decode([String: JiraWatch.Seen].self, from: $0) }
        if jiraAccountID == nil { jiraAccountID = try? await client.myAccountID() }
        let events = JiraWatch.events(old: old, now: assigned, me: jiraAccountID)
        defaults.set(try? JSONEncoder().encode(JiraWatch.snapshot(assigned)), forKey: "jiraSeen")
        guard notifyJira else { return }
        for event in events {
            switch event {
            case .assigned(let key, let summary, let new):
                Notifier.shared.postTicket(id: "jira:assigned:\(key)", title: new ? "New ticket for you · \(key)" : "Assigned to you · \(key)", body: summary, key: key)
            case .commented(let key, let summary, let who):
                Notifier.shared.postTicket(id: "jira:comment:\(key):\(Date.now.timeIntervalSince1970)", title: "\(who) commented · \(key)", body: summary, key: key)
            case .gone(let key):
                // Closed by someone else is news; closed by the user, or handed on, is not.
                guard let ticket = try? await client.ticket(key), ticket.done, ticket.statusChangedByID != jiraAccountID else { continue }
                Notifier.shared.postTicket(id: "jira:closed:\(key)", title: "\(ticket.statusChangedBy ?? "Someone") closed your ticket · \(key)",
                                           body: "\(ticket.summary) is now \(ticket.status).", key: key)
            }
        }
    }
}
