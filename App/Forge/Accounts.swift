import Foundation
import Security

/// Where access tokens are kept. The app uses the Keychain; tests use memory.
protocol TokenStore: Sendable {
    func token(for host: String) -> String?
    func setToken(_ token: String?, for host: String) throws
}

struct KeychainTokenStore: TokenStore {
    static let service = "pl.paksonite.gitnest-view"

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain did not save the token: \(text)"
        }
    }

    private func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: host]
    }

    func token(for host: String) -> String? {
        var query = query(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String?, for host: String) throws {
        SecItemDelete(query(host) as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var item = query(host)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "GitNest View: \(host)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func token(for host: String) -> String? {
        lock.withLock { tokens[host] }
    }

    func setToken(_ token: String?, for host: String) throws {
        lock.withLock { tokens[host] = token }
    }
}

/// A forge the user connected: the host as it appears in remote URLs.
/// The token lives in the TokenStore, never in preferences.
struct ForgeAccount: Codable, Identifiable, Hashable, Sendable {
    var host: String
    /// Who the token belongs to, shown in Settings.
    var login: String?
    var serverVersion: String?
    /// Clone over SSH with the user's own keys; otherwise over HTTPS with
    /// the access token.
    var cloneWithSSH: Bool?

    var id: String { host }

    /// "forge.example.com", whatever the user pasted (a URL, a trailing slash).
    static func normalize(_ input: String) -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        return host
    }
}
