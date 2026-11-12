import XCTest
@testable import GitNestView

/// Serves canned answers for the follower's requests.
final class CannedServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: String] = [:] // "path?query" → body

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = url.path + (url.query.map { "?" + $0 } ?? "")
        let body = Self.answers[key]
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func client() -> ForgejoClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CannedServer.self]
        return ForgejoClient(host: "forge.test", token: "t", session: URLSession(configuration: config))
    }
}

@MainActor
final class LogFollowerTests: XCTestCase {
    private let base = "/api/v1/repos/o/r/actions"
    private let target = LogTarget(repo: RepoSlug(host: "forge.test", owner: "o", name: "r"), runID: 7, jobID: 1, title: "t", webURL: nil)

    private let job = """
    {"id":1,"name":"plan","status":"success","task_id":3,"steps":[
      {"number":0,"name":"Set up","status":"success","started":"2026-11-10T21:06:44Z","stopped":"2026-11-10T21:06:45Z"},
      {"number":1,"name":"Plan","status":"success","started":"2026-11-10T21:06:45Z","stopped":"2026-11-10T21:06:50Z"}]}
    """

    private func follow() async -> LogFollower {
        let follower = LogFollower()
        follower.follow(target, client: CannedServer.client())
        for _ in 0..<100 where follower.live { try? await Task.sleep(for: .milliseconds(20)) }
        return follower
    }

    func testReadsStepByStep() async {
        CannedServer.answers = [
            "\(base)/jobs/1": job,
            "\(base)/jobs/1/logs?step=0": "2026-11-10T21:06:44.1Z Runner received task\n",
            "\(base)/jobs/1/logs?step=1": "2026-11-10T21:06:46.1Z Plan: 1 to add, 0 to change, 0 to destroy.\n",
        ]
        let follower = await follow()
        XCTAssertFalse(follower.live)
        XCTAssertEqual(follower.steps.map(\.step.name), ["Set up", "Plan"])
        XCTAssertEqual(follower.steps.map { $0.lines.map(\.text) }, [["Runner received task"], ["Plan: 1 to add, 0 to change, 0 to destroy."]])
    }

    /// An older server ignores ?step= and answers each step with the whole
    /// log: the follower notices and shows the log in one piece.
    func testServerThatIgnoresTheStepFilter() async {
        let whole = "2026-11-10T21:06:44.1Z one\n2026-11-10T21:06:46.1Z two\n"
        CannedServer.answers = [
            "\(base)/jobs/1": job,
            "\(base)/jobs/1/logs?step=0": whole,
            "\(base)/jobs/1/logs?step=1": whole,
            "\(base)/jobs/1/logs": whole,
        ]
        let follower = await follow()
        XCTAssertTrue(follower.steps.isEmpty)
        XCTAssertEqual(follower.lines.map(\.text), ["one", "two"])
    }

    /// No steps in the job (no step API): the whole log.
    func testJobWithoutSteps() async {
        CannedServer.answers = [
            "\(base)/jobs/1": #"{"id":1,"name":"plan","status":"failure","task_id":3}"#,
            "\(base)/jobs/1/logs": "2026-11-10T21:06:44.1Z Error: boom\n",
        ]
        let follower = await follow()
        XCTAssertEqual(follower.state, .failure)
        XCTAssertEqual(follower.lines.map(\.text), ["Error: boom"])
    }
}
