import Foundation
import SwiftUI
import WebKit

/// Forgejo before 17 has no API to run a pipeline again: only its web pages
/// can. The app keeps a web session of its own for such a server (the user
/// signs in once, in the app's window, the way they sign in in a browser) and
/// posts the same form the page's Re-run button posts.
///
/// The session lives in the app's WebKit store: cookies only, never a
/// password, and only for the servers where the user signed in.
@MainActor
enum ForgeWebSession {
    enum Failure: LocalizedError {
        case signInNeeded(String)
        case refused(String, Int)

        var errorDescription: String? {
            switch self {
            case .signInNeeded(let host): "Sign in to \(host) in GitNest View to run pipelines again there."
            case .refused(let host, let status): "\(host) did not run it again (HTTP \(status))."
            }
        }
    }

    /// The app's own WebKit store; tests put a store of their own here.
    static var store: WKWebsiteDataStore = .default()

    static func cookies(for host: String) async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies().filter { matches($0.domain, host) }
    }

    /// "example.com" and ".example.com" both cover "git.example.com".
    nonisolated static func matches(_ domain: String, _ host: String) -> Bool {
        let domain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Whether the cookies sign the user in: the settings page answers
    /// instead of sending to the login page.
    static func signedIn(_ host: String) async -> Bool {
        guard let url = URL(string: "https://\(host)/user/settings") else { return false }
        let cookies = await cookies(for: host)
        guard !cookies.isEmpty else { return false }
        return (try? await send(URLRequest(url: url), cookies: cookies).1) == 200
    }

    /// Runs a whole run again ("/owner/name/actions/runs/7/rerun") or one of
    /// its jobs (".../runs/7/jobs/2/rerun", the job's place in the run).
    static func rerun(host: String, owner: String, name: String, run index: Int, job: Int?) async throws {
        var path = "/\(owner)/\(name)/actions/runs/\(index)"
        if let job { path += "/jobs/\(job)" }
        try await post(host: host, path: path + "/rerun")
    }

    static func post(host: String, path: String) async throws {
        guard let url = URL(string: "https://\(host)\(path)") else { throw Failure.refused(host, 0) }
        let cookies = await cookies(for: host)
        guard !cookies.isEmpty else { throw Failure.signInNeeded(host) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Forgejo checks where a form comes from instead of a token in it.
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, status) = try await send(request, cookies: cookies)
        if status == 200 { return }
        // Signed out answers "not found" or sends to the login page.
        if await !signedIn(host) { throw Failure.signInNeeded(host) }
        throw Failure.refused(host, status)
    }

    /// One request with the session's cookies, redirects not followed.
    private static func send(_ request: URLRequest, cookies: [HTTPCookie]) async throws -> (Data, Int) {
        var request = request
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: field) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Forgets the web session of one server.
    static func signOut(_ host: String) async {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { matches($0.displayName, host) || host.hasSuffix($0.displayName) }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
        for cookie in await cookies(for: host) { await store.httpCookieStore.deleteCookie(cookie) }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// The server's login page in the app's own WebKit store, so what the user
/// signs in with stays in the app. Calls `done` once signed in.
struct WebSignInView: NSViewRepresentable {
    let host: String
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(host: host, done: done) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ForgeWebSession.store
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        if let url = URL(string: "https://\(host)/user/login?redirect_to=%2Fuser%2Fsettings") { view.load(URLRequest(url: url)) }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let host: String
        let done: () -> Void
        private var finished = false

        init(host: String, done: @escaping () -> Void) {
            self.host = host
            self.done = done
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, let url = webView.url, url.host == host,
                  !url.path.hasPrefix("/user/login"), !url.path.hasPrefix("/user/two_factor"),
                  !url.path.hasPrefix("/user/webauthn"), !url.path.hasPrefix("/user/oauth2") else { return }
            Task {
                guard await ForgeWebSession.signedIn(host), !finished else { return }
                finished = true
                done()
            }
        }
    }
}
