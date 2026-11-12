import XCTest
@testable import GitNestView

final class TerraformPlanTests: XCTestCase {
    private func lines(_ text: String) -> [LogLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { LogTail.parse(String($0)) }
    }

    func testPlan() throws {
        let plan = try XCTUnwrap(TerraformPlan.parse(lines("""
        2026-11-10T18:33:15.1Z OpenTofu will perform the following actions:
        2026-11-10T18:33:15.2Z   # module.cloud_dns["private-a"].google_dns_record_set.this["k8s"] will be created
        2026-11-10T18:33:15.2Z   + resource "google_dns_record_set" "this" {
        2026-11-10T18:33:15.3Z   # google_compute_firewall.allow will be updated in-place
        2026-11-10T18:33:15.3Z   # google_compute_instance.vm must be replaced
        2026-11-10T18:33:15.3Z   # google_storage_bucket.old will be destroyed
        2026-11-10T18:33:15.3Z   # (because google_storage_bucket.old is not in configuration)
        2026-11-10T18:33:15.4Z \u{1B}[1mPlan:\u{1B}[0m 2 to add, 1 to change, 2 to destroy.
        """)))
        XCTAssertEqual([plan.add, plan.change, plan.destroy], [2, 1, 2])
        XCTAssertFalse(plan.applied)
        XCTAssertEqual(plan.changes.map(\.action), [.create, .update, .replace, .destroy])
        XCTAssertEqual(plan.changes.first?.address, #"module.cloud_dns["private-a"].google_dns_record_set.this["k8s"]"#)
    }

    func testApplyWinsOverTheEarlierPlan() throws {
        let plan = try XCTUnwrap(TerraformPlan.parse(lines("""
        # a.b will be created
        Plan: 1 to add, 0 to change, 0 to destroy.
        a.b: Creating...
        Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
        """)))
        XCTAssertTrue(plan.applied)
        XCTAssertEqual(plan.add, 1)
        XCTAssertEqual(plan.changes.count, 1)
    }

    func testNoChangesAndNoTerraform() throws {
        let none = try XCTUnwrap(TerraformPlan.parse(lines("No changes. Your infrastructure matches the configuration.")))
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(TerraformPlan.parse(lines("line 1\nPlan: maybe later\n# a comment will be created by someone")))
    }

    func testRepoNamePrefixes() {
        let names = ["org-core-dns", "org-core-firewalls", "gco-cmt-prod", "org-baas-client-onboarding", "single", "two-words"]
        let prefixes = RepoName.sharedPrefixes(names)
        XCTAssertEqual(prefixes, ["org-core-"])
        XCTAssertTrue(RepoName.split("org-core-dns", prefixes: prefixes) == ("org-core-", "dns"))
        XCTAssertTrue(RepoName.split("gco-cmt-prod", prefixes: prefixes) == ("", "gco-cmt-prod"))
        XCTAssertTrue(RepoName.split("single", prefixes: prefixes) == ("", "single"))
    }

    func testRepositoryAndSearchDecoding() throws {
        let repos = try ForgejoClient.decoder.decode([ForgeRepo].self, from: Data("""
        [{"id":2,"name":"gnv-ci-test","full_name":"claude/gnv-ci-test","owner":{"id":3,"login":"claude"},
          "description":"","empty":false,"private":false,"fork":false,"mirror":false,"archived":false,
          "html_url":"https://forge.example/claude/gnv-ci-test","ssh_url":"ssh://git@forge.example/claude/gnv-ci-test.git",
          "clone_url":"https://forge.example/claude/gnv-ci-test.git","open_pr_counter":1,"default_branch":"main",
          "updated_at":"2026-11-10T18:36:33Z","archived_at":"1970-01-01T00:00:00Z","has_actions":true}]
        """.utf8))
        XCTAssertEqual(repos.first?.openPulls, 1)
        XCTAssertEqual(repos.first?.owner.login, "claude")

        let hits = try ForgejoClient.decoder.decode([PullSearchHit].self, from: Data("""
        [{"id":1,"number":1,"title":"Add notes","html_url":"https://forge.example/claude/gnv-ci-test/pulls/1","state":"open",
          "updated_at":"2026-11-10T18:36:34Z","pull_request":{"merged":false,"merged_at":null,"draft":false},
          "repository":{"id":2,"name":"gnv-ci-test","full_name":"claude/gnv-ci-test"},"user":{"id":3,"login":"claude"}}]
        """.utf8))
        XCTAssertEqual(hits.first?.repository?.fullName, "claude/gnv-ci-test")

        let commits = try ForgejoClient.decoder.decode([PullCommit].self, from: Data("""
        [{"sha":"8571dd0b","created":"2026-11-10T18:36:32Z","commit":{"message":"Add notes\\n\\nBody.","author":{"name":"claude","email":"c@example.com","date":"2026-11-10T18:36:32Z"}},"author":null}]
        """.utf8))
        XCTAssertEqual(commits.first?.subject, "Add notes")
        XCTAssertEqual(RepoSlug(host: "Forge.Example", owner: "Ann", name: "Repo").key, "forge.example/ann/repo")
    }
}

final class TerraformLogTests: XCTestCase {
    private func lines(_ text: String) -> [LogLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { LogTail.parse(String($0)) }
    }

    private let plan = """
    2026-11-10T18:33:14.1Z Initializing the backend...
    2026-11-10T18:33:15.1Z OpenTofu will perform the following actions:
    2026-11-10T18:33:15.1Z
    2026-11-10T18:33:15.2Z   # module.firewall_policy["fw-policy-cmt-spokeprod"].google_compute_network_firewall_policy_rule.rules["12023"] will be created
    2026-11-10T18:33:15.2Z   + resource "google_compute_network_firewall_policy_rule" "rules" {
    2026-11-10T18:33:15.2Z       + action             = "allow"
    2026-11-10T18:33:15.2Z       + priority           = 12023
    2026-11-10T18:33:15.2Z       + match {
    2026-11-10T18:33:15.2Z           + dest_ip_ranges            = [
    2026-11-10T18:33:15.2Z               + "34.0.248.210/32",
    2026-11-10T18:33:15.2Z             ]
    2026-11-10T18:33:15.2Z           + layer4_configs {
    2026-11-10T18:33:15.2Z               + ip_protocol = "tcp"
    2026-11-10T18:33:15.2Z             }
    2026-11-10T18:33:15.2Z         }
    2026-11-10T18:33:15.2Z     }
    2026-11-10T18:33:15.2Z
    2026-11-10T18:33:15.3Z   # google_storage_bucket.old will be destroyed
    2026-11-10T18:33:15.3Z   # (because google_storage_bucket.old is not in configuration)
    2026-11-10T18:33:15.3Z   - resource "google_storage_bucket" "old" {
    2026-11-10T18:33:15.3Z       - labels = {
    2026-11-10T18:33:15.3Z           - "team" = "core"
    2026-11-10T18:33:15.3Z         } -> null
    2026-11-10T18:33:15.3Z       - name   = "old" -> null
    2026-11-10T18:33:15.3Z     }
    2026-11-10T18:33:15.3Z
    2026-11-10T18:33:15.4Z Plan: 1 to add, 0 to change, 1 to destroy.
    """

    func testCondenseKeepsOneLinePerResource() {
        let all = lines(plan)
        XCTAssertTrue(TerraformLog.hasResources(all))
        let short = TerraformLog.condense(all)
        XCTAssertEqual(short.map(\.text), [
            "Initializing the backend...",
            "OpenTofu will perform the following actions:",
            "",
            #"+ create  module.firewall_policy["fw-policy-cmt-spokeprod"].google_compute_network_firewall_policy_rule.rules["12023"]"#,
            "- destroy  google_storage_bucket.old",
            "Plan: 1 to add, 0 to change, 1 to destroy.",
        ])
        XCTAssertEqual(short[3].action, .create)
        XCTAssertEqual(short[3].time, "18:33:15")
        XCTAssertNil(short[0].action)
    }

    /// While a log is followed, the shortened text only ever grows: what was
    /// shown for a prefix of the log is a prefix of what is shown later.
    func testCondenseIsStableWhileTheLogGrows() {
        let all = lines(plan)
        var previous: [LogLine] = []
        for count in 0...all.count {
            let short = TerraformLog.condense(Array(all[..<count]))
            XCTAssertEqual(Array(short.prefix(previous.count)), previous, "after \(count) lines")
            previous = short
        }
    }

    func testCutOutputStillShowsTheResult() {
        let cut = lines("""
          # a.b will be created
          + resource "a" "b" {
              + x = 1
        Error: something failed
        after
        """)
        XCTAssertEqual(TerraformLog.condense(cut).map(\.text), ["+ create  a.b", "Error: something failed", "after"])
        XCTAssertFalse(TerraformLog.hasResources(lines("line 1\n# just a comment\nPlan: nothing")))
        XCTAssertEqual(TerraformLog.condense(lines("# a.b will be created\nnot a block")).map(\.text), ["+ create  a.b", "not a block"])
    }
}

final class TerraformErrorTests: XCTestCase {
    func testExtractsTheErrorBox() {
        let raw = """
        2026-11-10T21:06:45.1Z Initializing...
        2026-11-10T21:06:45.2Z \u{1B}[31m╷\u{1B}[0m
        2026-11-10T21:06:45.2Z \u{1B}[31m│\u{1B}[0m \u{1B}[1m\u{1B}[31mError: \u{1B}[0m\u{1B}[0m\u{1B}[1mInvalid reference\u{1B}[0m
        2026-11-10T21:06:45.2Z \u{1B}[31m│\u{1B}[0m
        2026-11-10T21:06:45.2Z \u{1B}[31m│\u{1B}[0m   on main.tf line 12, in module "iam":
        2026-11-10T21:06:45.2Z \u{1B}[31m╵\u{1B}[0m
        2026-11-10T21:06:45.3Z ❌  Failure - Main Plan
        """
        let lines = raw.split(separator: "\n").map { LogTail.parse(String($0)) }
        XCTAssertEqual(TerraformError.extract(lines), ["Error: Invalid reference", "", "on main.tf line 12, in module \"iam\":"])
        XCTAssertEqual(TerraformError.extract([LogTail.parse("Error: something broke")]), ["Error: something broke"])
        XCTAssertEqual(TerraformError.extract([LogTail.parse("all fine")]), [])
    }

    func testCheckNames() {
        let name = CheckName("Terraform pipeline / Terraform single state (org-core-iam) (pull_request)")
        XCTAssertEqual(name.job, "Terraform single state (org-core-iam)")
        XCTAssertEqual(name.workflow, "Terraform pipeline")
        XCTAssertEqual(CheckName("external").job, "external")
    }
}
