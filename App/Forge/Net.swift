import AppKit
import Foundation

/// Keeps a credential on the server it is for: a redirect to another host
/// goes on without the Authorization header, and never to plain http.
final class AuthGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = AuthGuard()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url else { return request }
        return Self.redirected(request, from: from, to: to)
    }

    static func redirected(_ request: URLRequest, from: URL, to: URL) -> URLRequest? {
        // A token must not follow a downgrade.
        if from.scheme?.lowercased() == "https", to.scheme?.lowercased() != "https" { return nil }
        guard from.host?.lowercased() != to.host?.lowercased() else { return request }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        return stripped
    }
}

/// Opens a link that came from a server or a file: web pages and the
/// editor only, never a file or another app's scheme.
@MainActor
@discardableResult
func openExternal(_ url: URL) -> Bool {
    guard ["https", "http", "vscode"].contains(url.scheme?.lowercased() ?? "") else { return false }
    // Tests do everything the app does, except leave it.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
    return NSWorkspace.shared.open(url)
}
