public import MirrorupCapture
public import MirrorupPTP

extension CameraError {
    /// The user-facing error for a PTP failure, shared by every PTP driver. `describeResponse` names
    /// response codes in the driver's vocabulary for `detail` (e.g. vendor codes 0xA0xx).
    public init(ptp error: PTPError, context: String,
                describeResponse: (PTPResponseCode) -> String = { $0.description }) {
        let detail = "\(context): \(error.description)"
        switch error {
        case .transport(let failure):
            switch failure {
            case .disconnected, .notOpen:
                self.init(.disconnected, "The camera was disconnected. Reconnect the USB cable or turn the camera back on.", detail: detail)
            case .timedOut:
                self.init(.timeout, "The camera stopped responding. Mirrorup is reconnecting.", detail: detail)
            case .exclusiveAccess:
                self.init(.inUseByAnotherApplication,
                          "Another app is using the camera, such as Photos, Image Capture or the camera maker's utility. Quit it and Mirrorup will reconnect.",
                          detail: detail)
            case .accessDenied:
                self.init(.accessDenied,
                          "Mirrorup isn't allowed to control the camera. Allow it in System Settings › Privacy & Security › Camera.",
                          detail: detail)
            case .cancelled:
                self.init(.cancelled, "Cancelled.", detail: detail)
            case .io:
                self.init(.protocolViolation, "Communication with the camera failed. Mirrorup is reconnecting.", detail: detail)
            }
        case .response(let code, _):
            self.init(.protocolViolation, "The camera rejected a command.", detail: "\(context): \(describeResponse(code))")
        case .sessionNotOpen:
            self.init(.disconnected, "The camera session is not open.", detail: detail)
        default:
            self.init(.protocolViolation, "The camera sent data Mirrorup does not understand.", detail: detail)
        }
    }
}

extension CameraPreparation {
    /// The engine's view of a PTP transport's preparation report, shared by every PTP driver.
    public init(ptp preparation: PTPPreparation) {
        switch preparation {
        case .indexingStorage(let percent):
            self = .readingStorage(percentComplete: percent)
        }
    }
}
