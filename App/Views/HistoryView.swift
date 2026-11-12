import AppKit
import SwiftUI

/// The History tab: the commits of the checked-out branch with what can be
/// done to them (gitnest's history editing, undoable), and the branches.
struct HistoryView: View {
    enum Mode: Hashable { case commits, branches, tags }

    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @State private var mode: Mode = .commits

    var body: some View {
        if model.clone(of: repo) == nil {
            EmptyState("Not cloned", symbol: "arrow.down.circle", message: "Clone the repository to see and edit its history.") {
                Button("Clone") { Task { await model.clone(repo) } }.buttonStyle(ChipButtonStyle(prominent: true))
            }
        } else {
            switch mode {
            case .commits: CommitsBrowser(repo: repo, mode: $mode)
            case .branches: BranchesBrowser(repo: repo, mode: $mode)
            case .tags: TagsBrowser(repo: repo, mode: $mode)
            }
        }
    }
}

private struct ModeSwitch: View {
    @Binding var mode: HistoryView.Mode

    var body: some View {
        Segments(options: [(HistoryView.Mode.commits, "Commits"), (.branches, "Branches"), (.tags, "Tags")], selection: $mode)
    }
}

// MARK: - Commits

private struct CommitsBrowser: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @Binding var mode: HistoryView.Mode
    @State private var history: History?
    @State private var error: String?
    @State private var selected: HistoryCommit.ID?

    private var current: HistoryCommit? {
        history?.commits.first { $0.id == selected } ?? history?.commits.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ModeSwitch(mode: $mode)
                    Spacer()
                    if let undo = history?.undo, !undo.isEmpty {
                        Button("Undo \(undo)", systemImage: "arrow.uturn.backward") {
                            Task { _ = await model.rewrite(.undo, in: repo) }
                        }
                        .buttonStyle(ChipButtonStyle())
                        .help("Bring the branch back to how it was before the last change to its history")
                    }
                }
                .padding(12)
                if let error {
                    EmptyState("Cannot read the history", symbol: "exclamationmark.triangle", message: error)
                } else if let history {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(history.commits.enumerated()), id: \.element.id) { index, commit in
                                CommitRow(commit: commit, last: index == history.commits.count - 1)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selected = commit.id }
                                    .hoverBackground(selected: current?.id == commit.id, radius: 5)
                                    .contextMenu { actions(commit, index: index, commits: history.commits) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 420)
            VLine()
            Group {
                if let commit = current, let commits = history?.commits, let index = commits.firstIndex(of: commit) {
                    CommitDetail(repo: repo, commit: commit) { actions(commit, index: index, commits: commits) }
                        .id(commit.id)
                } else {
                    EmptyState("Select a commit", symbol: "clock.arrow.circlepath")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(model.revision(repo))/\(model.clone(of: repo)?.lastCommit ?? 0)/\(model.clone(of: repo)?.branch ?? "")") {
            do {
                history = try await model.history(of: repo)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// What can be done to a commit. Squash and fixup fold it into the
    /// commit below, so the oldest commit cannot take them.
    @ViewBuilder func actions(_ commit: HistoryCommit, index: Int, commits: [HistoryCommit]) -> some View {
        let hasParent = !commit.parents.isEmpty && index + 1 < commits.count
        Button("Reword…") { model.sheet = .reword(repo, commit) }
        Button("Squash into the Commit Below") { rewrite(.squash, commit) }
            .disabled(!hasParent || commit.merge)
        Button("Fixup into the Commit Below") { rewrite(.fixup, commit) }
            .disabled(!hasParent || commit.merge)
        Button("Drop…") {
            model.confirm(title: "Drop \(commit.short)?", message: "“\(commit.subject)” and its changes leave the branch. Undo brings it back.",
                          button: "Drop", destructive: true) { rewrite(.drop, commit) }
        }
        .disabled(commit.merge)
        Divider()
        Button("Revert") { rewrite(.revert, commit) }
            .help("A new commit that undoes this one: safe on pushed history")
        Button("New Branch Here…") { model.sheet = .newBranch(repo, base: commit.sha) }
        Button("Tag…") { model.sheet = .newTag(repo, rev: commit.sha, label: "\(commit.short) \(commit.subject)") }
        Divider()
        Button("Copy SHA") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.sha, forType: .string)
            model.toast("Copied \(commit.short)", .info)
        }
        if let web = repo.htmlURL, let url = URL(string: "\(web)/commit/\(commit.sha)"), !commit.unpushed {
            Button("Open on the Server") { openExternal(url) }
        }
    }

    private func rewrite(_ action: AppModel.Rewrite, _ commit: HistoryCommit) {
        Task {
            if let remotes = await model.rewrite(action, sha: commit.sha, in: repo) {
                model.confirm(title: "Change commits that are on the server?",
                              message: "\(commit.short) is already on \(remotes.joined(separator: ", ")). Rewriting it changes every commit after it: the branch then needs a force push, and anyone who has it must reset. Undo brings the old history back.",
                              button: "Rewrite Anyway", destructive: true) {
                    Task { _ = await model.rewrite(action, sha: commit.sha, confirm: true, in: repo) }
                }
            }
        }
    }
}

private struct CommitRow: View {
    let commit: HistoryCommit
    let last: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // A simple line through the commits; merges get a hollow dot.
            VStack(spacing: 0) {
                Circle()
                    .strokeBorder(commit.unpushed ? Theme.blue : Theme.brand, lineWidth: commit.merge ? 2 : 0)
                    .background(Circle().fill(commit.merge ? Color.clear : (commit.unpushed ? Theme.blue : Theme.brand)))
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
                if !last {
                    Rectangle().fill(Theme.border).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(commit.subject).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(commit.short).font(.system(size: 11, design: .monospaced))
                    Text(commit.author)
                    Text(commit.when)
                    if commit.unpushed { Text("not pushed").foregroundStyle(Theme.blue) }
                    ForEach(refs, id: \.self) { ref in
                        Text(ref)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background((ref.hasPrefix("tag:") ? Theme.yellow : ref.contains("/") ? Theme.purple : Theme.green).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(ref.hasPrefix("tag:") ? Theme.yellow : ref.contains("/") ? Theme.purple : Theme.green)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// "HEAD -> main, origin/main, tag: v1" → ["main", "origin/main", "tag: v1"]
    private var refs: [String] {
        commit.refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("HEAD -> ") ? String($0.dropFirst(8)) : $0 }
            .filter { !$0.isEmpty && $0 != "HEAD" && !$0.hasSuffix("/HEAD") }
    }
}

private struct CommitDetail<Actions: View>: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let commit: HistoryCommit
    @ViewBuilder var actions: () -> Actions
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(commit.short).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                Text(commit.subject).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Button("Reword…", systemImage: "pencil") { model.sheet = .reword(repo, commit) }
                    .buttonStyle(ChipButtonStyle())
                Dropdown(id: "commit-actions", width: 240) {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                } content: {
                    MenuAsDropdown { actions() }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            HLine()
            if text.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PatchText(text: text)
            }
        }
        .task(id: commit.sha) { text = await model.show(commit.sha, in: repo) }
    }
}

/// Shows the buttons of a context menu in a themed drop-down.
private struct MenuAsDropdown<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(DropdownCenter.self) private var center

    var body: some View {
        content()
            .buttonStyle(DropdownButtonStyle(center: center))
            .labelStyle(.titleOnly)
    }
}

private struct DropdownButtonStyle: PrimitiveButtonStyle {
    let center: DropdownCenter
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            center.close()
            configuration.trigger()
        } label: {
            configuration.label
                .font(.system(size: 12.5))
                .foregroundStyle(enabled ? Theme.text : Theme.tertiary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(radius: 5)
    }
}

/// A commit's message, stat and patch, coloured like a diff.
struct PatchText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.usesFindBar = true
        view.layoutManager?.allowsNonContiguousLayout = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.textStorage?.setAttributedString(Self.render(text))
    }

    @MainActor
    static func render(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        let out = NSMutableAttributedString()
        var inPatch = false
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var color = NSColor(Theme.text)
            var weight = font
            if line.hasPrefix("diff --git") { inPatch = true; color = NSColor(Theme.text); weight = bold }
            else if i == 0 { color = NSColor(Theme.secondary) }
            else if inPatch && line.hasPrefix("@@") { color = NSColor(Theme.blue) }
            else if inPatch && line.hasPrefix("+") && !line.hasPrefix("+++") { color = NSColor(Theme.green) }
            else if inPatch && line.hasPrefix("-") && !line.hasPrefix("---") { color = NSColor(Theme.red) }
            else if inPatch && (line.hasPrefix("index ") || line.hasPrefix("+++") || line.hasPrefix("---")) { color = NSColor(Theme.tertiary) }
            else if !inPatch && line.contains(" | ") { color = NSColor(Theme.secondary) }
            out.append(NSAttributedString(string: String(line) + "\n", attributes: [.font: weight, .foregroundColor: color]))
        }
        return out
    }
}

// MARK: - Branches

private struct BranchesBrowser: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @Binding var mode: HistoryView.Mode
    @State private var branches: BranchList?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ModeSwitch(mode: $mode)
                Spacer()
                let gone = branches?.local.filter { $0.gone && !$0.current } ?? []
                if !gone.isEmpty {
                    Button("Delete \(gone.count) Gone", systemImage: "trash") {
                        model.confirm(title: "Delete \(gone.count) local \(gone.count == 1 ? "branch" : "branches") whose server branch is gone?",
                                      message: gone.map(\.name).joined(separator: ", ") + ". Their commits stay reachable from the reflog for a while.",
                                      button: "Delete", destructive: true) {
                            Task { for branch in gone { await model.deleteBranch(branch.name, force: true, in: repo) } }
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .help("Branches merged and deleted on the server")
                }
                Button("New Branch…", systemImage: "plus") { model.sheet = .newBranch(repo, base: model.clone(of: repo)?.branch ?? "") }
                    .buttonStyle(ChipButtonStyle(prominent: true))
            }
            .padding(12)
            ScrollView {
                if let branches {
                    VStack(alignment: .leading, spacing: 14) {
                        Card("Local") {
                            Text("\(branches.local.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        } content: {
                            VStack(spacing: 0) {
                                ForEach(branches.local) { branch in LocalBranchRow(repo: repo, branch: branch) }
                            }
                            .padding(.horizontal, -6)
                        }
                        let local = Set(branches.local.map(\.name))
                        let remote = branches.remote.filter { !$0.name.hasSuffix("/HEAD") }
                        Card("On the server") {
                            Text("\(remote.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        } content: {
                            VStack(spacing: 0) {
                                ForEach(remote) { branch in
                                    let short = branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name
                                    HStack(spacing: 8) {
                                        Image(systemName: "icloud").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 16)
                                        Text(branch.name).font(.system(size: 12.5, design: .monospaced)).lineLimit(1)
                                        Text(branch.subject).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(branch.updated).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                        if !local.contains(short) {
                                            Button("Check Out") { Task { await model.checkout(branch, in: repo) } }.buttonStyle(ChipButtonStyle())
                                        }
                                        if short != (repo.defaultBranch ?? "main") {
                                            Button("Delete", systemImage: "trash") {
                                                model.confirm(title: "Delete \(short) on the server?", message: "Everyone loses the branch \(short). Its pull request, if any, closes.",
                                                              button: "Delete", destructive: true) {
                                                    Task { await model.deleteBranch(short, remote: true, in: repo) }
                                                }
                                            }
                                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .frame(height: 32)
                                    .hoverBackground(radius: 5)
                                }
                            }
                            .padding(.horizontal, -6)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                } else {
                    ProgressView().controlSize(.small).padding(30)
                }
            }
        }
        .task(id: "\(model.revision(repo))/\(model.clone(of: repo)?.branch ?? "")") {
            branches = await model.branches(of: repo)
        }
    }
}

private struct LocalBranchRow: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let branch: LocalBranch
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: branch.current ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.system(size: 11)).foregroundStyle(branch.current ? Theme.green : Theme.secondary).frame(width: 16)
            if renaming {
                TextField("", text: $newName)
                    .font(.system(size: 12.5, design: .monospaced))
                    .fieldBox()
                    .onSubmit {
                        renaming = false
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, name != branch.name { Task { await model.renameBranch(branch.name, to: name, in: repo) } }
                    }
                    .onExitCommand { renaming = false }
            } else {
                Text(branch.name).font(.system(size: 12.5, weight: branch.current ? .semibold : .regular, design: .monospaced)).lineLimit(1)
            }
            Text(tracking).font(.system(size: 11.5)).foregroundStyle(branch.gone ? Theme.orange : Theme.tertiary).lineLimit(1)
            Spacer(minLength: 4)
            Text(branch.updated).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            if !branch.current {
                Button("Switch") { Task { await model.checkout(branch, in: repo) } }.buttonStyle(ChipButtonStyle())
            }
            Dropdown(id: "branch-\(branch.name)", width: 220) {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).foregroundStyle(Theme.secondary)
            } content: {
                DropdownItem(title: "Rename…", symbol: "pencil") {
                    newName = branch.name
                    renaming = true
                }
                if branch.current {
                    DropdownItem(title: branch.upstream.isEmpty ? "Publish" : "Push", symbol: "arrow.up") { Task { await model.push(repo) } }
                }
                DropdownItem(title: "New Branch from Here…", symbol: "plus") { model.sheet = .newBranch(repo, base: branch.name) }
                if !branch.current {
                    DropdownDivider()
                    DropdownItem(title: "Delete…", symbol: "trash") { delete() }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .hoverBackground(radius: 5)
    }

    private var tracking: String {
        if branch.gone { return "gone on the server" }
        if branch.upstream.isEmpty { return "local only" }
        var parts = [branch.upstream]
        if branch.ahead > 0 { parts.append("↑\(branch.ahead)") }
        if branch.behind > 0 { parts.append("↓\(branch.behind)") }
        return parts.joined(separator: " ")
    }

    private func delete() {
        model.confirm(title: "Delete \(branch.name)?",
                      message: branch.ahead > 0 || branch.upstream.isEmpty
                        ? "It has commits that are not on the server; they stay reachable from the reflog for a while."
                        : "The branch is on the server too; only the local copy goes.",
                      button: "Delete", destructive: true) {
            Task { await model.deleteBranch(branch.name, force: true, in: repo) }
        }
    }
}

// MARK: - Tags

private struct TagsBrowser: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @Binding var mode: HistoryView.Mode
    @State private var tags: [GitTag]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ModeSwitch(mode: $mode)
                Spacer()
                Button("New Tag…", systemImage: "tag") {
                    model.sheet = .newTag(repo, rev: "", label: "the commit checked out (\(model.clone(of: repo)?.branch ?? "HEAD"))")
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
            }
            .padding(12)
            ScrollView {
                ReleasesList(repo: repo)
                if let tags {
                    VStack(spacing: 0) {
                        if tags.isEmpty {
                            Text("No tags yet.").foregroundStyle(Theme.secondary).padding(20)
                        }
                        ForEach(tags) { tag in
                            HStack(spacing: 8) {
                                Image(systemName: tag.annotated ? "tag.fill" : "tag").font(.system(size: 11)).foregroundStyle(Theme.yellow).frame(width: 16)
                                Text(tag.name).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                Text(tag.short).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
                                Text(tag.subject).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(tag.when).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                Button("Push") { Task { await model.tag(.push, tag.name, in: repo) } }
                                    .buttonStyle(ChipButtonStyle())
                                    .help("Push \(tag.name) to the server")
                                Dropdown(id: "tag-\(tag.name)", width: 220) {
                                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).foregroundStyle(Theme.secondary)
                                } content: {
                                    DropdownItem(title: "Copy Name", symbol: "doc.on.doc") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(tag.name, forType: .string)
                                    }
                                    DropdownDivider()
                                    DropdownItem(title: "Delete Here…", symbol: "trash") {
                                        model.confirm(title: "Delete the tag \(tag.name) here?", message: "The tag stays on the server if it was pushed.",
                                                      button: "Delete", destructive: true) {
                                            Task { await model.tag(.delete, tag.name, in: repo) }
                                        }
                                    }
                                    DropdownItem(title: "Delete on the Server…", symbol: "icloud.slash") {
                                        model.confirm(title: "Delete the tag \(tag.name) on the server?",
                                                      message: "Anything pinned to it (a module source with ?ref=\(tag.name)) stops resolving.",
                                                      button: "Delete", destructive: true) {
                                            Task { await model.tag(.deleteRemote, tag.name, in: repo) }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .hoverBackground(radius: 5)
                        }
                    }
                    .padding(.horizontal, 8)
                } else {
                    ProgressView().controlSize(.small).padding(30)
                }
            }
        }
        .task(id: "\(model.revision(repo))") { tags = await model.tags(of: repo) }
    }
}
