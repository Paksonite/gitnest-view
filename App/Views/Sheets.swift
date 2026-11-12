import SwiftUI

/// The forms shown over the window (release, run a workflow), in the same
/// frame as the log window: a click outside, or Esc, closes them.
struct SheetLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { window in
            if let sheet = model.sheet {
                ZStack {
                    Color.black.opacity(0.5)
                        .onTapGesture { model.sheet = nil }
                        .transition(.opacity)
                    Group {
                        switch sheet {
                        case .release(let repo): ReleaseSheet(repo: repo)
                        case .createPull(let repo, let head): ReleaseSheet(repo: repo, release: false, initialHead: head)
                        case .dispatch(let repo, let workflow): DispatchSheet(repo: repo, workflow: workflow)
                        case .newBranch(let repo, let base): NewBranchSheet(repo: repo, base: base)
                        case .reword(let repo, let commit): RewordSheet(repo: repo, commit: commit)
                        case .newTag(let repo, let rev, let label): NewTagSheet(repo: repo, rev: rev, label: label)
                        case .pullAll: PullAllSheet()
                        case .getAll: GetAllSheet()
                        case .startWork(let preselected): StartWorkSheet(preselected: preselected)
                        case .openPulls(let branch): OpenPullsSheet(branch: branch)
                        case .review(let repo, let pull): ReviewSheet(repo: repo, pull: pull)
                        case .merge(let repo, let pull): MergeSheet(repo: repo, pull: pull)
                        case .editPull(let repo, let pull): EditPullSheet(repo: repo, pull: pull)
                        case .releases: ReleasesSheet()
                        }
                    }
                    .frame(width: min(640, window.size.width - 80))
                    .frame(maxHeight: window.size.height - 80)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Theme.window, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
                    .transition(.scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(y: 14)))
                }
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: model.sheet)
    }
}

/// The frame of a form: title, content, and the buttons at the bottom.
private struct SheetFrame<Content: View, Actions: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Theme.brand)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Close", systemImage: "xmark") { model.sheet = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            HLine()
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(16)
            HLine()
            HStack(spacing: 8) { actions }
                .padding(.horizontal, 16)
                .frame(height: 54)
        }
    }
}

/// A labelled input in the app's colours.
struct Field<Content: View>: View {
    let label: String
    var hint: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
            content
            if !hint.isEmpty {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

extension View {
    /// The look of a text input in the app's forms.
    func fieldBox() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
    }
}

private struct ErrorLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundStyle(Theme.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Release

/// Prepares the pull request that releases one branch into another
/// (develop into the default branch): shows what it would bring and opens it.
struct ReleaseSheet: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    /// A release (develop into the default branch), or a feature's pull request.
    var release = true
    var initialHead = "develop"
    @State private var head = "develop"
    @State private var base = ""
    @State private var title = ""
    @State private var text = ""
    @State private var draft: ReleaseDraft?
    @State private var loading = true
    @State private var creating = false
    @State private var error: String?
    /// What the server has: the lists to choose from.
    @State private var branches: [String] = []

    var body: some View {
        SheetFrame(title: release ? "Release \(repo.name)" : "New pull request in \(repo.name)", symbol: release ? "paperplane" : "arrow.triangle.pull") {
            HStack(alignment: .bottom, spacing: 10) {
                Field(label: "From") {
                    BranchPicker(id: "pull-head", name: "From", branches: branches, selection: $head, other: base)
                }
                Image(systemName: "arrow.right").foregroundStyle(Theme.tertiary).padding(.bottom, 8)
                Field(label: "Into") {
                    BranchPicker(id: "pull-base", name: "Into", branches: branches, selection: $base, other: head)
                }
            }
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Comparing the branches…").foregroundStyle(Theme.secondary)
                }
            } else if let draft {
                if let existing = draft.existing {
                    Label("Pull request #\(existing.number) already takes \(draft.head) into \(draft.base).", systemImage: "info.circle")
                        .foregroundStyle(Theme.secondary)
                } else if draft.commits.isEmpty {
                    Label("Nothing to merge: \(draft.base) already has everything from \(draft.head).", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.secondary)
                } else {
                    Field(label: "Title") {
                        TextField("Title", text: $title).fieldBox()
                    }
                    Field(label: "Description") {
                        TextEditor(text: $text)
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .frame(height: 84)
                            .padding(5)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    }
                    commits(draft)
                }
            }
            if let error { ErrorLine(text: error) }
        } actions: {
            if let draft, !draft.tickets.isEmpty {
                ForEach(draft.tickets.prefix(4), id: \.self) { Badge(text: $0, color: Theme.blue, filled: false) }
            }
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            if let existing = draft?.existing {
                Button("Show Pull Request") {
                    model.pendingPull = existing.number
                    model.sheet = nil
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
            } else {
                Button(creating ? "Opening…" : "Open Pull Request") { create() }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(creating || loading || title.trimmingCharacters(in: .whitespaces).isEmpty || (draft?.commits.isEmpty ?? true))
                    // ⌘↩: a plain Return belongs to the description being typed.
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘↩")
            }
        }
        .task {
            // Both branches first, then one comparison: a comparison with a
            // branch still missing would fail and its error outlive the right one.
            let start = initialHead
            let target = release ? (repo.defaultBranch ?? "main") : await model.defaultBase(for: start, in: repo)
            head = start
            base = target
            branches = await model.serverBranches(repo)
        }
        // One comparison per pair of branches; a newer pair cancels the older one.
        .task(id: Pair(head: head, base: base)) { await load() }
    }

    private func commits(_ draft: ReleaseDraft) -> some View {
        Field(label: "\(draft.commits.count) \(draft.commits.count == 1 ? "commit" : "commits")") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(draft.commits.enumerated()), id: \.element.id) { index, commit in
                        if index > 0 { HLine() }
                        HStack(spacing: 8) {
                            Text(String(commit.sha.prefix(7))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                            Text(commit.subject).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(commit.commit.author?.name ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                    }
                }
            }
            .frame(maxHeight: 170)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        }
    }

    private struct Pair: Hashable {
        var head: String
        var base: String
    }

    private func load() async {
        let from = head.trimmingCharacters(in: .whitespaces), into = base.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !into.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await model.releaseDraft(repo, head: from, base: into, release: release)
            // Only the answer for the branches chosen now counts.
            guard !Task.isCancelled, from == head.trimmingCharacters(in: .whitespaces), into == base.trimmingCharacters(in: .whitespaces) else { return }
            error = nil
            draft = fresh
            title = fresh.title
            text = fresh.body
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), from == head.trimmingCharacters(in: .whitespaces),
                  into == base.trimmingCharacters(in: .whitespaces) else { return }
            draft = nil
            switch error {
            case ForgejoClient.ForgeError.notFound, ForgejoClient.ForgeError.http(500):
                // Some servers answer a missing branch with 500 instead of 404.
                self.error = "Cannot compare: check that the branches \(from) and \(into) exist on the server."
            default:
                self.error = error.localizedDescription
            }
        }
    }

    private func create() {
        guard let draft else { return }
        creating = true
        error = nil
        Task {
            do {
                try await model.createRelease(repo, head: draft.head, base: draft.base, title: title, body: text)
                model.sheet = nil
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}

/// Title and description of a pull request.
struct EditPullSheet: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let pull: PullRequest
    @State private var title = ""
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        SheetFrame(title: "Edit #\(pull.number)", symbol: "pencil") {
            Field(label: "Title") { TextField("Title", text: $title).fieldBox() }
            Field(label: "Description") {
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(height: 160)
                    .padding(5)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            }
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(saving ? "Saving…" : "Save") {
                saving = true
                Task {
                    if await model.edit(pull, in: repo, title: title, body: text) { model.sheet = nil }
                    saving = false
                }
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("⌘↩")
        }
        .onAppear {
            title = pull.title
            text = pull.body ?? ""
        }
    }
}

/// A branch chosen from the ones the server has.
private struct BranchPicker: View {
    let id: String
    let name: String
    let branches: [String]
    @Binding var selection: String
    /// The branch on the other side: it cannot be chosen here too.
    let other: String

    var body: some View {
        Dropdown(id: id, width: 300) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                Text(selection.isEmpty ? "Choose a branch" : selection)
                    .font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selection.isEmpty ? Theme.tertiary : Theme.text)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
        } content: {
            if branches.isEmpty {
                DropdownHeader(text: "Reading the branches from the server…")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(branches, id: \.self) { branch in
                            DropdownItem(title: branch, symbol: "arrow.triangle.branch", checked: branch == selection,
                                         monospaced: true, disabled: branch == other) { selection = branch }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .help("Branches on the server")
        .accessibilityLabel("\(name) branch: \(selection)")
    }
}

// MARK: - Run a workflow

/// Starts a workflow by hand: the branch to run on and the inputs the
/// workflow declares.
struct DispatchSheet: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let workflow: Workflow
    @State private var ref = ""
    @State private var values: [String: String] = [:]
    @State private var running = false
    @State private var error: String?

    private var inputs: [WorkflowInfo.Input] { workflow.info?.inputs ?? [] }

    private var missing: [String] {
        inputs.filter { $0.required && (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.map(\.name)
    }

    var body: some View {
        SheetFrame(title: "Run \(workflow.title)", symbol: "play.circle") {
            Field(label: "Branch or tag", hint: "The workflow file of this branch is the one that runs.") {
                TextField("main", text: $ref).font(.system(size: 12.5, design: .monospaced)).fieldBox()
            }
            if inputs.isEmpty {
                Text("This workflow takes no inputs.").foregroundStyle(Theme.secondary)
            }
            ForEach(inputs) { input in
                Field(label: input.required ? "\(input.name) · required" : input.name, hint: input.description) {
                    control(for: input)
                }
            }
            if let error { ErrorLine(text: error) }
        } actions: {
            Text(workflow.file).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(running ? "Starting…" : "Run Workflow") { run() }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(running || ref.trimmingCharacters(in: .whitespaces).isEmpty || !missing.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            ref = model.clone(of: repo).flatMap { $0.detached ? nil : $0.branch } ?? repo.defaultBranch ?? "main"
            if ref != repo.defaultBranch, workflow.info?.events.contains("workflow_dispatch") == true {
                // A local branch may not be on the server; the default one always is.
                ref = repo.defaultBranch ?? ref
            }
            for input in inputs { values[input.name] = input.default }
        }
    }

    @ViewBuilder private func control(for input: WorkflowInfo.Input) -> some View {
        let binding = Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })
        switch input.type {
        case "boolean":
            Segments(options: [("true", "Yes"), ("false", "No")], selection: binding)
        case "choice" where !input.options.isEmpty && input.options.count <= 5:
            Segments(options: input.options.map { ($0, $0) }, selection: binding)
        case "choice" where !input.options.isEmpty:
            Dropdown(id: "input-\(input.name)", width: 280) {
                HStack {
                    Text(binding.wrappedValue.isEmpty ? "Choose…" : binding.wrappedValue)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .fieldBox()
            } content: {
                ForEach(input.options, id: \.self) { option in
                    DropdownItem(title: option, checked: option == binding.wrappedValue) { binding.wrappedValue = option }
                }
            }
        default:
            TextField(input.default.isEmpty ? input.name : input.default, text: binding).fieldBox()
        }
    }

    private func run() {
        running = true
        error = nil
        Task {
            do {
                try await model.dispatch(workflow, ref: ref.trimmingCharacters(in: .whitespaces), inputs: values, in: repo)
                model.sheet = nil
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

// MARK: - New branch

struct NewBranchSheet: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let base: String
    @State private var name = ""
    @State private var from = ""
    @State private var working = false
    @FocusState private var focused: Bool

    /// "INFRA-61 teleport rules" → "feat/INFRA-61-teleport-rules"
    private var cleaned: String {
        var text = name.trimmingCharacters(in: .whitespaces)
        if !text.contains("/") && !text.isEmpty { text = "feat/" + text }
        return text.replacingOccurrences(of: " ", with: "-")
    }

    var body: some View {
        SheetFrame(title: "New branch in \(repo.name)", symbol: "arrow.triangle.branch") {
            Field(label: "Name", hint: cleaned.isEmpty || cleaned == name ? "" : "Creates \(cleaned)") {
                TextField("feat/TICKET-1-short-name", text: $name).font(.system(size: 12.5, design: .monospaced)).fieldBox()
                    .focused($focused)
                    .onSubmit(create)
            }
            Field(label: "Starting from", hint: "A branch, tag or commit; the branch you are on when empty. Your uncommitted changes come along.") {
                TextField(base, text: $from).font(.system(size: 12.5, design: .monospaced)).fieldBox()
            }
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(working ? "Creating…" : "Create and Switch") { create() }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(cleaned.isEmpty || working)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { focused = true }
    }

    private func create() {
        guard !cleaned.isEmpty else { return }
        working = true
        Task {
            if await model.createBranch(cleaned, base: from.trimmingCharacters(in: .whitespaces), in: repo) {
                model.sheet = nil
            }
            working = false
        }
    }
}

// MARK: - Reword

struct RewordSheet: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let commit: HistoryCommit
    @State private var message = ""
    @State private var working = false

    var body: some View {
        SheetFrame(title: "Reword \(commit.short)", symbol: "pencil") {
            TextEditor(text: $message)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(5)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            if !commit.unpushed {
                Label("This commit is already on the server: after rewording, the branch needs a force push.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.yellow)
            }
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(working ? "Saving…" : "Reword") { save() }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(working || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .task {
            struct Params: Encodable, Sendable {
                var path: String
                var rev: String
            }
            if let clone = model.clone(of: repo),
               let result: MessageResult = try? await model.core.call("repo.message", Params(path: clone.path, rev: commit.sha)) {
                message = result.message
            } else {
                message = commit.subject
            }
        }
    }

    private func save() {
        working = true
        Task {
            if let remotes = await model.rewrite(.reword, sha: commit.sha, message: message, in: repo) {
                model.sheet = nil
                model.confirm(title: "Reword a commit that is on the server?",
                              message: "\(commit.short) is already on \(remotes.joined(separator: ", ")). Rewording rewrites it and the commits after it; the branch then needs a force push, and anyone who has it must reset.",
                              button: "Reword Anyway", destructive: true) {
                    Task { _ = await model.rewrite(.reword, sha: commit.sha, message: message, confirm: true, in: repo) }
                }
            } else {
                model.sheet = nil
            }
            working = false
        }
    }
}

// MARK: - Pull all

/// Fetches every clone of the workspace, then offers to fast-forward the
/// branches that are behind, like gitnest's pull all.
/// Everything of the workspace, here and current: what is not cloned is
/// cloned, then what is behind the server is pulled.
struct GetAllSheet: View {
    @Environment(AppModel.self) private var model
    @State private var done: Set<ForgeRepo.ID> = []
    @State private var working = false

    var body: some View {
        let missing = model.repos.filter { model.clone(of: $0) == nil && $0.empty != true }
        let cloned = model.repos.count { model.clone(of: $0) != nil }
        SheetFrame(title: "Get all of \(model.workspace?.title ?? "the workspace")", symbol: "square.and.arrow.down.on.square") {
            Text("\(model.repos.count) repositories: \(cloned) cloned here, \(missing.count) not yet\(model.repos.count { $0.empty == true } > 0 ? ", \(model.repos.count { $0.empty == true }) empty" : "").")
                .foregroundStyle(Theme.secondary)
            if let folder = model.workdir {
                Label("New clones go to \(folder)/\(model.workspace?.host ?? "server")/\(model.workspace?.owner ?? "owner")/", systemImage: "folder")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(2)
            }
            if working {
                ProgressView(value: Double(done.count), total: Double(max(1, missing.count + done.count)))
                Text("Cloned \(done.count)…").font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
            } else if !missing.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(missing) { repo in
                            Label(repo.name, systemImage: "arrow.down.circle").font(.system(size: 12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            Text("Then every clone is fetched, and the branches behind the server are pulled (fast-forward only: nothing of yours is changed).")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle()).disabled(working)
            Button(missing.isEmpty ? "Pull All…" : working ? "Cloning…" : "Clone \(missing.count), Then Pull") { start(missing) }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(working)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func start(_ missing: [ForgeRepo]) {
        guard !missing.isEmpty else { model.sheet = .pullAll; return }
        working = true
        Task {
            await model.clone(missing) { repo in done.insert(repo.id) }
            working = false
            model.sheet = .pullAll
        }
    }
}

struct PullAllSheet: View {
    @Environment(AppModel.self) private var model
    @State private var phase: Phase = .fetching
    @State private var result: FetchAllResult?
    @State private var chosen: Set<String> = []
    @State private var pulled: FastForwardResult?

    enum Phase { case fetching, choosing, pulling, done }

    var body: some View {
        SheetFrame(title: "Pull all in \(model.workspace?.title ?? "the workspace")", symbol: "arrow.down.circle") {
            switch phase {
            case .fetching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching \(model.repos.filter { model.clone(of: $0) != nil }.count) repositories…").foregroundStyle(Theme.secondary)
                }
            case .choosing, .pulling:
                choose
            case .done:
                summary
            }
        } actions: {
            if let result {
                let failed = result.results.filter { $0.error != nil }.count
                if failed > 0 {
                    Label("\(failed) could not be fetched", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.red)
                        .help(result.results.compactMap { r in r.error.map { "\(name(r.path)): \($0)" } }.joined(separator: "\n"))
                }
            }
            Spacer()
            if phase == .done {
                Button("Done") { model.sheet = nil }.buttonStyle(ChipButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
                Button(phase == .pulling ? "Pulling…" : "Pull \(chosen.count)") { pull() }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(phase != .choosing || chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task {
            result = await model.fetchAll()
            chosen = Set(result?.rows.filter(\.ok).map(\.id) ?? [])
            phase = (result?.rows.isEmpty ?? true) ? .done : .choosing
        }
    }

    private func name(_ path: String) -> String {
        model.forgeRepo(forClone: path)?.name ?? (path as NSString).lastPathComponent
    }

    @ViewBuilder private var choose: some View {
        let rows = result?.rows ?? []
        Text("\(rows.count) \(rows.count == 1 ? "branch is" : "branches are") behind the server.").foregroundStyle(Theme.secondary)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { HLine() }
                    Toggle(isOn: Binding(get: { chosen.contains(row.id) }, set: { on in
                        if on { chosen.insert(row.id) } else { chosen.remove(row.id) }
                    })) {
                        HStack(spacing: 8) {
                            Text(name(row.path)).lineLimit(1)
                            Text(row.branch).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                            Text("↓\(row.behind)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.purple)
                            Spacer(minLength: 4)
                            if !row.note.isEmpty {
                                Text(row.note).font(.system(size: 11)).foregroundStyle(row.ok ? Theme.tertiary : Theme.orange).lineLimit(1)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!row.ok || phase == .pulling)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                }
            }
        }
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }

    @ViewBuilder private var summary: some View {
        if let pulled {
            let failed = pulled.results.filter { $0.error != nil }
            Label("Pulled \(pulled.results.count - failed.count) of \(pulled.results.count) \(pulled.results.count == 1 ? "branch" : "branches").", systemImage: "checkmark.circle")
                .foregroundStyle(failed.isEmpty ? Theme.green : Theme.secondary)
            ForEach(failed, id: \.self) { item in
                Label("\(name(item.path)) \(item.branch): \(item.error ?? "")", systemImage: "xmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.red).lineLimit(3)
            }
        } else {
            Label("Everything is up to date.", systemImage: "checkmark.circle").foregroundStyle(Theme.green)
        }
    }

    private func pull() {
        guard let rows = result?.rows.filter({ chosen.contains($0.id) }), !rows.isEmpty else { return }
        phase = .pulling
        Task {
            pulled = await model.fastForward(rows)
            phase = .done
        }
    }
}

// MARK: - Confirmations and toasts

struct ConfirmLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let question = model.confirmation {
                Color.black.opacity(0.45)
                    .onTapGesture { model.confirmation = nil }
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: question.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(question.destructive ? Theme.orange : Theme.blue)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(question.title).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(question.message).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") { model.confirmation = nil }
                            .buttonStyle(ChipButtonStyle())
                            .keyboardShortcut(.cancelAction)
                        // Something that cannot be undone takes a click (or ⌘⌫), never
                        // a Return pressed out of habit.
                        Button(question.button) {
                            model.confirmation = nil
                            question.action()
                        }
                        .buttonStyle(DangerButtonStyle(destructive: question.destructive))
                        .keyboardShortcut(question.destructive ? KeyboardShortcut(.delete, modifiers: .command) : .defaultAction)
                    }
                }
                .padding(18)
                .frame(width: 420)
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.26, bounce: 0.15), value: model.confirmation?.id)
    }
}

struct DangerButtonStyle: ButtonStyle {
    var destructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(.white)
            .background((destructive ? Theme.red : Theme.blue).opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

struct ToastLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            ForEach(model.toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.kind == .error ? "exclamationmark.triangle.fill" : toast.kind == .success ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(toast.kind == .error ? Theme.red : toast.kind == .success ? Theme.green : Theme.blue)
                    Text(toast.text).font(.system(size: 12.5)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss", systemImage: "xmark") { model.toasts.removeAll { $0.id == toast.id } }
                        .labelStyle(.iconOnly).buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: 520)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(!model.toasts.isEmpty)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: model.toasts)
    }
}

// MARK: - Review

struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let pull: PullRequest
    @State private var event: AppModel.ReviewEvent = .approve
    @State private var text = ""
    @State private var working = false

    var body: some View {
        SheetFrame(title: "Review #\(pull.number)", symbol: "eye") {
            Text(pull.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
            Segments(options: [(AppModel.ReviewEvent.approve, "Approve"), (.requestChanges, "Request Changes"), (.comment, "Comment")], selection: $event)
            Field(label: event == .approve ? "Comment (optional)" : "Comment") {
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .padding(5)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            }
            Text("On \(String(pull.head.sha.prefix(7))), the commit you are looking at.").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(working ? "Sending…" : event == .approve ? "Approve" : event == .requestChanges ? "Request Changes" : "Comment") {
                working = true
                Task {
                    if await model.submitReview(event, body: text, pull: pull, in: repo) { model.sheet = nil }
                    working = false
                }
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .disabled(working || (event != .approve && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

// MARK: - Merge

struct MergeSheet: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let pull: PullRequest
    @State private var style = "merge"
    @State private var deleteBranch = true
    @State private var working = false
    @State private var planning = true

    private var extra: PullExtras? {
        model.slug(repo).flatMap { model.extras[AppModel.extrasKey($0, pull.number)] }
    }

    /// The plan of the pull request's head commit, once its pipeline has one.
    private var plan: TerraformPlan? { extra?.plan }
    private var planFailed: Bool { !(extra?.planError ?? []).isEmpty || extra?.pullRuns.first?.state == .failure }

    /// Merging into the default branch of a Terraform repository applies.
    private var applies: Bool {
        pull.base.ref == (repo.defaultBranch ?? "main") && model.forgeState(repo).runs.contains { run in
            "\(run.workflowID ?? "") \(run.title)".lowercased().contains("terraform") || "\(run.workflowID ?? "")".lowercased().contains("tofu")
        }
    }

    var body: some View {
        SheetFrame(title: "Merge #\(pull.number)", symbol: "arrow.triangle.merge") {
            Text(pull.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
            HStack(spacing: 6) {
                Text(pull.head.ref).font(.system(size: 12, design: .monospaced))
                Image(systemName: "arrow.right").foregroundStyle(Theme.tertiary)
                Text(pull.base.ref).font(.system(size: 12, design: .monospaced))
            }
            .foregroundStyle(Theme.secondary)
            Segments(options: [("merge", "Merge Commit"), ("squash", "Squash"), ("rebase", "Rebase")], selection: $style)
            Toggle("Delete \(pull.head.ref) after merging", isOn: $deleteBranch)
                .toggleStyle(.checkbox)
                .disabled(pull.head.ref == "develop" || pull.head.ref == (repo.defaultBranch ?? "main"))
            if applies {
                Label("Merging into \(pull.base.ref) starts the Terraform apply.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.yellow)
            }
            // What the merge is about to do: the plan of this very commit.
            if let plan {
                PlanSummary(plan: plan, limit: 6)
                if plan.destroy > 0 {
                    Label("The plan destroys \(plan.destroy) \(plan.destroy == 1 ? "resource" : "resources"). Read it before you merge.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.red)
                }
            } else if planning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the plan…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            } else if applies {
                Label(planFailed ? "The plan of this commit failed." : "No finished plan for this commit yet.", systemImage: "questionmark.circle")
                    .font(.system(size: 12)).foregroundStyle(planFailed ? Theme.red : Theme.secondary)
            }
            if let required = model.requiredApprovals(pull, in: repo), model.forgeState(repo).summary(for: pull).approvals < required {
                Label("It has fewer approvals than the \(required) the branch requires; the server may refuse.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(working ? "Merging…" : "Merge") {
                working = true
                Task {
                    if await model.merge(pull, style: style, deleteBranch: deleteBranch, in: repo) { model.sheet = nil }
                    working = false
                }
            }
            .buttonStyle(DangerButtonStyle(destructive: false))
            .disabled(working)
            .keyboardShortcut(.defaultAction)
        }
        .task {
            await model.loadExtras(pull, in: repo, ifOlderThan: 20)
            planning = false
        }
        .onAppear {
            // develop is long-lived: never delete it by default.
            deleteBranch = pull.head.ref != "develop" && pull.head.ref != (repo.defaultBranch ?? "main")
        }
    }
}

// MARK: - A pull request's diff

struct DiffModalLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { window in
            if let target = model.diffTarget {
                ZStack {
                    Color.black.opacity(0.5)
                        .onTapGesture { model.diffTarget = nil }
                        .transition(.opacity)
                    DiffWindow(target: target)
                        .id(target)
                        .frame(width: min(1180, window.size.width - 120), height: min(820, window.size.height - 100))
                        .background(Theme.window, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                        .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
                        .transition(.scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(y: 14)))
                }
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: model.diffTarget)
    }
}

private struct DiffWindow: View {
    @Environment(AppModel.self) private var model
    let target: DiffTarget
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Theme.secondary)
                Text(target.file ?? target.title).font(.system(size: 13, weight: .medium, design: target.file == nil ? .default : .monospaced)).lineLimit(1)
                Text("#\(target.number)").foregroundStyle(Theme.tertiary)
                Spacer()
                if target.file != nil {
                    Button("Whole Diff") { model.diffTarget = DiffTarget(repo: target.repo, number: target.number, title: target.title, file: nil) }
                        .buttonStyle(ChipButtonStyle())
                }
                Button("Close", systemImage: "xmark") { model.diffTarget = nil }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            HLine()
            if let error {
                EmptyState("Cannot read the diff", symbol: "exclamationmark.triangle", message: error)
            } else if let text {
                if text.isEmpty {
                    EmptyState("No changes", symbol: "doc")
                } else {
                    PatchText(text: text)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: target) {
            do {
                text = try await model.pullDiff(target)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Start work in several repositories

struct StartWorkSheet: View {
    @Environment(AppModel.self) private var model
    let preselected: ForgeRepo.ID?
    @State private var name = ""
    @State private var chosen: Set<ForgeRepo.ID> = []
    @State private var fromServer = true
    @State private var working = false
    @FocusState private var focused: Bool

    private var cloned: [ForgeRepo] { model.repos.filter { model.clone(of: $0) != nil } }

    private var branch: String {
        var text = name.trimmingCharacters(in: .whitespaces)
        if !text.contains("/") && !text.isEmpty { text = "feat/" + text }
        return text.replacingOccurrences(of: " ", with: "-")
    }

    var body: some View {
        SheetFrame(title: "Start work in several repositories", symbol: "square.stack.3d.up") {
            Field(label: "Branch", hint: branch.isEmpty || branch == name ? "The same branch in every repository you choose." : "Creates \(branch)") {
                TextField("INFRA-99 short description", text: $name).font(.system(size: 12.5, design: .monospaced)).fieldBox()
                    .focused($focused)
            }
            Toggle("Start from the server's develop (or default branch), fetched first", isOn: $fromServer)
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
            Field(label: "Repositories · \(chosen.count) chosen") {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(cloned.enumerated()), id: \.element.id) { index, repo in
                            if index > 0 { HLine() }
                            let clone = model.clone(of: repo)
                            Toggle(isOn: Binding(get: { chosen.contains(repo.id) }, set: { on in
                                if on { chosen.insert(repo.id) } else { chosen.remove(repo.id) }
                            })) {
                                HStack(spacing: 8) {
                                    Text(repo.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(clone?.branch ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                    if let clone, clone.changes > 0 {
                                        Text("●\(clone.changes)").font(.system(size: 11)).foregroundStyle(Theme.orange)
                                            .help("Uncommitted changes come along to the new branch")
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            }
            if cloned.isEmpty {
                Text("Clone the repositories first.").foregroundStyle(Theme.secondary)
            }
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(working ? "Creating…" : "Create in \(chosen.count)") {
                working = true
                let repos = cloned.filter { chosen.contains($0.id) }
                Task {
                    await model.startWork(branch, in: repos, fromServer: fromServer)
                    working = false
                    model.sheet = nil
                }
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .disabled(working || branch.isEmpty || chosen.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            if let suggested = model.startWorkName { name = suggested; model.startWorkName = nil }
            focused = true
            if let preselected { chosen = [preselected] }
        }
    }
}

// MARK: - Pull requests for one branch in every repository

struct OpenPullsSheet: View {
    @Environment(AppModel.self) private var model
    let branch: String
    @State private var drafts: [Row] = []
    @State private var loading = true
    @State private var working = false

    struct Row: Identifiable {
        var repo: ForgeRepo
        var base: String
        var draft: ReleaseDraft?
        var error: String?
        var title: String
        var on: Bool
        var id: String { repo.id.description }
    }

    var body: some View {
        SheetFrame(title: "Pull requests for \(branch)", symbol: "arrow.triangle.pull") {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Comparing \(branch) in each repository…").foregroundStyle(Theme.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach($drafts) { $row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Toggle("", isOn: $row.on).toggleStyle(.checkbox).labelsHidden()
                                .disabled(!row.canOpen)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(row.repo.name).font(.system(size: 12.5, weight: .medium))
                                    Text("→ \(row.base)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
                                    Spacer(minLength: 4)
                                    Text(row.status).font(.system(size: 11.5)).foregroundStyle(row.canOpen ? Theme.secondary : Theme.tertiary)
                                }
                                if row.canOpen {
                                    TextField("Title", text: $row.title).fieldBox()
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        HLine()
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(working ? "Opening…" : "Open \(drafts.filter { $0.on && $0.canOpen }.count)") { open() }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(working || loading || !drafts.contains { $0.on && $0.canOpen })
                .keyboardShortcut(.defaultAction)
        }
        .task { await load() }
    }

    private func load() async {
        let work = model.workInProgress.first { $0.branch == branch }
        var rows: [Row] = []
        for item in work?.items ?? [] {
            let base = await model.defaultBase(for: branch, in: item.repo)
            do {
                let draft = try await model.releaseDraft(item.repo, head: branch, base: base, release: false)
                rows.append(Row(repo: item.repo, base: base, draft: draft, title: draft.title, on: draft.existing == nil && !draft.commits.isEmpty))
            } catch {
                rows.append(Row(repo: item.repo, base: base, draft: nil,
                                error: item.clone.hasUpstream ? error.localizedDescription : "not pushed yet", title: "", on: false))
            }
        }
        drafts = rows
        loading = false
    }

    private func open() {
        working = true
        Task {
            var opened = 0
            for row in drafts where row.on && row.canOpen {
                do {
                    try await model.createRelease(row.repo, head: branch, base: row.base, title: row.title, body: row.draft?.body ?? "")
                    opened += 1
                } catch {
                    model.toast("\(row.repo.name): \(error.localizedDescription)", .error)
                }
            }
            model.pendingPull = nil
            if opened > 1 { model.toast("Opened \(opened) pull requests for \(branch)") }
            working = false
            model.sheet = nil
        }
    }
}

private extension OpenPullsSheet.Row {
    var canOpen: Bool { draft != nil && draft?.existing == nil && !(draft?.commits.isEmpty ?? true) }

    var status: String {
        if let error { return error }
        guard let draft else { return "" }
        if let existing = draft.existing { return "#\(existing.number) is open" }
        if draft.commits.isEmpty { return "nothing to merge" }
        return "\(draft.commits.count) \(draft.commits.count == 1 ? "commit" : "commits")"
    }
}

// MARK: - New tag

struct NewTagSheet: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let rev: String
    let label: String
    @State private var name = ""
    @State private var message = ""
    @State private var push = true
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        SheetFrame(title: "Tag in \(repo.name)", symbol: "tag") {
            Text("On \(label)").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            Field(label: "Name", hint: "Versions like v1.2.0 are what module sources pin with ?ref=.") {
                TextField("v1.0.0", text: $name).font(.system(size: 12.5, design: .monospaced)).fieldBox().focused($focused)
            }
            Field(label: "Message (makes an annotated tag)") {
                TextField("Release notes in one line", text: $message).fieldBox()
            }
            Toggle("Push the tag to the server", isOn: $push).toggleStyle(.checkbox).font(.system(size: 12.5))
        } actions: {
            Spacer()
            Button("Cancel") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            Button(working ? "Tagging…" : push ? "Tag and Push" : "Tag") {
                let tag = name.trimmingCharacters(in: .whitespaces)
                working = true
                Task {
                    if await model.tag(.create, tag, rev: rev, message: message, in: repo) {
                        if push { await model.tag(.push, tag, in: repo) }
                        model.sheet = nil
                    }
                    working = false
                }
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear { focused = true }
    }
}


// MARK: - Releases across repositories

/// Every repository where develop is ahead of the default branch: what a
/// release would ship, and the pull request for it.
struct ReleasesSheet: View {
    @Environment(AppModel.self) private var model
    @State private var candidates: [ReleaseCandidate] = []
    @State private var loading = true
    @State private var progress = (done: 0, of: 0)
    @State private var working = false

    private var missing: [ReleaseCandidate] { candidates.filter { $0.draft.existing == nil } }

    var body: some View {
        SheetFrame(title: "Releases · \(model.workspace?.title ?? "")", symbol: "paperplane") {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.of > 0 ? "Comparing develop with the default branch… \(progress.done)/\(progress.of)" : "Comparing develop with the default branch…")
                        .foregroundStyle(Theme.secondary).monospacedDigit()
                }
            } else if candidates.isEmpty {
                Label("Nothing waits on develop: every repository is released.", systemImage: "checkmark.circle").foregroundStyle(Theme.green)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { candidate in
                            row(candidate)
                            HLine()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        } actions: {
            if !loading, !candidates.isEmpty {
                Text("\(candidates.count) \(candidates.count == 1 ? "repository" : "repositories") · \(candidates.reduce(0) { $0 + $1.draft.commits.count }) commits")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Close") { model.sheet = nil }.buttonStyle(ChipButtonStyle())
            if !missing.isEmpty {
                Button(working ? "Opening…" : "Open \(missing.count) Pull \(missing.count == 1 ? "Request" : "Requests")") {
                    let repos = missing.map(\.repo.name).joined(separator: ", ")
                    model.confirm(title: "Open \(missing.count) release pull \(missing.count == 1 ? "request" : "requests")?",
                                  message: "develop → the default branch in: \(repos). Nothing is merged; each pull request still needs its review.",
                                  button: "Open") {
                        working = true
                        Task {
                            _ = await model.openReleases(missing)
                            await load()
                            working = false
                        }
                    }
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(working)
            }
        }
        .task { await load() }
    }

    private func row(_ candidate: ReleaseCandidate) -> some View {
        let draft = candidate.draft
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(candidate.repo.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text("\(draft.commits.count) \(draft.commits.count == 1 ? "commit" : "commits")")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    ForEach(draft.tickets.prefix(4), id: \.self) { ticket in
                        Badge(text: ticket, color: Theme.yellow, filled: false)
                    }
                }
                ForEach(draft.commits.prefix(3)) { commit in
                    Text(commit.subject).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                if draft.commits.count > 3 {
                    Text("and \(draft.commits.count - 3) more").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let existing = draft.existing {
                Button("#\(existing.number)") {
                    model.sheet = nil
                    Task {
                        await model.openPull(host: model.workspace?.host ?? "", fullName: candidate.repo.fullName, number: existing.number, url: existing.htmlURL)
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .help("The release pull request is open")
            } else {
                Button("Release…") {
                    model.selection = candidate.repo.id
                    model.section = .repositories
                    model.sheet = .release(candidate.repo)
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
        .padding(.vertical, 8)
    }

    private func load() async {
        loading = true
        candidates = await model.releaseCandidates { done, of in progress = (done, of) }
        loading = false
    }
}
