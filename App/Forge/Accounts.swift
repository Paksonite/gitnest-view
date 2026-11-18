import Foundation
import Security

/// Where access tokens are kept. The app uses the Keychain; tests use memory.
protocol TokenStore: Sendable {
    func token(for host: String) -> String?
    func setToken(_ token: String?, for host: String) throws
}

/// The tokens of every server and Jira site in one Keychain item.
///
/// The app is signed with its own certificate, which has no Apple Team ID,
/// so macOS ties a Keychain item's access to the exact build that was
/// allowed ("cdhash" partitions): every update asks again, once per item.
/// With all tokens in one item it asks once per update, not once per server.
/// Items of earlier versions (one per host) move into it when first read.
final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    static let service = "pl.paksonite.gitnest-view"
    /// The account of the one item that holds them all.
    static let bundleAccount = "gitnest-view.tokens"

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain did not save the token: \(text)"
        }
    }

    private let service: String
    private let lock = NSLock()
    /// What the item holds, once read: nil until then.
    private var bundle: [String: String]?
    /// The item exists but could not be read (access denied): never written
    /// over, so a "Deny" loses no token.
    private var unreadable = false

    init(service: String = KeychainTokenStore.service) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> (Data?, OSStatus) {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (item as? Data, status)
    }

    /// Reads the shared item once; the caller holds the lock.
    private func loadBundle() -> [String: String] {
        if let bundle { return bundle }
        let (data, status) = read(Self.bundleAccount)
        if status == errSecSuccess, let data, let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            bundle = saved
        } else {
            unreadable = status != errSecItemNotFound
            bundle = [:]
        }
        return bundle ?? [:]
    }

    private func saveBundle(_ tokens: [String: String]) throws {
        guard !unreadable else { throw KeychainError(status: errSecAuthFailed) }
        let data = try JSONEncoder().encode(tokens)
        let update = SecItemUpdate(query(Self.bundleAccount) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query(Self.bundleAccount)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "GitNest View: tokens"
            item[kSecAttrDescription as String] = "Access tokens of the servers connected to GitNest View"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if update != errSecSuccess {
            throw KeychainError(status: update)
        }
        bundle = tokens
    }

    func token(for host: String) -> String? {
        lock.withLock {
            var tokens = loadBundle()
            if let token = tokens[host] { return token }
            // An item of an earlier version: moved into the shared one.
            guard case (let data?, errSecSuccess) = read(host), let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
            tokens[host] = token
            if (try? saveBundle(tokens)) != nil { SecItemDelete(query(host) as CFDictionary) }
            return token
        }
    }

    func setToken(_ token: String?, for host: String) throws {
        try lock.withLock {
            var tokens = loadBundle()
            if let token, !token.isEmpty { tokens[host] = token } else { tokens[host] = nil }
            try saveBundle(tokens)
            SecItemDelete(query(host) as CFDictionary)
        }
    }

    /// Removes everything this store wrote (tests).
    func removeAll(hosts: [String]) {
        lock.withLock {
            SecItemDelete(query(Self.bundleAccount) as CFDictionary)
            for host in hosts { SecItemDelete(query(host) as CFDictionary) }
            bundle = nil
            unreadable = false
        }
    }

    /// Writes an item the way versions up to 0.1.9 did (tests).
    func writeLegacy(_ token: String, for host: String) {
        var item = query(host)
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    func legacyExists(_ host: String) -> Bool { read(host).1 == errSecSuccess }
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
    /// Forgejo when absent: accounts saved before GitHub and GitLab came.
    var kind: ForgeKind?

    var id: String { host }
    var forgeKind: ForgeKind { kind ?? .forgejo }

    /// "forge.example.com", whatever the user pasted (a URL, a trailing slash).
    static func normalize(_ input: String) -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        return host
    }
}
