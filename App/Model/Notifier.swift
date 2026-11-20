import AppKit
import Foundation
import OSLog
import UserNotifications

/// What macOS lets GitNest View show. Notifications turned off there are
/// thrown away by the system without a word, so the app says so itself.
enum NotificationAccess: Equatable, Sendable {
    case unknown, allowed, notAsked, off
}

/// macOS notifications: someone asks for the user's review, or a pipeline
/// of the user's own pull request fails. A click opens the pull request.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var model: AppModel?
    private var asked = false
    /// Where notifications go; tests collect them instead of showing them.
    var deliver: (@MainActor (UNNotificationRequest) -> Void)?

    /// Under tests and in development launches, the app neither asks for
    /// permission nor shows anything: no system prompt may appear there.
    static let quiet: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["GNV_DEV_HOST"] != nil
    }()

    private let log = Logger(subsystem: "pl.paksonite.gitnest-view", category: "notifications")

    func start(_ model: AppModel) {
        self.model = model
        if Self.quiet {
            // Development launches can show either state without asking macOS.
            switch ProcessInfo.processInfo.environment["GNV_DEV_NOTIFICATIONS"] {
            case "off": model.notificationAccess = .off
            case "on": model.notificationAccess = .allowed
            default: break
            }
            return
        }
        UNUserNotificationCenter.current().delegate = self
        // Back from System Settings: the switch there may have been turned.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await Notifier.shared.refreshAccess() }
        }
        Task { await refreshAccess() }
    }

    /// Reads what macOS allows now.
    func refreshAccess() async {
        guard !Self.quiet else { return }
        let access = await Self.currentAccess()
        if model?.notificationAccess != access { model?.notificationAccess = access }
    }

    /// Read off the main actor: the settings object itself may not cross over.
    private nonisolated static func currentAccess() async -> NotificationAccess {
        await withCheckedContinuation { done in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let access: NotificationAccess = switch settings.authorizationStatus {
                case .authorized, .provisional: settings.alertSetting == .disabled && settings.notificationCenterSetting == .disabled ? .off : .allowed
                case .notDetermined: .notAsked
                default: .off
                }
                done.resume(returning: access)
            }
        }
    }

    /// Asks once for permission; macOS remembers the answer. `again` asks
    /// even when this launch already did (the user's button in Settings).
    func requestAccess(again: Bool = false) {
        guard !asked || again, !Self.quiet else { return }
        asked = true
        // The async form: macOS answers on a queue of its own, and a callback
        // made here would be bound to the main actor and stop the app there.
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                // Turned off in System Settings: macOS refuses without asking.
                log.error("Notifications not allowed: \(error.localizedDescription, privacy: .public)")
            }
            await refreshAccess()
        }
    }

    /// System Settings → Notifications, on GitNest View's page.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "pl.paksonite.gitnest-view"
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    /// One notification now, to see that they reach the screen.
    func postTest() {
        let content = UNMutableNotificationContent()
        content.title = "GitNest View"
        content.body = "Notifications reach you: approvals, review requests, failed pipelines and Jira news will look like this."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "test:\(Date.now.timeIntervalSince1970)", content: content, trigger: nil)
        if let deliver {
            deliver(request)
        } else if !Self.quiet {
            add(request)
        }
    }

    /// Hands a notification to macOS; a refusal is written to the log and
    /// read back as the current access, so the app can say why none came.
    private func add(_ request: UNNotificationRequest) {
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                log.error("Notification refused: \(error.localizedDescription, privacy: .public)")
            }
            await refreshAccess()
        }
    }

    func post(id: String, title: String, body: String, host: String, fullName: String, number: Int, url: String?) {
        // A muted server still fills the Inbox; it just does not interrupt.
        if model?.isMuted(host) == true { return }
        let content = UNMutableNotificationContent()
        content.title = title
        // Which server: with several connected, a title alone is half a fact.
        content.subtitle = host
        content.body = body
        content.sound = .default
        content.threadIdentifier = "\(host)/\(fullName)"
        content.userInfo = ["host": host, "fullName": fullName, "number": number, "url": url ?? ""]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if let deliver {
            deliver(request)
        } else if !Self.quiet {
            add(request)
        }
    }

    /// News about a Jira ticket; a click opens the ticket in the app.
    func postTicket(id: String, title: String, body: String, key: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = "Jira"
        content.body = body
        content.sound = .default
        content.threadIdentifier = "jira"
        content.userInfo = ["jira": key]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if let deliver {
            deliver(request)
        } else if !Self.quiet {
            add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let key = info["jira"] as? String {
            await MainActor.run {
                NSApp.activate()
                guard let model = self.model else { return }
                if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) { model.openMainWindow?() }
                model.section = .home
                model.ticketTarget = key
            }
            return
        }
        guard let host = info["host"] as? String, let fullName = info["fullName"] as? String else { return }
        let number = (info["number"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        let url = info["url"] as? String
        await MainActor.run {
            NSApp.activate()
            guard let model = self.model else { return }
            if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) { model.openMainWindow?() }
            Task { await model.openPull(host: host, fullName: fullName, number: number, url: url) }
        }
    }
}

extension AppModel {
    /// Reads review requests and the user's own pull requests, and tells
    /// the user about what is new. Runs in the background too, every two
    /// minutes. What was already announced is remembered across launches;
    /// the very first run only remembers.
    func checkForNews() async {
        let before = myPulls
        lastNews = .now
        await refreshInbox()
        await refreshMyPulls()
        var seen = Set(defaults.stringArray(forKey: "notified") ?? [])
        let firstRun = defaults.object(forKey: "notified") == nil
        var fresh: [String] = []

        if notifyMyPulls {
            // What reviewers did to the user's own pull requests.
            for pull in myPulls {
                if pull.approvals > 0 {
                    let key = "approved:\(pull.id)@\(pull.approvals)"
                    if !seen.contains(key) {
                        fresh.append(key)
                        if !firstRun {
                            Notifier.shared.post(id: key, title: pull.ready ? "Approved, ready to merge · \(pull.repoFullName)" : "Approved · \(pull.repoFullName)",
                                                 body: "#\(pull.number) \(pull.title)\(pull.approvals > 1 ? " — \(pull.approvals) approvals" : "")",
                                                 host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL)
                        }
                    }
                }
                if pull.changesRequested {
                    let key = "changes:\(pull.id)@\(pull.headSHA)"
                    if !seen.contains(key) {
                        fresh.append(key)
                        if !firstRun {
                            Notifier.shared.post(id: key, title: "Changes requested · \(pull.repoFullName)", body: "#\(pull.number) \(pull.title)",
                                                 host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL)
                        }
                    }
                }
            }
            // Gone from the open ones: merged (by someone) or closed.
            if !firstRun {
                let open = Set(myPulls.map(\.id))
                for pull in before where !open.contains(pull.id) {
                    guard let slug = Self.slug(host: pull.host, fullName: pull.repoFullName), let client = client(for: pull.host),
                          let now = try? await client.pullRequest(slug, number: pull.number), now.state != "open" else { continue }
                    let key = "closed:\(pull.id)"
                    guard !seen.contains(key) else { continue }
                    fresh.append(key)
                    Notifier.shared.post(id: key, title: now.merged == true ? "Merged · \(pull.repoFullName)" : "Closed · \(pull.repoFullName)",
                                         body: "#\(pull.number) \(pull.title)", host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL)
                }
            }
        }

        if notifyReviews {
            for item in inbox {
                let key = "review:\(item.id)"
                guard !seen.contains(key) else { continue }
                fresh.append(key)
                guard !firstRun, let repo = item.hit.repository?.fullName else { continue }
                Notifier.shared.post(id: key, title: "Review requested · \(repo)",
                                     body: "\(item.hit.user?.login ?? "Someone") asks for your review: \(item.hit.title)",
                                     host: item.host, fullName: repo, number: item.hit.number, url: item.hit.htmlURL)
            }
        }
        if notifyFailures {
            for pull in myPulls where pull.state == .failure {
                let key = "fail:\(pull.id)@\(pull.headSHA)"
                guard !seen.contains(key) else { continue }
                fresh.append(key)
                guard !firstRun else { continue }
                Notifier.shared.post(id: key, title: "Pipeline failed · \(pull.repoFullName)",
                                     body: "#\(pull.number) \(pull.title)",
                                     host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL)
            }
        }
        if notifyFailures, let host = workspace?.host {
            // Drift detection and other scheduled workflows: once per failed run.
            for repo in repos {
                for run in Self.scheduledRuns(forgeState(repo).runs) where run.state == .failure {
                    let key = "sched:\(host)/\(repo.fullName)#\(run.id)"
                    guard !seen.contains(key) else { continue }
                    fresh.append(key)
                    guard !firstRun else { continue }
                    Notifier.shared.post(id: key, title: "\(workflowName(run, in: repo)) · \(repo.name)",
                                         body: "The scheduled run reports a problem on \(run.prettyRef ?? repo.defaultBranch ?? "main").",
                                         host: host, fullName: repo.fullName, number: 0, url: run.htmlURL)
                }
            }
        }
        updateDockBadge()
        if firstRun || !fresh.isEmpty {
            seen.formUnion(fresh)
            defaults.set(Array(seen.suffix(800)), forKey: "notified")
        }
    }

    var notifyMyPulls: Bool {
        get { _ = settingsRevision; return defaults.object(forKey: "notifyMyPulls") as? Bool ?? true }
        set { guard newValue != notifyMyPulls else { return }; defaults.set(newValue, forKey: "notifyMyPulls"); settingsRevision += 1 }
    }

    var notifyReviews: Bool {
        get { _ = settingsRevision; return defaults.object(forKey: "notifyReviews") as? Bool ?? true }
        set { guard newValue != notifyReviews else { return }; defaults.set(newValue, forKey: "notifyReviews"); settingsRevision += 1 }
    }

    var notifyFailures: Bool {
        get { _ = settingsRevision; return defaults.object(forKey: "notifyFailures") as? Bool ?? true }
        set { guard newValue != notifyFailures else { return }; defaults.set(newValue, forKey: "notifyFailures"); settingsRevision += 1 }
    }

    var showInMenuBar: Bool {
        get { _ = settingsRevision; return defaults.object(forKey: "showInMenuBar") as? Bool ?? true }
        set { guard newValue != showInMenuBar else { return }; defaults.set(newValue, forKey: "showInMenuBar"); settingsRevision += 1 }
    }

    var backgroundFetch: Bool {
        get { _ = settingsRevision; return defaults.object(forKey: "backgroundFetch") as? Bool ?? true }
        set { guard newValue != backgroundFetch else { return }; defaults.set(newValue, forKey: "backgroundFetch"); settingsRevision += 1 }
    }
}

extension AppModel {
    /// The Dock icon counts what waits for the user: reviews and failing
    /// pull requests of theirs.
    func updateDockBadge() {
        let count = inbox.count + myPulls.filter { $0.state == .failure }.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
