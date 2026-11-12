import AppKit
import Sparkle

/// Updates through Sparkle: the feed is the appcast of the latest GitHub
/// release, signed with the GitNest View EdDSA key (SUPublicEDKey).
@MainActor
final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// Started once at launch; not under tests or development launches,
    /// which must not talk to GitHub or show update windows.
    func start() {
        guard controller == nil, !Notifier.quiet else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        start()
        controller?.checkForUpdates(nil)
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? !Notifier.quiet }
}
