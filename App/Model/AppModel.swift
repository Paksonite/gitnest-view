import AppKit
import Foundation
import Observation

/// An organisation (or the account's own repositories) on a connected server:
/// what the switcher at the top of the sidebar lists.
struct Workspace: Codable, Identifiable, Hashable, Sendable {
    var host: String
    /// The organisation's name; the account's login for a personal workspace.
    var owner: String
    var personal: Bool

    var id: String { "\(host)/\(owner)".lowercased() }
    var title: String { owner }
}

/// What the app knows from the forge about one repository.
struct RepoForge: Equatable, Sendable {
    var pulls: [PullRequest] = []
    var runs: [WorkflowRun] = []
    var statuses: [String: CombinedStatus] = [:] // by commit sha
    var reviews: [Int: [Review]] = [:] // by pull request number
    var error: String?
    var loaded = false

    /// The repository's dot in the list: its most recent pipeline.
    var latest: CheckState? { runs.first?.state }

    func summary(for pull: PullRequest) -> ReviewSummary {
        ReviewSummary(reviews: reviews[pull.number] ?? [], requested: pull.requestedReviewers ?? [])
    }
}

/// What is loaded only for the pull request on screen.
struct PullExtras: Equatable, Sendable {
    var commits: [PullCommit] = []
    var files: [PullFile] = []
    /// Pipelines of the pull request's head commit (the plan).
    var pullRuns: [WorkflowRun] = []
    /// Pipelines started by merging the pull request (the apply).
    var mergeRuns: [WorkflowRun] = []
    var jobs: [Int: [WorkflowJob]] = [:] // by run id
    /// What Terraform printed in the pull request's pipeline, and after the merge.
    var plan: TerraformPlan?
    var applied: TerraformPlan?
    /// Terraform's error, when the plan or the apply failed.
    var planError: [String]?
    var applyError: [String]?
    /// What people wrote: in the conversation, and on lines in reviews.
    var comments: [IssueComment] = []
    var lineComments: [ReviewComment] = []
    var loaded = false

    /// True while a pipeline of the pull request is still going.
    var isLive: Bool {
        (pullRuns + mergeRuns).contains { !$0.state.isFinished }
    }
}

/// The job whose log is open.
struct LogTarget: Hashable, Sendable {
    var repo: RepoSlug
    var runID: Int
    var jobID: Int
    var title: String
    var webURL: String?
}

struct InboxItem: Identifiable, Hashable, Sendable {
    var host: String
    var hit: PullSearchHit
    var id: String { "\(host)#\(hit.id)" }
}

enum AppSection: Hashable, Sendable { case home, repositories, inbox, search }

/// A form shown over the window.
enum AppSheet: Hashable, Sendable {
    case release(ForgeRepo)
    /// A pull request for a feature branch.
    case createPull(ForgeRepo, head: String)
    case dispatch(ForgeRepo, Workflow)
    case newBranch(ForgeRepo, base: String)
    case reword(ForgeRepo, HistoryCommit)
    case newTag(ForgeRepo, rev: String, label: String)
    case pullAll
    /// Clone every repository of the workspace that is not here yet, then pull the rest.
    case getAll
    /// One branch in several repositories at once (a ticket that spans them).
    case startWork(preselected: ForgeRepo.ID?)
    /// Pull requests for one branch in every repository that has it.
    case openPulls(branch: String)
    case review(ForgeRepo, PullRequest)
    case merge(ForgeRepo, PullRequest)
    case editPull(ForgeRepo, PullRequest)
    /// What waits on develop in every repository of the workspace.
    case releases
}

/// The diff shown in a window over the app: a pull request's, all of it or
/// one file.
struct DiffTarget: Hashable, Sendable {
    var repo: RepoSlug
    var number: Int
    var title: String
    var file: String?
}

/// A question with one button that does something that cannot be undone.
struct Confirmation: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var button: String
    var destructive: Bool
    var action: () -> Void
}

/// What a release pull request would contain.
struct ReleaseDraft: Sendable {
    var head: String
    var base: String
    var commits: [PullCommit]
    var tickets: [String]
    var title: String
    var body: String
    /// The open pull request for the same branches, when there is one.
    var existing: PullRequest?
}

@MainActor @Observable
final class AppModel {
    // Settings
    private(set) var accounts: [ForgeAccount] = [] {
        didSet { ServerName.known = accounts.map(\.host) }
    }
    private(set) var workdir: String?

    // The forge
    private(set) var workspaces: [Workspace] = []
    private(set) var workspace: Workspace?
    private(set) var repos: [ForgeRepo] = []
    private(set) var reposError: String?
    /// Set while the workspace's server cannot be reached and the last known
    /// repository list is shown.
    var offline: String?
    private(set) var loadingRepos = false
    private(set) var forge: [String: RepoForge] = [:] // by RepoSlug.key
    private(set) var extras: [String: PullExtras] = [:] // by "slug.key#number"
    private(set) var inbox: [InboxItem] = []
    /// What the servers want the user to know (mentions, comments); empty
    /// when the token may not read notifications.
    var notifications: [HostNotification] = []
    /// Jira, when the user connected it.
    var jira = JiraState()
    var myPulls: [MyPull] = []
    /// Branch protection rules by RepoSlug.key; empty when they cannot be read.
    var protections: [String: [BranchProtection]] = [:]
    /// What the server said about the base branches of pull requests, by "slug.key@branch".
    var branches: [String: BranchInfo] = [:]

    // Local clones under the working directory
    var local: [String: Repo] = [:] // by RepoSlug.key
    private(set) var cloning: Set<String> = []
    var busy: Set<String> = [] // fetch / pull / checkout in progress
    private(set) var engineError: String?
    /// Short messages at the bottom of the window ("Pushed feat/x").
    var toasts: [Toast] = []
    /// Bumped after every change the app makes to a clone, so the views that
    /// show its files and history read them again.
    var localRevision: [String: Int] = [:] // by RepoSlug.key
    /// Bumped whenever the app comes to the front: the user may have changed
    /// files in the editor or terminal meanwhile.
    var activations = 0
    var lastActivation = Date.distantPast
    /// Bumped when a setting kept in UserDefaults changes, so views redraw.
    var settingsRevision = 0
    var fetchingAll = false

    // What is on screen
    /// Home first, like gitnest's dashboard: what needs the user, at a glance.
    var section: AppSection = .home
    var selection: ForgeRepo.ID?
    var filter = ""
    var logTarget: LogTarget?
    var sheet: AppSheet?
    var repoTab: RepoTab = .overview
    var paletteOpen = false
    /// Opens the main window again after it was closed; set by a view that
    /// lives as long as the app (the menu bar item).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// The text the Search section looks for (set by the palette too).
    var searchText = ""
    var confirmation: Confirmation?
    var diffTarget: DiffTarget?
    /// Whether a server's token may change things there; absent until asked.
    var writeAccess: [String: Bool] = [:]
    /// The setup wizard is on screen (first run, or asked for again).
    var wizardOpen = false
    /// The step of the tour on screen; nil when the tour is not running.
    var tourStep: Int?
    /// The Jira ticket open in the app's own window (its key).
    var ticketTarget: String?
    /// The file open in the app's own viewer.
    var fileTarget: FileTarget?
    private(set) var workflows: [String: [Workflow]] = [:] // by RepoSlug.key
    /// The jobs worth showing while they pass: the ones whose name contains
    /// one of these. Other jobs appear only when they fail.
    private(set) var keyJobs: [String] = AppModel.defaultKeyJobs
    static let defaultKeyJobs = ["Terraform single state", "filter plan", "Terragrunt plan"]
    /// A pull request to show once its repository is on screen (from the Inbox).
    var pendingPull: Int?

    let core: CoreClient
    private let tokens: any TokenStore
    let defaults: UserDefaults
    private var loops: [Task<Void, Never>] = []
    /// Tokens already read from the store, so the Keychain is asked once per
    /// server and not on every refresh.
    private var tokenCache: [String: String] = [:]
    /// How the servers are reached; tests put a canned server here.
    @ObservationIgnored var session: URLSession = .shared
    @ObservationIgnored var jiraTokenCache: (key: String, token: String)?
    @ObservationIgnored var jiraAccountID: String?
    /// The name Start Work opens with (a ticket's key), once.
    @ObservationIgnored var startWorkName: String?
    var tokenStore: any TokenStore { tokens }
    @ObservationIgnored private var tokensLoading = false
    private var historyWanted: Set<String> = []
    @ObservationIgnored private var runsWanted: Set<String> = []
    @ObservationIgnored var pinnedCache: (revision: Int, names: Set<String>)?
    @ObservationIgnored private var forgeFlights: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var forgeRead: [String: Date] = [:]
    @ObservationIgnored private var extrasFlights: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var extrasRead: [String: Date] = [:]
    /// When a pull request's reviews and checks were last read with its repository.
    @ObservationIgnored private var extrasChecked: [String: Date] = [:]
    /// Logs of finished jobs already searched for a Terraform plan.
    private var planCache: [String: TerraformPlan?] = [:]
    private var errorCache: [String: [String]] = [:]

    enum Key {
        static let accounts = "accounts"
        static let workdir = "workdir"
        static let workspace = "workspace"
        static let keyJobs = "keyJobs"
    }

    init(core: CoreClient = .bundled(), tokens: any TokenStore = KeychainTokenStore(), defaults: UserDefaults = .standard) {
        self.core = core
        self.tokens = tokens
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.accounts), let saved = try? JSONDecoder().decode([ForgeAccount].self, from: data) {
            accounts = saved
        }
        workdir = defaults.string(forKey: Key.workdir)
        if let saved = defaults.stringArray(forKey: Key.keyJobs) { keyJobs = saved }
        if let data = defaults.data(forKey: Key.workspace) {
            workspace = try? JSONDecoder().decode(Workspace.self, from: data)
        }
    }

    #if DEBUG
    /// For development only: `GNV_DEV_HOST`, `GNV_DEV_LOGIN`, `GNV_DEV_TOKEN`
    /// and `GNV_DEV_WORKDIR` in the environment start the app on that
    /// server with the token kept in memory and its own preferences, so a
    /// developer's real settings and Keychain are left alone.
    /// `GNV_DEV_TAB` picks the tab a repository opens on, `GNV_DEV_OPEN`
    /// what is opened at launch.
    static func development() -> AppModel? {
        let env = ProcessInfo.processInfo.environment
        if env["GNV_DEV_ONBOARDING"] != nil, let defaults = UserDefaults(suiteName: "pl.paksonite.gitnest-view.dev") {
            // First launch, without touching the real settings or Keychain.
            defaults.removePersistentDomain(forName: "pl.paksonite.gitnest-view.dev")
            return AppModel(tokens: MemoryTokenStore(), defaults: defaults)
        }
        guard let host = env["GNV_DEV_HOST"], let token = env["GNV_DEV_TOKEN"], let workdir = env["GNV_DEV_WORKDIR"],
              let defaults = UserDefaults(suiteName: "pl.paksonite.gitnest-view.dev")
        else { return nil }
        defaults.removePersistentDomain(forName: "pl.paksonite.gitnest-view.dev")
        // Measuring on a server that must be left alone: no fetch on its own.
        if env["GNV_DEV_NOFETCH"] != nil { defaults.set(false, forKey: "backgroundFetch") }
        let tokens = MemoryTokenStore()
        try? tokens.setToken(token, for: host)
        let model = AppModel(tokens: tokens, defaults: defaults)
        if let site = env["GNV_DEV_JIRA_SITE"], let email = env["GNV_DEV_JIRA_EMAIL"], let jiraToken = env["GNV_DEV_JIRA_TOKEN"] {
            let settings = JiraSettings(site: site, email: email, filter: env["GNV_DEV_JIRA_JQL"])
            try? tokens.setToken(jiraToken, for: settings.tokenKey)
            defaults.set(try? JSONEncoder().encode(settings), forKey: "jira")
        }
        model.accounts = [ForgeAccount(host: host, login: env["GNV_DEV_LOGIN"])]
        // A second server, to look at everything with two connected.
        if let other = env["GNV_DEV_HOST2"], let otherToken = env["GNV_DEV_TOKEN2"] {
            try? tokens.setToken(otherToken, for: other)
            model.accounts.append(ForgeAccount(host: other, login: env["GNV_DEV_LOGIN"]))
        }
        model.workdir = workdir
        model.initialTab = env["GNV_DEV_TAB"]
        model.initialOpen = env["GNV_DEV_OPEN"]
        model.initialRepo = env["GNV_DEV_REPO"]
        model.initialWorkspace = env["GNV_DEV_WORKSPACE"]
        model.section = .repositories
        return model
    }
    #endif

    /// The tab a repository opens on, by its name; nil for the default.
    var initialTab: String?
    /// Development only (`GNV_DEV_OPEN`): "log", "workspace" or "branch"
    /// opens that piece of interface at launch, to look at it.
    var initialOpen: String?
    /// Development only (`GNV_DEV_REPO`): the repository selected at launch.
    var initialRepo: String?
    /// Development only (`GNV_DEV_WORKSPACE`): the organisation shown at launch.
    var initialWorkspace: String?

    /// The app is usable once a server is connected and a folder is chosen.
    var isSetUp: Bool { !accounts.isEmpty && workdir != nil }

    var selectedRepo: ForgeRepo? { repos.first { $0.id == selection } }

    var shownRepos: [ForgeRepo] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? repos : repos.filter { $0.name.lowercased().contains(needle) }
    }

    func slug(_ repo: ForgeRepo) -> RepoSlug? {
        guard let host = workspace?.host else { return nil }
        return RepoSlug(host: host, owner: repo.owner.login, name: repo.name)
    }

    func clone(of repo: ForgeRepo) -> Repo? {
        slug(repo).flatMap { local[$0.key] }
    }

    func forgeState(_ repo: ForgeRepo) -> RepoForge {
        slug(repo).flatMap { forge[$0.key] } ?? RepoForge()
    }

    // MARK: - Lifecycle

    /// Starts the background refreshes. Polling stops while the app is in the
    /// background, so an idle window costs nothing.
    func start() {
        guard loops.isEmpty else { return }
        Notifier.shared.start(self)
        ServerName.known = accounts.map(\.host)
        applyAppearance()
        Updater.shared.start()
        if isSetUp { Notifier.shared.requestAccess() }
        loops.append(Task { [weak self] in
            await self?.loadTokens()
            await self?.reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard NSApp.isActive else { continue }
                await self?.refreshLocal()
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if NSApp.isActive { await self?.refreshSelected() }
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard NSApp.isActive else { continue }
                await self?.loadRepos(quiet: true)
                await self?.refreshOverview()
            }
        })
        // News (review requests, failed pipelines of my pull requests) are
        // read in the background too: they are what notifications are for.
        loops.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                guard let self else { return }
                if self.isSetUp { await self.checkForNews() }
                try? await Task.sleep(for: .seconds(120))
            }
        })
        // A quiet fetch of every clone keeps "behind" true without asking.
        loops.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                guard let self else { return }
                if NSApp.isActive, self.backgroundFetch, !self.fetchingAll { await self.quietFetchAll() }
                try? await Task.sleep(for: .seconds(600))
            }
        })
    }

    /// Everything from scratch: after launch and after a change in Settings.
    func reload() async {
        guard isSetUp else { return }
        Notifier.shared.requestAccess()
        Task { await refreshServerVersions() }
        async let scanned: Void = scan(full: false)
        await loadWorkspaces()
        await loadRepos(quiet: false)
        await scanned
        if repos.isEmpty, reposError != nil { reposFromClones() }
        await refreshSelected()
        Task {
            await refreshOverview()
            await warmUp()
        }
        Task { await refreshInbox() }
        Task { await learnWriteAccess() }
    }

    // MARK: - Settings

    func setWorkdir(_ url: URL) {
        workdir = url.path
        defaults.set(url.path, forKey: Key.workdir)
        local = [:]
        Task { await reload() }
    }

    /// Checks the token against the server and remembers the account.
    func connect(host input: String, token: String) async throws {
        let host = ForgeAccount.normalize(input)
        let client = ForgejoClient(host: host, token: token, session: session)
        let user = try await client.currentUser()
        let version = try? await client.version()
        try tokens.setToken(token, for: host)
        tokenCache[host] = token
        writeAccess[host] = nil
        let ssh = accounts.first { $0.host == host }?.cloneWithSSH
        accounts.removeAll { $0.host == host }
        accounts.append(ForgeAccount(host: host, login: user.login, serverVersion: version, cloneWithSSH: ssh))
        accounts.sort { $0.host < $1.host }
        saveAccounts()
        await reload()
    }

    func disconnect(_ account: ForgeAccount) {
        try? tokens.setToken(nil, for: account.host)
        tokenCache[account.host] = nil
        accounts.removeAll { $0.host == account.host }
        saveAccounts()
        workspaces.removeAll { $0.host == account.host }
        if workspace?.host == account.host {
            workspace = workspaces.first
            repos = []
            selection = nil
        }
        Task { await reload() }
    }

    /// What each server runs now: it decides what the app can ask of it,
    /// and a server gets upgraded between launches.
    func refreshServerVersions() async {
        for account in accounts {
            guard let client = client(for: account.host), let version = try? await client.version(),
                  let index = accounts.firstIndex(where: { $0.host == account.host }), accounts[index].serverVersion != version else { continue }
            accounts[index].serverVersion = version
            saveAccounts()
        }
    }

    func setCloneWithSSH(_ ssh: Bool, for account: ForgeAccount) {
        guard let index = accounts.firstIndex(where: { $0.host == account.host }) else { return }
        accounts[index].cloneWithSSH = ssh
        saveAccounts()
    }

    private func saveAccounts() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: Key.accounts)
    }

    /// Reads the tokens off the main thread before the first use: the
    /// Keychain may ask the user first, and the window must not freeze
    /// while its question is on screen.
    func loadTokens() async {
        tokensLoading = true
        defer { tokensLoading = false }
        let store = tokens
        for account in accounts where tokenCache[account.host] == nil {
            let host = account.host
            if let token = await Task.detached(operation: { store.token(for: host) }).value { tokenCache[host] = token }
        }
    }

    func client(for host: String) -> ForgejoClient? {
        guard accounts.contains(where: { $0.host == host }) else { return nil }
        // Still waiting for the Keychain: whoever asks now is asked again by the first reload.
        if tokensLoading, tokenCache[host] == nil { return nil }
        if tokenCache[host] == nil, let token = tokens.token(for: host) { tokenCache[host] = token }
        return ForgejoClient(host: host, token: tokenCache[host], session: session)
    }

    // MARK: - Workspaces and repositories

    func loadWorkspaces() async {
        var all: [Workspace] = []
        var reachable = true
        for account in accounts {
            guard let client = client(for: account.host) else { continue }
            do {
                let orgs = try await client.organizations()
                all += orgs.map { Workspace(host: account.host, owner: $0.login, personal: false) }
                    .sorted { $0.owner.localizedStandardCompare($1.owner) == .orderedAscending }
            } catch {
                // The server cannot be reached (VPN down, offline): keep what
                // was known about it instead of falling back to another workspace.
                reachable = false
                all += cachedWorkspaces.filter { $0.host == account.host && !$0.personal }
            }
            if let login = account.login {
                all.append(Workspace(host: account.host, owner: login, personal: true))
            }
        }
        if let current = workspace, !all.contains(where: { $0.id == current.id }), !reachable {
            all.insert(current, at: 0)
        }
        workspaces = all
        if reachable { cachedWorkspaces = all }
        if let wanted = initialWorkspace, let found = all.first(where: { $0.owner.lowercased() == wanted.lowercased() }) {
            workspace = found
            initialWorkspace = nil
        }
        if workspace == nil || !all.contains(where: { $0.id == workspace?.id }) {
            workspace = all.first
        }
        // Remembered, so the same workspace opens next time, also offline.
        if reachable, let workspace { defaults.set(try? JSONEncoder().encode(workspace), forKey: Key.workspace) }
    }

    func select(_ workspace: Workspace) {
        guard workspace.id != self.workspace?.id else { return }
        self.workspace = workspace
        defaults.set(try? JSONEncoder().encode(workspace), forKey: Key.workspace)
        repos = []
        selection = nil
        logTarget = nil
        Task {
            await loadRepos(quiet: false)
            await refreshSelected()
            await refreshOverview()
        }
    }

    func loadRepos(quiet: Bool) async {
        guard let workspace, let client = client(for: workspace.host) else { return }
        if !quiet { loadingRepos = true }
        defer { loadingRepos = false }
        do {
            var fresh: [ForgeRepo]
            if workspace.personal {
                // Own repositories and the ones shared with the account,
                // without those of organisations (they have their own entry).
                let orgs = Set(workspaces.filter { !$0.personal && $0.host == workspace.host }.map { $0.owner.lowercased() })
                fresh = try await client.userRepositories().filter { !orgs.contains($0.owner.login.lowercased()) }
            } else {
                fresh = try await client.repositories(org: workspace.owner)
            }
            guard workspace.id == self.workspace?.id else { return }
            fresh.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if repos != fresh { repos = fresh }
            reposError = nil
            offline = nil
            saveRepoCache(fresh, for: workspace)
            if let wanted = initialRepo, let repo = repos.first(where: { $0.name == wanted }) {
                selection = repo.id
                initialRepo = nil
            }
            if selectedRepo == nil { selection = repos.first { clone(of: $0) != nil }?.id ?? repos.first?.id }
        } catch {
            // Offline: the last known list keeps the clones usable.
            if repos.isEmpty, let cached = loadRepoCache(for: workspace), !cached.isEmpty {
                repos = cached
                if selectedRepo == nil { selection = repos.first { clone(of: $0) != nil }?.id ?? repos.first?.id }
            }
            if repos.isEmpty {
                if !quiet { reposError = error.localizedDescription }
            } else {
                offline = "\(workspace.host) cannot be reached: \(error.localizedDescription)"
            }
        }
    }

    /// Offline and nothing cached yet: the clones of the workspace's owner
    /// still make a list to work with.
    private func reposFromClones() {
        guard var workspace else { return }
        var found = local.values.filter { $0.remote.host == workspace.host && $0.remote.owner.lowercased() == workspace.owner.lowercased() }
        if found.isEmpty {
            // No workspace was remembered: take the owner with the most clones
            // on this server (an organisation, most likely).
            let counts = Dictionary(grouping: local.values.filter { $0.remote.host == workspace.host && !$0.remote.owner.isEmpty }, by: \.remote.owner)
            guard let best = counts.max(by: { $0.value.count < $1.value.count }) else { return }
            workspace = Workspace(host: workspace.host, owner: best.key, personal: false)
            if !workspaces.contains(where: { $0.id == workspace.id }) { workspaces.insert(workspace, at: 0) }
            self.workspace = workspace
            found = best.value
        }
        repos = found.map { clone in
            ForgeRepo(id: -abs(clone.path.hashValue), name: clone.remote.repo, fullName: "\(clone.remote.owner)/\(clone.remote.repo)",
                      owner: ForgeUser(id: 0, login: clone.remote.owner), htmlURL: clone.remote.web.isEmpty ? nil : clone.remote.web)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        offline = "\(workspace.host) cannot be reached: showing the clones in the working directory."
        reposError = nil
        if selectedRepo == nil { selection = repos.first?.id }
    }

    // MARK: - Offline cache

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "GitNest View", directoryHint: .isDirectory)
    }

    private func cacheFile(_ workspace: Workspace) -> URL {
        let name = workspace.id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return Self.cacheDirectory.appending(path: "repos-\(name).json")
    }

    private func saveRepoCache(_ repos: [ForgeRepo], for workspace: Workspace) {
        guard defaults == .standard || defaults.bool(forKey: "useRepoCache") else { return } // tests and dev launches keep no cache
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(repos) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile(workspace), options: .atomic)
    }

    private func loadRepoCache(for workspace: Workspace) -> [ForgeRepo]? {
        guard let data = try? Data(contentsOf: cacheFile(workspace)) else { return nil }
        return try? ForgejoClient.decoder.decode([ForgeRepo].self, from: data)
    }

    /// The workspaces seen when the servers last answered.
    private var cachedWorkspaces: [Workspace] {
        get { (defaults.data(forKey: "workspaces")).flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "workspaces") }
    }

    // MARK: - Local clones (the engine)

    func scan(full: Bool) async {
        guard let workdir else { return }
        do {
            let result: ScanResult = try await core.call("repos.scan", ScanParams(roots: [workdir], full: full))
            index(result.repos, replacing: true)
            engineError = nil
        } catch {
            engineError = error.localizedDescription
        }
    }

    func refreshLocal() async {
        let paths = local.values.map(\.path)
        guard !paths.isEmpty else { return }
        do {
            let result: ScanResult = try await core.call("repos.status", PathsParams(paths: paths))
            index(result.repos, replacing: true)
            engineError = nil
        } catch {
            engineError = error.localizedDescription
        }
    }

    /// Clones are matched to forge repositories by their remote, not by
    /// where they are: an existing clone anywhere in the folder counts.
    func index(_ found: [Repo], replacing: Bool) {
        var map = replacing ? [:] : local
        for repo in found {
            guard let slug = repo.slug else { continue }
            // Two clones of one repository: keep the one used most recently.
            if let other = map[slug.key], other.lastUsed > repo.lastUsed { continue }
            map[slug.key] = repo
        }
        if local != map { local = map }
    }

    /// Where a new clone goes: <working directory>/<owner>/<name>.
    func cloneDestination(_ repo: ForgeRepo) -> String? {
        guard let workdir else { return nil }
        // One GitNest folder holds every server: <folder>/<server>/<owner>/<name>.
        // A folder that is already named after the server keeps its shape.
        var base = URL(fileURLWithPath: workdir)
        if let host = workspace?.host, base.lastPathComponent.lowercased() != host.lowercased() { base = base.appending(path: host) }
        return base.appending(path: repo.owner.login).appending(path: repo.name).path
    }

    func auth(host: String, forURL url: String) -> GitAuth? {
        guard url.lowercased().hasPrefix("https://"), let account = accounts.first(where: { $0.host == host }),
              let token = client(for: host)?.token, !token.isEmpty
        else { return nil }
        return GitAuth(host: host, user: account.login ?? "token", token: token)
    }

    func clone(_ repo: ForgeRepo) async {
        guard let slug = slug(repo), let dest = cloneDestination(repo), !cloning.contains(slug.key) else { return }
        let ssh = accounts.first { $0.host == slug.host }?.cloneWithSSH == true
        guard let url = ssh ? repo.sshURL : repo.cloneURL else { return }
        cloning.insert(slug.key)
        defer { cloning.remove(slug.key) }
        do {
            let result: ScanResult = try await core.call("repo.clone", CloneParams(url: url, dest: dest, auth: auth(host: slug.host, forURL: url)))
            index(result.repos, replacing: false)
            toast("Cloned \(repo.name)")
        } catch {
            toast("Cloning \(repo.name) failed: \(error.localizedDescription)", .error)
        }
    }

    /// Clones every repository of the workspace that is not cloned yet.
    func cloneAll() async {
        await clone(repos.filter { clone(of: $0) == nil && $0.empty != true })
    }

    /// Clones several repositories, a few at a time; `progress` hears each one done.
    func clone(_ targets: [ForgeRepo], progress: (@MainActor (ForgeRepo) -> Void)? = nil) async {
        await withTaskGroup(of: ForgeRepo.self) { group in
            var waiting = targets.makeIterator()
            for _ in 0..<3 {
                guard let repo = waiting.next() else { break }
                group.addTask { await self.clone(repo); return repo }
            }
            for await done in group {
                progress?(done)
                if let repo = waiting.next() { group.addTask { await self.clone(repo); return repo } }
            }
        }
    }

    enum GitAction: String { case fetch = "repo.fetch", pull = "repo.pull" }

    func run(_ action: GitAction, on repo: ForgeRepo) async {
        guard let slug = slug(repo), let clone = local[slug.key], !busy.contains(slug.key) else { return }
        busy.insert(slug.key)
        defer { busy.remove(slug.key) }
        let before = clone.behind
        do {
            try await core.run(action.rawValue, RepoParams(path: clone.path, auth: auth(host: slug.host, forURL: clone.remote.url)))
        } catch {
            toast("\(action == .pull ? "Pull" : "Fetch") failed in \(repo.name): \(error.localizedDescription)", .error)
        }
        await refreshClone(repo)
        if action == .pull, let after = local[slug.key], after.behind == 0, before > 0 {
            toast("Pulled \(before) \(before == 1 ? "commit" : "commits") into \(after.branch)")
        }
    }

    func branches(of repo: ForgeRepo) async -> BranchList? {
        guard let clone = clone(of: repo) else { return nil }
        return try? await core.call("repo.branches", PathParams(path: clone.path))
    }

    func checkout(_ branch: LocalBranch, in repo: ForgeRepo) async {
        guard let slug = slug(repo), let clone = local[slug.key] else { return }
        busy.insert(slug.key)
        defer { busy.remove(slug.key) }
        do {
            try await core.run("repo.checkout", CheckoutParams(path: clone.path, name: branch.name, remote: branch.remote))
            toast("Switched to \(branch.remote ? (branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name) : branch.name)")
        } catch {
            toast(error.localizedDescription, .error)
        }
        await refreshClone(repo)
    }

    func changedFiles(of repo: ForgeRepo) async -> [ChangedFile] {
        guard let clone = clone(of: repo) else { return [] }
        let result: ChangedFiles? = try? await core.call("repo.files", PathParams(path: clone.path))
        return result?.files ?? []
    }

    func commits(of repo: ForgeRepo, limit: Int = 10) async -> [LocalCommit] {
        guard let clone = clone(of: repo) else { return [] }
        let result: CommitList? = try? await core.call("repo.log", LogParams(path: clone.path, limit: limit))
        return result?.commits ?? []
    }

    // MARK: - Pull requests and pipelines

    func refreshSelected() async {
        guard let repo = selectedRepo else { return }
        await refreshForge(repo, detailed: true)
        if let key = slug(repo)?.key, workflows[key] == nil { await loadWorkflows(repo) }
    }

    /// The dots of every repository in the workspace, a few at a time.
    func refreshOverview() async {
        let targets = repos.filter { $0.id != selection && $0.hasActions != false && $0.empty != true }
        await withTaskGroup(of: Void.self) { group in
            var waiting = targets.makeIterator()
            for _ in 0..<4 {
                guard let repo = waiting.next() else { break }
                group.addTask { await self.refreshForge(repo, detailed: false) }
            }
            while await group.next() != nil {
                if let repo = waiting.next() {
                    group.addTask { await self.refreshForge(repo, detailed: false) }
                }
            }
        }
    }

    /// Reads a repository's pipelines; `detailed` also reads its pull
    /// requests with the checks and reviews of the open ones.
    func refreshForge(_ repo: ForgeRepo, detailed: Bool, ifOlderThan age: TimeInterval = 0) async {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return }
        guard detailed else { return await readForge(repo, slug: slug, client: client, detailed: false) }
        // A click right after a hover, or two views asking at once, share one
        // round of requests; an answer a moment old is not asked for again.
        if let running = forgeFlights[slug.key] { return await running.value }
        if age > 0, let read = forgeRead[slug.key], Date.now.timeIntervalSince(read) < age { return }
        let flight = Task { await self.readForge(repo, slug: slug, client: client, detailed: true) }
        forgeFlights[slug.key] = flight
        await flight.value
        forgeFlights[slug.key] = nil
    }

    /// Once after launch: the pull requests of the cloned repositories, a few
    /// at a time, so the first visit to each is as quick as the second.
    func warmUp() async {
        let targets = repos.filter { $0.id != selection && $0.empty != true && clone(of: $0) != nil }
        await withTaskGroup(of: Void.self) { group in
            var waiting = targets.makeIterator()
            for _ in 0..<3 {
                guard let repo = waiting.next() else { break }
                group.addTask { await self.refreshForge(repo, detailed: true, ifOlderThan: 300) }
            }
            while await group.next() != nil {
                if let repo = waiting.next() {
                    group.addTask { await self.refreshForge(repo, detailed: true, ifOlderThan: 300) }
                }
            }
        }
    }

    /// The user looks at closed pull requests of this repository: read more
    /// of them, now and on later refreshes.
    func wantHistory(_ repo: ForgeRepo) {
        Task { await loadHistory(repo) }
    }

    func loadHistory(_ repo: ForgeRepo) async {
        guard let key = slug(repo)?.key, !historyWanted.contains(key) else { return }
        historyWanted.insert(key)
        await refreshForge(repo, detailed: true)
    }

    func hasHistory(_ repo: ForgeRepo) -> Bool { slug(repo).map { historyWanted.contains($0.key) } ?? false }

    /// The Actions tab is open: read more of the repository's runs from now on.
    func wantRuns(_ repo: ForgeRepo) async {
        guard let key = slug(repo)?.key, !runsWanted.contains(key) else { return }
        runsWanted.insert(key)
        await refreshForge(repo, detailed: true)
    }

    /// Reads what a repository's row needs before it is clicked: called when
    /// the pointer rests on it, so the click finds the answer already here.
    func prefetch(_ repo: ForgeRepo) {
        guard repo.id != selection, repo.empty != true else { return }
        Task {
            await refreshForge(repo, detailed: true, ifOlderThan: 30)
            if let pull = featuredPull(in: repo) { await loadExtras(pull, in: repo, ifOlderThan: 30) }
        }
    }

    /// The pull request a repository opens on: the open one of the branch
    /// checked out, else any open one, else the last merged.
    func featuredPull(in repo: ForgeRepo) -> PullRequest? {
        let pulls = forgeState(repo).pulls
        if let branch = clone(of: repo)?.branch,
           let mine = pulls.first(where: { $0.state == "open" && $0.head.ref == branch }) { return mine }
        return pulls.first { $0.state == "open" } ?? pulls.first { $0.merged == true }
    }

    private func readForge(_ repo: ForgeRepo, slug: RepoSlug, client: ForgejoClient, detailed: Bool) async {
        var state = forge[slug.key] ?? RepoForge()
        do {
            if detailed {
                // Open pull requests are few and quick; closed ones are heavy
                // (a second each on a busy server), so only the newest come
                // along until the user asks for the history.
                async let openPulls = client.pullRequests(slug, state: "open", limit: 50)
                async let closedPulls = client.pullRequests(slug, state: "closed", limit: historyWanted.contains(slug.key) ? 40 : 5)
                // Each run carries its whole repository (10 kB): a dozen is
                // enough until the Actions tab is opened.
                async let newest = client.runs(slug, limit: runsWanted.contains(slug.key) ? 40 : 12)
                // The default branch's own runs (merges, schedules) are asked
                // for by name: among the newest they drown in pull requests.
                async let onMain = try? client.runs(slug, limit: 8, branch: repo.defaultBranch ?? "main")
                let (nowOpen, nowClosed, newestRuns, mainRuns) = try await (openPulls, closedPulls, newest, onMain)
                let freshRuns = Self.joined(newestRuns, mainRuns ?? [])
                // Once each: a pull request merged between the two answers is in both.
                var seenPulls = Set<PullRequest.ID>()
                let freshPulls = (nowOpen + nowClosed).filter { seenPulls.insert($0.id).inserted }
                    .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                state.pulls = freshPulls
                state.runs = freshRuns
                let open = freshPulls.filter { $0.state == "open" }
                await withTaskGroup(of: (Int, String, [Review]?, CombinedStatus?).self) { group in
                    for pull in open {
                        group.addTask {
                            async let reviews = try? client.reviews(slug, pull: pull.number)
                            async let status = try? client.combinedStatus(slug, ref: pull.head.sha)
                            return await (pull.number, pull.head.sha, reviews, status)
                        }
                    }
                    for await (number, sha, reviews, status) in group {
                        if let reviews { state.reviews[number] = reviews }
                        if let status { state.statuses[sha] = status }
                    }
                }
                state.loaded = true
                forgeRead[slug.key] = .now
                for pull in open { extrasChecked[Self.extrasKey(slug, pull.number)] = .now }
                Trace.note("refreshForge \(repo.name): \(freshPulls.count) pulls (\(open.count) open), \(freshRuns.count) runs")
            } else {
                // The overview reads only the newest runs: keep the older ones.
                async let newest = client.runs(slug, limit: 3)
                async let onMain = try? client.runs(slug, limit: 8, branch: repo.defaultBranch ?? "main")
                let fresh = Self.joined(try await newest, await onMain ?? [])
                let ids = Set(fresh.map(\.id))
                state.runs = (fresh + state.runs.filter { !ids.contains($0.id) }).sorted { $0.id > $1.id }
            }
            state.error = nil
        } catch is CancellationError {
            return
        } catch {
            state.error = error.localizedDescription
        }
        if detailed, state.error == nil, var now = forge[slug.key] {
            // Others (a pull request's own load) may have written meanwhile.
            now.pulls = state.pulls; now.runs = state.runs; now.loaded = true; now.error = nil
            now.reviews.merge(state.reviews) { _, new in new }
            now.statuses.merge(state.statuses) { _, new in new }
            state = now
        }
        if forge[slug.key] != state { forge[slug.key] = state }
    }

    /// Two lists of runs as one, newest first, each run once.
    static func joined(_ a: [WorkflowRun], _ b: [WorkflowRun]) -> [WorkflowRun] {
        var seen = Set<Int>()
        return (a + b).filter { seen.insert($0.id).inserted }.sorted { $0.id > $1.id }
    }

    static func extrasKey(_ slug: RepoSlug, _ number: Int) -> String { "\(slug.key)#\(number)" }

    /// How many approvals the base branch of a pull request requires, when
    /// the account can read the branch protection; nil otherwise.
    func requiredApprovals(_ pull: PullRequest, in repo: ForgeRepo) -> Int? {
        guard let slug = slug(repo) else { return nil }
        // The branch's own answer first: any token may read it.
        if let info = branches[Self.branchKey(slug, pull.base.ref)] {
            return info.protected == true ? info.requiredApprovals.flatMap { $0 > 0 ? $0 : nil } : nil
        }
        guard let rules = protections[slug.key] else { return nil }
        return rules.first { $0.covers(pull.base.ref) }?.requiredApprovals.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Whether the app knows if the base branch needs approvals. Without it,
    /// "no review required" would be a guess.
    func knowsRequirement(_ pull: PullRequest, in repo: ForgeRepo) -> Bool {
        guard let slug = slug(repo) else { return false }
        return branches[Self.branchKey(slug, pull.base.ref)] != nil || !(protections[slug.key] ?? []).isEmpty
    }

    static func branchKey(_ slug: RepoSlug, _ branch: String) -> String { "\(slug.key)@\(branch)" }

    /// Commits, files, reviews, checks, the pipelines of the pull request
    /// and of its merge, and what Terraform printed in them.
    func loadExtras(_ pull: PullRequest, in repo: ForgeRepo, ifOlderThan age: TimeInterval = 0) async {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return }
        let key = Self.extrasKey(slug, pull.number)
        if let running = extrasFlights[key] { return await running.value }
        if age > 0, let read = extrasRead[key], Date.now.timeIntervalSince(read) < age { return }
        let flight = Task { await self.readExtras(pull, slug: slug, client: client, key: key) }
        extrasFlights[key] = flight
        await flight.value
        extrasFlights[key] = nil
    }

    /// Everything is asked for at once and shown as it arrives: the
    /// pipelines first, they are what the eye looks for.
    private func readExtras(_ pull: PullRequest, slug: RepoSlug, client: ForgejoClient, key: String) async {
        let merged = pull.merged == true ? pull.mergeCommitSHA.flatMap { $0.isEmpty || $0 == pull.head.sha ? nil : $0 } : nil
        // The repository's own refresh has just read these for an open pull request.
        let checked = extrasChecked[key].map { Date.now.timeIntervalSince($0) < 5 } ?? false
        let needsRules = protections[slug.key] == nil

        async let commits = try? client.pullCommits(slug, pull: pull.number)
        async let files = try? client.pullFiles(slug, pull: pull.number)
        async let reviews = checked ? nil : try? client.reviews(slug, pull: pull.number)
        async let status = checked ? nil : try? client.combinedStatus(slug, ref: pull.head.sha)
        async let headRuns = try? client.runs(slug, limit: 10, headSHA: pull.head.sha)
        async let afterMerge: [WorkflowRun]? = merged == nil ? nil : try? client.runs(slug, limit: 20, headSHA: merged!)
        // Only admins may read them: anyone else gets an empty list.
        async let rules: [BranchProtection]? = needsRules ? ((try? await client.branchProtections(slug)) ?? []) : nil
        async let talk = try? client.comments(slug, number: pull.number)
        async let base = try? client.branch(slug, name: pull.base.ref)

        var extra = extras[key] ?? PullExtras()
        if let runs = await headRuns {
            // The pipeline of the pull request itself first, then the push's.
            extra.pullRuns = runs.filter { $0.trigger == "pull_request" } + runs.filter { $0.trigger != "pull_request" && $0.trigger != "schedule" }
        }
        if let runs = await afterMerge { extra.mergeRuns = Self.mergeRuns(runs) }
        let shownRuns = Array(extra.pullRuns.prefix(1) + extra.mergeRuns.prefix(2))
        await withTaskGroup(of: (Int, [WorkflowJob]?).self) { group in
            for run in shownRuns {
                // A finished run's jobs never change: read once.
                if run.state.isFinished, extra.jobs[run.id]?.allSatisfy({ $0.state.isFinished }) == true { continue }
                group.addTask { (run.id, try? await client.jobs(slug, run: run.id)) }
            }
            for await (id, jobs) in group { if let jobs { extra.jobs[id] = jobs } }
        }
        publish(merge(extra, into: key), as: key)
        Trace.note("extras #\(pull.number) pipelines shown")

        if let commits = await commits { extra.commits = commits }
        if let files = await files { extra.files = files }
        var state = forge[slug.key] ?? RepoForge()
        if let reviews = await reviews { state.reviews[pull.number] = reviews }
        if let talk = await talk { extra.comments = talk }
        // Comments on lines hang on reviews: read those of the reviews that say something.
        let spoken = (state.reviews[pull.number] ?? []).filter { $0.state != "REQUEST_REVIEW" }.suffix(12)
        if !spoken.isEmpty {
            var lines: [ReviewComment] = []
            await withTaskGroup(of: [ReviewComment].self) { group in
                for review in spoken { group.addTask { (try? await client.reviewComments(slug, number: pull.number, review: review.id)) ?? [] } }
                for await some in group { lines += some }
            }
            extra.lineComments = lines.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }
        if let checks = await status { state.statuses[pull.head.sha] = checks }
        if forge[slug.key] != state { forge[slug.key] = state }
        if let rules = await rules, protections[slug.key] != rules { protections[slug.key] = rules }
        if let base = await base, branches[Self.branchKey(slug, pull.base.ref)] != base { branches[Self.branchKey(slug, pull.base.ref)] = base }
        extra.loaded = true
        publish(merge(extra, into: key), as: key)
        extrasRead[key] = .now
        Trace.note("extras #\(pull.number) shown")

        let planJobs = extra.pullRuns.prefix(1).flatMap { extra.jobs[$0.id] ?? [] }
        let applyJobs = extra.mergeRuns.prefix(2).flatMap { extra.jobs[$0.id] ?? [] }
        async let plan = terraform(in: planJobs, slug: slug, client: client)
        async let applied = terraform(in: applyJobs, slug: slug, client: client)
        let (planned, done) = await (plan, applied)
        if var now = extras[key] { now.plan = planned; now.applied = done; publish(now, as: key) }
        async let planError = planned == nil ? terraformError(in: planJobs, slug: slug, client: client) : nil
        async let applyError = done == nil ? terraformError(in: applyJobs, slug: slug, client: client) : nil
        let (planFailure, applyFailure) = await (planError, applyError)
        if var now = extras[key] { now.planError = planFailure; now.applyError = applyFailure; publish(now, as: key) }
        Trace.note("extras #\(pull.number) plan read")
    }

    /// Writes only what changed: every write redraws the views that read it.
    private func publish(_ extra: PullExtras, as key: String) {
        if extras[key] != extra { extras[key] = extra }
    }

    /// Keeps what Terraform said from an earlier read while the new one loads.
    private func merge(_ extra: PullExtras, into key: String) -> PullExtras {
        var extra = extra
        if let old = extras[key] {
            extra.plan = old.plan; extra.applied = old.applied
            extra.planError = old.planError; extra.applyError = old.applyError
        }
        return extra
    }

    /// The pipelines a merge started: those of the push. Scheduled runs
    /// (drift detection and the like) land on the same commit while the
    /// branch rests, but they are not the merge's doing.
    static func mergeRuns(_ runs: [WorkflowRun]) -> [WorkflowRun] {
        let pushed = runs.filter { $0.trigger == "push" }
        if !pushed.isEmpty { return pushed }
        return runs.filter { $0.trigger != "pull_request" && $0.trigger != "schedule" }
    }

    /// The newest scheduled run of each workflow: the repository's standing
    /// checks (drift detection), shown beside a pull request's own.
    static func scheduledRuns(_ runs: [WorkflowRun]) -> [WorkflowRun] {
        var seen = Set<String>()
        return runs.filter { $0.trigger == "schedule" }.filter { seen.insert($0.workflowID ?? $0.title).inserted }
    }

    /// The Terraform summary in the logs of the finished jobs, if any. A
    /// finished job's log never changes, so each is read once.
    private func terraform(in jobs: [WorkflowJob], slug: RepoSlug, client: ForgejoClient) async -> TerraformPlan? {
        let ordered = jobs.filter(isKey) + jobs.filter { !isKey($0) }
        for job in ordered where job.state.isFinished && job.hasStarted {
            let cacheKey = "\(slug.key)#job\(job.id)"
            if let known = planCache[cacheKey] {
                if let known { return known }
                continue
            }
            guard let data = try? await client.jobLog(slug, job: job.id, from: 0) else { continue }
            // A plan's log can be megabytes: read it off the main thread.
            let plan = await Task.detached(priority: .utility) {
                var tail = LogTail()
                return TerraformPlan.parse(tail.append(data) + tail.flush())
            }.value
            planCache[cacheKey] = .some(plan)
            if let plan { return plan }
        }
        return nil
    }

    /// The error of the first failed key job (else any failed job) whose log
    /// has one. Read once per job and kept.
    private func terraformError(in jobs: [WorkflowJob], slug: RepoSlug, client: ForgejoClient) async -> [String]? {
        let failed = jobs.filter { $0.state == .failure && $0.hasStarted }
        for job in failed.filter(isKey) + failed.filter({ !isKey($0) }) {
            let cacheKey = "\(slug.key)#err\(job.id)"
            if let known = errorCache[cacheKey] {
                if !known.isEmpty { return known }
                continue
            }
            guard let data = try? await client.jobLog(slug, job: job.id, from: 0) else { continue }
            let lines = await Task.detached(priority: .utility) {
                var tail = LogTail()
                return TerraformError.extract(tail.append(data) + tail.flush())
            }.value
            errorCache[cacheKey] = lines
            if !lines.isEmpty { return lines }
        }
        return nil
    }

    /// Opens the log window for a job.
    func openLog(job: WorkflowJob, run: WorkflowRun, in repo: ForgeRepo) {
        guard let slug = slug(repo) else { return }
        logTarget = LogTarget(repo: slug, runID: run.id, jobID: job.id, title: "\(run.title) · \(job.name)", webURL: job.htmlURL)
    }

    /// Opens the log window for a run: its job that is running, else the
    /// first one that has a log.
    func openLog(run: WorkflowRun, in repo: ForgeRepo) async {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return }
        guard let jobs = try? await client.jobs(slug, run: run.id),
              let job = jobs.first(where: { isKey($0) && $0.hasStarted }) ?? jobs.first(where: { $0.state == .failure && $0.hasStarted })
                ?? jobs.first(where: { $0.state == .running && $0.hasStarted }) ?? jobs.first(where: \.hasStarted) ?? jobs.first
        else {
            if let url = run.htmlURL.flatMap(URL.init) { openExternal(url) }
            return
        }
        openLog(job: job, run: run, in: repo)
    }

    /// The Actions job a check points at.
    private func job(for check: CommitStatus, slug: RepoSlug, client: ForgejoClient) async -> (id: Int, runID: Int, web: String?)? {
        guard let reference = check.jobReference else { return nil }
        func matching(_ runs: [WorkflowRun]) -> WorkflowRun? {
            runs.first { URLComponents(string: $0.htmlURL ?? "")?.path == reference.runPath }
        }
        var run = matching(forge[slug.key]?.runs ?? [])
        if run == nil { run = matching((try? await client.runs(slug, limit: 50)) ?? []) }
        guard let run, let jobs = try? await client.jobs(slug, run: run.id), jobs.indices.contains(reference.jobIndex) else { return nil }
        let job = jobs[reference.jobIndex]
        return (job.id, run.id, job.htmlURL)
    }

    /// Opens the log of the job behind a check; a check from another CI
    /// opens in the browser.
    func openLog(for check: CommitStatus, in repo: ForgeRepo) async {
        guard let slug = slug(repo), let client = client(for: slug.host),
              let job = await job(for: check, slug: slug, client: client)
        else {
            if let url = checkURL(check, host: workspace?.host) { openExternal(url) }
            return
        }
        logTarget = LogTarget(repo: slug, runID: job.runID, jobID: job.id, title: check.context, webURL: job.web)
    }

    func checkURL(_ check: CommitStatus, host: String?) -> URL? {
        guard let target = check.targetURL, !target.isEmpty else { return nil }
        if target.hasPrefix("/"), let host { return URL(string: "https://\(host)\(target)") }
        return URL(string: target)
    }

    // MARK: - Key jobs

    func setKeyJobs(_ names: [String]) {
        keyJobs = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        defaults.set(keyJobs, forKey: Key.keyJobs)
    }

    /// A run's workflow by the name in its file ("Terraform pipeline"), or
    /// the file's name until the files have been read.
    func workflowName(_ run: WorkflowRun, in repo: ForgeRepo) -> String {
        guard let file = run.workflowID else { return run.title }
        if let key = slug(repo)?.key, let workflow = workflows[key]?.first(where: { $0.file == file }), let name = workflow.info?.name, !name.isEmpty {
            return name
        }
        return (file as NSString).deletingPathExtension
    }

    func isKey(_ job: WorkflowJob) -> Bool {
        keyJobs.contains { job.name.localizedCaseInsensitiveContains($0) }
    }

    /// The jobs to list for a pipeline: the key ones, and any other that
    /// failed or is running now. A pipeline without key jobs lists them all.
    func visibleJobs(_ jobs: [WorkflowJob]) -> (shown: [WorkflowJob], passed: Int, other: Int) {
        guard jobs.contains(where: isKey) else { return (jobs, 0, 0) }
        // A failed key job explains the failure; the wrapper job that called
        // it fails along and would only repeat it.
        let keyFailed = jobs.contains { isKey($0) && $0.state == .failure }
        let shown = jobs.filter { job in
            isKey(job) || (job.state == .failure && !keyFailed) || (job.state == .running && job.hasStarted)
        }
        let hidden = jobs.filter { job in !shown.contains { $0.id == job.id } }
        let passed = hidden.count { $0.state == .success || $0.state == .skipped }
        // Hidden failures are the wrapper's echo of a key job's failure.
        let unfinished = hidden.count { !$0.state.isFinished }
        return (shown, passed, unfinished)
    }

    // MARK: - Workflows

    func loadWorkflows(_ repo: ForgeRepo) async {
        guard let slug = slug(repo), let client = client(for: slug.host), let files = try? await client.workflowFiles(slug) else { return }
        var known = Dictionary(uniqueKeysWithValues: (workflows[slug.key] ?? []).map { ($0.path, $0) })
        var list: [Workflow] = []
        for file in files {
            var workflow = known.removeValue(forKey: file.path) ?? Workflow(file: file.name, path: file.path)
            if workflow.info == nil, let text = try? await client.fileText(slug, path: file.path) {
                workflow.info = try? await core.call("workflow.parse", WorkflowParseParams(content: text))
            }
            list.append(workflow)
        }
        if workflows[slug.key] != list { workflows[slug.key] = list }
    }

    func dispatch(_ workflow: Workflow, ref: String, inputs: [String: String], in repo: ForgeRepo) async throws {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return }
        try await client.dispatch(slug, workflow: workflow.file, ref: ref, inputs: inputs)
        try? await Task.sleep(for: .seconds(1))
        await refreshForge(repo, detailed: true)
    }

    enum RunAction { case rerun, cancel }

    func perform(_ action: RunAction, on run: WorkflowRun, in repo: ForgeRepo) async {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return }
        if action == .rerun, !supportsRerun(slug.host) { return rerunInBrowser(run.htmlURL, what: "run #\(run.number)") }
        do {
            switch action {
            case .rerun: try await client.rerun(slug, run: run.id)
            case .cancel: try await client.cancel(slug, run: run.id)
            }
            toast(action == .rerun ? "Run #\(run.number) starts again" : "Run #\(run.number) cancelled")
        } catch {
            toast(error.localizedDescription, .error)
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshForge(repo, detailed: true)
    }

    func rerun(_ job: WorkflowJob, in repo: ForgeRepo) async {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return }
        if !supportsRerun(slug.host) { return rerunInBrowser(job.htmlURL, what: job.name) }
        do {
            try await client.rerun(slug, job: job.id)
            toast("\(job.name) starts again")
        } catch {
            toast(error.localizedDescription, .error)
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshForge(repo, detailed: true)
    }

    // MARK: - Releases

    /// "INFRA-50", "ABC-1": ticket keys mentioned in commit messages.
    static func tickets(in messages: [String]) -> [String] {
        var found: [String] = []
        for message in messages {
            for match in message.matches(of: /\b[A-Z][A-Z0-9]+-[0-9]+\b/) {
                let key = String(match.output)
                // Looks like a ticket, but is a standard or an algorithm.
                let prefix = key.prefix { $0 != "-" }
                if ["UTF", "ISO", "SHA", "MD", "RFC", "CVE", "TLS", "SSL", "HTTP", "IPV", "X", "AES", "RSA"].contains(String(prefix)) { continue }
                if !found.contains(key) { found.append(key) }
            }
        }
        return found
    }

    /// What a pull request from `head` into `base` would bring, with a title
    /// and a description to start from. A release (develop into the default
    /// branch) is titled after the tickets; a feature after its first commit.
    func releaseDraft(_ repo: ForgeRepo, head: String, base: String, release: Bool = true) async throws -> ReleaseDraft {
        guard let slug = slug(repo), let client = client(for: slug.host) else { throw ForgejoClient.ForgeError.notAnswer }
        let commits = try await client.compare(slug, base: base, head: head)
        let tickets = Self.tickets(in: commits.map(\.commit.message) + (release ? [] : [head]))
        let open = (try? await client.pullRequests(slug, state: "open")) ?? []
        let existing = open.first { $0.head.ref == head && $0.base.ref == base }
        let title: String
        var body: String
        if release {
            title = tickets.isEmpty ? "chore: release \(head) into \(base)" : "chore: \(tickets.joined(separator: ", ")) release"
            body = "Release \(head) → \(base)"
        } else {
            let oldestFirst = commits.sorted { ($0.commit.author?.date ?? .distantPast) < ($1.commit.author?.date ?? .distantPast) }
            title = oldestFirst.first?.subject ?? head
            body = oldestFirst.count > 1 ? oldestFirst.map { "- \($0.subject)" }.joined(separator: "\n") : ""
        }
        if !tickets.isEmpty { body += (body.isEmpty ? "" : "\n\n") + "Tickets: \(tickets.joined(separator: ", "))" }
        return ReleaseDraft(head: head, base: base, commits: commits, tickets: tickets, title: title, body: body, existing: existing)
    }

    /// The branches the server has, the default one and develop first.
    func serverBranches(_ repo: ForgeRepo) async -> [String] {
        guard let slug = slug(repo), let client = client(for: slug.host), let names = try? await client.branches(slug) else { return [] }
        let first = [repo.defaultBranch ?? "main", "develop"]
        return names.sorted { a, b in
            let x = first.firstIndex(of: a) ?? first.count, y = first.firstIndex(of: b) ?? first.count
            return x != y ? x < y : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Opens the pull request and shows it.
    func createRelease(_ repo: ForgeRepo, head: String, base: String, title: String, body: String) async throws {
        guard let slug = slug(repo), let client = client(for: slug.host) else { return }
        let pull = try await client.createPull(slug, head: head, base: base, title: title, body: body)
        await refreshForge(repo, detailed: true)
        pendingPull = pull.number
        toast("Opened pull request #\(pull.number)")
    }

    /// Asks before something that cannot be undone.
    func confirm(title: String, message: String, button: String, destructive: Bool = false, action: @escaping () -> Void) {
        confirmation = Confirmation(title: title, message: message, button: button, destructive: destructive, action: action)
    }

    // MARK: - Inbox

    func refreshInbox() async {
        var items: [InboxItem] = []
        for account in accounts {
            guard let client = client(for: account.host) else { continue }
            guard let hits = try? await client.reviewRequests() else {
                // Unreachable: keep what was known rather than an empty inbox.
                items += inbox.filter { $0.host == account.host }
                continue
            }
            items += hits.map { InboxItem(host: account.host, hit: $0) }
        }
        let sorted = items.sorted { ($0.hit.updatedAt ?? .distantPast) > ($1.hit.updatedAt ?? .distantPast) }
        if inbox != sorted { inbox = sorted }
        await refreshNotifications()
        await refreshJira()
    }

    /// Shows a pull request from the Inbox in its repository.
    func open(_ item: InboxItem) async {
        guard let fullName = item.hit.repository?.fullName else { return }
        await openPull(host: item.host, fullName: fullName, number: item.hit.number, url: item.hit.htmlURL)
    }

    /// Shows a pull request of any repository the account sees: switches to
    /// its workspace and repository first. Falls back to the browser.
    func openPull(host: String, fullName: String, number: Int?, url: String?) async {
        guard let owner = fullName.split(separator: "/").first.map(String.init) else { return }
        if workspace?.host != host || workspace?.owner.lowercased() != owner.lowercased() {
            guard let target = workspaces.first(where: { $0.host == host && $0.owner.lowercased() == owner.lowercased() })
                ?? workspaces.first(where: { $0.host == host && $0.personal })
            else {
                if let url = url.flatMap(URL.init) { openExternal(url) }
                return
            }
            workspace = target
            defaults.set(try? JSONEncoder().encode(target), forKey: Key.workspace)
            repos = []
            await loadRepos(quiet: false)
        }
        guard let repo = repos.first(where: { $0.fullName.lowercased() == fullName.lowercased() }) else {
            if let url = url.flatMap(URL.init) { openExternal(url) }
            return
        }
        pendingPull = number
        selection = repo.id
        section = .repositories
        await refreshSelected()
    }
}
