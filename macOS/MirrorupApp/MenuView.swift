import AppKit
import AVFoundation
import SwiftUI

/// The menu-bar popover: the live preview, one switch, a problem line only when something needs the
/// user, and a single ⋯ menu for everything else.
struct MenuView: View {
    @Bindable var model: AppModel
    @State private var refreshedOnce = false

    var body: some View {
        let attention = Attention(cameraAccess: model.cameraAccess, extensionState: model.extensionManager.state)
        VStack(alignment: .leading, spacing: 12) {
            LivePreview(model: model, phase: model.phase)
            CameraHeader(
                name: model.cameraName,
                summary: model.phase == .live ? model.cameraSummary : nil,
                phase: model.phase,
                isStreaming: $model.isStreaming
            )
            if model.phase == .live {
                CameraControlsView(model: model)
            }
            // A problem the user can fix gets its own block with the button; one they can't is just
            // the footer's status line, so the popover never states the same thing twice.
            if let attention, attention.action != nil {
                AttentionView(attention: attention, extensionManager: model.extensionManager)
            }
            Divider()
            MenuFooter(status: MenuFooter.Status(attention: attention, isAvailable: model.isVirtualCameraAvailable, name: model.virtualCameraName))
        }
        .padding(14)
        .frame(width: 340)
        // The default glass lets whatever is behind the menu bar show through the labels.
        .containerBackground(.thickMaterial, for: .window)
        // Opening the popover is the user asking what the camera is doing; while it stays open, a
        // setting changed on the camera (mode dial, exposure) is re-read, a burst coalesced into one read.
        .task(id: model.settingsRevision) {
            if refreshedOnce {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            } else {
                refreshedOnce = true
                model.refreshSystemPermissions()
            }
            await model.refreshCameraInfo()
            await model.refreshControls()
        }
        .onDisappear { refreshedOnce = false }
    }
}

// MARK: - Preview

private struct LivePreview: View {
    let model: AppModel
    let phase: AppModel.Phase
    @State private var size = CGSize.zero

    var body: some View {
        PreviewView(renderer: model.preview)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay {
                // Clicks are taken by a SwiftUI layer: the AppKit preview view underneath ignores them.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { location in
                        guard phase == .live, size.width > 0, size.height > 0 else { return }
                        model.previewClicked(at: CGPoint(x: location.x / size.width, y: location.y / size.height))
                    }
            }
            .overlay {
                if phase == .live, let feedback = model.focusFeedback {
                    // A new attempt is a new indicator: it starts pulsing again at its own point.
                    FocusIndicator(feedback: feedback, size: size)
                        .id(feedback.id)
                }
            }
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
            .overlay(alignment: .bottomTrailing) {
                if phase == .live, model.controlState?.battery != nil {
                    BatteryLabel(state: model.controlState)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(8)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            // Keep the children readable: the placeholder carries the only camera-error text.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Camera preview")
    }
}

/// A focus square where the user clicked (none for the Focus button) and a short status pill.
/// White while focusing, green on a lock, yellow when the camera couldn't lock.
private struct FocusIndicator: View {
    let feedback: AppModel.FocusFeedback
    let size: CGSize
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch feedback.state {
        case .focusing, .unconfirmed: .white
        case .focused: .green
        case .notFocused, .failed: .yellow
        }
    }

    private var status: String? {
        switch feedback.state {
        case .focusing: "Focusing…"
        case .focused: "Focused"
        case .notFocused: "Couldn't focus"
        case .unconfirmed: "Focus done"
        case .failed: nil  // the error appears under the controls
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let point = feedback.point {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color, lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .frame(width: 44, height: 44)
                    .scaleEffect(feedback.state == .focusing && pulse ? 0.85 : 1)
                    .position(x: point.x * size.width, y: point.y * size.height)
            }
            if let status {
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(.top, 8)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: feedback.state)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement()
        .accessibilityLabel(status ?? "")
        .accessibilityHidden(status == nil)
        .onChange(of: feedback.state) {
            if let status, feedback.state != .focusing { AccessibilityNotification.Announcement(status).post() }
        }
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? "Mirrorup")
                    .font(.headline)
                    .lineLimit(1)
                Text(summary ?? phase.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
    let attention: Attention
    let extensionManager: ExtensionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(attention.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            if let action = attention.action {
                Button(action.title) { perform(action) }
                    .controlSize(.small)
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
            extensionManager.openApprovalSettings()
        case .installExtension:
            extensionManager.activate()
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
    /// One line for the footer, for problems without an action.
    let shortMessage: String
    let action: Action?

    init?(cameraAccess: AVAuthorizationStatus, extensionState: ExtensionManager.State) {
        if cameraAccess == .denied || cameraAccess == .restricted {
            message = "Mirrorup needs camera access to publish the Mirrorup Camera."
            shortMessage = "Camera access needed"
            action = .openCameraPrivacySettings
            return
        }
        switch extensionState {
        case .awaitingApproval:
            message = "Allow the Mirrorup camera extension so other apps can use it."
            shortMessage = "Extension awaiting approval"
            action = .openExtensionSettings
        case .notInstalled:
            message = "The Mirrorup Camera isn't installed yet."
            shortMessage = "Mirrorup Camera not installed"
            action = .installExtension
        case .failed(let failure, _):
            message = failure
            shortMessage = "Camera extension failed"
            action = .installExtension
        case .rebootRequired:
            message = "Restart your Mac to finish installing the Mirrorup Camera."
            shortMessage = "Restart to finish installing"
            action = nil
        case .blockedByPolicy:
            // Installing again can't help: an administrator has to allow the extension.
            message = "Your organization's device management blocks the Mirrorup Camera. Ask your administrator to allow it."
            shortMessage = "Blocked by device management"
            action = nil
        case .checking, .activating, .active, .deactivating:
            return nil
        }
    }
}

// MARK: - Footer

private struct MenuFooter: View {
    struct Status {
        let text: String
        let symbol: String
        let color: Color
        /// The full explanation, as a tooltip.
        let help: String?

        /// Nil when the attention block above already explains the state.
        init?(attention: Attention?, isAvailable: Bool, name: String) {
            if let attention {
                guard attention.action == nil else { return nil }
                (text, symbol, color, help) = (attention.shortMessage, "exclamationmark.triangle.fill", .orange, attention.message)
            } else if isAvailable {
                (text, symbol, color, help) = ("Available as “\(name)”", "checkmark.circle.fill", .green, nil)
            } else {
                (text, symbol, color, help) = ("Mirrorup Camera unavailable", "circle.dashed", .secondary, nil)
            }
        }
    }

    let status: Status?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            if let status {
                Label {
                    Text(status.text)
                } icon: {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.color)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(status.help ?? "")
            }

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
