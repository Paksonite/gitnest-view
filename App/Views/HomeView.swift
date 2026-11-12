import Charts
import SwiftUI

/// The start screen, like gitnest's dashboard: what needs the user across
/// the workspace, their pull requests and reviews, and recent activity.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var activity: [ActivityCommit] = []
    @State private var loaded = false
    @State private var showCommits = false
    private let days = 14

    var body: some View {
        // Read once: every card below asks for it, and it walks all repositories.
        let todo = model.todo

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Home").font(.system(size: 14, weight: .semibold))
                Text(model.workspace.map { "\($0.title) · \($0.host)" } ?? "").foregroundStyle(Theme.secondary)
                Spacer()
                Button("Fetch All", systemImage: "arrow.clockwise") { Task { await model.fetchAllReporting(); await load() } }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(model.fetchingAll)
                Button("Pull All…", systemImage: "arrow.down.circle") { model.sheet = .pullAll }
                    .buttonStyle(ChipButtonStyle())
                Button("Releases…", systemImage: "paperplane") { model.sheet = .releases }
                    .buttonStyle(ChipButtonStyle())
                    .help("What waits on develop in every repository")
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 48)
            HLine()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tiles(todo)
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) {
                            todoCard(todo)
                            workCard
                            myPullsCard
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 14) {
                            if model.jiraSettings != nil {
                                // With Jira the tickets lead; the commits fold away below.
                                JiraCard()
                                DisclosureGroup("Recent commits", isExpanded: $showCommits) {
                                    VStack(spacing: 14) { activityCard; activeCard; latestCard }.padding(.top, 10)
                                }
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                            } else {
                                activityCard
                                activeCard
                                latestCard
                            }
                        }
                        .frame(width: 400)
                    }
                }
                .padding(16)
            }
        }
        .task(id: model.repos.count) { await load() }
    }

    private func load() async {
        activity = await model.activity(days: days)
        loaded = true
    }

    // MARK: Tiles

    private func tiles(_ todo: [TodoItem]) -> some View {
        let clones = model.repos.compactMap { repo in model.clone(of: repo).map { (repo, $0) } }
        let failing = model.myPulls.filter { $0.state == .failure }.count
        let behind = clones.filter { $0.1.behind > 0 }
        let dirty = clones.filter { $0.1.changes > 0 }
        return HStack(spacing: 12) {
            tile("To do", todo.count, note: todo.isEmpty ? "nothing waits" : "steps that wait for you", todo.isEmpty ? Theme.green : Theme.orange, "checklist",
                 help: "Everything listed below under To do")
            tile("Reviews for you", model.inbox.count, note: "pull requests asking for your review", Theme.orange, "eye",
                 help: "Show them in the Inbox") { model.section = .inbox }
            tile("Your pull requests", model.myPulls.count, note: failing > 0 ? "\(failing) with a failing pipeline" : "open, none failing",
                 noteColor: failing > 0 ? Theme.red : nil, failing > 0 ? Theme.red : Theme.text, "arrow.triangle.pull",
                 help: "Show them in the Inbox") { model.section = .inbox }
            tile("To pull", behind.count, note: "clones behind the server", Theme.purple, "arrow.down",
                 help: "Open Pull All") { model.sheet = .pullAll }
            tile("Uncommitted", dirty.count, note: "clones with changes", Theme.orange, "pencil",
                 help: dirty.isEmpty ? "No clone has uncommitted changes" : "Show the changes in \(dirty[0].0.name)") {
                guard let first = dirty.first else { return }
                model.selection = first.0.id
                model.section = .repositories
                model.repoTab = .changes
            }
        }
    }

    /// A number with what it counts; a click goes where it can be dealt with.
    private func tile(_ title: String, _ value: Int, note: String, noteColor: Color? = nil, _ color: Color, _ symbol: String,
                      help: String, action: (() -> Void)? = nil) -> some View {
        HomeTile(title: title, value: value, note: note, noteColor: noteColor, color: color, symbol: symbol, help: help, action: action)
    }

    // MARK: Left column

    /// One line per step that waits for the user, each with its one button.
    private func todoCard(_ todo: [TodoItem]) -> some View {
        Card("To do") {
            Text("\(todo.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        } content: {
            if todo.isEmpty {
                Label("Nothing waits for you in \(model.workspace?.title ?? "this workspace").", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.green)
            }
            VStack(spacing: 0) {
                ForEach(todo) { item in
                    HStack(spacing: 10) {
                        Button { show(item) } label: {
                            HStack(spacing: 8) {
                                TodoIcon(item: item).frame(width: 34, alignment: .leading)
                                Text(item.title).lineLimit(1)
                                Text(item.detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                                if model.accounts.count > 1, let host = item.host { ServerChip(host: host) }
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        quickAction(item)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 32)
                    .hoverBackground(radius: 5)
                }
            }
            .padding(.horizontal, -6)
        }
    }

    /// A click on the line shows what it is about.
    private func show(_ item: TodoItem) {
        switch item.action {
        case .review(let entry): Task { await model.open(entry) }
        case .merge(let pull), .failing(let pull), .changes(let pull):
            Task { await model.openPull(host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL) }
        case .ticket(let issue):
            model.ticketTarget = issue.key
        case .repo(let repo, _):
            model.selection = repo.id
            model.section = .repositories
        }
    }

    /// The one button that deals with the step.
    @ViewBuilder private func quickAction(_ item: TodoItem) -> some View {
        switch item.action {
        case .review(let entry):
            Button("Review…") {
                guard let fullName = entry.hit.repository?.fullName else { return }
                Task { await model.openPull(host: entry.host, fullName: fullName, number: entry.hit.number, url: entry.hit.htmlURL, then: .review) }
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
        case .merge(let pull):
            Button("Merge…") {
                Task { await model.openPull(host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL, then: .merge) }
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
        case .failing(let pull):
            Button("Run Again") { Task { await model.rerunFailed(pull) } }.buttonStyle(ChipButtonStyle())
                .help("Run the failed pipelines again")
        case .changes:
            Button("Open") { show(item) }.buttonStyle(ChipButtonStyle())
        case .repo(let repo, let reason):
            repoAction(repo, reason)
        case .ticket(let issue):
            Button("Start Work") {
                model.startWorkName = "chore/\(issue.key)"
                model.sheet = .startWork(preselected: nil)
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    @ViewBuilder private func repoAction(_ repo: ForgeRepo, _ reason: AttentionReason) -> some View {
        switch reason {
        case .behind:
            Button("Pull") { Task { await model.run(.pull, on: repo) } }.buttonStyle(ChipButtonStyle())
        case .ahead:
            Button("Push") { Task { await model.push(repo) } }.buttonStyle(ChipButtonStyle())
        case .changes, .conflict, .diverged:
            Button(reason.rank == AttentionReason.changes(0).rank ? "Commit…" : "Resolve") {
                model.selection = repo.id
                model.section = .repositories
                model.repoTab = .changes
            }
            .buttonStyle(ChipButtonStyle())
        case .failedMain:
            Button("Log") {
                Task {
                    model.selection = repo.id
                    model.section = .repositories
                    let branch = repo.defaultBranch ?? "main"
                    if let run = model.forgeState(repo).runs.first(where: { $0.prettyRef == branch && $0.trigger != "pull_request" }) {
                        await model.openLog(run: run, in: repo)
                    }
                }
            }
            .buttonStyle(ChipButtonStyle())
        case .scheduledFailing:
            Button("Log") {
                Task {
                    model.selection = repo.id
                    model.section = .repositories
                    if let run = AppModel.scheduledRuns(model.forgeState(repo).runs).first(where: { $0.state == .failure }) {
                        await model.openLog(run: run, in: repo)
                    }
                }
            }
            .buttonStyle(ChipButtonStyle())
        case .myPullChanges, .myPullReady, .myPullFailing, .reviewRequested:
            EmptyView()
        }
    }

    /// Feature branches checked out now, across repositories.
    private var workCard: some View {
        let work = model.workInProgress
        return Card("Work in progress") {
            Button("Start Work…", systemImage: "plus") { model.sheet = .startWork(preselected: model.selection) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.blue)
                .help("One branch in several repositories")
        } content: {
            if work.isEmpty {
                Text("No feature branch is checked out. Start one in several repositories at once with Start Work.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            ForEach(work) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Text(item.branch).font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 4)
                        let unpushed = item.items.contains { !$0.clone.hasUpstream || $0.clone.ahead > 0 }
                        if unpushed {
                            Button("Push All") { Task { await model.pushAll(item) } }.buttonStyle(ChipButtonStyle())
                        }
                        Button("Pull Requests…") { model.sheet = .openPulls(branch: item.branch) }
                            .buttonStyle(ChipButtonStyle())
                    }
                    HStack(spacing: 6) {
                        ForEach(item.items, id: \.repo.id) { entry in
                            Button {
                                model.selection = entry.repo.id
                                model.section = .repositories
                                model.repoTab = .changes
                            } label: {
                                HStack(spacing: 4) {
                                    Text(entry.repo.name).lineLimit(1)
                                    LocalState(repo: entry.clone)
                                    if !entry.clone.hasUpstream {
                                        Image(systemName: "icloud.slash").font(.system(size: 9)).foregroundStyle(Theme.tertiary).help("Not on the server yet")
                                    }
                                }
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var myPullsCard: some View {
        Card("Your pull requests") {
            if model.myPulls.isEmpty { Text("None open.").foregroundStyle(Theme.secondary) }
            ForEach(model.myPulls) { pull in
                Button {
                    Task { await model.openPull(host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL) }
                } label: {
                    HStack(spacing: 8) {
                        CheckIcon(state: pull.state)
                        Text(pull.title).lineLimit(1)
                        if pull.changesRequested {
                            Badge(text: "changes requested", color: Theme.orange, filled: false)
                        } else if pull.ready {
                            Badge(text: "ready to merge", color: Theme.green, filled: false)
                        } else if pull.approvals > 0 {
                            Badge(text: "approved", color: Theme.green, filled: false)
                        }
                        Spacer(minLength: 4)
                        Text("\(pull.repoFullName.split(separator: "/").last ?? "") #\(pull.number)")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Right column

    private struct Day: Identifiable {
        var date: Date
        var count: Int
        var id: Date { date }
    }

    private var perDay: [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var counts: [Date: Int] = [:]
        for commit in activity {
            counts[calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(commit.unix))), default: 0] += 1
        }
        return (0..<days).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { Day(date: $0, count: counts[$0] ?? 0) }
        }
    }

    private var activityCard: some View {
        Card("Commits · last \(days) days") {
            Text("\(activity.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
        } content: {
            Chart(perDay) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Commits", day.count))
                    .foregroundStyle(Theme.brand.gradient)
                    .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel()
                }
            }
            .frame(height: 130)
            if loaded && activity.isEmpty {
                Text("No commits in the clones of this workspace lately.").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var activeCard: some View {
        let counts = Dictionary(grouping: activity, by: \.path).mapValues(\.count).sorted { $0.value > $1.value }.prefix(5)
        let top = counts.first?.value ?? 1
        return Card("Most active") {
            if counts.isEmpty { Text("—").foregroundStyle(Theme.tertiary) }
            ForEach(Array(counts), id: \.key) { path, count in
                let repo = model.forgeRepo(forClone: path)
                Button {
                    if let repo {
                        model.selection = repo.id
                        model.section = .repositories
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(repo?.name ?? (path as NSString).lastPathComponent).lineLimit(1).frame(width: 150, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2).fill(Theme.brand.opacity(0.7))
                                .frame(width: max(4, geo.size.width * CGFloat(count) / CGFloat(top)), height: 8)
                                .frame(maxHeight: .infinity)
                        }
                        Text("\(count)").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var latestCard: some View {
        Card("Latest commits") {
            if activity.isEmpty { Text("—").foregroundStyle(Theme.tertiary) }
            ForEach(activity.prefix(10), id: \.self) { commit in
                HStack(spacing: 8) {
                    Text(commit.short).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                    Text(commit.subject).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(model.forgeRepo(forClone: commit.path)?.name ?? "").font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                .help("\(commit.author) · \(Date(timeIntervalSince1970: TimeInterval(commit.unix)).relative)")
            }
        }
    }
}

private struct HomeTile: View {
    let title: String
    let value: Int
    let note: String
    let noteColor: Color?
    let color: Color
    let symbol: String
    let help: String
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(title, systemImage: symbol).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    if action != nil {
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.tertiary).opacity(hovering ? 1 : 0)
                    }
                }
                Text("\(value)").font(.system(size: 22, weight: .semibold)).foregroundStyle(value == 0 ? Theme.text : color).monospacedDigit()
                    .contentTransition(.numericText())
                Text(note).font(.system(size: 11)).foregroundStyle(noteColor ?? Theme.tertiary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && action != nil ? Theme.hover : Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(hovering && action != nil ? Theme.blue.opacity(0.45) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(help)
        .accessibilityLabel("\(title): \(value), \(note)")
    }
}

/// The sign in front of a to-do line.
private struct TodoIcon: View {
    let item: TodoItem

    var body: some View {
        switch item.action {
        case .review: Image(systemName: "eye.fill").font(.system(size: 10)).foregroundStyle(Theme.orange)
        case .merge: Image(systemName: "checkmark.seal.fill").font(.system(size: 10.5)).foregroundStyle(Theme.green)
        case .failing: Image(systemName: "arrow.triangle.pull").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.red)
        case .changes: Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 10)).foregroundStyle(Theme.orange)
        case .repo(_, let reason): AttentionBadges(reasons: [reason])
        case .ticket: Image(systemName: "ticket.fill").font(.system(size: 10)).foregroundStyle(Theme.blue)
        }
    }
}
