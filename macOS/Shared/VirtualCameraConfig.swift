import Foundation
import CoreVideo

/// Constants shared by the Mirrorup app and its Camera Extension. Both targets compile this file, so
/// the app's sink client and the extension always agree on identity and format.
enum VirtualCameraConfig {
    /// Device name until the app has named a camera, and what a never-connected install shows.
    static let defaultDeviceName = "Mirrorup Camera"

    /// The name other apps list while `cameraName` is the selected source. The name follows the
    /// selected camera; the device ID never changes, so apps keep the camera selected.
    static func deviceName(forCamera cameraName: String) -> String {
        "\(cameraName) (Mirrorup)"
    }

    /// Longest device name the extension accepts; anything longer is truncated.
    static let maxDeviceNameLength = 80

    /// Custom device property through which the app sets the device name (a CFString). CoreMediaIO
    /// exposes extension custom properties as `4cc_<selector>_<scope>_<element>`; the app addresses
    /// the same property as selector `deviceNameSelector`, global scope, main element.
    static let deviceNamePropertyKey = "4cc_mrnm_glob_0000"
    static let deviceNameSelector: UInt32 = 0x6D72_6E6D // 'mrnm'

    /// Read-only custom device property: "1" while a client streams from the source (another app
    /// uses the camera), else "0". The app reads it to postpone a rename without interrupting.
    static let sourceActivePropertyKey = "4cc_mrsa_glob_0000"
    static let sourceActiveSelector: UInt32 = 0x6D72_7361 // 'mrsa'

    static let manufacturer = "Mirrorup"
    static let model = "Mirrorup Virtual Camera"

    /// Stable identity of the virtual camera. CoreMediaIO exposes it to clients as the device UID
    /// (`kCMIODevicePropertyDeviceUID`), which is how the app finds the device. Never change it:
    /// apps such as Zoom and FaceTime remember the selected camera by this UID.
    static let deviceID = UUID(uuidString: "AE47482F-7BC7-4341-9F96-959C50511F5F")!

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
