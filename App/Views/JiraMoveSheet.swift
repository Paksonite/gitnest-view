import SwiftUI

/// A status move waiting for what Jira asks with it: the comment its
/// screen wants, the fields it needs, or Jira's reason for refusing it.
struct JiraMoveRequest: Identifiable {
    let id = UUID()
    let key: String
    let transition: JiraTransition
    var refusal: String?
}

extension AppModel {
    /// Moves a ticket because the user chose it: nil when Jira took the
    /// move, else Jira's reason.
    func moveTicket(_ key: String, by transition: JiraTransition, input: JiraMoveInput = JiraMoveInput()) async -> String? {
        let refusal = await jira("\(key) is now \(transition.to?.name ?? transition.name)") { try await $0.moveTicket(key, transition, input: input) }
        if refusal == nil { await refreshJira() }
        return refusal
    }

    /// A status chosen from a list: moved at once when Jira asks nothing
    /// with it; otherwise, or when Jira refuses, the request to show.
    func chooseMove(_ key: String, _ transition: JiraTransition) async -> JiraMoveRequest? {
        if transition.asks { return JiraMoveRequest(key: key, transition: transition) }
        guard let refusal = await moveTicket(key, by: transition) else { return nil }
        return JiraMoveRequest(key: key, transition: transition, refusal: refusal)
    }
}

/// Asks for what a move needs, the way Jira's own page does, then moves.
struct JiraMoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: JiraMoveRequest
    var moved: () -> Void = {}
    @State private var input = JiraMoveInput()
    @State private var refusal: String?
    @State private var working = false
    @FocusState private var focused: Bool

    private var transition: JiraTransition { request.transition }
    private var target: String { transition.to?.name ?? transition.name }
    private var missing: Bool {
        (transition.commentRequired && input.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || transition.requiredFields.contains { (input.values[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                JiraMark(size: 15)
                Text("Move \(request.key) to \(target)").font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 48)
            HLine()
            VStack(alignment: .leading, spacing: 14) {
                if let refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Jira refused: \(refusal)")
                }
                ForEach(transition.requiredFields, id: \.id) { item in
                    Field(label: item.field.name) { fieldInput(item.id, item.field) }
                }
                Field(label: transition.commentRequired || refusal != nil ? "Comment" : "Comment (optional)",
                      hint: transition.commentRequired ? "Jira needs a comment with this move." : "") {
                    TextEditor(text: $input.comment)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .frame(height: 120)
                        .padding(5)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                        .focused($focused)
                        .accessibilityLabel("Move comment")
                }
            }
            .padding(16)
            HLine()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(ChipButtonStyle()).keyboardShortcut(.cancelAction)
                Button(working ? "Moving…" : "Move to \(target)") { submit() }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(working || missing)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘↩")
            }
            .padding(.horizontal, 16).frame(height: 54)
        }
        .frame(width: 460)
        .background(Theme.window)
        .onAppear {
            refusal = request.refusal
            for item in transition.requiredFields {
                if let first = item.field.allowedValues?.first?.id { input.values[item.id] = first }
            }
            focused = true
        }
    }

    @ViewBuilder
    private func fieldInput(_ id: String, _ field: JiraTransition.Field) -> some View {
        let value = Binding { input.values[id] ?? "" } set: { input.values[id] = $0 }
        if let options = field.allowedValues, !options.isEmpty {
            Picker(field.name, selection: value) {
                ForEach(options, id: \.self) { option in Text(option.label).tag(option.id ?? "") }
            }
            .labelsHidden()
        } else {
            TextField(field.name, text: value).fieldBox()
        }
    }

    private func submit() {
        working = true
        Task {
            refusal = await model.moveTicket(request.key, by: transition, input: input)
            working = false
            if refusal == nil {
                moved()
                dismiss()
            }
        }
    }
}
