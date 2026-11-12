import AppKit
import SwiftUI

/// Settings, by what they are about: the app as a whole, each server on
/// its own, notifications, integrations.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ServerSettings().tabItem { Label("Servers", systemImage: "server.rack") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell.badge") }
            IntegrationSettings().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 660, height: 600)
    }
}

/// A settings page: grouped sections that scroll when they are many.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

private func footnote(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary)
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            Section {
                Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                    Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                    Label("Light", systemImage: "sun.max").tag("light")
                    Label("Dark", systemImage: "moon").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle("Show GitNest View in the menu bar", isOn: Binding(get: { model.showInMenuBar }, set: { model.showInMenuBar = $0 }))
            } header: {
                Text("Theme")
            } footer: {
                footnote("System follows macOS: light by day, dark by night, if that is how the Mac is set.")
            }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.workdir ?? "Not chosen").foregroundStyle(model.workdir == nil ? .secondary : .primary).lineLimit(1).truncationMode(.head)
                        Button("Choose…") { chooseWorkdir(model) }
                    }
                }
                Toggle("Fetch every clone in the background (every 10 minutes)", isOn: Binding(get: { model.backgroundFetch }, set: { model.backgroundFetch = $0 }))
            } header: {
                Text("Working folder")
            } footer: {
                footnote("One folder for everything GitNest clones: server/owner/repository inside it. Clones that are already anywhere in it are recognised by their remote.")
            }

            Section {
                TextField("Key jobs", text: Binding(
                    get: { model.keyJobs.joined(separator: ", ") },
                    set: { model.setKeyJobs($0.split(separator: ",").map(String.init)) }
                ), prompt: Text(AppModel.defaultKeyJobs.joined(separator: ", ")))
            } header: {
                Text("Pipelines")
            } footer: {
                footnote("Jobs whose name contains one of these are always listed on a pull request. Other jobs are listed only when they fail. Separate them with commas.")
            }

            Section {
                HStack {
                    Button("Run the Setup Wizard Again…") { model.wizardOpen = true; NSApp.keyWindow?.close() }
                    Button("Show the Tutorial") { model.startTour(); NSApp.keyWindow?.close() }
                }
            } header: {
                Text("Getting started")
            }
        }
    }
}

/// Each server on its own card: who, how, what the token may do.
private struct ServerSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            if model.accounts.isEmpty {
                Section { Text("No server is connected yet.").foregroundStyle(.secondary) }
            }
            ForEach(model.accounts) { account in
                Section {
                    LabeledContent("Signed in as") {
                        Text([account.login, account.serverVersion.map { "Forgejo \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    Picker("Clone with", selection: Binding(get: { account.cloneWithSSH == true }, set: { model.setCloneWithSSH($0, for: account) })) {
                        Text("HTTPS + token").tag(false)
                        Text("SSH keys").tag(true)
                    }
                    Toggle("Notify me about this server", isOn: Binding(get: { !model.isMuted(account.host) }, set: { model.setMuted(!$0, host: account.host) }))
                    PermissionList(host: account.host)
                    HStack {
                        Spacer()
                        Button("Remove \(ServerName.short(account.host))", role: .destructive) { model.disconnect(account) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(ServerName.color(account.host)).frame(width: 8, height: 8)
                        Text(account.host)
                    }
                }
            }
            Section {
                ConnectForm()
            } header: {
                Text("Connect another server")
            } footer: {
                footnote("Create the token on the server under Settings → Applications with read and write access to repositories, issues and notifications, and read access to organisations and your user. It is kept in the Keychain.")
            }
        }
    }
}

/// What the token lets GitNest do on a server: green works, red does not.
struct PermissionList: View {
    @Environment(AppModel.self) private var model
    let host: String
    @State private var checks: [PermissionCheck]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What this token allows").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Check Again") { Task { await check() } }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.blue)
            }
            if let checks {
                ForEach(checks) { check in
                    HStack(spacing: 8) {
                        Image(systemName: check.answer == .yes ? "checkmark.circle.fill" : check.answer == .no ? "xmark.circle.fill" : "questionmark.circle")
                            .foregroundStyle(check.answer == .yes ? Theme.green : check.answer == .no ? Theme.red : Theme.secondary)
                        Text(check.feature).foregroundStyle(check.answer == .no ? Theme.red : Theme.text)
                        Spacer(minLength: 4)
                        Text(check.scope).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
                    }
                    .font(.system(size: 12))
                    .help(check.answer == .yes ? "Works" : check.answer == .no ? "Does not work: the token lacks \(check.scope)" : "The server did not say (its proxy hides the answer)")
                    .accessibilityLabel("\(check.feature): \(check.answer == .yes ? "works" : check.answer == .no ? "does not work" : "unknown")")
                }
                if checks.contains(where: { $0.answer == .no }) {
                    Text("Create a new token with the scopes in red and connect the server again.").font(.system(size: 11.5)).foregroundStyle(Theme.orange)
                }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking the server…").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
        }
        .task(id: host) { await check() }
    }

    private func check() async {
        checks = nil
        checks = await model.permissions(host: host)
    }
}

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            Section {
                Toggle("Someone asks for my review", isOn: Binding(get: { model.notifyReviews }, set: { model.notifyReviews = $0 }))
                Toggle("A pipeline of my pull request, or a scheduled one, fails", isOn: Binding(get: { model.notifyFailures }, set: { model.notifyFailures = $0 }))
            } header: {
                Text("Forgejo")
            } footer: {
                footnote("Checked every two minutes, also while GitNest View is in the background. Every notification names its server. A server can be silenced on its own under Servers.")
            }
            Section {
                Toggle("A ticket is assigned to me, commented on, or closed by someone else",
                       isOn: Binding(get: { model.notifyJira }, set: { model.notifyJira = $0 }))
                    .disabled(model.jiraSettings == nil)
            } header: {
                Text("Jira")
            } footer: {
                footnote(model.jiraSettings == nil ? "Connect Jira under Integrations first." : "A click on the notification opens the ticket in GitNest View.")
            }
        }
    }
}

private struct IntegrationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            Section {
                JiraForm()
            } header: {
                HStack(spacing: 6) { JiraMark(size: 13); Text("Jira (optional)") }
            } footer: {
                footnote("Your tickets on Home, in a window of their own: workflow, comments, time. Jira Cloud: the site's address, your Atlassian e-mail and an API token from id.atlassian.com → Security → API tokens. Disconnected, GitNest View shows nothing of Jira and asks it nothing.")
            }
        }
    }
}
