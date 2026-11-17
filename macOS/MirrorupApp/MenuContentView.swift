import AppKit
import SwiftUI

/// The menu-bar popover: status at a glance plus the controls used day to day.
struct MenuContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { model.wantsStreaming }, set: { model.setStreaming($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mirrorup").font(.headline)
                    Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let explanation = model.explanation {
                Label(explanation, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let access = model.cameraAccessMessage {
                Label(access, systemImage: "lock")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Source", selection: $model.source) {
                ForEach(CameraSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }

            VirtualCameraStatusView(model: model)

            Divider()

            HStack {
                Button("Preview") { show(WindowID.preview) }
                Button("Diagnostics") { show(WindowID.diagnostics) }
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var statusLine: String {
        guard model.wantsStreaming, let camera = model.status.camera else { return model.headline }
        return "\(model.headline) · \(camera.name)"
    }

    private func show(_ id: String) {
        openWindow(id: id)
        // Menu-bar (LSUIElement) apps are not frontmost; bring the new window forward.
        NSApp.activate()
    }
}

/// Extension + sink status with the action that fixes the most likely problem.
struct VirtualCameraStatusView: View {
    let model: AppModel

    var body: some View {
        let manager = model.extensionManager
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(manager.state == .active ? UserFacingText.sink(model.sinkState) : "Camera extension: \(manager.state.summary)")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: model.sinkState == .connected ? "checkmark.circle.fill" : "camera.badge.ellipsis")
                    .foregroundStyle(model.sinkState == .connected ? .green : .secondary)
            }
            .font(.callout)

            switch manager.state {
            case .notInstalled, .failed:
                Button("Install Camera Extension") { manager.activate() }
            case .awaitingApproval:
                Text(ExtensionManager.approvalInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { manager.openApprovalSettings() }
            default:
                EmptyView()
            }
        }
    }
}
