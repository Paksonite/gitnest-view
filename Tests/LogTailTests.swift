import XCTest
@testable import GitNestView

final class LogTailTests: XCTestCase {
    func testWholeLinesOnly() {
        var tail = LogTail()
        XCTAssertEqual(tail.append(Data("one\ntw".utf8)).map(\.text), ["one"])
        XCTAssertEqual(tail.offset, 6)
        XCTAssertEqual(tail.append(Data("o\nthree\n".utf8)).map(\.text), ["two", "three"])
        XCTAssertEqual(tail.append(Data()).map(\.text), [])
        XCTAssertEqual(tail.offset, 14)
        XCTAssertEqual(tail.flush(), [])
    }

    func testCharacterSplitAcrossReads() {
        let bytes = Array("zażółć 🐳\n".utf8)
        for cut in 1..<bytes.count {
            var tail = LogTail()
            var lines = tail.append(Data(bytes[..<cut]))
            lines += tail.append(Data(bytes[cut...]))
            XCTAssertEqual(lines.map(\.text), ["zażółć 🐳"], "cut at byte \(cut)")
            XCTAssertEqual(tail.offset, bytes.count)
        }
    }

    func testFlushGivesTheUnfinishedLine() {
        var tail = LogTail()
        XCTAssertEqual(tail.append(Data("done\nno newline".utf8)).map(\.text), ["done"])
        XCTAssertEqual(tail.flush().map(\.text), ["no newline"])
        XCTAssertEqual(tail.flush(), [])
    }

    func testTimestampAndMarkers() {
        let step = LogTail.parse("2026-11-10T18:33:15.3871677Z ⭐ Run Main Count slowly")
        XCTAssertEqual(step.time, "18:33:15")
        XCTAssertEqual(step.text, "⭐ Run Main Count slowly")
        XCTAssertTrue(step.isStep)

        let plain = LogTail.parse("Plan: 1 to add, 0 to change, 0 to destroy.\r")
        XCTAssertNil(plain.time)
        XCTAssertEqual(plain.text, "Plan: 1 to add, 0 to change, 0 to destroy.")
        XCTAssertFalse(plain.isStep)

        XCTAssertEqual(LogTail.parse("").text, "")
        let blank = LogTail.parse("2026-11-10T18:33:15.3871677Z")
        XCTAssertEqual(blank.time, "18:33:15")
        XCTAssertEqual(blank.text, "", "an empty line may come as the timestamp alone")
        XCTAssertNil(LogTail.parse("Zebra crossing").time)
        XCTAssertTrue(LogTail.parse("2026-11-10T18:33:15.3871677Z ❌  Failure - Main Build").isFailure)
    }

    func testStripsColours() {
        XCTAssertEqual(LogTail.stripANSI("\u{1B}[1m\u{1B}[32mApply complete!\u{1B}[0m Resources: 1 added"), "Apply complete! Resources: 1 added")
        XCTAssertEqual(LogTail.stripANSI("no escapes"), "no escapes")
        XCTAssertEqual(LogTail.stripANSI("cut \u{1B}["), "cut ")

        let (text, styles) = LogTail.parseANSI("\u{1B}[1m\u{1B}[32mApply ✓\u{1B}[0m plain \u{1B}[31mred\u{1B}[39m end\u{1B}[2K")
        XCTAssertEqual(text, "Apply ✓ plain red end")
        XCTAssertEqual(styles, [
            LogStyle(start: 0, length: 7, color: .green, bold: true),
            LogStyle(start: 14, length: 3, color: .red, bold: false),
        ])
        let line = LogTail.parse("2026-11-10T18:33:15.3871677Z \u{1B}[33mWarning\u{1B}[0m")
        XCTAssertEqual(line.text, "Warning")
        XCTAssertEqual(line.styles.first?.color, .yellow)
        XCTAssertTrue(LogTail.parse("  🐳  docker exec cmd=[sh]").isRunnerNoise)
        XCTAssertFalse(LogTail.parse("Plan: 1 to add").isRunnerNoise)
    }
}
