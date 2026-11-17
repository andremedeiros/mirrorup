import AppKit
import AVFoundation
import SwiftUI

/// The menu-bar popover: the live preview, one switch, a problem line only when something needs the
/// user, and a single ⋯ menu for everything else.
struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            LivePreview(model: model, phase: model.phase)
            CameraHeader(
                name: model.cameraName,
                summary: model.phase == .live ? model.cameraSummary : nil,
                phase: model.phase,
                isStreaming: $model.isStreaming
            )
            AttentionView(model: model)
            Divider()
            MenuFooter(isAvailable: model.isVirtualCameraAvailable)
        }
        .padding()
        .frame(width: 340)
        // Opening the popover is the user asking what the camera is doing.
        .task { await model.refreshCameraInfo() }
    }
}

// MARK: - Preview

private struct LivePreview: View {
    let model: AppModel
    let phase: AppModel.Phase

    var body: some View {
        PreviewView(renderer: model.preview)
            .overlay {
                if phase != .live {
                    PreviewPlaceholder(phase: phase)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if phase == .live {
                    LiveBadge(model: model)
                        .padding(8)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Camera preview")
    }
}

private struct PreviewPlaceholder: View {
    let phase: AppModel.Phase

    var body: some View {
        VStack(spacing: 8) {
            switch phase {
            case .off:
                Image(systemName: "video.slash").font(.title)
                Text("Camera off")
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting to camera…")
            case .reconnecting(let reason):
                ProgressView().controlSize(.small)
                Text("Reconnecting…")
                if let reason {
                    Text(reason).font(.caption).multilineTextAlignment(.center)
                }
            case .unavailable(let message):
                Image(systemName: "exclamationmark.triangle").font(.title)
                Text(message).font(.callout).multilineTextAlignment(.center)
            case .live:
                EmptyView()
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

/// Reads the 4 Hz metrics itself so only this badge re-renders, not the popover.
private struct LiveBadge: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Text("Live · \(model.status.metrics.cameraFPS, format: .number.precision(.fractionLength(0))) fps")
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: .capsule)
    }
}

// MARK: - Header

private struct CameraHeader: View {
    let name: String?
    let summary: String?
    let phase: AppModel.Phase
    @Binding var isStreaming: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? "Mirrorup")
                    .font(.headline)
                    .lineLimit(1)
                Text(summary ?? phase.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("Stream", isOn: $isStreaming)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Stream camera")
        }
    }
}

private extension AppModel.Phase {
    var caption: String {
        switch self {
        case .off: "Streaming is off"
        case .connecting: "Connecting…"
        case .live: "Streaming"
        case .reconnecting: "Reconnecting…"
        case .unavailable: "Camera unavailable"
        }
    }
}

// MARK: - Attention

/// At most one problem, with the one action that fixes it. Camera errors are shown on the preview.
private struct AttentionView: View {
    let model: AppModel

    var body: some View {
        if let attention = Attention(cameraAccess: model.cameraAccess, extensionState: model.extensionManager.state) {
            VStack(alignment: .leading, spacing: 8) {
                Label(attention.message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = attention.action {
                    Button(action.title) { perform(action) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func perform(_ action: Attention.Action) {
        switch action {
        case .openCameraPrivacySettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        case .openExtensionSettings:
            model.extensionManager.openApprovalSettings()
        case .installExtension:
            model.extensionManager.activate()
        }
    }
}

private struct Attention {
    enum Action {
        case openCameraPrivacySettings, openExtensionSettings, installExtension

        var title: String {
            switch self {
            case .openCameraPrivacySettings: "Open Privacy Settings"
            case .openExtensionSettings: "Open System Settings"
            case .installExtension: "Install Camera Extension"
            }
        }
    }

    let message: String
    let action: Action?

    init?(cameraAccess: AVAuthorizationStatus, extensionState: ExtensionManager.State) {
        if cameraAccess == .denied || cameraAccess == .restricted {
            message = "Mirrorup needs camera access to publish the Mirrorup Camera."
            action = .openCameraPrivacySettings
            return
        }
        switch extensionState {
        case .awaitingApproval:
            message = "Allow the Mirrorup camera extension so other apps can use it."
            action = .openExtensionSettings
        case .notInstalled:
            message = "The Mirrorup Camera isn't installed yet."
            action = .installExtension
        case .failed(let failure, _):
            message = failure
            action = .installExtension
        case .rebootRequired:
            message = "Restart your Mac to finish installing the Mirrorup Camera."
            action = nil
        case .blockedByPolicy:
            // Installing again can't help: an administrator has to allow the extension.
            message = "Your organization's device management blocks the Mirrorup Camera. Ask your administrator to allow it."
            action = nil
        case .checking, .activating, .active, .deactivating:
            return nil
        }
    }
}

// MARK: - Footer

private struct MenuFooter: View {
    let isAvailable: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Label {
                Text(isAvailable ? "Available as “Mirrorup Camera”" : "Mirrorup Camera unavailable")
            } icon: {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isAvailable ? .green : .secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Button("Camera Info…") { show(.cameraInfo) }
                Button("Diagnostics…") { show(.diagnostics) }
                Divider()
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                .keyboardShortcut(",")
                Divider()
                Button("Quit Mirrorup") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func show(_ window: WindowID) {
        openWindow(id: window.rawValue)
        // Menu-bar (LSUIElement) apps are not frontmost; bring the window forward.
        NSApp.activate()
    }
}
