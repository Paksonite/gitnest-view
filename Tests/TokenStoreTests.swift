import XCTest
@testable import GitNestView

/// The Keychain store, in the login Keychain under a service of its own:
/// everything it writes is removed again.
final class TokenStoreTests: XCTestCase {
    private let service = "pl.paksonite.gitnest-view.unit-test"
    private let hosts = ["one.example.test", "two.example.test", "jira:three.example.test"]

    override func setUp() {
        KeychainTokenStore(service: service).removeAll(hosts: hosts)
    }

    override func tearDown() {
        KeychainTokenStore(service: service).removeAll(hosts: hosts)
    }

    func testTokensShareOneItem() throws {
        let store = KeychainTokenStore(service: service)
        try store.setToken("token-one", for: hosts[0])
        try store.setToken("token-two", for: hosts[1])
        // A new store (a relaunch) reads both from the one item.
        let again = KeychainTokenStore(service: service)
        XCTAssertEqual(again.token(for: hosts[0]), "token-one")
        XCTAssertEqual(again.token(for: hosts[1]), "token-two")
        XCTAssertFalse(again.legacyExists(hosts[0]))

        try again.setToken(nil, for: hosts[0])
        let third = KeychainTokenStore(service: service)
        XCTAssertNil(third.token(for: hosts[0]))
        XCTAssertEqual(third.token(for: hosts[1]), "token-two")
    }

    func testEarlierItemsMoveIntoTheSharedOne() throws {
        let store = KeychainTokenStore(service: service)
        store.writeLegacy("old-one", for: hosts[0])
        store.writeLegacy("old-jira", for: hosts[2])
        try store.setToken("new-two", for: hosts[1])

        XCTAssertEqual(store.token(for: hosts[0]), "old-one")
        XCTAssertEqual(store.token(for: hosts[2]), "old-jira")
        XCTAssertFalse(store.legacyExists(hosts[0]), "the old item is removed once moved")
        XCTAssertFalse(store.legacyExists(hosts[2]))

        let again = KeychainTokenStore(service: service)
        XCTAssertEqual(again.token(for: hosts[0]), "old-one")
        XCTAssertEqual(again.token(for: hosts[1]), "new-two")
        XCTAssertEqual(again.token(for: hosts[2]), "old-jira")
    }
}
