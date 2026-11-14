import AppKit
import Combine
import Sparkle

/// In-app updates via Sparkle. Owns the single updater controller and republishes the bits the UI binds to.
///
/// Wickbar is an accessory (menu-bar) app, so a scheduled check that finds an update while the user is busy
/// elsewhere is surfaced as a row in the popover ("gentle reminder") instead of an alert ordered behind other apps.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// User default that overrides the appcast URL, for testing updates against a local feed.
    /// EdDSA signatures are still verified against `SUPublicEDKey`, so this can't install unsigned builds.
    static let feedOverrideDefaultsKey = "WickbarUpdateFeedURL"

    /// False when running outside an .app bundle (`swift run`, tests): Sparkle needs Info.plist keys and a
    /// bundle to replace, and dev runs shouldn't hit the network.
    let isAvailable: Bool
    @Published private(set) var canCheckForUpdates = false
    /// Version of an update found by a scheduled check that Sparkle left for us to present.
    @Published private(set) var pendingUpdateVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let bundle = Bundle.main
        isAvailable = bundle.bundleURL.pathExtension == "app"
            && bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        super.init()
    }

    /// Call once from applicationDidFinishLaunching. Delegates are weak in Sparkle; AppDelegate keeps `self` alive.
    func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        observations.append(controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // The KVO closure isn't actor-isolated, but SPUUpdater only changes this on the main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        })
        controller.startUpdater()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Bound to the Settings toggle. Sparkle persists this in user defaults itself.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// User-initiated check. If an update is already pending this brings its alert to the front instead.
    func checkForUpdates() {
        guard let controller else { return }
        // Accessory apps aren't active when the popover button is clicked; without this the alert can open behind.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let s = UserDefaults.standard.string(forKey: Updater.feedOverrideDefaultsKey), !s.isEmpty else { return nil }
        return s
    }
}

// Sparkle calls the user driver delegate on the main thread, but the protocol isn't annotated as such.
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show the alert itself only when it would put it in front (e.g. right after launch);
    /// otherwise we show the popover row and wait for the user to ask.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { pendingUpdateVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }
}
