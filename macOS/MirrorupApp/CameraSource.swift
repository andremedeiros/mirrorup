import MirrorupCameras
import MirrorupCapture
import MirrorupDevices

/// Which camera feeds the capture engine. The only place that knows how backends are constructed.
enum CameraSource: String, CaseIterable, Identifiable, Sendable {
    /// The first attached camera a built-in driver supports (`CameraRegistry.builtIn`).
    case camera
    case testPattern

    var id: Self { self }

    /// Reads a stored value, including the pre-driver name of `.camera` ("canon").
    init?(storedValue: String) {
        self.init(rawValue: storedValue == "canon" ? Self.camera.rawValue : storedValue)
    }

    func makeBackend() async throws(CameraError) -> any CameraBackend {
        switch self {
        case .camera: try await CameraRegistry.builtIn.makeBackend()
        case .testPattern: SyntheticCamera()
        }
    }
}
