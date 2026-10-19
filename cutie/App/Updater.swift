import AppKit
import Observation
import Sparkle

/// Optional updates through Sparkle. Automatic checks are off until the person
/// turns them on (Settings or the welcome window); "Check for Updates…" works
/// either way. A build without a feed and key (a fresh clone, the Dev build,
/// the tests) offers no updates at all.
///
/// When a scheduled check finds a version while Cutie isn't in front (it rarely
/// is: it lives in the menu bar), nothing pops up: the menu's item turns into
/// "Update to …" until the person looks (Sparkle's gentle reminders).
@Observable
final class Updater {
    var automaticChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    /// A version a background check found and is waiting to show.
    private(set) var waitingVersion: String?

    var isAvailable: Bool { controller != nil }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let reminders = GentleReminders()

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        if !feed.isEmpty, !key.isEmpty, !AppIdentity.isDev, !AppIdentity.isRunningTests {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: reminders)
        }
        automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        reminders.onWaiting = { [weak self] version in self?.waitingVersion = version }
    }

    func checkForUpdates() {
        waitingVersion = nil
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle's user driver asks before showing a scheduled update; a menu bar
/// app answers "not now" unless it's in front, and offers it in the menu instead.
private final class GentleReminders: NSObject, SPUStandardUserDriverDelegate {
    var onWaiting: (String?) -> Void = { _ in }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { onWaiting(update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onWaiting(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onWaiting(nil)
    }
}
