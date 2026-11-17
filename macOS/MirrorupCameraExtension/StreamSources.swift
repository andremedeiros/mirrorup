import CoreMedia
import CoreMediaIO
import Foundation
import MirrorupDiagnostics
import os

private func unsupported(_ message: String) -> NSError {
    NSError(
        domain: NSOSStatusErrorDomain,
        code: Int(kCMIOHardwareIllegalOperationError),
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

/// Validates settable properties shared by both streams: only the single advertised format and its
/// fixed frame duration are accepted.
private func validate(_ properties: CMIOExtensionStreamProperties, frameDuration: CMTime) throws {
    if let index = properties.activeFormatIndex, index != 0 {
        throw unsupported("Format index \(index) is not supported; only 1280x720 '420v' is offered.")
    }
    if let duration = properties.frameDuration, CMTimeCompare(duration, frameDuration) != 0 {
        throw unsupported("Frame duration \(duration.seconds)s is not supported; only 1/30 s is offered.")
    }
}

// MARK: - Source stream (what FaceTime, Zoom, browsers see)

final class SourceStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let frameDuration: CMTime
    private let relay: FrameRelay

    init(format: CMIOExtensionStreamFormat, frameDuration: CMTime, relay: FrameRelay) {
        self.format = format
        self.frameDuration = frameDuration
        self.relay = relay
        super.init()
        stream = CMIOExtensionStream(
            localizedName: VirtualCameraConfig.sourceStreamName,
            // Fresh per device instance: a renamed device replaces the old one before CoreMediaIO
            // has finished removing it, and reused stream IDs fail with "streamID already included".
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = frameDuration }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        try validate(streamProperties, frameDuration: frameDuration)
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        Diagnostics.virtualCamera.info("Source client pid=\(client.pid) \(client.signingID ?? "unsigned", privacy: .public) authorized")
        return true
    }

    /// Called after the source starts or stops, so the device can announce it. Set once by the
    /// owning device before it is published.
    var onActiveChanged: (@Sendable () -> Void)?

    func startStream() throws {
        relay.startSource(on: stream)
        onActiveChanged?()
    }

    func stopStream() throws {
        relay.stopSource()
        onActiveChanged?()
    }
}

// MARK: - Sink stream (fed by the Mirrorup app)

final class SinkStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private struct State {
        var client: CMIOExtensionClient?
        var running = false
        /// Bumped on every start/stop so completions from an earlier session are ignored.
        var generation: UInt64 = 0
        var consecutiveEmpty = 0
    }

    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let frameDuration: CMTime
    private let relay: FrameRelay
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let retryQueue = DispatchQueue(label: "cool.andre.Mirrorup.CameraExtension.sink", qos: .userInteractive)
    private let log = Diagnostics.virtualCamera

    init(format: CMIOExtensionStreamFormat, frameDuration: CMTime, relay: FrameRelay) {
        self.format = format
        self.frameDuration = frameDuration
        self.relay = relay
        super.init()
        stream = CMIOExtensionStream(
            localizedName: VirtualCameraConfig.sinkStreamName,
            streamID: UUID(),
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex, .streamFrameDuration,
            .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = frameDuration }
        // One slot: the app drops a frame rather than queueing behind a slow consumer.
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(.streamSinkBufferUnderrunCount) { result.sinkBufferUnderrunCount = 0 }
        if properties.contains(.streamSinkEndOfData) { result.sinkEndOfData = 0 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        try validate(streamProperties, frameDuration: frameDuration)
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        log.info("Sink client pid=\(client.pid) \(client.signingID ?? "unsigned", privacy: .public) authorized")
        state.withLockUnchecked { $0.client = client }
        return true
    }

    func startStream() throws {
        let generation: UInt64? = state.withLockUnchecked { state in
            guard state.client != nil else { return nil }
            state.generation &+= 1
            state.running = true
            state.consecutiveEmpty = 0
            return state.generation
        }
        guard let generation else { throw unsupported("Sink stream started without an authorized client.") }
        log.info("Sink stream started")
        consumeNext(generation: generation)
    }

    func stopStream() throws {
        state.withLockUnchecked { state in
            state.generation &+= 1
            state.running = false
            state.client = nil
        }
        relay.clearSink()
        log.info("Sink stream stopped")
    }

    /// Keeps exactly one `consumeSampleBuffer` request outstanding while the sink runs. After a buffer
    /// arrives the next request is issued immediately; when the client has nothing queued the retry
    /// backs off from 1 ms to 16 ms so an idle sink costs almost nothing.
    private func consumeNext(generation: UInt64) {
        let client: CMIOExtensionClient? = state.withLockUnchecked { state in
            state.running && state.generation == generation ? state.client : nil
        }
        guard let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            let current = state.withLockUnchecked { $0.running && $0.generation == generation }
            guard current else { return }
            if let sampleBuffer {
                relay.storeSinkSample(sampleBuffer)
                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: sequenceNumber,
                    hostTimeInNanoseconds: HostTime.nanoseconds(HostTime.now())
                )
                stream.notifyScheduledOutputChanged(output)
                state.withLockUnchecked { $0.consecutiveEmpty = 0 }
                consumeNext(generation: generation)
            } else {
                let empty = state.withLockUnchecked { state -> Int in
                    state.consecutiveEmpty += 1
                    return state.consecutiveEmpty
                }
                if let error, empty == 1 {
                    log.debug("Sink consume returned no buffer: \(error.localizedDescription, privacy: .public)")
                }
                let delayMilliseconds = 1 << min(empty - 1, 4)
                retryQueue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
                    self?.consumeNext(generation: generation)
                }
            }
        }
    }
}
