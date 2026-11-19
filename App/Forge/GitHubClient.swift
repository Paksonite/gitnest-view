import Foundation

/// GitHub (github.com and GitHub Enterprise Server) in the app's Forgejo
/// model. Gitea copied much of GitHub's API, so repositories, pull requests,
/// commits and comments decode as they are; runs, jobs, checks, reviews and
/// notifications are translated.
struct GitHubClient: ForgeService {
    let host: String
    let token: String?
    let api: RestAPI
    var kind: ForgeKind { .github }

    init(host: String, token: String?, session: URLSession = .shared) {
        self.host = host
        self.token = token
        let base = host == "github.com" ? URL(string: "https://api.github.com/")! : URL(string: "https://\(host)/api/v3/")!
        var headers = ["X-GitHub-Api-Version": "2022-11-28"]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer " + token }
        api = RestAPI(base: base, headers: headers, session: session)
    }

    private func repo(_ slug: RepoSlug) -> String { "repos/\(slug.owner)/\(slug.name)" }
    private static func page(_ size: Int, _ page: Int = 1) -> [URLQueryItem] {
        [.init(name: "per_page", value: String(min(100, max(1, size)))), .init(name: "page", value: String(page))]
    }

    /// Reads a listing page by page.
    private func pages<T: Decodable>(_ path: String, query: [URLQueryItem] = [], maxPages: Int = 10) async throws -> [T] {
        var all: [T] = []
        for number in 1...maxPages {
            let batch: [T] = try await api.get(path, query: query + Self.page(100, number))
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    private func json(_ path: String, query: [URLQueryItem] = []) async throws -> Any {
        let (data, _) = try await api.data(api.request("GET", path, query: query))
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Who and where

    func version() async throws -> String {
        guard host != "github.com" else { return "github.com" }
        let meta = try await json("meta") as? [String: Any]
        return (meta?["installed_version"] as? String).map { "GitHub Enterprise \($0)" } ?? "GitHub Enterprise"
    }

    func currentUser() async throws -> ForgeUser {
        guard let user = Self.user(try await json("user")) else { throw ForgeError.notAnswer }
        return user
    }

    func organizations() async throws -> [ForgeOrg] {
        struct Org: Decodable { var id: Int; var login: String }
        let orgs: [Org] = try await pages("user/orgs")
        return orgs.map { ForgeOrg(id: $0.id, username: $0.login, name: $0.login, fullName: nil) }
    }

    func repositories(org: String) async throws -> [ForgeRepo] {
        // An organisation, or the user's own account (their personal workspace).
        do {
            return try await pages("orgs/\(org)/repos", query: [.init(name: "sort", value: "updated")])
        } catch ForgeError.notFound {
            return try await pages("users/\(org)/repos", query: [.init(name: "sort", value: "updated")])
        }
    }

    func userRepositories() async throws -> [ForgeRepo] {
        try await pages("user/repos", query: [.init(name: "affiliation", value: "owner,collaborator"), .init(name: "sort", value: "updated")])
    }

    // MARK: Pull requests

    func listPulls(_ slug: RepoSlug, state: String, limit: Int) async throws -> [PullRequest] {
        let list = try await json(repo(slug) + "/pulls", query: [
            .init(name: "state", value: state), .init(name: "sort", value: "updated"), .init(name: "direction", value: "desc"),
        ] + Self.page(limit)) as? [Any] ?? []
        return try list.map { try Self.pull($0) }
    }

    func pullRequest(_ slug: RepoSlug, number: Int) async throws -> PullRequest {
        try Self.pull(try await json(repo(slug) + "/pulls/\(number)"))
    }

    /// A pull request listing leaves out `merged`; merged_at tells.
    static func pull(_ object: Any) throws -> PullRequest {
        guard var item = object as? [String: Any] else { throw ForgeError.notAnswer }
        if item["merged"] == nil || item["merged"] is NSNull { item["merged"] = !(item["merged_at"] is NSNull || item["merged_at"] == nil) }
        return try Translate.decode(item)
    }

    func pullCommits(_ slug: RepoSlug, pull number: Int) async throws -> [PullCommit] {
        try await api.get(repo(slug) + "/pulls/\(number)/commits", query: Self.page(100))
    }

    func pullFiles(_ slug: RepoSlug, pull number: Int) async throws -> [PullFile] {
        try await pages(repo(slug) + "/pulls/\(number)/files", maxPages: 3)
    }

    func pullDiff(_ slug: RepoSlug, number: Int) async throws -> String {
        try await api.text(repo(slug) + "/pulls/\(number)", accept: "application/vnd.github.diff")
    }

    private func search(_ query: String) async throws -> [PullSearchHit] {
        let root = try await json("search/issues", query: [.init(name: "q", value: query), .init(name: "sort", value: "updated"), .init(name: "per_page", value: "50")]) as? [String: Any]
        return try (root?["items"] as? [[String: Any]] ?? []).map { item in
            var hit = item
            // "https://api.github.com/repos/owner/name" → owner/name.
            if let url = item["repository_url"] as? String, let range = url.range(of: "/repos/") {
                let full = String(url[range.upperBound...])
                hit["repository"] = ["name": full.split(separator: "/").last.map(String.init) ?? full, "full_name": full]
            }
            return try Translate.decode(hit) as PullSearchHit
        }
    }

    func myPullRequests() async throws -> [PullSearchHit] { try await search("is:pr is:open author:@me archived:false") }
    func reviewRequests() async throws -> [PullSearchHit] { try await search("is:pr is:open review-requested:@me archived:false") }
    func openPullRequests(owner: String) async throws -> [PullSearchHit] {
        do { return try await search("is:pr is:open org:\(owner) archived:false") } catch { return try await search("is:pr is:open user:\(owner) archived:false") }
    }

    func createPull(_ slug: RepoSlug, head: String, base: String, title: String, body: String) async throws -> PullRequest {
        let data = try await api.send("POST", repo(slug) + "/pulls", json: ["head": head, "base": base, "title": title, "body": body])
        return try Self.pull(try JSONSerialization.jsonObject(with: data))
    }

    func changePull(_ slug: RepoSlug, number: Int, title: String?, body: String?, state: String?, assignees: [String]?) async throws {
        var fields: [String: Any] = [:]
        if let title { fields["title"] = title }
        if let body { fields["body"] = body }
        if let state { fields["state"] = state }
        if let assignees { fields["assignees"] = assignees }
        // The issue endpoint takes assignees as well; the pull one does not.
        try await api.send("PATCH", repo(slug) + "/issues/\(number)", json: fields)
    }

    func updateBranch(_ slug: RepoSlug, number: Int, style: String) async throws {
        guard style == "merge" else {
            throw ForgeError.rejected("GitHub brings the base branch in only with a merge commit. Rebase the branch on your computer instead.")
        }
        try await api.send("PUT", repo(slug) + "/pulls/\(number)/update-branch", json: [:])
    }

    func merge(_ slug: RepoSlug, number: Int, style: String, deleteBranch: Bool, head: String, title: String?) async throws {
        let method = switch style {
        case "squash": "squash"
        case "rebase", "rebase-merge", "fast-forward-only": "rebase"
        default: "merge"
        }
        var body: [String: Any] = ["merge_method": method, "sha": head]
        if let title, !title.isEmpty { body["commit_title"] = title }
        try await api.send("PUT", repo(slug) + "/pulls/\(number)/merge", json: body)
        if deleteBranch {
            // Only a branch of this repository; a fork's branch is its owner's.
            let pull = try await json(repo(slug) + "/pulls/\(number)") as? [String: Any]
            let headPart = pull?["head"] as? [String: Any]
            let headRepo = (headPart?["repo"] as? [String: Any])?["full_name"] as? String
            if let ref = headPart?["ref"] as? String, headRepo?.lowercased() == "\(slug.owner)/\(slug.name)".lowercased() {
                try? await api.send("DELETE", repo(slug) + "/git/refs/heads/\(ref)")
            }
        }
    }

    // MARK: Reviews and talk

    func reviews(_ slug: RepoSlug, pull number: Int) async throws -> [Review] {
        let list = try await json(repo(slug) + "/pulls/\(number)/reviews", query: Self.page(100)) as? [[String: Any]] ?? []
        return try list.compactMap { item -> Review? in
            let state = item["state"] as? String ?? ""
            guard state != "PENDING" else { return nil } // the user's own unsent draft
            var review = item
            review["state"] = switch state {
            case "CHANGES_REQUESTED": "REQUEST_CHANGES"
            case "COMMENTED": "COMMENT"
            case "DISMISSED": "COMMENT"
            default: state
            }
            review["dismissed"] = state == "DISMISSED"
            review["user"] = Self.userJSON(item["user"])
            return try Translate.decode(review)
        }
    }

    func submitReview(_ slug: RepoSlug, number: Int, event: String, body: String, commit: String) async throws {
        let verdict = switch event {
        case "APPROVED": "APPROVE"
        case "REQUEST_CHANGES": "REQUEST_CHANGES"
        default: "COMMENT"
        }
        var fields: [String: Any] = ["event": verdict, "commit_id": commit]
        if !body.isEmpty { fields["body"] = body }
        try await api.send("POST", repo(slug) + "/pulls/\(number)/reviews", json: fields)
    }

    func reviewComments(_ slug: RepoSlug, number: Int, review: Int) async throws -> [ReviewComment] {
        try await api.get(repo(slug) + "/pulls/\(number)/reviews/\(review)/comments", query: Self.page(100))
    }

    func comments(_ slug: RepoSlug, number: Int) async throws -> [IssueComment] {
        try await pages(repo(slug) + "/issues/\(number)/comments", maxPages: 3)
    }

    func comment(_ slug: RepoSlug, number: Int, body: String) async throws {
        try await api.send("POST", repo(slug) + "/issues/\(number)/comments", json: ["body": body])
    }

    func reviewers(_ slug: RepoSlug) async throws -> [ForgeUser] { try await assignees(slug) }

    func assignees(_ slug: RepoSlug) async throws -> [ForgeUser] {
        let list = try await json(repo(slug) + "/assignees", query: Self.page(100)) as? [Any] ?? []
        return list.compactMap(Self.user)
    }

    func askReview(_ slug: RepoSlug, number: Int, from logins: [String], withdraw: Bool) async throws {
        try await api.send(withdraw ? "DELETE" : "POST", repo(slug) + "/pulls/\(number)/requested_reviewers", json: ["reviewers": logins])
    }

    func labels(_ slug: RepoSlug) async throws -> [ForgeLabel] {
        try await pages(repo(slug) + "/labels", maxPages: 3)
    }

    func setLabels(_ slug: RepoSlug, number: Int, ids: [Int]) async throws {
        // GitHub names labels; the app holds their ids.
        let known = try await labels(slug)
        let names = ids.compactMap { id in known.first { $0.id == id }?.name }
        try await api.send("PUT", repo(slug) + "/issues/\(number)/labels", json: ["labels": names])
    }

    // MARK: Branches and checks

    func branch(_ slug: RepoSlug, name: String) async throws -> BranchInfo {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let info = try await json(repo(slug) + "/branches/\(encoded)") as? [String: Any]
        let protected = info?["protected"] as? Bool ?? false
        // Rulesets are readable with read access; classic protection by admins only.
        var required: Int?
        if let rules = try? await json(repo(slug) + "/rules/branches/\(encoded)") as? [[String: Any]] {
            required = rules.filter { $0["type"] as? String == "pull_request" }
                .compactMap { ($0["parameters"] as? [String: Any])?["required_approving_review_count"] as? Int }.max()
        }
        if protected, required == nil, let rule = try? await json(repo(slug) + "/branches/\(encoded)/protection") as? [String: Any] {
            required = (rule["required_pull_request_reviews"] as? [String: Any])?["required_approving_review_count"] as? Int
        }
        return try Translate.decode(["name": name, "protected": protected || (required ?? 0) > 0, "required_approvals": required as Any])
    }

    func branches(_ slug: RepoSlug) async throws -> [String] {
        struct Branch: Decodable { var name: String }
        let all: [Branch] = try await pages(repo(slug) + "/branches", maxPages: 6)
        return all.map(\.name)
    }

    /// Read per branch in branch(_:name:): rulesets answer anyone who can read.
    func branchProtections(_ slug: RepoSlug) async throws -> [BranchProtection] { [] }

    func compare(_ slug: RepoSlug, base: String, head: String) async throws -> [PullCommit] {
        let result: Comparison = try await api.get(repo(slug) + "/compare/\(base)...\(head)")
        return result.commits ?? []
    }

    /// Commit statuses and check runs together: GitHub Actions reports only the latter.
    func combinedStatus(_ slug: RepoSlug, ref: String) async throws -> CombinedStatus {
        async let classic = json(repo(slug) + "/commits/\(ref)/status")
        async let checks = try? json(repo(slug) + "/commits/\(ref)/check-runs", query: Self.page(100))
        let status = try await classic as? [String: Any] ?? [:]
        var all: [[String: Any]] = (status["statuses"] as? [[String: Any]] ?? []).map { item in
            ["id": item["id"] ?? 0, "status": item["state"] ?? "pending", "context": item["context"] ?? "",
             "description": item["description"] ?? NSNull(), "target_url": item["target_url"] ?? NSNull()]
        }
        for run in (await checks as? [String: Any])?["check_runs"] as? [[String: Any]] ?? [] {
            let url = run["html_url"] as? String ?? run["details_url"] as? String
            var check: [String: Any] = [
                "id": run["id"] ?? 0, "status": Self.state(run["status"], run["conclusion"]), "context": run["name"] ?? "",
                "description": ((run["output"] as? [String: Any])?["title"] as? String) ?? NSNull(), "target_url": url ?? NSNull(),
            ]
            if (run["app"] as? [String: Any])?["slug"] as? String == "github-actions", let id = run["id"] as? Int {
                check["gnv_job_id"] = id
                if let url, let runID = Self.runID(in: url) { check["gnv_run_id"] = runID }
            }
            all.append(check)
        }
        return try Translate.decode(["state": status["state"] ?? "pending", "sha": status["sha"] ?? ref, "statuses": all])
    }

    /// ".../actions/runs/123/job/456" → 123.
    static func runID(in url: String) -> Int? {
        let parts = url.split(separator: "/")
        guard let index = parts.firstIndex(of: "runs"), parts.count > index + 1 else { return nil }
        return Int(parts[index + 1])
    }

    /// GitHub's status and conclusion as one word Forgejo would use.
    static func state(_ status: Any?, _ conclusion: Any?) -> String {
        switch status as? String {
        case "completed":
            switch conclusion as? String {
            case "success": "success"
            case "failure", "timed_out", "startup_failure": "failure"
            case "cancelled": "cancelled"
            case "skipped", "neutral", "stale": "skipped"
            case "action_required": "waiting"
            default: "unknown"
            }
        case "in_progress": "running"
        case "queued", "waiting", "pending", "requested": "waiting"
        default: "unknown"
        }
    }

    // MARK: Actions

    func listRuns(_ slug: RepoSlug, limit: Int, headSHA: String?, branch: String?) async throws -> [WorkflowRun] {
        var query = Self.page(limit)
        if let headSHA { query.append(.init(name: "head_sha", value: headSHA)) }
        if let branch { query.append(.init(name: "branch", value: branch)) }
        let root = try await json(repo(slug) + "/actions/runs", query: query) as? [String: Any]
        return try (root?["workflow_runs"] as? [[String: Any]] ?? []).map(Self.run)
    }

    static func run(_ item: [String: Any]) throws -> WorkflowRun {
        let status = state(item["status"], item["conclusion"])
        let finished = item["status"] as? String == "completed"
        let path = item["path"] as? String ?? ""
        return try Translate.decode([
            "id": item["id"] ?? 0, "title": item["display_title"] ?? item["name"] ?? "",
            "workflow_id": path.isEmpty ? NSNull() : ((path.split(separator: "@").first.map(String.init) ?? path) as NSString).lastPathComponent,
            "index_in_repo": item["run_number"] ?? NSNull(), "prettyref": item["head_branch"] ?? NSNull(),
            "commit_sha": item["head_sha"] ?? NSNull(), "event": item["event"] ?? NSNull(), "trigger_event": item["event"] ?? NSNull(),
            "status": status, "started": item["run_started_at"] ?? NSNull(), "stopped": finished ? (item["updated_at"] ?? NSNull()) : NSNull(),
            "created": item["created_at"] ?? NSNull(), "html_url": item["html_url"] ?? NSNull(),
            "trigger_user": userJSON(item["triggering_actor"] ?? item["actor"]),
        ])
    }

    static func job(_ item: [String: Any]) throws -> WorkflowJob {
        let started = item["status"] as? String != "queued" && !(item["started_at"] is NSNull)
        let steps = (item["steps"] as? [[String: Any]] ?? []).map { step -> [String: Any] in
            ["number": step["number"] ?? 0, "name": step["name"] ?? "", "status": state(step["status"], step["conclusion"]),
             "started": step["started_at"] ?? NSNull(), "stopped": step["completed_at"] ?? NSNull()]
        }
        return try Translate.decode([
            "id": item["id"] ?? 0, "run_id": item["run_id"] ?? NSNull(), "name": item["name"] ?? "",
            "status": state(item["status"], item["conclusion"]), "attempt": item["run_attempt"] ?? NSNull(),
            "task_id": started ? (item["id"] ?? 0) : 0, "runs_on": item["labels"] ?? [], "html_url": item["html_url"] ?? NSNull(),
            "steps": steps,
        ])
    }

    func jobs(_ slug: RepoSlug, run id: Int) async throws -> [WorkflowJob] {
        let root = try await json(repo(slug) + "/actions/runs/\(id)/jobs", query: Self.page(100)) as? [String: Any]
        return try (root?["jobs"] as? [[String: Any]] ?? []).map(Self.job)
    }

    func job(_ slug: RepoSlug, id: Int) async throws -> WorkflowJob {
        guard let item = try await json(repo(slug) + "/actions/jobs/\(id)") as? [String: Any] else { throw ForgeError.notAnswer }
        return try Self.job(item)
    }

    /// GitHub hands out a job's log once the job has finished; until then nil.
    func jobLog(_ slug: RepoSlug, job id: Int, from offset: Int) async throws -> Data? {
        do {
            let (data, _) = try await api.data(api.request("GET", repo(slug) + "/actions/jobs/\(id)/logs", accept: "application/vnd.github+json"))
            return offset < data.count ? data.dropFirst(offset) : Data()
        } catch ForgeError.notFound {
            return nil
        } catch ForgeError.rejected {
            return nil
        }
    }

    /// No log per step on GitHub: the job's log holds them all.
    func readStepLog(_ slug: RepoSlug, job id: Int, step: Int, from offset: Int) async throws -> Data? { nil }

    func workflowFiles(_ slug: RepoSlug) async throws -> [ContentEntry] {
        do {
            let entries: [ContentEntry] = try await api.get(repo(slug) + "/contents/.github/workflows")
            return entries.filter { $0.type == "file" && ($0.name.hasSuffix(".yaml") || $0.name.hasSuffix(".yml")) }
        } catch ForgeError.notFound {
            return []
        }
    }

    func fileText(_ slug: RepoSlug, path: String) async throws -> String {
        let file: ContentFile = try await api.get(repo(slug) + "/contents/\(path)")
        guard let data = Data(base64Encoded: file.content ?? "", options: .ignoreUnknownCharacters) else { throw ForgeError.notAnswer }
        return String(decoding: data, as: UTF8.self)
    }

    func dispatch(_ slug: RepoSlug, workflow file: String, ref: String, inputs: [String: String]) async throws {
        try await api.send("POST", repo(slug) + "/actions/workflows/\(file)/dispatches", json: ["ref": ref, "inputs": inputs])
    }

    func rerun(_ slug: RepoSlug, run id: Int) async throws { try await api.send("POST", repo(slug) + "/actions/runs/\(id)/rerun") }
    func rerun(_ slug: RepoSlug, job id: Int) async throws { try await api.send("POST", repo(slug) + "/actions/jobs/\(id)/rerun") }
    func cancel(_ slug: RepoSlug, run id: Int) async throws { try await api.send("POST", repo(slug) + "/actions/runs/\(id)/cancel") }

    // MARK: Around

    func notifications() async throws -> [ForgeNotification] {
        let list = try await json("notifications", query: Self.page(30)) as? [[String: Any]] ?? []
        return try list.compactMap { item -> ForgeNotification? in
            guard let id = Int(item["id"] as? String ?? "") else { return nil }
            let subject = item["subject"] as? [String: Any] ?? [:]
            let api = subject["url"] as? String
            let type = switch subject["type"] as? String {
            case "PullRequest": "Pull"
            case let other?: other
            case nil: "Issue"
            }
            var about: [String: Any] = ["title": subject["title"] ?? "", "type": type]
            if let api {
                about["url"] = api
                about["html_url"] = webURL(api)
            }
            let repository: [String: Any] = ["full_name": (item["repository"] as? [String: Any])?["full_name"] ?? ""]
            let fields: [String: Any] = ["id": id, "unread": item["unread"] ?? true, "updated_at": item["updated_at"] ?? NSNull(), "subject": about, "repository": repository]
            return try Translate.decode(fields)
        }
    }

    /// "https://api.github.com/repos/o/r/pulls/5" → "https://github.com/o/r/pull/5".
    func webURL(_ api: String) -> String {
        let web = host == "github.com" ? "https://github.com/" : "https://\(host)/"
        guard let range = api.range(of: "/repos/") else { return api }
        return web + api[range.upperBound...].replacingOccurrences(of: "/pulls/", with: "/pull/")
    }

    func markRead(notification id: Int) async throws { try await api.send("PATCH", "notifications/threads/\(id)") }

    func releases(_ slug: RepoSlug) async throws -> [ForgeRelease] {
        try await api.get(repo(slug) + "/releases", query: Self.page(50))
    }

    func actionVariables(_ slug: RepoSlug) async throws -> [ActionVariable] {
        let root = try await json(repo(slug) + "/actions/variables", query: Self.page(100)) as? [String: Any]
        return (root?["variables"] as? [[String: Any]] ?? []).compactMap { item in
            (item["name"] as? String).map { ActionVariable(name: $0, data: item["value"] as? String) }
        }
    }

    func actionSecrets(_ slug: RepoSlug) async throws -> [ActionSecret] {
        let root = try await json(repo(slug) + "/actions/secrets", query: Self.page(100)) as? [String: Any]
        return (root?["secrets"] as? [[String: Any]] ?? []).compactMap { ($0["name"] as? String).map(ActionSecret.init) }
    }

    // MARK: The token

    /// A classic token lists its scopes in X-OAuth-Scopes; a fine-grained
    /// one does not, and is asked the harmless questions instead.
    func permissions() async -> [PermissionCheck] {
        guard let (_, response) = try? await api.data(api.request("GET", "user")) else {
            return [PermissionCheck(id: "user", feature: "Sign in and know who you are", scope: "token", writes: false, answer: .no)]
        }
        let features: [(String, String, String, Bool)] = [
            ("user", "Sign in and know who you are", "(any)", false),
            ("repos", "List repositories, read pipelines and logs", "repo", false),
            ("orgs", "Workspaces (organisations)", "read:org", false),
            ("issues", "Pull requests, reviews and the Inbox", "repo", false),
            ("notes", "Unread marks from the server", "notifications", false),
            ("write-repo", "Merge, open pull requests, run and re-run pipelines", "repo, workflow", true),
            ("write-issue", "Comment, review, labels, reviewers", "repo", true),
            ("write-notes", "Mark as read", "notifications", true),
        ]
        if let header = response.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            let scopes = Set(header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            func has(_ scope: String) -> Bool {
                scope == "(any)" || scope.split(separator: ",").allSatisfy { part in
                    let name = part.trimmingCharacters(in: .whitespaces)
                    return scopes.contains(name) || (name == "read:org" && (scopes.contains("admin:org") || scopes.contains("write:org")))
                }
            }
            return features.map { PermissionCheck(id: $0.0, feature: $0.1, scope: $0.2, writes: $0.3, answer: has($0.2) ? .yes : .no) }
        }
        let probes: [PermissionProbe.Probe] = [
            ("user", features[0].1, "Metadata", false, "GET", "user"),
            ("repos", features[1].1, "Contents, Actions (read)", false, "GET", "user/repos?per_page=1"),
            ("orgs", features[2].1, "Members (read)", false, "GET", "user/orgs?per_page=1"),
            ("issues", features[3].1, "Pull requests (read)", false, "GET", "search/issues?q=is:pr+author:@me&per_page=1"),
            ("notes", features[4].1, "classic token only", false, "GET", "notifications?per_page=1"),
            ("write-repo", features[5].1, "Contents, Actions (write)", true, "POST", "repos/gitnest-view-probe/none/pulls"),
            ("write-issue", features[6].1, "Pull requests (write)", true, "POST", "repos/gitnest-view-probe/none/issues/0/comments"),
            ("write-notes", features[7].1, "classic token only", true, "PATCH", "notifications/threads/0"),
        ]
        let api = api
        return await PermissionProbe.run(probes) { await api.status($0, $1) }
    }

    // MARK: Shapes

    static func userJSON(_ object: Any?) -> Any {
        guard let user = object as? [String: Any] else { return NSNull() }
        return ["id": user["id"] ?? 0, "login": user["login"] ?? "", "full_name": user["name"] ?? NSNull(), "avatar_url": user["avatar_url"] ?? NSNull()]
    }

    static func user(_ object: Any?) -> ForgeUser? {
        (userJSON(object) as? [String: Any]).flatMap { try? Translate.decode($0) }
    }
}

/// Turns a server's JSON, rearranged into Forgejo's shape, into the app's models.
enum Translate {
    static func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        guard JSONSerialization.isValidJSONObject(object) else { throw ForgeError.notAnswer }
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            return try ForgejoClient.decoder.decode(T.self, from: data)
        } catch {
            Trace.note("translate \(T.self) failed: \(error)")
            throw ForgeError.notAnswer
        }
    }
}
