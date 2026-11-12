import XCTest
@testable import GitNestView

final class PaletteAndAttentionTests: XCTestCase {
    @MainActor
    func testModuleSources() {
        XCTAssertTrue(AppModel.source("../terraform-modules//dns", refersTo: "terraform-modules"))
        XCTAssertTrue(AppModel.source("git::https://forge.example/Lab/terraform-modules.git//firewall?ref=v1", refersTo: "terraform-modules"))
        XCTAssertTrue(AppModel.source("git::ssh://git@forge/Lab/terraform-modules//x?ref=v2", refersTo: "terraform-modules"))
        XCTAssertFalse(AppModel.source("../terraform-modules-old//dns", refersTo: "terraform-modules"))
        XCTAssertFalse(AppModel.source("hashicorp/consul/aws", refersTo: "terraform-modules"))
        XCTAssertEqual(AppModel.ref(in: "git::https://h/o/m.git//x?ref=v1.2.0"), "v1.2.0")
        XCTAssertEqual(AppModel.ref(in: "git::https://h/o/m.git//x?depth=1&ref=main"), "main")
        XCTAssertNil(AppModel.ref(in: "../terraform-modules//dns"))
    }

    func testFuzzy() {
        XCTAssertNotNil(Fuzzy.score("fw", "org-core-firewalls"))
        XCTAssertNil(Fuzzy.score("xyz", "org-core-firewalls"))
        XCTAssertEqual(Fuzzy.score("", "anything"), 0)
        // A substring beats a scattered match; word starts beat the middle.
        let substring = Fuzzy.score("core", "org-core-dns")!
        let scattered = Fuzzy.score("ocd", "org-core-dns")!
        XCTAssertGreaterThan(substring, scattered)
        let starts = Fuzzy.score("ocd", "org-core-dns")!
        let middle = Fuzzy.score("ocd", "procedure")
        XCTAssertGreaterThan(starts, middle ?? Int.min)
        // Case does not matter.
        XCTAssertNotNil(Fuzzy.score("INFRA", "feat: infra-61 teleport"))
    }

    func testAttentionOrder() {
        let reasons: [AttentionReason] = [.changes(2), .behind(1), .reviewRequested(count: 1), .failedMain(workflow: "terraform"), .conflict("rebasing")]
        XCTAssertEqual(reasons.sorted().map(\.rank), [0, 1, 5, 8, 10])
        XCTAssertEqual(AttentionReason.behind(1).text, "1 commit to pull")
        XCTAssertEqual(AttentionReason.ahead(3).text, "3 commits to push")
        XCTAssertEqual(AttentionReason.conflict("").text, "conflicts to resolve")
    }

    /// A plan's addresses are matched to the blocks that declare them.
    func testPlanIsAttributedToFiles() throws {
        XCTAssertEqual(PlanAttribution.declaration(of: #"module.projects_iam["prj-x"].google_project_iam_member.this["roles/viewer"]"#), "module.projects_iam")
        XCTAssertEqual(PlanAttribution.declaration(of: "google_dns_record_set.a[0]"), "google_dns_record_set.a")
        XCTAssertEqual(PlanAttribution.declaration(of: #"data.google_project.p["a.b"]"#), "data.google_project.p")
        XCTAssertEqual(PlanAttribution.declaration(of: "module.a.module.b.google_x.y"), "module.a")

        func item(_ kind: String, _ type: String, _ name: String, _ file: String) throws -> TFItem {
            let address = kind == "module" ? "module.\(name)" : "\(type).\(name)"
            return try JSONDecoder().decode(TFItem.self, from: Data(#"{"kind":"\#(kind)","type":"\#(type)","name":"\#(name)","file":"\#(file)","line":1,"source":"","many":false,"address":"\#(address)"}"#.utf8))
        }
        let items = [try item("module", "", "projects_iam", "iam/checkmk.tf"), try item("resource", "google_dns_record_set", "a", "dns/main.tf"),
                     try item("resource", "google_dns_record_set", "a", "other/main.tf")]
        let plan = TerraformPlan(add: 2, change: 0, destroy: 1, changes: [
            .init(action: .create, address: #"module.projects_iam["x"].google_project_iam_member.this["v"]"#),
            .init(action: .destroy, address: "google_dns_record_set.a"),
            .init(action: .create, address: "google_storage_bucket.gone"),
        ])
        let found = PlanAttribution(plan: plan, items: items, changed: ["iam/checkmk.tf", "README.md"])
        XCTAssertEqual(found.byFile["iam/checkmk.tf"]?.map(\.action), [.create])
        XCTAssertEqual(found.elsewhere.map(\.file), ["dns/main.tf"], "declared in a file the pull request does not touch")
        XCTAssertEqual(found.unknown.map(\.address), ["google_storage_bucket.gone"])
        // The same address in two roots: the changed file wins.
        let other = PlanAttribution(plan: plan, items: items, changed: ["other/main.tf"])
        XCTAssertEqual(other.byFile["other/main.tf"]?.map(\.address), ["google_dns_record_set.a"])
    }

    func testCommitNamesItsPullRequest() throws {
        func commit(_ subject: String) -> BlockCommit { BlockCommit(sha: "a", short: "a", author: "x", when: "now", subject: subject) }
        XCTAssertEqual(commit("chore: MGCMT-475 add iam (#91)").pullNumber, 91)
        XCTAssertEqual(commit("Merge pull request 'chore/x' (#12) from chore/x into develop").pullNumber, 12)
        XCTAssertNil(commit("fix: no number here").pullNumber)
        XCTAssertNil(commit("fix (#abc)").pullNumber)
    }

    func testFileLetters() throws {
        func file(_ code: String, untracked: Bool = false, conflict: Bool = false) throws -> ChangedFile {
            try JSONDecoder().decode(ChangedFile.self, from: Data(#"{"path":"a","orig":"","staged":true,"unstaged":true,"untracked":\#(untracked),"conflict":\#(conflict),"code":"\#(code)"}"#.utf8))
        }
        XCTAssertEqual(try file("MD").letter(staged: true).0, "M")
        XCTAssertEqual(try file("MD").letter(staged: false).0, "D")
        XCTAssertEqual(try file("A ").letter(staged: true).0, "A")
        XCTAssertEqual(try file("R ").letter(staged: true).0, "R")
        XCTAssertEqual(try file("??", untracked: true).letter(staged: false).0, "U")
        XCTAssertEqual(try file("UU", conflict: true).letter(staged: false).0, "!")
    }
}
