import Foundation
import XCTest
@testable import GitNestView

/// A Forgejo server that lives in the test process: answers recorded from a
/// real server (Tests/Fixtures/forge), multiplied to any number of
/// repositories, with switches for the ways a server goes wrong.
final class CannedForge: URLProtocol, @unchecked Sendable {
    static let host = "forge.example.test"
    static let org = "Lab"

    struct State {
        var repos = 12
        /// Every n-th repository has the recorded open pull request.
        var pullEvery = 4
        /// Path fragments answered with this status instead of the recording.
        var failing: [String: Int] = [:]
        /// Path fragments answered with this body (status 200).
        var garbage: Set<String> = []
        /// Seconds every answer waits.
        var latency = 0.0
        /// Like Forgejo 16: the list of runs ignores "limit" without "page".
        var unpagedRunLists = 0
        var hits: [String: Int] = [:]
        var writes: [String] = []
        var probes = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    nonisolated(unsafe) private static var fixtures: [String: Data] = [:]

    static func reset(_ change: (inout State) -> Void = { _ in }) {
        lock.withLock { state = State(); change(&state) }
    }

    static func change(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }
    static var hits: [String: Int] { lock.withLock { state.hits } }
    static var writes: [String] { lock.withLock { state.writes } }
    static var totalHits: Int { hits.values.reduce(0, +) }
    static var unpagedRunLists: Int { lock.withLock { state.unpagedRunLists } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedForge.self]
        return URLSession(configuration: configuration)
    }

    static func repoName(_ index: Int) -> String {
        let areas = ["core", "net", "data", "sec", "app", "obs", "fin", "ops"]
        return String(format: "org-%@-svc%03d", areas[index % areas.count], index)
    }

    private static func fixture(_ name: String) -> Data {
        lock.withLock {
            if let data = fixtures[name] { return data }
            let url = Bundle(for: CannedForge.self).url(forResource: name, withExtension: "json")
                ?? Bundle(for: CannedForge.self).url(forResource: name, withExtension: "json", subdirectory: "forge")
            let data = url.flatMap { try? Data(contentsOf: $0) } ?? Data("null".utf8)
            fixtures[name] = data
            return data
        }
    }

    private static func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data("null".utf8) }

    private static func repoList(page: Int, limit: Int, count: Int) -> Data {
        guard let template = (try? JSONSerialization.jsonObject(with: fixture("repos")) as? [[String: Any]])?.first else { return Data("[]".utf8) }
        let from = (page - 1) * limit
        guard from < count else { return Data("[]".utf8) }
        let pullEvery = lock.withLock { state.pullEvery }
        return json((from..<min(count, from + limit)).map { index -> [String: Any] in
            var repo = template
            let name = repoName(index)
            repo["id"] = 1000 + index
            repo["name"] = name
            repo["full_name"] = "\(org)/\(name)"
            repo["empty"] = false
            repo["has_actions"] = true
            repo["default_branch"] = "main"
            repo["open_pr_counter"] = pullEvery > 0 && index % pullEvery == 0 ? 1 : 0
            repo["html_url"] = "https://\(host)/\(org)/\(name)"
            repo["clone_url"] = "https://\(host)/\(org)/\(name).git"
            var owner = repo["owner"] as? [String: Any] ?? [:]
            owner["login"] = org
            owner["username"] = org
            repo["owner"] = owner
            return repo
        })
    }

    /// The answer for a path below /api/v1/.
    private static func answer(_ path: String, query: [String: String], method: String) -> (Int, Data) {
        let snapshot = lock.withLock { () -> State in
            state.hits[path, default: 0] += 1
            // The permission probes aim at nothing: they are not changes.
            let probe = path.contains("gitnest-view-probe") || path == "notifications/threads/0"
            if method != "GET" { if probe { state.probes += 1 } else { state.writes.append("\(method) \(path)") } }
            return state
        }
        for (fragment, status) in snapshot.failing where path.contains(fragment) { return (status, Data("{\"message\":\"canned failure\"}".utf8)) }
        for fragment in snapshot.garbage where path.contains(fragment) { return (200, Data("<html>proxy error</html>".utf8)) }
        if method != "GET" { return (200, Data("{}".utf8)) }
        switch path {
        case "version": return (200, fixture("version"))
        case "user": return (200, fixture("user"))
        case "user/orgs":
            var orgs = (try? JSONSerialization.jsonObject(with: fixture("orgs")) as? [[String: Any]]) ?? []
            if var first = orgs.first {
                first["username"] = org; first["name"] = org; first["full_name"] = org
                orgs = [first]
            }
            return (200, json(orgs))
        case "orgs/\(org)/repos":
            return (200, repoList(page: Int(query["page"] ?? "") ?? 1, limit: Int(query["limit"] ?? "") ?? 50, count: snapshot.repos))
        case "user/repos": return (200, Data("[]".utf8))
        case "repos/issues/search": return (200, fixture("search"))
        default: break
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "repos" else { return (404, Data("{}".utf8)) }
        let name = parts[2]
        let index = Int(name.suffix(3)) ?? 0
        let hasPull = snapshot.pullEvery > 0 && index % snapshot.pullEvery == 0
        let rest = parts.dropFirst(3).joined(separator: "/")
        switch rest {
        case "pulls":
            // The recorded pull request is open.
            return (200, hasPull && query["state"] != "closed" ? fixture("pulls") : Data("[]".utf8))
        case "actions/runs":
            if query["page"] == nil { lock.withLock { state.unpagedRunLists += 1 } }
            return (200, fixture("runs"))
        case "branch_protections": return (200, fixture("protections"))
        case "branches":
            let names = ["feat/b", "develop", "main", "feat/a"]
            return (200, (Int(query["page"] ?? "1") ?? 1) == 1 ? json(names.map { ["name": $0] }) : Data("[]".utf8))
        default: break
        }
        if rest.hasPrefix("pulls/") {
            if rest.hasSuffix("/commits") { return (200, fixture("commits")) }
            if rest.hasSuffix("/files") { return (200, fixture("files")) }
            if rest.hasSuffix("/reviews") { return (200, fixture("reviews")) }
            return (200, fixture("pull"))
        }
        if rest.hasPrefix("commits/"), rest.hasSuffix("/status") { return (200, fixture("status")) }
        if rest.hasPrefix("actions/runs/"), rest.hasSuffix("/jobs") { return (200, fixture("jobs")) }
        if rest.hasPrefix("actions/jobs/"), rest.hasSuffix("/logs") { return (200, Data("2026-01-01T00:00:00Z Terraform will perform the following actions:\n".utf8)) }
        // What a server does not have: the lab's ingress turns this into a 500.
        return (404, Data("{}".utf8))
    }

    // MARK: URLProtocol

    static let jiraHost = "jira.example.test"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host || request.url?.host == jiraHost }

    /// Jira Cloud's two answers the app reads; the token "wrong" is refused.
    private static func jira(_ request: URLRequest) -> (Int, Data) {
        lock.withLock { state.hits["jira:" + (request.url?.path ?? ""), default: 0] += 1 }
        let expected = "Basic " + Data("me@example.test:good".utf8).base64EncodedString()
        guard request.value(forHTTPHeaderField: "Authorization") == expected else { return (401, Data("{}".utf8)) }
        if request.httpMethod == "POST" {
            lock.withLock { state.writes.append("JIRA POST " + (request.url?.path ?? "")) }
            return (204, Data())
        }
        switch request.url?.path {
        case "/rest/api/3/issue/INFRA-77/transitions":
            return (200, Data(#"{"transitions":[{"id":"31","name":"Done","to":{"name":"Done"}},{"id":"11","name":"Back","to":{"name":"To Do"}}]}"#.utf8))
        case "/rest/api/3/myself": return (200, Data(#"{"displayName":"Test User","accountId":"1"}"#.utf8))
        case "/rest/api/3/search/jql":
            return (200, Data(#"""
            {"issues":[
              {"id":"1","key":"INFRA-80","fields":{"summary":"Logs bucket","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"name":"Task"}}},
              {"id":"2","key":"INFRA-77","fields":{"summary":"Bind the deploy SA","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"priority":{"name":"High"}}}
            ],"isLast":true}
            """#.utf8))
        default: return (404, Data("{}".utf8))
        }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let path = url.path.hasPrefix("/api/v1/") ? String(url.path.dropFirst("/api/v1/".count)) : url.path
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        let (status, body) = url.host == Self.jiraHost ? Self.jira(request) : Self.answer(path, query: query, method: request.httpMethod ?? "GET")
        let latency = Self.lock.withLock { Self.state.latency }
        let send = { [self] in
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if latency > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + latency, execute: send) } else { send() }
    }
}

/// A model connected to the canned server, with a few real clones on disk.
@MainActor
struct CannedApp {
    let model: AppModel
    let workdir: URL
    private let suite: String

    /// `clones` repositories get a clone with a commit and a Terraform file.
    init(repos: Int, clones: Int = 3, configure: (inout CannedForge.State) -> Void = { _ in }) async throws {
        CannedForge.reset { $0.repos = repos; configure(&$0) }
        workdir = FileManager.default.temporaryDirectory.appending(path: "gnv-canned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        for index in 0..<min(clones, repos) { try Self.makeClone(index, in: workdir) }
        suite = "gnv-canned-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        model = AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        model.session = CannedForge.session()
        model.setWorkdir(workdir)
        try await model.connect(host: CannedForge.host, token: "canned")
        if let workspace = model.workspaces.first(where: { $0.owner == CannedForge.org }) { model.select(workspace) }
        await model.loadRepos(quiet: false)
        await model.scan(full: true)
        await settle()
    }

    /// Waits until the model's own background reads (after connecting and
    /// choosing a workspace) are over, so a test starts from a quiet app.
    func settle() async {
        var last = -1
        var quiet = 0
        for _ in 0..<200 where quiet < 4 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = CannedForge.totalHits
            quiet = now == last ? quiet + 1 : 0
            last = now
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workdir)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.test", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: arguments.joined(separator: " ")]) }
    }

    static let sampleTerraform = """
    # The service's project and its bucket.
    module "project" {
      source = "git::https://forge.example.test/Lab/terraform-modules.git//project?ref=v2"
      name   = "svc-${var.env}"
    }

    resource "google_storage_bucket" "logs" {
      name     = "logs-${var.env}"
      location = "EU"
      labels   = { owner = "platform" }
    }

    data "google_project" "current" {}

    """

    @discardableResult
    static func makeClone(_ index: Int, in workdir: URL) throws -> URL {
        let name = CannedForge.repoName(index)
        let directory = workdir.appending(path: CannedForge.org).appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: directory)
        try git(["remote", "add", "origin", "https://\(CannedForge.host)/\(CannedForge.org)/\(name).git"], in: directory)
        try sampleTerraform.write(to: directory.appending(path: "main.tf"), atomically: true, encoding: .utf8)
        try "name: ci\non: [push]\n".write(to: directory.appending(path: "ci.yaml"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: directory)
        try git(["commit", "-q", "-m", "feat: T-\(index) first commit (#1)"], in: directory)
        return directory
    }
}
