import AppKit
import SwiftUI

/// The form that connects a Forgejo server; used in Settings and on first launch.
struct ConnectForm: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        TextField("Server", text: $host, prompt: Text("forgejo.example.com"))
            .autocorrectionDisabled()
        SecureField("Access token", text: $token)
        HStack {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("Connect") { connect() }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(host.isEmpty || token.isEmpty || working)
        }
    }

    private func connect() {
        working = true
        error = nil
        Task {
            do {
                try await model.connect(host: host, token: token)
                host = ""
                token = ""
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

@MainActor
func chooseWorkdir(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose the folder GitNest View clones repositories into. Clones already in it are found."
    if let current = model.workdir { panel.directoryURL = URL(fileURLWithPath: current) }
    if panel.runModal() == .OK, let url = panel.url {
        model.setWorkdir(url)
    }
}

/// Connecting Jira, or what is connected.
struct JiraForm: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var working = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        if let settings = model.jiraSettings {
            HStack {
                VStack(alignment: .leading) {
                    Text(settings.site)
                    Text("as \(settings.email) · \(model.jira.error ?? "\(model.jira.issues.count) open tickets assigned to you")")
                        .font(.caption).foregroundStyle(model.jira.error == nil ? Color.secondary : Color.orange)
                }
                Spacer()
                Button("Disconnect", role: .destructive) { model.disconnectJira() }
            }
            TextField("Tickets shown (JQL)", text: $filter, prompt: Text(JiraClient.defaultFilter))
                .onSubmit { Task { await model.setJiraFilter(filter) } }
                .onAppear { filter = settings.filter ?? "" }
                .help("Leave empty for the open tickets assigned to you. Press Return to apply.")
        } else {
            TextField("Site", text: $site, prompt: Text("your-team.atlassian.net"))
            TextField("E-mail", text: $email, prompt: Text("you@example.com"))
            SecureField("API token", text: $token)
            HStack {
                Button(working ? "Connecting…" : "Connect Jira") {
                    working = true
                    message = nil
                    Task {
                        do {
                            let name = try await model.connectJira(site: site, email: email, token: token)
                            message = "Connected as \(name)."
                            failed = false
                            token = ""
                        } catch {
                            message = error.localizedDescription
                            failed = true
                        }
                        working = false
                    }
                }
                .disabled(working || site.isEmpty || email.isEmpty || token.isEmpty)
                if let message { Text(message).font(.callout).foregroundStyle(failed ? Color.red : Color.secondary) }
            }
        }
    }
}

