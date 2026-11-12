import SwiftUI
import XCTest
@testable import GitNestView

/// The app's real window inside the test process: steps are taken through
/// the model, the way clicks do, and every step is drawn and timed.
@MainActor
final class FlowWindow {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    var timings: [(String, Double)] = []

    /// macOS quietly ends an app that has no window left; the tests after
    /// this one still need their host.
    private static let keepAlive: Void = {
        ProcessInfo.processInfo.disableAutomaticTermination("tests are running")
        ProcessInfo.processInfo.disableSuddenTermination()
    }()

    init(_ model: AppModel) {
        _ = Self.keepAlive
        host = NSHostingView(rootView: AnyView(RootView().environment(model)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 880), styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }

    private func draw() -> Double {
        let started = Date()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        return Date().timeIntervalSince(started) * 1000
    }

    /// Does what a click does, draws the result, and notes how long the
    /// main thread was held; then lets the app's own reads finish and draws
    /// what they brought.
    func step(_ name: String, wait: Double = 0.25, _ action: () -> Void) async {
        let started = Date()
        action()
        _ = draw()
        timings.append((name, Date().timeIntervalSince(started) * 1000))
        try? await Task.sleep(for: .seconds(wait))
        timings.append((name + " (settled)", draw()))
    }

    /// Texts on screen, read the way VoiceOver reads them; empty when the
    /// accessibility tree does not answer in this process.
    func visibleTexts() -> Set<String> {
        var found: Set<String> = []
        var queue: [Any] = [host as Any]
        var seen = 0
        while let next = queue.popLast(), seen < 20000 {
            seen += 1
            guard let element = next as? NSObject else { continue }
            for key in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] where element.responds(to: NSSelectorFromString(key)) {
                if let text = element.value(forKey: key) as? String, !text.isEmpty { found.insert(text) }
            }
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [Any] { queue.append(contentsOf: children) }
        }
        return found
    }

    func report(budget: Double, file: StaticString = #filePath, line: UInt = #line) {
        let worst = timings.max { $0.1 < $1.1 }
        let text = timings.map { String(format: "%6.1f ms  %@", $0.1, $0.0) }.joined(separator: "\n")
        print("UI flow timings:\n\(text)")
        // A shared CI machine draws several times slower than a desk.
        let budget = ProcessInfo.processInfo.environment["CI"] == nil ? budget : budget * 8
        if let worst { XCTAssertLessThan(worst.1, budget, "\"\(worst.0)\" held the main thread too long\n\(text)", file: file, line: line) }
    }
}
