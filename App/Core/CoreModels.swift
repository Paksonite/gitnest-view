import Foundation

/// A local repository as the engine reports it (`repos.scan`, `repos.status`).
struct Repo: Codable, Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var branch: String
    var detached: Bool
    var hasUpstream: Bool
    var upstreamGone: Bool
    var ahead: Int
    var behind: Int
    var changes: Int
    var conflicts: Bool
    var stashes: Int
    /// Empty, or an operation in progress: "merging", "rebasing", …
    var state: String
    var lastCommit: Int
    var lastUsed: Int
    var remote: Remote

    var id: String { path }

    /// Where the repository lives on a forge; nil for local-only repositories
    /// and remotes that are not host/owner/repo.
    var slug: RepoSlug? {
        guard !remote.host.isEmpty, !remote.owner.isEmpty, !remote.repo.isEmpty else { return nil }
        return RepoSlug(host: remote.host, owner: remote.owner, name: remote.repo)
    }
}

struct Remote: Codable, Hashable, Sendable {
    var url: String
    var host: String
    var owner: String
    var repo: String
    var web: String
}

struct RepoSlug: Hashable, Sendable {
    var host: String
    var owner: String
    var name: String

    /// Hosts and names compare without case, as forges treat them.
    var key: String { "\(host)/\(owner)/\(name)".lowercased() }
}

struct ScanResult: Decodable, Sendable {
    var repos: [Repo]
}

struct CoreInfo: Decodable, Sendable {
    var version: String
    var git: String
    var gitError: String
    var config: String
}

struct HeadCommit: Decodable, Sendable {
    var sha: String
    var subject: String?
}

struct ScanParams: Encodable, Sendable {
    var roots: [String]
    var full = false
}

/// An access token for git over HTTPS, passed to the engine for one call.
struct GitAuth: Encodable, Sendable {
    var host: String
    var user: String
    var token: String
}

struct RepoParams: Encodable, Sendable {
    var path: String
    var auth: GitAuth?
}

struct CloneParams: Encodable, Sendable {
    var url: String
    var dest: String
    var auth: GitAuth?
}

struct CheckoutParams: Encodable, Sendable {
    var path: String
    var name: String
    var remote: Bool
}

struct LogParams: Encodable, Sendable {
    var path: String
    var limit: Int
}

struct LocalBranch: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    var upstream: String
    var current: Bool
    var remote: Bool
    var ahead: Int
    var behind: Int
    var gone: Bool
    var updated: String
    var subject: String

    var id: String { (remote ? "r:" : "l:") + name }
}

struct BranchList: Decodable, Sendable {
    var local: [LocalBranch]
    var remote: [LocalBranch]
}

struct ChangedFile: Decodable, Identifiable, Hashable, Sendable {
    var path: String
    var orig: String
    var staged: Bool
    var unstaged: Bool
    var untracked: Bool
    var conflict: Bool
    var code: String

    var id: String { path }
}

struct ChangedFiles: Decodable, Sendable {
    var files: [ChangedFile]
}

struct LocalCommit: Decodable, Identifiable, Hashable, Sendable {
    var sha: String
    var short: String
    var author: String
    var when: String
    var subject: String
    var refs: String

    var id: String { sha }
}

struct CommitList: Decodable, Sendable {
    var commits: [LocalCommit]
}

struct PathsParams: Encodable, Sendable {
    var paths: [String]
}

struct PathParams: Encodable, Sendable {
    var path: String
}

struct WorkflowParseParams: Encodable, Sendable {
    var content: String
}

// MARK: - Local work (Changes, History)

struct FileDiff: Decodable, Hashable, Sendable {
    struct Line: Decodable, Hashable, Sendable {
        var kind: String // "+", "-", " " or "\\"
        var text: String
        var old: Int
        var new: Int

        var isChange: Bool { kind == "+" || kind == "-" }
    }

    struct Hunk: Decodable, Hashable, Sendable {
        var header: String
        var lines: [Line]?

        var rows: [Line] { lines ?? [] }
    }

    var path: String
    var staged: Bool
    var hunks: [Hunk]
    var binary: Bool
    var truncated: Bool
    var digest: String
}

/// One line of a diff, by position, as the engine's line staging takes it.
struct LineRef: Codable, Hashable, Sendable {
    var Hunk: Int
    var Line: Int
}

struct FileRef: Encodable, Sendable {
    var path: String
    var orig: String
    var untracked: Bool
    var code: String

    init(_ file: ChangedFile) {
        path = file.path
        orig = file.orig
        untracked = file.untracked
        code = file.code
    }
}

struct BehindBranch: Decodable, Identifiable, Hashable, Sendable {
    var path: String
    var branch: String
    var current: Bool
    var behind: Int
    var ahead: Int
    var ok: Bool
    var note: String

    var id: String { path + "\u{1F}" + branch }
}

struct RepoResult: Decodable, Hashable, Sendable {
    var path: String
    var error: String?
}

struct FetchAllResult: Decodable, Sendable {
    var results: [RepoResult]
    var rows: [BehindBranch]
}

struct FastForwardResult: Decodable, Sendable {
    struct Item: Decodable, Hashable, Sendable {
        var path: String
        var branch: String
        var error: String?
    }
    var results: [Item]
}

struct Stash: Decodable, Identifiable, Hashable, Sendable {
    var ref: String
    var message: String
    var when: String
    var id: String { ref }
}

struct StashList: Decodable, Sendable {
    var stashes: [Stash]
}

struct HistoryCommit: Decodable, Identifiable, Hashable, Sendable {
    var sha: String
    var short: String
    var author: String
    var when: String
    var subject: String
    var refs: String
    var parents: [String]
    var merge: Bool
    var unpushed: Bool
    var id: String { sha }
}

struct History: Decodable, Sendable {
    var commits: [HistoryCommit]
    var undo: String
}

struct RewriteResult: Decodable, Sendable {
    var needsConfirm: Bool?
    var remotes: [String]?
}

struct TextResult: Decodable, Sendable {
    var text: String
}

struct MessageResult: Decodable, Sendable {
    var message: String
}

struct ActivityCommit: Decodable, Hashable, Sendable {
    var path: String
    var unix: Int
    var short: String
    var author: String
    var subject: String
}

struct ActivityResult: Decodable, Sendable {
    var commits: [ActivityCommit]
}

/// A declaration of the Terraform configuration (`repo.resources`).
struct TFItem: Decodable, Identifiable, Hashable, Sendable {
    var kind: String // resource, data, module, unit
    var type: String
    var name: String
    var file: String
    var line: Int
    var source: String
    var many: Bool
    var address: String
    var id: String { "\(file):\(line):\(address)" }
}

struct TFItems: Decodable, Sendable {
    var items: [TFItem]
}

struct GitTag: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    var short: String
    var subject: String
    var when: String
    var annotated: Bool
    var id: String { name }
}

struct TagList: Decodable, Sendable {
    var tags: [GitTag]
}

struct GrepMatch: Decodable, Hashable, Sendable {
    var file: String
    var line: Int
    var text: String
}

struct GrepHit: Decodable, Identifiable, Hashable, Sendable {
    var path: String
    var matches: [GrepMatch]
    var error: String?
    var id: String { path }
}

struct GrepResult: Decodable, Sendable {
    var results: [GrepHit]
}

struct ModuleUse: Decodable, Hashable, Sendable {
    var path: String
    var item: TFItem.Raw
}

struct ModuleUses: Decodable, Sendable {
    var uses: [ModuleUse]
}

extension TFItem {
    /// An item as `repos.modules` sends it (no address field).
    struct Raw: Decodable, Hashable, Sendable {
        var kind: String
        var type: String
        var name: String
        var file: String
        var line: Int
        var source: String
        var many: Bool
    }
}
