import AppKit
import SwiftUI

enum WindowID {
    static let preview = "preview"
    static let diagnostics = "diagnostics"
}

@main
struct MirrorupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.menuBarSymbol)
                .accessibilityLabel("Mirrorup")
        }
        .menuBarExtraStyle(.window)

        Window("Mirrorup Preview", id: WindowID.preview) {
            PreviewWindowContent(model: appDelegate.model)
        }
        .defaultSize(width: 640, height: 400)

        Window("Mirrorup Diagnostics", id: WindowID.diagnostics) {
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

private struct PreviewWindowContent: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(renderer: model.preview)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(minWidth: 320, minHeight: 180)
            HStack {
                Text(model.headline)
                Spacer()
                if model.wantsStreaming {
                    Text(String(format: "Camera %.1f fps", model.status.metrics.cameraFPS))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }
}
