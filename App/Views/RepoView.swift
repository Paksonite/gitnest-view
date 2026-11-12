import SwiftUI

enum RepoTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case changes = "Changes"
    case history = "History"
    case resources = "Resources"
    case pulls = "Pull requests"
    case actions = "Actions"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .changes: "doc.badge.plus"
        case .history: "clock.arrow.circlepath"
        case .resources: "square.stack.3d.up"
        case .pulls: "arrow.triangle.pull"
        case .actions: "play.circle"
        }
    }
}

struct RepoView: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @Namespace private var tabPill

    private var tab: RepoTab {
        get { model.repoTab }
        nonmutating set { model.repoTab = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            RepoHeader(repo: repo)
            tabs
            HLine()
            content.frame(maxWidth: .infinity, maxHeight: .infinity).id(tab).settleIn()
        }
        .onChange(of: tab) { model.logTarget = nil }
        .onChange(of: model.pendingPull, initial: true) {
            // Overview and Pull requests both show the pull request; switching
            // between them here would race with the one that is showing it.
            if model.pendingPull != nil, tab != .overview, tab != .pulls { tab = .pulls }
        }
        .task {
            if let wanted = model.initialTab.flatMap({ name in RepoTab.allCases.first { $0.rawValue.lowercased().hasPrefix(name.lowercased()) } }) {
                tab = wanted
            }
            await model.refreshForge(repo, detailed: true, ifOlderThan: 8)
            if model.initialOpen == "release" {
                model.initialOpen = nil
                model.sheet = .release(repo)
            }
            if model.initialOpen == "dispatch" {
                model.initialOpen = nil
                await model.loadWorkflows(repo)
                let all = model.slug(repo).flatMap { model.workflows[$0.key] } ?? []
                if let workflow = all.first(where: { $0.info?.dispatch == true && !($0.info?.inputs.isEmpty ?? true) }) ?? all.first(where: { $0.info?.dispatch == true }) {
                    model.sheet = .dispatch(repo, workflow)
                }
            }
            if model.initialOpen == "log" {
                model.initialOpen = nil
                let runs = model.forgeState(repo).runs
                let wanted = ProcessInfo.processInfo.environment["GNV_DEV_WORKFLOW"]
                if let run = runs.first(where: { wanted != nil && $0.workflowID == wanted })
                    ?? runs.first(where: { $0.workflowID?.contains("terraform") == true && $0.state != .waiting }) ?? runs.first {
                    await model.openLog(run: run, in: repo)
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(RepoTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 12))
                        Text(item.rawValue).font(.system(size: 13, weight: tab == item ? .medium : .regular))
                        if item == .changes, let changes = model.clone(of: repo)?.changes, changes > 0 {
                            Text("\(changes)").font(.system(size: 11)).foregroundStyle(Theme.orange).monospacedDigit()
                        }
                        if item == .pulls, let count = repo.openPulls, count > 0 {
                            Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.secondary).monospacedDigit()
                        }
                    }
                    .foregroundStyle(tab == item ? Theme.text : Theme.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverBackground()
                .background {
                    // The marker slides from the tab left to the one chosen.
                    if tab == item {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.selected).matchedGeometryEffect(id: "tab", in: tabPill)
                    }
                }
            }
            Spacer()
        }
        .animation(Motion.snap, value: tab)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        let state = model.forgeState(repo)
        switch tab {
        case .changes: ChangesView(repo: repo)
        case .history: HistoryView(repo: repo)
        case .resources: ResourcesView(repo: repo)
        case .overview, .pulls:
            if model.offline != nil, !state.loaded {
                EmptyState("The server cannot be reached", symbol: "wifi.slash",
                           message: "Pull requests and pipelines come back with the server. The clone works as usual.") {
                    HStack(spacing: 8) {
                        Button("Changes") { model.repoTab = .changes }.buttonStyle(ChipButtonStyle(prominent: true))
                        Button("History") { model.repoTab = .history }.buttonStyle(ChipButtonStyle())
                    }
                }
            } else if let error = state.error, !state.loaded {
                EmptyState("Cannot read the pull requests", symbol: "wifi.exclamationmark", message: error)
            } else if !state.loaded {
                ProgressView().controlSize(.small)
            } else {
                PullBrowser(repo: repo, forge: state, overview: tab == .overview).id(tab)
            }
        case .actions:
            if !state.loaded {
                ProgressView().controlSize(.small)
            } else {
                ActionsView(repo: repo, forge: state).task { await model.wantRuns(repo) }
            }
        }
    }
}

/// The top line: the repository, its branch, and what can be done with the clone.
struct RepoHeader: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo

    var body: some View {
        let clone = model.clone(of: repo)
        let key = model.slug(repo)?.key ?? ""
        let working = model.busy.contains(key)
        let cloning = model.cloning.contains(key)

        HStack(spacing: 10) {
            Text(repo.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if repo.isPrivate == true {
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Theme.tertiary).help("Private")
            }
            if repo.archived == true { Badge(text: "Archived", color: Theme.yellow) }
            if let clone {
                BranchMenu(repo: repo, clone: clone)
                LocalState(repo: clone)
            } else if let branch = repo.defaultBranch {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(branch).font(.system(size: 12, design: .monospaced))
                }
                .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            if working || cloning { ProgressView().controlSize(.small) }
            if let clone {
                Button("Fetch", systemImage: "arrow.clockwise") { Task { await model.run(.fetch, on: repo) } }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(working)
                    .help("Fetch from the server")
                if clone.behind > 0 {
                    Button("Pull \(clone.behind)", systemImage: "arrow.down") { Task { await model.run(.pull, on: repo) } }
                        .buttonStyle(ChipButtonStyle(prominent: true))
                        .disabled(working)
                }
                Button("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right") { openClone(clone, in: .editor) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ChipButtonStyle())
                    .help("Open the clone in Visual Studio Code")
                Button("Open in Terminal", systemImage: "terminal") { openClone(clone, in: .terminal) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ChipButtonStyle())
                    .help("Open a terminal in the clone")
                Button("Show in Finder", systemImage: "folder") { openClone(clone, in: .finder) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ChipButtonStyle())
                    .help(clone.path)
            } else if repo.empty != true {
                Button(cloning ? "Cloning…" : "Clone", systemImage: "arrow.down.circle") { Task { await model.clone(repo) } }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(cloning)
                    .help("Clone into \(model.cloneDestination(repo) ?? "")")
            }
            if let url = repo.htmlURL.flatMap(URL.init) {
                Button("Open in Browser", systemImage: "safari") { openExternal(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ChipButtonStyle())
                    .help("Open on \(model.workspace?.host ?? "the server")")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 48)
    }
}

enum CloneOpener { case editor, terminal, finder }

/// Opens a clone where the work happens: the editor or a terminal next to
/// this app, or Finder.
@MainActor
func openClone(_ clone: Repo, in place: CloneOpener) {
    let folder = URL(fileURLWithPath: clone.path)
    let workspace = NSWorkspace.shared
    func open(with bundleIDs: [String]) -> Bool {
        for id in bundleIDs {
            guard let app = workspace.urlForApplication(withBundleIdentifier: id) else { continue }
            workspace.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return false
    }
    switch place {
    case .editor:
        if !open(with: ["com.microsoft.VSCode", "com.vscodium", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed"]) {
            workspace.activateFileViewerSelecting([folder])
        }
    case .terminal:
        _ = open(with: ["com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"])
    case .finder:
        workspace.activateFileViewerSelecting([folder])
    }
}

/// The current branch as a chip; the menu switches to another one.
struct BranchMenu: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let clone: Repo

    var body: some View {
        Dropdown(id: "branch", width: 300, autoOpen: model.initialOpen == "branch") {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Text(clone.detached ? "detached" : clone.branch).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        } content: {
            BranchOptions(repo: repo)
        }
        .fixedSize()
    }
}

/// The open branch menu: local branches, then the ones only on the server.
struct BranchOptions: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @State private var branches: BranchList?

    var body: some View {
        Group {
            if let branches {
                DropdownItem(title: "New branch…", symbol: "plus") {
                    model.sheet = .newBranch(repo, base: model.clone(of: repo)?.branch ?? "")
                }
                DropdownDivider()
                DropdownHeader(text: "Local")
                ForEach(branches.local) { branch in
                    DropdownItem(title: branch.name, detail: branch.updated, checked: branch.current, monospaced: true) {
                        if !branch.current { Task { await model.checkout(branch, in: repo) } }
                    }
                }
                let localNames = Set(branches.local.map(\.name))
                let remoteOnly = branches.remote.filter { branch in
                    guard let slash = branch.name.firstIndex(of: "/") else { return false }
                    let short = String(branch.name[branch.name.index(after: slash)...])
                    return short != "HEAD" && !localNames.contains(short)
                }
                if !remoteOnly.isEmpty {
                    DropdownHeader(text: "On the server")
                    ForEach(remoteOnly) { branch in
                        DropdownItem(title: branch.name, detail: branch.updated, monospaced: true) {
                            Task { await model.checkout(branch, in: repo) }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading branches…").foregroundStyle(Theme.secondary)
                }
                .padding(8)
            }
        }
        .task { branches = await model.branches(of: repo) }
    }
}

/// Uncommitted changes and how far the branch is from its upstream.
struct LocalState: View {
    let repo: Repo

    var body: some View {
        HStack(spacing: 6) {
            if repo.conflicts || !repo.state.isEmpty {
                Label(repo.state.isEmpty ? "conflicts" : repo.state, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.red)
            }
            if repo.changes > 0 {
                Text("●\(repo.changes)").foregroundStyle(Theme.orange).help("\(repo.changes) uncommitted changes")
            }
            if repo.ahead > 0 {
                Text("↑\(repo.ahead)").foregroundStyle(Theme.blue).help("\(repo.ahead) commits to push")
            }
            if repo.behind > 0 {
                Text("↓\(repo.behind)").foregroundStyle(Theme.purple).help("\(repo.behind) commits to pull")
            }
        }
        .font(.system(size: 11.5).monospacedDigit())
    }
}
