import AppKit
import SwiftUI

/// The ticket window: opens over the app like a pipeline's log.
struct TicketModalLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { window in
            if let key = model.ticketTarget {
                ZStack {
                    Color.black.opacity(0.5)
                        .onTapGesture { model.ticketTarget = nil }
                        .transition(.opacity)
                    TicketWindow(key: key)
                        .id(key)
                        .frame(width: min(1040, window.size.width - 120), height: min(780, window.size.height - 90))
                        .background(Theme.window, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                        .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
                        .transition(.scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(y: 14)))
                }
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: model.ticketTarget)
    }
}

/// One Jira ticket: what the browser shows, and the same things to do.
private struct TicketWindow: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State private var ticket: JiraTicket?
    @State private var moves: [JiraTransition] = []
    @State private var priorities: [String] = []
    @State private var problem: String?
    /// Jira's reason for refusing the last change ("Time Spent is required").
    @State private var refusal: String?
    @State private var working = false
    @State private var editing = false
    @State private var summary = ""
    @State private var text = ""
    @State private var comment = ""
    @State private var time = ""
    @State private var timeNote = ""
    @State private var estimate = ""
    @State private var due = ""
    @State private var labels = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                JiraMark(size: 15)
                Text(key).font(.system(size: 13, weight: .semibold, design: .monospaced))
                if let ticket {
                    Text(ticket.type).foregroundStyle(Theme.secondary)
                    Text("· \(ticket.project)").foregroundStyle(Theme.tertiary).lineLimit(1)
                    if let parent = ticket.parent {
                        Button("in \(parent)") { model.ticketTarget = parent }.buttonStyle(.plain).foregroundStyle(Theme.blue).linkCursor()
                    }
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Read the ticket again")
                Button("Open in Jira", systemImage: "arrow.up.right.square") {
                    if let url = model.jiraSettings.flatMap({ JiraClient.siteURL($0.site) })?.appending(path: "browse/\(key)") { openExternal(url) }
                }
                .buttonStyle(ChipButtonStyle())
                Button("Close Ticket Window", systemImage: "xmark") { model.ticketTarget = nil }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .frame(height: 46)
            HLine()
            if let refusal {
                // Jira would not do it: its own words, where they cannot be missed.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Theme.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jira did not allow this").font(.system(size: 12.5, weight: .semibold))
                        Text(refusal).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Dismiss") { self.refusal = nil }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.blue)
                }
                .padding(12)
                .background(Theme.orange.opacity(0.1))
                HLine()
            }
            if let problem {
                EmptyState("Cannot read \(key)", symbol: "exclamationmark.triangle", message: problem)
            } else if let ticket {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView { main(ticket).padding(16) }.frame(maxWidth: .infinity)
                    VLine()
                    ScrollView { side(ticket).padding(14) }.frame(width: 320).background(Theme.sidebar)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    // MARK: Left: what it is and what was said

    private func main(_ ticket: JiraTicket) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if editing {
                TextField("Summary", text: $summary).font(.system(size: 16, weight: .semibold)).textFieldStyle(.plain)
                    .padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                TextEditor(text: $text).font(.system(size: 12.5)).scrollContentBackground(.hidden).frame(minHeight: 160)
                    .padding(5).background(Theme.card, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    .accessibilityLabel("Description")
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }.buttonStyle(ChipButtonStyle())
                    Button("Save") {
                        change("Saved \(key)") {
                            try await $0.update(key, fields: ["summary": summary, "description": JiraTicket.document(text)])
                        } then: { editing = false }
                    }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(ticket.summary).font(.system(size: 17, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Edit", systemImage: "pencil") {
                        summary = ticket.summary
                        text = ticket.description
                        editing = true
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                Card("Description") {
                    Text(ticket.description.isEmpty ? "No description." : ticket.description)
                        .foregroundStyle(ticket.description.isEmpty ? Theme.secondary : Theme.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Card("Comments") {
                Text("\(ticket.comments.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } content: {
                if ticket.comments.isEmpty { Text("Nobody has commented yet.").foregroundStyle(Theme.secondary) }
                ForEach(ticket.comments) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.author).font(.system(size: 12, weight: .semibold))
                            if let when = item.created { Text(when.relative).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                        }
                        Text(item.body).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $comment).font(.system(size: 12.5)).scrollContentBackground(.hidden).frame(height: 58)
                        .padding(5).background(Theme.inset, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                        .overlay(alignment: .topLeading) {
                            if comment.isEmpty {
                                Text("Add a comment…").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).padding(.horizontal, 10).padding(.vertical, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("Ticket comment")
                    Button("Comment") {
                        change("Commented on \(key)") { try await $0.addComment(key, text: comment) } then: { comment = "" }
                    }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(working || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: Right: where it stands, who has it, the time

    private func side(_ ticket: JiraTicket) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                label("Status")
                Badge(text: ticket.status, color: ticket.done ? Theme.green : ticket.statusCategory == "indeterminate" ? Theme.blue : Theme.secondary)
                // The workflow's own buttons, named as Jira names them.
                if moves.isEmpty {
                    Text("No move is allowed from here.").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                ForEach(moves) { move in
                    Button {
                        change("\(key) is now \(move.to?.name ?? move.name)") { try await $0.moveTicket(key, transition: move.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(move.name)
                            Spacer(minLength: 4)
                            if let to = move.to?.name, to != move.name { Text("→ \(to)").foregroundStyle(Theme.tertiary) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(working)
                    .accessibilityLabel("Workflow: \(move.name)")
                }
            }
            HLine()
            VStack(alignment: .leading, spacing: 9) {
                label("Details")
                detail("Assignee", ticket.assignee ?? "Unassigned") {
                    if ticket.assigneeID == nil || ticket.assigneeID != model.jiraAccountID {
                        Button("Assign to Me") {
                            change("\(key) is yours") { client in try await client.assign(key, to: try await client.myAccountID()) }
                        }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.blue)
                    }
                }
                detail("Reporter", ticket.reporter ?? "—") { EmptyView() }
                detail("Priority", ticket.priority ?? "—") {
                    Menu("Change") {
                        ForEach(priorities, id: \.self) { name in
                            Button(name) { change("Priority of \(key) is \(name)") { try await $0.update(key, fields: ["priority": ["name": name]]) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11.5)).disabled(priorities.isEmpty)
                }
                field("Due date", $due, prompt: "YYYY-MM-DD") {
                    change("Due date of \(key) saved") { try await $0.update(key, fields: ["duedate": due.isEmpty ? NSNull() : due as Any]) }
                }
                field("Labels", $labels, prompt: "comma, separated") {
                    let list = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    change("Labels of \(key) saved") { try await $0.update(key, fields: ["labels": list]) }
                }
                if let created = ticket.created { detail("Created", created.relative) { EmptyView() } }
                if let updated = ticket.updated { detail("Updated", updated.relative) { EmptyView() } }
            }
            HLine()
            VStack(alignment: .leading, spacing: 9) {
                label("Time tracking")
                // Spent against the estimate, as Jira draws it.
                let fraction = ticket.estimateSeconds > 0 ? min(1, Double(ticket.spentSeconds) / Double(ticket.estimateSeconds)) : (ticket.spentSeconds > 0 ? 1 : 0)
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border)
                        Capsule().fill(ticket.estimateSeconds > 0 && ticket.spentSeconds > ticket.estimateSeconds ? Theme.orange : Theme.blue)
                            .frame(width: bar.size.width * fraction)
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(ticket.spent ?? "0m") logged").font(.system(size: 11.5))
                    Spacer()
                    Text(ticket.estimate.map { "of \($0) estimated" } ?? "no estimate").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                if let remaining = ticket.remaining { Text("\(remaining) remaining").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                field("Estimate", $estimate, prompt: "e.g. 4h") {
                    change("Estimate of \(key) saved") { try await $0.update(key, fields: ["timetracking": ["originalEstimate": estimate]]) }
                }
                HStack(spacing: 6) {
                    TextField("Time spent", text: $time, prompt: Text("1h 30m")).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 7).frame(width: 84, height: 26)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    TextField("What was done", text: $timeNote, prompt: Text("note (optional)")).textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 7).frame(height: 26)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                }
                Button("Log Time") {
                    change("Logged \(time) on \(key)") { try await $0.logWork(key, timeSpent: time, note: timeNote) } then: { time = ""; timeNote = "" }
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(working || time.trimmingCharacters(in: .whitespaces).isEmpty)
                ForEach(ticket.worklogs.suffix(5)) { log in
                    HStack {
                        Text(log.timeSpent).font(.system(size: 11.5, design: .monospaced))
                        Text(log.author).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer()
                        if let when = log.started { Text(when.relative).font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                    }
                }
            }
        }
        .font(.system(size: 12.5))
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.5).foregroundStyle(Theme.tertiary)
    }

    private func detail(_ name: String, _ value: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(name).foregroundStyle(Theme.secondary).frame(width: 70, alignment: .leading)
            Text(value).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
        .font(.system(size: 12))
    }

    /// A value typed in place; Return saves it.
    private func field(_ name: String, _ value: Binding<String>, prompt: String, save: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(name).foregroundStyle(Theme.secondary).frame(width: 70, alignment: .leading)
            TextField(name, text: value, prompt: Text(prompt)).textFieldStyle(.plain)
                .padding(.horizontal, 7).frame(height: 24)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                .onSubmit(save)
                .help("Press Return to save")
        }
        .font(.system(size: 12))
    }

    // MARK: Work

    private func load() async {
        do {
            let fresh = try await model.ticket(key)
            ticket = fresh
            problem = nil
            due = fresh.due ?? ""
            labels = fresh.labels.joined(separator: ", ")
            estimate = fresh.estimate ?? ""
            async let allowed = model.ticketTransitions(key)
            async let names = priorities.isEmpty ? model.jiraPriorities() : priorities
            (moves, priorities) = await (allowed, names)
        } catch {
            if ticket == nil { problem = error.localizedDescription }
        }
    }

    /// One change in Jira, then the ticket read again; Jira's refusal stays on screen.
    private func change(_ done: String, _ work: @escaping (JiraClient) async throws -> Void, then finish: @escaping () -> Void = {}) {
        working = true
        Task {
            refusal = await model.jira(done, work)
            if refusal == nil { finish() }
            await load()
            working = false
        }
    }
}
