import AppKit
import Foundation

/// What a token lets the app do on a server, feature by feature.
struct PermissionCheck: Identifiable, Equatable, Sendable {
    enum Answer: Sendable { case yes, no, unknown }
    var id: String
    /// The feature in the app's words.
    var feature: String
    /// The token scope behind it, as Forgejo names it.
    var scope: String
    var writes: Bool
    var answer: Answer
}

extension AppModel {
    // MARK: Appearance

    /// "system", "light" or "dark".
    var appearance: String {
        get { _ = settingsRevision; return defaults.string(forKey: "appearance") ?? "system" }
        set {
            guard newValue != appearance else { return }
            defaults.set(newValue, forKey: "appearance")
            settingsRevision += 1
            applyAppearance()
        }
    }

    func applyAppearance() {
        switch defaults.string(forKey: "appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: Per server

    /// Servers whose news is not announced (they still show in the Inbox).
    private var mutedHosts: Set<String> {
        _ = settingsRevision
        return Set(defaults.stringArray(forKey: "mutedHosts") ?? [])
    }

    func isMuted(_ host: String) -> Bool { mutedHosts.contains(host) }

    func setMuted(_ muted: Bool, host: String) {
        var hosts = mutedHosts
        if muted { hosts.insert(host) } else { hosts.remove(host) }
        defaults.set(hosts.sorted(), forKey: "mutedHosts")
        settingsRevision += 1
    }

    /// Asks the server what the token may do, one harmless request per
    /// feature: reads read one item; writes aim at a repository that does
    /// not exist, so the server answers "not found" (allowed) or "forbidden"
    /// (the scope is missing) and nothing is ever changed.
    func permissions(host: String) async -> [PermissionCheck] {
        guard let client = client(for: host) else { return [] }
        return await client.permissions()
    }

    /// False only when the server said so: the token cannot change things
    /// there. Unknown (not asked yet, or the server hides its answer) counts
    /// as allowed, and the server's refusal is then shown when it comes.
    func mayWrite(_ host: String?) -> Bool {
        guard let host else { return true }
        return writeAccess[host] != false
    }

    func mayWrite(_ repo: ForgeRepo) -> Bool { mayWrite(workspace?.host) }

    /// Asks each server once what its token may do, for the buttons that write.
    func learnWriteAccess() async {
        // Measuring on a server that must be left alone: not even a probe goes out.
        if ProcessInfo.processInfo.environment["GNV_DEV_NOFETCH"] != nil { return }
        for account in accounts where writeAccess[account.host] == nil {
            let checks = await permissions(host: account.host)
            let writes = checks.filter { $0.writes && $0.id != "write-notes" }
            if writes.contains(where: { $0.answer == .no }) {
                writeAccess[account.host] = false
            } else if !writes.isEmpty, writes.allSatisfy({ $0.answer == .yes }) {
                writeAccess[account.host] = true
            }
        }
    }

    /// Forgejo's API can start a run or a job again from version 17 on;
    /// before, the app does it through the server's web pages (see
    /// ForgeWebSession). An unknown version is tried with the API.
    func supportsRerun(_ host: String?) -> Bool {
        guard let host, let version = accounts.first(where: { $0.host == host })?.serverVersion,
              let major = Int(version.prefix { $0.isNumber }) else { return true }
        return major >= 17
    }

    static let readOnlyNote = "This server's token is read-only: connect one with write access to repositories and issues to do this."

    // MARK: First run and the tour

    var tourSeen: Bool {
        get { _ = settingsRevision; return defaults.bool(forKey: "tourSeen") }
        set { defaults.set(newValue, forKey: "tourSeen"); settingsRevision += 1 }
    }

    func startTour() {
        wizardOpen = false
        tourStep = 0
    }

    func endTour() {
        tourStep = nil
        tourSeen = true
    }

    /// The folder GitNest suggests for everything it clones.
    static var suggestedWorkdir: URL {
        // Tests name their own folder: they must not make one in the user's home.
        if let path = ProcessInfo.processInfo.environment["GNV_SUGGESTED_WORKDIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "GitNest")
    }
}

extension ForgejoClient {
    /// The HTTP status of a request, nothing else; 0 when the server did not answer.
    func status(_ method: String, _ pathAndQuery: String) async -> Int {
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/" + pathAndQuery) else { return 0 }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        if let token, !token.isEmpty { request.setValue("token " + token, forHTTPHeaderField: "Authorization") }
        guard let (_, response) = try? await session.data(for: request, delegate: AuthGuard.shared) else { return 0 }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
