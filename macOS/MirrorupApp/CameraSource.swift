import MirrorupCanon
import MirrorupCapture

/// Which camera feeds the capture engine. The only place that knows how backends are constructed.
enum CameraSource: String, CaseIterable, Identifiable, Sendable {
    case canon
    case testPattern

    var id: Self { self }

    func makeBackend() async throws(CameraError) -> any CameraBackend {
        switch self {
        case .canon: try await CanonBackendFactory.makeBackend()
        case .testPattern: SyntheticCamera()
        }
    }
}
