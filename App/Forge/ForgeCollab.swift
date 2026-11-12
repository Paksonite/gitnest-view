import Foundation

// What people say and decide on a pull request, and the smaller parts of a
// forge around it: notifications, releases, the variables of Actions.

/// A comment in a pull request's conversation.
struct IssueComment: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var user: ForgeUser?
    var body: String
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case createdAt = "created_at"
    }
}

/// A comment on a line of a pull request's changes, made in a review.
struct ReviewComment: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var user: ForgeUser?
    var body: String
    var path: String?
    var position: Int?
    var originalPosition: Int?
    var diffHunk: String?
    var createdAt: Date?
    var resolver: ForgeUser?

    enum CodingKeys: String, CodingKey {
        case id, user, body, path, position, resolver
        case originalPosition = "original_position"
        case diffHunk = "diff_hunk"
        case createdAt = "created_at"
    }

    /// The last lines of the hunk the comment is about.
    var context: [String] {
        Array((diffHunk ?? "").split(separator: "\n", omittingEmptySubsequences: false).suffix(4)).map(String.init)
    }
}

struct ForgeLabel: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var color: String?
}

/// One thing the server wants the user to know: a mention, a comment, a
/// review request, a state change.
struct ForgeNotification: Decodable, Identifiable, Hashable, Sendable {
    struct Subject: Decodable, Hashable, Sendable {
        var title: String
        var type: String? // Pull, Issue, Commit, Repository
        var state: String?
        var htmlURL: String?
        var url: String?

        enum CodingKeys: String, CodingKey {
            case title, type, state, url
            case htmlURL = "html_url"
        }
    }

    struct Repository: Decodable, Hashable, Sendable {
        var fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    var id: Int
    var unread: Bool?
    var subject: Subject
    var repository: Repository?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, unread, subject, repository
        case updatedAt = "updated_at"
    }

    /// The pull request or issue number the notification is about.
    var number: Int? {
        (subject.htmlURL ?? subject.url).flatMap { $0.split(separator: "/").last }.flatMap { Int($0.split(separator: "#").first ?? "") }
    }
}

struct ForgeRelease: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var tagName: String
    var name: String?
    var draft: Bool?
    var prerelease: Bool?
    var htmlURL: String?
    var publishedAt: Date?
    var author: ForgeUser?

    enum CodingKeys: String, CodingKey {
        case id, name, draft, prerelease, author
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

struct ActionVariable: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    var data: String?
    var id: String { name }
}

struct ActionSecret: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    var id: String { name }
}

extension ForgejoClient {
    private func issue(_ repo: RepoSlug, _ number: Int) -> String { "repos/\(repo.owner)/\(repo.name)/issues/\(number)" }
    private func pull(_ repo: RepoSlug, _ number: Int) -> String { "repos/\(repo.owner)/\(repo.name)/pulls/\(number)" }

    // MARK: Conversation

    func comments(_ repo: RepoSlug, number: Int) async throws -> [IssueComment] {
        try await get(issue(repo, number) + "/comments")
    }

    func comment(_ repo: RepoSlug, number: Int, body: String) async throws {
        struct Body: Encodable { var body: String }
        try await send("POST", issue(repo, number) + "/comments", body: Body(body: body))
    }

    func reviewComments(_ repo: RepoSlug, number: Int, review: Int) async throws -> [ReviewComment] {
        try await get(pull(repo, number) + "/reviews/\(review)/comments")
    }

    // MARK: People and labels

    /// The accounts that can be asked to review in this repository.
    func reviewers(_ repo: RepoSlug) async throws -> [ForgeUser] {
        try await get("repos/\(repo.owner)/\(repo.name)/reviewers")
    }

    func assignees(_ repo: RepoSlug) async throws -> [ForgeUser] {
        try await get("repos/\(repo.owner)/\(repo.name)/assignees")
    }

    func requestReview(_ repo: RepoSlug, number: Int, from logins: [String], withdraw: Bool = false) async throws {
        struct Body: Encodable { var reviewers: [String] }
        try await send(withdraw ? "DELETE" : "POST", pull(repo, number) + "/requested_reviewers", body: Body(reviewers: logins))
    }

    func labels(_ repo: RepoSlug) async throws -> [ForgeLabel] {
        try await pages("repos/\(repo.owner)/\(repo.name)/labels", maxPages: 4)
    }

    func setLabels(_ repo: RepoSlug, number: Int, ids: [Int]) async throws {
        struct Body: Encodable { var labels: [Int] }
        try await send("PUT", issue(repo, number) + "/labels", body: Body(labels: ids))
    }

    // MARK: The pull request itself

    /// Changes what is given; nil leaves a part as it is.
    func editPull(_ repo: RepoSlug, number: Int, title: String? = nil, body: String? = nil, state: String? = nil, assignees: [String]? = nil) async throws {
        struct Body: Encodable {
            var title: String?
            var body: String?
            var state: String?
            var assignees: [String]?
        }
        try await send("PATCH", pull(repo, number), body: Body(title: title, body: body, state: state, assignees: assignees))
    }

    /// Brings the base branch's new commits into the pull request's branch,
    /// by a merge commit or by rebasing it ("merge" / "rebase").
    func updateBranch(_ repo: RepoSlug, number: Int, style: String) async throws {
        var request = try request(pull(repo, number) + "/update", query: [.init(name: "style", value: style)])
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request, delegate: AuthGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw ForgeError.notAnswer }
        guard (200..<300).contains(http.statusCode) else {
            struct Message: Decodable { var message: String? }
            if let message = (try? JSONDecoder().decode(Message.self, from: data))?.message, !message.isEmpty { throw ForgeError.rejected(message) }
            throw ForgeError.http(http.statusCode)
        }
    }

    // MARK: Around the pull requests

    func notifications() async throws -> [ForgeNotification] {
        try await get("notifications", query: [.init(name: "page", value: "1"), .init(name: "limit", value: "30")])
    }

    func markRead(notification id: Int) async throws {
        try await send("PATCH", "notifications/threads/\(id)")
    }

    func releases(_ repo: RepoSlug) async throws -> [ForgeRelease] {
        try await get("repos/\(repo.owner)/\(repo.name)/releases", query: [.init(name: "page", value: "1"), .init(name: "limit", value: "20")])
    }

    func actionVariables(_ repo: RepoSlug) async throws -> [ActionVariable] {
        try await get("repos/\(repo.owner)/\(repo.name)/actions/variables")
    }

    func actionSecrets(_ repo: RepoSlug) async throws -> [ActionSecret] {
        try await get("repos/\(repo.owner)/\(repo.name)/actions/secrets")
    }
}
