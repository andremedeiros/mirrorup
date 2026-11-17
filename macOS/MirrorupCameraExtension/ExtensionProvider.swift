import CoreMedia
import CoreMediaIO
import Foundation
import IOKit.audio
import MirrorupDiagnostics
import os

/// The single "Mirrorup Camera" device with its source and sink streams.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private let sourceStream: SourceStreamSource
    private let sinkStream: SinkStreamSource

    init(relay: FrameRelay) {
        let frameDuration = CMTime(value: 1, timescale: VirtualCameraConfig.frameRate)
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: VirtualCameraConfig.pixelFormat,
            width: VirtualCameraConfig.width,
            height: VirtualCameraConfig.height,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            // Static, valid arguments: failure here means CoreMedia itself is broken.
            fatalError("CMVideoFormatDescriptionCreate failed: \(status)")
        }
        // Advertise exactly what the relay produces: 1280x720 '420v' at a fixed 30 fps.
        let format = CMIOExtensionStreamFormat(
            formatDescription: description,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil
        )
        sourceStream = SourceStreamSource(format: format, frameDuration: frameDuration, relay: relay)
        sinkStream = SinkStreamSource(format: format, frameDuration: frameDuration, relay: relay)
        super.init()
        device = CMIOExtensionDevice(
            localizedName: VirtualCameraConfig.deviceName,
            deviceID: VirtualCameraConfig.deviceID,
            legacyDeviceID: nil,
            source: self
        )
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = Int(kIOAudioDeviceTransportTypeVirtual) }
        if properties.contains(.deviceModel) { result.model = VirtualCameraConfig.model }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // No settable device properties.
    }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    private(set) var provider: CMIOExtensionProvider!
    private let deviceSource: DeviceSource

    init(relay: FrameRelay) {
        deviceSource = DeviceSource(relay: relay)
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        Diagnostics.virtualCamera.info("Client connected pid=\(client.pid) \(client.signingID ?? "unsigned", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        Diagnostics.virtualCamera.info("Client disconnected pid=\(client.pid)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer, .providerName] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = VirtualCameraConfig.manufacturer }
        if properties.contains(.providerName) { result.name = VirtualCameraConfig.deviceName }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable provider properties.
    }
}
