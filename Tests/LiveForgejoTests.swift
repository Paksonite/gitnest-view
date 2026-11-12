import UserNotifications
import XCTest
@testable import GitNestView

/// Against a real Forgejo server; skipped unless the environment names one:
///
///     TEST_RUNNER_GNV_HOST=forge.example.com TEST_RUNNER_GNV_TOKEN=… \
///     TEST_RUNNER_GNV_REPO=owner/name scripts/test.sh
///
/// The repository needs at least one pull request and one Actions run.
/// With GNV_DISPATCH=workflow.yaml the test also starts that workflow (the
/// token then needs write access) and follows its log while it runs.
final class LiveForgejoTests: XCTestCase {
    private var client: ForgejoClient!
    private var slug: RepoSlug!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["GNV_HOST"], let token = env["GNV_TOKEN"],
              let parts = env["GNV_REPO"]?.split(separator: "/"), parts.count == 2
        else { throw XCTSkip("no live server configured") }
        client = ForgejoClient(host: host, token: token)
        slug = RepoSlug(host: host, owner: String(parts[0]), name: String(parts[1]))
    }

    func testReadsPullRequestsChecksAndReviews() async throws {
        let user = try await client.currentUser()
        XCTAssertFalse(user.login.isEmpty)
        let version = try await client.version()
        XCTAssertFalse(version.isEmpty)

        let pulls = try await client.pullRequests(slug, state: "all")
        let pull = try XCTUnwrap(pulls.first, "the test repository needs a pull request")
        _ = try await client.reviews(slug, pull: pull.number)
        let status = try await client.combinedStatus(slug, ref: pull.head.sha)
        for check in status.checks where check.context.contains("/") {
            XCTAssertNotNil(check.jobReference, "an Actions status must point at its job: \(check.targetURL ?? "nil")")
        }
    }

    func testReadsRunsJobsAndAFinishedLog() async throws {
        let runs = try await client.runs(slug)
        let run = try XCTUnwrap(runs.first { $0.state.isFinished }, "the test repository needs a finished run")
        let jobs = try await client.jobs(slug, run: run.id)
        let job = try XCTUnwrap(jobs.first)

        let whole = try await client.jobLog(slug, job: job.id, from: 0)
        let data = try XCTUnwrap(whole)
        XCTAssertGreaterThan(data.count, 100)
        // Reading from the middle gives exactly the rest; from the end, nothing.
        let half = data.count / 2
        let rest = try await client.jobLog(slug, job: job.id, from: half)
        XCTAssertEqual(rest, data.dropFirst(half))
        let nothing = try await client.jobLog(slug, job: job.id, from: data.count)
        XCTAssertEqual(nothing, Data())
    }

    /// The whole path of the app: connect, list the workspace's
    /// repositories, clone one with the token, switch branch, read the
    /// pull request with its plan.
    @MainActor
    func testConnectListCloneAndRead() async throws {
        let env = ProcessInfo.processInfo.environment
        let workdir = FileManager.default.temporaryDirectory.appending(path: "gnv-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        XCTAssertFalse(model.isSetUp)
        model.setWorkdir(workdir)
        try await model.connect(host: "https://\(slug.host)/", token: try XCTUnwrap(env["GNV_TOKEN"]))
        XCTAssertTrue(model.isSetUp)
        XCTAssertEqual(model.accounts.first?.host, slug.host)

        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner.lowercased() == slug.owner.lowercased() })
        model.select(workspace)
        await model.loadRepos(quiet: false)
        let repo = try XCTUnwrap(model.repos.first { $0.name == slug.name }, model.reposError ?? "repository not listed")
        XCTAssertNil(model.clone(of: repo))

        await model.clone(repo)
        let clone = try XCTUnwrap(model.clone(of: repo), model.toasts.map(\.text).joined(separator: "; "))
        XCTAssertTrue(clone.path.hasSuffix("/\(slug.owner)/\(slug.name)"), clone.path)
        let remote = try String(contentsOfFile: clone.path + "/.git/config", encoding: .utf8)
        XCTAssertFalse(remote.contains(try XCTUnwrap(env["GNV_TOKEN"])), "the token must not be written into the clone")

        await model.run(.fetch, on: repo)
        XCTAssertFalse(model.toasts.contains { $0.kind == .error }, model.toasts.map(\.text).joined(separator: "; "))
        let listed = await model.branches(of: repo)
        let branches = try XCTUnwrap(listed)
        if let other = branches.remote.first(where: { !$0.name.hasSuffix("/HEAD") && !$0.name.hasSuffix("/" + clone.branch) }) {
            await model.checkout(other, in: repo)
            XCTAssertFalse(model.toasts.contains { $0.kind == .error }, model.toasts.map(\.text).joined(separator: "; "))
            XCTAssertEqual(model.clone(of: repo).map { "origin/" + $0.branch }, other.name)
        }
        let commits = await model.commits(of: repo)
        XCTAssertFalse(commits.isEmpty)

        model.selection = repo.id
        await model.refreshSelected()
        let state = model.forgeState(repo)
        XCTAssertTrue(state.loaded, state.error ?? "")
        XCTAssertFalse(state.runs.isEmpty)
        let pull = try XCTUnwrap(state.pulls.first)
        await model.loadExtras(pull, in: repo)
        let extra = try XCTUnwrap(model.extras[AppModel.extrasKey(slug, pull.number)])
        XCTAssertFalse(extra.commits.isEmpty)
        XCTAssertFalse(extra.files.isEmpty)
        await model.refreshInbox()
    }

    /// Workflows with their manual triggers, and the draft of a release.
    /// With GNV_RELEASE=head:base the test also opens that pull request
    /// (the token then needs write access).
    @MainActor
    func testWorkflowsAndReleaseDraft() async throws {
        let env = ProcessInfo.processInfo.environment
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(FileManager.default.temporaryDirectory)
        try await model.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))
        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner.lowercased() == slug.owner.lowercased() })
        model.select(workspace)
        await model.loadRepos(quiet: false)
        let repo = try XCTUnwrap(model.repos.first { $0.name == slug.name })

        await model.loadWorkflows(repo)
        let workflows = try XCTUnwrap(model.workflows[slug.key])
        XCTAssertFalse(workflows.isEmpty, "the test repository needs a workflow")
        XCTAssertTrue(workflows.allSatisfy { $0.info != nil }, "every workflow file must parse")
        XCTAssertTrue(workflows.contains { $0.info?.dispatch == true })

        guard let pair = env["GNV_RELEASE"]?.split(separator: ":").map(String.init), pair.count == 2 else { return }
        let draft = try await model.releaseDraft(repo, head: pair[0], base: pair[1])
        XCTAssertFalse(draft.title.isEmpty)
        if draft.existing == nil, !draft.commits.isEmpty {
            try await model.createRelease(repo, head: pair[0], base: pair[1], title: draft.title, body: draft.body)
            let again = try await model.releaseDraft(repo, head: pair[0], base: pair[1])
            XCTAssertNotNil(again.existing, "the release pull request must exist now")
            XCTAssertEqual(model.pendingPull, again.existing?.number)
        }
    }

    /// Notifications against the lab (org Lab-GCP): the first check only
    /// remembers what exists; a new review request is announced, once.
    /// Needs GNV_REVIEWER_TOKEN (a second account that can open pull
    /// requests in GNV_LAB_REPO, e.g. Lab-GCP/org-core-firewalls).
    @MainActor
    func testNotifiesNewReviewRequestsOnce() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let reviewerToken = env["GNV_REVIEWER_TOKEN"], let lab = env["GNV_LAB_REPO"]?.split(separator: "/").map(String.init), lab.count == 2 else {
            throw XCTSkip("GNV_REVIEWER_TOKEN and GNV_LAB_REPO are not set")
        }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(FileManager.default.temporaryDirectory)
        try await model.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))

        var posted: [UNNotificationRequest] = []
        Notifier.shared.deliver = { posted.append($0) }
        defer { Notifier.shared.deliver = nil }

        await model.checkForNews()
        XCTAssertTrue(posted.isEmpty, "the first check only remembers")
        XCTAssertNotNil(defaults.stringArray(forKey: "notified"))

        // The reviewer opens a pull request and asks for our review.
        let reviewer = ForgejoClient(host: slug.host, token: reviewerToken)
        let labSlug = RepoSlug(host: slug.host, owner: lab[0], name: lab[1])
        let branch = "test/notify-\(Int(Date().timeIntervalSince1970))"
        let pull = try await LabHelper.openPull(reviewer, labSlug, branch: branch, reviewer: try XCTUnwrap(model.accounts.first?.login))
        addTeardownBlock { try? await LabHelper.close(reviewer, labSlug, pull: pull, branch: branch) }

        await model.checkForNews()
        let reviews = posted.filter { $0.identifier.hasPrefix("review:") }
        XCTAssertEqual(reviews.count, 1, "one notification for the new review request: \(posted.map(\.identifier))")
        XCTAssertEqual(reviews.first?.content.userInfo["number"] as? Int, pull)
        await model.checkForNews()
        XCTAssertEqual(posted.filter { $0.identifier.hasPrefix("review:") }.count, 1, "announced once")
    }

    /// The Changes workflow end to end, through the model: clone, branch,
    /// edit, stage some lines, commit, push over HTTPS with the token, open a
    /// pull request, then clean up. Needs a token that may write.
    @MainActor
    func testBranchCommitPushAndOpenPullRequest() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GNV_WRITE"] == "1" else { throw XCTSkip("GNV_WRITE=1 is not set") }
        let workdir = FileManager.default.temporaryDirectory.appending(path: "gnv-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(workdir)
        try await model.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))
        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner.lowercased() == slug.owner.lowercased() })
        model.select(workspace)
        await model.loadRepos(quiet: false)
        let repo = try XCTUnwrap(model.repos.first { $0.name == slug.name })
        await model.clone(repo)
        var clone = try XCTUnwrap(model.clone(of: repo))

        let branch = "test/changes-\(Int(Date().timeIntervalSince1970))"
        let made = await model.createBranch(branch, in: repo)
        XCTAssertTrue(made)
        XCTAssertEqual(model.clone(of: repo)?.branch, branch)

        // Two new lines; only the first is staged and committed.
        let file = URL(fileURLWithPath: clone.path).appending(path: "a-\(branch.split(separator: "-").last!).txt")
        try "keep me\nnot this one\n".write(to: file, atomically: true, encoding: .utf8)
        await model.refreshClone(repo)
        let files = await model.changedFiles(of: repo)
        let changed = try XCTUnwrap(files.first { $0.path == file.lastPathComponent })
        XCTAssertTrue(changed.untracked)
        let diff = try await model.diff(changed, staged: false, in: repo)
        XCTAssertEqual(diff.hunks.first?.rows.map(\.text), ["keep me", "not this one"])
        let staged = await model.lines(.stage, [LineRef(Hunk: 0, Line: 0)], of: changed, diff: diff, in: repo)
        XCTAssertTrue(staged)
        let committed = await model.commit("test: keep one line\n\nMade by a GitNest View test.", amend: false, in: repo)
        XCTAssertTrue(committed)
        clone = try XCTUnwrap(model.clone(of: repo))
        XCTAssertEqual(clone.changes, 1, "the second line stays uncommitted")
        XCTAssertFalse(clone.hasUpstream)

        let pushed = await model.push(repo)
        XCTAssertTrue(pushed, model.toasts.map(\.text).joined(separator: "; "))
        clone = try XCTUnwrap(model.clone(of: repo))
        XCTAssertTrue(clone.hasUpstream)
        XCTAssertEqual(clone.ahead, 0)
        let config = try String(contentsOfFile: clone.path + "/.git/config", encoding: .utf8)
        XCTAssertFalse(config.contains(try XCTUnwrap(env["GNV_TOKEN"])), "the token must not be written into the clone")

        let base = await model.defaultBase(for: branch, in: repo)
        let draft = try await model.releaseDraft(repo, head: branch, base: base, release: false)
        XCTAssertEqual(draft.title, "test: keep one line")
        XCTAssertEqual(draft.commits.count, 1)
        try await model.createRelease(repo, head: branch, base: base, title: draft.title, body: draft.body)
        let number = try XCTUnwrap(model.pendingPull)
        let client = try XCTUnwrap(model.client(for: slug.host))
        let pull = try await client.pullRequest(slug, number: number)
        XCTAssertEqual(pull.head.ref, branch)

        // Clean up: close the pull request, delete the branch on the server.
        try await LabHelper.close(client, slug, pull: number, branch: branch)
    }

    /// Review and merge through the model: the reviewer opens a pull
    /// request, we read its diff, approve it, and squash-merge it.
    @MainActor
    func testDiffApproveAndMerge() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GNV_WRITE"] == "1", let reviewerToken = env["GNV_REVIEWER_TOKEN"],
              let lab = env["GNV_LAB_REPO"]?.split(separator: "/").map(String.init), lab.count == 2 else {
            throw XCTSkip("GNV_WRITE, GNV_REVIEWER_TOKEN and GNV_LAB_REPO are not set")
        }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(FileManager.default.temporaryDirectory)
        try await model.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))
        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner.lowercased() == lab[0].lowercased() })
        model.select(workspace)
        await model.loadRepos(quiet: false)
        let repo = try XCTUnwrap(model.repos.first { $0.name == lab[1] })

        let reviewer = ForgejoClient(host: slug.host, token: reviewerToken)
        let labSlug = RepoSlug(host: slug.host, owner: lab[0], name: lab[1])
        let branch = "test/merge-\(Int(Date().timeIntervalSince1970))"
        let number = try await LabHelper.openPull(reviewer, labSlug, branch: branch, reviewer: try XCTUnwrap(model.accounts.first?.login))
        await model.refreshForge(repo, detailed: true)
        let pull = try XCTUnwrap(model.forgeState(repo).pulls.first { $0.number == number })
        XCTAssertFalse(model.isMine(pull))
        XCTAssertTrue(model.reviewRequested(of: pull, in: repo))

        let file = "notes/\(branch.replacingOccurrences(of: "/", with: "-")).md"
        let diff = try await model.pullDiff(DiffTarget(repo: labSlug, number: number, title: pull.title, file: file))
        XCTAssertTrue(diff.contains("+note \(branch)"), diff)
        XCTAssertTrue(diff.hasPrefix("diff --git"))

        let approved = await model.submitReview(.approve, body: "Looks good (test).", pull: pull, in: repo)
        XCTAssertTrue(approved, model.toasts.map(\.text).joined(separator: "; "))
        XCTAssertEqual(model.forgeState(repo).summary(for: pull).approvals, 1)
        XCTAssertFalse(model.reviewRequested(of: pull, in: repo))

        let merged = await model.merge(pull, style: "squash", deleteBranch: true, in: repo)
        XCTAssertTrue(merged, model.toasts.map(\.text).joined(separator: "; "))
        let client = try XCTUnwrap(model.client(for: slug.host))
        let after = try await client.pullRequest(labSlug, number: number)
        XCTAssertEqual(after.merged, true)
    }

    /// One branch in two repositories: start work from the server, commit
    /// in both, push both, and see the work grouped.
    @MainActor
    func testStartWorkAndPushAll() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GNV_WRITE"] == "1", let lab = env["GNV_LAB_REPO"]?.split(separator: "/").map(String.init), lab.count == 2 else {
            throw XCTSkip("GNV_WRITE and GNV_LAB_REPO are not set")
        }
        let workdir = FileManager.default.temporaryDirectory.appending(path: "gnv-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(workdir)
        try await model.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))
        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner.lowercased() == lab[0].lowercased() })
        model.select(workspace)
        await model.loadRepos(quiet: false)
        let chosen = model.repos.filter { [lab[1], "terraform-modules"].contains($0.name) }
        XCTAssertEqual(chosen.count, 2)
        for repo in chosen { await model.clone(repo) }

        let branch = "test/multi-\(Int(Date().timeIntervalSince1970))"
        await model.startWork(branch, in: chosen, fromServer: true)
        for repo in chosen {
            let clone = try XCTUnwrap(model.clone(of: repo))
            XCTAssertEqual(clone.branch, branch)
            XCTAssertFalse(clone.hasUpstream, "a branch started from the server must not track develop or main")
            try "multi\n".write(to: URL(fileURLWithPath: clone.path).appending(path: "multi.txt"), atomically: true, encoding: .utf8)
            await model.refreshClone(repo)
            await model.stage([], all: true, in: repo)
            let committed = await model.commit("test: multi-repo work", amend: false, in: repo)
            XCTAssertTrue(committed, model.toasts.map(\.text).joined(separator: "; "))
        }
        let work = try XCTUnwrap(model.workInProgress.first { $0.branch == branch })
        XCTAssertEqual(work.items.count, 2)
        await model.pushAll(work)
        let client = try XCTUnwrap(model.client(for: slug.host))
        for repo in chosen {
            let clone = try XCTUnwrap(model.clone(of: repo))
            XCTAssertTrue(clone.hasUpstream, model.toasts.map(\.text).joined(separator: "; "))
            let repoSlug = RepoSlug(host: slug.host, owner: lab[0], name: repo.name)
            _ = try? await LabHelper.request(client, "DELETE", "repos/\(repoSlug.owner)/\(repoSlug.name)/branches/\(branch)", nil)
        }
    }

    /// Without the server (here: a token it refuses) the app keeps the
    /// workspace and the last known repositories, and says it is offline.
    @MainActor
    func testOfflineKeepsTheLastKnownRepositories() async throws {
        let env = ProcessInfo.processInfo.environment
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "useRepoCache")
        defer { defaults.removePersistentDomain(forName: suite) }
        let online = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        online.setWorkdir(FileManager.default.temporaryDirectory)
        try await online.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))
        let workspace = try XCTUnwrap(online.workspaces.first { !$0.personal })
        online.select(workspace)
        await online.loadRepos(quiet: false)
        let known = online.repos.map(\.name)
        XCTAssertFalse(known.isEmpty)
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GitNest View/repos-\(workspace.id.replacingOccurrences(of: "/", with: "_")).json")
        defer { try? FileManager.default.removeItem(at: cache) }

        let refused = MemoryTokenStore()
        try refused.setToken("not-a-valid-token", for: slug.host)
        let offline = AppModel(tokens: refused, defaults: defaults)
        await offline.reload()
        XCTAssertEqual(offline.workspace?.id, workspace.id, "the chosen workspace stays")
        XCTAssertEqual(offline.repos.map(\.name), known, "the last known list is shown")
        XCTAssertNotNil(offline.offline)
        XCTAssertNil(offline.reposError)
    }

    /// Offline on the very first launch of a version with the cache: the
    /// clones in the working directory make the list.
    @MainActor
    func testOfflineWithoutCacheUsesTheClones() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let workdir = env["GNV_LAB_WORKDIR"] else { throw XCTSkip("GNV_LAB_WORKDIR is not set") }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([ForgeAccount(host: slug.host, login: "claude")]), forKey: "accounts")
        defaults.set(workdir, forKey: "workdir")
        let refused = MemoryTokenStore()
        try refused.setToken("not-a-valid-token", for: slug.host)
        let model = AppModel(tokens: refused, defaults: defaults)
        await model.reload()
        XCTAssertNotNil(model.offline)
        XCTAssertEqual(model.workspace?.owner, "Lab-GCP", "the owner with the most clones")
        XCTAssertFalse(model.repos.isEmpty)
        XCTAssertTrue(model.repos.allSatisfy { model.clone(of: $0) != nil })
    }

    /// Starting a workflow with inputs: the values reach the run (the lab's
    /// drift detection names its job after the chosen environment).
    @MainActor
    func testDispatchWithInputs() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GNV_WRITE"] == "1" else { throw XCTSkip("GNV_WRITE=1 is not set") }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(FileManager.default.temporaryDirectory)
        try await model.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))
        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner == "Lab-GCP" }, "needs the lab (org Lab-GCP)")
        model.select(workspace)
        await model.loadRepos(quiet: false)
        let repo = try XCTUnwrap(model.repos.first { $0.name == "org-core-dns" })
        await model.loadWorkflows(repo)
        let drift = try XCTUnwrap(model.workflows[try XCTUnwrap(model.slug(repo)).key]?.first { $0.file == "drift-detection.yaml" })
        XCTAssertEqual(drift.info?.inputs.map(\.name), ["environment", "refresh_only", "note"])

        let client = try XCTUnwrap(model.client(for: slug.host))
        let labSlug = try XCTUnwrap(model.slug(repo))
        let before = try await client.runs(labSlug, limit: 1).first?.id ?? 0
        try await model.dispatch(drift, ref: "main", inputs: ["environment": "test", "refresh_only": "false", "note": "from a test"], in: repo)
        var run: WorkflowRun?
        for _ in 0..<30 where run == nil {
            try await Task.sleep(for: .seconds(1))
            run = try await client.runs(labSlug, limit: 3).first { $0.id > before && $0.workflowID == "drift-detection.yaml" }
        }
        let started = try XCTUnwrap(run, "the dispatched run did not appear")
        let jobs = try await client.jobs(labSlug, run: started.id)
        XCTAssertEqual(jobs.first?.name, "Drift check (test)", "the input reached the job")
    }

    @MainActor
    func testFollowsARunningJob() async throws {
        guard let workflow = ProcessInfo.processInfo.environment["GNV_DISPATCH"] else {
            throw XCTSkip("GNV_DISPATCH is not set")
        }
        let client = client!
        let slug = slug!
        let before = try await client.runs(slug, limit: 1).first?.id ?? 0
        try await Self.dispatch(workflow, client: client, slug: slug)

        var run: WorkflowRun?
        for _ in 0..<20 where run == nil {
            try await Task.sleep(for: .seconds(1))
            run = try await client.runs(slug, limit: 1).first { $0.id > before }
        }
        let started = try XCTUnwrap(run, "the dispatched run did not appear")
        let first = try await client.jobs(slug, run: started.id).first
        var job = try XCTUnwrap(first)

        // The test runner takes one job at a time and the other live tests
        // queue Lab pipelines, so wait for this job to start before timing it.
        let queuedUntil = Date.now.addingTimeInterval(900)
        while ["waiting", "blocked", "queued"].contains(job.status), Date.now < queuedUntil {
            try await Task.sleep(for: .seconds(3))
            let now = try await client.jobs(slug, run: started.id).first
            job = try XCTUnwrap(now)
        }

        let follower = LogFollower()
        follower.follow(LogTarget(repo: slug, runID: started.id, jobID: job.id, title: "live", webURL: nil), client: client)

        // The log must grow while the job is still running: that is "live".
        var sizesWhileRunning: Set<Int> = []
        let deadline = Date.now.addingTimeInterval(300)
        while follower.live, Date.now < deadline {
            if follower.state == .running, !follower.lines.isEmpty { sizesWhileRunning.insert(follower.lines.count) }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertFalse(follower.live, "the job did not end in time")
        XCTAssertEqual(follower.state, .success)
        XCTAssertGreaterThan(sizesWhileRunning.count, 3, "the log did not grow while the job ran")

        // Followed step by step, the log has everything the job printed.
        // Forgejo 17 tells a job's steps; 16 does not, and the log is then read whole.
        let version = try await client.version()
        if !version.hasPrefix("16.") { XCTAssertFalse(follower.steps.isEmpty, "Forgejo \(version) tells a job's steps") }
        let printed = follower.lines.filter { $0.text.hasPrefix("line ") }.map(\.text)
        XCTAssertEqual(printed.count, 40)
        XCTAssertTrue(follower.steps.allSatisfy { $0.step.state.isFinished })
    }

    private static func dispatch(_ workflow: String, client: ForgejoClient, slug: RepoSlug) async throws {
        let url = client.baseURL.appending(path: "api/v1/repos/\(slug.owner)/\(slug.name)/actions/workflows/\(workflow)/dispatches")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("token " + (client.token ?? ""), forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"ref":"main"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    /// The conversation and the upkeep of a pull request, on a fresh one
    /// in the lab: comment, ask for a review and take it back, draft, edit,
    /// update the branch, close and reopen.
    @MainActor
    func testConversationPeopleAndUpkeep() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GNV_WRITE"] == "1", let reviewerToken = env["GNV_REVIEWER_TOKEN"],
              let lab = env["GNV_LAB_REPO"]?.split(separator: "/").map(String.init), lab.count == 2 else {
            throw XCTSkip("GNV_WRITE, GNV_REVIEWER_TOKEN and GNV_LAB_REPO are not set")
        }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(FileManager.default.temporaryDirectory)
        try await model.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))
        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner.lowercased() == lab[0].lowercased() })
        model.select(workspace)
        await model.loadRepos(quiet: false)
        let repo = try XCTUnwrap(model.repos.first { $0.name == lab[1] })
        let labSlug = RepoSlug(host: slug.host, owner: lab[0], name: lab[1])
        let me = try XCTUnwrap(model.accounts.first?.login)

        // The reviewer opens a pull request; the user works on it.
        let reviewer = ForgejoClient(host: slug.host, token: reviewerToken)
        let branch = "test/collab-\(Int(Date().timeIntervalSince1970))"
        let number = try await LabHelper.openPull(reviewer, labSlug, branch: branch, reviewer: me)
        func current() async throws -> PullRequest {
            await model.refreshForge(repo, detailed: true)
            return try XCTUnwrap(model.forgeState(repo).pulls.first { $0.number == number })
        }
        func errors() -> String { model.toasts.filter { $0.kind == .error }.map(\.text).joined(separator: "; ") }
        var pull = try await current()

        // Conversation: a comment from the reviewer is read, an answer is sent.
        try await reviewer.comment(labSlug, number: number, body: "Why this rule?")
        await model.loadExtras(pull, in: repo)
        let key = AppModel.extrasKey(labSlug, number)
        XCTAssertEqual(model.extras[key]?.comments.map(\.body), ["Why this rule?"])
        let answered = await model.comment(on: pull, in: repo, text: "Because the test says so.")
        XCTAssertTrue(answered, errors())
        XCTAssertEqual(model.extras[key]?.comments.map(\.body), ["Why this rule?", "Because the test says so."])
        XCTAssertEqual(model.extras[key]?.comments.last?.user?.login, me)

        // People: who can be asked, ask, take it back.
        let candidates = await model.reviewerCandidates(pull, in: repo)
        XCTAssertFalse(candidates.contains { $0.login == pull.user?.login }, "the author cannot review their own pull request")
        if let someone = candidates.first(where: { $0.login != me }) {
            await model.requestReview(of: pull, in: repo, from: someone)
            pull = try await current()
            XCTAssertTrue((pull.requestedReviewers ?? []).contains { $0.login == someone.login }, errors())
            await model.requestReview(of: pull, in: repo, from: someone, withdraw: true)
            pull = try await current()
            XCTAssertFalse((pull.requestedReviewers ?? []).contains { $0.login == someone.login }, errors())
        }
        let assignable = await model.assigneeCandidates(in: repo)
        XCTAssertTrue(assignable.contains { $0.login == me })
        await model.setAssignees([me], on: pull, in: repo)
        pull = try await current()
        XCTAssertEqual(pull.assignees?.map(\.login), [me], errors())

        // Upkeep: draft and back, edit, update the branch, close, reopen.
        let title = pull.title
        await model.setDraft(true, pull, in: repo)
        pull = try await current()
        XCTAssertTrue(AppModel.isDraft(pull), errors())
        await model.setDraft(false, pull, in: repo)
        pull = try await current()
        XCTAssertEqual(pull.title, title)
        let saved = await model.edit(pull, in: repo, title: title + " (edited)", body: "Edited by a GitNest View test.")
        XCTAssertTrue(saved, errors())
        pull = try await current()
        XCTAssertEqual(pull.title, title + " (edited)")
        XCTAssertEqual(pull.body, "Edited by a GitNest View test.")

        await model.updateBranch(of: pull, in: repo, rebase: false)
        // Up to date already, or updated: either way the server must not refuse the request itself.
        XCTAssertFalse(errors().contains("404") || errors().contains("405"), errors())

        await model.setOpen(false, pull, in: repo)
        pull = try await current()
        XCTAssertEqual(pull.state, "closed", errors())
        await model.setOpen(true, pull, in: repo)
        pull = try await current()
        XCTAssertEqual(pull.state, "open", errors())

        // Around it: notifications are readable, releases and variables do not fail.
        await model.refreshNotifications()
        _ = await model.releases(of: repo)
        _ = await model.actionSettings(of: repo)

        try await LabHelper.close(reviewer, labSlug, pull: number, branch: branch)
    }

    /// The to-do queue, the releases across the lab, and the quick actions
    /// of the menu bar, against the lab organisation.
    @MainActor
    func testQueueReleasesAndQuickActions() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GNV_WRITE"] == "1", let reviewerToken = env["GNV_REVIEWER_TOKEN"],
              let lab = env["GNV_LAB_REPO"]?.split(separator: "/").map(String.init), lab.count == 2 else {
            throw XCTSkip("GNV_WRITE, GNV_REVIEWER_TOKEN and GNV_LAB_REPO are not set")
        }
        let suite = "gnv-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.setWorkdir(FileManager.default.temporaryDirectory)
        try await model.connect(host: slug.host, token: try XCTUnwrap(env["GNV_TOKEN"]))
        let workspace = try XCTUnwrap(model.workspaces.first { $0.owner.lowercased() == lab[0].lowercased() })
        model.select(workspace)
        await model.loadRepos(quiet: false)

        // Releases: read-only, every repository whose develop is ahead.
        let candidates = await model.releaseCandidates()
        XCTAssertFalse(candidates.isEmpty, "the lab keeps commits on develop")
        XCTAssertTrue(candidates.allSatisfy { !$0.draft.commits.isEmpty && $0.draft.head == "develop" })

        // A review request appears in the queue; approving it from the
        // menu bar takes it out again.
        let reviewer = ForgejoClient(host: slug.host, token: reviewerToken)
        let labSlug = RepoSlug(host: slug.host, owner: lab[0], name: lab[1])
        let branch = "test/quick-\(Int(Date().timeIntervalSince1970))"
        let number = try await LabHelper.openPull(reviewer, labSlug, branch: branch, reviewer: try XCTUnwrap(model.accounts.first?.login))
        await model.checkForNews()
        let entry = try XCTUnwrap(model.inbox.first { $0.hit.number == number && $0.hit.repository?.name == lab[1] })
        XCTAssertTrue(model.todo.contains { if case .review(let item) = $0.action { return item.id == entry.id } else { return false } })
        let approved = await model.quickApprove(entry)
        XCTAssertTrue(approved, model.toasts.map(\.text).joined(separator: "; "))
        XCTAssertFalse(model.inbox.contains { $0.id == entry.id }, "an approved request leaves the queue")
        let reviews = try await reviewer.reviews(labSlug, pull: number)
        XCTAssertTrue(reviews.contains { $0.state == "APPROVED" })
        try await LabHelper.close(reviewer, labSlug, pull: number, branch: branch)

        // The queue is ordered by urgency.
        let ranks = model.todo.map(\.rank)
        XCTAssertEqual(ranks, ranks.sorted())

        // A failing pull request of mine can be run again.
        if let failing = model.myPulls.first(where: { $0.state == .failure }) {
            model.toasts.removeAll()
            let again = await model.rerunFailed(failing)
            if model.supportsRerun(failing.host) {
                XCTAssertTrue(again, model.toasts.map(\.text).joined(separator: "; "))
            } else {
                // Forgejo 16: no re-run in the API. The app says so and does not pretend.
                XCTAssertFalse(again)
                XCTAssertFalse(model.toasts.contains { $0.kind == .error }, "an unsupported re-run is explained, not failed")
            }
        }
    }
}

/// Makes and removes test pull requests through the API.
enum LabHelper {
    struct Body: Encodable {
        var files: [File]
        var message: String
        var branch: String
        var new_branch: String
        struct File: Encodable {
            var operation = "create"
            var path: String
            var content: String
        }
    }

    static func request(_ client: ForgejoClient, _ method: String, _ path: String, _ body: Data?) async throws -> Data {
        var request = URLRequest(url: client.baseURL.appending(path: "api/v1/" + path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("token " + (client.token ?? ""), forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NSError(domain: "lab", code: code, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path): \(code) \(String(decoding: data, as: UTF8.self))"])
        }
        return data
    }

    /// A branch with one new file and a pull request into the default branch
    /// asking `reviewer` for a review. Returns the pull request's number.
    static func openPull(_ client: ForgejoClient, _ repo: RepoSlug, branch: String, reviewer: String) async throws -> Int {
        let content = Data("note \(branch)\n".utf8).base64EncodedString()
        let body = Body(files: [.init(path: "notes/\(branch.replacingOccurrences(of: "/", with: "-")).md", content: content)],
                        message: "test: \(branch)", branch: "main", new_branch: branch)
        _ = try await request(client, "POST", "repos/\(repo.owner)/\(repo.name)/contents", try JSONEncoder().encode(body))
        let pull = try JSONSerialization.data(withJSONObject: ["head": branch, "base": "main", "title": "test: notification \(branch)", "body": "Made by a GitNest View test."])
        let made = try await request(client, "POST", "repos/\(repo.owner)/\(repo.name)/pulls", pull)
        let number = try XCTUnwrap((try JSONSerialization.jsonObject(with: made) as? [String: Any])?["number"] as? Int)
        let ask = try JSONSerialization.data(withJSONObject: ["reviewers": [reviewer]])
        _ = try await request(client, "POST", "repos/\(repo.owner)/\(repo.name)/pulls/\(number)/requested_reviewers", ask)
        return number
    }

    static func close(_ client: ForgejoClient, _ repo: RepoSlug, pull: Int, branch: String) async throws {
        let closed = try JSONSerialization.data(withJSONObject: ["state": "closed"])
        _ = try await request(client, "PATCH", "repos/\(repo.owner)/\(repo.name)/pulls/\(pull)", closed)
        _ = try? await request(client, "DELETE", "repos/\(repo.owner)/\(repo.name)/branches/\(branch)", nil)
    }
}
