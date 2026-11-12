import SwiftUI

/// A repository at a glance: what is running now (with its log, live),
/// what waits to be merged, what was merged lately and how its pipeline
/// went, the default branch, the scheduled checks, and the clone.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let forge: RepoForge
    /// Jobs of the runs that are going on, by run id.
    @State private var jobs: [Int: [WorkflowJob]] = [:]

    private var running: [WorkflowRun] { Array(forge.runs.filter { !$0.state.isFinished }.prefix(3)) }
    private var open: [PullRequest] { forge.pulls.filter { $0.state == "open" } }

    private var merged: [PullRequest] {
        Array(forge.pulls.filter { $0.merged == true }
            .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }.prefix(4))
    }

    /// The pipeline the merge started, when it is among the runs read.
    private func mergeRun(_ pull: PullRequest) -> WorkflowRun? {
        guard let sha = pull.mergeCommitSHA, !sha.isEmpty else { return nil }
        return AppModel.mergeRuns(forge.runs.filter { $0.commitSHA == sha }).first
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    if running.isEmpty {
                        quiet
                    } else {
                        ForEach(running) { run in
                            LiveRunCard(repo: repo, run: run, jobs: jobs[run.id] ?? [])
                        }
                    }
                    openCard
                    mergedCard
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    BranchPipelinesCard(repo: repo, runs: forge.runs, onlyTrouble: false)
                    let scheduled = AppModel.scheduledRuns(forge.runs)
                    if !scheduled.isEmpty { scheduledCard(scheduled) }
                    cloneCard
                }
                .frame(width: 310)
            }
            .padding(16)
        }
        // While something runs, read the runs and their jobs every few seconds.
        .task(id: running.map(\.id)) { await follow() }
    }

    // MARK: Now

    private var quiet: some View {
        let last = forge.runs.first
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(Theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing is running in \(repo.name)").font(.system(size: 13, weight: .medium))
                if let last {
                    Text("Last pipeline: \(model.workflowName(last, in: repo)) · \(last.state.label)\((last.stopped ?? last.started).map { " · \($0.relative)" } ?? "")")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                } else {
                    Text("No pipeline has run here yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            Button("Actions") { model.repoTab = .actions }.buttonStyle(ChipButtonStyle())
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }

    private func follow() async {
        guard !running.isEmpty, let slug = model.slug(repo), let client = model.client(for: slug.host) else { return }
        while !Task.isCancelled {
            for run in running {
                if let found = try? await client.jobs(slug, run: run.id), jobs[run.id] != found { jobs[run.id] = found }
            }
            try? await Task.sleep(for: .seconds(4))
            await model.refreshForge(repo, detailed: true)
        }
    }

    // MARK: Pull requests

    private var openCard: some View {
        Card("Open pull requests") {
            HStack(spacing: 10) {
                Text("\(open.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("New", systemImage: "plus") { model.sheet = .createPull(repo, head: "develop") }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.blue)
                    .needsWrite()
            }
        } content: {
            if open.isEmpty { Text("Nothing waits to be merged.").foregroundStyle(Theme.secondary) }
            VStack(spacing: 0) {
                ForEach(open) { pull in
                    pullLine(pull, trailing: AnyView(reviewState(pull)))
                }
            }
            .padding(.horizontal, -6)
        }
    }

    private var mergedCard: some View {
        Card("Merged lately") {
            Button("All Pull Requests") { model.repoTab = .pulls }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.blue)
        } content: {
            if merged.isEmpty { Text("Nothing merged among the pull requests read.").foregroundStyle(Theme.secondary) }
            VStack(spacing: 0) {
                ForEach(merged) { pull in
                    pullLine(pull, trailing: AnyView(afterMerge(pull)))
                }
            }
            .padding(.horizontal, -6)
        }
    }

    private func pullLine(_ pull: PullRequest, trailing: AnyView) -> some View {
        Button {
            model.repoTab = .pulls
            model.pendingPull = pull.number
        } label: {
            HStack(spacing: 8) {
                if let status = forge.statuses[pull.head.sha], !status.checks.isEmpty, pull.state == "open" {
                    CheckIcon(state: status.overall)
                } else {
                    Image(systemName: pull.merged == true ? "arrow.triangle.merge" : "arrow.triangle.pull")
                        .font(.system(size: 11)).foregroundStyle(pull.phase.color).frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pull.title).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("#\(pull.number)")
                        Text("\(pull.base.ref) ← \(pull.head.name)").font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        if let user = pull.user { Text(user.displayName) }
                        if let when = pull.merged == true ? pull.mergedAt : pull.updatedAt { Text(when.relative) }
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(radius: 5)
        .help("Show #\(pull.number)")
    }

    @ViewBuilder private func reviewState(_ pull: PullRequest) -> some View {
        let summary = forge.summary(for: pull)
        let required = model.requiredApprovals(pull, in: repo)
        if summary.changesRequested > 0 {
            Badge(text: "changes requested", color: Theme.orange, filled: false)
        } else if let required, summary.approvals < required {
            Badge(text: "\(summary.approvals)/\(required) approvals", color: Theme.orange, filled: false)
        } else if summary.approvals > 0 {
            Badge(text: "approved", color: Theme.green, filled: false)
        } else if summary.waiting > 0 {
            Badge(text: "review requested", color: Theme.secondary, filled: false)
        }
    }

    @ViewBuilder private func afterMerge(_ pull: PullRequest) -> some View {
        if let run = mergeRun(pull) {
            HStack(spacing: 5) {
                CheckIcon(state: run.state, size: 12)
                Text(run.state.isFinished ? run.state.label : "running").font(.system(size: 11.5)).foregroundStyle(run.state == .failure ? Theme.red : Theme.secondary)
            }
            .help("The pipeline the merge started: \(model.workflowName(run, in: repo))")
        }
    }

    // MARK: Side

    private func scheduledCard(_ runs: [WorkflowRun]) -> some View {
        Card("Scheduled") {
            ForEach(runs) { run in
                Button {
                    Task { await model.openLog(run: run, in: repo) }
                } label: {
                    HStack(spacing: 8) {
                        CheckIcon(state: run.state)
                        Text(model.workflowName(run, in: repo)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let at = run.stopped ?? run.started { Text(at.relative).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Runs on a schedule. Last: \(run.state.label). Click for the log.")
            }
        }
    }

    @ViewBuilder private var cloneCard: some View {
        Card("Clone") {
            if let clone = model.clone(of: repo) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.secondary)
                        Text(clone.branch).font(.system(size: 12.5, design: .monospaced)).lineLimit(1)
                        LocalState(repo: clone)
                    }
                    HStack(spacing: 8) {
                        if clone.behind > 0 {
                            Button("Pull \(clone.behind)", systemImage: "arrow.down") { Task { await model.run(.pull, on: repo) } }
                                .buttonStyle(ChipButtonStyle(prominent: true))
                        }
                        Button("Changes") { model.repoTab = .changes }.buttonStyle(ChipButtonStyle())
                        Button("Resources") { model.repoTab = .resources }.buttonStyle(ChipButtonStyle())
                    }
                }
            } else {
                Text("Not cloned here.").foregroundStyle(Theme.secondary)
                Button("Clone") { Task { await model.clone(repo) } }.buttonStyle(ChipButtonStyle(prominent: true))
            }
        }
    }
}

/// A pipeline that is running: who started it and why, its jobs, and the
/// log of the job at work, live.
struct LiveRunCard: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let run: WorkflowRun
    let jobs: [WorkflowJob]
    /// The job whose log is shown; by default the one at work.
    @State private var chosen: Int?

    private var watched: WorkflowJob? {
        if let chosen, let job = jobs.first(where: { $0.id == chosen }) { return job }
        return jobs.first { $0.state == .running && $0.hasStarted && model.isKey($0) }
            ?? jobs.first { $0.state == .running && $0.hasStarted }
            ?? jobs.last { $0.hasStarted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                CheckIcon(state: run.state)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.workflowName(run, in: repo)).font(.system(size: 13, weight: .semibold))
                        Text(run.title).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text("#\(run.number)")
                        if !run.triggerLabel.isEmpty { Text("· \(run.triggerLabel)") }
                        if let who = run.triggerUser?.displayName, run.trigger != "schedule" { Text("by \(who)") }
                        if let ref = run.prettyRef { Text(ref).font(.system(size: 11.5, design: .monospaced)) }
                        if let took = run.duration { Text("· \(took)").monospacedDigit() }
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer()
                Badge(text: run.state.label, color: run.state.color)
            }
            .padding(12)
            if !jobs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(jobs) { job in
                            Button { chosen = job.id } label: {
                                HStack(spacing: 5) {
                                    CheckIcon(state: job.state, size: 11)
                                    Text(job.name).lineLimit(1)
                                }
                            }
                            .buttonStyle(ChipButtonStyle())
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(watched?.id == job.id ? Theme.blue : .clear))
                            .disabled(!job.hasStarted)
                            .help(job.hasStarted ? "Show this job's log" : "Not started yet")
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 10)
            }
            HLine()
            if let job = watched, let slug = model.slug(repo) {
                LogPane(target: LogTarget(repo: slug, runID: run.id, jobID: job.id, title: job.name, webURL: job.htmlURL))
                    .id(job.id)
                    .frame(height: 300)
            } else {
                HStack(spacing: 8) {
                    Spinner(color: run.state.color)
                    Text(run.state == .waiting ? "Waiting for a runner…" : "Starting…").foregroundStyle(Theme.secondary)
                }
                .padding(12)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(run.state.color.opacity(0.5)))
    }
}
