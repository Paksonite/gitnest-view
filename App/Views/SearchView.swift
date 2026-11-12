import AppKit
import SwiftUI

/// Search every clone of the workspace at once (git grep): where is this
/// project id, IP range, variable or module used?
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var regex = false
    @State private var ignoreCase = true
    @State private var results: [GrepHit]?
    @State private var searching = false
    @State private var error: String?
    @FocusState private var focused: Bool
    @State private var searchedWith = -1

    private var cloneCount: Int { model.repos.count { model.clone(of: $0) != nil } }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("Search every clone of \(model.workspace?.title ?? "the workspace") — a project id, an IP range, a variable…", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .focused($focused)
                        .onSubmit { Task { await search() } }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.blue.opacity(0.6) : Theme.border))
                Toggle("Aa", isOn: Binding(get: { !ignoreCase }, set: { ignoreCase = !$0 })).toggleStyle(.button).help("Match case")
                Toggle(".*", isOn: $regex).toggleStyle(.button).help("Regular expression")
                Button(searching ? "Searching…" : "Search") { Task { await search() } }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(searching || model.searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            HLine()
            WithFilePane { content }
        }
        .onAppear { focused = true }
        // Search again when the clones come in (at launch) or change: a
        // search before they are known would find nothing.
        .task(id: cloneCount) {
            if cloneCount > 0, !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty, searchedWith != cloneCount {
                await search()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let error {
            EmptyState("Cannot search", symbol: "exclamationmark.triangle", message: error)
        } else if searching && results == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if cloneCount == 0 {
            EmptyState("No clones to search", symbol: "arrow.down.circle", message: "Search looks through the clones of \(model.workspace?.title ?? "the workspace"); clone repositories first.")
        } else if let results {
            if results.isEmpty {
                EmptyState("Nothing found", symbol: "magnifyingglass", message: "No tracked file in the \(cloneCount) clones of \(model.workspace?.title ?? "this workspace") contains it.")
            } else {
                let total = results.reduce(0) { $0 + $1.matches.count }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("\(total) \(total == 1 ? "line" : "lines") in \(results.count) \(results.count == 1 ? "repository" : "repositories")")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        ForEach(results) { hit in
                            Card(model.forgeRepo(forClone: hit.path)?.name ?? (hit.path as NSString).lastPathComponent) {
                                Text("\(hit.matches.count)\(hit.matches.count >= 200 ? "+" : "")").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            } content: {
                                if let error = hit.error { Text(error).foregroundStyle(Theme.red).font(.system(size: 12)) }
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(hit.matches.enumerated()), id: \.offset) { _, match in
                                        Button {
                                            open(hit.path, match)
                                        } label: {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text("\(match.file):\(match.line)")
                                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                                                    .lineLimit(1).truncationMode(.head).frame(width: 260, alignment: .leading)
                                                highlighted(match.text.trimmingCharacters(in: .whitespaces))
                                                    .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                                Spacer(minLength: 0)
                                            }
                                            .padding(.horizontal, 6)
                                            .frame(height: 24)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .hoverBackground(radius: 4)
                                        .help("Open \(match.file) at line \(match.line)")
                                    }
                                }
                                .padding(.horizontal, -6)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            EmptyState("Search across repositories", symbol: "text.magnifyingglass",
                       message: "Every clone of the workspace is searched at once, in the files git tracks. ⌘K → “Search” jumps here.")
        }
    }

    /// The match with the searched text marked.
    private func highlighted(_ line: String) -> Text {
        let needle = model.searchText
        guard !regex, !needle.isEmpty,
              let range = line.range(of: needle, options: ignoreCase ? [.caseInsensitive] : []) else { return Text(line) }
        return Text(line[..<range.lowerBound]) + Text(line[range]).foregroundStyle(Theme.orange).bold() + Text(line[range.upperBound...])
    }

    private func search() async {
        let text = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        error = nil
        defer { searching = false }
        do {
            results = try await model.grep(text, regex: regex, ignoreCase: ignoreCase)
            searchedWith = cloneCount
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Shows the line in the app's own viewer.
    private func open(_ path: String, _ match: GrepMatch) {
        guard let repo = model.repos.first(where: { model.clone(of: $0)?.path == path }) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path).appending(path: match.file))
            return
        }
        model.fileTarget = FileTarget(repo: repo, file: match.file, line: match.line)
    }
}
