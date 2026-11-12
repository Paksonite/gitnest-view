import SwiftUI

/// The list of pull requests with the chosen one beside it. The Overview tab
/// shows the same, opened on the pull request of the current branch, with
/// the repository's pipelines and commits below.
struct PullBrowser: View {
    enum Filter: Hashable { case open, closed, all }

    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let forge: RepoForge
    var overview = false
    /// The user's choice; before one, Open when something is open, else All:
    /// an empty list beside a merged pull request reads as "nothing here".
    @State private var chosenFilter: Filter?

    private var filter: Filter {
        // Open, unless the user chose otherwise: an empty Open list says "nothing waits".
        chosenFilter ?? .open
    }
    @State private var selected: PullRequest.ID?

    private var shown: [PullRequest] {
        switch filter {
        case .open: forge.pulls.filter { $0.state == "open" }
        case .closed: forge.pulls.filter { $0.state != "open" }
        case .all: forge.pulls
        }
    }

    /// The chosen pull request; before a choice, the open one of the branch
    /// checked out here, else the one that changed last (open or not).
    private var current: PullRequest? {
        if let chosen = forge.pulls.first(where: { $0.id == selected }) { return chosen }
        if let branch = model.clone(of: repo)?.branch,
           let mine = forge.pulls.first(where: { $0.state == "open" && $0.head.ref == branch }) { return mine }
        // Then any open one, then the last merged (its apply may be running);
        // a pull request closed without merging is history, not news.
        return forge.pulls.first { $0.state == "open" } ?? forge.pulls.first { $0.merged == true }
            ?? (overview ? nil : forge.pulls.first)
    }

    var body: some View {
        HStack(spacing: 0) {
            ResizableColumn(key: "pullList", initial: 380, range: 280...720) { list }
            Group {
                if let pull = current {
                    PullDetail(repo: repo, pull: pull, forge: forge, overview: overview).id(pull.id).settleIn()
                } else if overview && forge.runs.isEmpty {
                    EmptyState("Quiet here", symbol: "leaf", message: "No pull requests and no pipelines in \(repo.name) yet.")
                } else if overview {
                    ScrollView {
                        VStack(spacing: 14) {
                            BranchPipelinesCard(repo: repo, runs: forge.runs, onlyTrouble: false)
                        }
                        .padding(16)
                    }
                } else {
                    EmptyState("No pull requests", symbol: "arrow.triangle.pull", message: "This repository has no pull requests yet.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: chosenFilter) {
            // Asked for by the user, not by the default: the full history costs a second.
            if let chosenFilter, chosenFilter != .open { model.wantHistory(repo) }
        }
        .onChange(of: model.pendingPull, initial: true) {
            guard let number = model.pendingPull else { return }
            if let pull = forge.pulls.first(where: { $0.number == number }) {
                chosenFilter = pull.state == "open" ? .open : .all
                selected = pull.id
                model.pendingPull = nil
            } else {
                // An older pull request: it comes with the history.
                Task {
                    await model.loadHistory(repo)
                    if let pull = model.forgeState(repo).pulls.first(where: { $0.number == number }) {
                        chosenFilter = pull.state == "open" ? .open : .all
                        selected = pull.id
                    }
                    model.pendingPull = nil
                }
            }
        }
    }

    /// The branch a new pull request most likely comes from: the one checked
    /// out here, unless that is the default branch or already has one.
    private var suggestedHead: String {
        let main = repo.defaultBranch ?? "main"
        if let branch = model.clone(of: repo)?.branch, branch != main,
           !forge.pulls.contains(where: { $0.state == "open" && $0.head.ref == branch }) { return branch }
        return "develop"
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Segments(options: [(Filter.open, "Open"), (.closed, "Closed"), (.all, "All")], selection: Binding(get: { filter }, set: { chosenFilter = $0 }))
                Spacer()
                Button("New", systemImage: "plus") { model.sheet = .createPull(repo, head: suggestedHead) }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .needsWrite()
                    .help("Open a new pull request: choose the branches from the server's")
                Button("Release", systemImage: "paperplane") { model.sheet = .release(repo) }
                    .buttonStyle(ChipButtonStyle())
                    .needsWrite()
                    .help("Prepare the pull request that releases develop into \(repo.defaultBranch ?? "main")")
            }
            .padding(12)
            if shown.isEmpty {
                EmptyState(
                    filter == .open ? "No open pull requests" : "No pull requests",
                    symbol: "arrow.triangle.pull",
                    message: filter == .open ? "Push a change branch and open a pull request on the server; it appears here with its checks and reviews." : ""
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { pull in
                            Button {
                                selected = pull.id
                            } label: {
                                PullRow(pull: pull, status: forge.statuses[pull.head.sha], summary: forge.summary(for: pull))
                            }
                            .buttonStyle(.plain)
                            .hoverBackground(selected: current?.id == pull.id)
                        }
                        if filter != .open, !model.hasHistory(repo), forge.pulls.count(where: { $0.state != "open" }) >= 5 {
                            Button("Show older pull requests") { model.wantHistory(repo) }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.blue)
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .linkCursor()
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

struct PullRow: View {
    let pull: PullRequest
    let status: CombinedStatus?
    let summary: ReviewSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let status, !status.checks.isEmpty {
                    CheckIcon(state: status.overall)
                } else {
                    Image(systemName: pull.phase == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                        .font(.system(size: 12))
                        .foregroundStyle(pull.phase.color)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(pull.title).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text("#\(pull.number)")
                    if pull.phase != .open { Text(pull.phase.label).foregroundStyle(pull.phase.color) }
                    if let user = pull.user { Text(user.displayName).help(user.login) }
                    if summary.approvals > 0 {
                        Label("\(summary.approvals)", systemImage: "checkmark").foregroundStyle(Theme.green)
                    }
                    if summary.changesRequested > 0 {
                        Label("\(summary.changesRequested)", systemImage: "exclamationmark.bubble").foregroundStyle(Theme.red)
                    }
                    if let updated = pull.updatedAt { Text(updated.relative) }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

struct PullDetail: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let pull: PullRequest
    let forge: RepoForge
    var overview = false

    private var extra: PullExtras {
        model.slug(repo).flatMap { model.extras[AppModel.extrasKey($0, pull.number)] } ?? PullExtras()
    }

    @State private var attribution: PlanAttribution?

    private struct PlanKey: Hashable {
        var plan: TerraformPlan?
        var files: Int
    }

    var body: some View {
        let extra = extra
        let _ = Trace.note("PullDetail body #\(pull.number) loaded=\(extra.loaded)")
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                title
                if !model.mayWrite(repo), pull.state == "open" {
                    Label(AppModel.readOnlyNote, systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        ForEach(extra.mergeRuns.prefix(2)) { run in
                            RunCard(repo: repo, run: run, jobs: extra.jobs[run.id] ?? [], result: extra.applied, failure: extra.applyError,
                                    stage: .merge(base: pull.base.ref), refresh: reload)
                        }
                        if let run = extra.pullRuns.first {
                            RunCard(repo: repo, run: run, jobs: extra.jobs[run.id] ?? [], result: extra.plan, failure: extra.planError,
                                    stage: .pull, refresh: reload)
                        }
                        if pull.state == "open", pull.mergeable == false { ConflictCard(repo: repo, pull: pull) }
                        Card("Description") {
                            if let body = pull.body, !body.isEmpty {
                                Text(LocalizedStringKey(body)).textSelection(.enabled)
                            } else {
                                Text("No description.").foregroundStyle(Theme.secondary)
                            }
                        }
                        ConversationCard(repo: repo, pull: pull, comments: extra.comments, lineComments: extra.lineComments,
                                         reviews: forge.reviews[pull.number] ?? [], loaded: extra.loaded)
                        if overview {
                            BranchPipelinesCard(repo: repo, runs: forge.runs, onlyTrouble: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 14) {
                        ReviewsCard(summary: forge.summary(for: pull), required: model.requiredApprovals(pull, in: repo), open: pull.state == "open",
                                    known: model.knowsRequirement(pull, in: repo))
                        if pull.state == "open" { PeopleCard(repo: repo, pull: pull) }
                        ChecksCard(repo: repo, status: forge.statuses[pull.head.sha], scheduled: AppModel.scheduledRuns(forge.runs),
                                   rerun: pull.state == "open" ? { Task { await model.rerunFailed(of: pull, in: repo) } } : nil)
                        CommitsCard(commits: extra.commits, loaded: extra.loaded)
                        FilesCard(files: extra.files, loaded: extra.loaded, count: pull.changedFiles, attribution: attribution) { file in
                            guard let slug = model.slug(repo) else { return }
                            model.diffTarget = DiffTarget(repo: slug, number: pull.number, title: pull.title, file: file)
                        }
                    }
                    .frame(width: 300)
                }
            }
            .padding(16)
        }
        .task(id: PlanKey(plan: extra.plan ?? extra.applied, files: extra.files.count)) {
            attribution = await model.planAttribution(extra.plan ?? extra.applied, files: extra.files, in: repo)
        }
        // Reload when the head moves or the pull request is merged, and keep
        // reading while one of its pipelines is running.
        .task(id: "\(pull.head.sha)/\(pull.state)/\(pull.mergeCommitSHA ?? "")") {
            var first = true
            while !Task.isCancelled {
                // What a hover has just read is not read again on the click.
                await model.loadExtras(pull, in: repo, ifOlderThan: first ? 8 : 0)
                first = false
                guard self.extra.isLive || !(forge.statuses[pull.head.sha]?.overall.isFinished ?? true) else { break }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func reload() {
        Task { await model.loadExtras(pull, in: repo) }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (Text(pull.title).font(.system(size: 17, weight: .semibold))
                    + Text("  #\(pull.number)").font(.system(size: 17)).foregroundStyle(Theme.tertiary))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                if pull.state == "open" {
                    if !model.isMine(pull) {
                        Button("Review…", systemImage: "eye") { model.sheet = .review(repo, pull) }
                            .buttonStyle(ChipButtonStyle(prominent: model.reviewRequested(of: pull, in: repo)))
                            .fixedSize()
                            .needsWrite()
                    }
                    if pull.mergeable != false {
                        // The step a pull request is for: coloured, and never cut short.
                        Button("Merge…", systemImage: "arrow.triangle.merge") { model.sheet = .merge(repo, pull) }
                            .buttonStyle(ChipButtonStyle(prominent: true, tint: Theme.green))
                            .fixedSize()
                            .needsWrite()
                    }
                }
                PullMenu(repo: repo, pull: pull)
                Button("Copy Link", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pull.htmlURL, forType: .string)
                    model.toast("Copied the link to #\(pull.number): \(pull.htmlURL)")
                }
                .buttonStyle(ChipButtonStyle())
                .fixedSize()
                .help("Copy the pull request's address, to send it to someone for approval")
                if let url = URL(string: pull.htmlURL) {
                    Button("Open in Browser", systemImage: "arrow.up.right.square") { openExternal(url) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                        .help("Open on the server")
                }
            }
            HStack(spacing: 8) {
                Badge(text: pull.phase.label, color: pull.phase.color)
                if pull.head.ref == "develop", pull.base.ref == repo.defaultBranch {
                    Badge(text: pull.merged == true ? "release · applied on merge" : "release · apply on merge", color: Theme.yellow, filled: false)
                }
                ForEach(pull.labels ?? [], id: \.name) { label in
                    Badge(text: label.name, color: Color(hex: label.color) ?? Theme.yellow, filled: false)
                }
                if pull.state == "open", pull.mergeable == false { Badge(text: "Conflicts", color: Theme.red) }
                if let user = pull.user { Text(user.displayName).help(user.login) }
                (Text(pull.base.ref).foregroundStyle(Theme.text) + Text(" ← ") + Text(pull.head.name).foregroundStyle(Theme.text))
                    .font(.system(size: 12, design: .monospaced))
                Text("· " + String(pull.head.sha.prefix(7))).font(.system(size: 12, design: .monospaced))
                if let updated = pull.updatedAt { Text("· updated \(updated.relative)") }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
        }
    }
}

/// One pipeline of a pull request: its state, live; its jobs; and for
/// Terraform or OpenTofu, what the plan or the apply said.
struct RunCard: View {
    enum Stage: Equatable {
        case pull
        case merge(base: String)
    }

    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let run: WorkflowRun
    let jobs: [WorkflowJob]
    let result: TerraformPlan?
    var failure: [String]? = nil
    let stage: Stage
    let refresh: () -> Void

    private var isTerraform: Bool {
        if result != nil { return true }
        let name = "\(run.workflowID ?? "") \(run.title) \(jobs.map(\.name).joined(separator: " "))".lowercased()
        return name.contains("terraform") || name.contains("tofu")
    }

    private var verb: String {
        switch stage {
        case .pull: isTerraform ? "Plan" : "Pipeline"
        case .merge: isTerraform ? "Apply" : "Pipeline"
        }
    }

    private var heading: String {
        switch stage {
        case .pull: isTerraform ? "Terraform plan" : "Pipeline"
        case .merge(let base): isTerraform ? "Terraform apply · \(base)" : "After merge · \(base)"
        }
    }

    var body: some View {
        let visible = model.visibleJobs(jobs)
        let quiet = result == nil && (failure ?? []).isEmpty && visible.shown.isEmpty && !(isTerraform && !run.state.isFinished)
        Card(heading, state: run.state) {
            // One line says which run this is; the card's body is for what it found.
            HStack(spacing: 10) {
                Text("#\(run.number) · \(model.workflowName(run, in: repo))").lineLimit(1)
                Text(String((run.commitSHA ?? "").prefix(7))).font(.system(size: 11.5, design: .monospaced))
                Button {
                    Task { await model.openLog(run: run, in: repo) }
                } label: {
                    Label("Logs", systemImage: "text.alignleft")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Show the log, live while the job runs")
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Read again")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiary)
        } content: {
            if quiet {
                Text("\(verb) \(run.state.isFinished ? "finished:" : "is") \(run.state.label).").foregroundStyle(Theme.secondary)
            }
            if let result {
                PlanSummary(plan: result)
            } else if let failure, !failure.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(failure.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, weight: line.hasPrefix("Error:") ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("Error:") ? Theme.red : Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.red.opacity(0.35)))
            } else if isTerraform, !run.state.isFinished {
                HStack(spacing: 8) {
                    Spinner(color: run.state.color)
                    Text("\(verb) is \(run.state.label) — the summary appears when terraform finishes.")
                        .foregroundStyle(Theme.secondary)
                }
            }
            if !visible.shown.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(visible.shown.enumerated()), id: \.element.id) { index, job in
                        if index > 0 { HLine() }
                        Button {
                            model.openLog(job: job, run: run, in: repo)
                        } label: {
                            HStack(spacing: 8) {
                                CheckIcon(state: job.state)
                                Text(job.name).lineLimit(1)
                                Spacer()
                                Text(job.state == .skipped ? "skipped" : job.state.isFinished && !job.hasStarted ? "no log" : job.state.label)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(job.state.isFinished && !job.hasStarted)
                        .hoverBackground(radius: 0)
                        .help("Show the log")
                    }
                }
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            }
            if !run.state.isFinished, let job = jobs.first(where: { $0.state == .running && $0.hasStarted && model.isKey($0) })
                ?? jobs.first(where: { $0.state == .running && $0.hasStarted }), let slug = model.slug(repo) {
                // While it runs, the log is here: no click needed to see it move.
                LogPane(target: LogTarget(repo: slug, runID: run.id, jobID: job.id, title: job.name, webURL: job.htmlURL))
                    .id(job.id)
                    .frame(height: 260)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            }
            if visible.passed + visible.other > 0 {
                // The other jobs are worth a line only: they passed, or have not run.
                Text([visible.passed > 0 ? "\(visible.passed) other \(visible.passed == 1 ? "job" : "jobs") passed" : nil,
                      visible.other > 0 ? "\(visible.other) not finished" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}

/// "1 to add 0 to change 0 to destroy" and the resources, one per line.
struct PlanSummary: View {
    let plan: TerraformPlan
    /// At most this many resources are listed; the rest are counted.
    var limit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                count(plan.add, plan.applied ? "added" : "to add", Theme.green)
                count(plan.change, plan.applied ? "changed" : "to change", Theme.yellow)
                count(plan.destroy, plan.applied ? "destroyed" : "to destroy", Theme.red)
            }
            if !plan.changes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(plan.changes.prefix(limit).enumerated()), id: \.offset) { index, change in
                        if index > 0 { HLine() }
                        HStack(spacing: 10) {
                            Text(change.action.sign).foregroundStyle(change.action.color).frame(width: 22, alignment: .leading)
                            Text(change.action.rawValue).foregroundStyle(change.action.color).frame(width: 56, alignment: .leading)
                            Text(change.address).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(change.address)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 28)
                    }
                }
            }
            if plan.changes.count > limit {
                Text("and \(plan.changes.count - limit) more").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }

    private func count(_ number: Int, _ label: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(number)").font(.system(size: 17, weight: .semibold)).foregroundStyle(number > 0 ? color : Theme.text).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }
}

extension TerraformPlan.Action {
    var color: Color {
        switch self {
        case .create: Theme.green
        case .update: Theme.yellow
        case .destroy: Theme.red
        case .replace: Theme.orange
        case .read: Theme.blue
        }
    }
}

/// The state of the default branch: the latest run of each workflow on it.
/// With `onlyTrouble`, the card shows only when something failed or is
/// running, and lists just that.
struct BranchPipelinesCard: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let runs: [WorkflowRun]
    let onlyTrouble: Bool

    private var latest: [WorkflowRun] {
        let branch = repo.defaultBranch ?? "main"
        var seen: Set<String> = []
        var out: [WorkflowRun] = []
        for run in runs where run.prettyRef == branch && run.trigger != "pull_request" {
            let workflow = run.workflowID ?? run.title
            if seen.insert(workflow).inserted { out.append(run) }
        }
        return onlyTrouble ? out.filter { $0.state != .success && $0.state != .skipped } : out
    }

    var body: some View {
        let latest = latest
        // Nothing to say about a repository whose branch never ran a pipeline.
        if !latest.isEmpty {
            Card(onlyTrouble ? "Needs attention on \(repo.defaultBranch ?? "main")" : "Pipelines on \(repo.defaultBranch ?? "main")") {
                if latest.isEmpty { Text("No pipeline has run on this branch yet.").foregroundStyle(Theme.secondary) }
                VStack(spacing: 0) {
                    ForEach(latest) { run in
                        Button {
                            Task { await model.openLog(run: run, in: repo) }
                        } label: {
                            HStack(spacing: 8) {
                                CheckIcon(state: run.state)
                                Text(model.workflowName(run, in: repo)).lineLimit(1)
                                Text(run.title).foregroundStyle(Theme.secondary).lineLimit(1)
                                Spacer()
                                Text(run.state.label).font(.system(size: 11.5)).foregroundStyle(run.state == .failure ? Theme.red : Theme.secondary)
                                Text((run.started ?? run.created)?.relative ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverBackground(radius: 5)
                        .help("Show the log")
                    }
                }
                .padding(.horizontal, -6)
            }
        }
    }
}

struct ReviewsCard: View {
    let summary: ReviewSummary
    var required: Int? = nil
    /// The pull request is still open: a missing review still matters.
    var open = true
    /// The app knows whether the base branch needs approvals.
    var known = true

    var body: some View {
        Card(required.map { "Reviews  \(summary.approvals)/\($0)" } ?? "Reviews") {
            if let required {
                Text(summary.approvals >= required ? "approved" : "\(required) \(required == 1 ? "approval" : "approvals") required")
                    .font(.system(size: 12)).foregroundStyle(summary.approvals >= required ? Theme.green : Theme.secondary)
            } else if summary.approvals > 0 {
                Text("\(summary.approvals) approved").font(.system(size: 12)).foregroundStyle(Theme.green)
            } else if summary.waiting > 0 {
                Text("\(summary.waiting) requested").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        } content: {
            if let required, summary.approvals < required, open {
                // The branch is protected: say so, whoever was or was not asked.
                let missing = required - summary.approvals
                Label {
                    Text(summary.waiting > 0 || !summary.verdicts.isEmpty
                        ? "Review required: \(missing) more \(missing == 1 ? "approval" : "approvals") before this can be merged."
                        : "Review required: \(required) \(required == 1 ? "approval" : "approvals") before this can be merged. Nobody has been asked yet.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.orange)
                }
                .font(.system(size: 12))
            } else if summary.verdicts.isEmpty {
                Text(!open ? "No reviews." : known ? "No reviews yet. This branch does not require one."
                     : "No reviews yet. The server did not say whether this branch requires one.")
                    .foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(summary.verdicts) { verdict in
                HStack(spacing: 8) {
                    Image(systemName: verdict.kind.symbol).foregroundStyle(verdict.kind.color).frame(width: 16)
                    Text(verdict.user.displayName).lineLimit(1).help(verdict.user.login)
                    Spacer()
                    Text(verdict.stale ? "\(verdict.kind.label), outdated" : verdict.kind.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

extension ReviewerVerdict.Kind {
    var symbol: String {
        switch self {
        case .approved: "checkmark.circle"
        case .changesRequested: "exclamationmark.bubble"
        case .commented: "bubble.left"
        case .requested: "person.crop.circle.badge.clock"
        }
    }

    var color: Color {
        switch self {
        case .approved: Theme.green
        case .changesRequested: Theme.red
        case .commented: Theme.secondary
        case .requested: Theme.orange
        }
    }

    var label: String {
        switch self {
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .commented: "commented"
        case .requested: "requested"
        }
    }
}

struct ChecksCard: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let status: CombinedStatus?
    /// The repository's standing checks: the newest scheduled run of each workflow.
    var scheduled: [WorkflowRun] = []

    /// Runs the failed pipelines again; nil hides the button.
    var rerun: (() -> Void)? = nil

    /// What is wrong first: failed, then running and waiting, then the rest.
    private static func order(_ state: CheckState) -> Int {
        switch state {
        case .failure: 0
        case .running: 1
        case .waiting: 2
        case .success: 4
        default: 3
        }
    }

    var body: some View {
        let checks = (status?.checks ?? []).enumerated().sorted {
            Self.order($0.element.state) != Self.order($1.element.state) ? Self.order($0.element.state) < Self.order($1.element.state) : $0.offset < $1.offset
        }.map(\.element)
        let failed = checks.count { $0.state == .failure }
        let passed = checks.count { $0.state == .success }
        Card("Checks", state: checks.isEmpty ? nil : status?.overall) {
            if !checks.isEmpty {
                Text(failed > 0 ? "\(failed) failed · \(passed) of \(checks.count) passed" : "\(passed) of \(checks.count) passed")
                    .font(.system(size: 12)).foregroundStyle(failed > 0 ? Theme.red : Theme.secondary).monospacedDigit().lineLimit(1)
            }
        } content: {
            if checks.isEmpty {
                Text("No checks for this commit.").foregroundStyle(Theme.secondary)
            }
            ForEach(checks) { check in
                CheckRow(check: check) { Task { await model.openLog(for: check, in: repo) } }
            }
            if failed > 0, let rerun {
                Button(model.supportsRerun(model.workspace?.host) ? "Run Failed Again" : "Re-run in Browser", systemImage: "arrow.clockwise", action: rerun)
                    .buttonStyle(ChipButtonStyle())
                    .needsWrite()
                    .help(model.supportsRerun(model.workspace?.host) ? "Run the failed pipelines of this commit again"
                          : "Forgejo 16 has no re-run in its API: opens the run in the browser")
            }
            if !scheduled.isEmpty {
                HLine().padding(.horizontal, -12)
                Text("Scheduled").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                ForEach(scheduled) { run in
                    Button {
                        Task { await model.openLog(run: run, in: repo) }
                    } label: {
                        HStack(spacing: 8) {
                            CheckIcon(state: run.state)
                            Text(model.workflowName(run, in: repo)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let at = run.stopped ?? run.started ?? run.created {
                                Text(at.relative).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Runs on a schedule, not for this pull request. Last: \(run.state.label).")
                }
            }
        }
    }
}

/// One check: its state, the job, what the server says about it; a click
/// shows its log.
private struct CheckRow: View {
    let check: CommitStatus
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                CheckIcon(state: check.state)
                let name = CheckName(check.context)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.job).lineLimit(1).truncationMode(.tail)
                    // "Failing after 13s", "Successful in 1m": the server's own words.
                    let note = [name.workflow, check.description ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !note.isEmpty {
                        Text(note).font(.system(size: 11)).foregroundStyle(check.state == .failure ? Theme.red.opacity(0.85) : Theme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: check.jobReference == nil ? "arrow.up.right" : "text.alignleft")
                    .font(.system(size: 10)).foregroundStyle(Theme.blue).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6).padding(.vertical, -3)
        .onHover { hovering = $0 }
        .linkCursor()
        .help("\(check.context)\n\(check.jobReference == nil ? "Open in the browser" : "Show the log")")
        .accessibilityLabel("Check \(CheckName(check.context).job): \(check.state.label)")
    }
}

struct CommitsCard: View {
    let commits: [PullCommit]
    let loaded: Bool

    var body: some View {
        Card("Commits · \(commits.count)") {
            if !loaded { ProgressView().controlSize(.small) }
            ForEach(commits.prefix(12)) { commit in
                HStack(spacing: 8) {
                    Text(String(commit.sha.prefix(7))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                    Text(commit.subject).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .help(commit.commit.message)
            }
            if commits.count > 12 {
                Text("and \(commits.count - 12) more").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
        }
    }
}

struct FilesCard: View {
    let files: [PullFile]
    let loaded: Bool
    let count: Int?
    /// What the plan changes, by the file that declares it.
    var attribution: PlanAttribution? = nil
    /// Shows a file's diff; nil shows all of them.
    var show: ((String?) -> Void)? = nil

    var body: some View {
        Card("Files · \(loaded ? files.count : (count ?? 0))") {
            if let show, !files.isEmpty {
                Button("Diff") { show(nil) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.blue)
            }
        } content: {
            if !loaded { ProgressView().controlSize(.small) }
            ForEach(files.prefix(15)) { file in
                FileLink(file: file) { show?(file.filename) }
                if let changes = attribution?.byFile[file.filename] {
                    PlanLines(changes: changes).padding(.leading, 10)
                }
            }
            if files.count > 15 {
                Text("and \(files.count - 15) more").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            if let attribution, !attribution.elsewhere.isEmpty || !attribution.unknown.isEmpty {
                // The plan reaches further than the files: say where.
                HLine().padding(.horizontal, -12)
                Text("The plan also changes").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                    .help("Resources declared in files this pull request does not touch: their inputs changed (a variable, a data file, a module).")
                let grouped = Dictionary(grouping: attribution.elsewhere, by: \.file)
                ForEach(grouped.keys.sorted(), id: \.self) { file in
                    Text(file).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.head)
                    PlanLines(changes: (grouped[file] ?? []).map(\.change)).padding(.leading, 10)
                }
                if !attribution.unknown.isEmpty { PlanLines(changes: attribution.unknown) }
            }
        }
    }
}

/// A changed file's name: it lights up under the pointer, because it opens.
private struct FileLink: View {
    let file: PullFile
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(hovering ? Theme.blue : Theme.tertiary)
                Text(file.filename).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(hovering ? Theme.blue : Theme.text)
                    .underline(hovering, color: Theme.blue.opacity(0.6))
                Spacer(minLength: 4)
                if hovering {
                    Text("Show changes").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.blue)
                        .transition(.opacity.combined(with: .offset(x: 6)))
                }
                Text("+\(file.additions ?? 0)").foregroundStyle(Theme.green)
                Text("−\(file.deletions ?? 0)").foregroundStyle(Theme.red)
            }
            .font(.system(size: 11.5).monospacedDigit())
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .padding(.vertical, -3)
        .onHover { hovering = $0 }
        .linkCursor()
        .animation(Motion.hover, value: hovering)
        .help("Show the changes in \(file.filename)")
    }
}

/// "Terraform pipeline / Terraform single state (org-core-iam) (pull_request)"
/// → job "Terraform single state (org-core-iam)", workflow "Terraform pipeline".
struct CheckName {
    var job: String
    var workflow: String

    init(_ context: String) {
        var text = context
        for event in [" (pull_request)", " (push)", " (pull_request_target)", " (workflow_dispatch)", " (schedule)"] where text.hasSuffix(event) {
            text = String(text.dropLast(event.count))
        }
        if let slash = text.range(of: " / ") {
            workflow = String(text[..<slash.lowerBound])
            job = String(text[slash.upperBound...])
        } else {
            workflow = ""
            job = text
        }
    }
}


/// A plan's changes as short lines: "+ google_dns_record_set.a".
struct PlanLines: View {
    let changes: [TerraformPlan.Change]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(changes.prefix(5).enumerated()), id: \.offset) { _, change in
                HStack(spacing: 6) {
                    Text(change.action.sign).foregroundStyle(change.action.color).frame(width: 12, alignment: .leading)
                    Text(change.address).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle).help("\(change.action.rawValue) \(change.address)")
                }
                .font(.system(size: 11, design: .monospaced))
            }
            if changes.count > 5 {
                Text("and \(changes.count - 5) more").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}
