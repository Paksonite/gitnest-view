import AppKit
import SwiftUI

/// The menu bar item: a glance at what needs the user, from anywhere, and
/// one click to it.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let urgent = model.repos.compactMap { repo -> (ForgeRepo, [AttentionReason])? in
            let reasons = model.attention(repo)
            return reasons.isEmpty ? nil : (repo, reasons)
        }.sorted { $0.1.first!.rank < $1.1.first!.rank }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Wordmark(size: 12.5)
                Spacer()
                Text(model.workspace?.title ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            HLine()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !model.isSetUp {
                        Text("Open GitNest View to connect a server.").foregroundStyle(Theme.secondary).padding(12)
                    } else if urgent.isEmpty && model.inbox.isEmpty && model.myPulls.isEmpty {
                        Label("Nothing needs you right now.", systemImage: "checkmark.circle").foregroundStyle(Theme.green).padding(12)
                    }
                    if !urgent.isEmpty {
                        header("Needs attention")
                        ForEach(urgent.prefix(10), id: \.0.id) { repo, reasons in
                            item(symbol: nil, badges: [reasons[0]], title: repo.name, detail: reasons[0].text) { open(repo) }
                        }
                    }
                    if !model.inbox.isEmpty {
                        header("Waiting for your review")
                        ForEach(model.inbox.prefix(6)) { entry in
                            item(symbol: "eye", tint: Theme.orange, title: entry.hit.title,
                                 detail: "\(entry.hit.repository?.name ?? "") #\(entry.hit.number)",
                                 quick: QuickAction(id: "approve:\(entry.id)", title: "Approve") { await model.quickApprove(entry) }) {
                                activate()
                                Task { await model.open(entry) }
                            }
                        }
                    }
                    if !model.myPulls.isEmpty {
                        header("Your pull requests")
                        ForEach(model.myPulls.prefix(6)) { pull in
                            item(state: pull.state, title: pull.title,
                                 detail: "\(pull.repoFullName.split(separator: "/").last ?? "") #\(pull.number)",
                                 quick: pull.state == .failure && model.supportsRerun(pull.host) ? QuickAction(id: "rerun:\(pull.id)", title: "Run Again") { await model.rerunFailed(pull) } : nil) {
                                activate()
                                Task { await model.openPull(host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL) }
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 460)
            HLine()
            HStack(spacing: 8) {
                Button("Open GitNest View") {
                    activate()
                    model.section = .home
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                Button("Fetch All", systemImage: "arrow.clockwise") { Task { await model.fetchAllReporting() } }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(model.fetchingAll || !model.isSetUp)
                Spacer()
                Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Quit GitNest View")
            }
            .padding(10)
        }
        .frame(width: 380)
        .background(Theme.window)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.5).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
    }

    private func item(symbol: String? = nil, tint: Color = Theme.secondary, state: CheckState? = nil, badges: [AttentionReason] = [],
                      title: String, detail: String, quick: QuickAction? = nil, action: @escaping () -> Void) -> some View {
        MenuBarRow(symbol: symbol, tint: tint, state: state, badges: badges, title: title, detail: detail, quick: quick, action: action)
    }

    private func open(_ repo: ForgeRepo) {
        activate()
        model.section = .repositories
        model.selection = repo.id
    }

    /// Brings the main window forward, opening a new one if it was closed.
    private func activate() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible && !($0.className.contains("MenuBarExtra")) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// The menu bar icon: the nest, with the number of things waiting.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = model.inbox.count + model.myPulls.filter { $0.state == .failure }.count
        HStack(spacing: 3) {
            Image(nsImage: Self.icon)
            if count > 0 { Text("\(count)").font(.system(size: 11, weight: .semibold)).monospacedDigit() }
        }
        .onAppear {
            let open = openWindow
            model.openMainWindow = { open(id: "main") }
        }
    }

    /// The logo as a template image, so macOS draws it in the menu bar's colour.
    static let icon: NSImage = {
        let image = NSImage(named: "Logo").flatMap { $0.copy() as? NSImage } ?? NSImage(systemSymbolName: "leaf", accessibilityDescription: nil)!
        image.size = NSSize(width: 17, height: 17)
        image.isTemplate = true
        return image
    }()
}


/// Something done straight from the menu bar, without opening the window.
struct QuickAction {
    var id: String
    var title: String
    var run: () async -> Bool
}

/// A line of the menu bar panel. Its quick action shows on hover and asks
/// once more before it acts: a click there cannot be taken back.
private struct MenuBarRow: View {
    var symbol: String?
    var tint: Color
    var state: CheckState?
    var badges: [AttentionReason]
    var title: String
    var detail: String
    var quick: QuickAction?
    var action: () -> Void
    @State private var hovering = false
    @State private var armed = false
    @State private var working = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Group {
                        if let state { CheckIcon(state: state, size: 11) }
                        else if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint) }
                        else { AttentionBadges(reasons: badges) }
                    }
                    .frame(width: 30, alignment: .leading)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 4)
                    if !(hovering && quick != nil) {
                        Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let quick, hovering || armed || working {
                Button(working ? "…" : armed ? "Confirm" : quick.title) {
                    guard armed else {
                        armed = true
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            armed = false
                        }
                        return
                    }
                    armed = false
                    working = true
                    Task {
                        _ = await quick.run()
                        working = false
                    }
                }
                .buttonStyle(ChipButtonStyle(prominent: armed))
                .disabled(working)
                .help(armed ? "Click again to do it" : "\(quick.title) without opening the window")
            }
        }
        .padding(.horizontal, 8)
        .hoverBackground(radius: 5)
        .onHover { hovering = $0 }
    }
}
