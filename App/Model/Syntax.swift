import Foundation

/// Colours a source file: Terraform / OpenTofu / Terragrunt (HCL) in full,
/// YAML and JSON enough to read them. Works on UTF-16 offsets, the ones
/// NSTextView counts in.
enum Syntax {
    enum Kind: Sendable {
        case comment, string, number, keyword, attribute, constant, function, reference, punctuation
    }

    struct Token: Equatable, Sendable {
        var range: NSRange
        var kind: Kind
    }

    enum Language: Sendable { case hcl, yaml, json, plain }

    static func language(of file: String) -> Language {
        let name = (file as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "tf", "hcl", "tfvars", "tofu", "tftest": return .hcl
        case "yaml", "yml": return .yaml
        case "json", "tfstate": return .json
        default: return name == ".terraform.lock.hcl" ? .hcl : .plain
        }
    }

    static func tokens(_ text: String, language: Language) -> [Token] {
        let units = Array(text.utf16)
        switch language {
        case .hcl:
            var scanner = HCL(units: units)
            scanner.code(from: 0, until: nil)
            return scanner.tokens
        case .yaml: return yaml(units)
        case .json: return json(units)
        case .plain: return []
        }
    }

    /// UTF-16 offsets where each line starts.
    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        for (i, unit) in text.utf16.enumerated() where unit == 10 { starts.append(i + 1) }
        return starts
    }

    /// The last line (1-based) of the block that opens on `line`: the line of
    /// the brace that closes the first one opened there. `line` itself when
    /// nothing opens.
    static func blockEnd(_ text: String, line: Int, language: Language = .hcl) -> Int {
        let units = Array(text.utf16)
        let starts = lineStarts(text)
        guard line >= 1, line <= starts.count else { return line }
        let skip = tokens(text, language: language).filter { $0.kind == .comment || $0.kind == .string }
        var next = 0 // the first token that may still cover i
        var depth = 0
        var current = line
        var i = starts[line - 1]
        while i < units.count {
            while next < skip.count, NSMaxRange(skip[next].range) <= i { next += 1 }
            if next < skip.count, skip[next].range.location <= i {
                // Inside a string or a comment: count its lines, not its braces.
                let end = NSMaxRange(skip[next].range)
                while i < end { if units[i] == 10 { current += 1 }; i += 1 }
                continue
            }
            switch units[i] {
            case 10:
                if depth == 0 { return line }
                current += 1
            case 123: depth += 1 // {
            case 125: // }
                depth -= 1
                if depth <= 0 { return current }
            default: break
            }
            i += 1
        }
        return current
    }

    // MARK: HCL

    private static let blocks: Set<String> = [
        "resource", "data", "module", "variable", "output", "locals", "provider", "terraform", "moved", "import", "check",
        "removed", "include", "dependency", "dependencies", "generate", "remote_state", "dynamic", "lifecycle", "backend",
        "required_providers", "provisioner", "connection", "content", "validation", "precondition", "postcondition", "unit",
        "stack", "feature", "exclude", "errors", "catalog", "mock_provider", "run", "assert", "ephemeral",
    ]
    private static let roots: Set<String> = ["var", "local", "module", "data", "each", "count", "path", "terraform", "self", "dependency", "include"]
    private static let words: Set<String> = ["for", "in", "if", "else", "endif", "endfor"]
    private static let constants: Set<String> = ["true", "false", "null"]

    private struct HCL {
        let units: [UInt16]
        var tokens: [Token] = []

        private func isIdentStart(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 }
        private func isIdent(_ u: UInt16) -> Bool { isIdentStart(u) || (u >= 48 && u <= 57) || u == 45 }
        private func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }

        private mutating func add(_ from: Int, _ to: Int, _ kind: Kind) {
            if to > from { tokens.append(Token(range: NSRange(location: from, length: to - from), kind: kind)) }
        }

        /// Code from `start`; returns where it stopped. With `until`, stops
        /// after the brace that closes the interpolation it is in.
        @discardableResult
        mutating func code(from start: Int, until closing: UInt16?) -> Int {
            var i = start
            var depth = 0
            var lineHasToken = false // something other than spaces came before on this line
            while i < units.count {
                let u = units[i]
                if u == 10 { lineHasToken = false; i += 1; continue }
                if u == 32 || u == 9 || u == 13 { i += 1; continue }
                let first = !lineHasToken
                lineHasToken = true
                if u == 35 || (u == 47 && i + 1 < units.count && units[i + 1] == 47) { // # or //
                    var j = i
                    while j < units.count, units[j] != 10 { j += 1 }
                    add(i, j, .comment); i = j
                } else if u == 47, i + 1 < units.count, units[i + 1] == 42 { // /*
                    var j = i + 2
                    while j + 1 < units.count, !(units[j] == 42 && units[j + 1] == 47) { j += 1 }
                    j = min(units.count, j + 2)
                    add(i, j, .comment); i = j
                } else if u == 34 { // "
                    i = string(from: i)
                } else if u == 60, i + 1 < units.count, units[i + 1] == 60 { // <<EOF
                    i = heredoc(from: i)
                } else if isDigit(u) {
                    var j = i
                    while j < units.count, isDigit(units[j]) || units[j] == 46 || units[j] == 120 || (units[j] >= 97 && units[j] <= 102)
                        || (units[j] >= 65 && units[j] <= 70) { j += 1 }
                    add(i, j, .number); i = j
                } else if isIdentStart(u) {
                    var j = i
                    while j < units.count, isIdent(units[j]) { j += 1 }
                    let word = String(utf16CodeUnits: Array(units[i..<j]), count: j - i)
                    var k = j
                    while k < units.count, units[k] == 32 || units[k] == 9 { k += 1 }
                    let after: UInt16 = k < units.count ? units[k] : 0
                    let afterNext: UInt16 = k + 1 < units.count ? units[k + 1] : 0
                    if first, Syntax.blocks.contains(word), after == 34 || after == 123 || isIdentStart(after) {
                        add(i, j, .keyword)
                    } else if first, after == 61, afterNext != 61 { // name =
                        add(i, j, .attribute)
                    } else if Syntax.constants.contains(word) {
                        add(i, j, .constant)
                    } else if Syntax.words.contains(word) {
                        add(i, j, .keyword)
                    } else if j < units.count, units[j] == 40 { // name(
                        add(i, j, .function)
                    } else if Syntax.roots.contains(word), j < units.count, units[j] == 46 {
                        add(i, j, .reference)
                    }
                    i = j
                } else if u == 123 {
                    depth += 1; i += 1
                } else if u == 125 {
                    if closing != nil, depth == 0 { return i + 1 }
                    depth -= 1; i += 1
                } else {
                    i += 1
                }
            }
            return i
        }

        /// A quoted string from its opening quote; `${…}` inside is code.
        private mutating func string(from start: Int) -> Int {
            var i = start + 1
            var piece = start
            while i < units.count {
                let u = units[i]
                if u == 92 { i += 2; continue } // backslash
                if u == 34 { add(piece, i + 1, .string); return i + 1 }
                if u == 10 { add(piece, i, .string); return i } // unterminated: stop at the line's end
                if (u == 36 || u == 37), i + 1 < units.count, units[i + 1] == 123 { // ${ or %{
                    if i > 0, units[i - 1] == u { i += 2; continue } // $${ is literal
                    add(piece, i, .string)
                    add(i, i + 2, .punctuation)
                    let end = code(from: i + 2, until: 125)
                    add(max(i + 2, end - 1), end, .punctuation)
                    i = end; piece = end
                    continue
                }
                i += 1
            }
            add(piece, units.count, .string)
            return units.count
        }

        private mutating func heredoc(from start: Int) -> Int {
            var i = start + 2
            if i < units.count, units[i] == 45 { i += 1 } // <<-
            let nameStart = i
            while i < units.count, isIdent(units[i]) { i += 1 }
            guard i > nameStart else { return start + 2 }
            let marker = Array(units[nameStart..<i])
            // Lines until one that holds only the marker.
            var lineStart = i
            while lineStart < units.count, units[lineStart] != 10 { lineStart += 1 }
            var j = lineStart + 1
            while j < units.count {
                var end = j
                while end < units.count, units[end] != 10 { end += 1 }
                let line = units[j..<end].filter { $0 != 32 && $0 != 9 && $0 != 13 }
                if Array(line) == marker { add(start, end, .string); return end }
                j = end + 1
            }
            add(start, units.count, .string)
            return units.count
        }
    }

    // MARK: YAML

    private static func yaml(_ units: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < units.count {
            var end = i
            while end < units.count, units[end] != 10 { end += 1 }
            var j = i
            while j < end, units[j] == 32 || units[j] == 45 { j += 1 } // indent and "- "
            // A key: up to a colon followed by a space or the line's end.
            var k = j
            var key: Int?
            if j < end, units[j] != 35, units[j] != 34, units[j] != 39 {
                while k < end {
                    if units[k] == 58, k + 1 == end || units[k + 1] == 32 { key = k; break }
                    if units[k] == 35 || units[k] == 34 || units[k] == 39 { break }
                    k += 1
                }
            }
            var p = j
            if let key {
                tokens.append(Token(range: NSRange(location: j, length: key - j), kind: .attribute))
                p = key + 1
            }
            while p < end {
                let u = units[p]
                if u == 35, p == j || units[p - 1] == 32 { // comment
                    tokens.append(Token(range: NSRange(location: p, length: end - p), kind: .comment)); break
                } else if u == 34 || u == 39 {
                    var q = p + 1
                    while q < end, units[q] != u { if units[q] == 92 { q += 1 }; q += 1 }
                    q = min(end, q + 1)
                    tokens.append(Token(range: NSRange(location: p, length: q - p), kind: .string)); p = q
                } else if u == 36, p + 2 < end, units[p + 1] == 123, units[p + 2] == 123 { // ${{ … }}
                    var q = p + 3
                    while q + 1 < end, !(units[q] == 125 && units[q + 1] == 125) { q += 1 }
                    q = min(end, q + 2)
                    tokens.append(Token(range: NSRange(location: p, length: q - p), kind: .reference)); p = q
                } else if u >= 48, u <= 57, p == 0 || units[p - 1] == 32 {
                    var q = p
                    while q < end, (units[q] >= 48 && units[q] <= 57) || units[q] == 46 { q += 1 }
                    if q == end || units[q] == 32 { tokens.append(Token(range: NSRange(location: p, length: q - p), kind: .number)) }
                    p = max(q, p + 1)
                } else {
                    p += 1
                }
            }
            i = end + 1
        }
        return tokens
    }

    // MARK: JSON

    private static func json(_ units: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < units.count {
            let u = units[i]
            if u == 34 {
                var j = i + 1
                while j < units.count, units[j] != 34, units[j] != 10 { if units[j] == 92 { j += 1 }; j += 1 }
                j = min(units.count, j + 1)
                var k = j
                while k < units.count, units[k] == 32 { k += 1 }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: k < units.count && units[k] == 58 ? .attribute : .string))
                i = j
            } else if (u >= 48 && u <= 57) || u == 45 {
                var j = i + 1
                while j < units.count, (units[j] >= 48 && units[j] <= 57) || units[j] == 46 || units[j] == 101 || units[j] == 69 { j += 1 }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .number)); i = j
            } else if u == 116 || u == 102 || u == 110 { // true false null
                var j = i
                while j < units.count, units[j] >= 97, units[j] <= 122 { j += 1 }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .constant)); i = j
            } else {
                i += 1
            }
        }
        return tokens
    }
}
