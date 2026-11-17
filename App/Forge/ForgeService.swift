import Foundation

/// The kind of server behind a connected host. The app speaks Forgejo's
/// model everywhere; each kind's client translates its own API into it.
enum ForgeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Forgejo and Gitea: the same API.
    case forgejo
    case github
    case gitlab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forgejo: "Forgejo / Gitea"
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }

    /// What a pull request is called there.
    var pullName: String { self == .gitlab ? "merge request" : "pull request" }
    /// What a pipeline file is.
    var pipelineName: String {
        switch self {
        case .forgejo: "Forgejo Actions"
        case .github: "GitHub Actions"
        case .gitlab: "GitLab CI/CD"
        }
    }

    /// The server's page where the user makes an access token.
    func tokenPage(host: String) -> URL? {
        switch self {
        case .forgejo: URL(string: "https://\(host)/user/settings/applications")
        case .github: URL(string: host == "github.com" ? "https://github.com/settings/tokens" : "https://\(host)/settings/tokens")
        case .gitlab: URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=GitNest%20View&scopes=api,read_user,read_repository,write_repository")
        }
    }

    /// The token's permissions, in the server's own words.
    var scopeHint: String {
        switch self {
        case .forgejo: "read:user, read:repository, read:organization, read:issue, read:notification; add the write scopes to merge, review and run pipelines."
        case .github: "A classic token with repo, read:org, workflow and notifications; or a fine-grained token with Contents, Pull requests, Actions and Metadata."
        case .gitlab: "Scopes api (or read_api for looking only), read_user and read_repository; write_repository to push over HTTPS."
        }
    }

    /// The user name git sends with the token over HTTPS.
    func gitUser(login: String?) -> String {
        switch self {
        case .forgejo: login ?? "token"
        case .github: "x-access-token"
        case .gitlab: "oauth2"
        }
    }

    /// The kind a host name gives away, when it does.
    static func guess(host: String) -> ForgeKind? {
        let host = host.lowercased()
        if host == "github.com" || host.hasSuffix(".ghe.com") { return .github }
        if host == "gitlab.com" { return .gitlab }
        return nil
    }
}

typealias ForgeError = ForgejoClient.ForgeError

/// Everything the app asks of a server. ForgejoClient, GitHubClient and
/// GitLabClient answer in the same models (ForgeModels): a merge request
/// is a PullRequest, a GitLab pipeline a WorkflowRun, and so on.
///
/// Requirements with optional parts carry a name of their own; the names
/// the app calls, with their defaults, are in the extension below.
protocol ForgeService: Sendable {
    var kind: ForgeKind { get }
    var token: String? { get }

    func version() async throws -> String
    func currentUser() async throws -> ForgeUser
    func organizations() async throws -> [ForgeOrg]
    func repositories(org: String) async throws -> [ForgeRepo]
    func userRepositories() async throws -> [ForgeRepo]

    func listPulls(_ repo: RepoSlug, state: String, limit: Int) async throws -> [PullRequest]
    func pullRequest(_ repo: RepoSlug, number: Int) async throws -> PullRequest
    func pullCommits(_ repo: RepoSlug, pull number: Int) async throws -> [PullCommit]
    func pullFiles(_ repo: RepoSlug, pull number: Int) async throws -> [PullFile]
    func pullDiff(_ repo: RepoSlug, number: Int) async throws -> String
    func myPullRequests() async throws -> [PullSearchHit]
    func openPullRequests(owner: String) async throws -> [PullSearchHit]
    func reviewRequests() async throws -> [PullSearchHit]
    func createPull(_ repo: RepoSlug, head: String, base: String, title: String, body: String) async throws -> PullRequest
    func changePull(_ repo: RepoSlug, number: Int, title: String?, body: String?, state: String?, assignees: [String]?) async throws
    func updateBranch(_ repo: RepoSlug, number: Int, style: String) async throws
    func merge(_ repo: RepoSlug, number: Int, style: String, deleteBranch: Bool, head: String, title: String?) async throws

    func reviews(_ repo: RepoSlug, pull number: Int) async throws -> [Review]
    func submitReview(_ repo: RepoSlug, number: Int, event: String, body: String, commit: String) async throws
    func reviewComments(_ repo: RepoSlug, number: Int, review: Int) async throws -> [ReviewComment]
    func comments(_ repo: RepoSlug, number: Int) async throws -> [IssueComment]
    func comment(_ repo: RepoSlug, number: Int, body: String) async throws
    func reviewers(_ repo: RepoSlug) async throws -> [ForgeUser]
    func assignees(_ repo: RepoSlug) async throws -> [ForgeUser]
    func askReview(_ repo: RepoSlug, number: Int, from logins: [String], withdraw: Bool) async throws
    func labels(_ repo: RepoSlug) async throws -> [ForgeLabel]
    func setLabels(_ repo: RepoSlug, number: Int, ids: [Int]) async throws

    func branch(_ repo: RepoSlug, name: String) async throws -> BranchInfo
    func branches(_ repo: RepoSlug) async throws -> [String]
    func branchProtections(_ repo: RepoSlug) async throws -> [BranchProtection]
    func compare(_ repo: RepoSlug, base: String, head: String) async throws -> [PullCommit]
    func combinedStatus(_ repo: RepoSlug, ref: String) async throws -> CombinedStatus

    func listRuns(_ repo: RepoSlug, limit: Int, headSHA: String?, branch: String?) async throws -> [WorkflowRun]
    func jobs(_ repo: RepoSlug, run id: Int) async throws -> [WorkflowJob]
    func job(_ repo: RepoSlug, id: Int) async throws -> WorkflowJob
    func jobLog(_ repo: RepoSlug, job id: Int, from offset: Int) async throws -> Data?
    func readStepLog(_ repo: RepoSlug, job id: Int, step: Int, from offset: Int) async throws -> Data?
    func workflowFiles(_ repo: RepoSlug) async throws -> [ContentEntry]
    func fileText(_ repo: RepoSlug, path: String) async throws -> String
    func dispatch(_ repo: RepoSlug, workflow file: String, ref: String, inputs: [String: String]) async throws
    func rerun(_ repo: RepoSlug, run id: Int) async throws
    func rerun(_ repo: RepoSlug, job id: Int) async throws
    func cancel(_ repo: RepoSlug, run id: Int) async throws

    func notifications() async throws -> [ForgeNotification]
    func markRead(notification id: Int) async throws
    func releases(_ repo: RepoSlug) async throws -> [ForgeRelease]
    func actionVariables(_ repo: RepoSlug) async throws -> [ActionVariable]
    func actionSecrets(_ repo: RepoSlug) async throws -> [ActionSecret]

    /// What the token may do, one line per feature; never changes anything.
    func permissions() async -> [PermissionCheck]

    /// The repository's size in KiB when a listing left it out (GitLab).
    func repositorySize(_ repo: RepoSlug) async -> Int?
}

extension ForgeService {
    func repositorySize(_ repo: RepoSlug) async -> Int? { nil }

    func pullRequests(_ repo: RepoSlug, state: String = "open", limit: Int = 50) async throws -> [PullRequest] {
        try await listPulls(repo, state: state, limit: limit)
    }

    func runs(_ repo: RepoSlug, limit: Int = 30, headSHA: String? = nil, branch: String? = nil) async throws -> [WorkflowRun] {
        try await listRuns(repo, limit: limit, headSHA: headSHA, branch: branch)
    }

    func stepLog(_ repo: RepoSlug, job id: Int, step: Int, from offset: Int = 0) async throws -> Data? {
        try await readStepLog(repo, job: id, step: step, from: offset)
    }

    func requestReview(_ repo: RepoSlug, number: Int, from logins: [String], withdraw: Bool = false) async throws {
        try await askReview(repo, number: number, from: logins, withdraw: withdraw)
    }

    func editPull(_ repo: RepoSlug, number: Int, title: String? = nil, body: String? = nil, state: String? = nil, assignees: [String]? = nil) async throws {
        try await changePull(repo, number: number, title: title, body: body, state: state, assignees: assignees)
    }
}

/// Answers whether the token may do each thing by asking harmless
/// questions: a read reads one item; a write aims at something that does not
/// exist, so "not found" means allowed and "forbidden" means the scope is
/// missing. `probes` are (id, feature, scope, writes, method, path).
enum PermissionProbe {
    typealias Probe = (id: String, feature: String, scope: String, writes: Bool, method: String, path: String)

    static func run(_ probes: [Probe], status: @escaping @Sendable (String, String) async -> Int) async -> [PermissionCheck] {
        await withTaskGroup(of: (Int, PermissionCheck).self) { group in
            for (index, probe) in probes.enumerated() {
                group.addTask {
                    let code = await status(probe.method, probe.path)
                    return (index, PermissionCheck(id: probe.id, feature: probe.feature, scope: probe.scope, writes: probe.writes, answer: answer(code, writes: probe.writes)))
                }
            }
            var all: [(Int, PermissionCheck)] = []
            for await item in group { all.append(item) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func answer(_ status: Int, writes: Bool) -> PermissionCheck.Answer {
        if writes {
            return [404, 405, 422, 400].contains(status) || (200..<300).contains(status) ? .yes : [401, 403].contains(status) ? .no : .unknown
        }
        return (200..<300).contains(status) ? .yes : [401, 403].contains(status) ? .no : .unknown
    }
}

/// HTTP for the GitHub and GitLab clients: JSON in and out, the token in a
/// header, the server's own reason when it refuses.
struct RestAPI: Sendable {
    let base: URL
    let headers: [String: String]
    var session: URLSession = .shared

    /// The base and the path as given: an escape already in the path stays
    /// one ("group%2Fproject" is how GitLab names a project); spaces and
    /// the like are escaped.
    func joined(_ path: String) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(CharacterSet(charactersIn: "%"))) ?? path
        return URL(string: base.absoluteString + encoded)
    }

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let joined = joined(path) else { throw ForgeError.notAnswer }
        var components = URLComponents(url: joined, resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        // URLComponents leaves "+" alone; servers read it as a space.
        if let encoded = components?.percentEncodedQuery { components?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B") }
        guard let url = components?.url else { throw ForgeError.notAnswer }
        return url
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], accept: String = "application/json") throws -> URLRequest {
        var request = URLRequest(url: try url(path, query: query), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// The answer's body and headers; throws for anything but 2xx.
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let asked = Date()
        let (data, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        Trace.note("\(request.httpMethod ?? "GET") \(request.url?.path ?? "") took \(Int(Date().timeIntervalSince(asked) * 1000)) ms, \(data.count) B")
        guard let http = response as? HTTPURLResponse else { throw ForgeError.notAnswer }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401: throw ForgeError.unauthorized
        case 403:
            if let message = Self.message(data) { throw ForgeError.rejected(message) }
            throw ForgeError.forbidden
        case 404: throw ForgeError.notFound
        default:
            if let message = Self.message(data) { throw ForgeError.rejected(message) }
            throw ForgeError.http(http.statusCode)
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as _: T.Type = T.self) async throws -> T {
        let (data, _) = try await data(request("GET", path, query: query))
        return try decode(data)
    }

    /// The body and the headers (for paging and scopes).
    func getWithHeaders<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as _: T.Type = T.self) async throws -> (T, HTTPURLResponse) {
        let (data, response) = try await data(request("GET", path, query: query))
        return (try decode(data), response)
    }

    func text(_ path: String, query: [URLQueryItem] = [], accept: String = "text/plain") async throws -> String {
        let (data, _) = try await data(request("GET", path, query: query, accept: accept))
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> Data {
        var request = try request(method, path, query: query)
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await data(request).0
    }

    /// The HTTP status only; 0 when the server did not answer.
    func status(_ method: String, _ pathAndQuery: String) async -> Int {
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1).map(String.init)
        guard let joined = joined(parts[0]), var components = URLComponents(url: joined, resolvingAgainstBaseURL: false) else { return 0 }
        if parts.count > 1 { components.percentEncodedQuery = parts[1] }
        guard let url = components.url else { return 0 }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        guard let (_, response) = try? await session.data(for: request, delegate: AuthGuard.shared) else { return 0 }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try ForgejoClient.decoder.decode(T.self, from: data)
        } catch {
            Trace.note("decode \(T.self) failed: \(error)")
            throw ForgeError.notAnswer
        }
    }

    /// GitHub: {"message": …, "errors": [{"message": …}]}; GitLab: {"message": …}
    /// (a string, a list or a map of field → reasons) or {"error": …}.
    static func message(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var parts: [String] = []
        func collect(_ value: Any?) {
            switch value {
            case let text as String: parts.append(text)
            case let list as [Any]: list.forEach(collect)
            case let map as [String: Any]:
                if let text = map["message"] as? String { parts.append(text) } else {
                    for (key, value) in map.sorted(by: { $0.key < $1.key }) {
                        let before = parts.count
                        collect(value)
                        if parts.count > before, key != "base" { parts[before] = "\(key) \(parts[before])" }
                    }
                }
            default: break
            }
        }
        collect(root["message"])
        if let errors = root["errors"] { collect(errors) }
        if parts.isEmpty { collect(root["error"]) }
        let text = parts.filter { !$0.isEmpty }.joined(separator: "; ")
        return text.isEmpty ? nil : text
    }
}

extension ForgejoClient: ForgeService {
    var kind: ForgeKind { .forgejo }

    func listPulls(_ repo: RepoSlug, state: String, limit: Int) async throws -> [PullRequest] {
        try await pullRequests(repo, state: state, limit: limit)
    }

    func listRuns(_ repo: RepoSlug, limit: Int, headSHA: String?, branch: String?) async throws -> [WorkflowRun] {
        try await runs(repo, limit: limit, headSHA: headSHA, branch: branch)
    }

    func readStepLog(_ repo: RepoSlug, job id: Int, step: Int, from offset: Int) async throws -> Data? {
        try await stepLog(repo, job: id, step: step, from: offset)
    }

    func askReview(_ repo: RepoSlug, number: Int, from logins: [String], withdraw: Bool) async throws {
        try await requestReview(repo, number: number, from: logins, withdraw: withdraw)
    }

    func changePull(_ repo: RepoSlug, number: Int, title: String?, body: String?, state: String?, assignees: [String]?) async throws {
        try await editPull(repo, number: number, title: title, body: body, state: state, assignees: assignees)
    }

    func permissions() async -> [PermissionCheck] {
        let probes: [PermissionProbe.Probe] = [
            ("user", "Sign in and know who you are", "read:user", false, "GET", "user"),
            ("repos", "List repositories, read pipelines and logs", "read:repository", false, "GET", "user/repos?limit=1"),
            ("orgs", "Workspaces (organisations)", "read:organization", false, "GET", "user/orgs?limit=1"),
            ("issues", "Pull requests, reviews and the Inbox", "read:issue", false, "GET", "repos/issues/search?limit=1&type=pulls"),
            ("notes", "Unread marks from the server", "read:notification", false, "GET", "notifications?limit=1"),
            ("write-repo", "Merge, open pull requests, run and re-run pipelines", "write:repository", true, "POST", "repos/gitnest-view-probe/none/pulls"),
            ("write-issue", "Comment, review, labels, reviewers", "write:issue", true, "POST", "repos/gitnest-view-probe/none/issues/0/comments"),
            ("write-notes", "Mark as read", "write:notification", true, "PATCH", "notifications/threads/0"),
        ]
        let client = self
        return await PermissionProbe.run(probes) { await client.status($0, $1) }
    }
}
