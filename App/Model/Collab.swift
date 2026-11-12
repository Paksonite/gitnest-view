import Foundation

/// A server's notification with the server it came from.
struct HostNotification: Identifiable, Hashable, Sendable {
    var host: String
    var item: ForgeNotification
    var id: String { "\(host)#\(item.id)" }
}

// What the user does on a pull request besides reading it: talk, ask for
// reviews, label, keep its branch current, edit, close.
extension AppModel {
    private func target(_ repo: ForgeRepo) -> (RepoSlug, ForgejoClient)? {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return nil }
        return (slug, client)
    }

    /// Runs a change on the server, says what happened, and reads the pull
    /// request again. Returns false when the server refused.
    @discardableResult
    private func change(_ repo: ForgeRepo, _ pull: PullRequest, done: String, _ work: (RepoSlug, ForgejoClient) async throws -> Void) async -> Bool {
        guard let (slug, client) = target(repo) else { return false }
        do {
            try await work(slug, client)
            toast(done)
            await refreshForge(repo, detailed: true)
            if let fresh = forgeState(repo).pulls.first(where: { $0.number == pull.number }) { await loadExtras(fresh, in: repo) }
            return true
        } catch {
            toast(error.localizedDescription, .error)
            return false
        }
    }

    @discardableResult
    func comment(on pull: PullRequest, in repo: ForgeRepo, text: String) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        return await change(repo, pull, done: "Commented on #\(pull.number)") { slug, client in
            try await client.comment(slug, number: pull.number, body: body)
        }
    }

    /// The accounts that can review here, without the author.
    func reviewerCandidates(_ pull: PullRequest, in repo: ForgeRepo) async -> [ForgeUser] {
        guard let (slug, client) = target(repo) else { return [] }
        let all = (try? await client.reviewers(slug)) ?? []
        return all.filter { $0.login != pull.user?.login }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func assigneeCandidates(in repo: ForgeRepo) async -> [ForgeUser] {
        guard let (slug, client) = target(repo) else { return [] }
        return ((try? await client.assignees(slug)) ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func repoLabels(in repo: ForgeRepo) async -> [ForgeLabel] {
        guard let (slug, client) = target(repo) else { return [] }
        return (try? await client.labels(slug)) ?? []
    }

    /// Asks someone for a review, or takes the request back.
    func requestReview(of pull: PullRequest, in repo: ForgeRepo, from user: ForgeUser, withdraw: Bool = false) async {
        await change(repo, pull, done: withdraw ? "Took back the request to \(user.displayName)" : "Asked \(user.displayName) for a review") { slug, client in
            try await client.requestReview(slug, number: pull.number, from: [user.login], withdraw: withdraw)
        }
    }

    func setLabels(_ ids: [Int], on pull: PullRequest, in repo: ForgeRepo) async {
        await change(repo, pull, done: "Labels of #\(pull.number) changed") { slug, client in
            try await client.setLabels(slug, number: pull.number, ids: ids)
        }
    }

    func setAssignees(_ logins: [String], on pull: PullRequest, in repo: ForgeRepo) async {
        await change(repo, pull, done: logins.isEmpty ? "Nobody is assigned to #\(pull.number)" : "Assigned #\(pull.number)") { slug, client in
            try await client.editPull(slug, number: pull.number, assignees: logins)
        }
    }

    @discardableResult
    func edit(_ pull: PullRequest, in repo: ForgeRepo, title: String, body: String) async -> Bool {
        await change(repo, pull, done: "Saved #\(pull.number)") { slug, client in
            try await client.editPull(slug, number: pull.number, title: title, body: body)
        }
    }

    /// Forgejo marks work in progress by the title: "WIP: …" cannot be merged.
    static func draftTitle(_ title: String, draft: Bool) -> String {
        var plain = title
        for prefix in ["WIP:", "[WIP]", "Draft:"] where plain.lowercased().hasPrefix(prefix.lowercased()) {
            plain = String(plain.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return draft ? "WIP: " + plain : plain
    }

    static func isDraft(_ pull: PullRequest) -> Bool {
        pull.draft == true || ["wip:", "[wip]", "draft:"].contains { pull.title.lowercased().hasPrefix($0) }
    }

    func setDraft(_ draft: Bool, _ pull: PullRequest, in repo: ForgeRepo) async {
        await change(repo, pull, done: draft ? "#\(pull.number) is a draft now" : "#\(pull.number) is ready for review") { slug, client in
            try await client.editPull(slug, number: pull.number, title: Self.draftTitle(pull.title, draft: draft))
        }
    }

    func setOpen(_ open: Bool, _ pull: PullRequest, in repo: ForgeRepo) async {
        await change(repo, pull, done: open ? "Reopened #\(pull.number)" : "Closed #\(pull.number)") { slug, client in
            try await client.editPull(slug, number: pull.number, state: open ? "open" : "closed")
        }
    }

    /// Brings the base branch's commits into the pull request's branch.
    func updateBranch(of pull: PullRequest, in repo: ForgeRepo, rebase: Bool) async {
        await change(repo, pull, done: "Updated \(pull.head.name) from \(pull.base.ref)") { slug, client in
            try await client.updateBranch(slug, number: pull.number, style: rebase ? "rebase" : "merge")
        }
    }

    // MARK: Notifications

    func refreshNotifications() async {
        var all: [HostNotification] = []
        for account in accounts {
            guard let client = client(for: account.host), let items = try? await client.notifications() else { continue }
            all += items.filter { $0.unread != false }.map { HostNotification(host: account.host, item: $0) }
        }
        all.sort { ($0.item.updatedAt ?? .distantPast) > ($1.item.updatedAt ?? .distantPast) }
        if notifications != all { notifications = all }
    }

    /// Whether the server holds an unread notification about this pull request.
    func isUnread(host: String, fullName: String, number: Int) -> Bool {
        notifications.contains { $0.host == host && $0.item.number == number && $0.item.repository?.fullName.lowercased() == fullName.lowercased() }
    }

    /// Unread notifications about the things the Inbox lists.
    var unreadCount: Int {
        inbox.count { isUnread(host: $0.host, fullName: $0.hit.repository?.fullName ?? "", number: $0.hit.number) }
            + myPulls.count { isUnread(host: $0.host, fullName: $0.repoFullName, number: $0.number) }
    }

    /// Marks what the server noted about a pull request as read.
    func markRead(host: String, fullName: String, number: Int) async {
        let matching = notifications.filter { $0.host == host && $0.item.number == number && $0.item.repository?.fullName.lowercased() == fullName.lowercased() }
        guard !matching.isEmpty else { return }
        notifications.removeAll { item in matching.contains { $0.id == item.id } }
        if let client = client(for: host) {
            for item in matching { try? await client.markRead(notification: item.item.id) }
        }
    }

    func markAllRead() async {
        for item in inbox { await markRead(host: item.host, fullName: item.hit.repository?.fullName ?? "", number: item.hit.number) }
        for pull in myPulls { await markRead(host: pull.host, fullName: pull.repoFullName, number: pull.number) }
    }

    /// Shows what a notification is about and marks it read on the server.
    func open(_ notification: HostNotification) async {
        if let client = client(for: notification.host) { try? await client.markRead(notification: notification.item.id) }
        notifications.removeAll { $0.id == notification.id }
        let item = notification.item
        if item.subject.type == "Pull", let number = item.number, let fullName = item.repository?.fullName {
            await openPull(host: notification.host, fullName: fullName, number: number, url: item.subject.htmlURL)
        } else if let url = item.subject.htmlURL.flatMap(URL.init) {
            await MainActor.run { _ = NSWorkspaceOpen(url) }
        }
    }

    // MARK: Releases and Actions settings

    func releases(of repo: ForgeRepo) async -> [ForgeRelease] {
        guard let (slug, client) = target(repo) else { return [] }
        return (try? await client.releases(slug)) ?? []
    }

    /// The names of the variables and secrets Actions has in the repository;
    /// nil when the account may not see them.
    func actionSettings(of repo: ForgeRepo) async -> (variables: [ActionVariable], secrets: [ActionSecret])? {
        guard let (slug, client) = target(repo) else { return nil }
        async let variables = try? client.actionVariables(slug)
        async let secrets = try? client.actionSecrets(slug)
        let (v, s) = await (variables, secrets)
        guard v != nil || s != nil else { return nil }
        return (v ?? [], s ?? [])
    }
}
