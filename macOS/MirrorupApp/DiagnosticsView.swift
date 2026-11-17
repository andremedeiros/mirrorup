import AppKit
import AVFoundation
import MirrorupCapture
import MirrorupDiagnostics
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    let model: AppModel
    @State private var exportMessage: String?
    @State private var isExporting = false

    var body: some View {
        let status = model.status
        let metrics = status.metrics
        Form {
            Section("Capture") {
                row("State", stateDescription(status.state))
                row("Camera", status.camera?.description ?? "None")
                row("Source resolution", resolution(metrics))
                row("Camera FPS", String(format: "%.1f", metrics.cameraFPS))
                row("Delivered FPS", String(format: "%.1f", metrics.deliveredFPS))
                row("Frame age p50 / p95", frameAge(metrics.frameAgeAtDelivery))
                row("Frames dropped", "\(metrics.framesDropped)")
                row("Invalid frames", "\(metrics.invalidFrames)")
                row("Reconnects", "\(status.reconnectCount)")
                if let error = status.lastRecoverableError {
                    row("Last recoverable error", UserFacingText.message(for: error))
                    row("Error detail", error.detail ?? "—")
                }
            }
            Section("Virtual camera") {
                row("Extension", model.extensionManager.state.summary)
                if case let .failed(_, detail) = model.extensionManager.state {
                    row("Extension error detail", detail)
                }
                row("Sink", UserFacingText.sink(model.sinkState))
                if case let .failed(_, detail) = model.sinkState {
                    row("Sink error detail", detail)
                }
                row("Frames sent / dropped (queue full)", "\(model.sinkCounters.enqueued) / \(model.sinkCounters.droppedQueueFull)")
            }
            Section("Process") {
                row("CPU", model.resources.map { String(format: "%.1f %%", $0.cpuPercent) } ?? "—")
                row("Memory", model.resources.map { ByteCountFormatter.string(fromByteCount: Int64($0.memoryBytes), countStyle: .memory) } ?? "—")
            }
            Section {
                HStack {
                    Button("Export Diagnostics…") { export() }
                        .disabled(isExporting)
                    if let exportMessage {
                        Text(exportMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 520)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private func stateDescription(_ state: CaptureState) -> String {
        guard model.wantsStreaming else { return "Stopped" }
        return switch state {
        case let .recovering(attempt, reason): "Reconnecting (attempt \(attempt)): \(reason)"
        case let .failed(error): "Failed: \(error.message)"
        default: UserFacingText.headline(for: state)
        }
    }

    private func resolution(_ metrics: FrameMetrics.Snapshot) -> String {
        guard let width = metrics.sourceWidth, let height = metrics.sourceHeight else { return "—" }
        return "\(width) × \(height)"
    }

    private func frameAge(_ summary: SampleWindow.Summary?) -> String {
        guard let summary else { return "—" }
        let p95 = summary.hasTailPercentiles ? String(format: "%.1f", summary.p95) : "—"
        return String(format: "%.1f / %@ ms", summary.p50, p95)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Mirrorup Diagnostics \(Date().formatted(.iso8601.year().month().day())).txt"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = DiagnosticsReport.Snapshot(
            wantsStreaming: model.wantsStreaming,
            source: model.source,
            status: model.status,
            extensionState: model.extensionManager.state.summary,
            sinkState: model.sinkState,
            sinkCounters: model.sinkCounters,
            cameraAccess: Self.describe(model.cameraAccess),
            cpuPercent: model.resources?.cpuPercent,
            memoryBytes: model.resources?.memoryBytes
        )
        isExporting = true
        exportMessage = "Exporting…"
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
                Result { try DiagnosticsReport.make(snapshot).write(to: url, atomically: true, encoding: .utf8) }
            }.value
            isExporting = false
            switch result {
            case .success: exportMessage = "Saved \(url.lastPathComponent)"
            case let .failure(error): exportMessage = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }
}
