import AppKit
import Foundation

struct Toast: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case success, error, info }
    var id = UUID()
    var text: String
    var kind: Kind
}

/// Working on a clone: staging, commits, branches, stashes, history, push,
/// and across clones: fetch all, pull all, activity.
extension AppModel {
    // MARK: Toasts

    func toast(_ text: String, _ kind: Toast.Kind = .success) {
        let item = Toast(text: text, kind: kind)
        toasts.append(item)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 9 : 4))
            self?.toasts.removeAll { $0.id == item.id }
        }
    }

    // MARK: Plumbing

    /// Runs a change on the clone of `repo`, then reads its state again.
    /// Errors become a toast; the result is whether it worked.
    @discardableResult
    func change(_ repo: ForgeRepo, success: String? = nil, _ body: (Repo) async throws -> Void) async -> Bool {
        guard let slug = slug(repo), let clone = local[slug.key] else { return false }
        busy.insert(slug.key)
        defer { busy.remove(slug.key) }
        var ok = true
        do {
            try await body(clone)
            if let success { toast(success) }
        } catch {
            ok = false
            toast(error.localizedDescription, .error)
        }
        await refreshClone(repo)
        return ok
    }

    /// Reads one clone's state again and tells the views it changed.
    func refreshClone(_ repo: ForgeRepo) async {
        guard let slug = slug(repo), let clone = local[slug.key] else { return }
        if let result: ScanResult = try? await core.call("repos.status", PathsParams(paths: [clone.path])) {
            if let fresh = result.repos.first { local[slug.key] = fresh } else { local[slug.key] = nil }
        }
        localRevision[slug.key, default: 0] += 1
    }

    /// Reads a clone again after its files changed (CloneWatcher).
    func refreshClone(atPath path: String) async {
        guard let key = local.first(where: { $0.value.path == path })?.key else { return }
        guard let result: ScanResult = try? await core.call("repos.status", PathsParams(paths: [path])) else { return }
        if let fresh = result.repos.first, local[key] != fresh { local[key] = fresh }
        // The views read the changes and diffs again even if the counts stay.
        localRevision[key, default: 0] += 1
    }

    func revision(_ repo: ForgeRepo) -> Int {
        slug(repo).flatMap { localRevision[$0.key] } ?? 0
    }

    func gitAuth(_ repo: ForgeRepo, _ clone: Repo) -> GitAuth? {
        guard let slug = slug(repo) else { return nil }
        return auth(host: slug.host, forURL: clone.remote.url)
    }

    // MARK: Files

    func diff(_ file: ChangedFile, staged: Bool, in repo: ForgeRepo) async throws -> FileDiff {
        guard let clone = clone(of: repo) else { throw CoreClient.CoreError.exited }
        struct Params: Encodable, Sendable {
            var path: String
            var file: FileRef
            var staged: Bool
        }
        return try await core.call("repo.diff", Params(path: clone.path, file: FileRef(file), staged: staged))
    }

    func stage(_ files: [ChangedFile], all: Bool = false, in repo: ForgeRepo) async {
        struct Params: Encodable, Sendable {
            var path: String
            var files: [String]
            var all: Bool
        }
        await change(repo) { clone in
            try await core.run("repo.stage", Params(path: clone.path, files: files.map(\.path), all: all))
        }
    }

    func unstage(_ files: [ChangedFile], all: Bool = false, in repo: ForgeRepo) async {
        struct Params: Encodable, Sendable {
            var path: String
            var files: [String]
            var all: Bool
        }
        await change(repo) { clone in
            try await core.run("repo.unstage", Params(path: clone.path, files: files.map(\.path), all: all))
        }
    }

    func discard(_ files: [ChangedFile], in repo: ForgeRepo) async {
        struct Params: Encodable, Sendable {
            var path: String
            var files: [FileRef]
        }
        let what = files.count == 1 ? files[0].path : "\(files.count) files"
        await change(repo, success: "Discarded the changes in \(what)") { clone in
            try await core.run("repo.discard", Params(path: clone.path, files: files.map(FileRef.init)))
        }
    }

    enum LineAction: String { case stage, unstage, discard }

    @discardableResult
    func lines(_ action: LineAction, _ refs: [LineRef], of file: ChangedFile, diff: FileDiff, in repo: ForgeRepo) async -> Bool {
        struct Params: Encodable, Sendable {
            var path: String
            var file: FileRef
            var action: String
            var digest: String
            var lines: [LineRef]
        }
        return await change(repo) { clone in
            try await core.run("repo.lines", Params(path: clone.path, file: FileRef(file), action: action.rawValue, digest: diff.digest, lines: refs))
        }
    }

    // MARK: Commit and push

    @discardableResult
    func commit(_ message: String, amend: Bool, in repo: ForgeRepo) async -> Bool {
        struct Params: Encodable, Sendable {
            var path: String
            var message: String
            var amend: Bool
        }
        let subject = message.split(separator: "\n").first.map(String.init) ?? ""
        return await change(repo, success: amend ? "Amended the last commit" : "Committed “\(subject)”") { clone in
            try await core.run("repo.commit", Params(path: clone.path, message: message, amend: amend))
        }
    }

    func lastMessage(in repo: ForgeRepo) async -> String {
        guard let clone = clone(of: repo) else { return "" }
        struct Params: Encodable, Sendable {
            var path: String
            var rev: String
        }
        let result: MessageResult? = try? await core.call("repo.message", Params(path: clone.path, rev: "HEAD"))
        return result?.message ?? ""
    }

    /// Commits on the checked-out branch that no branch on the server has.
    /// Nil when the engine cannot tell (no remote, an error).
    func newCommits(in clone: Repo) async -> Int? {
        struct Params: Encodable, Sendable { var path: String }
        let result: CountResult? = try? await core.call("repo.newcommits", Params(path: clone.path))
        return result?.count
    }

    /// Pushes the checked-out branch. Publishing a branch that has nothing
    /// the server lacks asks first: it is almost always a branch created and
    /// pushed before the work was committed.
    @discardableResult
    func push(_ repo: ForgeRepo, force: Bool = false, allowEmpty: Bool = false) async -> Bool {
        struct Params: Encodable, Sendable {
            var path: String
            var force: Bool
            var auth: GitAuth?
        }
        let branch = clone(of: repo)?.branch ?? ""
        if !allowEmpty, let clone = clone(of: repo), clone.upstreamGone, let merged = await mergedPull(of: repo) {
            confirm(title: "Publish \(branch) again?",
                    message: "\(branch) was merged into \(merged.base.name) in #\(merged.number) and deleted on the server: the work on it is done. Finish it to switch back to \(merged.base.name), or publish it again to keep working on it.",
                    button: "Publish Again") { [weak self] in
                Task { await self?.push(repo, allowEmpty: true) }
            }
            return false
        }
        if !force, !allowEmpty, let clone = clone(of: repo), !clone.hasUpstream, !clone.detached,
           await newCommits(in: clone) == 0 {
            confirm(title: "Publish empty branch \(branch)?",
                    message: "\(branch) has no commits that are not already on the server, so the new branch would only repeat the one it came from. Commit your work first, or publish it anyway to reserve the name.",
                    button: "Publish Anyway") { [weak self] in
                Task { await self?.push(repo, allowEmpty: true) }
            }
            return false
        }
        let ok = await change(repo, success: force ? "Force pushed \(branch)" : "Pushed \(branch)") { clone in
            try await core.run("repo.push", Params(path: clone.path, force: force, auth: gitAuth(repo, clone)))
        }
        if ok { Task { await refreshForge(repo, detailed: true) } }
        return ok
    }

    // MARK: Branches

    @discardableResult
    func createBranch(_ name: String, base: String = "", in repo: ForgeRepo) async -> Bool {
        struct Params: Encodable, Sendable {
            var path: String
            var name: String
            var base: String
        }
        return await change(repo, success: "Created and switched to \(name)") { clone in
            try await core.run("repo.branch.create", Params(path: clone.path, name: name, base: base))
        }
    }

    func deleteBranch(_ name: String, force: Bool = false, remote: Bool = false, in repo: ForgeRepo) async {
        struct Params: Encodable, Sendable {
            var path: String
            var name: String
            var force: Bool
            var remote: Bool
            var auth: GitAuth?
        }
        await change(repo, success: remote ? "Deleted \(name) on the server" : "Deleted \(name)") { clone in
            try await core.run("repo.branch.delete", Params(path: clone.path, name: name, force: force, remote: remote,
                                                           auth: remote ? gitAuth(repo, clone) : nil))
        }
    }

    /// The local copy of a branch just merged and deleted on the server.
    /// Checked out, it is finished: the app switches to `base` and pulls it.
    /// After a merge: a clone on the merged branch goes back to the branch it
    /// was merged into, up to date; the merged branch stays.
    func returnToBase(from head: String, into base: String, in repo: ForgeRepo) async {
        guard let slug = slug(repo), local[slug.key]?.branch == head, head != base else { return }
        await finishBranch(in: repo, into: base, keep: true)
    }

    func deleteMergedLocal(_ name: String, into base: String, in repo: ForgeRepo) async {
        if let slug = slug(repo), local[slug.key]?.branch == name {
            await finishBranch(in: repo, into: base)
        } else {
            // Forced: a squash merge leaves the branch's own commits unmerged in git's eyes.
            await deleteBranch(name, force: true, in: repo)
        }
    }

    func renameBranch(_ old: String, to name: String, in repo: ForgeRepo) async {
        struct Params: Encodable, Sendable {
            var path: String
            var old: String
            var name: String
        }
        await change(repo, success: "Renamed \(old) to \(name)") { clone in
            try await core.run("repo.branch.rename", Params(path: clone.path, old: old, name: name))
        }
    }

    // MARK: Stashes

    func stashes(of repo: ForgeRepo) async -> [Stash] {
        guard let clone = clone(of: repo) else { return [] }
        let list: StashList? = try? await core.call("repo.stashes", PathParams(path: clone.path))
        return list?.stashes ?? []
    }

    enum StashAction: String { case push, pop, apply, drop }

    func stash(_ action: StashAction, ref: String = "", message: String = "", in repo: ForgeRepo) async {
        struct Params: Encodable, Sendable {
            var path: String
            var action: String
            var ref: String
            var message: String
        }
        let done: String = switch action {
        case .push: "Stashed the changes"
        case .pop: "Applied and removed the stash"
        case .apply: "Applied the stash"
        case .drop: "Dropped the stash"
        }
        await change(repo, success: done) { clone in
            try await core.run("repo.stash", Params(path: clone.path, action: action.rawValue, ref: ref, message: message))
        }
    }

    // MARK: History

    func history(of repo: ForgeRepo, limit: Int = 150) async throws -> History {
        guard let clone = clone(of: repo) else { throw CoreClient.CoreError.exited }
        return try await core.call("repo.history", LogParams(path: clone.path, limit: limit))
    }

    func show(_ sha: String, in repo: ForgeRepo) async -> String {
        guard let clone = clone(of: repo) else { return "" }
        struct Params: Encodable, Sendable {
            var path: String
            var sha: String
        }
        let result: TextResult? = try? await core.call("repo.show", Params(path: clone.path, sha: sha))
        return result?.text ?? ""
    }

    enum Rewrite: String { case reword, squash, fixup, drop, revert, undo }

    /// Rewrites history. When the commits are already on the server and
    /// `confirm` is false, nothing changes and the remotes are returned, so
    /// the app can ask a second time.
    func rewrite(_ action: Rewrite, sha: String = "", message: String = "", confirm: Bool = false, in repo: ForgeRepo) async -> [String]? {
        struct Params: Encodable, Sendable {
            var path: String
            var action: String
            var sha: String
            var message: String
            var confirm: Bool
        }
        guard let clone = clone(of: repo) else { return nil }
        do {
            let result: RewriteResult = try await core.call("repo.rewrite", Params(path: clone.path, action: action.rawValue, sha: sha, message: message, confirm: confirm))
            if result.needsConfirm == true { return result.remotes ?? ["the server"] }
            let done: String = switch action {
            case .reword: "Reworded the commit"
            case .squash: "Squashed into the commit below"
            case .fixup: "Folded into the commit below"
            case .drop: "Dropped the commit"
            case .revert: "Reverted the commit"
            case .undo: "Undid the last change to history"
            }
            toast(done)
        } catch {
            toast(error.localizedDescription, .error)
        }
        await refreshClone(repo)
        return nil
    }

    enum Operation: String { case `continue`, abort, skip }

    func operation(_ action: Operation, in repo: ForgeRepo) async {
        struct Params: Encodable, Sendable {
            var path: String
            var action: String
        }
        await change(repo, success: action == .abort ? "Abandoned" : "Continued") { clone in
            try await core.run("repo.operation", Params(path: clone.path, action: action.rawValue))
        }
    }

    // MARK: Across clones

    /// The clones of the workspace, with their access tokens.
    private var clonesWithAuth: [(repo: ForgeRepo, clone: Repo, auth: GitAuth?)] {
        repos.compactMap { repo in
            guard let clone = clone(of: repo) else { return nil }
            return (repo, clone, gitAuth(repo, clone))
        }
    }

    /// Fetches every clone of the workspace. Returns the branches that are
    /// now behind (what pull all offers) and the clones that failed.
    func fetchAll() async -> FetchAllResult? {
        struct Item: Encodable, Sendable {
            var path: String
            var auth: GitAuth?
        }
        struct Params: Encodable, Sendable { var repos: [Item] }
        let items = clonesWithAuth.map { Item(path: $0.clone.path, auth: $0.auth) }
        guard !items.isEmpty else { return FetchAllResult(results: [], rows: []) }
        do {
            let result: FetchAllResult = try await core.call("repos.fetchAll", Params(repos: items))
            await refreshLocal()
            for repo in repos { if let key = slug(repo)?.key { localRevision[key, default: 0] += 1 } }
            return result
        } catch {
            toast(error.localizedDescription, .error)
            return nil
        }
    }

    func fastForward(_ rows: [BehindBranch]) async -> FastForwardResult? {
        struct Item: Encodable, Sendable {
            var path: String
            var branch: String
            var auth: GitAuth?
        }
        struct Params: Encodable, Sendable { var items: [Item] }
        let auths = Dictionary(clonesWithAuth.map { ($0.clone.path, $0.auth) }, uniquingKeysWith: { a, _ in a })
        do {
            let result: FastForwardResult = try await core.call("repos.fastForward", Params(items: rows.map {
                Item(path: $0.path, branch: $0.branch, auth: auths[$0.path] ?? nil)
            }))
            await refreshLocal()
            return result
        } catch {
            toast(error.localizedDescription, .error)
            return nil
        }
    }

    /// The forge repository a clone belongs to.
    func forgeRepo(forClone path: String) -> ForgeRepo? {
        repos.first { clone(of: $0)?.path == path }
    }

    func activity(days: Int) async -> [ActivityCommit] {
        struct Params: Encodable, Sendable {
            var paths: [String]
            var days: Int
        }
        let paths = clonesWithAuth.map(\.clone.path)
        guard !paths.isEmpty else { return [] }
        let result: ActivityResult? = try? await core.call("repos.activity", Params(paths: paths, days: days))
        return result?.commits ?? []
    }
}

extension AppModel {
    /// Where a feature branch is usually merged: develop when the server has
    /// one (feat → develop → main), else the default branch.
    func defaultBase(for head: String, in repo: ForgeRepo) async -> String {
        let fallback = repo.defaultBranch ?? "main"
        guard head != "develop", let branches = await branches(of: repo) else { return fallback }
        let remote = Set(branches.remote.map { $0.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? $0.name })
        return remote.contains("develop") ? "develop" : fallback
    }
}

extension AppModel {
    /// Back from the editor or the terminal: files may have changed, so the
    /// clones' state and the open Changes view are read again (at most every
    /// few seconds).
    func becameActive() {
        guard Date.now.timeIntervalSince(lastActivation) > 3 else { return }
        lastActivation = .now
        activations += 1
        Task { await refreshLocal() }
        // Back from the browser, where a ticket may just have moved.
        if jiraSettings != nil { Task { await refreshJira() } }
        // Back from the browser, where a pull request may just have been merged.
        if isSetUp, Date.now.timeIntervalSince(lastNews) > 15 { Task { await checkForNews() } }
    }
}

extension AppModel {
    /// Fetches every clone without showing anything but failures.
    func quietFetchAll() async {
        fetchingAll = true
        defer { fetchingAll = false }
        guard let result = await fetchAll() else { return }
        let failed = result.results.filter { $0.error != nil }
        if !failed.isEmpty {
            let names = failed.compactMap { forgeRepo(forClone: $0.path)?.name }.prefix(3).joined(separator: ", ")
            toast("Could not fetch \(failed.count == 1 ? names : "\(failed.count) repositories (\(names)…)")", .error)
        }
    }

    /// Fetches every clone and says what came in.
    func fetchAllReporting() async {
        fetchingAll = true
        defer { fetchingAll = false }
        guard let result = await fetchAll() else { return }
        let failed = result.results.filter { $0.error != nil }.count
        let behind = result.rows.count
        var text = "Fetched \(result.results.count - failed) \(result.results.count - failed == 1 ? "repository" : "repositories")"
        text += behind == 0 ? " · everything is up to date" : " · \(behind) \(behind == 1 ? "branch" : "branches") behind"
        if failed > 0 { text += " · \(failed) failed" }
        toast(text, failed > 0 ? .error : .success)
    }
}

extension AppModel {
    /// Pulls a branch that diverged from the server: `rebase` puts the local
    /// commits on top of the server's, `merge` makes a merge commit.
    func pull(_ repo: ForgeRepo, mode: String) async {
        struct Params: Encodable, Sendable {
            var path: String
            var auth: GitAuth?
            var mode: String
        }
        let branch = clone(of: repo)?.branch ?? ""
        await change(repo, success: mode == "rebase" ? "Rebased \(branch) onto the server's commits" : "Merged the server's commits into \(branch)") { clone in
            try await core.run("repo.pull", Params(path: clone.path, auth: gitAuth(repo, clone), mode: mode))
        }
    }
}

// MARK: - Uncommitted lines of a file

extension AppModel {
    /// The clone's files as git knows them (ignored ones left out).
    func treeFiles(of repo: ForgeRepo) async -> [String]? {
        guard let clone = clone(of: repo) else { return nil }
        struct Result: Decodable { var files: [String] }
        let result: Result? = try? await core.call("repo.tree", PathParams(path: clone.path))
        return result?.files
    }

    func lineChanges(of file: String, in repo: ForgeRepo) async -> LineChanges? {
        guard let clone = clone(of: repo) else { return nil }
        struct Params: Encodable, Sendable { var path: String; var file: String }
        return try? await core.call("repo.linechanges", Params(path: clone.path, file: file))
    }
}

// MARK: - Comparing branches

extension AppModel {
    /// What a pull request from `head` into `base` would change, read from
    /// the clone after fetching both branches; nil without a clone.
    func compareBranches(_ repo: ForgeRepo, base: String, head: String) async throws -> BranchComparison? {
        guard let clone = clone(of: repo) else { return nil }
        struct Params: Encodable, Sendable {
            var path: String
            var base: String
            var head: String
            var auth: GitAuth?
        }
        return try await core.call("repo.compare", Params(path: clone.path, base: base, head: head, auth: gitAuth(repo, clone)))
    }
}

// MARK: - Reviewing and merging

extension AppModel {
    /// The diff of a pull request, all of it or only `file`.
    func pullDiff(_ target: DiffTarget) async throws -> String {
        guard let client = client(for: target.repo.host) else { throw ForgeError.notAnswer }
        let whole = try await client.pullDiff(target.repo, number: target.number)
        guard let file = target.file else { return whole }
        return Self.section(of: whole, for: file)
    }

    /// The part of a git diff about one file.
    static func section(of diff: String, for file: String) -> String {
        var out: [Substring] = []
        var taking = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                taking = line.hasSuffix(" b/\(file)") || line.contains(" b/\(file) ")
            }
            if taking { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    enum ReviewEvent: String { case approve = "APPROVED", requestChanges = "REQUEST_CHANGES", comment = "COMMENT" }

    @discardableResult
    func submitReview(_ event: ReviewEvent, body: String, pull: PullRequest, in repo: ForgeRepo) async -> Bool {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return false }
        do {
            try await client.submitReview(slug, number: pull.number, event: event.rawValue, body: body, commit: pull.head.sha)
            let done: String = switch event {
            case .approve: "Approved #\(pull.number)"
            case .requestChanges: "Asked for changes on #\(pull.number)"
            case .comment: "Commented on #\(pull.number)"
            }
            toast(done)
            await refreshForge(repo, detailed: true)
            await loadExtras(pull, in: repo)
            Task { await checkForNews() }
            return true
        } catch {
            toast(error.localizedDescription, .error)
            return false
        }
    }

    @discardableResult
    func merge(_ pull: PullRequest, style: String, deleteBranch: Bool, in repo: ForgeRepo) async -> Bool {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return false }
        do {
            try await client.merge(slug, number: pull.number, style: style, deleteBranch: deleteBranch, head: pull.head.sha, title: nil)
            toast("Merged #\(pull.number) into \(pull.base.ref)")
            // Gone from the Inbox now, not at the next check.
            forgetPull(host: slug.host, fullName: "\(slug.owner)/\(slug.name)", number: pull.number)
            try? await Task.sleep(for: .seconds(1))
            Task { await checkForNews() }
            await refreshForge(repo, detailed: true)
            if let merged = forgeState(repo).pulls.first(where: { $0.number == pull.number }) { await loadExtras(merged, in: repo) }
            return true
        } catch {
            toast(error.localizedDescription, .error)
            return false
        }
    }

    /// Whether the user is the author: an author does not review their own work.
    func isMine(_ pull: PullRequest) -> Bool {
        guard let host = workspace?.host, let login = accounts.first(where: { $0.host == host })?.login else { return false }
        return pull.user?.login.lowercased() == login.lowercased()
    }

    func reviewRequested(of pull: PullRequest, in repo: ForgeRepo) -> Bool {
        guard let host = workspace?.host, let login = accounts.first(where: { $0.host == host })?.login.map({ $0.lowercased() }) else { return false }
        let summary = forgeState(repo).summary(for: pull)
        return summary.verdicts.contains { $0.user.login.lowercased() == login && $0.kind == .requested }
    }
}

// MARK: - Work across repositories

/// Where new work branches off.
enum StartBase: Hashable, Sendable {
    /// Each repository's main (default) branch on the server.
    case main
    /// A branch of that name on the server.
    case branch(String)
    /// What each clone has checked out, uncommitted changes included.
    case checkedOut
}

extension LocalBranch {
    /// A remote branch's name without the remote: "origin/develop" → "develop".
    var serverName: String { name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? name }
}

/// A branch checked out in one or more clones: a piece of work that may
/// span repositories (IAM here, resources there).
struct WorkInProgress: Identifiable, Sendable {
    var branch: String
    var items: [(repo: ForgeRepo, clone: Repo)]
    var id: String { branch }
}

extension AppModel {
    /// Feature branches checked out right now, grouped by name.
    var workInProgress: [WorkInProgress] {
        var groups: [String: [(ForgeRepo, Repo)]] = [:]
        for repo in repos {
            guard let clone = clone(of: repo), !clone.detached else { continue }
            let main = repo.defaultBranch ?? "main"
            guard clone.branch != main, clone.branch != "develop", clone.branch != "master" else { continue }
            groups[clone.branch, default: []].append((repo, clone))
        }
        return groups.map { WorkInProgress(branch: $0.key, items: $0.value.map { (repo: $0.0, clone: $0.1) }) }
            .sorted { a, b in a.items.count != b.items.count ? a.items.count > b.items.count : a.branch < b.branch }
    }

    /// Creates `branch` in each repository, from the chosen branch on the
    /// server (fetched first) or from what is checked out.
    func startWork(_ branch: String, in chosen: [ForgeRepo], from start: StartBase) async {
        struct Params: Encodable, Sendable {
            var path: String
            var name: String
            var base: String
        }
        var done: [String] = []
        var failed: [String] = []
        var missing: [String] = []
        for repo in chosen {
            var base = ""
            switch start {
            case .checkedOut:
                break
            case .main:
                await run(.fetch, on: repo)
                base = "origin/" + (repo.defaultBranch ?? "main")
            case .branch(let name):
                await run(.fetch, on: repo)
                guard let list = await branches(of: repo), list.remote.contains(where: { $0.serverName == name }) else {
                    missing.append(repo.name)
                    continue
                }
                base = "origin/" + name
            }
            let ok = await change(repo) { clone in
                try await core.run("repo.branch.create", Params(path: clone.path, name: branch, base: base))
            }
            if ok { done.append(repo.name) } else { failed.append(repo.name) }
        }
        if !done.isEmpty {
            toast("Created \(branch) in \(done.count == 1 ? done[0] : "\(done.count) repositories")")
        }
        if !failed.isEmpty { toast("Not created in \(failed.joined(separator: ", "))", .error) }
        if case .branch(let name) = start, !missing.isEmpty {
            toast("Not created in \(missing.joined(separator: ", ")): the server has no \(name) there", .error)
        }
    }

    /// Pushes the branch in every clone that has something to push.
    func pushAll(_ work: WorkInProgress, allowEmpty: Bool = false) async {
        var pushed = 0
        var empty: [String] = []
        for (repo, clone) in work.items where !clone.hasUpstream || clone.ahead > 0 {
            // Merged and deleted on the server: the work there is done, not unpushed.
            if clone.upstreamGone, await mergedPull(of: repo) != nil { continue }
            if !allowEmpty, !clone.hasUpstream, await newCommits(in: clone) == 0 {
                empty.append(repo.name)
                continue
            }
            struct Params: Encodable, Sendable {
                var path: String
                var force: Bool
                var auth: GitAuth?
            }
            let ok = await change(repo) { clone in
                try await core.run("repo.push", Params(path: clone.path, force: false, auth: gitAuth(repo, clone)))
            }
            if ok { pushed += 1 }
        }
        if pushed > 0 || empty.isEmpty {
            toast(pushed == 0 ? "Nothing to push in \(work.branch)" : "Pushed \(work.branch) in \(pushed) \(pushed == 1 ? "repository" : "repositories")")
        }
        if !empty.isEmpty {
            let names = ListFormatter.localizedString(byJoining: empty)
            confirm(title: "Publish empty \(work.branch)?",
                    message: "In \(names) the branch has no commits that are not already on the server. Publish it there anyway?",
                    button: "Publish Anyway") { [weak self] in
                guard let self else { return }
                let rest = WorkInProgress(branch: work.branch, items: work.items.filter { empty.contains($0.0.name) && !$0.1.hasUpstream })
                Task { await self.pushAll(rest, allowEmpty: true) }
            }
        }
    }
}

// MARK: - Resources

extension AppModel {
    func resources(of repo: ForgeRepo) async -> [TFItem]? {
        guard let clone = clone(of: repo) else { return nil }
        let result: TFItems? = try? await core.call("repo.resources", PathParams(path: clone.path))
        return result?.items
    }

    /// The newest Terraform plan read for any pull request of the repository.
    func latestPlan(of repo: ForgeRepo) -> TerraformPlan? {
        guard let slug = slug(repo) else { return nil }
        let pulls = forgeState(repo).pulls
        for pull in pulls {
            let extra = extras[Self.extrasKey(slug, pull.number)]
            if let plan = extra?.plan ?? extra?.applied { return plan }
        }
        return nil
    }
}

// MARK: - Tags

extension AppModel {
    func tags(of repo: ForgeRepo) async -> [GitTag] {
        guard let clone = clone(of: repo) else { return [] }
        let list: TagList? = try? await core.call("repo.tags", PathParams(path: clone.path))
        return list?.tags ?? []
    }

    enum TagAction: String { case create, push, delete, deleteRemote }

    @discardableResult
    func tag(_ action: TagAction, _ name: String, rev: String = "", message: String = "", in repo: ForgeRepo) async -> Bool {
        struct Params: Encodable, Sendable {
            var path: String
            var action: String
            var name: String
            var rev: String
            var message: String
            var auth: GitAuth?
        }
        let done: String = switch action {
        case .create: "Tagged \(name)"
        case .push: "Pushed \(name)"
        case .delete: "Deleted \(name)"
        case .deleteRemote: "Deleted \(name) on the server"
        }
        return await change(repo, success: done) { clone in
            try await core.run("repo.tag", Params(path: clone.path, action: action.rawValue, name: name, rev: rev, message: message,
                                                  auth: action == .push || action == .deleteRemote ? gitAuth(repo, clone) : nil))
        }
    }
}

// MARK: - Across repositories: search and module use

/// One place that uses a module repository.
struct ModuleUsage: Identifiable, Hashable, Sendable {
    var repo: ForgeRepo
    var module: String
    var file: String
    var line: Int
    var source: String
    /// The ref the source pins (?ref=v1), if any.
    var ref: String?
    var id: String { "\(repo.id):\(file):\(line)" }
}

extension AppModel {
    func grep(_ text: String, regex: Bool, ignoreCase: Bool) async throws -> [GrepHit] {
        struct Params: Encodable, Sendable {
            var paths: [String]
            var text: String
            var regex: Bool
            var ignoreCase: Bool
        }
        let paths = repos.compactMap { clone(of: $0)?.path }
        guard !paths.isEmpty else { return [] }
        let result: GrepResult = try await core.call("repos.grep", Params(paths: paths, text: text, regex: regex, ignoreCase: ignoreCase))
        return result.results
    }

    /// The lines of one clone's files that hold `text` (as typed; case
    /// ignored unless it has a capital letter), for the file browser.
    func grep(_ text: String, in repo: ForgeRepo) async throws -> [GrepMatch] {
        struct Params: Encodable, Sendable {
            var paths: [String]
            var text: String
            var regex: Bool
            var ignoreCase: Bool
        }
        guard let clone = clone(of: repo) else { return [] }
        let result: GrepResult = try await core.call("repos.grep", Params(paths: [clone.path], text: text, regex: false, ignoreCase: text.lowercased() == text))
        if let failed = result.results.first?.error { throw CoreClient.CoreError.rpc(code: 0, message: failed) }
        return result.results.first?.matches ?? []
    }

    /// Where other clones of the workspace use `repo` as a module source.
    func moduleUsage(of repo: ForgeRepo) async -> [ModuleUsage] {
        struct Params: Encodable, Sendable { var paths: [String] }
        let others = repos.filter { $0.id != repo.id }.compactMap { other in clone(of: other).map { (other, $0) } }
        guard !others.isEmpty else { return [] }
        let byPath = Dictionary(others.map { ($0.1.path, $0.0) }, uniquingKeysWith: { a, _ in a })
        guard let result: ModuleUses = try? await core.call("repos.modules", Params(paths: others.map(\.1.path))) else { return [] }
        let name = repo.name.lowercased()
        return result.uses.compactMap { use in
            guard let user = byPath[use.path], Self.source(use.item.source, refersTo: name) else { return nil }
            return ModuleUsage(repo: user, module: use.item.kind == "unit" ? use.item.name : "module.\(use.item.name)",
                               file: use.item.file, line: use.item.line, source: use.item.source, ref: Self.ref(in: use.item.source))
        }.sorted { $0.repo.name.localizedStandardCompare($1.repo.name) == .orderedAscending }
    }

    /// Whether a module source points at the repository `name`:
    /// "../terraform-modules//dns", "git::https://host/org/terraform-modules.git//x?ref=v1".
    static func source(_ source: String, refersTo name: String) -> Bool {
        let s = source.lowercased()
        return s.contains("/\(name).git") || s.contains("../\(name)/") || s.contains("../\(name)//") || s.hasPrefix("\(name)/")
            || s.contains("/\(name)//") || s.hasSuffix("/\(name)") || s.contains("../\(name)?")
    }

    static func ref(in source: String) -> String? {
        guard let range = source.range(of: "ref=") else { return nil }
        let rest = source[range.upperBound...]
        return String(rest.prefix { $0 != "&" && $0 != "\"" })
    }
}

// MARK: - Finished work

extension AppModel {
    /// The pull request the checked-out branch of `repo` was merged in, when
    /// the branch is gone from the server (merging usually deletes it). Asked
    /// once per branch; nil when it was deleted without a merge, or the
    /// server cannot tell.
    func mergedPull(of repo: ForgeRepo) async -> PullRequest? {
        guard let slug = slug(repo), let clone = local[slug.key], clone.upstreamGone, !clone.detached else { return nil }
        let key = clone.path + "|" + clone.branch
        if let known = mergedPulls[key] { return known }
        guard let client = client(for: slug.host),
              let pulls = try? await client.pullRequests(slug, state: "closed", limit: 50) else { return nil }
        let branch = clone.branch
        let merged = pulls.first { pull in
            pull.phase == .merged && (pull.head.name == branch || pull.head.name.hasSuffix(":" + branch))
        }
        mergedPulls[key] = .some(merged)
        return merged
    }

    /// Ends the work on a merged branch: switches back to the branch it was
    /// merged into, pulls it, and deletes the local branch (its commits are
    /// in the merge). Uncommitted changes stop it. With `keep` the branch
    /// stays: only the switch and the pull.
    @discardableResult
    func finishBranch(in repo: ForgeRepo, into base: String, keep: Bool = false) async -> Bool {
        guard let slug = slug(repo), let clone = local[slug.key] else { return false }
        let branch = clone.branch
        if clone.changes > 0 || !clone.state.isEmpty {
            toast("\(repo.name): \(branch) has uncommitted changes; commit or stash them first"
                  + (keep ? ", then switch to \(base)" : ""), .error)
            return false
        }
        // The base as the server has it ("origin/develop"), whatever the remote is called.
        let remote = await branches(of: repo)?.remote.first { $0.name.split(separator: "/", maxSplits: 1).last.map(String.init) == base }?.name
        struct Delete: Encodable, Sendable {
            var path: String
            var name: String
            var force: Bool
            var remote: Bool
            var auth: GitAuth?
        }
        let auth = auth(host: slug.host, forURL: clone.remote.url)
        let ok = await change(repo) { clone in
            try await core.run("repo.checkout", CheckoutParams(path: clone.path, name: remote ?? base, remote: remote != nil))
            try await core.run("repo.pull", RepoParams(path: clone.path, auth: auth))
            guard !keep else { return }
            // Forced: a squash merge leaves the branch's own commits unmerged in git's eyes.
            try await core.run("repo.branch.delete", Delete(path: clone.path, name: branch, force: true, remote: false, auth: nil))
        }
        if ok, !keep { mergedPulls[clone.path + "|" + branch] = nil }
        if ok, keep { toast("\(repo.name): switched to \(base)") }
        return ok
    }

    /// Finishes every merged clone of a piece of work, after asking.
    func finish(_ work: WorkInProgress, merged: [String: PullRequest]) {
        let done = work.items.filter { merged[$0.clone.path] != nil }
        guard !done.isEmpty else { return }
        let names = ListFormatter.localizedString(byJoining: done.map(\.repo.name))
        let bases = Set(done.compactMap { merged[$0.clone.path]?.base.name }).sorted().joined(separator: ", ")
        confirm(title: "Finish \(work.branch)?",
                message: "Its pull \(done.count == 1 ? "request is" : "requests are") merged. In \(names) the app switches back to \(bases), pulls it, and deletes \(work.branch) here.",
                button: "Finish") { [weak self] in
            guard let self else { return }
            Task {
                var finished = 0
                for entry in done {
                    if let base = merged[entry.clone.path]?.base.name, await self.finishBranch(in: entry.repo, into: base) { finished += 1 }
                }
                if finished > 0 {
                    self.toast("Finished \(work.branch) in \(finished) \(finished == 1 ? "repository" : "repositories")")
                }
            }
        }
    }
}
