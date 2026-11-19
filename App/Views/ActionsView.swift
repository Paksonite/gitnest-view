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
                    // As on the server: the run on top, its jobs down the
                    // left, the chosen job's steps beside them.
                    runHeader(run)
                    HLine()
                    HStack(spacing: 0) {
                        ResizableColumn(key: "jobList", initial: 250, range: 190...460) {
                            jobList(run)
                        }
                        Group {
                            if let target {
                                LogPane(target: target, showsState: true)
                            } else if let jobsError {
                                EmptyState("Cannot read the jobs", symbol: "wifi.exclamationmark", message: jobsError)
                            } else {
                                EmptyState("Select a job to see its steps", symbol: "list.bullet.rectangle")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(alignment: .top, spacing: 10) {
            CheckIcon(state: run.state, size: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(run.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    .textSelection(.enabled)
                // What ran, and who or what started it.
                HStack(spacing: 5) {
                    if let sha = run.commitSHA {
                        Text("Commit")
                        Text(String(sha.prefix(10))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.blue)
                            .textSelection(.enabled)
                    }
                    Text(Self.started(run))
                    if let who = run.triggerUser?.displayName, run.trigger != "schedule" {
                        Text(who).foregroundStyle(Theme.orange)
                    }
                    Text("#\(run.number)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 5).frame(height: 17)
                        .background(Theme.border.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    if let ref = run.prettyRef {
                        Text(ref).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                // Which workflow; its other runs one click away.
                HStack(spacing: 5) {
                    Text("Workflow")
                    if let file = run.workflowID {
                        Text(file).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.orange)
                        Button("all runs") {
                            workflow = file
                            filter = .all
                            selected = run.id
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.blue)
                        .help("List only the runs of \(file)")
                    }
                    Text("·")
                    Text(run.state.label).foregroundStyle(run.state.color)
                    if let took = run.duration { Text(run.state.isFinished ? "in \(took)" : "for \(took)").monospacedDigit() }
                    if let when = run.started ?? run.created { Text("· \(when.relative)") }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if working { ProgressView().controlSize(.small).padding(.top, 4) }
            if run.state.isFinished {
                Button("Re-run all jobs", systemImage: "arrow.clockwise") { act(.rerun, run) }
                    .buttonStyle(ChipButtonStyle(prominent: run.state == .failure))
                    .needsWrite()
                    .disabled(working)
                    .fixedSize()
                    .help(model.supportsRerun(model.workspace?.host) ? "Run all jobs of this run again"
                          : "Run all jobs of this run again (through the server's web pages: Forgejo before 17 has no API for it)")
            } else {
                Button("Cancel", systemImage: "stop.fill") { act(.cancel, run) }
                    .buttonStyle(ChipButtonStyle())
                    .needsWrite()
                    .disabled(working)
                    .fixedSize()
            }
            if let url = run.htmlURL.flatMap(URL.init) {
                Button("Open in Browser", systemImage: "arrow.up.right.square") { openExternal(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 4)
                    .help("Open the run on the server")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// "pushed by", "started by": the words the server uses.
    private static func started(_ run: WorkflowRun) -> String {
        switch run.trigger {
        case "push": "pushed by"
        case "pull_request", "pull_request_target": "pull request by"
        case "schedule": "scheduled"
        case "workflow_dispatch": "started by"
        default: run.triggerLabel.isEmpty ? "by" : "\(run.triggerLabel) by"
        }
    }

    private func act(_ action: AppModel.RunAction, _ run: WorkflowRun) {
        working = true
        Task {
            await model.perform(action, on: run, in: repo)
            await loadJobs()
            working = false
        }
    }

    /// The run's jobs, one under another, each with its state, its time
    /// and a button to run it again.
    private func jobList(_ run: WorkflowRun) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(jobs) { job in jobRow(job, run: run) }
                if jobs.isEmpty, jobsError == nil {
                    ProgressView().controlSize(.small).padding(.top, 16)
                }
                if let failed = jobs.first(where: { $0.state == .failure }), jobs.count > 1, run.state.isFinished {
                    Button("Re-run failed job", systemImage: "arrow.clockwise") {
                        Task {
                            await model.rerun(failed, of: run, in: repo)
                            await loadJobs()
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .needsWrite()
                    .help("Run \(failed.name) again")
                    .padding(.top, 8)
                }
            }
            .padding(8)
        }
    }

    private func jobRow(_ job: WorkflowJob, run: WorkflowRun) -> some View {
        let chosen = target?.jobID == job.id
        return HStack(spacing: 8) {
            Button {
                open(job, run: run)
            } label: {
                HStack(spacing: 8) {
                    CheckIcon(state: job.state, size: 13)
                    Text(job.name).font(.system(size: 12.5, weight: chosen ? .semibold : .regular)).lineLimit(2)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 8)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if run.state.isFinished {
                Button("Re-run This Job", systemImage: "arrow.clockwise") {
                    Task {
                        await model.rerun(job, of: run, in: repo)
                        await loadJobs()
                    }
                }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                .needsWrite()
                .help("Run \(job.name) again")
            }
            Text(job.duration ?? "").font(.system(size: 11.5, weight: chosen ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(Theme.secondary).frame(minWidth: 30, alignment: .trailing)
                .padding(.trailing, 8)
        }
        .hoverBackground(selected: chosen)
        .contextMenu {
            Button("Re-run This Job") {
                Task {
                    await model.rerun(job, of: run, in: repo)
                    await loadJobs()
                }
            }
        }
    }

    private func open(_ job: WorkflowJob, run: WorkflowRun) {
        guard let slug = model.slug(repo) else { return }
        target = LogTarget(repo: slug, runID: run.id, jobID: job.id, title: job.name, webURL: job.htmlURL)
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
            let listed = try await client.jobs(slug, run: run.id)
            // The list keeps what is known of each job's steps (their times)
            // from the last read: no flicker while the details come.
            let known = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            jobs = listed.map { job in
                var job = job
                if job.steps == nil { job.steps = known[job.id]?.steps }
                return job
            }
            jobsError = nil
            // Forgejo lists jobs without their steps: read them for the times.
            let missing = listed.filter { $0.steps == nil && $0.hasStarted }
            if !missing.isEmpty {
                let details = await withTaskGroup(of: WorkflowJob?.self) { group in
                    for job in missing { group.addTask { try? await client.job(slug, id: job.id) } }
                    var found: [Int: WorkflowJob] = [:]
                    for await job in group { if let job { found[job.id] = job } }
                    return found
                }
                if jobs.first?.runID == run.id || jobs.first?.runID == nil {
                    jobs = jobs.map { job in
                        var job = job
                        if let steps = details[job.id]?.steps { job.steps = steps }
                        return job
                    }
                }
            }
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

