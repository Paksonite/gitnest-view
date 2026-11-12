import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var dropdowns = DropdownCenter()

    // Split in parts: as one expression the body is more than older
    // compilers type-check in reasonable time.
    var body: some View {
        stage
            .modifier(WindowLayers())
            .task { await launchSwitches() }
            .coordinateSpace(name: dropdownSpace)
            .environment(dropdowns)
            .background(Theme.window)
            .foregroundStyle(Theme.text)
            .font(.system(size: 13))
            .ignoresSafeArea()
    }

    /// The app itself, or the welcome before it is set up.
    @ViewBuilder private var stage: some View {
        if model.isSetUp, !model.wizardOpen {
            HStack(spacing: 0) {
                ResizableColumn(key: "sidebar", initial: 264, range: 220...460) { SidebarView() }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            WelcomeFlow()
        }
    }

    /// What the environment asks for at launch: measuring, and (in debug
    /// builds) opening a screen to look at it.
    private func launchSwitches() async {
        #if DEBUG
        // Development and tests: the window on the main screen, whatever
        // screen the last session used (a screen that is off cannot be seen).
        let environment = ProcessInfo.processInfo.environment
        if environment["GNV_DEV_HOST"] != nil || environment["GNV_DEV_ONBOARDING"] != nil, let screen = NSScreen.main {
            try? await Task.sleep(for: .milliseconds(200))
            for window in NSApp.windows where window.canBecomeMain {
                let size = NSSize(width: min(1440, screen.visibleFrame.width - 40), height: min(880, screen.visibleFrame.height - 40))
                window.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                                       width: size.width, height: size.height), display: true)
            }
        }
        #endif
        // Measuring: walks the repositories like a user clicking down the
        // sidebar and prints timings (GNV_TRACE). Reads only.
        let env = ProcessInfo.processInfo.environment
        if let cycle = env["GNV_DEV_CYCLE"] {
            Task {
                try? await Task.sleep(for: .seconds(Double(env["GNV_DEV_CYCLE_WAIT"] ?? "") ?? 8))
                Trace.watchMainThread()
                Trace.note("cycle: \(model.repos.count) repositories")
                let count = Int(cycle) ?? 6
                let step = max(1, model.repos.count / max(1, count))
                let picked = stride(from: 0, to: model.repos.count, by: step).prefix(count).map { model.repos[$0] }
                for repo in picked {
                    Trace.begin("select \(repo.name)")
                    model.selection = repo.id
                    model.section = .repositories
                    DispatchQueue.main.async { Trace.note("main thread free again") }
                    try? await Task.sleep(for: .seconds(4))
                }
                for repo in picked.prefix(4) {
                    Trace.begin("select again \(repo.name)")
                    model.selection = repo.id
                    DispatchQueue.main.async { Trace.note("main thread free again") }
                    try? await Task.sleep(for: .seconds(3))
                }
                Trace.begin("home")
                model.section = .home
                DispatchQueue.main.async { Trace.note("main thread free again") }
                try? await Task.sleep(for: .seconds(3))
                Trace.begin("back to a repository")
                model.section = .repositories
                DispatchQueue.main.async { Trace.note("main thread free again") }
                try? await Task.sleep(for: .seconds(3))
                Trace.begin("cycle done")
            }
        }
        #if DEBUG
        // Development switches (see AppModel.development()).
        if env["GNV_DEV_SECTION"] == "home" { model.section = .home }
        if env["GNV_DEV_SECTION"] == "inbox" { model.section = .inbox }
        if env["GNV_DEV_SECTION"] == "search" {
            model.searchText = env["GNV_DEV_QUERY"] ?? ""
            model.section = .search
        }
        if model.initialOpen == "palette" {
            try? await Task.sleep(for: .seconds(4))
            model.paletteOpen = true
        }
        if model.initialOpen == "releases" {
            try? await Task.sleep(for: .seconds(3))
            model.sheet = .releases
        }
        if model.initialOpen == "merge" {
            try? await Task.sleep(for: .seconds(4))
            if let repo = model.selectedRepo, let pull = model.forgeState(repo).pulls.first(where: { $0.state == "open" }) {
                model.sheet = .merge(repo, pull)
            }
        }
        if model.initialOpen == "file" {
            try? await Task.sleep(for: .seconds(4))
            if let repo = model.selectedRepo, let items = await model.resources(of: repo),
               let item = items.first(where: { $0.file.hasPrefix("zz_") && $0.kind == "resource" }) ?? items.first(where: { $0.kind == "resource" }) ?? items.first {
                model.fileTarget = FileTarget(repo: repo, file: item.file, line: item.line)
            }
        }
        if let key = ProcessInfo.processInfo.environment["GNV_DEV_TICKET"] {
            try? await Task.sleep(for: .seconds(4))
            model.ticketTarget = key
        }
        if model.initialOpen == "settings" {
            try? await Task.sleep(for: .seconds(2))
            openSettings()
        }
        if model.initialOpen == "pullall" {
            try? await Task.sleep(for: .seconds(4))
            model.sheet = .pullAll
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .home:
            HomeView().settleIn()
        case .inbox:
            InboxView().settleIn()
        case .search:
            SearchView().settleIn()
        case .repositories:
            if let repo = model.selectedRepo {
                RepoView(repo: repo).id(repo.id)
            } else if let error = model.reposError {
                EmptyState("Cannot read the repositories", symbol: "wifi.exclamationmark", message: error) {
                    Button("Try Again") { Task { await model.reload() } }.buttonStyle(ChipButtonStyle())
                }
            } else if model.loadingRepos || model.workspace == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState("No repositories", symbol: "shippingbox", message: "\(model.workspace?.title ?? "This workspace") has no repositories you can see.")
            }
        }
    }
}

/// Everything that opens over the window: forms, the palette, logs, diffs,
/// tickets, the tour, menus, questions, messages.
private struct WindowLayers: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(FormLayers())
            .overlay { LogModalLayer() }
            .overlay { DiffModalLayer() }
            .overlay { TourLayer() }
            .overlay { TicketModalLayer() }
            .overlay { DropdownLayer() }
            .overlay { ConfirmLayer() }
            .overlay(alignment: .bottom) { ToastLayer() }
    }
}

private struct FormLayers: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay { SheetLayer() }
            .overlay { CommandPalette() }
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                // Development: the menu bar panel drawn in the window, to look at it.
                if ProcessInfo.processInfo.environment["GNV_DEV_OPEN"] == "menubar" {
                    MenuBarView().clipShape(RoundedRectangle(cornerRadius: 10)).shadow(radius: 20).padding(40)
                }
            }
            #endif
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let reasons = model.attentionByRepo
        VStack(alignment: .leading, spacing: 0) {
            // The window's close, minimise and zoom buttons sit on the left.
            HStack {
                Spacer()
                Wordmark(size: 12.5)
            }
            .padding(.trailing, 14)
            .frame(height: 40)
            VStack(alignment: .leading, spacing: 8) {
                WorkspaceSwitcher()
                search
                VStack(spacing: 1) {
                    NavRow(title: "Home", symbol: "house", count: reasons.count, selected: model.section == .home) {
                        model.section = .home
                    }
                    NavRow(title: "Repositories", symbol: "books.vertical", selected: model.section == .repositories) {
                        model.section = .repositories
                    }
                    NavRow(title: "Inbox", symbol: "tray", count: model.inbox.count + model.myPulls.count, badge: true,
                           dot: model.unreadCount > 0, selected: model.section == .inbox) {
                        model.section = .inbox
                    }
                    NavRow(title: "Search", symbol: "text.magnifyingglass", selected: model.section == .search) {
                        model.section = .search
                    }
                    SettingsLink {
                        NavRowLabel(title: "Settings", symbol: "gearshape", count: 0)
                    }
                    .buttonStyle(.plain)
                    .hoverBackground()
                }
            }
            .padding(.horizontal, 10)

            HStack(spacing: 6) {
                Text("REPOSITORIES").font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                Text("\(model.shownRepos.count)").font(.system(size: 11)).monospacedDigit()
                Spacer()
                if model.fetchingAll {
                    ProgressView().controlSize(.mini)
                } else {
                    sidebarButton("Fetch all", "arrow.clockwise") { Task { await model.fetchAllReporting() } }
                }
                sidebarButton("Pull all…", "arrow.down.circle") { model.sheet = .pullAll }
                sidebarButton(model.sidebarByAttention ? "Order: what needs attention first" : "Order: by name",
                              model.sidebarByAttention ? "exclamationmark.circle" : "textformat") {
                    model.sidebarByAttention.toggle()
                }
            }
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    let prefixes = RepoName.sharedPrefixes(model.repos.map(\.name))
                    let groups = model.sidebarGroups(reasons)
                    let pinned = model.pinnedRepos
                    if !pinned.isEmpty {
                        groupHeader("Pinned", pinned.count)
                        ForEach(pinned) { repo in row(repo, prefixes, reasons, quiet: false) }
                    }
                    if let urgent = groups.attention, !urgent.isEmpty {
                        groupHeader("Needs attention", urgent.count)
                        ForEach(urgent) { repo in row(repo, prefixes, reasons, quiet: false) }
                        groupHeader("Everything else", groups.rest.count)
                    }
                    ForEach(groups.rest) { repo in row(repo, prefixes, reasons, quiet: groups.attention != nil) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .overlay {
                if model.repos.isEmpty, model.loadingRepos { ProgressView().controlSize(.small) }
            }

            if let offline = model.offline {
                HLine()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "wifi.slash").foregroundStyle(Theme.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline").font(.system(size: 11.5, weight: .semibold))
                        Text(offline).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(3)
                        Text("Clones work as usual; pull requests and pipelines come back with the server.")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
            if let notice = model.engineError {
                HLine()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.red)
                    Text(notice).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(4)
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
        }
        .background(Theme.sidebar)
    }

    /// A row gets plain values, so it is drawn again only when one of them
    /// changes: with hundreds of repositories nothing else stays quick.
    private func row(_ repo: ForgeRepo, _ prefixes: Set<String>, _ reasons: [ForgeRepo.ID: [AttentionReason]], quiet: Bool) -> some View {
        let key = model.slug(repo)?.key ?? ""
        return RepoRow(repo: repo, name: RepoName.split(repo.name, prefixes: prefixes), cloned: model.local[key] != nil,
                       latest: model.forge[key]?.latest, reasons: reasons[repo.id] ?? [], cloning: model.cloning.contains(key),
                       selected: model.selection == repo.id && model.section == .repositories, quiet: quiet, pinned: model.isPinned(repo))
            .equatable()
    }

    private func sidebarButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .help(title)
    }

    private func groupHeader(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text("\(count)").font(.system(size: 11)).monospacedDigit()
            Spacer()
        }
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// Opens the command palette: jump to a repository, pull request,
    /// branch or workflow, or run a command.
    private var search: some View {
        Button {
            model.paletteOpen = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                Text("Search or run…").foregroundStyle(Theme.tertiary)
                Spacer()
                Text("⌘K")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k")
    }
}

struct WorkspaceSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let title = model.workspace?.title ?? "No workspace"
        Dropdown(id: "workspace", width: 244, autoOpen: model.initialOpen == "workspace") {
            HStack(spacing: 8) {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Theme.purple, in: RoundedRectangle(cornerRadius: 5))
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
        } content: {
            WorkspaceList()
        }
        .help(model.workspace.map { "\($0.title) on \($0.host)" } ?? "")
    }
}

/// The open workspace menu: organisations by server, then actions.
struct WorkspaceList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.accounts) { account in
            DropdownHeader(text: account.host)
            ForEach(model.workspaces.filter { $0.host == account.host }) { workspace in
                DropdownItem(
                    title: workspace.title,
                    symbol: workspace.personal ? "person" : "building.2",
                    detail: workspace.personal ? "personal" : nil,
                    checked: workspace.id == model.workspace?.id
                ) {
                    model.select(workspace)
                }
            }
        }
        DropdownDivider()
        DropdownItem(title: "Get all repositories…", symbol: "square.and.arrow.down.on.square") { model.sheet = .getAll }
        DropdownItem(title: "Reload", symbol: "arrow.clockwise") { Task { await model.reload() } }
    }
}

struct NavRowLabel: View {
    let title: String
    let symbol: String
    let count: Int
    /// The count drawn as a filled badge: things wait there.
    var badge = false
    /// Something new since the user last looked.
    var dot = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(Theme.secondary)
            Text(title)
            Spacer()
            if dot { Circle().fill(Theme.blue).frame(width: 6, height: 6).help("New since you last looked") }
            if count > 0, badge {
                Text("\(count)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white).monospacedDigit()
                    .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                    .background(Theme.orange, in: Capsule())
                    .help("\(count) waiting: reviews asked of you and your open pull requests")
            } else if count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

struct NavRow: View {
    let title: String
    let symbol: String
    var count = 0
    var badge = false
    var dot = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NavRowLabel(title: title, symbol: symbol, count: count, badge: badge, dot: dot)
        }
        .buttonStyle(.plain)
        .hoverBackground(selected: selected)
    }
}

/// Splits repository names like "org-core-dns" into the part shared with
/// their neighbours ("org-core-") and the part that tells them apart.
enum RepoName {
    static func sharedPrefixes(_ names: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for name in names {
            if let prefix = prefix(of: name) { counts[prefix, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    /// The first two dash-separated words, when more follow.
    static func prefix(of name: String) -> String? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return parts[0] + "-" + parts[1] + "-"
    }

    static func split(_ name: String, prefixes: Set<String>) -> (dim: String, rest: String) {
        guard let prefix = prefix(of: name), prefixes.contains(prefix) else { return ("", name) }
        return (prefix, String(name.dropFirst(prefix.count)))
    }
}

struct RepoRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let name: (dim: String, rest: String)
    let cloned: Bool
    let latest: CheckState?
    let reasons: [AttentionReason]
    let cloning: Bool
    let selected: Bool
    /// Drawn dimmer: nothing to do here.
    let quiet: Bool
    let pinned: Bool
    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>?

    nonisolated static func == (a: RepoRow, b: RepoRow) -> Bool {
        a.repo == b.repo && a.name == b.name && a.cloned == b.cloned && a.latest == b.latest && a.reasons == b.reasons
            && a.cloning == b.cloning && a.selected == b.selected && a.quiet == b.quiet && a.pinned == b.pinned
    }

    // The model is read only in actions: a row must not redraw with it.
    var body: some View {
        Button {
            Trace.begin("select \(repo.name)")
            model.selection = repo.id
            model.section = .repositories
        } label: {
            HStack(spacing: 9) {
                StatusDot(state: latest)
                (Text(name.dim).foregroundStyle(Theme.secondary)
                    + Text(name.rest).foregroundStyle(cloned ? Theme.text : Theme.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                AttentionBadges(reasons: reasons)
                if let pulls = repo.openPulls, pulls > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.pull").font(.system(size: 9))
                        Text("\(pulls)").font(.system(size: 11)).monospacedDigit()
                    }
                    .foregroundStyle(Theme.secondary)
                    .help("\(pulls) open pull requests")
                }
                if cloning {
                    ProgressView().controlSize(.mini)
                } else if !cloned, hovering, repo.empty != true {
                    Button("Clone", systemImage: "arrow.down.circle") { Task { await model.clone(repo) } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                        .help("Clone into the working directory")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(quiet && !hovering && !selected ? 0.62 : 1)
        .hoverBackground(selected: selected)
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            guard inside else { return }
            // A pointer that rests here is likely to click: read ahead.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled { model.prefetch(repo) }
            }
        }
        .help(reasons.isEmpty ? repo.name : reasons.map { "\(AttentionBadges.look($0)): \(AttentionBadges.meaning($0))" }.joined(separator: "\n"))
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin to the Top") { model.togglePin(repo) }
            Divider()
            if cloned {
                Button("Show in Finder") {
                    if let clone = model.clone(of: repo) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clone.path)]) }
                }
            } else {
                Button("Clone") { Task { await model.clone(repo) } }
            }
            if let url = repo.htmlURL.flatMap(URL.init) {
                Button("Open in Browser") { openExternal(url) }
            }
        }
    }
}

/// Small marks after a repository's name: what needs doing there.
struct AttentionBadges: View {
    let reasons: [AttentionReason]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(reasons, id: \.self) { reason in
                badge(reason).help(Self.meaning(reason))
            }
        }
    }

    /// What a mark looks like, so a tooltip can say which one it explains.
    static func look(_ reason: AttentionReason) -> String {
        switch reason {
        case .conflict: "Red triangle"
        case .failedMain: "Red ✕"
        case .scheduledFailing: "Orange clock"
        case .myPullFailing: "Red pull request"
        case .myPullChanges: "Orange speech bubble"
        case .myPullReady: "Green seal"
        case .reviewRequested: "Orange eye"
        case .diverged: "↑↓ in red"
        case .behind: "↓"
        case .ahead: "↑"
        case .changes: "Orange dot"
        }
    }

    /// What a mark says, in words.
    static func meaning(_ reason: AttentionReason) -> String {
        switch reason {
        case .conflict: "A merge or rebase stopped on conflicts in the clone: finish or abort it in Changes"
        case .failedMain(let workflow): "\(workflow) failed on the default branch"
        case .scheduledFailing(let workflow): "The scheduled \(workflow) failed (drift detection found something)"
        case .myPullFailing(let number): "The pipeline of your pull request #\(number) fails"
        case .myPullChanges(let number): "A reviewer asks for changes in your pull request #\(number)"
        case .myPullReady(let number): "Your pull request #\(number) is approved and its checks pass: ready to merge"
        case .reviewRequested(let count): count == 1 ? "Someone asks for your review here" : "\(count) pull requests wait for your review here"
        case .diverged(let ahead, let behind): "The clone and the server went different ways: \(ahead) to push, \(behind) to pull"
        case .behind(let n): "\(n) \(n == 1 ? "commit" : "commits") on the server that the clone does not have: pull"
        case .ahead(let n): "\(n) \(n == 1 ? "commit" : "commits") in the clone that are not on the server: push"
        case .changes(let n): "\(n) uncommitted \(n == 1 ? "change" : "changes") in the clone"
        }
    }

    @ViewBuilder private func badge(_ reason: AttentionReason) -> some View {
        switch reason {
                case .conflict:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.red)
                case .failedMain:
                    Image(systemName: "xmark.octagon.fill").font(.system(size: 9.5)).foregroundStyle(Theme.red)
                case .scheduledFailing:
                    Image(systemName: "clock.badge.exclamationmark.fill").font(.system(size: 9.5)).foregroundStyle(Theme.orange)
                case .myPullFailing:
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.red)
                case .myPullChanges:
                    Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 9.5)).foregroundStyle(Theme.orange)
                case .myPullReady:
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 9.5)).foregroundStyle(Theme.green)
                case .reviewRequested(let count):
                    HStack(spacing: 1) {
                        Image(systemName: "eye.fill").font(.system(size: 8.5))
                        if count > 1 { Text("\(count)").font(.system(size: 10.5)).monospacedDigit() }
                    }
                    .foregroundStyle(Theme.orange)
                case .diverged(let ahead, let behind):
                    Text("↑\(ahead)↓\(behind)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.red)
                case .behind(let n):
                    Text("↓\(n)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.purple)
                case .ahead(let n):
                    Text("↑\(n)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.blue)
        case .changes:
            Text("●").font(.system(size: 8)).foregroundStyle(Theme.orange)
        }
    }
}
