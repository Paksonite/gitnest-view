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
        let probes: [(String, String, String, Bool, String, String)] = [
            ("user", "Sign in and know who you are", "read:user", false, "GET", "user"),
            ("repos", "List repositories, read pipelines and logs", "read:repository", false, "GET", "user/repos?limit=1"),
            ("orgs", "Workspaces (organisations)", "read:organization", false, "GET", "user/orgs?limit=1"),
            ("issues", "Pull requests, reviews and the Inbox", "read:issue", false, "GET", "repos/issues/search?limit=1&type=pulls"),
            ("notes", "Unread marks from the server", "read:notification", false, "GET", "notifications?limit=1"),
            ("write-repo", "Merge, open pull requests, run and re-run pipelines", "write:repository", true, "POST", "repos/gitnest-view-probe/none/pulls"),
            ("write-issue", "Comment, review, labels, reviewers", "write:issue", true, "POST", "repos/gitnest-view-probe/none/issues/0/comments"),
            ("write-notes", "Mark as read", "write:notification", true, "PATCH", "notifications/threads/0"),
        ]
        return await withTaskGroup(of: (Int, PermissionCheck).self) { group in
            for (index, probe) in probes.enumerated() {
                group.addTask {
                    let status = await client.status(probe.4, probe.5)
                    let answer: PermissionCheck.Answer
                    if probe.3 {
                        // Not found / unprocessable: the scope let it through. Forbidden: it did not.
                        answer = [404, 405, 422, 400].contains(status) || (200..<300).contains(status) ? .yes : [401, 403].contains(status) ? .no : .unknown
                    } else {
                        answer = (200..<300).contains(status) ? .yes : [401, 403].contains(status) ? .no : .unknown
                    }
                    return (index, PermissionCheck(id: probe.0, feature: probe.1, scope: probe.2, writes: probe.3, answer: answer))
                }
            }
            var all: [(Int, PermissionCheck)] = []
            for await item in group { all.append(item) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
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
    /// 16 can only do it in the browser. An unknown version is tried.
    func supportsRerun(_ host: String?) -> Bool {
        guard let host, let version = accounts.first(where: { $0.host == host })?.serverVersion,
              let major = Int(version.prefix { $0.isNumber }) else { return true }
        return major >= 17
    }

    /// Where a run can be started again by hand when the API cannot do it.
    func rerunInBrowser(_ url: String?, what: String) {
        toast("This server's Forgejo cannot run \(what) again from here: opened it in the browser, use Re-run there.", .info)
        if let url = url.flatMap(URL.init) { openExternal(url) }
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
