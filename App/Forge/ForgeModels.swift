import Foundation

// What the app reads from Forgejo's REST API (v1). Only the fields the app
// shows are decoded; everything is optional-tolerant where Forgejo sends null.

struct ForgeUser: Codable, Hashable, Sendable {
    var id: Int
    var login: String
    var fullName: String?
    var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, login
        case fullName = "full_name"
        case avatarURL = "avatar_url"
    }

    var displayName: String { (fullName?.isEmpty == false ? fullName : nil) ?? login }
}

struct PullRequest: Decodable, Identifiable, Hashable, Sendable {
    struct Branch: Decodable, Hashable, Sendable {
        var ref: String
        var sha: String
        /// The branch's name as it was: Forgejo turns `ref` into
        /// "refs/pull/5/head" once the branch is deleted, `label` stays.
        var label: String?

        var name: String {
            guard ref.hasPrefix("refs/pull/"), let label, !label.isEmpty else { return ref }
            return label
        }
    }

    var number: Int
    var title: String
    var body: String?
    var state: String
    var draft: Bool?
    var merged: Bool?
    var mergeable: Bool?
    var user: ForgeUser?
    var requestedReviewers: [ForgeUser]?
    var assignees: [ForgeUser]?
    var htmlURL: String
    var base: Branch
    var head: Branch
    var comments: Int?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var createdAt: Date?
    var updatedAt: Date?
    var mergedAt: Date?
    var labels: [Label]?
    var mergeCommitSHA: String?

    struct Label: Decodable, Hashable, Sendable {
        var id: Int?
        var name: String
        var color: String?
    }

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, draft, merged, mergeable, user, base, head, comments, additions, deletions, labels, assignees
        case mergeCommitSHA = "merge_commit_sha"
        case requestedReviewers = "requested_reviewers"
        case htmlURL = "html_url"
        case changedFiles = "changed_files"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
    }

    var id: Int { number }

    enum Phase: Sendable { case open, draft, merged, closed }

    var phase: Phase {
        if merged == true { return .merged }
        if state != "open" { return .closed }
        return draft == true ? .draft : .open
    }
}

struct Review: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var user: ForgeUser?
    /// APPROVED, REQUEST_CHANGES, COMMENT, PENDING or REQUEST_REVIEW.
    var state: String
    var body: String?
    var stale: Bool?
    var dismissed: Bool?
    var official: Bool?
    var submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, user, state, body, stale, dismissed, official
        case submittedAt = "submitted_at"
    }
}

/// The verdict of one reviewer: their latest review that says something
/// about merging. Comments do not replace an earlier approval.
struct ReviewerVerdict: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case approved, changesRequested, commented, requested }
    var user: ForgeUser
    var kind: Kind
    var stale: Bool
    var id: Int { user.id }
}

struct ReviewSummary: Hashable, Sendable {
    var verdicts: [ReviewerVerdict]

    var approvals: Int { verdicts.count { $0.kind == .approved && !$0.stale } }
    var changesRequested: Int { verdicts.count { $0.kind == .changesRequested } }
    var waiting: Int { verdicts.count { $0.kind == .requested } }

    init(reviews: [Review], requested: [ForgeUser]) {
        var byUser: [Int: ReviewerVerdict] = [:]
        var order: [Int] = []
        let sorted = reviews.sorted { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }
        for review in sorted where review.dismissed != true {
            guard let user = review.user else { continue }
            let kind: ReviewerVerdict.Kind
            switch review.state {
            case "APPROVED": kind = .approved
            case "REQUEST_CHANGES": kind = .changesRequested
            case "COMMENT": kind = .commented
            // Forgejo records a review request as a review too: asked again
            // after a verdict, the reviewer is waiting once more.
            case "REQUEST_REVIEW": kind = .requested
            default: continue
            }
            if kind == .commented, let earlier = byUser[user.id], earlier.kind != .commented { continue }
            if byUser[user.id] == nil { order.append(user.id) }
            byUser[user.id] = ReviewerVerdict(user: user, kind: kind, stale: review.stale ?? false)
        }
        // Forgejo keeps reviewers in requested_reviewers after they answer, so
        // the list only adds people who have not reviewed at all.
        for user in requested where byUser[user.id] == nil {
            order.append(user.id)
            byUser[user.id] = ReviewerVerdict(user: user, kind: .requested, stale: false)
        }
        verdicts = order.compactMap { byUser[$0] }
    }
}

/// The states Forgejo uses for commit statuses and for Actions runs and jobs,
/// folded into what the app draws.
enum CheckState: String, Sendable {
    case success, failure, running, waiting, cancelled, skipped, unknown

    init(forge value: String) {
        switch value.lowercased() {
        case "success": self = .success
        case "failure", "error": self = .failure
        case "running": self = .running
        case "pending", "waiting", "blocked": self = .waiting
        case "cancelled", "canceled": self = .cancelled
        case "skipped": self = .skipped
        case "warning": self = .failure
        default: self = .unknown
        }
    }

    var isFinished: Bool {
        switch self {
        case .success, .failure, .cancelled, .skipped: true
        case .running, .waiting, .unknown: false
        }
    }
}

struct CommitStatus: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var status: String
    var context: String
    var description: String?
    var targetURL: String?

    enum CodingKeys: String, CodingKey {
        case id, status, context, description
        case targetURL = "target_url"
    }

    var state: CheckState {
        // A pending status whose job already runs says so only in its text.
        if status == "pending", description?.localizedCaseInsensitiveContains("running") == true { return .running }
        return CheckState(forge: status)
    }

    /// The Actions job behind this status, when it was reported by Forgejo
    /// Actions: target_url is /owner/repo/actions/runs/{run}/jobs/{index}.
    var jobReference: JobReference? {
        guard let targetURL, let path = URLComponents(string: targetURL)?.path else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let runs = parts.firstIndex(of: "runs"), parts.count > runs + 3, parts[runs + 2] == "jobs",
              parts[..<runs].last == "actions", let run = Int(parts[runs + 1]), let job = Int(parts[runs + 3])
        else { return nil }
        return JobReference(runPath: "/" + parts[...(runs + 1)].joined(separator: "/"), runNumber: run, jobIndex: job)
    }
}

struct JobReference: Hashable, Sendable {
    /// Path of the run's page, to match against a run's html_url.
    var runPath: String
    var runNumber: Int
    var jobIndex: Int
}

struct CombinedStatus: Decodable, Hashable, Sendable {
    var state: String
    var sha: String?
    var statuses: [CommitStatus]?

    var checks: [CommitStatus] { statuses ?? [] }

    var overall: CheckState {
        let states = checks.map(\.state)
        if states.isEmpty { return .unknown }
        if states.contains(.failure) { return .failure }
        if states.contains(.running) { return .running }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.cancelled) { return .cancelled }
        return .success
    }
}

struct WorkflowRun: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var workflowID: String?
    var indexInRepo: Int?
    var prettyRef: String?
    var commitSHA: String?
    var event: String?
    var status: String
    var started: Date?
    var stopped: Date?
    var created: Date?
    var htmlURL: String?
    var triggerUser: ForgeUser?
    var triggerEvent: String?
    var scheduleID: Int?

    /// What started the run: "push", "pull_request", "schedule",
    /// "workflow_dispatch". Forgejo 16 files a scheduled run under the event
    /// "push" and says "schedule" only in trigger_event and ScheduleID.
    var trigger: String? {
        if (scheduleID ?? 0) != 0 { return "schedule" }
        if let triggerEvent, !triggerEvent.isEmpty { return triggerEvent }
        return event
    }

    enum CodingKeys: String, CodingKey {
        case id, title, event, status, started, stopped, created
        case triggerEvent = "trigger_event"
        case scheduleID = "ScheduleID"
        case workflowID = "workflow_id"
        case indexInRepo = "index_in_repo"
        case prettyRef = "prettyref"
        case commitSHA = "commit_sha"
        case htmlURL = "html_url"
        case triggerUser = "trigger_user"
    }

    var state: CheckState { CheckState(forge: status) }
    var number: Int { indexInRepo ?? id }

    /// What started it, in a word a person would use.
    var triggerLabel: String {
        switch trigger {
        case "push": "push"
        case "pull_request", "pull_request_target": "pull request"
        case "schedule": "schedule"
        case "workflow_dispatch": "manual"
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        case nil: ""
        }
    }

    /// "12s", "3m 05s", "1h 02m"; while it runs, the time so far; nil before it starts.
    var duration: String? {
        guard let started, started.timeIntervalSince1970 > 0 else { return nil }
        let end = state.isFinished ? (stopped ?? started) : Date.now
        let seconds = max(0, Int(end.timeIntervalSince(started)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h \(String(format: "%02d", seconds % 3600 / 60))m"
    }
}

struct WorkflowRunList: Decodable, Sendable {
    var workflowRuns: [WorkflowRun]?
    var totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
        case totalCount = "total_count"
    }
}

struct WorkflowJob: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var runID: Int?
    var name: String
    var status: String
    var attempt: Int?
    var taskID: Int?
    var runsOn: [String]?
    var htmlURL: String?
    /// Only in the answer for a single job.
    var steps: [Step]?

    struct Step: Decodable, Identifiable, Hashable, Sendable {
        var number: Int
        var name: String
        var status: String
        var started: Date?
        var stopped: Date?

        var id: Int { number }
        var state: CheckState { CheckState(forge: status) }

        /// "12s", "3m 05s"; nil before the step has started.
        var duration: String? {
            guard let started else { return nil }
            let seconds = max(0, Int((stopped ?? .now).timeIntervalSince(started)))
            return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, attempt, steps
        case runID = "run_id"
        case taskID = "task_id"
        case runsOn = "runs_on"
        case htmlURL = "html_url"
    }

    var state: CheckState { CheckState(forge: status) }
    /// A job has a log only once a runner picked it up.
    var hasStarted: Bool { (taskID ?? 0) > 0 }
}

struct ForgeVersion: Decodable, Sendable {
    var version: String
}

/// An organisation the account belongs to.
struct ForgeOrg: Decodable, Hashable, Sendable {
    var id: Int
    var username: String?
    var name: String?
    var fullName: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name
        case fullName = "full_name"
    }

    var login: String { username ?? name ?? "" }
}

/// A repository on the forge.
struct ForgeRepo: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var fullName: String
    var owner: ForgeUser
    var description: String?
    var isPrivate: Bool?
    var archived: Bool?
    var empty: Bool?
    var fork: Bool?
    var mirror: Bool?
    var defaultBranch: String?
    var sshURL: String?
    var cloneURL: String?
    var htmlURL: String?
    var openPulls: Int?
    var hasActions: Bool?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, owner, description, archived, empty, fork, mirror
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case sshURL = "ssh_url"
        case cloneURL = "clone_url"
        case htmlURL = "html_url"
        case openPulls = "open_pr_counter"
        case hasActions = "has_actions"
        case updatedAt = "updated_at"
    }
}

struct PullCommit: Decodable, Identifiable, Hashable, Sendable {
    struct Detail: Decodable, Hashable, Sendable {
        struct Person: Decodable, Hashable, Sendable {
            var name: String?
            var date: Date?
        }
        var message: String
        var author: Person?
    }

    var sha: String
    var commit: Detail
    var author: ForgeUser?

    var id: String { sha }
    var subject: String { commit.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
}

struct PullFile: Decodable, Identifiable, Hashable, Sendable {
    var filename: String
    var status: String?
    var additions: Int?
    var deletions: Int?

    var id: String { filename }
}

/// A pull request found by a search across repositories (the Inbox).
struct PullSearchHit: Decodable, Identifiable, Hashable, Sendable {
    struct Repository: Decodable, Hashable, Sendable {
        var name: String
        var fullName: String

        enum CodingKeys: String, CodingKey {
            case name
            case fullName = "full_name"
        }
    }

    var id: Int
    var number: Int
    var title: String
    var htmlURL: String?
    var user: ForgeUser?
    var repository: Repository?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, number, title, user, repository
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
    }
}

/// An entry of a directory listing.
struct ContentEntry: Decodable, Hashable, Sendable {
    var name: String
    var path: String
    var type: String
    var sha: String?
}

struct ContentFile: Decodable, Sendable {
    var content: String?
}

struct Comparison: Decodable, Sendable {
    var commits: [PullCommit]?
    var totalCommits: Int?

    enum CodingKeys: String, CodingKey {
        case commits
        case totalCommits = "total_commits"
    }
}

/// A workflow file as the engine reads it (`workflow.parse`).
struct WorkflowInfo: Decodable, Hashable, Sendable {
    struct Input: Decodable, Hashable, Sendable, Identifiable {
        var name: String
        var description: String
        var required: Bool
        var `default`: String
        var type: String
        var options: [String]

        var id: String { name }
    }

    var name: String
    var dispatch: Bool
    var inputs: [Input]
    var events: [String]
}

/// A workflow of a repository: its file and what the file says.
struct Workflow: Identifiable, Hashable, Sendable {
    var file: String // "terraform.yaml"
    var path: String
    var info: WorkflowInfo?

    var id: String { file }
    var title: String { (info?.name.isEmpty == false ? info?.name : nil) ?? file }
}

/// A branch protection rule; only what the Reviews card needs.
struct BranchProtection: Decodable, Hashable, Sendable {
    var ruleName: String?
    var branchName: String?
    var requiredApprovals: Int?

    enum CodingKeys: String, CodingKey {
        case ruleName = "rule_name"
        case branchName = "branch_name"
        case requiredApprovals = "required_approvals"
    }

    /// Whether the rule covers `branch`: the exact name, or a glob such as
    /// "release/*".
    func covers(_ branch: String) -> Bool {
        let pattern = ruleName ?? branchName ?? ""
        if pattern == branch { return true }
        guard pattern.contains("*") || pattern.contains("?") else { return false }
        return fnmatch(pattern, branch, 0) == 0
    }
}
