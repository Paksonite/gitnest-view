import Foundation

/// What a Terraform or OpenTofu plan (or apply) printed, read from a job's log.
struct TerraformPlan: Hashable, Sendable {
    enum Action: String, Sendable { case create, update, destroy, replace, read }

    struct Change: Hashable, Sendable {
        var action: Action
        var address: String
    }

    var add = 0
    var change = 0
    var destroy = 0
    /// True for the result of an apply ("Apply complete!"), false for a plan.
    var applied = false
    var changes: [Change] = []

    var isEmpty: Bool { add == 0 && change == 0 && destroy == 0 }

    /// The last plan or apply summary in the log, with the resources listed
    /// before it. Nil when the log has no Terraform summary.
    static func parse(_ lines: [LogLine]) -> TerraformPlan? {
        var found: TerraformPlan?
        var changes: [Change] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("# "), let change = Self.change(text) {
                if !changes.contains(change) { changes.append(change) }
            } else if let numbers = numbers(text, prefix: "Plan:", words: ["to add", "to change", "to destroy"]) {
                found = TerraformPlan(add: numbers[0], change: numbers[1], destroy: numbers[2], applied: false, changes: changes)
            } else if let numbers = numbers(text, prefix: "Apply complete! Resources:", words: ["added", "changed", "destroyed"]) {
                found = TerraformPlan(add: numbers[0], change: numbers[1], destroy: numbers[2], applied: true, changes: changes)
            } else if text.hasPrefix("No changes.") {
                found = TerraformPlan(changes: [])
            }
        }
        return found
    }

    /// "# module.dns.google_dns_record_set.a will be created"
    static func change(_ text: String) -> Change? {
        let endings: [(String, Action)] = [
            (" will be created", .create), (" will be updated in-place", .update),
            (" will be destroyed", .destroy), (" must be replaced", .replace),
            (" will be replaced", .replace), (" will be read during apply", .read),
        ]
        for (ending, action) in endings {
            guard let range = text.range(of: ending) else { continue }
            let address = text[text.index(text.startIndex, offsetBy: 2)..<range.lowerBound]
            guard !address.isEmpty, !address.contains(" ") else { continue }
            return Change(action: action, address: String(address))
        }
        return nil
    }

    /// The numbers before each of `words` in "Plan: 1 to add, 0 to change, 0 to destroy."
    private static func numbers(_ text: String, prefix: String, words: [String]) -> [Int]? {
        guard let start = text.range(of: prefix) else { return nil }
        let parts = text[start.upperBound...].split(separator: ",")
        guard parts.count >= words.count else { return nil }
        var out: [Int] = []
        for (part, word) in zip(parts, words) {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard piece.contains(word), let number = Int(piece.prefix { $0.isNumber }) else { return nil }
            out.append(number)
        }
        return out
    }
}

extension TerraformPlan.Action {
    /// The sign Terraform itself prints for the action.
    var sign: String {
        switch self {
        case .create: "+"
        case .update: "~"
        case .destroy: "-"
        case .replace: "-/+"
        case .read: "<="
        }
    }
}

/// Shortens a Terraform or OpenTofu log for reading: every resource block,
/// which lists all the attributes, becomes one line such as
/// `+ create  module.x.google_dns_record_set.a["b"]`. Everything else
/// (the init, the plan's totals, errors) stays as it is.
enum TerraformLog {
    static func condense(_ lines: [LogLine]) -> [LogLine] {
        var out: [LogLine] = []
        out.reserveCapacity(lines.count)
        var inBlock = false
        var opened = false
        var depth = 0
        var skipped = 0

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            // The blank line Terraform puts after each block would leave the
            // one-line summaries double spaced.
            if text.isEmpty, !inBlock, out.last?.action != nil { continue }
            if text.hasPrefix("# "), let change = TerraformPlan.change(text) {
                out.append(LogLine(time: line.time, text: "\(change.action.sign) \(change.action.rawValue)  \(change.address)", action: change.action))
                inBlock = true
                opened = false
                depth = 0
                skipped = 0
                continue
            }
            guard inBlock else {
                out.append(line)
                continue
            }
            skipped += 1
            if !opened {
                // Between the heading and the block: notes like
                // "# (because … is not in configuration)" and blank lines.
                if text.isEmpty || text.hasPrefix("#") { continue }
                if text.hasSuffix("{") {
                    opened = true
                    depth = 1
                    continue
                }
                // Not a block after all: show the line.
                inBlock = false
                out.append(line)
                continue
            }
            if text.hasSuffix("{") {
                depth += 1
            } else if text == "}" || text.hasPrefix("} ") {
                depth -= 1
                if depth <= 0 { inBlock = false }
            } else if text.hasPrefix("Plan:") || text.hasPrefix("Apply complete!") || text.hasPrefix("Error:") || skipped > 20000 {
                // The block never closed (cut output): never hide the result.
                inBlock = false
                out.append(line)
            }
        }
        return out
    }

    /// True when the log has resource blocks to shorten.
    static func hasResources(_ lines: [LogLine]) -> Bool {
        lines.contains { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("# ") && TerraformPlan.change(text) != nil
        }
    }
}

/// What Terraform or OpenTofu said when it failed: the error boxes
/// ("│ Error: …"), at most a few lines each, without the box drawing.
enum TerraformError {
    static func extract(_ lines: [LogLine], maxLines: Int = 14) -> [String] {
        var out: [String] = []
        var inBox = false
        for line in lines {
            var text = line.text
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("╷") { inBox = true; continue }
            if trimmed.hasPrefix("╵") {
                if inBox && out.last != "" { out.append("") }
                inBox = false
                continue
            }
            if trimmed.hasPrefix("│") {
                text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if inBox || text.hasPrefix("Error:") { out.append(text) }
            } else if trimmed.hasPrefix("Error:") {
                out.append(trimmed)
            }
            if out.count >= maxLines { break }
        }
        while out.last == "" { out.removeLast() }
        // Lines that only repeat the box frame's emptiness add nothing.
        var compact: [String] = []
        for line in out where !(line.isEmpty && compact.last?.isEmpty == true) { compact.append(line) }
        return compact
    }
}
