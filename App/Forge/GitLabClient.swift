import Foundation

/// GitLab (self-hosted or gitlab.com) in the app's Forgejo model:
/// groups are workspaces, projects repositories, merge requests pull
/// requests (numbered by their iid), pipelines runs, and to-dos the
/// notifications.
struct GitLabClient: ForgeService {
    let host: String
    let token: String?
    let api: RestAPI
    var kind: ForgeKind { .gitlab }

    init(host: String, token: String?, session: URLSession = .shared) {
        self.host = host
        self.token = token
        var headers: [String: String] = [:]
        if let token, !token.isEmpty { headers["PRIVATE-TOKEN"] = token }
        api = RestAPI(base: URL(string: "https://\(host)/api/v4/")!, headers: headers, session: session)
    }

    /// "group/sub/name" as one path segment, the way GitLab names a project.
    private func project(_ slug: RepoSlug) -> String {
        "projects/" + Self.escape("\(slug.owner)/\(slug.name)")
    }

    private func mr(_ slug: RepoSlug, _ iid: Int) -> String { project(slug) + "/merge_requests/\(iid)" }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
    }

    private func json(_ path: String, query: [URLQueryItem] = []) async throws -> Any {
        let (data, _) = try await api.data(api.request("GET", path, query: query))
        return try JSONSerialization.jsonObject(with: data)
    }

    private func list(_ path: String, query: [URLQueryItem] = [], perPage: Int = 100, maxPages: Int = 10) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        for page in 1...maxPages {
            let batch = try await json(path, query: query + [.init(name: "per_page", value: String(perPage)), .init(name: "page", value: String(page))]) as? [[String: Any]] ?? []
            all += batch
            if batch.count < perPage { break }
        }
        return all
    }

    // MARK: Who and where

    func version() async throws -> String {
        let root = try await json("version") as? [String: Any]
        return "GitLab " + (root?["version"] as? String ?? "")
    }

    func currentUser() async throws -> ForgeUser {
        guard let user = Self.user(try await json("user")) else { throw ForgeError.notAnswer }
        return user
    }

    /// Top-level groups the user belongs to; a workspace shows its subgroups' projects too.
    func organizations() async throws -> [ForgeOrg] {
        let groups = try await list("groups", query: [.init(name: "min_access_level", value: "10"), .init(name: "top_level_only", value: "true")])
        return groups.compactMap { group in
            guard let id = group["id"] as? Int, let path = group["full_path"] as? String else { return nil }
            return ForgeOrg(id: id, username: path, name: path, fullName: group["full_name"] as? String)
        }
    }

    func repositories(org: String) async throws -> [ForgeRepo] {
        let query: [URLQueryItem] = [.init(name: "include_subgroups", value: "true"), .init(name: "archived", value: "false"),
                                     .init(name: "order_by", value: "last_activity_at"), .init(name: "with_shared", value: "false"),
                                     .init(name: "statistics", value: "true")]
        do {
            return try await list("groups/\(Self.escape(org))/projects", query: query).compactMap(Self.repo)
        } catch ForgeError.notFound {
            // The user's own namespace.
            return try await list("users/\(Self.escape(org))/projects", query: [.init(name: "order_by", value: "last_activity_at")]).compactMap(Self.repo)
        }
    }

    func userRepositories() async throws -> [ForgeRepo] {
        try await list("projects", query: [.init(name: "membership", value: "true"), .init(name: "archived", value: "false"),
                                          .init(name: "order_by", value: "last_activity_at"), .init(name: "statistics", value: "true")], maxPages: 5).compactMap(Self.repo)
    }

    static func repo(_ item: [String: Any]) -> ForgeRepo? {
        let namespace = item["namespace"] as? [String: Any] ?? [:]
        let ownerPath = namespace["full_path"] as? String ?? ""
        let owner: [String: Any] = ["id": namespace["id"] ?? 0, "login": ownerPath, "full_name": namespace["name"] ?? NSNull(), "avatar_url": namespace["avatar_url"] ?? NSNull()]
        let pipelines = (item["builds_access_level"] as? String).map { $0 != "disabled" } ?? (item["jobs_enabled"] as? Bool)
        return try? Translate.decode([
            "id": item["id"] ?? 0, "name": item["path"] ?? item["name"] ?? "", "full_name": item["path_with_namespace"] ?? "",
            "owner": owner, "description": item["description"] ?? NSNull(), "private": (item["visibility"] as? String).map { $0 != "public" } ?? NSNull(),
            "archived": item["archived"] ?? false, "empty": item["empty_repo"] ?? false, "fork": item["forked_from_project"] != nil,
            "mirror": item["mirror"] ?? false, "default_branch": item["default_branch"] ?? NSNull(),
            "ssh_url": item["ssh_url_to_repo"] ?? NSNull(), "clone_url": item["http_url_to_repo"] ?? NSNull(), "html_url": item["web_url"] ?? NSNull(),
            "open_pr_counter": item["open_merge_requests_count"] ?? NSNull(), "has_actions": pipelines ?? NSNull(),
            "updated_at": item["last_activity_at"] ?? item["updated_at"] ?? NSNull(),
            "size": ((item["statistics"] as? [String: Any])?["repository_size"] as? Int).map { $0 / 1024 } ?? NSNull(),
        ])
    }

    func repositorySize(_ slug: RepoSlug) async -> Int? {
        let item = try? await json(project(slug), query: [.init(name: "statistics", value: "true")]) as? [String: Any]
        return ((item?["statistics"] as? [String: Any])?["repository_size"] as? Int).map { $0 / 1024 }
    }

    // MARK: Merge requests

    func listPulls(_ slug: RepoSlug, state: String, limit: Int) async throws -> [PullRequest] {
        // Closed in the app's sense is GitLab's closed and merged.
        let wanted = state == "open" ? "opened" : (state == "closed" ? nil : "all")
        var query: [URLQueryItem] = [.init(name: "order_by", value: "updated_at"), .init(name: "per_page", value: String(min(100, limit)))]
        if let wanted { query.append(.init(name: "state", value: wanted)) }
        var items = try await json(project(slug) + "/merge_requests", query: query) as? [[String: Any]] ?? []
        if state == "closed" { items = items.filter { ["closed", "merged"].contains($0["state"] as? String ?? "") } }
        return items.compactMap { try? Self.pull($0) }
    }

    func pullRequest(_ slug: RepoSlug, number: Int) async throws -> PullRequest {
        guard let item = try await json(mr(slug, number)) as? [String: Any] else { throw ForgeError.notAnswer }
        return try Self.pull(item)
    }

    static func pull(_ item: [String: Any]) throws -> PullRequest {
        let state = item["state"] as? String ?? "opened"
        let refs = item["diff_refs"] as? [String: Any]
        let source = item["source_branch"] as? String ?? ""
        let changes = (item["changes_count"] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "+"))) }
        let mergeable: Any = switch item["detailed_merge_status"] as? String {
        case "mergeable": true
        case "conflict", "broken_status", "need_rebase": false
        default: NSNull()
        }
        let labels = (item["labels"] as? [Any] ?? []).compactMap { label -> [String: Any]? in
            if let name = label as? String { return ["name": name] }
            guard let map = label as? [String: Any] else { return nil }
            return ["id": map["id"] ?? NSNull(), "name": map["name"] ?? "", "color": (map["color"] as? String)?.replacingOccurrences(of: "#", with: "") ?? NSNull()]
        }
        var pull: [String: Any] = [:]
        pull["number"] = item["iid"] ?? 0
        pull["title"] = item["title"] ?? ""
        pull["body"] = item["description"] ?? NSNull()
        pull["state"] = state == "opened" ? "open" : "closed"
        pull["draft"] = item["draft"] ?? item["work_in_progress"] ?? false
        pull["merged"] = state == "merged"
        pull["mergeable"] = mergeable
        pull["user"] = userJSON(item["author"])
        pull["requested_reviewers"] = people(item["reviewers"])
        pull["assignees"] = people(item["assignees"])
        pull["html_url"] = item["web_url"] ?? ""
        let target: Any = item["target_branch"] ?? ""
        pull["base"] = ["ref": target, "sha": refs?["base_sha"] ?? "", "label": target] as [String: Any]
        let head: Any = item["sha"] ?? refs?["head_sha"] ?? ""
        pull["head"] = ["ref": source, "sha": head, "label": source] as [String: Any]
        pull["comments"] = item["user_notes_count"] ?? 0
        pull["changed_files"] = changes.map { $0 as Any } ?? NSNull()
        pull["created_at"] = item["created_at"] ?? NSNull()
        pull["updated_at"] = item["updated_at"] ?? NSNull()
        pull["merged_at"] = item["merged_at"] ?? NSNull()
        pull["labels"] = labels
        pull["merge_commit_sha"] = item["merge_commit_sha"] ?? item["squash_commit_sha"] ?? NSNull()
        return try Translate.decode(pull)
    }

    func pullCommits(_ slug: RepoSlug, pull number: Int) async throws -> [PullCommit] {
        try await list(mr(slug, number) + "/commits", maxPages: 2).compactMap(Self.commit)
    }

    static func commit(_ item: [String: Any]) -> PullCommit? {
        try? Translate.decode([
            "sha": item["id"] ?? "",
            "commit": ["message": item["message"] ?? item["title"] ?? "", "author": ["name": item["author_name"] ?? NSNull(), "date": item["authored_date"] ?? item["created_at"] ?? NSNull()]],
        ])
    }

    private func diffs(_ slug: RepoSlug, _ number: Int) async throws -> [[String: Any]] {
        do {
            return try await list(mr(slug, number) + "/diffs", maxPages: 5)
        } catch ForgeError.notFound {
            // Before GitLab 15.7: the changes endpoint.
            let root = try await json(mr(slug, number) + "/changes") as? [String: Any]
            return root?["changes"] as? [[String: Any]] ?? []
        }
    }

    func pullFiles(_ slug: RepoSlug, pull number: Int) async throws -> [PullFile] {
        try await diffs(slug, number).compactMap { item in
            let diff = item["diff"] as? String ?? ""
            var added = 0, removed = 0
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 } else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
            }
            let status = item["new_file"] as? Bool == true ? "added" : item["deleted_file"] as? Bool == true ? "removed" : item["renamed_file"] as? Bool == true ? "renamed" : "modified"
            return try? Translate.decode(["filename": item["new_path"] ?? item["old_path"] ?? "", "status": status, "additions": added, "deletions": removed])
        }
    }

    /// GitLab sends each file's hunks; put together as `git diff` prints them.
    func pullDiff(_ slug: RepoSlug, number: Int) async throws -> String {
        try await diffs(slug, number).map { item in
            let old = item["old_path"] as? String ?? "", new = item["new_path"] as? String ?? old
            let created = item["new_file"] as? Bool == true, deleted = item["deleted_file"] as? Bool == true
            var text = "diff --git a/\(old) b/\(new)\n"
            if created { text += "new file mode \(item["b_mode"] as? String ?? "100644")\n" }
            if deleted { text += "deleted file mode \(item["a_mode"] as? String ?? "100644")\n" }
            if old != new { text += "rename from \(old)\nrename to \(new)\n" }
            let body = item["diff"] as? String ?? ""
            if !body.isEmpty {
                text += "--- \(created ? "/dev/null" : "a/" + old)\n+++ \(deleted ? "/dev/null" : "b/" + new)\n" + body
                if !body.hasSuffix("\n") { text += "\n" }
            }
            return text
        }.joined()
    }

    private func search(_ query: [URLQueryItem], path: String = "merge_requests") async throws -> [PullSearchHit] {
        let items = try await json(path, query: query + [.init(name: "state", value: "opened"), .init(name: "per_page", value: "50"), .init(name: "order_by", value: "updated_at")]) as? [[String: Any]] ?? []
        return items.compactMap { item in
            // "group/sub/name!12" names the project.
            let reference = (item["references"] as? [String: Any])?["full"] as? String ?? ""
            let full = reference.split(separator: "!").first.map(String.init) ?? ""
            return try? Translate.decode([
                "id": item["id"] ?? 0, "number": item["iid"] ?? 0, "title": item["title"] ?? "", "html_url": item["web_url"] ?? NSNull(),
                "user": Self.userJSON(item["author"]), "updated_at": item["updated_at"] ?? NSNull(),
                "repository": ["name": full.split(separator: "/").last.map(String.init) ?? full, "full_name": full],
            ])
        }
    }

    func myPullRequests() async throws -> [PullSearchHit] { try await search([.init(name: "scope", value: "created_by_me")]) }

    func reviewRequests() async throws -> [PullSearchHit] {
        let me = try await currentUser()
        return try await search([.init(name: "scope", value: "all"), .init(name: "reviewer_id", value: String(me.id))])
    }

    func openPullRequests(owner: String) async throws -> [PullSearchHit] {
        do {
            return try await search([], path: "groups/\(Self.escape(owner))/merge_requests")
        } catch ForgeError.notFound {
            return try await search([.init(name: "scope", value: "all"), .init(name: "author_username", value: owner)])
        }
    }

    func createPull(_ slug: RepoSlug, head: String, base: String, title: String, body: String) async throws -> PullRequest {
        let data = try await api.send("POST", project(slug) + "/merge_requests", json: [
            "source_branch": head, "target_branch": base, "title": title, "description": body, "remove_source_branch": false,
        ])
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ForgeError.notAnswer }
        return try Self.pull(item)
    }

    func changePull(_ slug: RepoSlug, number: Int, title: String?, body: String?, state: String?, assignees: [String]?) async throws {
        var fields: [String: Any] = [:]
        if let title { fields["title"] = title }
        if let body { fields["description"] = body }
        if let state { fields["state_event"] = state == "closed" ? "close" : "reopen" }
        if let assignees { fields["assignee_ids"] = try await userIDs(assignees) }
        try await api.send("PUT", mr(slug, number), json: fields)
    }

    func updateBranch(_ slug: RepoSlug, number: Int, style: String) async throws {
        guard style == "rebase" else {
            throw ForgeError.rejected("GitLab brings the target branch in only by rebasing the merge request's branch. Choose Rebase, or merge on your computer.")
        }
        try await api.send("PUT", mr(slug, number) + "/rebase")
    }

    func merge(_ slug: RepoSlug, number: Int, style: String, deleteBranch: Bool, head: String, title: String?) async throws {
        var fields: [String: Any] = ["sha": head, "should_remove_source_branch": deleteBranch, "squash": style == "squash"]
        if let title, !title.isEmpty { fields[style == "squash" ? "squash_commit_message" : "merge_commit_message"] = title }
        try await api.send("PUT", mr(slug, number) + "/merge", json: fields)
    }

    // MARK: Reviews and talk

    /// Approvals as APPROVED reviews; reviewers who asked for changes
    /// (GitLab 17+) as REQUEST_CHANGES.
    func reviews(_ slug: RepoSlug, pull number: Int) async throws -> [Review] {
        var reviews: [[String: Any]] = []
        if let approvals = try? await json(mr(slug, number) + "/approvals") as? [String: Any] {
            for entry in approvals["approved_by"] as? [[String: Any]] ?? [] {
                guard let user = entry["user"] as? [String: Any] else { continue }
                reviews.append(["id": user["id"] ?? 0, "user": Self.userJSON(user), "state": "APPROVED", "submitted_at": approvals["updated_at"] ?? NSNull()])
            }
        }
        if let reviewers = try? await json(mr(slug, number) + "/reviewers") as? [[String: Any]] {
            for entry in reviewers {
                guard let user = entry["user"] as? [String: Any], let id = user["id"] as? Int else { continue }
                let state: String? = switch entry["state"] as? String {
                case "requested_changes": "REQUEST_CHANGES"
                case "reviewed": "COMMENT"
                default: nil
                }
                guard let state, !reviews.contains(where: { ($0["id"] as? Int) == id }) else { continue }
                reviews.append(["id": id, "user": Self.userJSON(user), "state": state, "submitted_at": entry["created_at"] ?? NSNull()])
            }
        }
        return reviews.compactMap { try? Translate.decode($0) }
    }

    func submitReview(_ slug: RepoSlug, number: Int, event: String, body: String, commit: String) async throws {
        switch event {
        case "APPROVED":
            try await api.send("POST", mr(slug, number) + "/approve", json: ["sha": commit])
            if !body.isEmpty { try await comment(slug, number: number, body: body) }
        case "REQUEST_CHANGES":
            // GitLab has no "request changes" in its API: the words go as a
            // comment, and an earlier approval of the user's is withdrawn.
            try? await api.send("POST", mr(slug, number) + "/unapprove")
            try await comment(slug, number: number, body: body.isEmpty ? "Changes requested." : body)
        default:
            try await comment(slug, number: number, body: body)
        }
    }

    /// Line comments come with the merge request's discussions; GitLab does
    /// not group them by review, so they come once, under the first review.
    func reviewComments(_ slug: RepoSlug, number: Int, review: Int) async throws -> [ReviewComment] {
        let first = try await reviews(slug, pull: number).first?.id
        guard review == first else { return [] }
        return try await list(mr(slug, number) + "/notes", query: [.init(name: "sort", value: "asc")], maxPages: 5)
            .filter { $0["type"] as? String == "DiffNote" && $0["system"] as? Bool != true }
            .compactMap { note in
                let position = note["position"] as? [String: Any]
                return try? Translate.decode([
                    "id": note["id"] ?? 0, "user": Self.userJSON(note["author"]), "body": note["body"] ?? "",
                    "path": position?["new_path"] ?? position?["old_path"] ?? NSNull(), "position": position?["new_line"] ?? position?["old_line"] ?? NSNull(),
                    "created_at": note["created_at"] ?? NSNull(), "resolver": note["resolved"] as? Bool == true ? Self.userJSON(note["resolved_by"]) : NSNull(),
                ])
            }
    }

    func comments(_ slug: RepoSlug, number: Int) async throws -> [IssueComment] {
        try await list(mr(slug, number) + "/notes", query: [.init(name: "sort", value: "asc")], maxPages: 5)
            .filter { $0["system"] as? Bool != true && $0["type"] as? String != "DiffNote" }
            .compactMap { note in
                try? Translate.decode(["id": note["id"] ?? 0, "user": Self.userJSON(note["author"]), "body": note["body"] ?? "", "created_at": note["created_at"] ?? NSNull()])
            }
    }

    func comment(_ slug: RepoSlug, number: Int, body: String) async throws {
        try await api.send("POST", mr(slug, number) + "/notes", json: ["body": body])
    }

    func reviewers(_ slug: RepoSlug) async throws -> [ForgeUser] { try await assignees(slug) }

    /// Members who can write (Developer and up), the ones GitLab lets review.
    func assignees(_ slug: RepoSlug) async throws -> [ForgeUser] {
        try await list(project(slug) + "/members/all", maxPages: 3)
            .filter { ($0["access_level"] as? Int ?? 0) >= 30 && $0["state"] as? String != "blocked" && $0["bot"] as? Bool != true }
            .compactMap(Self.user)
    }

    private func userIDs(_ logins: [String]) async throws -> [Int] {
        var ids: [Int] = []
        for login in logins {
            let found = try await json("users", query: [.init(name: "username", value: login)]) as? [[String: Any]] ?? []
            if let id = found.first?["id"] as? Int { ids.append(id) }
        }
        return ids
    }

    func askReview(_ slug: RepoSlug, number: Int, from logins: [String], withdraw: Bool) async throws {
        let current = try await pullRequest(slug, number: number).requestedReviewers?.map(\.login) ?? []
        let wanted = withdraw ? current.filter { !logins.contains($0) } : Array(Set(current + logins))
        try await api.send("PUT", mr(slug, number), json: ["reviewer_ids": try await userIDs(wanted)])
    }

    func labels(_ slug: RepoSlug) async throws -> [ForgeLabel] {
        try await list(project(slug) + "/labels", maxPages: 3).compactMap { item in
            try? Translate.decode(["id": item["id"] ?? 0, "name": item["name"] ?? "", "color": (item["color"] as? String)?.replacingOccurrences(of: "#", with: "") ?? NSNull()])
        }
    }

    func setLabels(_ slug: RepoSlug, number: Int, ids: [Int]) async throws {
        let known = try await labels(slug)
        let names = ids.compactMap { id in known.first { $0.id == id }?.name }
        try await api.send("PUT", mr(slug, number), json: ["labels": names.joined(separator: ",")])
    }

    // MARK: Branches and checks

    func branch(_ slug: RepoSlug, name: String) async throws -> BranchInfo {
        guard let info = try await json(project(slug) + "/repository/branches/\(Self.escape(name))") as? [String: Any] else { throw ForgeError.notAnswer }
        // Approval rules need a paid tier; Free answers without required approvals.
        var required: Int?
        if let rules = try? await json(project(slug) + "/approval_rules") as? [[String: Any]] {
            required = rules.compactMap { $0["approvals_required"] as? Int }.max()
        }
        return try Translate.decode([
            "name": name, "protected": info["protected"] ?? false, "required_approvals": required ?? NSNull(),
            "user_can_merge": info["can_push"] ?? NSNull(),
        ])
    }

    func branches(_ slug: RepoSlug) async throws -> [String] {
        try await list(project(slug) + "/repository/branches", maxPages: 6).compactMap { $0["name"] as? String }
    }

    func branchProtections(_ slug: RepoSlug) async throws -> [BranchProtection] {
        try await list(project(slug) + "/protected_branches", maxPages: 2).compactMap { item in
            try? Translate.decode(["rule_name": item["name"] ?? "", "branch_name": item["name"] ?? ""])
        }
    }

    func compare(_ slug: RepoSlug, base: String, head: String) async throws -> [PullCommit] {
        let root = try await json(project(slug) + "/repository/compare", query: [.init(name: "from", value: base), .init(name: "to", value: head)]) as? [String: Any]
        // GitLab lists oldest first, as Forgejo does.
        return (root?["commits"] as? [[String: Any]] ?? []).compactMap(Self.commit)
    }

    /// The jobs of the commit's pipelines (and any external status), each a check.
    func combinedStatus(_ slug: RepoSlug, ref: String) async throws -> CombinedStatus {
        let items = try await list(project(slug) + "/repository/commits/\(Self.escape(ref))/statuses", query: [.init(name: "all", value: "false")], maxPages: 3)
        let checks: [[String: Any]] = items.map { item in
            var check: [String: Any] = [
                "id": item["id"] ?? 0, "status": Self.state(item["status"]), "context": item["name"] ?? "",
                "description": item["description"] ?? NSNull(), "target_url": item["target_url"] ?? NSNull(),
            ]
            // A job of this GitLab's own CI comes without a target; an
            // external status brings its own link.
            let url = item["target_url"] as? String
            if url == nil || url?.contains("/-/jobs/") == true, let id = item["id"] as? Int {
                check["gnv_job_id"] = id
                check["target_url"] = "https://\(host)/\(slug.owner)/\(slug.name)/-/jobs/\(id)"
                if let pipeline = item["pipeline_id"] as? Int { check["gnv_run_id"] = pipeline }
            }
            return check
        }
        return try Translate.decode(["state": "pending", "sha": ref, "statuses": checks])
    }

    /// GitLab's job and pipeline states as the words Forgejo uses.
    static func state(_ value: Any?) -> String {
        switch value as? String {
        case "success": "success"
        case "failed": "failure"
        case "running": "running"
        case "pending", "created", "waiting_for_resource", "preparing", "scheduled", "manual", "waiting_for_callback": "waiting"
        case "canceled", "canceling": "cancelled"
        case "skipped": "skipped"
        default: "unknown"
        }
    }

    // MARK: Pipelines

    func listRuns(_ slug: RepoSlug, limit: Int, headSHA: String?, branch: String?) async throws -> [WorkflowRun] {
        var query: [URLQueryItem] = [.init(name: "per_page", value: String(min(100, limit))), .init(name: "order_by", value: "id")]
        if let headSHA { query.append(.init(name: "sha", value: headSHA)) }
        if let branch { query.append(.init(name: "ref", value: branch)) }
        let items = try await json(project(slug) + "/pipelines", query: query) as? [[String: Any]] ?? []
        return items.compactMap { try? Self.run($0) }
    }

    /// A pipeline as a run. GitLab has one pipeline file, so the workflow
    /// is always .gitlab-ci.yml; what started it says the event.
    static func run(_ item: [String: Any]) throws -> WorkflowRun {
        let source = item["source"] as? String ?? ""
        let event = switch source {
        case "merge_request_event", "external_pull_request_event": "pull_request"
        case "web", "api", "trigger", "pipeline", "parent_pipeline": "workflow_dispatch"
        case "schedule": "schedule"
        default: source.isEmpty ? "push" : source
        }
        let status = state(item["status"])
        let finished = ["success", "failure", "cancelled", "skipped"].contains(status)
        let ref = item["ref"] as? String ?? ""
        let title = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Pipeline on \(ref.replacingOccurrences(of: "refs/merge-requests/", with: "!").replacingOccurrences(of: "/head", with: ""))"
        return try Translate.decode([
            "id": item["id"] ?? 0, "title": title, "workflow_id": ".gitlab-ci.yml", "index_in_repo": item["iid"] ?? NSNull(),
            "prettyref": ref, "commit_sha": item["sha"] ?? NSNull(), "event": event, "trigger_event": event, "status": status,
            "started": item["started_at"] ?? item["created_at"] ?? NSNull(), "stopped": finished ? (item["finished_at"] ?? item["updated_at"] ?? NSNull()) : NSNull(),
            "created": item["created_at"] ?? NSNull(), "html_url": item["web_url"] ?? NSNull(), "trigger_user": userJSON(item["user"]),
        ])
    }

    static func job(_ item: [String: Any]) throws -> WorkflowJob {
        let started = !(item["started_at"] is NSNull) && item["started_at"] != nil
        return try Translate.decode([
            "id": item["id"] ?? 0, "run_id": (item["pipeline"] as? [String: Any])?["id"] ?? NSNull(),
            "name": (item["stage"] as? String).map { stage in "\(stage): \(item["name"] as? String ?? "")" } ?? item["name"] ?? "",
            "status": state(item["status"]), "attempt": NSNull(), "task_id": started ? (item["id"] ?? 0) : 0,
            "runs_on": item["tag_list"] ?? [], "html_url": item["web_url"] ?? NSNull(), "steps": [] as [Any],
        ])
    }

    func jobs(_ slug: RepoSlug, run id: Int) async throws -> [WorkflowJob] {
        // Oldest first, stage by stage, as the pipeline runs them.
        try await list(project(slug) + "/pipelines/\(id)/jobs", query: [.init(name: "include_retried", value: "false")], maxPages: 3)
            .sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
            .compactMap { try? Self.job($0) }
    }

    func job(_ slug: RepoSlug, id: Int) async throws -> WorkflowJob {
        guard let item = try await json(project(slug) + "/jobs/\(id)") as? [String: Any] else { throw ForgeError.notAnswer }
        return try Self.job(item)
    }

    /// The job's trace, as it grows while the job runs.
    func jobLog(_ slug: RepoSlug, job id: Int, from offset: Int) async throws -> Data? {
        var request = try api.request("GET", project(slug) + "/jobs/\(id)/trace", accept: "text/plain")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        do {
            let (data, response) = try await api.data(request)
            if response.statusCode == 206 { return data }
            return offset < data.count ? data.dropFirst(offset) : Data()
        } catch ForgeError.notFound {
            return nil
        } catch ForgeError.http(416) {
            return Data()
        }
    }

    /// GitLab has no steps: the job's trace holds its sections.
    func readStepLog(_ slug: RepoSlug, job id: Int, step: Int, from offset: Int) async throws -> Data? { nil }

    func workflowFiles(_ slug: RepoSlug) async throws -> [ContentEntry] {
        do {
            let file = try await json(project(slug) + "/repository/files/.gitlab-ci.yml", query: [.init(name: "ref", value: "HEAD")]) as? [String: Any]
            return [ContentEntry(name: ".gitlab-ci.yml", path: ".gitlab-ci.yml", type: "file", sha: file?["blob_id"] as? String)]
        } catch ForgeError.notFound {
            return []
        }
    }

    func fileText(_ slug: RepoSlug, path: String) async throws -> String {
        try await api.text(project(slug) + "/repository/files/\(Self.escape(path))/raw", query: [.init(name: "ref", value: "HEAD")])
    }

    /// A new pipeline on `ref`; the inputs go as CI/CD variables.
    func dispatch(_ slug: RepoSlug, workflow file: String, ref: String, inputs: [String: String]) async throws {
        let variables = inputs.sorted { $0.key < $1.key }.map { ["key": $0.key, "value": $0.value, "variable_type": "env_var"] }
        try await api.send("POST", project(slug) + "/pipeline", json: ["ref": ref, "variables": variables])
    }

    func rerun(_ slug: RepoSlug, run id: Int) async throws { try await api.send("POST", project(slug) + "/pipelines/\(id)/retry") }
    func rerun(_ slug: RepoSlug, job id: Int) async throws { try await api.send("POST", project(slug) + "/jobs/\(id)/retry") }
    func cancel(_ slug: RepoSlug, run id: Int) async throws { try await api.send("POST", project(slug) + "/pipelines/\(id)/cancel") }

    // MARK: Around

    /// To-dos: mentions, review requests, assignments, failed pipelines.
    func notifications() async throws -> [ForgeNotification] {
        let items = try await json("todos", query: [.init(name: "state", value: "pending"), .init(name: "per_page", value: "30")]) as? [[String: Any]] ?? []
        return items.compactMap { item in
            let target = item["target"] as? [String: Any] ?? [:]
            let type = switch item["target_type"] as? String {
            case "MergeRequest": "Pull"
            case "Issue": "Issue"
            case "Commit": "Commit"
            case let other?: other
            case nil: "Issue"
            }
            let state = (target["state"] as? String).map { $0 == "opened" ? "open" : $0 }
            return try? Translate.decode([
                "id": item["id"] ?? 0, "unread": true, "updated_at": item["updated_at"] ?? item["created_at"] ?? NSNull(),
                "subject": ["title": target["title"] ?? item["body"] ?? "", "type": type, "state": state ?? NSNull(), "html_url": item["target_url"] ?? NSNull(), "url": item["target_url"] ?? NSNull()],
                "repository": ["full_name": (item["project"] as? [String: Any])?["path_with_namespace"] ?? ""],
            ])
        }
    }

    func markRead(notification id: Int) async throws { try await api.send("POST", "todos/\(id)/mark_as_done") }

    func releases(_ slug: RepoSlug) async throws -> [ForgeRelease] {
        let items = try await json(project(slug) + "/releases", query: [.init(name: "per_page", value: "50")]) as? [[String: Any]] ?? []
        return items.enumerated().compactMap { index, item in
            try? Translate.decode([
                "id": index + 1, "tag_name": item["tag_name"] ?? "", "name": item["name"] ?? NSNull(),
                "draft": false, "prerelease": item["upcoming_release"] ?? false,
                "html_url": (item["_links"] as? [String: Any])?["self"] ?? NSNull(), "published_at": item["released_at"] ?? item["created_at"] ?? NSNull(),
                "author": Self.userJSON(item["author"]), "body": item["description"] ?? NSNull(),
            ])
        }
    }

    /// Plain variables with their values; masked and hidden ones are secrets.
    func actionVariables(_ slug: RepoSlug) async throws -> [ActionVariable] {
        try await list(project(slug) + "/variables", maxPages: 2)
            .filter { $0["masked"] as? Bool != true && $0["hidden"] as? Bool != true }
            .compactMap { item in (item["key"] as? String).map { ActionVariable(name: $0, data: item["value"] as? String) } }
    }

    func actionSecrets(_ slug: RepoSlug) async throws -> [ActionSecret] {
        try await list(project(slug) + "/variables", maxPages: 2)
            .filter { $0["masked"] as? Bool == true || $0["hidden"] as? Bool == true }
            .compactMap { ($0["key"] as? String).map(ActionSecret.init) }
    }

    // MARK: The token

    /// GitLab names a token's scopes itself (personal_access_tokens/self).
    func permissions() async -> [PermissionCheck] {
        let features: [(String, String, [String], Bool)] = [
            ("user", "Sign in and know who you are", ["read_user", "read_api", "api"], false),
            ("repos", "List projects, read pipelines and logs", ["read_api", "api"], false),
            ("orgs", "Workspaces (groups)", ["read_api", "api"], false),
            ("issues", "Merge requests, reviews and the Inbox", ["read_api", "api"], false),
            ("notes", "To-dos from the server", ["read_api", "api"], false),
            ("write-repo", "Merge, open merge requests, run and retry pipelines", ["api"], true),
            ("write-issue", "Comment, approve, labels, reviewers", ["api"], true),
            ("write-notes", "Mark to-dos as done", ["api"], true),
        ]
        guard let root = try? await json("personal_access_tokens/self") as? [String: Any], let scopes = root["scopes"] as? [String] else {
            // A project, group or OAuth token: ask the harmless questions.
            let probes: [PermissionProbe.Probe] = [
                ("user", features[0].1, "read_user", false, "GET", "user"),
                ("repos", features[1].1, "read_api", false, "GET", "projects?membership=true&per_page=1"),
                ("orgs", features[2].1, "read_api", false, "GET", "groups?per_page=1"),
                ("issues", features[3].1, "read_api", false, "GET", "merge_requests?scope=created_by_me&per_page=1"),
                ("notes", features[4].1, "read_api", false, "GET", "todos?per_page=1"),
                ("write-repo", features[5].1, "api", true, "POST", "projects/gitnest-view-probe%2Fnone/merge_requests"),
                ("write-issue", features[6].1, "api", true, "POST", "projects/gitnest-view-probe%2Fnone/merge_requests/0/notes"),
                ("write-notes", features[7].1, "api", true, "POST", "todos/0/mark_as_done"),
            ]
            let api = api
            return await PermissionProbe.run(probes) { await api.status($0, $1) }
        }
        return features.map { feature in
            PermissionCheck(id: feature.0, feature: feature.1, scope: feature.2.last ?? "api", writes: feature.3,
                            answer: feature.2.contains(where: scopes.contains) ? .yes : .no)
        }
    }

    // MARK: Shapes

    static func userJSON(_ object: Any?) -> Any {
        guard let user = object as? [String: Any] else { return NSNull() }
        return ["id": user["id"] ?? 0, "login": user["username"] ?? "", "full_name": user["name"] ?? NSNull(), "avatar_url": user["avatar_url"] ?? NSNull()]
    }

    /// A list of GitLab users as Forgejo users, whatever array type it came in.
    static func people(_ object: Any?) -> [Any] {
        let list: [Any] = (object as? [[String: Any]]).map { $0.map { $0 as Any } } ?? (object as? NSArray).map { Array($0) } ?? []
        return list.compactMap { entry -> Any? in
            let user = userJSON(entry)
            return user is NSNull ? nil : user
        }
    }

    static func user(_ object: Any?) -> ForgeUser? {
        (userJSON(object) as? [String: Any]).flatMap { try? Translate.decode($0) }
    }
}
