public import CoreGraphics
public import Foundation

/// Settings a backend may let the user change. Which ones appear, and with which options, is decided
/// by the camera and its current mode (e.g. a fully automatic mode offers no aperture choices).
public enum CameraSetting: String, Sendable, CaseIterable, Codable {
    case aperture, shutterSpeed, iso, exposureCompensation, whiteBalance, colorTemperature, pictureStyle
    /// Live-view autofocus method; the "face tracking" toggle selects between its options.
    case autofocusMethod

    public var title: String {
        switch self {
        case .aperture: "Aperture"
        case .shutterSpeed: "Shutter"
        case .iso: "ISO"
        case .exposureCompensation: "Brightness"
        case .whiteBalance: "White Balance"
        case .colorTemperature: "Color Temperature"
        case .pictureStyle: "Picture Style"
        case .autofocusMethod: "Focus Mode"
        }
    }
}

/// One value a setting can take: the camera's raw code and its human title ("f/5.6", "Daylight").
public struct CameraSettingOption: Sendable, Hashable, Identifiable {
    public let value: UInt32
    public let title: String
    public var id: UInt32 { value }

    public init(value: UInt32, title: String) {
        self.value = value
        self.title = title
    }
}

public struct CameraSettingState: Sendable, Equatable {
    public let setting: CameraSetting
    public let current: CameraSettingOption?
    /// Values the camera accepts right now, in the camera's order.
    public let options: [CameraSettingOption]

    public init(setting: CameraSetting, current: CameraSettingOption?, options: [CameraSettingOption]) {
        self.setting = setting
        self.current = current
        self.options = options
    }

    /// Only settings with a real choice are shown as controls.
    public var isAdjustable: Bool { options.count > 1 }
}

/// Live-view magnification. Zoom crops the sensor (sharper than digital zoom) and changes the
/// stream's field of view.
public enum CameraZoom: Int, Sendable, CaseIterable, Codable {
    /// No 10×: the SL2 sends the same image at 10× as at 5× over USB (verified), so it would add nothing.
    case x1 = 1, x5 = 5

    public var title: String { "\(rawValue)×" }
}

/// How an autofocus attempt ended, as reported by the camera's live-view AF frame.
public enum AutofocusResult: Sendable, Equatable {
    case focused
    /// The camera tried and could not lock (e.g. a low-contrast target).
    case notFocused
    /// The camera accepted the command but its frames gave no verdict (e.g. Face + Tracking mode).
    case unconfirmed
}

/// What the user can control right now. Read on demand (popover open, after a change); never polled.
public struct CameraControlState: Sendable, Equatable {
    public var settings: [CameraSetting: CameraSettingState]
    public var canAutofocus: Bool
    public var canFocusAtPoint: Bool
    /// Current magnification, or nil when the camera cannot zoom live view.
    public var zoom: CameraZoom?
    public var canCapturePhoto: Bool
    /// Human battery level ("Full", "50%"), nil when unknown.
    public var battery: String?
    public var batteryIsLow: Bool
    public var shotsRemaining: Int?

    public init(
        settings: [CameraSetting: CameraSettingState] = [:], canAutofocus: Bool = false, canFocusAtPoint: Bool = false,
        zoom: CameraZoom? = nil, canCapturePhoto: Bool = false, battery: String? = nil, batteryIsLow: Bool = false,
        shotsRemaining: Int? = nil
    ) {
        self.settings = settings
        self.canAutofocus = canAutofocus
        self.canFocusAtPoint = canFocusAtPoint
        self.zoom = zoom
        self.canCapturePhoto = canCapturePhoto
        self.battery = battery
        self.batteryIsLow = batteryIsLow
        self.shotsRemaining = shotsRemaining
    }

    public func adjustable(_ setting: CameraSetting) -> CameraSettingState? {
        settings[setting].flatMap { $0.isAdjustable ? $0 : nil }
    }
}

/// A full-resolution still taken while streaming.
public struct CapturedPhoto: Sendable {
    public let data: Data
    /// The camera's file name (e.g. "IMG_0042.JPG"); the extension reflects the format it shot.
    public let filename: String

    public init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }
}

/// Optional capability of a `CameraBackend`. Points are normalized to the camera's live-view frame
/// as the camera delivers it (before any app-side mirroring): (0, 0) is top-left, (1, 1) bottom-right.
/// Every method is safe to call while streaming; the backend interleaves it with frame requests.
public protocol CameraControlling: Sendable {
    func controlState() async -> CameraControlState
    /// Applies a value from the setting's current `options` and returns the camera-confirmed state.
    func set(_ setting: CameraSetting, to value: UInt32) async throws(CameraError) -> CameraControlState
    @discardableResult func autofocus() async throws(CameraError) -> AutofocusResult
    @discardableResult func focus(at point: CGPoint) async throws(CameraError) -> AutofocusResult
    /// Changes magnification; `center` (normalized, see above) positions the magnified area.
    func setZoom(_ zoom: CameraZoom, center: CGPoint?) async throws(CameraError) -> CameraControlState
    /// Takes a photo and returns the file. Live view pauses briefly while the shutter fires.
    func capturePhoto() async throws(CameraError) -> CapturedPhoto
}

/// App-side orientation applied to every frame before it is published (preview and virtual camera).
public struct FrameOrientation: Sendable, Equatable, Codable {
    public var mirrored: Bool
    public var upsideDown: Bool

    public init(mirrored: Bool = false, upsideDown: Bool = false) {
        self.mirrored = mirrored
        self.upsideDown = upsideDown
    }

    public static let normal = FrameOrientation()

    /// Maps a normalized point in the displayed (oriented) frame back to the camera's frame.
    public func cameraPoint(fromDisplayed point: CGPoint) -> CGPoint {
        var p = point
        if mirrored != upsideDown { p.x = 1 - p.x }  // upside down = rotate 180° = flip both axes
        if upsideDown { p.y = 1 - p.y }
        return p
    }
}
