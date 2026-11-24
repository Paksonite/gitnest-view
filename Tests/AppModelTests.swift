import XCTest
@testable import GitNestView

@MainActor
final class AppModelTests: XCTestCase {
    private func model() throws -> AppModel {
        let suite = "gnv-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(tokens: MemoryTokenStore(), defaults: defaults)
    }

    private func job(_ id: Int, _ name: String, _ status: String, task: Int = 1) throws -> WorkflowJob {
        try ForgejoClient.decoder.decode(WorkflowJob.self, from: Data(#"{"id":\#(id),"name":"\#(name)","status":"\#(status)","task_id":\#(task)}"#.utf8))
    }

    private func run(_ id: Int, _ workflow: String, _ event: String) throws -> WorkflowRun {
        try ForgejoClient.decoder.decode(WorkflowRun.self, from: Data(#"{"id":\#(id),"title":"t","workflow_id":"\#(workflow)","event":"\#(event)","status":"success"}"#.utf8))
    }

    /// Drift detection runs on a schedule on the merge commit while the
    /// branch rests; it is not the pipeline the merge started.
    func testScheduledRunsAreNotTheMergePipeline() throws {
        let runs = [try run(52, "drift.yaml", "schedule"), try run(51, "drift.yaml", "schedule"),
                    try run(48, "terraform.yaml", "push"), try run(47, "terraform.yaml", "pull_request")]
        XCTAssertEqual(AppModel.mergeRuns(runs).map(\.id), [48])
        XCTAssertEqual(AppModel.scheduledRuns(runs).map(\.id), [52], "the newest of each workflow")
        // Only scheduled runs on the commit: nothing to show as "after merge".
        XCTAssertEqual(AppModel.mergeRuns(Array(runs.prefix(2))).map(\.id), [])
        // A dispatched run counts when there was no push pipeline.
        XCTAssertEqual(AppModel.mergeRuns([try run(60, "x.yaml", "workflow_dispatch"), runs[0]]).map(\.id), [60])
    }

    /// Forgejo 16 files a scheduled run under "push"; only trigger_event
    /// and ScheduleID tell. It must not pass for the merge pipeline.
    func testScheduledRunsOnForgejo16() throws {
        let json = """
        [{"id": 3, "title": "drift", "workflow_id": "drift-detection.yaml", "event": "push", "trigger_event": "schedule", "ScheduleID": 7, "status": "failure", "prettyref": "main"},
         {"id": 2, "title": "apply", "workflow_id": "terraform.yaml", "event": "push", "trigger_event": "push", "ScheduleID": 0, "status": "success", "prettyref": "main"},
         {"id": 1, "title": "manual", "workflow_id": "setup.yaml", "event": "", "trigger_event": "workflow_dispatch", "ScheduleID": 0, "status": "success", "prettyref": "main"}]
        """
        let runs = try JSONDecoder().decode([WorkflowRun].self, from: Data(json.utf8))
        XCTAssertEqual(runs.map(\.trigger), ["schedule", "push", "workflow_dispatch"])
        XCTAssertEqual(AppModel.scheduledRuns(runs).map(\.id), [3])
        XCTAssertEqual(AppModel.mergeRuns(runs).map(\.id), [2])
        XCTAssertEqual(AppModel.joined(Array(runs.prefix(2)), Array(runs.suffix(2))).map(\.id), [3, 2, 1])
    }

    func testFullNameBeforeLogin() throws {
        let named = try JSONDecoder().decode(ForgeUser.self, from: Data(#"{"id":1,"login":"jan.kowalski","full_name":"Jan Kowalski"}"#.utf8))
        let bare = try JSONDecoder().decode(ForgeUser.self, from: Data(#"{"id":2,"login":"bot","full_name":""}"#.utf8))
        XCTAssertEqual(named.displayName, "Jan Kowalski")
        XCTAssertEqual(bare.displayName, "bot")
    }

    func testTickets() {
        XCTAssertEqual(AppModel.tickets(in: [
            "chore: INFRA-50 update dns_record_sets\n\nRefs INFRA-50 and CMT-463.",
            "Merge pull request 'x' (#311) from develop",
            "fix: abc-12 is not a ticket, UTF-8 neither, but K8S-7 is",
        ]), ["INFRA-50", "CMT-463", "K8S-7"])
        XCTAssertEqual(AppModel.tickets(in: []), [])
    }

    func testPullTitleSkipsMergesAndPrefersTheBranchTicket() throws {
        func commit(_ sha: String, _ message: String, _ date: String, parents: Int = 1) throws -> PullCommit {
            let parentList = (0..<parents).map { #"{"sha":"p\#($0)"}"# }.joined(separator: ",")
            let json = #"{"sha":"\#(sha)","commit":{"message":"\#(message)","author":{"date":"\#(date)"}},"parents":[\#(parentList)]}"#
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PullCommit.self, from: Data(json.utf8))
        }
        let commits = [
            try commit("a", "Merge pull request 'develop' (#94) from develop into main", "2026-10-06T08:40:36Z", parents: 2),
            try commit("b", "Merge develop into main", "2026-11-06T08:53:57Z", parents: 2),
            try commit("c", "fix: hotfix on main", "2026-11-10T08:00:00Z"),
            try commit("d", "chore: MGCMT-530 add monitoring", "2026-11-24T11:30:21Z"),
            try commit("e", "chore: format tf files", "2026-11-24T11:30:51Z"),
        ]
        XCTAssertEqual(AppModel.pullTitle(commits, head: "chore/MGCMT-530"), "chore: MGCMT-530 add monitoring")
        XCTAssertEqual(AppModel.pullTitle(commits, head: "feature/no-ticket"), "fix: hotfix on main")
        XCTAssertEqual(AppModel.pullTitle(Array(commits.prefix(2)), head: "develop"), "develop")
        XCTAssertTrue(try commit("f", "Merge branch 'main' into x", "2026-11-24T11:30:51Z").isMerge)
    }

    func testNextVersionAndReleaseNotes() throws {
        XCTAssertEqual(AppModel.nextVersion(after: "v1.4.2"), "v1.4.3")
        XCTAssertEqual(AppModel.nextVersion(after: "2.0.9"), "2.0.10")
        XCTAssertEqual(AppModel.nextVersion(after: "v2.0.0-rc.1"), "v2.0.0")
        XCTAssertEqual(AppModel.nextVersion(after: "release-7"), "v0.1.0")
        XCTAssertEqual(AppModel.nextVersion(after: nil), "v0.1.0")
        let commits = try JSONDecoder().decode([PullCommit].self, from: Data(#"""
        [{"sha":"abcdef123","commit":{"message":"feat: MGCMT-1 add alerts\n\nbody"},"parents":[{"sha":"x"}]},
         {"sha":"0123456aa","commit":{"message":"Merge pull request 'develop' (#9)"},"parents":[{"sha":"x"},{"sha":"y"}]}]
        """#.utf8))
        XCTAssertEqual(AppModel.releaseNotes(commits), "- feat: MGCMT-1 add alerts (abcdef1)")
    }

    func testKeyJobsHideWhatPassed() throws {
        let model = try model()
        let jobs = [
            try job(1, "terraform", "success", task: 0),
            try job(2, "Terraform single state (org-core-dns)", "success"),
            try job(3, "lint", "success"),
            try job(4, "docs", "failure"),
            try job(5, "notify", "waiting", task: 0),
            try job(6, "Filter plan", "running"),
        ]
        let visible = model.visibleJobs(jobs)
        XCTAssertEqual(visible.shown.map(\.id), [2, 4, 6], "key jobs, and others only when they fail")
        XCTAssertEqual(visible.passed, 2)
        XCTAssertEqual(visible.other, 1)

        // A pipeline without key jobs (not Terraform) lists everything.
        let plain = [try job(1, "build", "success"), try job(2, "test", "success")]
        XCTAssertEqual(model.visibleJobs(plain).shown.count, 2)

        model.setKeyJobs([" build ", ""])
        XCTAssertEqual(model.keyJobs, ["build"])
        XCTAssertEqual(model.visibleJobs(plain).shown.map(\.id), [1])
    }

    func testJobStepsAndDuration() throws {
        let job = try ForgejoClient.decoder.decode(WorkflowJob.self, from: Data("""
        {"id":7,"run_id":7,"attempt":1,"name":"Terraform single state","task_id":7,"status":"success","steps":[
          {"number":0,"name":"Set up job","status":"success","started":"2026-11-10T21:06:44Z","stopped":"2026-11-10T21:06:45Z"},
          {"number":2,"name":"Plan","status":"success","started":"2026-11-10T21:06:54Z","stopped":"2026-11-10T21:09:59Z"},
          {"number":3,"name":"Later","status":"waiting","started":null,"stopped":null}]}
        """.utf8))
        XCTAssertEqual(job.steps?.map(\.duration), ["1s", "3m 05s", nil])
        XCTAssertEqual(job.steps?.last?.state, .waiting)
    }

    func testLogTones() {
        func tone(_ text: String) -> String {
            let (color, bold) = LogRenderer.tone(LogTail.parse(text))
            let name = [(NSColor(Theme.green), "green"), (NSColor(Theme.red), "red"), (NSColor(Theme.yellow), "yellow"),
                        (NSColor(Theme.tertiary), "faint")].first { $0.0 == color }?.1 ?? "other"
            return bold ? name + "+bold" : name
        }
        XCTAssertEqual(tone("      + action = \"allow\""), "green")
        XCTAssertEqual(tone("  - name = \"old\" -> null"), "red")
        XCTAssertEqual(tone("  ~ ttl = 300 -> 60"), "yellow")
        XCTAssertEqual(tone("Error: Invalid reference"), "red+bold")
        XCTAssertEqual(tone("Warning: Deprecated attribute"), "yellow+bold")
        XCTAssertEqual(tone("Apply complete! Resources: 1 added, 0 changed, 0 destroyed."), "green+bold")
        XCTAssertEqual(tone("  🐳  docker exec cmd=[sh]"), "faint")
        XCTAssertEqual(tone("google_dns_record_set.a: Creating..."), "green")
        XCTAssertEqual(tone("just a line"), "other")
    }
}
