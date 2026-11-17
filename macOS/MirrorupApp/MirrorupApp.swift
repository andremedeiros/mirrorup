import AppKit
import SwiftUI

enum WindowID: String {
    case cameraInfo, diagnostics
}

@main
struct MirrorupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.menuBarIcon.rawValue)
                .accessibilityLabel("Mirrorup")
                .accessibilityValue(appDelegate.model.menuBarIcon.accessibilityValue)
        }
        .menuBarExtraStyle(.window)

        Window("Camera Info", id: WindowID.cameraInfo.rawValue) {
            CameraInfoView(model: appDelegate.model)
        }
        .defaultSize(width: 480, height: 640)

        Window("Mirrorup Diagnostics", id: WindowID.diagnostics.rawValue) {
            DiagnosticsView(model: appDelegate.model)
        }
        .defaultSize(width: 520, height: 640)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        PopoverSnapshot.scheduleIfRequested(model: model)
        #endif
    }

    /// Releases the camera (leaves live view) and the virtual-camera sink before quitting, so the
    /// camera is immediately usable by other apps.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateLater }
        isShuttingDown = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
