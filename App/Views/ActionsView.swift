import SwiftUI

/// The repository's Actions, as on the server: the workflows it defines
/// (with a button to start the ones that allow it), their runs, and for a
/// run its jobs, log, re-run and cancel.
struct ActionsView: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let forge: RepoForge
    /// The file of the workflow whose runs are listed; nil lists all.
    @State private var workflow: String?
    @State private var selected: WorkflowRun.ID?
    @State private var filter: RunFilter = .all
    @State private var jobs: [WorkflowJob] = []
    @State private var jobsError: String?
    @State private var target: LogTarget?
    @State private var working = false

    private var workflows: [Workflow] {
        model.slug(repo).flatMap { model.workflows[$0.key] } ?? []
    }

    enum RunFilter: Hashable { case all, failed, running }

    /// The runs of the workflow chosen, before the state filter.
    private var allRuns: [WorkflowRun] {
        guard let workflow else { return forge.runs }
        return forge.runs.filter { $0.workflowID == workflow }
    }

    private var runs: [WorkflowRun] {
        switch filter {
        case .all: allRuns
        case .failed: allRuns.filter { $0.state == .failure }
        case .running: allRuns.filter { !$0.state.isFinished }
        }
    }

    private var current: WorkflowRun? {
        runs.first { $0.id == selected } ?? runs.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ResizableColumn(key: "runList", initial: 380, range: 280...720) {
                VStack(spacing: 0) {
                    workflowList
                    HLine()
                    runList
                }
            }
            VStack(spacing: 0) {
                if let run = current {
                    runHeader(run)
                    HLine()
                    jobBar(run)
                    HLine()
                    if let target {
                        LogPane(target: target)
                    } else if let jobsError {
                        EmptyState("Cannot read the jobs", symbol: "wifi.exclamationmark", message: jobsError)
                    } else {
                        EmptyState("Select a job to see its log", symbol: "text.alignleft")
                    }
                } else {
                    EmptyState("No runs", symbol: "play.circle", message: workflow == nil ? "Runs of the repository's workflows appear here." : "This workflow has not run yet.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadWorkflows(repo) }
        // Reload the jobs when another run is picked, and while the run is
        // changing state (its status is part of the task's identity).
        .task(id: JobsKey(run: current?.id, status: current?.status)) {
            await loadJobs()
        }
    }

    private struct JobsKey: Hashable {
        var run: Int?
        var status: String?
    }

    // MARK: Workflows

    private var workflowList: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("WORKFLOWS").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.tertiary)
                Spacer()
                ActionSettingsButton(repo: repo)
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            workflowRow(title: "All workflows", file: nil, item: nil)
            ForEach(workflows) { item in
                workflowRow(title: item.title, file: item.file, item: item)
            }
        }
        .padding(8)
        .padding(.top, 4)
    }

    private func workflowRow(title: String, file: String?, item: Workflow?) -> some View {
        let latest = file.flatMap { name in forge.runs.first { $0.workflowID == name } }
        return HStack(spacing: 8) {
            Button {
                workflow = file
                selected = nil
            } label: {
                HStack(spacing: 8) {
                    if let latest {
                        CheckIcon(state: latest.state, size: 12)
                    } else {
                        Image(systemName: file == nil ? "square.stack" : "circle.dashed")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).frame(width: 15, height: 15)
                    }
                    Text(title).lineLimit(1)
                    if let file, title != file {
                        Text(file).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let item, item.info?.dispatch == true {
                Button("Run", systemImage: "play.fill") { model.sheet = .dispatch(repo, item) }
                    .buttonStyle(ChipButtonStyle())
                    .needsWrite()
                    .help("Start this workflow by hand")
                    .padding(.trailing, 4)
            }
        }
        .hoverBackground(selected: workflow == file)
    }

    // MARK: Runs

    private var runList: some View {
        VStack(spacing: 0) {
            // What went wrong, or what is going on now, without scrolling for it.
            HStack {
                Segments(options: [(RunFilter.all, "All \(allRuns.count)"), (.failed, "Failed \(allRuns.count { $0.state == .failure })"),
                                   (.running, "Running \(allRuns.count { !$0.state.isFinished })")], selection: $filter)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.top, 8)
            if runs.isEmpty {
                EmptyState(filter == .all ? "No runs" : filter == .failed ? "Nothing failed" : "Nothing is running", symbol: "play.circle")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(runs) { run in
                            Button {
                                selected = run.id
                            } label: {
                                RunRow(run: run, workflow: model.workflowName(run, in: repo))
                            }
                            .buttonStyle(.plain)
                            .hoverBackground(selected: current?.id == run.id)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private func runHeader(_ run: WorkflowRun) -> some View {
        HStack(spacing: 8) {
            CheckIcon(state: run.state)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(run.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("#\(run.number)").foregroundStyle(Theme.tertiary)
                }
                // Who, why, where, how long: the questions a red run raises.
                HStack(spacing: 6) {
                    Text(run.state.label).foregroundStyle(run.state.color)
                    if let took = run.duration { Text(run.state.isFinished ? "in \(took)" : "for \(took)").monospacedDigit() }
                    if !run.triggerLabel.isEmpty { Text("· \(run.triggerLabel)") }
                    if let who = run.triggerUser?.displayName, run.trigger != "schedule" { Text("by \(who)") }
                    if let ref = run.prettyRef { Text(ref).font(.system(size: 11.5, design: .monospaced)).lineLimit(1) }
                    if let sha = run.commitSHA { Text(String(sha.prefix(7))).font(.system(size: 11.5, design: .monospaced)) }
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            if run.state.isFinished {
                Button(model.supportsRerun(model.workspace?.host) ? "Re-run" : "Re-run in Browser", systemImage: "arrow.clockwise") { act(.rerun, run) }
                    .buttonStyle(ChipButtonStyle(prominent: run.state == .failure))
                    .needsWrite()
                    .disabled(working)
                    .help(model.supportsRerun(model.workspace?.host) ? "Run all jobs of this run again" : "Forgejo 16 has no re-run in its API: opens the run in the browser")
            } else {
                Button("Cancel", systemImage: "stop.fill") { act(.cancel, run) }
                    .buttonStyle(ChipButtonStyle())
                    .needsWrite()
                    .disabled(working)
            }
            if let url = run.htmlURL.flatMap(URL.init) {
                Button("Open in Browser", systemImage: "arrow.up.right.square") { openExternal(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private func act(_ action: AppModel.RunAction, _ run: WorkflowRun) {
        working = true
        Task {
            await model.perform(action, on: run, in: repo)
            await loadJobs()
            working = false
        }
    }

    private func jobBar(_ run: WorkflowRun) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(jobs) { job in
                    Button {
                        open(job, run: run)
                    } label: {
                        HStack(spacing: 5) {
                            CheckIcon(state: job.state, size: 12)
                            Text(job.name)
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(target?.jobID == job.id ? Theme.blue : .clear))
                    .contextMenu {
                        Button("Re-run This Job") {
                            Task {
                                await model.rerun(job, in: repo)
                                await loadJobs()
                            }
                        }
                    }
                }
                if jobs.isEmpty, jobsError == nil { ProgressView().controlSize(.small) }
                if let failed = jobs.first(where: { $0.state == .failure }), jobs.count > 1 {
                    Button("Re-run failed job", systemImage: "arrow.clockwise") {
                        Task {
                            await model.rerun(failed, in: repo)
                            await loadJobs()
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .help("Run \(failed.name) again")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
    }

    private func open(_ job: WorkflowJob, run: WorkflowRun) {
        guard let slug = model.slug(repo) else { return }
        target = LogTarget(repo: slug, runID: run.id, jobID: job.id, title: "\(run.title) · \(job.name)", webURL: job.htmlURL)
    }

    private func loadJobs() async {
        guard let run = current, let slug = model.slug(repo), let client = model.client(for: slug.host) else {
            jobs = []
            target = nil
            return
        }
        if jobs.first?.runID != run.id {
            jobs = []
            target = nil
        }
        do {
            jobs = try await client.jobs(slug, run: run.id)
            jobsError = nil
            // Show a log straight away: the failed job, else the key one,
            // else the only one.
            // A job that only calls another workflow has nothing to print:
            // the key job that failed is where the answer is.
            if target == nil, let job = jobs.first(where: { $0.state == .failure && model.isKey($0) && $0.hasStarted })
                ?? jobs.first(where: { $0.state == .failure && $0.hasStarted && !($0.runsOn ?? []).isEmpty })
                ?? jobs.first(where: { $0.state == .failure && $0.hasStarted })
                ?? jobs.first(where: { model.isKey($0) && $0.hasStarted }) ?? (jobs.count == 1 ? jobs.first : nil) {
                open(job, run: run)
            }
        } catch is CancellationError {
        } catch {
            jobsError = error.localizedDescription
        }
    }
}

struct RunRow: View {
    let run: WorkflowRun
    var workflow: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CheckIcon(state: run.state).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title).lineLimit(1).truncationMode(.tail)
                // What ran and where.
                HStack(spacing: 6) {
                    Text("#\(run.number)").monospacedDigit()
                    if let workflow = workflow ?? run.workflowID { Text(workflow).lineLimit(1) }
                    if let ref = run.prettyRef { Text(ref).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                // Why, who, when, how long.
                HStack(spacing: 6) {
                    if !run.triggerLabel.isEmpty { Text(run.triggerLabel) }
                    if let who = run.triggerUser?.displayName, run.trigger != "schedule" { Text("· \(who)").lineLimit(1) }
                    Spacer(minLength: 4)
                    if let when = run.started ?? run.created { Text(when.relative) }
                    if let took = run.duration { Text(took).monospacedDigit().foregroundStyle(Theme.secondary) }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help("\(run.title)\n#\(run.number) · \(run.triggerLabel)\(run.prettyRef.map { " · \($0)" } ?? "")")
    }
}

// MARK: - Inbox

