import Foundation
import CoreVideo

/// Constants shared by the Mirrorup app and its Camera Extension. Both targets compile this file, so
/// the app's sink client and the extension always agree on identity and format.
enum VirtualCameraConfig {
    static let deviceName = "Mirrorup Camera"
    static let manufacturer = "Mirrorup"
    static let model = "Mirrorup Virtual Camera"

    /// Stable identity of the virtual camera. CoreMediaIO exposes it to clients as the device UID
    /// (`kCMIODevicePropertyDeviceUID`), which is how the app finds the device. Never change it:
    /// apps such as Zoom and FaceTime remember the selected camera by this UID.
    static let deviceID = UUID(uuidString: "AE47482F-7BC7-4341-9F96-959C50511F5F")!
    static let sourceStreamID = UUID(uuidString: "E408A13C-FA10-43CE-A35C-D688C786FDA3")!
    static let sinkStreamID = UUID(uuidString: "8DB3E19A-7666-4240-9B15-97AE36C53545")!

    static let sourceStreamName = "Mirrorup Camera Video"
    static let sinkStreamName = "Mirrorup Camera Input"

    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let frameRate: Int32 = 30
    /// '420v': 8-bit bi-planar 4:2:0, video range.
    static let pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// A sink frame older than this is considered stale and the extension shows the fallback frame.
    static let sinkFreshnessNanoseconds: UInt64 = 500_000_000
}
