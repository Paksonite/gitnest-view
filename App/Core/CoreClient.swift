import Foundation

/// Talks to `gitnest-core`, the Go engine inside the app bundle: JSON-RPC 2.0,
/// one message per line over the engine's stdin and stdout. The engine is
/// started on the first call and again if it ever exits.
actor CoreClient {
    enum CoreError: LocalizedError {
        case missingEngine(String)
        case cannotStart(String)
        case exited
        case rpc(code: Int, message: String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .missingEngine(let path): "The GitNest engine is missing from the app (\(path))."
            case .cannotStart(let why): "The GitNest engine did not start: \(why)"
            case .exited: "The GitNest engine stopped unexpectedly."
            case .rpc(_, let message): message
            case .badResponse: "The GitNest engine sent an answer the app does not understand."
            }
        }
    }

    private let executable: URL
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextID = 1
    /// Counts engine starts, so a reader that outlived its engine cannot fail
    /// the calls of the next one.
    private var generation = 0

    init(executable: URL) {
        self.executable = executable
    }

    /// The engine shipped in `Contents/Helpers` of the running app.
    static func bundled() -> CoreClient {
        CoreClient(executable: Bundle.main.bundleURL.appending(path: "Contents/Helpers/gitnest-core"))
    }

    func call<Result: Decodable>(
        _ method: String, _ params: some Encodable & Sendable = NoParams(), as _: Result.Type = Result.self
    ) async throws -> Result {
        let line = try await send(method, params)
        let envelope = try JSONDecoder().decode(Envelope.self, from: line)
        if let error = envelope.error {
            throw CoreError.rpc(code: error.code, message: error.message)
        }
        guard let result = try? JSONDecoder().decode(ResultEnvelope<Result>.self, from: line) else {
            throw CoreError.badResponse
        }
        return result.result
    }

    /// For methods whose result carries nothing.
    func run(_ method: String, _ params: some Encodable & Sendable = NoParams()) async throws {
        let _: Ignored = try await call(method, params)
    }

    /// Stops the engine; calls still waiting fail. The next call starts it again.
    func stop() {
        try? input?.close()
        process = nil
        input = nil
        generation += 1
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: CoreError.exited)
        }
    }

    // MARK: - Transport

    private func send(_ method: String, _ params: some Encodable) async throws -> Data {
        try start()
        let id = nextID
        nextID += 1
        var data = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        data.append(0x0A)
        guard let input else { throw CoreError.exited }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: data)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: CoreError.exited)
            }
        }
    }

    private func start() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CoreError.missingEngine(executable.path)
        }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.standardInput = stdin
        process.standardOutput = stdout
        process.environment = Self.environment()
        do {
            try process.run()
        } catch {
            throw CoreError.cannotStart(error.localizedDescription)
        }
        self.process = process
        input = stdin.fileHandleForWriting
        generation += 1
        let generation = generation
        // Read with the handle's own callback, not FileHandle.bytes: all
        // FileHandle.bytes sequences share one reader, so an idle engine
        // would hold up the answers of every other one.
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(data)
            }
        }
        Task.detached { [weak self] in
            var buffer = Data()
            for await chunk in chunks {
                buffer.append(chunk)
                // One answer per line; a chunk can end in the middle of one.
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    if !line.isEmpty { await self?.receive(line) }
                }
            }
            await self?.engineEnded(generation)
        }
    }

    /// git must find Homebrew's tools (credential helpers, a newer git) even
    /// though an app started from Finder gets only the system PATH.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        return env
    }

    private func receive(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line), let id = envelope.id else { return }
        pending.removeValue(forKey: id)?.resume(returning: line)
    }

    private func engineEnded(_ endedGeneration: Int) {
        guard endedGeneration == generation else { return }
        process = nil
        input = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: CoreError.exited)
        }
    }

    // MARK: - Wire types

    struct NoParams: Encodable, Sendable {}
    private struct Ignored: Decodable {}

    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: Params
    }

    private struct Envelope: Decodable {
        struct RPCError: Decodable {
            let code: Int
            let message: String
        }
        let id: Int?
        let error: RPCError?
    }

    private struct ResultEnvelope<Result: Decodable>: Decodable {
        let result: Result
    }
}
