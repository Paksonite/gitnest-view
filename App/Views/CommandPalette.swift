import AppKit
import SwiftUI

/// One thing the palette can jump to or do.
struct PaletteItem: Identifiable {
    enum Kind: String { case repository = "Repositories", pull = "Pull requests", branch = "Branches", workflow = "Workflows", command = "Commands", workspace = "Workspaces" }

    var id: String
    var kind: Kind
    var title: String
    var detail: String = ""
    var symbol: String
    var tint: Color = Theme.secondary
    /// Extra words that match but are not shown (ticket keys, owner…).
    var keywords: String = ""
    var action: @MainActor () -> Void
}

/// Ranks how well `query` matches `text`: every character of the query in
/// order, more for matches at word starts and in a row; nil for no match.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        if let range = text.lowercased().range(of: query.lowercased()) {
            // A plain substring beats any scattered match; earlier is better.
            let offset = text.lowercased().distance(from: text.startIndex, to: range.lowerBound)
            return 1000 - min(offset, 200) * 2 - t.count / 4
        }
        var score = 0, qi = 0, streak = 0, previous = -2
        for (i, c) in t.enumerated() where qi < q.count && c == q[qi] {
            let wordStart = i == 0 || " -_/.#".contains(t[i - 1])
            streak = i == previous + 1 ? streak + 1 : 0
            score += 10 + (wordStart ? 25 : 0) + streak * 8
            previous = i
            qi += 1
        }
        return qi == q.count ? score - t.count / 3 : nil
    }
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var cursor = 0
    @State private var pulls: [InboxItem] = []
    @State private var branches: BranchList?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            if model.paletteOpen {
                Color.black.opacity(0.35)
                    .onTapGesture { close() }
                    .transition(.opacity)
                panel
                    .padding(.top, 80)
                    .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.16), value: model.paletteOpen)
    }

    private var panel: some View {
        let results = ranked
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                TextField("Jump to a repository, pull request, branch, workflow — or run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1, results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, results.count); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onSubmit { run(results) }
                    .onChange(of: query) { cursor = 0 }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            HLine()
            if results.isEmpty {
                Text(query.isEmpty ? "Type to search." : "Nothing matches “\(query)”.")
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || results[index - 1].kind != item.kind {
                                    Text(item.kind.rawValue.uppercased())
                                        .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                                        .foregroundStyle(Theme.tertiary)
                                        .padding(.horizontal, 12).padding(.top, index == 0 ? 4 : 10).padding(.bottom, 3)
                                }
                                row(item, selected: index == cursor)
                                    .id(item.id)
                                    .onTapGesture { cursor = index; run(results) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: cursor) {
                        if results.indices.contains(cursor) { proxy.scrollTo(results[cursor].id) }
                    }
                }
            }
            HLine()
            HStack(spacing: 14) {
                hint("↑↓", "move")
                hint("↵", "open")
                hint("esc", "close")
                Spacer()
                if let workspace = model.workspace {
                    Text(workspace.title).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .onAppear {
            query = ""
            #if DEBUG
            query = ProcessInfo.processInfo.environment["GNV_DEV_QUERY"] ?? ""
            #endif
            cursor = 0
            focused = true
        }
        .task { await load() }
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border))
            Text(what).font(.system(size: 11))
        }
        .foregroundStyle(Theme.tertiary)
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).font(.system(size: 12)).foregroundStyle(item.tint).frame(width: 18)
            Text(item.title).lineLimit(1)
            if !item.detail.isEmpty {
                Text(item.detail).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func move(_ by: Int, _ count: Int) {
        guard count > 0 else { return }
        cursor = (cursor + by + count) % count
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(cursor) else { return }
        let item = results[cursor]
        close()
        item.action()
    }

    private func close() {
        model.paletteOpen = false
    }

    private func load() async {
        branches = nil
        if let repo = model.selectedRepo {
            async let workflows: Void = model.loadWorkflows(repo)
            branches = await model.branches(of: repo)
            await workflows
        }
        if let workspace = model.workspace, let client = model.client(for: workspace.host),
           let hits = try? await client.openPullRequests(owner: workspace.owner) {
            pulls = hits.map { InboxItem(host: workspace.host, hit: $0) }
        }
    }

    // MARK: Items

    private var ranked: [PaletteItem] {
        let all = items
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Without a query: what is most likely wanted next.
            return Array(all.filter { $0.kind == .command }.prefix(8)) + Array(all.filter { $0.kind == .repository }.prefix(10))
        }
        let order: [PaletteItem.Kind] = [.repository, .pull, .branch, .workflow, .command, .workspace]
        var scored: [(PaletteItem, Int)] = []
        for item in all {
            let best = [Fuzzy.score(query, item.title), Fuzzy.score(query, item.detail).map { $0 - 40 },
                        Fuzzy.score(query, item.keywords).map { $0 - 20 }].compactMap { $0 }.max()
            if let best { scored.append((item, best)) }
        }
        // Grouped by kind, each group best first, at most a dozen per group.
        var out: [PaletteItem] = []
        for kind in order {
            let group = scored.filter { $0.0.kind == kind }.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
            out += group
        }
        // The group with the single best match comes first.
        if let top = scored.max(by: { $0.1 < $1.1 })?.0.kind {
            out = out.filter { $0.kind == top } + out.filter { $0.kind != top }
        }
        return out
    }

    private var items: [PaletteItem] {
        var out: [PaletteItem] = []
        let current = model.selectedRepo

        // Commands about the repository on screen come first.
        if let repo = current {
            let clone = model.clone(of: repo)
            for tab in RepoTab.allCases {
                out.append(PaletteItem(id: "tab:\(tab.rawValue)", kind: .command, title: "Go to \(tab.rawValue)", detail: repo.name, symbol: tab.symbol) {
                    model.section = .repositories
                    model.repoTab = tab
                })
            }
            if let clone {
                out.append(PaletteItem(id: "cmd:editor", kind: .command, title: "Open in Editor", detail: repo.name, symbol: "chevron.left.forwardslash.chevron.right") { openClone(clone, in: .editor) })
                out.append(PaletteItem(id: "cmd:terminal", kind: .command, title: "Open in Terminal", detail: repo.name, symbol: "terminal") { openClone(clone, in: .terminal) })
                out.append(PaletteItem(id: "cmd:finder", kind: .command, title: "Show in Finder", detail: repo.name, symbol: "folder") { openClone(clone, in: .finder) })
                out.append(PaletteItem(id: "cmd:branch", kind: .command, title: "New Branch…", detail: repo.name, symbol: "plus", keywords: "create checkout") {
                    model.sheet = .newBranch(repo, base: clone.branch)
                })
                out.append(PaletteItem(id: "cmd:push", kind: .command, title: "Push", detail: "\(repo.name) · \(clone.branch)", symbol: "arrow.up") { Task { await model.push(repo) } })
                out.append(PaletteItem(id: "cmd:pull", kind: .command, title: "Pull", detail: "\(repo.name) · \(clone.branch)", symbol: "arrow.down") { Task { await model.run(.pull, on: repo) } })
                if !clone.detached, clone.branch != (repo.defaultBranch ?? "main") {
                    out.append(PaletteItem(id: "cmd:pr", kind: .command, title: "Open Pull Request…", detail: clone.branch, symbol: "arrow.triangle.pull") {
                        model.sheet = .createPull(repo, head: clone.branch)
                    })
                }
            } else if repo.empty != true {
                out.append(PaletteItem(id: "cmd:clone", kind: .command, title: "Clone", detail: repo.name, symbol: "arrow.down.circle") { Task { await model.clone(repo) } })
            }
            out.append(PaletteItem(id: "cmd:pin", kind: .command, title: model.isPinned(repo) ? "Unpin" : "Pin to the Top", detail: repo.name,
                                   symbol: model.isPinned(repo) ? "pin.slash" : "pin", keywords: "favorite") { model.togglePin(repo) })
            out.append(PaletteItem(id: "cmd:release", kind: .command, title: "Release…", detail: "develop → \(repo.defaultBranch ?? "main") · \(repo.name)", symbol: "paperplane") {
                model.sheet = .release(repo)
            })
            if let url = repo.htmlURL.flatMap(URL.init) {
                out.append(PaletteItem(id: "cmd:web", kind: .command, title: "Open on the Server", detail: repo.name, symbol: "safari") { openExternal(url) })
            }
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let text = query.trimmingCharacters(in: .whitespaces)
            out.append(PaletteItem(id: "cmd:grep", kind: .command, title: "Search “\(text)” in All Repositories", detail: "every clone of \(model.workspace?.title ?? "the workspace")",
                                   symbol: "text.magnifyingglass", keywords: text) {
                model.searchText = text
                model.section = .search
            })
        }
        out.append(PaletteItem(id: "cmd:fetchall", kind: .command, title: "Fetch All", detail: "every clone of \(model.workspace?.title ?? "the workspace")", symbol: "arrow.clockwise") {
            Task { await model.fetchAllReporting() }
        })
        out.append(PaletteItem(id: "cmd:startwork", kind: .command, title: "Start Work in Several Repositories…", detail: "one branch, many repositories",
                               symbol: "square.stack.3d.up", keywords: "ticket branch multi") {
            model.sheet = .startWork(preselected: model.selection)
        })
        out.append(PaletteItem(id: "cmd:releases", kind: .command, title: "Releases…", detail: "what waits on develop, in every repository", symbol: "paperplane", keywords: "release develop main ship") { model.sheet = .releases })
        out.append(PaletteItem(id: "cmd:pullall", kind: .command, title: "Pull All…", detail: "fast-forward what is behind", symbol: "arrow.down.circle") { model.sheet = .pullAll })
        out.append(PaletteItem(id: "cmd:getall", kind: .command, title: "Get All Repositories…", detail: "clone what is missing, then pull",
                               symbol: "square.and.arrow.down.on.square") { model.sheet = .getAll })
        out.append(PaletteItem(id: "cmd:home", kind: .command, title: "Go to Home", detail: "activity and what needs you", symbol: "house") { model.section = .home })
        out.append(PaletteItem(id: "cmd:inbox", kind: .command, title: "Go to Inbox", detail: "reviews waiting for you", symbol: "tray") { model.section = .inbox })
        let settings = openSettings
        out.append(PaletteItem(id: "cmd:settings", kind: .command, title: "Settings…", symbol: "gearshape", keywords: "preferences token server") {
            settings()
        })

        for repo in model.repos {
            let reasons = model.attention(repo)
            let cloned = model.clone(of: repo) != nil
            out.append(PaletteItem(id: "repo:\(repo.id)", kind: .repository, title: repo.name,
                                   detail: reasons.first?.text ?? (cloned ? "" : "not cloned"),
                                   symbol: cloned ? "folder.fill" : "folder", tint: reasons.isEmpty ? Theme.secondary : Theme.orange,
                                   keywords: repo.fullName) {
                model.section = .repositories
                model.selection = repo.id
            })
        }

        var seenPulls: Set<String> = []
        for item in pulls + model.inbox {
            guard seenPulls.insert(item.id).inserted, let repo = item.hit.repository else { continue }
            let tickets = AppModel.tickets(in: [item.hit.title]).joined(separator: " ")
            out.append(PaletteItem(id: "pull:\(item.id)", kind: .pull, title: item.hit.title,
                                   detail: "\(repo.name) #\(item.hit.number) · \(item.hit.user?.displayName ?? "")",
                                   symbol: "arrow.triangle.pull", tint: Theme.green, keywords: "\(repo.fullName) #\(item.hit.number) \(tickets)") {
                Task { await model.openPull(host: item.host, fullName: repo.fullName, number: item.hit.number, url: item.hit.htmlURL) }
            })
        }

        if let repo = current, let branches {
            let local = Set(branches.local.map(\.name))
            for branch in branches.local {
                out.append(PaletteItem(id: "branch:l:\(branch.name)", kind: .branch, title: branch.name,
                                       detail: branch.current ? "checked out" : "switch · \(branch.updated)",
                                       symbol: branch.current ? "checkmark" : "arrow.triangle.branch", tint: branch.current ? Theme.green : Theme.secondary) {
                    if !branch.current { Task { await model.checkout(branch, in: repo) } }
                })
            }
            for branch in branches.remote where !branch.name.hasSuffix("/HEAD") {
                let short = branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name
                guard !local.contains(short) else { continue }
                out.append(PaletteItem(id: "branch:r:\(branch.name)", kind: .branch, title: short, detail: "on the server · check out",
                                       symbol: "icloud.and.arrow.down", keywords: branch.name) {
                    Task { await model.checkout(branch, in: repo) }
                })
            }
        }

        if let repo = current, let slug = model.slug(repo) {
            for workflow in model.workflows[slug.key] ?? [] {
                out.append(PaletteItem(id: "wf:\(workflow.id)", kind: .workflow, title: workflow.title,
                                       detail: workflow.info?.dispatch == true ? "run · \(workflow.file)" : "runs · \(workflow.file)",
                                       symbol: workflow.info?.dispatch == true ? "play.fill" : "play.circle") {
                    if workflow.info?.dispatch == true {
                        model.sheet = .dispatch(repo, workflow)
                    } else {
                        model.section = .repositories
                        model.repoTab = .actions
                    }
                })
            }
        }

        for workspace in model.workspaces where workspace.id != model.workspace?.id {
            out.append(PaletteItem(id: "ws:\(workspace.id)", kind: .workspace, title: workspace.title, detail: "switch · \(workspace.host)",
                                   symbol: workspace.personal ? "person" : "building.2") {
                model.select(workspace)
            })
        }
        return out
    }
}
