import XCTest
@testable import GitNestView

/// GitHub and GitLab against real servers, skipped unless named:
/// GNV_GITHUB_TOKEN + GNV_GITHUB_REPO ("owner/name", read only: nothing is
/// changed there), and GNV_GITLAB_HOST + GNV_GITLAB_TOKEN + GNV_GITLAB_REPO
/// ("group/name", a lab project that may be written to: a merge request is
/// opened, commented on, approved, labelled and closed).
@MainActor
final class LiveProviderTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func slug(_ host: String, _ full: String) throws -> RepoSlug {
        let index = try XCTUnwrap(full.lastIndex(of: "/"))
        return RepoSlug(host: host, owner: String(full[..<index]), name: String(full[full.index(after: index)...]))
    }

    // MARK: GitHub

    func testGitHubReadsEverythingTheAppShows() async throws {
        guard let token = env["GNV_GITHUB_TOKEN"], let full = env["GNV_GITHUB_REPO"] else { throw XCTSkip("no GitHub configured") }
        let client = GitHubClient(host: "github.com", token: token)
        let repo = try slug("github.com", full)

        let me = try await client.currentUser()
        XCTAssertFalse(me.login.isEmpty)
        let version = try await client.version()
        XCTAssertEqual(version, "github.com")
        let repos = try await client.repositories(org: repo.owner)
        let found = try XCTUnwrap(repos.first { $0.name == repo.name }, "\(full) is listed under its owner")
        XCTAssertNotNil(found.cloneURL)
        XCTAssertNotNil(found.defaultBranch)

        // Pull requests, newest merged one in detail.
        let closed = try await client.pullRequests(repo, state: "closed", limit: 10)
        let merged = try XCTUnwrap(closed.first { $0.merged == true }, "a merged pull request")
        XCTAssertEqual(merged.phase, .merged, "merged_at tells a merged pull request in a listing")
        let detail = try await client.pullRequest(repo, number: merged.number)
        XCTAssertEqual(detail.merged, true)
        XCTAssertFalse(detail.head.sha.isEmpty)
        let files = try await client.pullFiles(repo, pull: merged.number)
        XCTAssertFalse(files.isEmpty)
        let commits = try await client.pullCommits(repo, pull: merged.number)
        XCTAssertFalse(commits.isEmpty)
        let diff = try await client.pullDiff(repo, number: merged.number)
        XCTAssertTrue(diff.hasPrefix("diff --git"), String(diff.prefix(80)))
        _ = try await client.reviews(repo, pull: merged.number)
        _ = try await client.comments(repo, number: merged.number)

        // Checks: GitHub Actions reports check runs, each naming its job.
        let status = try await client.combinedStatus(repo, ref: detail.head.sha)
        let check = try XCTUnwrap(status.checks.first { $0.jobID != nil }, "an Actions check on the head commit: \(status.checks.map(\.context))")
        XCTAssertNotNil(check.runID)
        XCTAssertNotEqual(check.state, .unknown)

        // Runs, jobs with steps, a finished job's log.
        let runs = try await client.runs(repo, limit: 5)
        let run = try XCTUnwrap(runs.first { $0.state.isFinished }, "a finished run")
        XCTAssertNotNil(run.workflowID)
        XCTAssertTrue(run.workflowID?.hasSuffix(".yml") == true || run.workflowID?.hasSuffix(".yaml") == true, run.workflowID ?? "")
        XCTAssertNotNil(run.started)
        let jobs = try await client.jobs(repo, run: run.id)
        let job = try XCTUnwrap(jobs.first, "the run has jobs")
        XCTAssertTrue(job.hasStarted)
        XCTAssertFalse(job.steps?.isEmpty ?? true, "GitHub sends the steps with the job")
        let log = try await client.jobLog(repo, job: job.id, from: 0)
        XCTAssertGreaterThan(log?.count ?? 0, 100, "a finished job's log")
        let tail = try await client.jobLog(repo, job: job.id, from: max(0, (log?.count ?? 0) - 10))
        XCTAssertEqual(tail?.count, 10, "a log read from an offset holds only what is after it")
        let byBranch = try await client.runs(repo, limit: 3, branch: found.defaultBranch ?? "main")
        XCTAssertTrue(byBranch.allSatisfy { $0.prettyRef == (found.defaultBranch ?? "main") })

        let workflows = try await client.workflowFiles(repo)
        XCTAssertFalse(workflows.isEmpty)
        let text = try await client.fileText(repo, path: try XCTUnwrap(workflows.first).path)
        XCTAssertTrue(text.contains("jobs:"))
        let releases = try await client.releases(repo)
        XCTAssertFalse(releases.isEmpty)
        let branch = try await client.branch(repo, name: found.defaultBranch ?? "main")
        XCTAssertEqual(branch.name, found.defaultBranch ?? "main")
        _ = try await client.myPullRequests()
        _ = try await client.reviewRequests()
        let compared = try await client.compare(repo, base: "v0.1.2", head: "v0.1.3")
        XCTAssertFalse(compared.isEmpty)

        let checks = await client.permissions()
        XCTAssertEqual(checks.count, 8)
        XCTAssertEqual(checks.first?.answer, .yes)
    }

    func testGitHubMapsStatesAndURLs() {
        XCTAssertEqual(GitHubClient.state("completed", "success"), "success")
        XCTAssertEqual(GitHubClient.state("completed", "timed_out"), "failure")
        XCTAssertEqual(GitHubClient.state("in_progress", nil), "running")
        XCTAssertEqual(GitHubClient.state("queued", nil), "waiting")
        XCTAssertEqual(CheckState(forge: GitHubClient.state("completed", "cancelled")), .cancelled)
        XCTAssertEqual(GitHubClient.runID(in: "https://github.com/o/r/actions/runs/123/job/456"), 123)
        let client = GitHubClient(host: "github.com", token: nil)
        XCTAssertEqual(client.webURL("https://api.github.com/repos/o/r/pulls/5"), "https://github.com/o/r/pull/5")
        XCTAssertEqual(ForgeKind.guess(host: "github.com"), .github)
        XCTAssertEqual(ForgeKind.github.gitUser(login: "me"), "x-access-token")
        XCTAssertEqual(ForgeKind.gitlab.gitUser(login: "me"), "oauth2")
        XCTAssertEqual(ForgeKind.forgejo.gitUser(login: "me"), "me")
    }

    func testGitLabTranslatesMergeRequestsAndPipelines() throws {
        let pull = try GitLabClient.pull([
            "iid": 7, "title": "Draft: things", "state": "merged", "draft": true, "web_url": "https://gl/x/-/merge_requests/7",
            "source_branch": "feat/x", "target_branch": "main", "sha": "abc", "diff_refs": ["base_sha": "def", "head_sha": "abc"],
            "author": ["id": 3, "username": "ann", "name": "Ann Lee"], "reviewers": [["id": 4, "username": "bo", "name": "Bo"]],
            "labels": ["backend"], "changes_count": "12+", "user_notes_count": 2, "detailed_merge_status": "mergeable",
            "created_at": "2026-11-10T08:00:00.000Z", "merged_at": "2026-11-11T08:00:00.000Z",
        ])
        XCTAssertEqual(pull.number, 7)
        XCTAssertEqual(pull.phase, .merged)
        XCTAssertEqual(pull.head.ref, "feat/x")
        XCTAssertEqual(pull.base.sha, "def")
        XCTAssertEqual(pull.user?.displayName, "Ann Lee")
        XCTAssertEqual(pull.requestedReviewers?.first?.login, "bo")
        XCTAssertEqual(pull.changedFiles, 12)
        XCTAssertEqual(pull.labels?.first?.name, "backend")
        XCTAssertNotNil(pull.createdAt)

        let run = try GitLabClient.run(["id": 55, "iid": 9, "status": "failed", "source": "merge_request_event", "ref": "refs/merge-requests/7/head",
                                         "sha": "abc", "web_url": "https://gl/x/-/pipelines/55", "created_at": "2026-11-10T08:00:00Z", "finished_at": "2026-11-10T08:05:00Z"])
        XCTAssertEqual(run.state, .failure)
        XCTAssertEqual(run.trigger, "pull_request")
        XCTAssertEqual(run.number, 9)
        XCTAssertEqual(run.workflowID, ".gitlab-ci.yml")
        XCTAssertNotNil(run.stopped)
        XCTAssertEqual(CheckState(forge: GitLabClient.state("manual")), .waiting)
        XCTAssertEqual(CheckState(forge: GitLabClient.state("canceled")), .cancelled)
        let job = try GitLabClient.job(["id": 81, "name": "plan", "stage": "test", "status": "running", "started_at": "2026-11-10T08:01:00Z", "pipeline": ["id": 55]])
        XCTAssertEqual(job.name, "test: plan")
        XCTAssertEqual(job.runID, 55)
        XCTAssertTrue(job.hasStarted)
        XCTAssertEqual(GitLabClient.escape("group/sub/name"), "group%2Fsub%2Fname")
        let repo = try XCTUnwrap(GitLabClient.repo(["id": 1, "path": "infra", "path_with_namespace": "ops/aws/infra", "namespace": ["id": 2, "full_path": "ops/aws"],
                                                   "default_branch": "main", "http_url_to_repo": "https://gl/ops/aws/infra.git", "visibility": "private"]))
        XCTAssertEqual(repo.owner.login, "ops/aws", "a subgroup is the owner")
        XCTAssertEqual(repo.isPrivate, true)
        XCTAssertEqual(AppModel.slug(host: "gl", fullName: "ops/aws/infra")?.owner, "ops/aws")
        XCTAssertEqual(AppModel.slug(host: "gl", fullName: "ops/aws/infra")?.name, "infra")
        XCTAssertNil(AppModel.slug(host: "gl", fullName: "infra"))
        XCTAssertEqual(RestAPI.message(Data(#"{"message":{"source_branch":["is invalid"]}}"#.utf8)), "source_branch is invalid")
    }

    // MARK: GitLab

    func testGitLabReadsAndWritesLikeTheApp() async throws {
        guard let host = env["GNV_GITLAB_HOST"], let token = env["GNV_GITLAB_TOKEN"], let full = env["GNV_GITLAB_REPO"] else { throw XCTSkip("no GitLab configured") }
        let client = GitLabClient(host: host, token: token)
        let repo = try slug(host, full)

        let me = try await client.currentUser()
        XCTAssertFalse(me.login.isEmpty)
        let version = try await client.version()
        XCTAssertTrue(version.hasPrefix("GitLab "), version)
        let groups = try await client.organizations()
        let top = String(full.split(separator: "/").first ?? "")
        XCTAssertTrue(groups.contains { $0.login == top }, "\(top) is a workspace: \(groups.map(\.login))")
        let repos = try await client.repositories(org: top)
        let found = try XCTUnwrap(repos.first { $0.fullName == full }, "\(full) in \(repos.map(\.fullName))")
        let main = found.defaultBranch ?? "main"
        let branches = try await client.branches(repo)
        XCTAssertTrue(branches.contains(main))

        // A branch of its own for this run, from the default branch.
        let branch = "gnv-test-\(Int(Date().timeIntervalSince1970))"
        try await client.api.send("POST", "projects/\(GitLabClient.escape(full))/repository/branches", query: [.init(name: "branch", value: branch), .init(name: "ref", value: main)])
        try await client.api.send("POST", "projects/\(GitLabClient.escape(full))/repository/files/\(GitLabClient.escape("notes/\(branch).txt"))",
                                  json: ["branch": branch, "content": "from the test\n", "commit_message": "Add a note for \(branch)"])
        let commits = try await client.compare(repo, base: main, head: branch)
        XCTAssertEqual(commits.count, 1)

        let pull = try await client.createPull(repo, head: branch, base: main, title: "Test \(branch)", body: "Opened by GitNest View's tests.")
        XCTAssertEqual(pull.state, "open")
        XCTAssertEqual(pull.head.ref, branch)
        let listed = try await client.pullRequests(repo, state: "open", limit: 20)
        XCTAssertTrue(listed.contains { $0.number == pull.number })

        // The conversation and the diff.
        try await client.comment(repo, number: pull.number, body: "A comment from the test")
        let talk = try await client.comments(repo, number: pull.number)
        XCTAssertTrue(talk.contains { $0.body == "A comment from the test" })
        // GitLab works out a new merge request's diff in the background.
        var files = try await client.pullFiles(repo, pull: pull.number)
        for _ in 0..<20 where files.isEmpty {
            try await Task.sleep(for: .seconds(1))
            files = try await client.pullFiles(repo, pull: pull.number)
        }
        XCTAssertEqual(files.first?.filename, "notes/\(branch).txt")
        XCTAssertEqual(files.first?.status, "added")
        XCTAssertEqual(files.first?.additions, 1)
        let diff = try await client.pullDiff(repo, number: pull.number)
        XCTAssertTrue(diff.contains("+++ b/notes/\(branch).txt"), diff)
        var pullCommits = try await client.pullCommits(repo, pull: pull.number)
        for _ in 0..<10 where pullCommits.isEmpty {
            try await Task.sleep(for: .seconds(1))
            pullCommits = try await client.pullCommits(repo, pull: pull.number)
        }
        XCTAssertEqual(pullCommits.first?.subject, "Add a note for \(branch)")

        // Labels, title, approval.
        let label = "gnv-test"
        _ = try? await client.api.send("POST", "projects/\(GitLabClient.escape(full))/labels", json: ["name": label, "color": "#5843AD"])
        let labels = try await client.labels(repo)
        let id = try XCTUnwrap(labels.first { $0.name == label }?.id)
        try await client.setLabels(repo, number: pull.number, ids: [id])
        try await client.editPull(repo, number: pull.number, title: "Test \(branch) (renamed)")
        let fresh = try await client.pullRequest(repo, number: pull.number)
        XCTAssertEqual(fresh.labels?.map(\.name), [label])
        XCTAssertEqual(fresh.title, "Test \(branch) (renamed)")
        try await client.submitReview(repo, number: pull.number, event: "APPROVED", body: "", commit: fresh.head.sha)
        let reviews = try await client.reviews(repo, pull: pull.number)
        XCTAssertTrue(reviews.contains { $0.state == "APPROVED" && $0.user?.login == me.login }, "\(reviews)")
        let summary = ReviewSummary(reviews: reviews, requested: fresh.requestedReviewers ?? [])
        XCTAssertEqual(summary.approvals, 1)

        // Pipelines: the branch's own, with its job; a lab runner takes it.
        let runs = try await client.runs(repo, limit: 10, branch: branch)
        let run = try XCTUnwrap(runs.first, "the push started a pipeline")
        XCTAssertEqual(run.workflowID, ".gitlab-ci.yml")
        XCTAssertEqual(run.trigger, "push")
        let jobs = try await client.jobs(repo, run: run.id)
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.runID, run.id)
        let status = try await client.combinedStatus(repo, ref: fresh.head.sha)
        let check = try XCTUnwrap(status.checks.first { $0.jobID != nil }, "\(status.checks)")
        XCTAssertEqual(check.runID, run.id)
        XCTAssertTrue(check.targetURL?.contains("/-/jobs/") == true)
        var finished = try await client.job(repo, id: job.id)
        for _ in 0..<40 where !finished.state.isFinished {
            try await Task.sleep(for: .seconds(2))
            finished = try await client.job(repo, id: job.id)
        }
        if finished.state == .success {
            let read = try await client.jobLog(repo, job: job.id, from: 0)
            let log = try XCTUnwrap(read)
            let text = String(decoding: log, as: UTF8.self)
            XCTAssertTrue(text.contains("Plan: 1 to add"), text)
            var tail = LogTail()
            let lines = tail.append(log) + tail.flush()
            XCTAssertTrue(lines.contains { $0.text.hasPrefix("Plan: 1 to add") }, "the log reads clean: \(lines.map(\.text).prefix(12))")
            XCTAssertNotNil(TerraformPlan.parse(lines), "the plan line is found as in a Forgejo log")
            let rest = try await client.jobLog(repo, job: job.id, from: log.count - 20)
            XCTAssertEqual(rest?.count, 20)
            try await client.rerun(repo, job: job.id)
            let again = try await client.runs(repo, limit: 10, branch: branch)
            XCTAssertFalse(again.isEmpty)
        }
        let workflows = try await client.workflowFiles(repo)
        XCTAssertEqual(workflows.map(\.name), [".gitlab-ci.yml"])

        // Inbox and the token.
        let mine = try await client.myPullRequests()
        XCTAssertTrue(mine.contains { $0.number == pull.number && $0.repository?.fullName == full }, "\(mine.map { "\($0.repository?.fullName ?? "") !\($0.number)" })")
        let open = try await client.openPullRequests(owner: top)
        XCTAssertTrue(open.contains { $0.number == pull.number })
        _ = try await client.notifications()
        let checks = await client.permissions()
        XCTAssertTrue(checks.allSatisfy { $0.answer == .yes }, "\(checks.filter { $0.answer != .yes }.map(\.feature))")

        // Merge with the branch removed, as the app's Merge button does.
        try await client.merge(repo, number: pull.number, style: "squash", deleteBranch: true, head: fresh.head.sha, title: "Test \(branch)")
        var merged = try await client.pullRequest(repo, number: pull.number)
        for _ in 0..<10 where merged.merged != true {
            try await Task.sleep(for: .seconds(1))
            merged = try await client.pullRequest(repo, number: pull.number)
        }
        XCTAssertEqual(merged.phase, .merged)
    }

    /// The app's own path: connect finds out the kind, the workspaces and
    /// repositories load, the token goes to git as GitLab wants it.
    func testConnectFindsOutGitLab() async throws {
        guard let host = env["GNV_GITLAB_HOST"], let token = env["GNV_GITLAB_TOKEN"] else { throw XCTSkip("no GitLab configured") }
        let suite = "gnv-gitlab-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        let kind = try await model.detectKind(host: host)
        XCTAssertEqual(kind, .gitlab)
        try await model.connect(host: host, token: token)
        let account = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(account.forgeKind, .gitlab)
        XCTAssertTrue(model.client(for: host) is GitLabClient)
        XCTAssertEqual(model.auth(host: host, forURL: "https://\(host)/g/p.git")?.user, "oauth2")
        await model.loadWorkspaces()
        XCTAssertFalse(model.workspaces.isEmpty)
    }

    func testForgejoIsFoundOutToo() async throws {
        guard let host = env["GNV_HOST"] else { throw XCTSkip("no Forgejo configured") }
        let model = AppModel(tokens: MemoryTokenStore(), defaults: try XCTUnwrap(UserDefaults(suiteName: "gnv-kind-\(UUID().uuidString)")))
        let kind = try await model.detectKind(host: ForgeAccount.normalize(host))
        XCTAssertEqual(kind, .forgejo)
    }
}
