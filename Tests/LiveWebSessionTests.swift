import WebKit
import XCTest
@testable import GitNestView

/// Re-running through a Forgejo 16's web pages, against a lab server.
/// Skipped unless the environment names it: GNV_WEB16_HOST, _USER,
/// _PASSWORD (a lab account), _REPO and GNV_WEB16_TOKEN (to read the run).
/// The session lives in a store of the test's own, never the app's.
@MainActor
final class LiveWebSessionTests: XCTestCase {
    func testSignedOutAsksToSignIn() async throws {
        ForgeWebSession.store = .nonPersistent()
        let host = ProcessInfo.processInfo.environment["GNV_WEB16_HOST"] ?? "forgejo.example.test"
        do {
            try await ForgeWebSession.rerun(host: host, owner: "nobody", name: "nothing", run: 1, job: 0)
            XCTFail("re-ran without a session")
        } catch ForgeWebSession.Failure.signInNeeded(let asked) {
            XCTAssertEqual(asked, host)
        }
    }

    func testCookieDomains() {
        XCTAssertTrue(ForgeWebSession.matches("git.example.com", "git.example.com"))
        XCTAssertTrue(ForgeWebSession.matches(".example.com", "git.example.com"))
        XCTAssertFalse(ForgeWebSession.matches("other.example.com", "git.example.com"))
        XCTAssertFalse(ForgeWebSession.matches("ample.com", "git.example.com"))
    }

    func testRerunJobThroughWebPages() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["GNV_WEB16_HOST"], let user = env["GNV_WEB16_USER"], let password = env["GNV_WEB16_PASSWORD"],
              let token = env["GNV_WEB16_TOKEN"], let parts = env["GNV_WEB16_REPO"]?.split(separator: "/"), parts.count == 2
        else { throw XCTSkip("no Forgejo 16 lab configured") }
        let slug = RepoSlug(host: host, owner: String(parts[0]), name: String(parts[1]))
        let store = WKWebsiteDataStore.nonPersistent()
        ForgeWebSession.store = store
        defer { ForgeWebSession.store = .default() }

        // Signed out first: the server answers as to a stranger.
        let signedOut = await ForgeWebSession.signedIn(host)
        XCTAssertFalse(signedOut)

        // What the sign-in window leaves behind: the server's session cookies.
        for cookie in try await login(host: host, user: user, password: password) {
            await store.httpCookieStore.setCookie(cookie)
        }
        let signedIn = await ForgeWebSession.signedIn(host)
        XCTAssertTrue(signedIn, "the session's cookies do not sign in")

        let client = ForgejoClient(host: host, token: token)
        let runs = try await client.runs(slug, limit: 20)
        let run = try XCTUnwrap(runs.first { $0.state.isFinished })
        let jobs = try await client.jobs(slug, run: run.id)
        let tokens = MemoryTokenStore()
        try tokens.setToken(token, for: host)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "gnv-web16-test"))
        defaults.removePersistentDomain(forName: "gnv-web16-test")
        defaults.set(try JSONEncoder().encode([ForgeAccount(host: host, login: user, serverVersion: "16.0.4", kind: .forgejo)]), forKey: "accounts")
        let model = AppModel(tokens: tokens, defaults: defaults)
        XCTAssertFalse(model.supportsRerun(host))
        try await model.rerunOnWeb(slug, run: run, job: jobs.last)

        // The job waits or runs again: a new attempt.
        var again = false
        for _ in 0..<20 where !again {
            try await Task.sleep(for: .seconds(1))
            let now = try await client.jobs(slug, run: run.id)
            again = now.contains { $0.id == jobs.last?.id && (!$0.state.isFinished || ($0.attempt ?? 1) > (jobs.last?.attempt ?? 1)) }
        }
        XCTAssertTrue(again, "\(jobs.last?.name ?? "") of run #\(run.number) did not start again")
    }

    /// Forgejo's login form, as a browser posts it.
    private func login(host: String, user: String, password: String) async throws -> [HTTPCookie] {
        // An ephemeral session keeps its cookies in a jar of its own.
        let session = URLSession(configuration: .ephemeral)
        let url = try XCTUnwrap(URL(string: "https://\(host)/user/login"))
        _ = try await session.data(from: url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "user_name", value: user), URLQueryItem(name: "password", value: password),
                           URLQueryItem(name: "remember", value: "on")]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        _ = try await session.data(for: request)
        let cookies = session.configuration.httpCookieStorage?.cookies ?? []
        XCTAssertFalse(cookies.isEmpty, "the login left no cookie")
        return cookies
    }
}
