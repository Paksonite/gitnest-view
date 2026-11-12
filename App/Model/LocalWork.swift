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

    @discardableResult
    func push(_ repo: ForgeRepo, force: Bool = false) async -> Bool {
        struct Params: Encodable, Sendable {
            var path: String
            var force: Bool
            var auth: GitAuth?
        }
        let branch = clone(of: repo)?.branch ?? ""
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

// MARK: - Reviewing and merging

extension AppModel {
    /// The diff of a pull request, all of it or only `file`.
    func pullDiff(_ target: DiffTarget) async throws -> String {
        guard let client = client(for: target.repo.host) else { throw ForgejoClient.ForgeError.notAnswer }
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
            try? await Task.sleep(for: .seconds(1))
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

    /// Creates `branch` in each repository, from the server's develop (or
    /// default branch) when `fromServer`, else from what is checked out.
    func startWork(_ branch: String, in chosen: [ForgeRepo], fromServer: Bool) async {
        struct Params: Encodable, Sendable {
            var path: String
            var name: String
            var base: String
        }
        var done: [String] = []
        var failed: [String] = []
        for repo in chosen {
            var base = ""
            if fromServer {
                await run(.fetch, on: repo)
                base = "origin/" + (await defaultBase(for: branch, in: repo))
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
    }

    /// Pushes the branch in every clone that has something to push.
    func pushAll(_ work: WorkInProgress) async {
        var pushed = 0
        for (repo, clone) in work.items where !clone.hasUpstream || clone.ahead > 0 {
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
        toast(pushed == 0 ? "Nothing to push in \(work.branch)" : "Pushed \(work.branch) in \(pushed) \(pushed == 1 ? "repository" : "repositories")")
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
