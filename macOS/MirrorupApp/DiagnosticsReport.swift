import Foundation
import MirrorupCapture
import MirrorupDiagnostics
import OSLog

/// Plain-text diagnostics export: current status plus this process's recent Mirrorup log entries.
enum DiagnosticsReport {
    struct Snapshot: Sendable {
        var wantsStreaming: Bool
        var source: CameraSource
        var status: CaptureStatus
        var extensionState: String
        var sinkState: VirtualCameraSink.State
        var sinkCounters: VirtualCameraSink.Counters
        var cameraAccess: String
        var cpuPercent: Double?
        var memoryBytes: UInt64?
        /// Everything the camera reports (including undocumented codes), read at export time.
        var cameraMetadata: CameraMetadata?
    }

    /// Builds the report. Reads OSLogStore, which can take a moment: call off the main actor.
    nonisolated static func make(_ snapshot: Snapshot, logWindow: TimeInterval = 30 * 60) -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        lines.append("Mirrorup diagnostics")
        lines.append("Generated: \(Date().formatted(.iso8601))")
        lines.append("App version: \(version)")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")

        let status = snapshot.status
        let metrics = status.metrics
        lines.append("== Capture ==")
        lines.append("Streaming enabled: \(snapshot.wantsStreaming)")
        lines.append("Source: \(snapshot.source.rawValue)")
        lines.append("State: \(status.state)")
        lines.append("Camera: \(status.camera.map { "\($0.description) model=\($0.model ?? "-") serial=\($0.serialNumber ?? "-")" } ?? "none")")
        lines.append("Source resolution: \(metrics.sourceWidth.map(String.init) ?? "-")x\(metrics.sourceHeight.map(String.init) ?? "-")")
        lines.append(String(format: "Camera FPS: %.2f  Delivered FPS: %.2f", metrics.cameraFPS, metrics.deliveredFPS))
        lines.append("Frames acquired=\(metrics.framesAcquired) decoded=\(metrics.framesDecoded) delivered=\(metrics.framesDelivered) dropped=\(metrics.framesDropped) invalid=\(metrics.invalidFrames)")
        lines.append("Acquisition: \(metrics.acquisition?.formatted() ?? "-")")
        lines.append("Decode: \(metrics.decode?.formatted() ?? "-")")
        lines.append("Frame age at delivery: \(metrics.frameAgeAtDelivery?.formatted() ?? "-")")
        lines.append("Inter-frame interval: \(metrics.interFrameInterval?.formatted() ?? "-")")
        lines.append("Reconnects: \(status.reconnectCount)  Recovery attempts: \(metrics.recoveryAttempts)  Last recovery: \(metrics.lastRecoveryDuration.map { String(format: "%.0f ms", $0.milliseconds) } ?? "-")")
        if let error = status.lastRecoverableError {
            lines.append("Last recoverable error: \(error.kind) — \(error.message) [\(error.detail ?? "no detail")]")
        }
        if case let .failed(error) = status.state {
            lines.append("Failure: \(error.kind) — \(error.message) [\(error.detail ?? "no detail")]")
        }
        lines.append("")

        // Everything the camera reported, including codes no public source documents, with raw values.
        if let metadata = snapshot.cameraMetadata, !metadata.isEmpty {
            lines.append("== Camera ==")
            for section in metadata.sections.sorted(by: { $0.kind < $1.kind }) {
                lines.append("[\(section.title)]")
                for item in section.items {
                    var line = "\(item.label): \(item.value)  (raw \(item.raw))"
                    if !item.isDocumented { line += "  [undocumented]" }
                    lines.append(line)
                    if !item.allowedValues.isEmpty {
                        lines.append("    allowed: \(item.allowedValues.joined(separator: ", "))")
                    }
                }
            }
            lines.append("")
        }

        lines.append("== Virtual camera ==")
        lines.append("Extension: \(snapshot.extensionState)")
        switch snapshot.sinkState {
        case let .failed(message, detail): lines.append("Sink: failed — \(message) [\(detail)]")
        default: lines.append("Sink: \(snapshot.sinkState)")
        }
        let counters = snapshot.sinkCounters
        lines.append("Sink enqueued=\(counters.enqueued) droppedQueueFull=\(counters.droppedQueueFull) enqueueFailures=\(counters.enqueueFailures) connects=\(counters.connects)")
        lines.append("Camera permission: \(snapshot.cameraAccess)")
        lines.append("")

        lines.append("== Process ==")
        lines.append("CPU: \(snapshot.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "-")")
        lines.append("Memory: \(snapshot.memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "-")")
        lines.append("")

        lines.append("== Log (this process, last \(Int(logWindow / 60)) min) ==")
        lines.append("Camera Extension logs: log show --last 30m --predicate 'subsystem == \"\(Diagnostics.subsystem)\"'")
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-logWindow))
            let predicate = NSPredicate(format: "subsystem == %@", Diagnostics.subsystem)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for case let entry as OSLogEntryLog in try store.getEntries(at: position, matching: predicate) {
                lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(level(entry.level)) \(entry.composedMessage)")
            }
        } catch {
            lines.append("Could not read log: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "-"
        @unknown default: "?"
        }
    }
}
