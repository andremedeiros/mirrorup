import Foundation
import Observation
import Sparkle

/// App updates through Sparkle, from the appcast each GitHub release carries (`SUFeedURL` in
/// project.yml). Sparkle checks daily and offers an update; installing it always takes the user's
/// click, then Sparkle replaces the app and relaunches it. The relaunched app replaces the Camera
/// Extension only if the update changed its version.
///
/// Debug builds never start the updater: they would offer to replace themselves with the latest
/// release.
@MainActor @Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    /// False while a check or an update is in progress, and in debug builds.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        #if !DEBUG
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
        }
        #endif
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// A menu-bar app has no Dock icon to badge and is rarely frontmost: let Sparkle show scheduled
    /// update alerts without stealing focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
