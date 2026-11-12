import Foundation

/// Reads one Forgejo server's REST API. URLSession gives it the system's
/// proxy, VPN routes and trusted certificates, which internal servers need.
struct ForgejoClient: Sendable {
    enum ForgeError: LocalizedError {
        case unauthorized
        case forbidden
        case notFound
        case rejected(String)
        case http(Int)
        case notAnswer

        var errorDescription: String? {
            switch self {
            case .unauthorized: "The server refused the access token."
            case .forbidden: "The access token is not allowed to do this. Changing things on the server needs a token with write access to repositories."
            case .rejected(let why): why
            case .notFound: "Not found on the server (or the token may not see it)."
            case .http(let code): "The server answered with an error (HTTP \(code))."
            case .notAnswer: "The server sent an answer the app does not understand."
            }
        }
    }

    let baseURL: URL
    let token: String?
    var session: URLSession = .shared

    init(host: String, token: String?, session: URLSession = .shared) {
        // A host is stored as typed in Settings: "forge.example.com" or a full URL.
        let text = host.contains("://") ? host : "https://" + host
        baseURL = URL(string: text) ?? URL(string: "https://invalid.invalid")!
        self.token = token
        self.session = session
    }

    // MARK: - Endpoints

    func version() async throws -> String {
        try await get("version", as: ForgeVersion.self).version
    }

    func currentUser() async throws -> ForgeUser {
        try await get("user")
    }

    func organizations() async throws -> [ForgeOrg] {
        try await pages("user/orgs")
    }

    func repositories(org: String) async throws -> [ForgeRepo] {
        try await pages("orgs/\(org)/repos")
    }

    /// Every repository the account can see that is not in an organisation
    /// it belongs to: its own and the ones shared with it.
    func userRepositories() async throws -> [ForgeRepo] {
        try await pages("user/repos")
    }

    func pullCommits(_ repo: RepoSlug, pull number: Int) async throws -> [PullCommit] {
        try await get("repos/\(repo.owner)/\(repo.name)/pulls/\(number)/commits", query: [.init(name: "limit", value: "50")])
    }

    func pullFiles(_ repo: RepoSlug, pull number: Int) async throws -> [PullFile] {
        try await get("repos/\(repo.owner)/\(repo.name)/pulls/\(number)/files", query: [.init(name: "limit", value: "100")])
    }

    /// The account's own open pull requests, across repositories.
    func myPullRequests() async throws -> [PullSearchHit] {
        try await get("repos/issues/search", query: [
            .init(name: "type", value: "pulls"), .init(name: "state", value: "open"),
            .init(name: "created", value: "true"), .init(name: "limit", value: "50"),
        ])
    }

    /// Open pull requests in every repository of an owner (organisation or user).
    func openPullRequests(owner: String) async throws -> [PullSearchHit] {
        try await get("repos/issues/search", query: [
            .init(name: "type", value: "pulls"), .init(name: "state", value: "open"),
            .init(name: "owner", value: owner), .init(name: "limit", value: "50"),
        ])
    }

    func pullRequest(_ repo: RepoSlug, number: Int) async throws -> PullRequest {
        try await get("repos/\(repo.owner)/\(repo.name)/pulls/\(number)")
    }

    /// Open pull requests waiting for the account's review.
    func reviewRequests() async throws -> [PullSearchHit] {
        try await get("repos/issues/search", query: [
            .init(name: "type", value: "pulls"), .init(name: "state", value: "open"),
            .init(name: "review_requested", value: "true"), .init(name: "limit", value: "50"),
        ])
    }

    /// Reads a listing page by page (Forgejo caps a page at 50 by default).
    func pages<T: Decodable>(_ path: String, limit: Int = 50, maxPages: Int = 20) async throws -> [T] {
        var all: [T] = []
        for page in 1...maxPages {
            let batch: [T] = try await get(path, query: [
                .init(name: "page", value: String(page)), .init(name: "limit", value: String(limit)),
            ])
            all += batch
            if batch.count < limit { break }
        }
        return all
    }

    func pullRequests(_ repo: RepoSlug, state: String = "open", limit: Int = 50) async throws -> [PullRequest] {
        try await get("repos/\(repo.owner)/\(repo.name)/pulls", query: [
            .init(name: "state", value: state), .init(name: "sort", value: "recentupdate"),
            .init(name: "page", value: "1"), .init(name: "limit", value: String(limit)),
        ])
    }

    /// The whole diff of a pull request, as git prints it.
    func pullDiff(_ repo: RepoSlug, number: Int) async throws -> String {
        var request = try request("repos/\(repo.owner)/\(repo.name)/pulls/\(number).diff")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw ForgeError.notAnswer }
        switch http.statusCode {
        case 200..<300: return String(decoding: data, as: UTF8.self)
        case 401: throw ForgeError.unauthorized
        case 403: throw ForgeError.forbidden
        case 404: throw ForgeError.notFound
        default: throw ForgeError.http(http.statusCode)
        }
    }

    /// APPROVED, REQUEST_CHANGES or COMMENT, on the commit the reviewer saw.
    func submitReview(_ repo: RepoSlug, number: Int, event: String, body: String, commit: String) async throws {
        struct Body: Encodable {
            var event: String
            var body: String
            var commit_id: String
        }
        try await send("POST", "repos/\(repo.owner)/\(repo.name)/pulls/\(number)/reviews", body: Body(event: event, body: body, commit_id: commit))
    }

    /// Merges a pull request; `head` makes the server refuse when the branch
    /// moved since the user looked at it.
    func merge(_ repo: RepoSlug, number: Int, style: String, deleteBranch: Bool, head: String, title: String?) async throws {
        struct Body: Encodable {
            var Do: String
            var delete_branch_after_merge: Bool
            var head_commit_id: String
            var MergeTitleField: String?
        }
        try await send("POST", "repos/\(repo.owner)/\(repo.name)/pulls/\(number)/merge",
                       body: Body(Do: style, delete_branch_after_merge: deleteBranch, head_commit_id: head, MergeTitleField: title))
    }

    /// Branch protection rules; readable by repository admins only.
    /// What the server says about one branch: protected, and how many
    /// approvals a merge into it needs. Readable with read access, unlike
    /// the protection rules themselves (admins only).
    func branch(_ repo: RepoSlug, name: String) async throws -> BranchInfo {
        try await get("repos/\(repo.owner)/\(repo.name)/branches/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)")
    }

    /// The names of the repository's branches on the server.
    func branches(_ repo: RepoSlug) async throws -> [String] {
        struct Branch: Decodable { var name: String }
        let all: [Branch] = try await pages("repos/\(repo.owner)/\(repo.name)/branches", maxPages: 6)
        return all.map(\.name)
    }

    func branchProtections(_ repo: RepoSlug) async throws -> [BranchProtection] {
        try await get("repos/\(repo.owner)/\(repo.name)/branch_protections")
    }

    func reviews(_ repo: RepoSlug, pull number: Int) async throws -> [Review] {
        try await get("repos/\(repo.owner)/\(repo.name)/pulls/\(number)/reviews")
    }

    func combinedStatus(_ repo: RepoSlug, ref: String) async throws -> CombinedStatus {
        try await get("repos/\(repo.owner)/\(repo.name)/commits/\(ref)/status")
    }

    func runs(_ repo: RepoSlug, limit: Int = 30, headSHA: String? = nil, branch: String? = nil) async throws -> [WorkflowRun] {
        // With "page": Forgejo 16 ignores "limit" alone here and sends every
        // run the repository ever had (megabytes, seconds).
        var query = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "limit", value: String(limit))]
        if let headSHA { query.append(.init(name: "head_sha", value: headSHA)) }
        if let branch { query.append(.init(name: "ref", value: "refs/heads/" + branch)) }
        let list: WorkflowRunList = try await get("repos/\(repo.owner)/\(repo.name)/actions/runs", query: query)
        return list.workflowRuns ?? []
    }

    func jobs(_ repo: RepoSlug, run id: Int) async throws -> [WorkflowJob] {
        try await get("repos/\(repo.owner)/\(repo.name)/actions/runs/\(id)/jobs")
    }

    /// A job with its steps.
    func job(_ repo: RepoSlug, id: Int) async throws -> WorkflowJob {
        try await get("repos/\(repo.owner)/\(repo.name)/actions/jobs/\(id)")
    }

    /// The log of one step of a job after `offset` bytes; nil while the
    /// step has no log yet. Like whole logs, step logs honour Range, so a
    /// running step costs only its new bytes.
    func stepLog(_ repo: RepoSlug, job id: Int, step: Int, from offset: Int = 0) async throws -> Data? {
        var components = URLComponents(url: baseURL.appending(path: "api/v1/repos/\(repo.owner)/\(repo.name)/actions/jobs/\(id)/logs"), resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "step", value: String(step))]
        guard let url = components?.url else { throw ForgeError.notAnswer }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let token, !token.isEmpty { request.setValue("token " + token, forHTTPHeaderField: "Authorization") }
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (data, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw ForgeError.notAnswer }
        switch http.statusCode {
        case 206: return data
        case 200: return offset < data.count ? data.dropFirst(offset) : Data()
        case 416: return Data()
        case 404, 500: return nil
        case 401: throw ForgeError.unauthorized
        case 403: throw ForgeError.forbidden
        default: throw ForgeError.http(http.statusCode)
        }
    }

    // MARK: Workflows

    /// The workflow files of the repository's default branch.
    func workflowFiles(_ repo: RepoSlug) async throws -> [ContentEntry] {
        for directory in [".forgejo/workflows", ".gitea/workflows", ".github/workflows"] {
            do {
                let entries: [ContentEntry] = try await get("repos/\(repo.owner)/\(repo.name)/contents/\(directory)")
                let files = entries.filter { $0.type == "file" && ($0.name.hasSuffix(".yaml") || $0.name.hasSuffix(".yml")) }
                if !files.isEmpty { return files }
            } catch ForgeError.notFound {
                continue
            }
        }
        return []
    }

    func fileText(_ repo: RepoSlug, path: String) async throws -> String {
        let file: ContentFile = try await get("repos/\(repo.owner)/\(repo.name)/contents/\(path)")
        guard let data = Data(base64Encoded: file.content ?? "", options: .ignoreUnknownCharacters) else { throw ForgeError.notAnswer }
        return String(decoding: data, as: UTF8.self)
    }

    func dispatch(_ repo: RepoSlug, workflow file: String, ref: String, inputs: [String: String]) async throws {
        struct Body: Encodable {
            var ref: String
            var inputs: [String: String]
        }
        try await send("POST", "repos/\(repo.owner)/\(repo.name)/actions/workflows/\(file)/dispatches", body: Body(ref: ref, inputs: inputs))
    }

    func rerun(_ repo: RepoSlug, run id: Int) async throws {
        try await send("POST", "repos/\(repo.owner)/\(repo.name)/actions/runs/\(id)/rerun")
    }

    func rerun(_ repo: RepoSlug, job id: Int) async throws {
        try await send("POST", "repos/\(repo.owner)/\(repo.name)/actions/jobs/\(id)/rerun")
    }

    func cancel(_ repo: RepoSlug, run id: Int) async throws {
        try await send("POST", "repos/\(repo.owner)/\(repo.name)/actions/runs/\(id)/cancel")
    }

    // MARK: Releases

    /// The commits `head` has that `base` lacks.
    func compare(_ repo: RepoSlug, base: String, head: String) async throws -> [PullCommit] {
        let result: Comparison = try await get("repos/\(repo.owner)/\(repo.name)/compare/\(base)...\(head)")
        return result.commits ?? []
    }

    func createPull(_ repo: RepoSlug, head: String, base: String, title: String, body: String) async throws -> PullRequest {
        struct Body: Encodable {
            var head: String
            var base: String
            var title: String
            var body: String
        }
        let data = try await send("POST", "repos/\(repo.owner)/\(repo.name)/pulls", body: Body(head: head, base: base, title: title, body: body))
        do {
            return try Self.decoder.decode(PullRequest.self, from: data)
        } catch {
            throw ForgeError.notAnswer
        }
    }

    /// The part of a job's log after `offset` bytes. Forgejo serves the log
    /// while the job runs and honours Range, so following a log costs only
    /// the new bytes. Returns nil while there is no log yet.
    func jobLog(_ repo: RepoSlug, job id: Int, from offset: Int) async throws -> Data? {
        var request = try request("repos/\(repo.owner)/\(repo.name)/actions/jobs/\(id)/logs")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let asked = Date()
        let (data, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        Trace.note("GET job \(id) log took \(Int(Date().timeIntervalSince(asked) * 1000)) ms, \(data.count) B")
        guard let http = response as? HTTPURLResponse else { throw ForgeError.notAnswer }
        switch http.statusCode {
        case 206: return data
        case 200: return offset < data.count ? data.dropFirst(offset) : Data()
        case 416: return Data() // nothing new past offset
        case 404, 500: return nil // Forgejo answers 500 for a job no runner has taken yet
        case 401: throw ForgeError.unauthorized
        case 403: throw ForgeError.forbidden
        default: throw ForgeError.http(http.statusCode)
        }
    }

    // MARK: - Transport

    func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw ForgeError.notAnswer }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("token " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as _: T.Type = T.self) async throws -> T {
        let asked = Date()
        let (data, response) = try await session.data(for: request(path, query: query), delegate: AuthGuard.shared)
        Trace.note("GET \(path)\(query.isEmpty ? "" : "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")) took \(Int(Date().timeIntervalSince(asked) * 1000)) ms, \(data.count) B")
        guard let http = response as? HTTPURLResponse else { throw ForgeError.notAnswer }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw ForgeError.unauthorized
        case 403: throw ForgeError.forbidden
        case 404: throw ForgeError.notFound
        default: throw ForgeError.http(http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ForgeError.notAnswer
        }
    }

    /// Sends a change to the server and returns the answer's body.
    @discardableResult
    func send(_ method: String, _ path: String, body: some Encodable = NoBody()) async throws -> Data {
        var request = try request(path)
        request.httpMethod = method
        if !(body is NoBody) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw ForgeError.notAnswer }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ForgeError.unauthorized
        case 403: throw ForgeError.forbidden
        case 404: throw ForgeError.notFound
        default:
            // Forgejo explains refusals: {"message": "..."}.
            if let message = (try? JSONDecoder().decode(ServerMessage.self, from: data))?.message, !message.isEmpty {
                throw ForgeError.rejected(message)
            }
            throw ForgeError.http(http.statusCode)
        }
    }

    struct NoBody: Encodable {}
    struct ServerMessage: Decodable { var message: String }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
        }
        return decoder
    }()

    /// Forgejo writes RFC 3339 dates, with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
