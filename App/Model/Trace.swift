import Foundation

/// Timing notes on stderr, for hunting slowness. Off unless GNV_TRACE is set.
enum Trace {
    static let on = ProcessInfo.processInfo.environment["GNV_TRACE"] != nil
    nonisolated(unsafe) private static var mark = Date()
    private static let lock = NSLock()

    /// Starts the clock: "the user asked for something now".
    static func begin(_ what: @autoclosure () -> String) {
        guard on else { return }
        lock.lock(); mark = Date(); lock.unlock()
        FileHandle.standardError.write("TRACE    0 ms  BEGIN \(what())\n".data(using: .utf8)!)
    }

    static func note(_ what: @autoclosure () -> String) {
        guard on else { return }
        lock.lock(); let ms = Int(Date().timeIntervalSince(mark) * 1000); lock.unlock()
        FileHandle.standardError.write(String(format: "TRACE %4d ms  %@\n", ms, what()).data(using: .utf8)!)
    }

    /// Reports every time the main thread does not answer for 25 ms or more.
    static func watchMainThread() {
        guard on else { return }
        Thread.detachNewThread {
            while true {
                let asked = Date()
                DispatchQueue.main.sync {}
                let ms = Int(Date().timeIntervalSince(asked) * 1000)
                if ms >= 25 { note("main thread was busy for \(ms) ms") }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }
}
