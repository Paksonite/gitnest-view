import XCTest
@testable import GitNestView

/// The app and the real engine together: the tests run inside the app, so
/// `gitnest-core` is the one in its bundle.
final class CoreClientTests: XCTestCase {
    func testEngineAnswers() async throws {
        let core = CoreClient.bundled()
        let info: CoreInfo = try await core.call("core.info")
        XCTAssertFalse(info.version.isEmpty)
        XCTAssertFalse(info.git.isEmpty, "git must be found: \(info.gitError)")
        await core.stop()
    }

    func testConcurrentCallsGetTheirOwnAnswers() async throws {
        let core = CoreClient.bundled()
        let dir = FileManager.default.temporaryDirectory.appending(path: "gnv-\(UUID().uuidString)").path
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let info: CoreInfo = try await core.call("core.info")
                    XCTAssertFalse(info.version.isEmpty)
                }
                group.addTask {
                    let result: ScanResult = try await core.call("repos.status", PathsParams(paths: [dir]))
                    XCTAssertEqual(result.repos, [], "a path that is not a repository is left out")
                }
            }
            try await group.waitForAll()
        }
        await core.stop()
    }

    func testEngineErrorsBecomeErrors() async throws {
        let core = CoreClient.bundled()
        do {
            try await core.run("repo.fetch", RepoParams(path: "/nonexistent/repository"))
            XCTFail("fetching a missing repository must fail")
        } catch let error as CoreClient.CoreError {
            guard case .rpc(_, let message) = error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertTrue(message.contains("not a git repository"), message)
        }
        do {
            try await core.run("no.such.method")
            XCTFail("an unknown method must fail")
        } catch let error as CoreClient.CoreError {
            guard case .rpc(let code, _) = error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(code, -32601)
        }
        await core.stop()
    }

    func testRestartsAfterStop() async throws {
        let core = CoreClient.bundled()
        let _: CoreInfo = try await core.call("core.info")
        await core.stop()
        let again: CoreInfo = try await core.call("core.info")
        XCTAssertFalse(again.version.isEmpty)
        await core.stop()
    }

    /// Several engines at once (one per window, or left idle) must not hold
    /// each other's answers up.
    func testIdleEnginesDoNotBlockOthers() async throws {
        let idle = [CoreClient.bundled(), CoreClient.bundled(), CoreClient.bundled()]
        for core in idle {
            let _: CoreInfo = try await core.call("core.info")
        }
        let busy = CoreClient.bundled()
        for _ in 0..<5 {
            let info: CoreInfo = try await busy.call("core.info")
            XCTAssertFalse(info.version.isEmpty)
        }
        for core in idle + [busy] { await core.stop() }
    }

    func testMissingEngine() async {
        let core = CoreClient(executable: URL(fileURLWithPath: "/nonexistent/gitnest-core"))
        do {
            let _: CoreInfo = try await core.call("core.info")
            XCTFail("a missing engine must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing"), error.localizedDescription)
        }
    }
}
