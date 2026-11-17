import Foundation
import MirrorupCapture

/// Plain-language text for app states. Camera errors show `CameraError.message`, which backends write
/// in the camera's own terms; raw codes (`CameraError.detail`) only appear in Diagnostics.
enum UserFacingText {
    static func headline(for state: CaptureState) -> String {
        switch state {
        case .idle: "Stopped"
        case .discovering: "Looking for the camera…"
        case .connecting: "Connecting to the camera…"
        case .initializing: "Starting live view…"
        case .ready: "Camera ready"
        case .streaming: "Streaming"
        case let .recovering(attempt, _): attempt > 1 ? "Reconnecting (attempt \(attempt))…" : "Reconnecting…"
        case .failed: "Camera unavailable"
        }
    }

    static func sink(_ state: VirtualCameraSink.State) -> String {
        switch state {
        case .inactive: "Not started"
        case .deviceNotFound: "Mirrorup Camera not available. Install and allow the camera extension in Settings."
        case .connected: "Publishing to Mirrorup Camera"
        case let .failed(message, _): message
        }
    }
}
