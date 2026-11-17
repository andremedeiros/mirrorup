import Foundation
import MirrorupCapture

/// Plain-language text for the UI. Raw codes (`CameraError.detail`) only appear in Diagnostics.
enum UserFacingText {
    static func message(for error: CameraError) -> String {
        switch error.kind {
        case .notFound:
            "No camera found. Connect your Canon camera with a USB cable and turn it on."
        case .disconnected:
            "The camera was disconnected. Reconnect the USB cable or turn the camera back on."
        case .inUseByAnotherApplication:
            "The camera is in use by another app, such as Photos, Image Capture or EOS Utility. Quit that app and Mirrorup will reconnect."
        case .accessDenied:
            "Mirrorup doesn't have permission to use the camera. Allow it in System Settings › Privacy & Security › Camera."
        case .liveViewUnavailable:
            "The camera can't start live view. Set the mode dial to a shooting mode and close any menus on the camera."
        case .timeout, .protocolViolation:
            "The camera stopped responding. Mirrorup is reconnecting."
        case .invalidFrame:
            "The camera sent a damaged picture. Mirrorup skipped it."
        case .cancelled:
            "Stopped."
        }
    }

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
