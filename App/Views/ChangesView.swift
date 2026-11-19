import AppKit
import SwiftUI

/// The Changes tab: what differs from the last commit, staged file by file
/// or line by line, committed, pushed, and turned into a pull request.
struct ChangesView: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo

    @State private var files: [ChangedFile] = []
    @State private var loaded = false
    /// The file whose diff is shown, and which side of it.
    @State private var selected: Pick?
    @State private var stashes: [Stash] = []
    /// The left column: the changes, or every file of the clone.
    #if DEBUG
    @State private var showFiles = ProcessInfo.processInfo.environment["GNV_DEV_OPEN"] == "files"
    #else
    @State private var showFiles = false
    #endif

    struct Pick: Hashable {
        var path: String
        var staged: Bool
    }

    private var staged: [ChangedFile] { files.filter { $0.staged && !$0.conflict } }
    private var unstaged: [ChangedFile] { files.filter { ($0.unstaged || $0.untracked) && !$0.conflict } }
    private var conflicts: [ChangedFile] { files.filter(\.conflict) }

    var body: some View {
        let clone = model.clone(of: repo)
        Group {
            if let clone {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        SyncBar(repo: repo, clone: clone)
                        HLine()
                        if !clone.state.isEmpty || clone.conflicts {
                            OperationBanner(repo: repo, clone: clone)
                            HLine()
                        }
                        Segments(options: [(false, files.isEmpty ? "Changes" : "Changes \(files.count)"), (true, "Files")], selection: $showFiles)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HLine()
                        if showFiles {
                            RepoFiles(repo: repo, clone: clone, changed: files)
                        } else {
                            fileList
                        }
                        HLine()
                        CommitBox(repo: repo, stagedCount: staged.count, unstagedCount: unstaged.count)
                    }
                    .frame(width: 360)
                    VLine()
                    Group {
                        if showFiles {
                            // Browsing: the chosen file takes the whole right side.
                            if let target = model.fileTarget, target.repo.id == repo.id {
                                FilePane(target: target)
                            } else {
                                EmptyState("Choose a file", symbol: "doc.text.magnifyingglass",
                                           message: "Uncommitted lines are marked beside the line numbers; ±N in the file's header shows its diff.")
                            }
                        } else {
                            WithFilePane(repo: repo, closesOnLeave: false) { diffPane }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                EmptyState(model.isCloning(repo) ? "Cloning \(repo.name)…" : "Not cloned", symbol: "arrow.down.circle", message: model.isCloning(repo) ? "Big repositories take a while; the bar shows git's progress." : "Clone the repository to stage, commit and push from here.") {
                    CloneButton(repo: repo)
                }
            }
        }
        .task(id: "\(model.revision(repo))/\(model.activations)/\(clone?.changes ?? -1)/\(clone?.branch ?? "")/\(clone?.lastCommit ?? 0)") {
            await reload()
        }
        // The file beside the changes follows the chosen one.
        .onChange(of: selected) {
            guard !showFiles, let selected, let shown = model.fileTarget, shown.repo.id == repo.id, shown.file != selected.path,
                  let file = files.first(where: { $0.path == selected.path }), !file.code.contains("D") else { return }
            model.fileTarget = FileTarget(repo: repo, file: selected.path, line: nil)
        }
        .onChange(of: model.changesFocus) {
            guard let wanted = model.changesFocus, let file = files.first(where: { $0.path == wanted }) else { return }
            showFiles = false
            selected = Pick(path: file.path, staged: !(file.unstaged || file.untracked))
            model.changesFocus = nil
        }
    }

    private func reload() async {
        let fresh = await model.changedFiles(of: repo)
        files = fresh
        stashes = await model.stashes(of: repo)
        loaded = true
        // Keep the shown file if it is still there (on either side).
        if let pick = selected {
            let stillThere = fresh.contains { $0.path == pick.path && (pick.staged ? $0.staged : ($0.unstaged || $0.untracked)) }
            if !stillThere {
                if let other = fresh.first(where: { $0.path == pick.path }) {
                    selected = Pick(path: other.path, staged: other.staged && !other.unstaged)
                } else {
                    selected = nil
                }
            }
        }
        // Asked for from the file pane: that file.
        if let wanted = model.changesFocus, let file = fresh.first(where: { $0.path == wanted }) {
            selected = Pick(path: file.path, staged: !(file.unstaged || file.untracked))
            model.changesFocus = nil
        }
        if selected == nil, let first = unstaged.first ?? staged.first ?? conflicts.first {
            selected = Pick(path: first.path, staged: !(first.unstaged || first.untracked))
        }
    }

    // MARK: Files

    /// The files in the order the list shows them, with their side.
    private var ordered: [(ChangedFile, Bool)] {
        conflicts.map { ($0, false) } + staged.map { ($0, true) } + unstaged.map { ($0, false) }
    }

    private func moveSelection(_ by: Int) {
        let list = ordered
        guard !list.isEmpty else { return }
        let index = list.firstIndex { selected == Pick(path: $0.0.path, staged: $0.1) } ?? -1
        let next = min(max(index + by, 0), list.count - 1)
        selected = Pick(path: list[next].0.path, staged: list[next].1)
    }

    private var selectedFile: (ChangedFile, Bool)? {
        ordered.first { selected == Pick(path: $0.0.path, staged: $0.1) }
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
                } else if files.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(Theme.green)
                        Text("Nothing to commit").font(.system(size: 13, weight: .medium))
                        Text("The working tree matches the last commit.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
                if !conflicts.isEmpty {
                    section("Conflicts", count: conflicts.count, action: nil)
                    ForEach(conflicts) { row($0, staged: false) }
                }
                if !staged.isEmpty {
                    section("In the next commit", count: staged.count, tint: Theme.green, action: ("Unstage All", "minus.circle", {
                        Task { await model.unstage([], all: true, in: repo) }
                    }))
                    ForEach(staged) { row($0, staged: true) }
                }
                if !unstaged.isEmpty {
                    section("Not in the commit", count: unstaged.count, action: ("Stage All", "plus.circle", {
                        Task { await model.stage([], all: true, in: repo) }
                    }))
                    ForEach(unstaged) { row($0, staged: false) }
                }
                StashSection(repo: repo, stashes: stashes, canStash: !files.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .onChange(of: selected) { if let selected { proxy.scrollTo(selected) } }
        }
        // The keyboard, for people coming from the terminal: ↑↓ choose a file,
        // space stages or unstages it, ⌫ discards it (after asking).
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.space) {
            guard let (file, isStaged) = selectedFile, !file.conflict else { return .ignored }
            Task { if isStaged { await model.unstage([file], in: repo) } else { await model.stage([file], in: repo) } }
            return .handled
        }
        .onKeyPress(.delete) {
            guard let (file, isStaged) = selectedFile, !isStaged, !file.conflict else { return .ignored }
            model.confirm(title: "Discard the changes in \(file.path)?", message: "This cannot be undone.", button: "Discard", destructive: true) {
                Task { await model.discard([file], in: repo) }
            }
            return .handled
        }
    }

    private func section(_ title: String, count: Int, tint: Color = Theme.tertiary, action: (String, String, () -> Void)?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.5).foregroundStyle(tint)
            Text("\(count)").font(.system(size: 10.5)).foregroundStyle(tint).monospacedDigit()
            Spacer()
            if let action {
                Button(action.0, systemImage: action.1, action: action.2)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func row(_ file: ChangedFile, staged: Bool) -> some View {
        fileRow(file, staged: staged).id(Pick(path: file.path, staged: staged))
    }

    private func fileRow(_ file: ChangedFile, staged: Bool) -> some View {
        FileRow(file: file, staged: staged, selected: selected == Pick(path: file.path, staged: staged)) {
            selected = Pick(path: file.path, staged: staged)
        } toggle: {
            Task {
                if staged { await model.unstage([file], in: repo) } else { await model.stage([file], in: repo) }
            }
        } discard: {
            model.confirm(title: "Discard the changes in \(file.path)?",
                          message: file.untracked ? "The new file is deleted. This cannot be undone." : "The file goes back to the last commit. This cannot be undone.",
                          button: "Discard", destructive: true) {
                Task { await model.discard([file], in: repo) }
            }
        } open: {
            if let clone = model.clone(of: repo) { openFile(clone, file.path) }
        }
    }

    // MARK: Diff

    @ViewBuilder private var diffPane: some View {
        if let pick = selected, let file = files.first(where: { $0.path == pick.path }) {
            DiffPane(repo: repo, file: file, staged: pick.staged, revision: model.revision(repo)) { side in
                selected = Pick(path: file.path, staged: side)
            }
            .id(pick)
        } else {
            EmptyState(loaded && files.isEmpty ? "Working tree clean" : "Select a file", symbol: "doc.text.magnifyingglass",
                       message: loaded && files.isEmpty ? "Edit files in your editor; they show up here as soon as you come back." : "")
        }
    }
}

/// Opens one file of a clone in the editor.
@MainActor
func openFile(_ clone: Repo, _ path: String) {
    let url = URL(fileURLWithPath: clone.path).appending(path: path)
    let workspace = NSWorkspace.shared
    for id in ["com.microsoft.VSCode", "com.vscodium", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed"] {
        if let app = workspace.urlForApplication(withBundleIdentifier: id) {
            workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
    }
    workspace.open(url)
}

extension ChangedFile {
    /// The letter for one side of the status: what happened to the file in
    /// the index (staged) or in the working tree.
    func letter(staged: Bool) -> (String, Color) {
        if conflict { return ("!", Theme.red) }
        if untracked { return ("U", Theme.green) }
        let chars = Array(code)
        let c = chars.count == 2 ? (staged ? chars[0] : chars[1]) : "M"
        switch c {
        case "A": return ("A", Theme.green)
        case "D": return ("D", Theme.red)
        case "R": return ("R", Theme.blue)
        case "C": return ("C", Theme.blue)
        case "T": return ("T", Theme.purple)
        default: return ("M", Theme.orange)
        }
    }
}

private struct FileRow: View {
    let file: ChangedFile
    let staged: Bool
    let selected: Bool
    let select: () -> Void
    let toggle: () -> Void
    let discard: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let (letter, color) = file.letter(staged: staged)
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 8) {
            if !file.conflict {
                // In the commit or not, at a glance; a click changes it.
                Button(action: toggle) {
                    Image(systemName: staged ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(staged ? Theme.green : Theme.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(staged ? "In the next commit — click to take it out" : "Not in the commit — click to add it")
                .accessibilityLabel(staged ? "In the next commit" : "Not in the commit")
            }
            Text(letter)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 5) {
                Text(name).lineLimit(1).foregroundStyle(staged ? Theme.text : Theme.secondary)
                if !staged, file.staged {
                    Badge(text: "partly in", color: Theme.green, filled: false)
                        .help("Some of this file's changes are in the next commit, the rest are not")
                }
                if !folder.isEmpty {
                    Text(folder).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if hovering {
                if !staged && !file.conflict {
                    iconButton("Discard", "arrow.uturn.backward", discard)
                }
                iconButton("Open in Editor", "pencil", open)
                if !file.conflict {
                    iconButton(staged ? "Unstage" : "Stage", staged ? "minus" : "plus", toggle)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(staged ? Theme.green.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !file.conflict { toggle() } }
        .simultaneousGesture(TapGesture().onEnded { select() })
        .hoverBackground(selected: selected, radius: 5)
        .onHover { hovering = $0 }
        .help(file.orig.isEmpty ? file.path : "\(file.orig) → \(file.path)")
    }

    private func iconButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .help(title)
    }
}

// MARK: - The diff of one file

private struct DiffPane: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let file: ChangedFile
    let staged: Bool
    let revision: Int
    let switchSide: (Bool) -> Void

    @State private var diff: FileDiff?
    @State private var error: String?
    @State private var chosen: Set<LineRef> = []
    @State private var anchor: LineRef?

    private var hasBothSides: Bool { file.staged && (file.unstaged || file.untracked) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HLine()
            if file.conflict {
                EmptyState("Conflict in \((file.path as NSString).lastPathComponent)", symbol: "exclamationmark.triangle",
                           message: "Both sides changed the same lines. Resolve the markers in your editor, then mark the file resolved.") {
                    HStack(spacing: 8) {
                        Button("Open in Editor") { if let clone = model.clone(of: repo) { openFile(clone, file.path) } }
                            .buttonStyle(ChipButtonStyle())
                        Button("Mark Resolved") { Task { await model.stage([file], in: repo) } }
                            .buttonStyle(ChipButtonStyle(prominent: true))
                    }
                }
            } else if let error {
                EmptyState("Cannot show the changes", symbol: "exclamationmark.triangle", message: error)
            } else if let diff {
                if diff.binary {
                    EmptyState("Binary file", symbol: "doc.zipper", message: "Its changes cannot be shown as text.")
                } else if diff.hunks.allSatisfy({ $0.rows.isEmpty }) {
                    EmptyState("No changes in the text", symbol: "doc", message: file.untracked ? "The new file is empty." : "Only the file's mode or name changed.")
                } else {
                    lines(diff)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(file.path)/\(staged)/\(revision)/\(model.activations)") {
            do {
                diff = try await model.diff(file, staged: staged, in: repo)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            chosen = []
            anchor = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(Theme.secondary)
            Text(file.path).font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            if hasBothSides {
                Segments(options: [(false, "Unstaged"), (true, "Staged")], selection: Binding(get: { staged }, set: { switchSide($0) }))
            } else {
                Text(staged ? "staged" : file.untracked ? "new file" : "not staged").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            // A deleted file has nothing left to read.
            if !file.conflict, !file.code.contains("D") {
                let open = model.fileTarget?.repo.id == repo.id && model.fileTarget?.file == file.path
                Button(open ? "Hide File" : "View File", systemImage: open ? "sidebar.right" : "doc.text.magnifyingglass") {
                    if open {
                        model.fileTarget = nil
                    } else {
                        // At the first changed line of the shown side.
                        let line = diff?.hunks.lazy.flatMap(\.rows).first(where: { $0.kind == "+" })?.new
                        model.fileTarget = FileTarget(repo: repo, file: file.path, line: line)
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .fixedSize()
                .help(open ? "Close the file beside the changes" : "Read the whole file beside the changes, its changed lines marked")
            }
            if !chosen.isEmpty {
                Text("\(chosen.count) \(chosen.count == 1 ? "line" : "lines")").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                if !staged {
                    Button("Discard", systemImage: "arrow.uturn.backward") { discardLines() }
                        .buttonStyle(ChipButtonStyle())
                        .disabled(file.untracked)
                }
                Button(staged ? "Unstage Lines" : "Stage Lines", systemImage: staged ? "minus" : "plus") { apply(staged ? .unstage : .stage) }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .help("Space stages or unstages the chosen file; ⇧-click chooses a range of lines")
            } else if !file.conflict {
                Button(staged ? "Unstage File" : "Stage File", systemImage: staged ? "minus" : "plus") {
                    Task {
                        if staged { await model.unstage([file], in: repo) } else { await model.stage([file], in: repo) }
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func lines(_ diff: FileDiff) -> some View {
        GeometryReader { viewport in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { h, hunk in
                    Button {
                        toggleHunk(h, hunk)
                    } label: {
                        Text(hunk.header)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.blue)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .background(Theme.blue.opacity(0.07))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose every changed line of this hunk")
                    ForEach(Array(hunk.rows.enumerated()), id: \.offset) { i, line in
                        DiffRow(line: line, chosen: chosen.contains(LineRef(Hunk: h, Line: i)))
                            .onTapGesture { tap(LineRef(Hunk: h, Line: i), in: diff) }
                    }
                }
                if diff.truncated {
                    Text("The diff is long; only its beginning is shown.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).padding(10)
                }
            }
            // As wide as the longest line, which a lazy stack does not
            // measure until it is on screen (its end could not be scrolled
            // to), and at least as wide as the pane, so the line colours
            // reach its edge.
            .frame(minWidth: max(viewport.size.width, DiffRow.width(of: diff)), alignment: .leading)
            .padding(.bottom, 12)
        }
        }
        .background(Theme.inset)
    }

    /// A click chooses or un-chooses a changed line; with ⇧ it chooses every
    /// changed line from the last click.
    private func tap(_ ref: LineRef, in diff: FileDiff) {
        guard diff.hunks[ref.Hunk].rows[ref.Line].isChange, !file.conflict else { return }
        if NSEvent.modifierFlags.contains(.shift), let anchor {
            let all = changeRefs(diff)
            if let a = all.firstIndex(of: anchor), let b = all.firstIndex(of: ref) {
                for r in all[min(a, b)...max(a, b)] { chosen.insert(r) }
            }
        } else if chosen.contains(ref) {
            chosen.remove(ref)
        } else {
            chosen.insert(ref)
        }
        anchor = ref
    }

    private func toggleHunk(_ h: Int, _ hunk: FileDiff.Hunk) {
        guard !file.conflict else { return }
        let refs = hunk.rows.indices.filter { hunk.rows[$0].isChange }.map { LineRef(Hunk: h, Line: $0) }
        if refs.allSatisfy(chosen.contains) { refs.forEach { chosen.remove($0) } } else { refs.forEach { chosen.insert($0) } }
    }

    private func changeRefs(_ diff: FileDiff) -> [LineRef] {
        diff.hunks.enumerated().flatMap { h, hunk in
            hunk.rows.indices.filter { hunk.rows[$0].isChange }.map { LineRef(Hunk: h, Line: $0) }
        }
    }

    private func apply(_ action: AppModel.LineAction) {
        guard let diff else { return }
        let refs = chosen.sorted { ($0.Hunk, $0.Line) < ($1.Hunk, $1.Line) }
        Task { await model.lines(action, refs, of: file, diff: diff, in: repo) }
    }

    private func discardLines() {
        let count = chosen.count
        model.confirm(title: "Discard \(count) \(count == 1 ? "line" : "lines")?", message: "They go back to what the index has. This cannot be undone.",
                      button: "Discard", destructive: true) { apply(.discard) }
    }
}

private struct DiffRow: View {
    let line: FileDiff.Line
    let chosen: Bool

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    /// The two numbers, the sign and the space after the text.
    private static let gutter: CGFloat = 40 + 40 + 22 + 16

    /// How wide the diff's longest row is: the few longest lines are
    /// measured (a tab or a wide character is wider than its count says).
    static func width(of diff: FileDiff) -> CGFloat {
        let rows = diff.hunks.lazy.flatMap(\.rows)
        let most = rows.map(\.text.utf16.count).max() ?? 0
        let longest = rows.map(\.text).filter { $0.utf16.count * 5 >= most * 4 }.prefix(5)
        let text = longest.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 0
        return ceil(text) + gutter
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(line.old > 0 ? "\(line.old)" : "").frame(width: 40, alignment: .trailing)
            Text(line.new > 0 ? "\(line.new)" : "").frame(width: 40, alignment: .trailing)
            Text(line.kind == "\\" ? " " : line.kind)
                .foregroundStyle(sign)
                .frame(width: 22)
            Text(line.kind == "\\" ? line.text.trimmingCharacters(in: .whitespaces) : line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == "\\" ? Theme.tertiary : Theme.text)
                .fixedSize()
                .padding(.trailing, 16)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(Theme.tertiary)
        .frame(minHeight: 19, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .leading) {
            if chosen { Rectangle().fill(Theme.blue).frame(width: 3) }
        }
        .contentShape(Rectangle())
    }

    private var sign: Color {
        switch line.kind {
        case "+": Theme.green
        case "-": Theme.red
        default: Theme.tertiary
        }
    }

    private var background: Color {
        if chosen { return Theme.blue.opacity(0.22) }
        switch line.kind {
        case "+": return Theme.green.opacity(0.11)
        case "-": return Theme.red.opacity(0.11)
        default: return .clear
        }
    }
}

// MARK: - Branch state, push, pull request

/// Where the branch stands against the server, with the one action that
/// moves it forward: publish, push, pull, or open a pull request.
private struct SyncBar: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let clone: Repo
    /// The pull request a branch deleted on the server was merged in.
    @State private var merged: PullRequest?

    private var openPull: PullRequest? {
        model.forgeState(repo).pulls.first { $0.state == "open" && $0.head.ref == clone.branch }
    }

    private var isDefault: Bool { clone.branch == (repo.defaultBranch ?? "main") }

    var body: some View {
        let busy = model.busy.contains(model.slug(repo)?.key ?? "")
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Text(clone.detached ? "detached HEAD" : clone.branch)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            Spacer(minLength: 4)
            if busy { ProgressView().controlSize(.small) }
            action.disabled(busy)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .task(id: clone.upstreamGone ? clone.path + "|" + clone.branch : "") {
            merged = clone.upstreamGone ? await model.mergedPull(of: repo) : nil
        }
    }

    private var status: String {
        if clone.detached { return "" }
        if let merged, clone.upstreamGone { return "merged in #\(merged.number)" }
        if !clone.hasUpstream { return clone.upstreamGone ? "upstream deleted" : "not on the server" }
        var parts: [String] = []
        if clone.ahead > 0 { parts.append("↑\(clone.ahead)") }
        if clone.behind > 0 { parts.append("↓\(clone.behind)") }
        return parts.isEmpty ? "up to date" : parts.joined(separator: " ")
    }

    @ViewBuilder private var action: some View {
        if clone.detached {
            EmptyView()
        } else if let merged, clone.upstreamGone {
            Button("Finish", systemImage: "checkmark") {
                model.finish(WorkInProgress(branch: clone.branch, items: [(repo: repo, clone: clone)]), merged: [clone.path: merged])
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .help("\(clone.branch) is merged into \(merged.base.name): switch back to it, pull it, and delete \(clone.branch) here")
        } else if !clone.hasUpstream {
            Button("Publish", systemImage: "icloud.and.arrow.up") { Task { await model.push(repo) } }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .help("Push \(clone.branch) to the server and track it")
        } else if clone.ahead > 0 && clone.behind > 0 {
            HStack(spacing: 6) {
                Button("Rebase", systemImage: "arrow.down") { Task { await model.pull(repo, mode: "rebase") } }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .help("Put your \(clone.ahead) local \(clone.ahead == 1 ? "commit" : "commits") on top of the server's \(clone.behind)")
                Button("Merge") { Task { await model.pull(repo, mode: "merge") } }
                    .buttonStyle(ChipButtonStyle())
                    .help("Bring in the server's commits with a merge commit")
                Button("Force Push…") {
                    model.confirm(title: "Force push \(clone.branch)?",
                                  message: "The server's \(clone.behind) \(clone.behind == 1 ? "commit" : "commits") on this branch that you do not have are replaced by your history. Use it after rewriting commits you pushed before.",
                                  button: "Force Push", destructive: true) {
                        Task { await model.push(repo, force: true) }
                    }
                }
                .buttonStyle(ChipButtonStyle())
            }
        } else if clone.behind > 0 {
            Button("Pull \(clone.behind)", systemImage: "arrow.down") { Task { await model.run(.pull, on: repo) } }
                .buttonStyle(ChipButtonStyle(prominent: true))
        } else if clone.ahead > 0 {
            Button("Push \(clone.ahead)", systemImage: "arrow.up") { Task { await model.push(repo) } }
                .buttonStyle(ChipButtonStyle(prominent: true))
        }
    }
}

/// A merge, rebase, cherry-pick or revert stopped on conflicts.
private struct OperationBanner: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let clone: Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(clone.state.isEmpty ? "Conflicts to resolve" : "\(clone.state.capitalized) — stopped", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.red)
            Text(clone.conflicts ? "Resolve the conflicted files in your editor, stage them, then continue." : "Stage the result, then continue.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            if !clone.state.isEmpty {
                HStack(spacing: 6) {
                    Button("Continue") { Task { await model.operation(.continue, in: repo) } }
                        .buttonStyle(ChipButtonStyle(prominent: true))
                        .disabled(clone.conflicts)
                    if clone.state == "rebasing" || clone.state == "cherry-picking" || clone.state == "reverting" {
                        Button("Skip") { Task { await model.operation(.skip, in: repo) } }.buttonStyle(ChipButtonStyle())
                    }
                    Button("Abort") {
                        model.confirm(title: "Abort the \(clone.state)?", message: "The repository goes back to how it was before it started.",
                                      button: "Abort", destructive: true) {
                            Task { await model.operation(.abort, in: repo) }
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.red.opacity(0.07))
    }
}

// MARK: - Commit

private struct CommitBox: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let stagedCount: Int
    let unstagedCount: Int
    @State private var message = ""
    @State private var amend = false
    @State private var working = false
    @FocusState private var focused: Bool

    private var subject: String { message.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "" }
    private var hasMessage: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canCommit: Bool {
        !working && (amend || (hasMessage && (stagedCount > 0 || unstagedCount > 0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(height: 74)
                if message.isEmpty {
                    Text(amend ? "Message of the last commit" : "Commit message — the first line is the summary")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.blue.opacity(0.6) : Theme.border))

            HStack(spacing: 8) {
                Toggle("Amend", isOn: $amend)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .help("Change the last commit instead of making a new one")
                    .onChange(of: amend) {
                        if amend, message.isEmpty { Task { message = await model.lastMessage(in: repo) } }
                    }
                if subject.count > 72 {
                    Text("\(subject.count)/72").font(.system(size: 11)).foregroundStyle(Theme.yellow).monospacedDigit()
                        .help("A summary longer than 72 characters is cut in many places")
                }
                Spacer()
                Button(commitTitle) { commit(push: false) }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(!canCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘↩")
                Button("& Push") { commit(push: true) }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(!canCommit)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help("Commit, then push (⇧⌘↩)")
            }
        }
        .padding(10)
    }

    private var commitTitle: String {
        if amend { return "Amend" }
        if stagedCount == 0 && unstagedCount > 0 { return "Commit All" }
        return "Commit"
    }

    private func commit(push: Bool) {
        working = true
        let text = message
        let stageFirst = !amend && stagedCount == 0 && unstagedCount > 0
        let wasAmend = amend
        Task {
            if stageFirst { await model.stage([], all: true, in: repo) }
            if await model.commit(text, amend: wasAmend, in: repo) {
                message = ""
                amend = false
                if push {
                    // An amended commit that was already pushed needs a force push.
                    let clone = model.clone(of: repo)
                    if wasAmend, let clone, clone.behind > 0, clone.ahead > 0 {
                        model.confirm(title: "Force push \(clone.branch)?", message: "The amended commit replaces the one on the server.",
                                      button: "Force Push", destructive: true) {
                            Task { await model.push(repo, force: true) }
                        }
                    } else {
                        await model.push(repo)
                    }
                }
            }
            working = false
        }
    }
}

// MARK: - Stashes

private struct StashSection: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let stashes: [Stash]
    let canStash: Bool
    @State private var open = false

    var body: some View {
        if canStash || !stashes.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.snappy(duration: 0.15)) { open.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                            Text("STASHES").font(.system(size: 10.5, weight: .semibold)).kerning(0.5)
                            Text("\(stashes.count)").font(.system(size: 10.5)).monospacedDigit()
                        }
                        .foregroundStyle(Theme.tertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if canStash {
                        Button("Stash Changes", systemImage: "tray.and.arrow.down") { Task { await model.stash(.push, in: repo) } }
                            .labelStyle(.titleAndIcon)
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .help("Put every change aside and clean the working tree")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 3)
                if open {
                    if stashes.isEmpty {
                        Text("No stashes.").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    ForEach(stashes) { stash in
                        HStack(spacing: 8) {
                            Image(systemName: "tray").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stash.message).lineLimit(1)
                                Text("\(stash.ref) · \(stash.when)").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                            }
                            Spacer()
                            Button("Pop") { Task { await model.stash(.pop, ref: stash.ref, in: repo) } }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.blue)
                                .help("Apply and remove")
                            Button("Drop", systemImage: "trash") {
                                model.confirm(title: "Drop \(stash.ref)?", message: "The stashed changes are lost.", button: "Drop", destructive: true) {
                                    Task { await model.stash(.drop, ref: stash.ref, in: repo) }
                                }
                            }
                            .labelStyle(.iconOnly).buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .hoverBackground(radius: 5)
                    }
                }
            }
        }
    }
}

/// The clone as its folders and files, uncommitted ones marked (and the
/// folders that hold them); a click on a file opens it beside the tree.
struct RepoFiles: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let clone: Repo
    let changed: [ChangedFile]
    @State private var tree: FileTree?
    @State private var query = ""
    @FocusState private var filterFocused: Bool
    /// Looks for the text inside the files instead of in their names.
    @AppStorage("filesSearchText") private var inText = false
    @State private var hits: [GrepMatch]?
    @State private var searchProblem: String?
    /// The open folders live in the model, per clone: they stay as they were
    /// when the tree comes back (another tab, another repo, a relaunch).
    private var state: Binding<FileTreeState> {
        Binding { model.treeState(of: clone.path) } set: { model.setTreeState($0, of: clone.path) }
    }
    private var expanded: Set<String> { state.wrappedValue.expanded }

    var body: some View {
        let marks = Dictionary(changed.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                TextField(inText ? "Search text in files" : "Filter files", text: $query).textFieldStyle(.plain)
                    .focused($filterFocused)
                Button(inText ? "Names" : "Text") {
                    inText.toggle()
                    filterFocused = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(inText ? Theme.blue : Theme.tertiary)
                .padding(.horizontal, 6).frame(height: 18)
                .background((inText ? Theme.blue : Theme.border).opacity(inText ? 0.14 : 0.5), in: RoundedRectangle(cornerRadius: 4))
                .help(inText ? "Searching the text inside the files. Click to filter by file name." : "Filtering by file name. Click to search the text inside the files.")
                .accessibilityLabel(inText ? "Search File Names" : "Search Text in Files")
                if !expanded.isEmpty, query.isEmpty, !inText {
                    Button("Collapse All", systemImage: "arrow.down.right.and.arrow.up.left") { state.wrappedValue.expanded = [] }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.tertiary).help("Collapse every folder")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).frame(height: 26)
            .focusesField($filterFocused)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .padding(8)
            if inText, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                textHits
            } else if let tree {
                let rows = tree.rows(expanded: expanded, query: inText ? "" : query)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in
                            if row.folder {
                                folderRow(row)
                            } else {
                                fileRow(row, mark: marks[row.path])
                            }
                        }
                        if rows.isEmpty {
                            Text(tree.root.children.isEmpty ? "The clone has no files." : "Nothing matches.")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(12)
                        }
                        if tree.cut {
                            Text("The first \(FileTree.limit) files are shown.").font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(8)
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(clone.path)/\(clone.lastCommit)/\(clone.branch)/\(changed.map(\.path).joined(separator: "|"))") {
            let changedPaths = changed.filter { !$0.code.contains("D") }.map(\.path)
            guard let paths = await model.treeFiles(of: repo) else { return }
            let fresh = await Task.detached(priority: .userInitiated) { FileTree.build(paths, changed: changedPaths) }.value
            // Folders that came to hold changes open by themselves, once.
            var kept = state.wrappedValue
            let new = fresh.foldersWithChanges.subtracting(kept.opened)
            kept.expanded.formUnion(new)
            kept.opened.formUnion(new)
            state.wrappedValue = kept
            tree = fresh
            reveal(model.fileTarget)
        }
        .onChange(of: model.fileTarget) { reveal(model.fileTarget) }
        .task(id: inText ? "\(clone.path)|\(query)|\(model.revision(repo))" : "") {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard inText, !text.isEmpty else { hits = nil; searchProblem = nil; return }
            // Typing: wait for a pause before asking git.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let found = try await model.grep(text, in: repo)
                guard !Task.isCancelled else { return }
                hits = found
                searchProblem = nil
            } catch {
                guard !Task.isCancelled else { return }
                hits = []
                searchProblem = error.localizedDescription
            }
        }
    }

    /// The lines that hold the text, under their files; a click opens the
    /// file at that line with the find bar on the text.
    @ViewBuilder private var textHits: some View {
        if let hits {
            let files = Dictionary(grouping: hits, by: \.file).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            let text = query.trimmingCharacters(in: .whitespaces)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let searchProblem {
                        Text(searchProblem).font(.system(size: 12)).foregroundStyle(Theme.red).padding(12)
                    } else if hits.isEmpty {
                        Text("No file holds “\(text)”.").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(12)
                    } else {
                        Text("\(hits.count == 200 ? "The first 200" : "\(hits.count)") \(hits.count == 1 ? "line" : "lines") in \(files.count) \(files.count == 1 ? "file" : "files")")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.horizontal, 6).padding(.vertical, 4)
                    }
                    ForEach(files, id: \.key) { file, lines in
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                            Text(file).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 4)
                            Text("\(lines.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.tertiary)
                        }
                        .padding(.horizontal, 6).frame(height: 23)
                        .help(file)
                        ForEach(lines, id: \.self) { hit in hitRow(hit, text: text) }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hitRow(_ hit: GrepMatch, text: String) -> some View {
        let shown = model.fileTarget?.repo.id == repo.id && model.fileTarget?.file == hit.file && model.fileTarget?.line == hit.line
        return Button {
            model.fileTarget = FileTarget(repo: repo, file: hit.file, line: hit.line, find: text)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(hit.line)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
                    .frame(minWidth: 30, alignment: .trailing)
                Text(Self.marked(hit.text.trimmingCharacters(in: .whitespaces), text))
                    .font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(height: 21)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(selected: shown, radius: 5)
        .help("\(hit.file):\(hit.line)")
    }

    /// The line with the text looked for in bold.
    static func marked(_ line: String, _ text: String) -> AttributedString {
        var out = AttributedString(line)
        guard !text.isEmpty else { return out }
        let options: String.CompareOptions = text.lowercased() == text ? [.caseInsensitive] : []
        var from = line.startIndex
        while let found = line.range(of: text, options: options, range: from..<line.endIndex) {
            if let low = AttributedString.Index(found.lowerBound, within: out), let high = AttributedString.Index(found.upperBound, within: out) {
                out[low..<high].foregroundColor = Theme.orange
                out[low..<high].font = .system(size: 11.5, weight: .bold, design: .monospaced)
            }
            from = found.upperBound
        }
        return out
    }

    /// Opens the folders above a file shown from elsewhere (Search, Changes).
    private func reveal(_ target: FileTarget?) {
        guard let target, target.repo.id == repo.id else { return }
        var prefix = ""
        var kept = state.wrappedValue
        for part in target.file.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            kept.expanded.insert(prefix)
        }
        state.wrappedValue = kept
    }

    private func folderRow(_ row: FileTree.Row) -> some View {
        let open = !query.isEmpty || expanded.contains(row.path)
        return Button {
            guard query.isEmpty else { return }
            if open { state.wrappedValue.expanded.remove(row.path) } else { state.wrappedValue.expanded.insert(row.path) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                Image(systemName: open ? "folder.fill" : "folder").font(.system(size: 11)).foregroundStyle(Theme.blue.opacity(0.8))
                Text(row.name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                if row.changes > 0 {
                    Text("\(row.changes)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.orange)
                        .help("\(row.changes) changed \(row.changes == 1 ? "file" : "files") inside")
                }
            }
            .padding(.leading, CGFloat(row.depth) * 14 + 4).padding(.trailing, 6).frame(height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(radius: 5)
        .help(row.path)
    }

    private func fileRow(_ row: FileTree.Row, mark: ChangedFile?) -> some View {
        let shown = model.fileTarget?.repo.id == repo.id && model.fileTarget?.file == row.path
        return Button {
            model.fileTarget = shown ? nil : FileTarget(repo: repo, file: row.path, line: nil)
        } label: {
            HStack(spacing: 5) {
                Color.clear.frame(width: 10)
                Image(systemName: "doc.text").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(mark == nil ? Theme.text : (mark?.untracked == true ? Theme.green : Theme.orange))
                Spacer(minLength: 4)
                if let mark {
                    Text(mark.untracked ? "A" : mark.code.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(mark.untracked ? Theme.green : Theme.orange)
                        .help(mark.untracked ? "New, not committed" : "Changed since the last commit")
                }
            }
            .padding(.leading, CGFloat(row.depth) * 14 + 4).padding(.trailing, 6).frame(height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(selected: shown, radius: 5)
        .help(row.path)
    }
}

/// A clone's folders and files, read from the disk.
struct FileTree: Sendable {
    static let limit = 50_000

    final class Node: @unchecked Sendable {
        let name: String
        let path: String
        let folder: Bool
        var children: [Node] = []
        /// Changed files at or below this node.
        var changes = 0
        init(name: String, path: String, folder: Bool) {
            self.name = name
            self.path = path
            self.folder = folder
        }
    }

    struct Row: Identifiable, Hashable {
        var path: String
        var name: String
        var folder: Bool
        var depth: Int
        var changes: Int
        var id: String { path }
    }

    let root: Node
    let cut: Bool
    let foldersWithChanges: Set<String>

    /// The tree of a list of paths ("a/b/c.yml"), folders made from them.
    static func build(_ paths: [String], changed: [String]) -> FileTree {
        let root = Node(name: "", path: "", folder: true)
        var folders: [String: Node] = ["": root]
        let cut = paths.count > limit
        for path in paths.prefix(limit) {
            let parts = path.split(separator: "/").map(String.init)
            var parent = root
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                if let known = folders[prefix] {
                    parent = known
                } else {
                    let folder = Node(name: part, path: prefix, folder: true)
                    parent.children.append(folder)
                    folders[prefix] = folder
                    parent = folder
                }
            }
            parent.children.append(Node(name: parts.last ?? path, path: path, folder: false))
        }
        // Folders first, as Finder and editors list them.
        func order(_ node: Node) {
            node.children.sort { $0.folder != $1.folder ? $0.folder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            node.children.filter(\.folder).forEach(order)
        }
        order(root)
        var withChanges: Set<String> = []
        for path in changed {
            var prefix = ""
            root.changes += 1
            for part in path.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                folders[prefix]?.changes += 1
                withChanges.insert(prefix)
            }
        }
        return FileTree(root: root, cut: cut, foldersWithChanges: withChanges)
    }

    /// The rows to draw: open folders show their children; a query shows
    /// the matching files with the folders above them.
    func rows(expanded: Set<String>, query: String) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        // One walk: a folder shows when it is open, or (filtering) when
        // something below it matches.
        func add(_ node: Node, depth: Int) -> [Row] {
            var rows: [Row] = []
            for child in node.children {
                let row = Row(path: child.path, name: child.name, folder: child.folder, depth: depth, changes: child.changes)
                if child.folder {
                    if needle.isEmpty {
                        rows.append(row)
                        if expanded.contains(child.path) { rows += add(child, depth: depth + 1) }
                    } else {
                        let below = add(child, depth: depth + 1)
                        if !below.isEmpty { rows.append(row); rows += below }
                    }
                } else if needle.isEmpty || child.path.localizedCaseInsensitiveContains(needle) {
                    rows.append(row)
                }
            }
            return rows
        }
        return add(root, depth: 0)
    }
}
