import AppKit
import SwiftUI

/// The first launch: the logo arrives, then the wizard.
struct WelcomeFlow: View {
    @Environment(AppModel.self) private var model
    /// The intro plays once, before anything is set up.
    @State private var introDone = false

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            if introDone || model.isSetUp {
                SetupWizard().transition(.opacity.combined(with: .offset(y: 18)))
            } else {
                IntroView { withAnimation(Motion.reduced ? nil : .spring(duration: 0.55, bounce: 0.1)) { introDone = true } }
                    .transition(.opacity.combined(with: .scale(scale: 1.06)))
            }
        }
    }
}

/// Logo, name, slogan: each arrives in turn, then the stage is the wizard's.
private struct IntroView: View {
    let finish: () -> Void
    @State private var stage = 0

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                // A soft glow in the logo's green, breathing once.
                Circle().fill(Theme.brand.opacity(0.18)).frame(width: 220, height: 220).blur(radius: 50)
                    .scaleEffect(stage >= 1 ? 1 : 0.4).opacity(stage >= 1 ? 1 : 0)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 128, height: 128)
                    .scaleEffect(stage >= 1 ? 1 : 0.55).opacity(stage >= 1 ? 1 : 0)
                    .rotationEffect(.degrees(stage >= 1 ? 0 : -10))
            }
            Wordmark(size: 34)
                .opacity(stage >= 2 ? 1 : 0).offset(y: stage >= 2 ? 0 : 14)
            (Text("All your Git repositories. ") + Text("One place.").foregroundStyle(Theme.brand))
                .font(.system(size: 18, weight: .semibold))
                .opacity(stage >= 3 ? 1 : 0).offset(y: stage >= 3 ? 0 : 10)
            Text("Pull requests, reviews and live pipelines next to your clones")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .opacity(stage >= 3 ? 1 : 0)
            Button("Get Started") { finish() }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .opacity(stage >= 4 ? 1 : 0)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if stage >= 3 { finish() } }
        .task {
            guard !Motion.reduced else { stage = 4; return }
            let steps: [(Double, Animation)] = [
                (0.25, .spring(duration: 0.7, bounce: 0.32)), (0.55, .easeOut(duration: 0.4)), (0.4, .easeOut(duration: 0.4)), (0.5, .easeOut(duration: 0.3)),
            ]
            for (index, step) in steps.enumerated() {
                try? await Task.sleep(for: .seconds(step.0))
                withAnimation(step.1) { stage = index + 1 }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to GitNest View")
    }
}

/// Setup in five steps: server, token, workspace, folder, the rest.
struct SetupWizard: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var host = ""
    @State private var token = ""
    @State private var working = false
    @State private var error: String?
    @State private var version: String?
    @State private var folder = AppModel.suggestedWorkdir

    private let titles = ["Server", "Token", "Workspace", "Folder", "Finish"]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Wordmark(size: 22)
                Text("Set up in a minute").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            progress
            VStack(alignment: .leading, spacing: 14) {
                content
                    .id(step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 26)), removal: .opacity.combined(with: .offset(x: -26))))
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(width: 540, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            HStack {
                if step > 0 { Button("Back") { go(step - 1) }.buttonStyle(ChipButtonStyle()) }
                if model.isSetUp { Button("Close") { model.wizardOpen = false }.buttonStyle(.plain).foregroundStyle(Theme.secondary) }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                next
            }
            .frame(width: 540)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.panel, value: step)
        .onAppear {
            // Asked for again: start from what is already there.
            if let account = model.accounts.first { host = account.host; version = account.serverVersion }
            if let workdir = model.workdir { folder = URL(fileURLWithPath: workdir) }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(index < step ? Theme.green : index == step ? Theme.blue : Theme.border).frame(width: 20, height: 20)
                        if index < step {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(index == step ? .white : Theme.secondary)
                        }
                    }
                    Text(title).font(.system(size: 12, weight: index == step ? .semibold : .regular))
                        .foregroundStyle(index == step ? Theme.text : Theme.secondary)
                }
                if index < titles.count - 1 { Rectangle().fill(index < step ? Theme.green : Theme.border).frame(width: 26, height: 1.5) }
            }
        }
        .accessibilityLabel("Step \(step + 1) of \(titles.count): \(titles[step])")
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            heading("Where is your Forgejo?", "The address you open in the browser.")
            TextField("Server", text: $host, prompt: Text("forgejo.example.com")).textFieldStyle(.plain).font(.system(size: 13.5))
                .padding(.horizontal, 10).frame(height: 34)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                .autocorrectionDisabled()
                .onSubmit { Task { await checkServer() } }
            if let version { Label("Forgejo \(version) answers there.", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.green) }
        case 1:
            heading("An access token", "GitNest signs in with a token, not your password. It is kept in the Keychain; macOS asks once whether GitNest View may read it — choose Always Allow.")
            HStack(spacing: 8) {
                Button("Create a Token on \(ServerName.short(host))…", systemImage: "arrow.up.right.square") {
                    if let url = URL(string: "https://\(ForgeAccount.normalize(host))/user/settings/applications") { openExternal(url) }
                }
                .buttonStyle(ChipButtonStyle())
                Text("read + write: repository, issue, notification · read: organization, user")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let account = model.accounts.first(where: { $0.host == ForgeAccount.normalize(host) }) {
                Label("Signed in as \(account.login ?? "?").", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.green)
                PermissionList(host: account.host)
            } else {
                SecureField("Access token", text: $token, prompt: Text("paste the token")).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    .onSubmit { Task { await connect() } }
            }
        case 2:
            heading("Which workspace first?", "An organisation's repositories, or your own. It can be switched any time at the top of the sidebar.")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.workspaces) { workspace in
                        Button { model.select(workspace) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: workspace.personal ? "person" : "building.2").foregroundStyle(Theme.secondary).frame(width: 18)
                                Text(workspace.title)
                                if workspace.personal { Text("personal").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                                Spacer()
                                if workspace.id == model.workspace?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
                            }
                            .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverBackground(selected: workspace.id == model.workspace?.id)
                    }
                }
            }
            .frame(maxHeight: 210)
            .task { if model.workspaces.isEmpty { await model.loadWorkspaces() } }
            if model.workspaces.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading your organisations…").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
            if model.workspace != nil {
                Text("\(model.repos.count) repositories in \(model.workspace?.title ?? "")").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        case 3:
            heading("GitNest's working folder", "One folder for everything GitNest clones. Each server gets its own folder inside it, then the owner, then the repository. Clones you already have in it are found by their remote.")
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Theme.secondary)
                Text(folder.path).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") { choose() }.buttonStyle(ChipButtonStyle())
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 3) {
                let last = folder.lastPathComponent
                let server = ForgeAccount.normalize(host)
                Text("\(last)/").foregroundStyle(Theme.text)
                if last.lowercased() != server.lowercased() { Text("  \(server)/").foregroundStyle(ServerName.color(server)) }
                Text("    \(model.workspace?.owner ?? "owner")/")
                Text("      repository/")
            }
            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
        default:
            heading("Ready", "Two last choices; both can be changed in Settings.")
            Toggle("Notify me about review requests and failed pipelines", isOn: Binding(get: { model.notifyReviews }, set: { model.notifyReviews = $0; model.notifyFailures = $0 }))
            Toggle("Keep GitNest View in the menu bar", isOn: Binding(get: { model.showInMenuBar }, set: { model.showInMenuBar = $0 }))
            HStack(spacing: 6) {
                JiraMark(size: 13)
                Text("Jira and the theme are in Settings → Integrations and General.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            let clones = model.repos.count { model.clone(of: $0) != nil }
            Label("\(model.repos.count) repositories, \(clones) already cloned here.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.green)
        }
    }

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var next: some View {
        switch step {
        case 0:
            Button("Continue") { Task { await checkServer() } }.buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || working).keyboardShortcut(.defaultAction)
        case 1:
            if model.accounts.contains(where: { $0.host == ForgeAccount.normalize(host) }) {
                Button("Continue") { go(2) }.buttonStyle(ChipButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            } else {
                Button("Connect") { Task { await connect() } }.buttonStyle(ChipButtonStyle(prominent: true))
                    .disabled(token.isEmpty || working).keyboardShortcut(.defaultAction)
            }
        case 2:
            Button("Continue") { go(3) }.buttonStyle(ChipButtonStyle(prominent: true)).disabled(model.workspace == nil).keyboardShortcut(.defaultAction)
        case 3:
            Button("Use This Folder") { useFolder() }.buttonStyle(ChipButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
        default:
            Button("Skip the Tour") { model.wizardOpen = false; model.tourSeen = true }.buttonStyle(ChipButtonStyle())
            Button("Show Me Around") { model.startTour() }.buttonStyle(ChipButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
        }
    }

    private func go(_ to: Int) {
        error = nil
        step = to
    }

    /// Is there a Forgejo at this address at all?
    private func checkServer() async {
        working = true
        defer { working = false }
        error = nil
        let client = ForgejoClient(host: ForgeAccount.normalize(host), token: nil, session: model.session)
        do {
            version = try await client.version()
            go(1)
        } catch ForgejoClient.ForgeError.unauthorized, ForgejoClient.ForgeError.forbidden {
            // A private server answers only to a token: fine, go on.
            version = nil
            go(1)
        } catch {
            self.error = "No Forgejo answers at \(ForgeAccount.normalize(host)): \(error.localizedDescription) Check the address, the VPN, the certificate."
        }
    }

    private func connect() async {
        working = true
        defer { working = false }
        error = nil
        model.wizardOpen = true // stays on screen once the account exists
        do {
            try await model.connect(host: host, token: token)
            token = ""
            // No folder yet, so nothing was loaded: the next step needs the organisations.
            await model.loadWorkspaces()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "The folder GitNest View clones into: server/owner/repository inside it."
        panel.directoryURL = folder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func useFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            model.wizardOpen = true
            model.setWorkdir(folder)
            go(4)
        } catch {
            self.error = "The folder cannot be created: \(error.localizedDescription)"
        }
    }
}

// MARK: - The tour

/// One stop of the tour: where the app goes and what is said there.
struct TourStop {
    var title: String
    var text: String
    var symbol: String
    /// Where the card sits, so it does not cover what it talks about.
    var corner: Alignment
    var show: @MainActor (AppModel) -> Void
}

enum Tour {
    @MainActor static let stops: [TourStop] = [
        TourStop(title: "The sidebar: what needs you first", text: "Repositories that need something come first, each with marks: a red sign for a failed pipeline, arrows for commits to pull or push, a dot for uncommitted changes. Rest the pointer on a mark and it says what it means. Pin a repository with a right click.",
                 symbol: "sidebar.left", corner: .bottom) { $0.section = .repositories },
        TourStop(title: "Home: your steps", text: "To do lists what waits for you personally: reviews asked of you, your pull requests, clones to pull or push. Each line has the one button that deals with it. The tiles on top count the same things; click one to go there.",
                 symbol: "house", corner: .bottomTrailing) { $0.section = .home },
        TourStop(title: "⌘K: go anywhere", text: "Type a few letters of a repository, a pull request, a branch or a command. It is the fastest way around when there are many repositories.",
                 symbol: "magnifyingglass", corner: .bottom) { $0.section = .home; $0.paletteOpen = true },
        TourStop(title: "Overview: the pull request that matters", text: "A repository opens on its open pull request: the Terraform plan, the checks, who must review, the conversation. Merge and Review are at the top right; the … menu edits, drafts, updates the branch.",
                 symbol: "square.grid.2x2", corner: .bottomLeading) { $0.paletteOpen = false; $0.section = .repositories; $0.repoTab = .overview },
        TourStop(title: "Changes: your work in the clone", text: "Stage whole files or single lines, commit, push, switch and create branches, stash. Everything here is local until you push.",
                 symbol: "doc.badge.plus", corner: .bottomTrailing) { $0.repoTab = .changes },
        TourStop(title: "History: commits, branches, tags", text: "Read the history, reword or squash commits that are not pushed yet, manage branches and tags, see the server's releases.",
                 symbol: "clock.arrow.circlepath", corner: .bottomTrailing) { $0.repoTab = .history },
        TourStop(title: "Resources: Terraform at a glance", text: "Every module, resource and data source the clone declares, with what the latest plan changes. Click one and its file opens beside the list, coloured; the clock shows who changed it and when.",
                 symbol: "square.stack.3d.up", corner: .bottomTrailing) { $0.repoTab = .resources },
        TourStop(title: "Pull requests: open, review, merge", text: "New opens a pull request between two branches chosen from the server's. Release prepares develop → main. Closed ones load when you ask for them.",
                 symbol: "arrow.triangle.pull", corner: .bottomTrailing) { $0.repoTab = .pulls },
        TourStop(title: "Actions: pipelines and live logs", text: "Runs by workflow, their jobs, and the log as it is written. Run a workflow by hand, re-run or cancel one.",
                 symbol: "play.circle", corner: .bottomLeading) { $0.repoTab = .actions },
        TourStop(title: "Inbox: every server, kept apart", text: "Reviews asked of you and your own pull requests, grouped by server, each in its colour. A blue dot marks what changed since you last looked.",
                 symbol: "tray", corner: .bottomTrailing) { $0.section = .inbox },
        TourStop(title: "That is the map", text: "Settings (⌘,) hold the theme, each server's options and what its token allows, notifications, and Jira. This tour is under Help whenever you want it again.",
                 symbol: "checkmark.seal", corner: .center) { $0.section = .home },
    ]
}

/// The tour's card: it describes, the app shows the place; nothing is done
/// to the user's data.
struct TourLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let index = model.tourStep, Tour.stops.indices.contains(index) {
            let stop = Tour.stops[index]
            ZStack(alignment: stop.corner) {
                Color.black.opacity(0.18).allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: stop.symbol).font(.system(size: 14)).foregroundStyle(Theme.brand).frame(width: 22)
                        Text(stop.title).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(index + 1) of \(Tour.stops.count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary).monospacedDigit()
                    }
                    Text(stop.text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Skip the Tour") { model.endTour() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Spacer()
                        if index > 0 { Button("Back") { move(to: index - 1) }.buttonStyle(ChipButtonStyle()) }
                        Button(index == Tour.stops.count - 1 ? "Done" : "Next") {
                            if index == Tour.stops.count - 1 { model.endTour() } else { move(to: index + 1) }
                        }
                        .buttonStyle(ChipButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(width: 420)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.brand.opacity(0.5)))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                .padding(28)
                .id(index)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tour: \(stop.title)")
            }
            .animation(Motion.panel, value: index)
            .onAppear { stop.show(model) }
            .onExitCommand { model.endTour() }
        }
    }

    private func move(to index: Int) {
        Tour.stops[index].show(model)
        model.tourStep = index
    }
}
