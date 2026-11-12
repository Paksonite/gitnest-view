import Foundation

/// One reason a repository wants the user's attention, most urgent first.
enum AttentionReason: Hashable, Sendable, Comparable {
    /// A merge, rebase… stopped, or files in conflict.
    case conflict(String)
    /// The newest pipeline of the default branch failed.
    case failedMain(workflow: String)
    /// The newest run of a scheduled workflow (drift detection) failed.
    case scheduledFailing(workflow: String)
    /// A pipeline of one of the user's own pull requests failed.
    case myPullFailing(number: Int)
    /// A reviewer asked for changes on one of the user's pull requests.
    case myPullChanges(number: Int)
    /// Someone asked the user for a review.
    case reviewRequested(count: Int)
    /// One of the user's pull requests is approved and its checks pass.
    case myPullReady(number: Int)
    /// Local and server history both moved.
    case diverged(ahead: Int, behind: Int)
    /// The server has commits the clone does not.
    case behind(Int)
    /// Commits not pushed yet.
    case ahead(Int)
    /// Uncommitted changes.
    case changes(Int)

    var rank: Int {
        switch self {
        case .conflict: 0
        case .failedMain: 1
        case .scheduledFailing: 2
        case .myPullFailing: 3
        case .myPullChanges: 4
        case .reviewRequested: 5
        case .myPullReady: 6
        case .diverged: 7
        case .behind: 8
        case .ahead: 9
        case .changes: 10
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    var text: String {
        switch self {
        case .conflict(let what): what.isEmpty ? "conflicts to resolve" : "\(what) stopped"
        case .failedMain(let workflow): "\(workflow) failed on the default branch"
        case .scheduledFailing(let workflow): "\(workflow) reports a problem"
        case .myPullFailing(let number): "your pull request #\(number) fails"
        case .myPullChanges(let number): "changes requested on your #\(number)"
        case .reviewRequested(let count): count == 1 ? "a review is waiting for you" : "\(count) reviews are waiting for you"
        case .myPullReady(let number): "your #\(number) is approved and ready to merge"
        case .diverged(let ahead, let behind): "diverged: \(ahead) to push, \(behind) to pull"
        case .behind(let n): "\(n) \(n == 1 ? "commit" : "commits") to pull"
        case .ahead(let n): "\(n) \(n == 1 ? "commit" : "commits") to push"
        case .changes(let n): "\(n) uncommitted \(n == 1 ? "change" : "changes")"
        }
    }
}

/// One of the user's own open pull requests, with the state of its checks.
struct MyPull: Identifiable, Hashable, Sendable {
    var host: String
    var repoFullName: String
    var number: Int
    var title: String
    var headSHA: String
    var state: CheckState
    var htmlURL: String?
    var approvals = 0
    var changesRequested = false
    var id: String { "\(host)/\(repoFullName)#\(number)" }

    /// Approved, nobody asks for changes, and the checks pass (or there are none).
    var ready: Bool { approvals > 0 && !changesRequested && (state == .success || state == .unknown) }
}

extension AppModel {
    /// Why a repository needs attention, most urgent first; empty when all
    /// is well.
    func attention(_ repo: ForgeRepo) -> [AttentionReason] {
        var reasons: [AttentionReason] = []
        if let clone = clone(of: repo) {
            if clone.conflicts || !clone.state.isEmpty { reasons.append(.conflict(clone.state)) }
            if clone.ahead > 0 && clone.behind > 0 {
                reasons.append(.diverged(ahead: clone.ahead, behind: clone.behind))
            } else if clone.behind > 0 {
                reasons.append(.behind(clone.behind))
            } else if clone.ahead > 0 {
                reasons.append(.ahead(clone.ahead))
            }
            if clone.changes > 0 { reasons.append(.changes(clone.changes)) }
        }
        let branch = repo.defaultBranch ?? "main"
        if let run = forgeState(repo).runs.first(where: { $0.prettyRef == branch && $0.trigger != "pull_request" }), run.state == .failure {
            reasons.append(.failedMain(workflow: workflowName(run, in: repo)))
        }
        for run in Self.scheduledRuns(forgeState(repo).runs) where run.state == .failure {
            reasons.append(.scheduledFailing(workflow: workflowName(run, in: repo)))
        }
        let fullName = repo.fullName.lowercased()
        let host = workspace?.host ?? ""
        for pull in myPulls where pull.host == host && pull.repoFullName.lowercased() == fullName {
            if pull.state == .failure {
                reasons.append(.myPullFailing(number: pull.number))
            } else if pull.changesRequested {
                reasons.append(.myPullChanges(number: pull.number))
            } else if pull.ready {
                reasons.append(.myPullReady(number: pull.number))
            }
        }
        let reviews = inbox.count { $0.host == host && $0.hit.repository?.fullName.lowercased() == fullName }
        if reviews > 0 { reasons.append(.reviewRequested(count: reviews)) }
        return reasons.sorted()
    }

    /// Reads the user's own open pull requests and the state of their
    /// checks. Returns the ones whose checks just failed.
    @discardableResult
    func refreshMyPulls() async -> [MyPull] {
        var fresh: [MyPull] = []
        for account in accounts {
            guard let client = client(for: account.host) else { continue }
            guard let hits = try? await client.myPullRequests() else {
                fresh += myPulls.filter { $0.host == account.host }
                continue
            }
            await withTaskGroup(of: MyPull?.self) { group in
                for hit in hits {
                    guard let fullName = hit.repository?.fullName else { continue }
                    let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let slug = RepoSlug(host: account.host, owner: parts[0], name: parts[1])
                    group.addTask {
                        guard let pull = try? await client.pullRequest(slug, number: hit.number) else { return nil }
                        async let status = try? client.combinedStatus(slug, ref: pull.head.sha)
                        async let reviews = try? client.reviews(slug, pull: hit.number)
                        let checks = await status
                        let state = (checks?.checks.isEmpty ?? true) ? CheckState.unknown : checks!.overall
                        let summary = ReviewSummary(reviews: await reviews ?? [], requested: pull.requestedReviewers ?? [])
                        return MyPull(host: account.host, repoFullName: fullName, number: hit.number, title: hit.title,
                                      headSHA: pull.head.sha, state: state, htmlURL: hit.htmlURL,
                                      approvals: summary.approvals, changesRequested: summary.changesRequested > 0)
                    }
                }
                for await item in group { if let item { fresh.append(item) } }
            }
        }
        let before = Dictionary(myPulls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newlyFailed = fresh.filter { pull in
            guard pull.state == .failure else { return false }
            guard let old = before[pull.id] else { return true }
            return old.state != .failure || old.headSHA != pull.headSHA
        }
        let sorted = fresh.sorted { $0.number > $1.number }
        if myPulls != sorted { myPulls = sorted }
        return newlyFailed
    }
}

extension AppModel {
    /// Repositories for the sidebar: with attention first, the ones that need
    /// something (most urgent first) and the rest; by name, everything in one
    /// list (`attention` is nil).
    func sidebarGroups(_ reasons: [ForgeRepo.ID: [AttentionReason]]) -> (attention: [ForgeRepo]?, rest: [ForgeRepo]) {
        let shown = shownRepos.filter { !isPinned($0) }
        guard sidebarByAttention else { return (nil, shown) }
        var urgent: [(ForgeRepo, Int)] = []
        var cloned: [ForgeRepo] = []
        var others: [ForgeRepo] = []
        for repo in shown {
            if let first = reasons[repo.id]?.first {
                urgent.append((repo, first.rank))
            } else if clone(of: repo) != nil {
                // Clones first among the rest: they are what the user works with.
                cloned.append(repo)
            } else {
                others.append(repo)
            }
        }
        urgent.sort { a, b in
            a.1 != b.1 ? a.1 < b.1 : a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }
        return (urgent.map(\.0), cloned + others)
    }

    /// Why each repository needs attention (only those that do), read in
    /// one pass: the sidebar asks for all of them on every redraw.
    var attentionByRepo: [ForgeRepo.ID: [AttentionReason]] {
        var all: [ForgeRepo.ID: [AttentionReason]] = [:]
        for repo in repos {
            let reasons = attention(repo)
            if !reasons.isEmpty { all[repo.id] = reasons }
        }
        return all
    }

    var sidebarByAttention: Bool {
        get { _ = settingsRevision; return defaults.object(forKey: "sidebarByAttention") as? Bool ?? true }
        set { guard newValue != sidebarByAttention else { return }; defaults.set(newValue, forKey: "sidebarByAttention"); settingsRevision += 1 }
    }
}

// MARK: - Pinned repositories (gitnest's favorites)

extension AppModel {
    /// Read once per change, not once per row: the sidebar asks for every repository.
    private var pinnedNames: Set<String> {
        if let cached = pinnedCache, cached.revision == settingsRevision { return cached.names }
        let names = Set(defaults.stringArray(forKey: "pinned") ?? [])
        pinnedCache = (settingsRevision, names)
        return names
    }

    private func pinKey(_ repo: ForgeRepo) -> String {
        "\(workspace?.host ?? "")/\(repo.fullName)".lowercased()
    }

    func isPinned(_ repo: ForgeRepo) -> Bool { pinnedNames.contains(pinKey(repo)) }

    func togglePin(_ repo: ForgeRepo) {
        var names = pinnedNames
        if names.contains(pinKey(repo)) { names.remove(pinKey(repo)) } else { names.insert(pinKey(repo)) }
        defaults.set(Array(names).sorted(), forKey: "pinned")
        settingsRevision += 1
    }

    /// Pinned repositories stay on top of the sidebar, whatever their state.
    var pinnedRepos: [ForgeRepo] { shownRepos.filter(isPinned) }
}
