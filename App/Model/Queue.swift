import AppKit
import Foundation

// MARK: - To do

/// One step that waits for the user, with the one button that deals with it.
struct TodoItem: Identifiable, Sendable {
    enum Action: Sendable {
        /// Someone asked the user for a review.
        case review(InboxItem)
        /// One of the user's pull requests: ready to merge, failing, or with changes requested.
        case merge(MyPull)
        case failing(MyPull)
        case changes(MyPull)
        /// Something in a repository itself: a clone's state or a failed pipeline.
        case repo(ForgeRepo, AttentionReason)
        /// A Jira ticket in progress with no branch or pull request yet.
        case ticket(JiraIssue)
    }

    var id: String
    var rank: Int
    var title: String
    var detail: String
    var action: Action

    /// The server of what the line is about, when it is not the workspace's own.
    var host: String? {
        switch action {
        case .review(let item): item.host
        case .merge(let pull), .failing(let pull), .changes(let pull): pull.host
        case .repo, .ticket: nil
        }
    }
}

extension AppModel {
    /// What waits for the user, most urgent first: one line per step, not
    /// per repository.
    var todo: [TodoItem] {
        var items: [TodoItem] = []
        for repo in repos {
            for reason in attention(repo) {
                switch reason {
                case .myPullFailing, .myPullChanges, .myPullReady, .reviewRequested:
                    continue // listed below, one per pull request
                case .scheduledFailing:
                    continue // nobody's own step: the sidebar and Checks show it
                case .failedMain where !startedByMe(defaultBranchRun(of: repo)):
                    continue // someone else's merge broke it: theirs to fix
                default:
                    items.append(TodoItem(id: "repo:\(repo.id):\(reason.rank)", rank: reason.rank, title: repo.name,
                                          detail: reason.text, action: .repo(repo, reason)))
                }
            }
        }
        for pull in myPulls {
            let name = String(pull.repoFullName.split(separator: "/").last ?? "")
            if pull.state == .failure {
                items.append(TodoItem(id: "fail:\(pull.id)", rank: AttentionReason.myPullFailing(number: 0).rank,
                                      title: pull.title, detail: "\(name) #\(pull.number) · the pipeline fails", action: .failing(pull)))
            } else if pull.changesRequested {
                items.append(TodoItem(id: "changes:\(pull.id)", rank: AttentionReason.myPullChanges(number: 0).rank,
                                      title: pull.title, detail: "\(name) #\(pull.number) · changes requested", action: .changes(pull)))
            } else if pull.ready {
                items.append(TodoItem(id: "ready:\(pull.id)", rank: AttentionReason.myPullReady(number: 0).rank,
                                      title: pull.title, detail: "\(name) #\(pull.number) · approved, checks pass", action: .merge(pull)))
            }
        }
        for item in inbox {
            items.append(TodoItem(id: "review:\(item.id)", rank: AttentionReason.reviewRequested(count: 1).rank, title: item.hit.title,
                                  detail: "\(item.hit.repository?.name ?? "") #\(item.hit.number) · \(item.hit.user?.displayName ?? "someone") asks for your review",
                                  action: .review(item)))
        }
        for issue in jira.issues where issue.inProgress {
            // A ticket often needs work in several repositories: it stays
            // while it is in progress, with what has been started for it.
            let work = work(for: issue)
            var started: [String] = []
            if !work.branches.isEmpty { started.append("\(work.branches.count) \(work.branches.count == 1 ? "branch" : "branches")") }
            if !work.pulls.isEmpty { started.append("\(work.pulls.count) pull \(work.pulls.count == 1 ? "request" : "requests")") }
            items.append(TodoItem(id: "ticket:\(issue.key)", rank: 20, title: issue.fields.summary,
                                  detail: "\(issue.key) · \(issue.fields.status.name) in Jira · " + (started.isEmpty ? "nothing started yet" : started.joined(separator: ", ")),
                                  action: .ticket(issue)))
        }
        return items.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.id < $1.id }
    }

    /// The newest pipeline of the default branch that is not a pull request's.
    func defaultBranchRun(of repo: ForgeRepo) -> WorkflowRun? {
        let branch = repo.defaultBranch ?? "main"
        return forgeState(repo).runs.first { $0.prettyRef == branch && $0.trigger != "pull_request" && $0.trigger != "schedule" }
    }

    /// Whether the user's own push or merge started the run.
    func startedByMe(_ run: WorkflowRun?) -> Bool {
        guard let login = run?.triggerUser?.login.lowercased(), let host = workspace?.host,
              let mine = accounts.first(where: { $0.host == host })?.login?.lowercased() else { return false }
        return login == mine
    }

    /// Shows a pull request and opens the review or the merge form over it.
    func openPull(host: String, fullName: String, number: Int, url: String?, then form: PullForm) async {
        await openPull(host: host, fullName: fullName, number: number, url: url)
        guard let repo = selectedRepo, repo.fullName.lowercased() == fullName.lowercased(),
              let slug = slug(repo), let client = client(for: slug.host),
              let pull = try? await client.pullRequest(slug, number: number), pull.state == "open" else { return }
        switch form {
        case .review: sheet = .review(repo, pull)
        case .merge: sheet = .merge(repo, pull)
        }
    }

    enum PullForm: Sendable { case review, merge }
}

// MARK: - Quick actions (menu bar)

extension AppModel {
    /// Approves a pull request the user was asked to review, without opening it.
    @discardableResult
    func quickApprove(_ item: InboxItem) async -> Bool {
        guard let slug = Self.slug(host: item.host, fullName: item.hit.repository?.fullName), let client = client(for: item.host) else { return false }
        do {
            let pull = try await client.pullRequest(slug, number: item.hit.number)
            try await client.submitReview(slug, number: pull.number, event: ReviewEvent.approve.rawValue, body: "", commit: pull.head.sha)
            toast("Approved \(slug.name) #\(pull.number)")
            await checkForNews()
            return true
        } catch {
            toast(error.localizedDescription, .error)
            return false
        }
    }

    /// Runs the failed pipelines of one of the user's pull requests again.
    @discardableResult
    func rerunFailed(_ pull: MyPull) async -> Bool {
        guard let slug = Self.slug(host: pull.host, fullName: pull.repoFullName), let client = client(for: pull.host) else { return false }
        do {
            let failed = try await client.runs(slug, limit: 10, headSHA: pull.headSHA).filter { $0.state == .failure }
            guard !failed.isEmpty else {
                toast("No failed pipeline to run again on \(slug.name) #\(pull.number)", .info)
                return false
            }
            guard supportsRerun(slug.host) else {
                rerunInBrowser(failed[0].htmlURL, what: "the pipeline of \(slug.name) #\(pull.number)")
                return false
            }
            for run in failed { try await client.rerun(slug, run: run.id) }
            toast("Running \(failed.count == 1 ? "the pipeline" : "\(failed.count) pipelines") of \(slug.name) #\(pull.number) again")
            Task {
                try? await Task.sleep(for: .seconds(3))
                await self.checkForNews()
            }
            return true
        } catch {
            toast(error.localizedDescription, .error)
            return false
        }
    }

    /// Runs the failed pipelines of a pull request's head commit again.
    func rerunFailed(of pull: PullRequest, in repo: ForgeRepo) async {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return }
        do {
            let failed = try await client.runs(slug, limit: 10, headSHA: pull.head.sha).filter { $0.state == .failure }
            guard !failed.isEmpty else { return toast("No failed pipeline to run again on #\(pull.number)", .info) }
            guard supportsRerun(slug.host) else { return rerunInBrowser(failed[0].htmlURL, what: "the pipeline of #\(pull.number)") }
            for run in failed { try await client.rerun(slug, run: run.id) }
            toast("Running \(failed.count == 1 ? "the pipeline" : "\(failed.count) pipelines") of #\(pull.number) again")
            try? await Task.sleep(for: .seconds(2))
            await loadExtras(pull, in: repo)
            await refreshForge(repo, detailed: true)
        } catch {
            toast(error.localizedDescription, .error)
        }
    }

    static func slug(host: String, fullName: String?) -> RepoSlug? {
        guard let parts = fullName?.split(separator: "/", maxSplits: 1).map(String.init), parts.count == 2 else { return nil }
        return RepoSlug(host: host, owner: parts[0], name: parts[1])
    }
}

// MARK: - Releases across repositories

/// A repository whose develop is ahead of its default branch.
struct ReleaseCandidate: Identifiable, Sendable {
    var repo: ForgeRepo
    var draft: ReleaseDraft
    var id: ForgeRepo.ID { repo.id }
}

extension AppModel {
    /// Every repository of the workspace where `head` has commits its default
    /// branch lacks, with the open release pull request if there is one.
    /// Reads only: a few repositories at a time.
    func releaseCandidates(head: String = "develop", progress: (@MainActor (Int, Int) -> Void)? = nil) async -> [ReleaseCandidate] {
        let targets = repos.filter { $0.empty != true }
        var found: [ReleaseCandidate] = []
        var done = 0
        await withTaskGroup(of: ReleaseCandidate?.self) { group in
            var waiting = targets.makeIterator()
            func next() {
                guard let repo = waiting.next() else { return }
                group.addTask {
                    let base = await MainActor.run { repo.defaultBranch ?? "main" }
                    guard base != head, let draft = try? await self.releaseDraft(repo, head: head, base: base), !draft.commits.isEmpty else { return nil }
                    return ReleaseCandidate(repo: repo, draft: draft)
                }
            }
            for _ in 0..<5 { next() }
            for await candidate in group {
                done += 1
                progress?(done, targets.count)
                if let candidate { found.append(candidate) }
                next()
            }
        }
        return found.sorted { $0.repo.name.localizedStandardCompare($1.repo.name) == .orderedAscending }
    }

    /// Opens the release pull request of each candidate that has none yet.
    /// Returns how many were opened.
    func openReleases(_ candidates: [ReleaseCandidate]) async -> Int {
        var opened = 0
        for candidate in candidates where candidate.draft.existing == nil {
            guard let slug = slug(candidate.repo), let client = client(for: slug.host) else { continue }
            do {
                _ = try await client.createPull(slug, head: candidate.draft.head, base: candidate.draft.base,
                                                title: candidate.draft.title, body: candidate.draft.body)
                opened += 1
            } catch {
                toast("\(candidate.repo.name): \(error.localizedDescription)", .error)
            }
        }
        if opened > 0 {
            toast("Opened \(opened) release pull \(opened == 1 ? "request" : "requests")")
            Task { await self.checkForNews() }
        }
        return opened
    }
}

// MARK: - A plan beside the files that caused it

/// What a plan changes, by the file that declares each resource.
struct PlanAttribution: Equatable, Sendable {
    /// Changes whose resource (or module call) is declared in a file the
    /// pull request touches, by that file.
    var byFile: [String: [TerraformPlan.Change]] = [:]
    /// Changes declared in files the pull request does not touch (their
    /// inputs changed elsewhere: variables, data files, a module), with the file.
    var elsewhere: [(change: TerraformPlan.Change, file: String)] = []
    /// Changes whose declaration was not found in the clone.
    var unknown: [TerraformPlan.Change] = []

    static func == (a: Self, b: Self) -> Bool {
        a.byFile == b.byFile && a.unknown == b.unknown
            && a.elsewhere.map(\.change) == b.elsewhere.map(\.change) && a.elsewhere.map(\.file) == b.elsewhere.map(\.file)
    }

    var isEmpty: Bool { byFile.isEmpty && elsewhere.isEmpty && unknown.isEmpty }

    /// "module.a["x"].google_x.y[0]" is declared as "module.a";
    /// "google_x.y["k"]" as "google_x.y"; "data.google_x.y" as itself.
    static func declaration(of address: String) -> String {
        var plain = ""
        var depth = 0
        for character in address {
            if character == "[" { depth += 1 } else if character == "]" { depth = max(0, depth - 1) } else if depth == 0 { plain.append(character) }
        }
        let parts = plain.split(separator: ".").map(String.init)
        guard let first = parts.first else { return plain }
        if first == "module", parts.count >= 2 { return "module.\(parts[1])" }
        if first == "data", parts.count >= 3 { return "data.\(parts[1]).\(parts[2])" }
        return parts.prefix(2).joined(separator: ".")
    }

    init(plan: TerraformPlan, items: [TFItem], changed: [String]) {
        let touched = Set(changed)
        var declared: [String: [String]] = [:] // address → files
        for item in items { declared[item.address, default: []].append(item.file) }
        for change in plan.changes {
            let files = declared[Self.declaration(of: change.address)] ?? []
            if let file = files.first(where: touched.contains) {
                byFile[file, default: []].append(change)
            } else if let file = files.first {
                elsewhere.append((change, file))
            } else {
                unknown.append(change)
            }
        }
    }

    init() {}
}

extension AppModel {
    /// The plan of a pull request against its changed files, when the
    /// repository is cloned (the declarations are read from the clone).
    func planAttribution(_ plan: TerraformPlan?, files: [PullFile], in repo: ForgeRepo) async -> PlanAttribution? {
        guard let plan, !plan.changes.isEmpty, let items = await resources(of: repo), !items.isEmpty else { return nil }
        return PlanAttribution(plan: plan, items: items, changed: files.map(\.filename))
    }
}

// MARK: - A resource's history

struct BlockCommit: Decodable, Identifiable, Hashable, Sendable {
    var sha: String
    var short: String
    var author: String
    var when: String
    var subject: String
    var id: String { sha }

    /// "… (#12)" or "Merge pull request '…' (#12) from …": the pull request.
    var pullNumber: Int? {
        guard let open = subject.range(of: "(#", options: .backwards),
              let close = subject[open.upperBound...].firstIndex(of: ")") else { return nil }
        return Int(subject[open.upperBound..<close])
    }
}

struct BlockHistory: Decodable, Sendable {
    var commits: [BlockCommit]
    var start: Int
    var end: Int
}

extension AppModel {
    /// The commits that changed one declaration (a resource, a module call).
    func history(of item: TFItem, in repo: ForgeRepo) async -> BlockHistory? {
        guard let clone = clone(of: repo) else { return nil }
        struct Params: Encodable, Sendable {
            var path: String
            var file: String
            var line: Int
        }
        return try? await core.call("repo.blockHistory", Params(path: clone.path, file: item.file, line: item.line))
    }
}
