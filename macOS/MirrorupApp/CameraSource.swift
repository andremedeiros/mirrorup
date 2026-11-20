import MirrorupCameras
import MirrorupCapture
import MirrorupDevices

/// Which camera feeds the capture engine. The only place that knows how backends are constructed.
enum CameraSource: String, CaseIterable, Identifiable, Sendable {
    /// The first attached camera a built-in driver supports (`CameraRegistry.builtIn`).
    case camera
    case testPattern

    var id: Self { self }

    func makeBackend() async throws(CameraError) -> any CameraBackend {
        switch self {
        case .camera: try await CameraRegistry.builtIn.makeBackend()
        case .testPattern: SyntheticCamera()
        }
    }

    /// When cameras appear on the transport `.camera` discovers on, so the engine waits for one
    /// instead of polling (`CaptureEngine(arrivals:)`). The test pattern never waits.
    static var arrivals: (any CameraArrivals)? { CameraDiscovery.arrivals(on: .imageCapture) }
}
