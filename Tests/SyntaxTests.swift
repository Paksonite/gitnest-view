import XCTest
@testable import GitNestView

final class SyntaxTests: XCTestCase {
    private func kinds(_ text: String, _ language: Syntax.Language = .hcl) -> [(String, Syntax.Kind)] {
        let ns = text as NSString
        return Syntax.tokens(text, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func has(_ tokens: [(String, Syntax.Kind)], _ text: String, _ kind: Syntax.Kind) -> Bool {
        tokens.contains { $0.0 == text && $0.1 == kind }
    }

    func testBlocksAttributesAndStrings() {
        let tokens = kinds("""
        resource "google_dns_managed_zone" "zone" {
          name = "zone-${each.key}" # the name
          ttl  = 300
          on   = true
        }
        """)
        XCTAssertTrue(has(tokens, "resource", .keyword))
        XCTAssertTrue(has(tokens, "\"google_dns_managed_zone\"", .string))
        XCTAssertTrue(has(tokens, "name", .attribute))
        XCTAssertTrue(has(tokens, "\"zone-", .string))
        XCTAssertTrue(has(tokens, "each", .reference), "code inside ${…} is code, not string")
        XCTAssertTrue(has(tokens, "# the name", .comment))
        XCTAssertTrue(has(tokens, "300", .number))
        XCTAssertTrue(has(tokens, "true", .constant))
    }

    func testHashInsideAStringIsNotAComment() {
        let tokens = kinds("url = \"https://example.test/#anchor\" // real")
        XCTAssertTrue(has(tokens, "\"https://example.test/#anchor\"", .string))
        XCTAssertTrue(has(tokens, "// real", .comment))
        XCTAssertEqual(tokens.filter { $0.1 == .comment }.count, 1)
    }

    func testHeredocAndBlockComment() {
        let tokens = kinds("""
        text = <<-EOT
          a { brace
          EOT
        /* two
           lines */
        x = upper(var.name)
        """)
        XCTAssertTrue(tokens.contains { $0.1 == .string && $0.0.hasPrefix("<<-EOT") && $0.0.hasSuffix("EOT") })
        XCTAssertTrue(tokens.contains { $0.1 == .comment && $0.0.hasPrefix("/* two") && $0.0.hasSuffix("*/") })
        XCTAssertTrue(has(tokens, "upper", .function))
        XCTAssertTrue(has(tokens, "var", .reference))
    }

    func testUnfinishedInputDoesNotCrash() {
        for text in ["\"open", "x = \"${var.", "<<EOT\nnever closed", "/* never closed", "resource \"a\" \"b\" {", "", "}}}}", "a = \"\\"] {
            _ = Syntax.tokens(text, language: .hcl)
            _ = Syntax.blockEnd(text, line: 1)
        }
        _ = Syntax.tokens("key: \"open", language: .yaml)
        _ = Syntax.tokens("{\"a\": \"open", language: .json)
    }

    func testNonAsciiKeepsOffsets() {
        let text = "# zażółć 🌍\nname = \"ö\"\n"
        let ns = text as NSString
        for token in Syntax.tokens(text, language: .hcl) {
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), ns.length)
        }
        XCTAssertTrue(has(kinds(text), "name", .attribute))
    }

    func testBlockEnd() {
        let text = """
        locals { a = 1 }
        resource "x" "y" {
          text = "} not the end"
          # } neither
          nested {
            b = 2
          }
        }
        output "z" { value = 1 }
        """
        XCTAssertEqual(Syntax.blockEnd(text, line: 1), 1)
        XCTAssertEqual(Syntax.blockEnd(text, line: 2), 8)
        XCTAssertEqual(Syntax.blockEnd(text, line: 5), 7)
        XCTAssertEqual(Syntax.blockEnd(text, line: 3), 3, "a line that opens nothing is its own block")
        XCTAssertEqual(Syntax.blockEnd(text, line: 99), 99)
    }

    func testYamlAndJson() {
        let yaml = kinds("name: build # ci\non:\n  - push\nrun: \"echo ${{ secrets.X }}\"\n", .yaml)
        XCTAssertTrue(has(yaml, "name", .attribute))
        XCTAssertTrue(has(yaml, "# ci", .comment))
        XCTAssertTrue(yaml.contains { $0.1 == .string })
        let json = kinds("{\"a\": \"b\", \"n\": 12, \"t\": true}", .json)
        XCTAssertTrue(has(json, "\"a\"", .attribute))
        XCTAssertTrue(has(json, "\"b\"", .string))
        XCTAssertTrue(has(json, "12", .number))
        XCTAssertTrue(has(json, "true", .constant))
    }

    func testLanguageByName() {
        XCTAssertEqual(Syntax.language(of: "a/b/main.tf"), .hcl)
        XCTAssertEqual(Syntax.language(of: "terragrunt.hcl"), .hcl)
        XCTAssertEqual(Syntax.language(of: "prod.tfvars"), .hcl)
        XCTAssertEqual(Syntax.language(of: ".forgejo/workflows/ci.yaml"), .yaml)
        XCTAssertEqual(Syntax.language(of: "README.md"), .plain)
    }

    func testFileReaderListsAndRefuses() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gnv-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "env/prod"), withIntermediateDirectories: true)
        try "x".write(to: root.appending(path: ".git/config.json"), atomically: true, encoding: .utf8)
        try "a = 1".write(to: root.appending(path: "env/prod/main.tf"), atomically: true, encoding: .utf8)
        try "# hi".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: root.appending(path: "blob.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(FileReader.list(root.path), ["env/prod/main.tf", "blob.json", "README.md"])
        if case .failure = FileReader.read(root.appending(path: "blob.json").path) {} else { XCTFail("binary must be refused") }
        if case .failure = FileReader.read(root.appending(path: "missing.tf").path) {} else { XCTFail("missing must be refused") }
        XCTAssertEqual(try FileReader.read(root.appending(path: "env/prod/main.tf").path).get(), "a = 1")
    }
}
