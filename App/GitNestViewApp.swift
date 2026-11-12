import AppKit
import SwiftUI

@main
struct GitNestViewApp: App {
    @State private var model: AppModel = {
        #if DEBUG
        if let development = AppModel.development() { return development }
        #endif
        return AppModel()
    }()

    var body: some Scene {
        WindowGroup("GitNest View", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.becameActive()
                }
                .task {
                    // Unit tests load the app as their host; they need no scanning.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 880)
        .commands { AppCommands(model: model) }

        MenuBarExtra(isInserted: Binding(get: { model.showInMenuBar }, set: { model.showInMenuBar = $0 })) {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The menus. Kept out of the scene's body: a large `commands` closure
/// there made Swift's type metadata so deep that resolving it overflowed the
/// stack at launch.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About GitNest View") { showAbout() }
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .help) {
            Button("Show the Tutorial") { model.startTour() }
            Button("Run the Setup Wizard Again…") { model.wizardOpen = true }
        }
        CommandMenu("Go") { GoMenu(model: model) }
        CommandMenu("Repository") { RepositoryMenu(model: model) }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await model.reload() } }
                .keyboardShortcut("r")
            Button("Rescan Repositories") { Task { await model.scan(full: true) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

private struct GoMenu: View {
    let model: AppModel

    var body: some View {
        Button("Home") { model.section = .home }.keyboardShortcut("0")
        tab(.overview, "1")
        tab(.changes, "2")
        tab(.history, "3")
        tab(.resources, "4")
        tab(.pulls, "5")
        tab(.actions, "6")
        Button("Inbox") { model.section = .inbox }.keyboardShortcut("i", modifiers: [.command, .shift])
        Divider()
        Button("Search or Run…") { model.paletteOpen = true }.keyboardShortcut("k")
    }

    private func tab(_ tab: RepoTab, _ key: KeyEquivalent) -> some View {
        Button(tab.rawValue) {
            model.section = .repositories
            model.repoTab = tab
        }
        .keyboardShortcut(key)
    }
}

private struct RepositoryMenu: View {
    let model: AppModel

    private var repo: ForgeRepo? { model.selectedRepo }
    private var clone: Repo? { repo.flatMap { model.clone(of: $0) } }

    var body: some View {
        Button("Fetch All") { Task { await model.fetchAllReporting() } }.keyboardShortcut("f", modifiers: [.command, .shift])
        Button("Pull All…") { model.sheet = .pullAll }.keyboardShortcut("p", modifiers: [.command, .shift])
        Divider()
        Button("New Branch…") {
            if let repo, let clone { model.sheet = .newBranch(repo, base: clone.branch) }
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(clone == nil)
        Button("Push") { if let repo { Task { await model.push(repo) } } }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(clone == nil)
        Button("Pull") { if let repo { Task { await model.run(.pull, on: repo) } } }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(clone == nil)
        Divider()
        Button("Open in Editor") { if let clone { openClone(clone, in: .editor) } }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(clone == nil)
        Button("Open in Terminal") { if let clone { openClone(clone, in: .terminal) } }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(clone == nil)
    }
}

/// The About panel says what the app is: GitNest, as a Mac app.
@MainActor
func showAbout() {
    let credits = NSMutableAttributedString()
    let body = NSMutableParagraphStyle()
    body.alignment = .center
    credits.append(NSAttributedString(string: "All your Git repositories. One place.\n", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .paragraphStyle: body, .foregroundColor: NSColor.labelColor,
    ]))
    credits.append(NSAttributedString(string: "GitNest Desktop for Mac: gitnest's engine with pull requests, reviews and live pipelines of your Forgejo server.\n\n", attributes: [
        .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: body, .foregroundColor: NSColor.secondaryLabelColor,
    ]))
    let link = NSMutableAttributedString(string: "github.com/Paksonite/gitnest", attributes: [
        .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: body, .link: URL(string: "https://github.com/Paksonite/gitnest")!,
    ])
    credits.append(link)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "GitNest View"])
    NSApp.activate()
}
