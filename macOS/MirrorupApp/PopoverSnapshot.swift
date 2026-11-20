#if DEBUG
import AppKit
import MirrorupDiagnostics
import SwiftUI

/// Debug builds only: renders the popover offscreen, with the live model, to a PNG, so layout can be
/// checked without screen-recording permission. The video preview layer is not captured (it draws
/// outside the view's backing store); everything else is.
///
///     open /Applications/Mirrorup.app --args -MirrorupSnapshotPopover /tmp/popover.png
///
/// The snapshot is taken 8 s after launch, once streaming and the control state have settled.
/// `-MirrorupSnapshotDelay <seconds>` (at least 2) takes it later or earlier, e.g. to catch a
/// camera that is still preparing.
enum PopoverSnapshot {
    static let argument = "MirrorupSnapshotPopover"
    static let delayArgument = "MirrorupSnapshotDelay"

    @MainActor
    static func scheduleIfRequested(model: AppModel, updater: Updater) {
        guard let path = UserDefaults.standard.string(forKey: argument) else { return }
        let requested = UserDefaults.standard.double(forKey: delayArgument)
        let delay = requested >= 2 ? requested : 8
        Diagnostics.app.notice("Popover snapshot scheduled in \(delay, privacy: .public) s: \(path, privacy: .public)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay - 2))
            await model.refreshCameraInfo()
            await model.refreshControls()
            try? await Task.sleep(for: .seconds(2))
            write(MenuView(model: model, updater: updater), to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    private static func write(_ view: some View, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSApp.effectiveAppearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Diagnostics.app.error("Popover snapshot failed: no bitmap for \(host.bounds.debugDescription, privacy: .public)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            Diagnostics.app.notice("Popover snapshot written to \(url.path, privacy: .public)")
        } catch {
            Diagnostics.app.error("Popover snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
        window.contentView = nil
    }
}
#endif
