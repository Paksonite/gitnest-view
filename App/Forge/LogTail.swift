import Foundation

/// One line of a job's log.
struct LogLine: Hashable, Sendable {
    /// The runner's timestamp, when the line starts with one.
    var time: String?
    var text: String
    /// Set on the one-line summaries of Terraform resource changes.
    var action: TerraformPlan.Action?
    /// Colours and weight the program itself asked for (terminal escapes).
    var styles: [LogStyle] = []

    /// What the runner prints about itself (containers, networks): rarely
    /// what the reader came for.
    var isRunnerNoise: Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("🐳") || text.hasPrefix("🚀") || text.hasPrefix("☁") || text.hasPrefix("🧪")
            || text.hasPrefix("Cleaning up ") || text.hasPrefix("The network alias is ") || text == "workflow prepared"
            || (text.hasPrefix("Runner ") && text.contains("received task"))
    }

    /// A line that opens a step ("⭐ Run Main Build").
    var isStep: Bool { text.hasPrefix("⭐") }
    var isFailure: Bool { text.hasPrefix("❌") || text.hasPrefix("::error") }
}

/// Turns the bytes of a growing log into whole lines. A read can end in the
/// middle of a line, or even of a character, so the unfinished tail waits for
/// the next read.
struct LogTail: Sendable {
    /// How many bytes of the log were consumed: where the next read starts.
    private(set) var offset = 0
    private var rest = Data()

    mutating func append(_ data: Data) -> [LogLine] {
        offset += data.count
        rest.append(data)
        guard let lastNewline = rest.lastIndex(of: 0x0A) else { return [] }
        let whole = rest[rest.startIndex...lastNewline]
        rest = Data(rest[rest.index(after: lastNewline)...])
        return String(decoding: whole, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast() // the piece after the final newline is empty
            .map { Self.parse(String($0)) }
    }

    /// The line still without its newline, shown when the job has ended.
    mutating func flush() -> [LogLine] {
        guard !rest.isEmpty else { return [] }
        let line = String(decoding: rest, as: UTF8.self)
        rest = Data()
        return [Self.parse(line)]
    }

    static func parse(_ raw: String) -> LogLine {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        var time: String?
        // "2026-11-10T18:33:15.5251032Z text"; an empty line is the stamp alone.
        let stamp = line.prefix { $0 != " " }
        if stamp.hasSuffix("Z"), stamp.count > 19, stamp[stamp.index(stamp.startIndex, offsetBy: 10)] == "T",
           stamp.first?.isNumber == true, let clock = stamp.split(separator: "T").last {
            time = String(clock.prefix(8))
            line = String(line.dropFirst(min(stamp.count + 1, line.count)))
        }
        let (text, styles) = parseANSI(line)
        return LogLine(time: time, text: text, styles: styles)
    }

    /// Removes terminal colour and cursor sequences (ESC [ … letter).
    static func stripANSI(_ text: String) -> String {
        parseANSI(text).0
    }

    /// Takes the terminal escapes out of a line and returns what the colour
    /// ones said: which stretch of the text is which colour, or bold.
    static func parseANSI(_ text: String) -> (String, [LogStyle]) {
        guard text.contains("\u{1B}") else { return (text, []) }
        var out = ""
        out.reserveCapacity(text.count)
        var styles: [LogStyle] = []
        var color: LogStyle.Color?
        var bold = false
        var spanStart = 0

        func closeSpan() {
            let end = out.utf16.count
            if end > spanStart, color != nil || bold {
                styles.append(LogStyle(start: spanStart, length: end - spanStart, color: color, bold: bold))
            }
            spanStart = end
        }

        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else {
                out.unicodeScalars.append(scalar)
                continue
            }
            guard let next = scalars.next(), next == "[" else { continue }
            var parameters = ""
            var final: Unicode.Scalar?
            while let parameter = scalars.next() {
                if (0x40...0x7E).contains(parameter.value) {
                    final = parameter
                    break
                }
                parameters.unicodeScalars.append(parameter)
            }
            guard final == "m" else { continue } // only colours; cursor moves are dropped
            closeSpan()
            let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            var index = 0
            while index < max(codes.count, 1) {
                let code = codes.isEmpty ? 0 : codes[index]
                switch code {
                case 0: color = nil; bold = false
                case 1: bold = true
                case 22: bold = false
                case 30...37: color = LogStyle.Color(rawValue: code - 30)
                case 90...97: color = LogStyle.Color(rawValue: code - 90)
                case 39: color = nil
                case 38, 48: index += codes.count > index + 1 && codes[index + 1] == 5 ? 2 : 4 // extended colours: skipped
                default: break
                }
                index += 1
            }
        }
        closeSpan()
        return (out, styles)
    }
}

/// A stretch of a log line with a terminal colour or weight. Offsets count
/// UTF-16 units, as AppKit's text does.
struct LogStyle: Hashable, Sendable {
    enum Color: Int, Sendable { case black, red, green, yellow, blue, magenta, cyan, white }
    var start: Int
    var length: Int
    var color: Color?
    var bold: Bool
}
