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
                MetricRow(title: "State", value: stateDescription(status.state))
                MetricRow(title: "Camera", value: status.camera?.description ?? "None")
                MetricRow(title: "Source resolution", value: resolution(metrics))
                MetricRow(title: "Camera FPS", value: String(format: "%.1f", metrics.cameraFPS))
                MetricRow(title: "Delivered FPS", value: String(format: "%.1f", metrics.deliveredFPS))
                MetricRow(title: "Frame age p50 / p95", value: frameAge(metrics.frameAgeAtDelivery))
                MetricRow(title: "Frames dropped", value: "\(metrics.framesDropped)")
                MetricRow(title: "Invalid frames", value: "\(metrics.invalidFrames)")
                MetricRow(title: "Reconnects", value: "\(status.reconnectCount)")
                if let error = status.lastRecoverableError {
                    MetricRow(title: "Last recoverable error", value: UserFacingText.message(for: error))
                    MetricRow(title: "Error detail", value: error.detail ?? "—")
                }
            }
            Section("Mirrorup Camera") {
                MetricRow(title: "Extension", value: model.extensionManager.state.summary)
                if case let .failed(_, detail) = model.extensionManager.state {
                    MetricRow(title: "Extension error detail", value: detail)
                }
                MetricRow(title: "Sink", value: UserFacingText.sink(model.sinkState))
                if case let .failed(_, detail) = model.sinkState {
                    MetricRow(title: "Sink error detail", value: detail)
                }
                MetricRow(title: "Frames sent / dropped (queue full)",
                          value: "\(model.sinkCounters.enqueued) / \(model.sinkCounters.droppedQueueFull)")
            }
            Section("Process") {
                MetricRow(title: "CPU", value: model.resources.map { String(format: "%.1f %%", $0.cpuPercent) } ?? "—")
                MetricRow(title: "Memory", value: model.resources.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0.memoryBytes), countStyle: .memory)
                } ?? "—")
            }
            if let exportMessage {
                Text(exportMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button("Export…", systemImage: "square.and.arrow.up") { export() }
                    .disabled(isExporting)
                    .help("Save a diagnostics report, including everything the camera reports and recent logs")
            }
        }
        .frame(minWidth: 460, minHeight: 520)
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

        var snapshot = DiagnosticsReport.Snapshot(
            wantsStreaming: model.wantsStreaming,
            source: model.source,
            status: model.status,
            extensionState: model.extensionManager.state.summary,
            sinkState: model.sinkState,
            sinkCounters: model.sinkCounters,
            cameraAccess: Self.describe(model.cameraAccess),
            cpuPercent: model.resources?.cpuPercent,
            memoryBytes: model.resources?.memoryBytes,
            cameraMetadata: nil
        )
        isExporting = true
        exportMessage = "Exporting…"
        Task {
            // Read once, for this export only.
            snapshot.cameraMetadata = await model.engine.cameraMetadata()
            let report = snapshot
            let result = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
                Result { try DiagnosticsReport.make(report).write(to: url, atomically: true, encoding: .utf8) }
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

private struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
