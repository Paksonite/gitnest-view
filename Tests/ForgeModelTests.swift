import XCTest
@testable import GitNestView

/// Decoding and the rules built on it, against answers shaped like the ones
/// Forgejo 17 gives (trimmed).
final class ForgeModelTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String, as _: T.Type = T.self) throws -> T {
        try ForgejoClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func user(_ id: Int, _ login: String) -> String {
        #"{"id":\#(id),"login":"\#(login)","full_name":"","avatar_url":"https://forge.example/avatars/\#(id)"}"#
    }

    func testPullRequest() throws {
        let pulls: [PullRequest] = try decode("""
        [{"id":1,"number":1,"user":\(user(3, "ann")),"title":"Add notes","body":"Text.","labels":[],
          "milestone":null,"assignee":null,"assignees":null,"requested_reviewers":[\(user(1, "bob"))],
          "state":"open","draft":false,"comments":0,"additions":1,"deletions":0,"changed_files":1,
          "html_url":"https://forge.example/ann/repo/pulls/1","mergeable":true,"merged":false,"merged_at":null,
          "base":{"label":"main","ref":"main","sha":"bbd2c62c","repo_id":2},
          "head":{"label":"feat/notes","ref":"feat/notes","sha":"8571dd0b","repo_id":2},
          "created_at":"2026-11-10T18:36:33Z","updated_at":"2026-11-10T18:36:34.123456Z","closed_at":null}]
        """)
        let pull = try XCTUnwrap(pulls.first)
        XCTAssertEqual(pull.phase, .open)
        XCTAssertEqual(pull.head.ref, "feat/notes")
        XCTAssertEqual(pull.requestedReviewers?.map(\.login), ["bob"])
        XCTAssertNotNil(pull.createdAt)
        XCTAssertNotNil(pull.updatedAt, "dates with fractional seconds must decode too")
        XCTAssertNil(pull.mergedAt)
    }

    func testPullRequestPhases() throws {
        func pull(state: String, merged: Bool, draft: Bool) throws -> PullRequest {
            try decode("""
            {"number":2,"title":"t","state":"\(state)","merged":\(merged),"draft":\(draft),"html_url":"u",
             "base":{"ref":"main","sha":"a"},"head":{"ref":"x","sha":"b"}}
            """)
        }
        XCTAssertEqual(try pull(state: "open", merged: false, draft: true).phase, .draft)
        XCTAssertEqual(try pull(state: "closed", merged: true, draft: false).phase, .merged)
        XCTAssertEqual(try pull(state: "closed", merged: false, draft: false).phase, .closed)
    }

    func testReviewSummary() throws {
        let reviews: [Review] = try decode("""
        [{"id":1,"user":\(user(1, "bob")),"state":"APPROVED","stale":false,"dismissed":false,"submitted_at":"2026-11-10T10:00:00Z"},
         {"id":2,"user":\(user(1, "bob")),"state":"COMMENT","stale":false,"dismissed":false,"submitted_at":"2026-11-10T11:00:00Z"},
         {"id":3,"user":\(user(2, "eve")),"state":"APPROVED","stale":false,"dismissed":false,"submitted_at":"2026-11-10T10:00:00Z"},
         {"id":4,"user":\(user(2, "eve")),"state":"REQUEST_CHANGES","stale":false,"dismissed":false,"submitted_at":"2026-11-10T12:00:00Z"},
         {"id":5,"user":\(user(4, "dan")),"state":"APPROVED","stale":false,"dismissed":true,"submitted_at":"2026-11-10T10:00:00Z"},
         {"id":6,"user":\(user(5, "old")),"state":"APPROVED","stale":true,"dismissed":false,"submitted_at":"2026-11-10T10:00:00Z"},
         {"id":7,"user":\(user(6, "kim")),"state":"COMMENT","stale":false,"dismissed":false,"submitted_at":"2026-11-10T10:00:00Z"},
         {"id":8,"user":\(user(7, "zed")),"state":"REQUEST_REVIEW","stale":false,"dismissed":false,"submitted_at":"2026-11-10T10:00:00Z"}]
        """)
        let requested: [ForgeUser] = try decode("[\(user(7, "zed")),\(user(5, "old"))]")
        let summary = ReviewSummary(reviews: reviews, requested: requested)
        let kinds = Dictionary(uniqueKeysWithValues: summary.verdicts.map { ($0.user.login, $0.kind) })

        XCTAssertEqual(kinds["bob"], .approved, "a later comment does not take an approval back")
        XCTAssertEqual(kinds["eve"], .changesRequested, "the latest verdict wins")
        XCTAssertNil(kinds["dan"], "dismissed reviews do not count")

        // Asked again (a REQUEST_REVIEW after the verdict): waiting again.
        let again: [Review] = try decode("""
        [{"id":1,"user":\(user(1, "bob")),"state":"APPROVED","submitted_at":"2026-11-10T10:00:00Z"},
         {"id":2,"user":\(user(1, "bob")),"state":"REQUEST_REVIEW","submitted_at":"2026-11-10T11:00:00Z"}]
        """)
        XCTAssertEqual(ReviewSummary(reviews: again, requested: []).verdicts.first?.kind, .requested)
        XCTAssertEqual(kinds["kim"], .commented)
        XCTAssertEqual(kinds["zed"], .requested)
        XCTAssertEqual(kinds["old"], .approved, "still listed as requested by Forgejo after approving: the approval counts")
        XCTAssertEqual(summary.approvals, 1, "the outdated approval does not count")
        XCTAssertEqual(summary.changesRequested, 1)
        XCTAssertEqual(summary.waiting, 1)
    }

    func testCombinedStatusAndJobReference() throws {
        let status: CombinedStatus = try decode("""
        {"state":"pending","sha":"8571dd0b","total_count":3,"statuses":[
          {"id":1,"status":"pending","target_url":"/ann/repo/actions/runs/4/jobs/0","description":"Has started running","context":"CI / build (pull_request)","creator":null},
          {"id":2,"status":"success","target_url":"https://forge.example/ann/repo/actions/runs/3/jobs/2","description":"Successful in 2m","context":"CI / lint (push)","creator":null},
          {"id":3,"status":"pending","target_url":"https://ci.example/build/9","description":"Waiting to run","context":"external","creator":null}],
         "commit_url":"","url":""}
        """)
        XCTAssertEqual(status.checks.map(\.state), [.running, .success, .waiting])
        XCTAssertEqual(status.overall, .running)
        XCTAssertEqual(status.checks[0].jobReference, JobReference(runPath: "/ann/repo/actions/runs/4", runNumber: 4, jobIndex: 0))
        XCTAssertEqual(status.checks[1].jobReference?.jobIndex, 2)
        XCTAssertNil(status.checks[2].jobReference, "a status from another CI has no Actions job")

        let failed: CombinedStatus = try decode(#"{"state":"failure","statuses":[{"id":1,"status":"failure","context":"a"},{"id":2,"status":"pending","context":"b"}]}"#)
        XCTAssertEqual(failed.overall, .failure)
        let none: CombinedStatus = try decode(#"{"state":"","statuses":null}"#)
        XCTAssertEqual(none.overall, .unknown)
    }

    func testRunsAndJobs() throws {
        let list: WorkflowRunList = try decode("""
        {"workflow_runs":[{"id":4,"title":"Add notes","workflow_id":"slow.yaml","index_in_repo":4,"trigger_user":\(user(3, "ann")),
          "prettyref":"#1","commit_sha":"8571dd0b","event":"pull_request","status":"running",
          "started":"2026-11-10T18:36:34Z","stopped":null,"created":"2026-11-10T18:36:33Z","duration":7000000000,
          "html_url":"https://forge.example/ann/repo/actions/runs/4"}],"total_count":1}
        """)
        let run = try XCTUnwrap(list.workflowRuns?.first)
        XCTAssertEqual(run.state, .running)
        XCTAssertEqual(run.number, 4)
        XCTAssertNil(run.stopped)

        let jobs: [WorkflowJob] = try decode("""
        [{"id":2,"run_id":2,"attempt":1,"name":"slow","html_url":"https://forge.example/ann/repo/actions/runs/2/jobs/0/attempt/1",
          "needs":null,"runs_on":["docker"],"task_id":0,"status":"waiting"}]
        """)
        XCTAssertEqual(jobs[0].state, .waiting)
        XCTAssertFalse(jobs[0].hasStarted)
        XCTAssertFalse(jobs[0].state.isFinished)
    }

    func testAccountHostNormalization() {
        XCTAssertEqual(ForgeAccount.normalize(" https://Forge.Example.com/ann/repo "), "forge.example.com")
        XCTAssertEqual(ForgeAccount.normalize("ssh://git@forge.example.com:2222/ann"), "forge.example.com:2222")
        XCTAssertEqual(ForgeAccount.normalize("forge.example.com"), "forge.example.com")
    }
}
