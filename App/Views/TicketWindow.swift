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
        .onDisappear { model.settleJira() }
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
                VStack(alignment: .leading, spacing: 10) {
                    if ticket.comments.isEmpty { Text("Nobody has commented yet.").foregroundStyle(Theme.secondary) }
                    ForEach(ticket.comments) { item in CommentBubble(comment: item, mine: item.authorID != nil && item.authorID == model.jiraAccountID) }
                    composer
                }
            }
        }
    }

    /// A new comment, under the conversation as in Jira.
    private var composer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $comment).font(.system(size: 12.5)).scrollContentBackground(.hidden).frame(height: 64)
                .padding(6).background(Theme.inset, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .overlay(alignment: .topLeading) {
                    if comment.isEmpty {
                        Text("Add a comment…").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).padding(.horizontal, 11).padding(.vertical, 7)
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
        .padding(.top, 4)
    }

    // MARK: Right: where it stands, who has it, the time

    private func side(_ ticket: JiraTicket) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                label("Status")
                StatusPicker(ticket: ticket, moves: moves, working: working) { move in
                    change("\(key) is now \(move.to?.name ?? move.name)") { try await $0.moveTicket(key, transition: move.id) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                label("Assignee")
                AssigneePicker(key: key, ticket: ticket, working: working) { person in
                    change(person.map { "\(key) is now with \($0.displayName)" } ?? "\(key) is unassigned") { try await $0.assign(key, to: person?.accountId) }
                }
            }
            HLine()
            VStack(alignment: .leading, spacing: 9) {
                label("Details")
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
            timeTracking(ticket)
        }
        .font(.system(size: 12.5))
    }

    private func timeTracking(_ ticket: JiraTicket) -> some View {
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
                change("Estimate of \(key) saved") { try await $0.update(key, fields: ["timetracking": ["originalEstimate": JiraTime.normalized(estimate)]]) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Log work").font(.system(size: 12, weight: .medium))
                HStack(spacing: 5) {
                    ForEach(["15m", "30m", "1h", "2h", "4h"], id: \.self) { amount in
                        Button(amount) { time = amount }
                            .buttonStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(time == amount ? Theme.blue.opacity(0.18) : Theme.card, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(time == amount ? Theme.blue.opacity(0.6) : Theme.border))
                            .accessibilityLabel("Time: \(amount)")
                    }
                }
                HStack(spacing: 6) {
                    TextField("Time spent", text: $time, prompt: Text("1h 30m")).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 7).frame(width: 84, height: 26)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(timeLooksWrong ? Theme.orange : Theme.border))
                        .onSubmit(logTime)
                        .accessibilityLabel("Time spent")
                    TextField("What was done", text: $timeNote, prompt: Text("note (optional)")).textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 7).frame(height: 26)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                        .onSubmit(logTime)
                        .accessibilityLabel("Work note")
                }
                if let timeHint {
                    Text(timeHint).font(.system(size: 11)).foregroundStyle(Theme.orange).fixedSize(horizontal: false, vertical: true)
                }
                Button("Log Time", action: logTime)
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(working)
            }
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            if !ticket.worklogs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ticket.worklogs.suffix(6).reversed()) { log in
                        HStack(spacing: 7) {
                            PersonMark(name: log.author, size: 18)
                            Text(log.timeSpent).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            Text(log.author).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                            Spacer()
                            if let when = log.started { Text(when.relative).font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                        }
                    }
                }
            }
        }
    }

    private var timeLooksWrong: Bool { !time.trimmingCharacters(in: .whitespaces).isEmpty && !JiraTime.valid(time) }
    @State private var timeTried = false

    private var timeHint: String? {
        if timeLooksWrong { return "Write the time as Jira does: 1h 30m, 45m, 1.5h or 2d." }
        if timeTried, time.trimmingCharacters(in: .whitespaces).isEmpty { return "Type how long it took, or pick one above." }
        return nil
    }

    private func logTime() {
        timeTried = true
        guard !working, JiraTime.valid(time) else { return }
        let spent = JiraTime.normalized(time)
        change("Logged \(spent) on \(key)") { try await $0.logWork(key, timeSpent: spent, note: timeNote) } then: { time = ""; timeNote = ""; timeTried = false }
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
            model.jiraTicketRead(fresh)
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

/// One comment: who, when, and what they said, set apart from the next.
private struct CommentBubble: View {
    let comment: JiraTicket.Comment
    let mine: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            PersonMark(name: comment.author, id: comment.authorID, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.system(size: 12, weight: .semibold))
                    if mine { Text("you").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.blue) }
                    if let when = comment.created {
                        Text(when.relative).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                            .help(when.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Text(comment.body.isEmpty ? "(no text)" : comment.body)
                    .font(.system(size: 12.5)).lineSpacing(2.5)
                    .foregroundStyle(comment.body.isEmpty ? Theme.tertiary : Theme.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mine ? Theme.blue.opacity(0.07) : Theme.inset, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(mine ? Theme.blue.opacity(0.25) : Theme.border))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The status as a coloured pill; a click lists the moves Jira allows,
/// named as Jira names them, each with the colour of where it leads.
private struct StatusPicker: View {
    let ticket: JiraTicket
    let moves: [JiraTransition]
    let working: Bool
    let move: (JiraTransition) -> Void
    @State private var open = false

    var body: some View {
        let color = JiraLook.status(ticket.status, category: ticket.statusCategory)
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(ticket.status).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(color).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color.opacity(0.8))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityLabel("Status: \(ticket.status)")
        .help(moves.isEmpty ? "Jira allows no move from here" : "Change the status")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MOVE TO").font(.system(size: 10, weight: .semibold)).kerning(0.5).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 8).padding(.bottom, 4)
                if moves.isEmpty {
                    Text("Jira allows no move from \(ticket.status).").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(8)
                }
                ForEach(moves) { item in
                    let target = item.to?.name ?? item.name
                    let tint = JiraLook.status(target, category: item.to?.statusCategory?.key)
                    Button {
                        open = false
                        move(item)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(tint).frame(width: 7, height: 7)
                            Text(target).font(.system(size: 12.5, weight: .medium)).foregroundStyle(tint)
                            Spacer(minLength: 12)
                            if target != item.name { Text(item.name).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuRowStyle())
                    .accessibilityLabel("Workflow: \(item.name)")
                }
            }
            .padding(8)
            .frame(minWidth: 240)
        }
    }
}

/// Who has the ticket; a click searches the people it can go to.
private struct AssigneePicker: View {
    @Environment(AppModel.self) private var model
    let key: String
    let ticket: JiraTicket
    let working: Bool
    let assign: (JiraUser?) -> Void
    @State private var open = false
    @State private var query = ""
    @State private var people: [JiraUser] = []
    @State private var searching = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                if let name = ticket.assignee {
                    PersonMark(name: name, id: ticket.assigneeID, size: 22)
                    Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                } else {
                    Image(systemName: "person.crop.circle.dashed").font(.system(size: 18)).foregroundStyle(Theme.tertiary)
                    Text("Unassigned").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityLabel("Assignee: \(ticket.assignee ?? "Unassigned")")
        .help("Hand the ticket to someone")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("Search people", text: $query, prompt: Text("Name or e-mail")).textFieldStyle(.plain)
                        .accessibilityLabel("Search people")
                    if searching { ProgressView().controlSize(.mini) }
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 8).frame(height: 28)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if let me = model.jiraAccountID, ticket.assigneeID != me {
                            row(Text("Assign to me").foregroundStyle(Theme.blue), mark: AnyView(Image(systemName: "person.fill.checkmark").foregroundStyle(Theme.blue).frame(width: 22))) {
                                assign(people.first { $0.accountId == me } ?? JiraUser(accountId: me, displayName: "you"))
                            }
                        }
                        ForEach(people) { person in
                            let current = person.accountId == ticket.assigneeID
                            row(HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(person.displayName)
                                    if let mail = person.emailAddress { Text(mail).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
                                }
                                Spacer(minLength: 6)
                                if current { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.blue) }
                            }, mark: AnyView(PersonMark(name: person.displayName, id: person.accountId, size: 22))) { if !current { assign(person) } }
                            .accessibilityLabel(current ? "\(person.displayName), assigned now" : "Assign to \(person.displayName)")
                        }
                        if !searching, people.allSatisfy({ $0.accountId == ticket.assigneeID }) {
                            Text(query.isEmpty ? "Nobody else can take this ticket in its project." : "Nobody else matches “\(query)”.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).padding(.horizontal, 6).padding(.vertical, 6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if ticket.assigneeID != nil {
                            Divider().padding(.vertical, 3)
                            row(Text("Unassign").foregroundStyle(Theme.secondary), mark: AnyView(Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(Theme.tertiary).frame(width: 22))) {
                                assign(nil)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            .padding(10)
            .frame(width: 280)
            .task(id: query) {
                searching = true
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                people = await model.jiraAssignable(key, query: query)
                searching = false
            }
        }
    }

    private func row(_ label: some View, mark: AnyView, action: @escaping () -> Void) -> some View {
        Button {
            open = false
            action()
        } label: {
            HStack(spacing: 8) {
                mark
                label.font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// A row in a popover list that lights up under the pointer.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(hover || configuration.isPressed ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                .onHover { hover = $0 }
        }
    }
}
