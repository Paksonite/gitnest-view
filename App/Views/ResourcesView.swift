import AppKit
import SwiftUI

/// The Resources tab: what the Terraform / OpenTofu configuration of the
/// clone declares (modules, resources, data sources, Terragrunt units),
/// read from the files, with what the latest plan changes marked.
struct ResourcesView: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @State private var items: [TFItem]?
    @State private var query = ""
    @State private var kind = "all"
    @State private var usage: [ModuleUsage] = []
    @State private var latestTag: String?

    var body: some View {
        let clone = model.clone(of: repo)
        Group {
            if clone == nil {
                EmptyState("Not cloned", symbol: "arrow.down.circle", message: "Resources are read from the configuration in the clone.") {
                    Button("Clone") { Task { await model.clone(repo) } }.buttonStyle(ChipButtonStyle(prominent: true))
                }
            } else if let items {
                if items.isEmpty && usage.isEmpty {
                    EmptyState("No Terraform here", symbol: "square.stack.3d.up", message: "No .tf or terragrunt.hcl files in \(repo.name).")
                } else {
                    WithFilePane(repo: repo) { list(items) }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(model.revision(repo))/\(clone?.lastCommit ?? 0)/\(clone?.branch ?? "")/\(model.activations)") {
            items = await model.resources(of: repo)
            usage = await model.moduleUsage(of: repo)
            latestTag = usage.isEmpty ? nil : await model.tags(of: repo).first?.name
        }
    }

    private func list(_ all: [TFItem]) -> some View {
        let plan = model.latestPlan(of: repo)
        let shown = all.filter { item in
            (kind == "all" || item.kind == kind) &&
                (query.isEmpty || item.address.localizedCaseInsensitiveContains(query) || item.source.localizedCaseInsensitiveContains(query)
                    || item.file.localizedCaseInsensitiveContains(query))
        }
        let byFile = Dictionary(grouping: shown, by: \.file)
        let files = byFile.keys.sorted()
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Segments(options: [("all", "All \(all.count)"), ("module", "Modules \(all.count { $0.kind == "module" })"),
                                   ("resource", "Resources \(all.count { $0.kind == "resource" })"), ("data", "Data \(all.count { $0.kind == "data" })")]
                    + (all.contains { $0.kind == "unit" } ? [("unit", "Units \(all.count { $0.kind == "unit" })")] : []),
                         selection: $kind)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("Filter by address, source or file", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                .frame(maxWidth: 320)
                Spacer()
                if let plan {
                    Label("Marked: the latest plan (+\(plan.add) ~\(plan.change) −\(plan.destroy))", systemImage: "info.circle")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(12)
            HLine()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !usage.isEmpty { usedBy }
                    ForEach(files, id: \.self) { file in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                model.fileTarget = FileTarget(repo: repo, file: file, line: nil)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                    Text(file).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                                    Text("\(byFile[file]?.count ?? 0)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverBackground(radius: 5)
                            .linkCursor()
                            .help("Show \(file)")
                            .padding(.bottom, 2)
                            ForEach(byFile[file] ?? []) { item in
                                ItemRow(item: item, change: change(for: item, in: plan), repo: repo,
                                        shown: model.fileTarget?.file == item.file && model.fileTarget?.line == item.line) { open(item) }
                            }
                        }
                    }
                    if all.isEmpty {
                        Text("No resources or modules are declared in this repository itself.").foregroundStyle(Theme.secondary).padding(8)
                    } else if shown.isEmpty {
                        Text("Nothing matches.").foregroundStyle(Theme.secondary).padding(20)
                    }
                }
                .padding(12)
            }
        }
    }

    /// Other repositories of the workspace that use this one as a module,
    /// and the version they pin, next to the newest tag.
    private var usedBy: some View {
        let repos = Set(usage.map(\.repo.id)).count
        return Card("Used by \(repos) \(repos == 1 ? "repository" : "repositories")") {
            if let latestTag { Text("newest tag \(latestTag)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary) }
        } content: {
            VStack(spacing: 0) {
                ForEach(usage) { use in
                    Button {
                        model.selection = use.repo.id
                        model.repoTab = .resources
                    } label: {
                        HStack(spacing: 8) {
                            Text(use.repo.name).lineLimit(1).frame(width: 180, alignment: .leading)
                            Text(use.module).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                            Spacer(minLength: 6)
                            if let ref = use.ref {
                                let outdated = latestTag != nil && ref != latestTag
                                Text(ref).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background((outdated ? Theme.orange : Theme.green).opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(outdated ? Theme.orange : Theme.green)
                                    .help(outdated ? "Pinned to \(ref); the newest tag is \(latestTag ?? "")" : "Pinned to the newest tag")
                            } else {
                                Text("no ref").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                                    .help("A local path or an unpinned source: it follows the default branch")
                            }
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverBackground(radius: 5)
                    .help("\(use.source)\n\(use.file):\(use.line)")
                }
            }
            .padding(.horizontal, -6)
        }
    }

    /// What the plan does to an item: a resource by its address, a module by
    /// anything inside it.
    private func change(for item: TFItem, in plan: TerraformPlan?) -> [TerraformPlan.Action] {
        guard let plan else { return [] }
        let actions = plan.changes.filter { change in
            let address = change.address
            switch item.kind {
            case "module":
                return address.hasPrefix(item.address + ".") || address.hasPrefix(item.address + "[")
            case "resource", "data":
                // Strip the index: google_x.y["k"] belongs to google_x.y.
                let base = address.split(separator: "[").first.map(String.init) ?? address
                return base == item.address
            default:
                return false
            }
        }.map(\.action)
        return Array(Set(actions)).sorted { $0.rawValue < $1.rawValue }
    }

    /// Shows the declaration in the app's own viewer.
    private func open(_ item: TFItem) {
        let target = FileTarget(repo: repo, file: item.file, line: item.line)
        // A second click on the same row puts the pane away again.
        model.fileTarget = model.fileTarget == target ? nil : target
    }
}

private struct ItemRow: View {
    let item: TFItem
    let change: [TerraformPlan.Action]
    let repo: ForgeRepo
    /// Its declaration is in the file pane now.
    var shown = false
    let open: () -> Void
    @State private var hovering = false
    @State private var showingHistory = false

    var body: some View {
        HStack(spacing: 0) {
            row
            Button("History of \(item.address)", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .frame(width: 26, height: 28)
                .opacity(hovering || showingHistory ? 1 : 0)
                .help("Who changed this, and when")
                .popover(isPresented: $showingHistory, arrowEdge: .trailing) {
                    ResourceHistory(repo: repo, item: item)
                }
        }
        .onHover { hovering = $0 }
    }

    private var row: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint).frame(width: 16)
                if item.kind == "module" || item.kind == "unit" {
                    Text(item.kind == "unit" ? item.name : "module.\(item.name)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                } else {
                    (Text(item.kind == "data" ? "data." : "").foregroundStyle(Theme.tertiary)
                        + Text(item.type).foregroundStyle(Theme.secondary)
                        + Text(".\(item.name)").foregroundStyle(Theme.text))
                        .font(.system(size: 12, design: .monospaced))
                }
                if item.many {
                    Text("each").font(.system(size: 10, weight: .medium)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(Theme.purple)
                        .help("count or for_each: one per item")
                }
                ForEach(change, id: \.self) { action in
                    Text("\(action.sign) \(action.rawValue)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(action.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(action.color)
                }
                Spacer(minLength: 8)
                if !item.source.isEmpty {
                    Text(item.source).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Text(":\(item.line)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(selected: shown, radius: 5)
        .help("Show \(item.file) at line \(item.line)")
    }

    private var symbol: String {
        switch item.kind {
        case "module": "shippingbox"
        case "data": "magnifyingglass"
        case "unit": "square.stack.3d.up"
        default: "cube"
        }
    }

    private var tint: Color {
        switch item.kind {
        case "module": Theme.blue
        case "data": Theme.secondary
        case "unit": Theme.purple
        default: Theme.green
        }
    }
}


/// The commits that changed one declaration, newest first.
private struct ResourceHistory: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let item: TFItem
    @State private var history: BlockHistory?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.address).font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text(history.map { "\(item.file) · lines \($0.start)–\($0.end)" } ?? item.file)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
            }
            .padding(12)
            HLine()
            if !loaded {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the history…").foregroundStyle(Theme.secondary) }.padding(12)
            } else if (history?.commits ?? []).isEmpty {
                Text("Not committed yet, or the history could not be read.").foregroundStyle(Theme.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(history?.commits ?? []) { commit in
                            Button { show(commit) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(commit.short).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(commit.subject).lineLimit(2).multilineTextAlignment(.leading)
                                        Text("\(commit.author) · \(commit.when)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                    }
                                    Spacer(minLength: 4)
                                    if let number = commit.pullNumber {
                                        Text("#\(number)").font(.system(size: 11.5)).foregroundStyle(Theme.blue)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverBackground(radius: 0)
                            .help(commit.pullNumber == nil ? "Show the commit on the server" : "Show the pull request")
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 440)
        .background(Theme.window)
        .task {
            history = await model.history(of: item, in: repo)
            loaded = true
        }
    }

    /// The pull request that brought the commit when its subject names one,
    /// else the commit on the server.
    private func show(_ commit: BlockCommit) {
        if let number = commit.pullNumber, let host = model.workspace?.host {
            Task { await model.openPull(host: host, fullName: repo.fullName, number: number, url: nil) }
        } else if let base = repo.htmlURL, let url = URL(string: "\(base)/commit/\(commit.sha)") {
            openExternal(url)
        }
    }
}
