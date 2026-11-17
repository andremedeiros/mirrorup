public import Foundation
public import CoreVideo

/// Identity of a physical (or synthetic) camera, for UI and logs.
public struct CameraIdentity: Sendable, Equatable, CustomStringConvertible {
    public var name: String
    public var model: String?
    public var serialNumber: String?
    /// How the camera is reached, e.g. "ImageCaptureCore", "USB", "Synthetic".
    public var transport: String

    public init(name: String, model: String? = nil, serialNumber: String? = nil, transport: String) {
        self.name = name
        self.model = model
        self.serialNumber = serialNumber
        self.transport = transport
    }

    public var description: String { "\(name) via \(transport)" }
}

/// One compressed live-view frame exactly as acquired from the camera.
public struct CameraFrame: Sendable {
    /// Monotonic per-backend sequence number, starting at 1 for each live-view session.
    public var sequence: UInt64
    /// Baseline JPEG bytes (often a slice of a larger vendor payload; no copy is made).
    public var jpeg: Data
    /// Host time (`HostTime.now()`) when the request that produced this frame was issued.
    public var acquisitionStart: UInt64
    /// Host time when the frame's bytes were fully received. This is the frame's capture timestamp.
    public var acquisitionEnd: UInt64
    public init(sequence: UInt64, jpeg: Data, acquisitionStart: UInt64, acquisitionEnd: UInt64) {
        self.sequence = sequence
        self.jpeg = jpeg
        self.acquisitionStart = acquisitionStart
        self.acquisitionEnd = acquisitionEnd
    }
}

/// Camera-layer failure with a user-facing message and preserved low-level detail.
public struct CameraError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// No compatible camera is attached.
        case notFound
        /// The camera went away mid-session (unplug, power-off, sleep).
        case disconnected
        /// Another process owns the camera.
        case inUseByAnotherApplication
        /// Missing permission or entitlement.
        case accessDenied
        /// A camera operation exceeded its deadline.
        case timeout
        /// The camera refused or cannot enter live view (mode dial, menu, unsupported model).
        case liveViewUnavailable
        /// The camera answered with data or codes we do not understand.
        case protocolViolation
        /// One frame was malformed; the session itself is still healthy.
        case invalidFrame
        /// The calling task was cancelled.
        case cancelled
    }

    public var kind: Kind
    /// Plain-language message suitable for UI.
    public var message: String
    /// Underlying error description (PTP codes, IOReturn values) for diagnostics, never primary UI.
    public var detail: String?

    public init(_ kind: Kind, _ message: String, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
    }

    public var description: String { detail.map { "\(message) [\($0)]" } ?? message }

    /// How the capture engine should react.
    public enum Disposition: Sendable, Equatable {
        /// Drop this frame and keep streaming.
        case skipFrame
        /// Tear down the session and reconnect with backoff.
        case reconnect
        /// Wait (with backoff) for the camera to (re)appear, then reconnect.
        case waitForDevice
        /// Retrying cannot help until the user acts.
        case fatal
        /// Stop quietly; someone cancelled us.
        case stop
    }

    public var disposition: Disposition {
        switch kind {
        case .invalidFrame: .skipFrame
        case .timeout, .protocolViolation, .liveViewUnavailable: .reconnect
        case .notFound, .disconnected, .inUseByAnotherApplication: .waitForDevice
        case .accessDenied: .fatal
        case .cancelled: .stop
        }
    }
}

/// A camera that can stream live-view frames. Implementations serialize their own device access
/// (typically by being actors) and must tolerate `stopLiveView`/`disconnect` racing a pending
/// `nextFrame` from another task: the pending call must finish promptly, with a frame or an error.
public protocol CameraBackend: Sendable {
    var identity: CameraIdentity { get async }

    /// Establishes the session and performs camera initialization. Idempotent once connected.
    func connect() async throws(CameraError)
    func startLiveView() async throws(CameraError)
    /// Waits for and returns the next frame. Never returns the same frame twice.
    func nextFrame() async throws(CameraError) -> CameraFrame
    func stopLiveView() async throws(CameraError)
    /// Releases every camera resource. Must not throw; safe to call in any state, repeatedly.
    func disconnect() async
    /// Everything the backend knows about the camera, decoded to human values: identity, lens,
    /// exposure and image settings, power, capabilities, and the metadata of the latest live-view
    /// frame. Reflects the latest state the camera has reported. Formatting is done here, on demand,
    /// never on the capture path: call it when a user asks, not on a timer.
    func metadata() async -> CameraMetadata
}

/// A decoded frame ready for display or publication. Pixel buffers are IOSurface-backed so they can
/// cross into the Camera Extension without copying.
public struct DecodedFrame: @unchecked Sendable {
    // CVPixelBuffer is immutable once published: producers never write to a buffer after handing it
    // to a consumer, which is what makes sharing it across tasks safe.
    public let pixelBuffer: CVPixelBuffer
    public let sequence: UInt64
    /// Host time when the compressed frame arrived from the camera (the capture timestamp).
    public let captureHostTime: UInt64
    /// Host time when decoding finished and the pixel buffer was ready.
    public let decodedHostTime: UInt64
    /// Native dimensions of the camera image before scaling/cropping to the output format.
    public let sourceWidth: Int
    public let sourceHeight: Int

    public init(pixelBuffer: CVPixelBuffer, sequence: UInt64, captureHostTime: UInt64, decodedHostTime: UInt64, sourceWidth: Int, sourceHeight: Int) {
        self.pixelBuffer = pixelBuffer
        self.sequence = sequence
        self.captureHostTime = captureHostTime
        self.decodedHostTime = decodedHostTime
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }
}

/// How a polling backend's live-view requests went: for benchmarks and diagnostics.
public struct LiveViewPollStatistics: Sendable, Equatable {
    /// Live-view requests sent.
    public var requests = 0
    /// Requests that returned a frame.
    public var frames = 0
    /// Requests the camera answered with "not ready yet".
    public var notReady = 0
    /// Responses that could not be parsed into a frame.
    public var invalidPayloads = 0
    public var payloadBytes = 0

    public init() {}
}

/// Optional capability of a `CameraBackend` that polls the camera for each frame (PTP live view).
public protocol LiveViewPolling: Sendable {
    var pollStatistics: LiveViewPollStatistics { get async }
}
