import AppKit
import SwiftUI

/// What else can be done with a pull request: edit, draft, update its
/// branch, close.
struct PullMenu: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let pull: PullRequest

    var body: some View {
        if pull.merged != true {
            Dropdown(id: "pull-menu-\(pull.number)", width: 250) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 26)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            } content: {
                if pull.state == "open" {
                    DropdownItem(title: "Edit Title and Description…", symbol: "pencil") { model.sheet = .editPull(repo, pull) }
                    let draft = AppModel.isDraft(pull)
                    DropdownItem(title: draft ? "Mark as Ready for Review" : "Mark as Draft", symbol: draft ? "checkmark.circle" : "pencil.and.outline") {
                        Task { await model.setDraft(!draft, pull, in: repo) }
                    }
                    DropdownDivider()
                    DropdownHeader(text: "Bring in \(pull.base.ref)")
                    DropdownItem(title: "Update Branch by Merge", symbol: "arrow.triangle.merge") {
                        Task { await model.updateBranch(of: pull, in: repo, rebase: false) }
                    }
                    DropdownItem(title: "Update Branch by Rebase", symbol: "arrow.triangle.branch") {
                        model.confirm(title: "Rebase \(pull.head.name) onto \(pull.base.ref)?",
                                      message: "The branch's commits are rewritten on the server. Anyone who has it checked out must reset to the new history.",
                                      button: "Rebase") {
                            Task { await model.updateBranch(of: pull, in: repo, rebase: true) }
                        }
                    }
                    DropdownDivider()
                    DropdownItem(title: "Close Without Merging…", symbol: "xmark.circle") {
                        model.confirm(title: "Close #\(pull.number) without merging?", message: "The pull request stays on the server and can be reopened.",
                                      button: "Close Pull Request", destructive: true) {
                            Task { await model.setOpen(false, pull, in: repo) }
                        }
                    }
                } else {
                    DropdownItem(title: "Reopen", symbol: "arrow.uturn.backward") { Task { await model.setOpen(true, pull, in: repo) } }
                }
            }
            .help("More: edit, draft, update the branch, close")
            .accessibilityLabel("More actions")
            .needsWrite()
        }
    }
}

/// Why the pull request cannot be merged, and the ways out.
struct ConflictCard: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let pull: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Conflicts with \(pull.base.ref)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.red)
            Text("\(pull.base.ref) changed the same lines since \(pull.head.name) was started. It cannot be merged until the branch takes those changes in and the conflicts are resolved in a clone.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if model.clone(of: repo) != nil {
                    Button("Resolve in Changes") {
                        model.repoTab = .changes
                        model.toast("Check out \(pull.head.name), then merge \(pull.base.ref) into it: the conflicts show here.", .info)
                    }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                }
                Button("Try Update by Merge") { Task { await model.updateBranch(of: pull, in: repo, rebase: false) } }
                    .buttonStyle(ChipButtonStyle())
                    .help("Works when the server can merge without help; real conflicts need a clone")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.red.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.red.opacity(0.35)))
    }
}

/// Reviewers, assignees and labels: who is asked, who owns it, what it is.
struct PeopleCard: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let pull: PullRequest
    @State private var reviewers: [ForgeUser] = []
    @State private var assignees: [ForgeUser] = []
    @State private var labels: [ForgeLabel] = []

    var body: some View {
        let asked = Set((pull.requestedReviewers ?? []).map(\.login))
        let assigned = Set((pull.assignees ?? []).map(\.login))
        let labelled = Set((pull.labels ?? []).map(\.name))
        Card("People and labels") {
            row("Reviewers", (pull.requestedReviewers ?? []).map(\.displayName), empty: "nobody asked") {
                if reviewers.isEmpty { DropdownHeader(text: "Nobody else can review here.") }
                ForEach(reviewers, id: \.login) { user in
                    DropdownItem(title: user.displayName, symbol: "eye", detail: user.login, checked: asked.contains(user.login)) {
                        Task { await model.requestReview(of: pull, in: repo, from: user, withdraw: asked.contains(user.login)) }
                    }
                }
            }
            row("Assignees", (pull.assignees ?? []).map(\.displayName), empty: "nobody") {
                ForEach(assignees, id: \.login) { user in
                    DropdownItem(title: user.displayName, symbol: "person", detail: user.login, checked: assigned.contains(user.login)) {
                        var now = assigned
                        if now.contains(user.login) { now.remove(user.login) } else { now.insert(user.login) }
                        Task { await model.setAssignees(now.sorted(), on: pull, in: repo) }
                    }
                }
            }
            row("Labels", (pull.labels ?? []).map(\.name), empty: labels.isEmpty ? "none in this repository" : "none") {
                if labels.isEmpty { DropdownHeader(text: "This repository has no labels.") }
                ForEach(labels) { label in
                    DropdownItem(title: label.name, symbol: "tag", checked: labelled.contains(label.name)) {
                        var ids = Set(labels.filter { labelled.contains($0.name) }.map(\.id))
                        if ids.contains(label.id) { ids.remove(label.id) } else { ids.insert(label.id) }
                        Task { await model.setLabels(ids.sorted(), on: pull, in: repo) }
                    }
                }
            }
        }
        .task(id: pull.number) {
            async let r = model.reviewerCandidates(pull, in: repo)
            async let a = model.assigneeCandidates(in: repo)
            async let l = model.repoLabels(in: repo)
            (reviewers, assignees, labels) = await (r, a, l)
        }
    }

    private func row(_ title: String, _ values: [String], empty: String, @ViewBuilder menu: @escaping () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Theme.secondary).frame(width: 74, alignment: .leading)
            Text(values.isEmpty ? empty : values.joined(separator: ", "))
                .foregroundStyle(values.isEmpty ? Theme.tertiary : Theme.text).lineLimit(2)
            Spacer(minLength: 4)
            Dropdown(id: "people-\(title)-\(pull.number)", width: 250) {
                Text("Change").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.blue)
            } content: {
                ScrollView { VStack(spacing: 0) { menu() } }.frame(maxHeight: 300)
            }
            .accessibilityLabel("Change \(title.lowercased())")
            .needsWrite()
        }
        .font(.system(size: 12))
    }
}

/// The pull request's conversation: comments, what reviewers wrote, their
/// remarks on lines; and a box to answer.
struct ConversationCard: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let pull: PullRequest
    let comments: [IssueComment]
    let lineComments: [ReviewComment]
    let reviews: [Review]
    let loaded: Bool
    @State private var reply = ""
    @State private var sending = false

    private struct Entry: Identifiable {
        var id: String
        var user: ForgeUser?
        var when: Date?
        var kind: String
        var tint: Color
        var body: String
        var path: String?
        var context: [String] = []
        var resolved = false
    }

    private var entries: [Entry] {
        var all: [Entry] = comments.map { Entry(id: "c\($0.id)", user: $0.user, when: $0.createdAt, kind: "commented", tint: Theme.secondary, body: $0.body) }
        for review in reviews where !(review.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (kind, tint): (String, Color) = switch review.state {
            case "APPROVED": ("approved", Theme.green)
            case "REQUEST_CHANGES": ("requested changes", Theme.orange)
            default: ("reviewed", Theme.secondary)
            }
            all.append(Entry(id: "r\(review.id)", user: review.user, when: review.submittedAt, kind: kind, tint: tint, body: review.body ?? ""))
        }
        all += lineComments.map {
            Entry(id: "l\($0.id)", user: $0.user, when: $0.createdAt, kind: "on a line", tint: Theme.blue, body: $0.body, path: $0.path,
                  context: $0.context, resolved: $0.resolver != nil)
        }
        return all.sorted { ($0.when ?? .distantPast) < ($1.when ?? .distantPast) }
    }

    var body: some View {
        let entries = entries
        Card("Conversation") {
            if !entries.isEmpty { Text("\(entries.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        } content: {
            if !loaded && entries.isEmpty { ProgressView().controlSize(.small) }
            if loaded && entries.isEmpty { Text("Nobody has written anything yet.").foregroundStyle(Theme.secondary) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(entry.user?.displayName ?? "someone").font(.system(size: 12, weight: .semibold)).help(entry.user?.login ?? "")
                        Text(entry.kind).font(.system(size: 11.5)).foregroundStyle(entry.tint)
                        if entry.resolved { Badge(text: "resolved", color: Theme.green, filled: false) }
                        if let when = entry.when { Text(when.relative).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                        Spacer(minLength: 0)
                    }
                    if let path = entry.path {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                            ForEach(Array(entry.context.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                    .foregroundStyle(line.hasPrefix("+") ? Theme.green : line.hasPrefix("-") ? Theme.red : Theme.tertiary)
                            }
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text(LocalizedStringKey(entry.body)).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
                .opacity(entry.resolved ? 0.6 : 1)
            }
            VStack(alignment: .trailing, spacing: 6) {
                TextEditor(text: $reply)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(height: 54)
                    .padding(5)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    .overlay(alignment: .topLeading) {
                        if reply.isEmpty {
                            Text("Write a comment…").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).padding(.horizontal, 10).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Comment")
                Button(sending ? "Sending…" : "Comment") {
                    sending = true
                    Task {
                        if await model.comment(on: pull, in: repo, text: reply) { reply = "" }
                        sending = false
                    }
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .needsWrite()
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘↩")
            }
        }
    }
}

/// The server's releases, above the clone's tags.
struct ReleasesList: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @State private var releases: [ForgeRelease] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !releases.isEmpty {
                Text("RELEASES ON THE SERVER").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                ForEach(releases) { release in
                    Button {
                        if let url = release.htmlURL.flatMap(URL.init) { openExternal(url) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox.fill").font(.system(size: 11)).foregroundStyle(Theme.brand).frame(width: 16)
                            Text(release.name?.isEmpty == false ? release.name! : release.tagName).font(.system(size: 12.5, weight: .medium))
                            Text(release.tagName).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
                            if release.draft == true { Badge(text: "draft", color: Theme.secondary, filled: false) }
                            if release.prerelease == true { Badge(text: "pre-release", color: Theme.orange, filled: false) }
                            Spacer(minLength: 4)
                            Text(release.author?.displayName ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                            if let when = release.publishedAt { Text(when.relative).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverBackground(radius: 0)
                    .help("Open the release on the server")
                }
                Text("TAGS IN THE CLONE").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            }
        }
        .task(id: repo.id) { releases = await model.releases(of: repo) }
    }
}

/// The names Actions knows in this repository: variables with their
/// values, secrets by name only.
struct ActionSettingsButton: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @State private var open = false
    @State private var variables: [ActionVariable] = []
    @State private var secrets: [ActionSecret] = []
    @State private var state = "loading"

    var body: some View {
        Button("Variables", systemImage: "key") { open = true }
            .buttonStyle(ChipButtonStyle())
            .help("The variables and secrets Actions has in this repository")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    switch state {
                    case "loading": ProgressView().controlSize(.small)
                    case "denied": Text("This account may not see the repository's variables and secrets.").foregroundStyle(Theme.secondary)
                    default:
                        Text("Variables").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                        if variables.isEmpty { Text("None.").foregroundStyle(Theme.tertiary) }
                        ForEach(variables) { variable in
                            HStack(spacing: 8) {
                                Text(variable.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text(variable.data ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1).textSelection(.enabled)
                            }
                        }
                        Text("Secrets").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.top, 4)
                        if secrets.isEmpty { Text("None.").foregroundStyle(Theme.tertiary) }
                        ForEach(secrets) { secret in
                            HStack(spacing: 8) {
                                Text(secret.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text("value hidden").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(14)
                .frame(width: 360, alignment: .leading)
                .background(Theme.window)
                .task {
                    if let found = await model.actionSettings(of: repo) {
                        variables = found.variables; secrets = found.secrets; state = "shown"
                    } else {
                        state = "denied"
                    }
                }
            }
    }
}

/// Tickets assigned to the user in Jira, with the work that belongs to them.
struct JiraCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.jira
        Card("Jira · Your tickets") {
            HStack(spacing: 8) {
                if let site = model.jiraSettings?.site { Text(site).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                if state.loaded { Text("\(state.issues.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
        } content: {
            if !state.loaded { ProgressView().controlSize(.small) }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.loaded, state.error == nil, state.issues.isEmpty {
                Text("No open ticket is assigned to you.").foregroundStyle(Theme.secondary)
            }
            ForEach(state.issues.prefix(12)) { issue in
                let work = model.work(for: issue)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Button { model.ticketTarget = issue.key } label: {
                            HStack(spacing: 7) {
                                Text(issue.key).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.blue)
                                Text(issue.fields.summary).lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).linkCursor().help("Open \(issue.key): \(issue.fields.summary)")
                        .accessibilityLabel("Ticket \(issue.key)")
                        JiraStatusButton(issue: issue)
                    }
                    HStack(spacing: 6) {
                        ForEach(work.pulls) { pull in
                            Button {
                                Task { await model.openPull(host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL) }
                            } label: {
                                HStack(spacing: 4) {
                                    CheckIcon(state: pull.state, size: 10)
                                    Text("\(pull.repoFullName.split(separator: "/").last ?? "") #\(pull.number)")
                                }
                                .font(.system(size: 11)).padding(.horizontal, 6).frame(height: 20)
                                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain).help(pull.title)
                        }
                        ForEach(work.branches, id: \.repo.id) { entry in
                            Button {
                                model.selection = entry.repo.id
                                model.section = .repositories
                                model.repoTab = .changes
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                                    Text(entry.repo.name)
                                }
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.horizontal, 6).frame(height: 20)
                                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain).help("\(entry.branch) is checked out in \(entry.repo.name)")
                        }
                        if work.pulls.isEmpty && work.branches.isEmpty && !issue.done {
                            Button("Start Work") {
                                model.startWorkName = "chore/\(issue.key)"
                                model.sheet = .startWork(preselected: nil)
                            }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.blue)
                            .help("A branch named after \(issue.key) in the repositories you choose")
                        }
                    }
                }
                .padding(.vertical, 2)
                .opacity(issue.done ? 0.55 : 1)
            }
            if state.issues.count > 12 {
                Text("and \(state.issues.count - 12) more in Jira").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
        }
        .leading(JiraMark())
    }
}

/// A ticket's status; a click offers where it can move.
private struct JiraStatusButton: View {
    @Environment(AppModel.self) private var model
    let issue: JiraIssue
    @State private var open = false
    @State private var moves: [JiraTransition]?

    var body: some View {
        Button { open = true } label: {
            Badge(text: issue.fields.status.name, color: issue.inProgress ? Theme.blue : issue.done ? Theme.green : Theme.secondary, filled: false)
        }
        .buttonStyle(.plain)
        .help("Move \(issue.key) to another status")
        .accessibilityLabel("Status of \(issue.key): \(issue.fields.status.name)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move \(issue.key) to").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 4)
                if let moves {
                    if moves.isEmpty { Text("Nothing else is allowed from here.").foregroundStyle(Theme.tertiary).padding(.horizontal, 8) }
                    ForEach(moves) { move in
                        Button {
                            open = false
                            Task { await model.move(issue, by: move) }
                        } label: {
                            Text(move.to?.name ?? move.name).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverBackground(radius: 5)
                    }
                } else {
                    ProgressView().controlSize(.small).padding(8)
                }
            }
            .font(.system(size: 12.5))
            .padding(8)
            .frame(width: 220, alignment: .leading)
            .background(Theme.window)
            .task { moves = await model.transitions(for: issue) }
        }
    }
}
