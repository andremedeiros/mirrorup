import CoreMedia
import CoreMediaIO
import Foundation
import IOKit.audio
import MirrorupDiagnostics
import os

private let deviceNameProperty = CMIOExtensionProperty(rawValue: VirtualCameraConfig.deviceNamePropertyKey)
private let sourceActiveProperty = CMIOExtensionProperty(rawValue: VirtualCameraConfig.sourceActivePropertyKey)

/// The single Mirrorup device with its source and sink streams. Its name is fixed at creation
/// (`CMIOExtensionDevice.localizedName` is read-only), so `ProviderSource` renames it by replacing
/// the whole device under the same device ID.
///
/// Nothing in the extension may crash: launchd would relaunch it, and video apps connected to the
/// old process never see the new one (they lose the camera until reopened). Failures throw and are
/// logged instead.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    let name: String
    private let sourceStream: SourceStreamSource
    private let sinkStream: SinkStreamSource
    private let relay: FrameRelay
    private let onNameRequest: @Sendable (String) -> Void

    struct CreationError: Error, CustomStringConvertible {
        let description: String
    }

    init(name: String, relay: FrameRelay, onNameRequest: @escaping @Sendable (String) -> Void) throws(CreationError) {
        self.name = name
        self.relay = relay
        self.onNameRequest = onNameRequest
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
            throw CreationError(description: "CMVideoFormatDescriptionCreate failed: \(status)")
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
        sourceStream.onActiveChanged = { [weak self] in self?.announceSourceActive() }
        device = CMIOExtensionDevice(
            localizedName: name,
            deviceID: VirtualCameraConfig.deviceID,
            legacyDeviceID: nil,
            source: self
        )
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            throw CreationError(description: "addStream failed: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, deviceNameProperty, sourceActiveProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = Int(kIOAudioDeviceTransportTypeVirtual) }
        if properties.contains(.deviceModel) { result.model = VirtualCameraConfig.model }
        if properties.contains(deviceNameProperty) {
            // Settable, so the app's CMIOObjectSetPropertyData reaches setDeviceProperties.
            let attributes = CMIOExtensionPropertyAttributes<AnyObject>(minValue: nil, maxValue: nil, validValues: nil, readOnly: false)
            result.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: name as NSString, attributes: attributes), forProperty: deviceNameProperty)
        }
        if properties.contains(sourceActiveProperty) {
            result.setPropertyState(sourceActiveState(), forProperty: sourceActiveProperty)
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        if let requested = deviceProperties.propertiesDictionary[deviceNameProperty]?.value as? String {
            onNameRequest(requested)
        }
    }

    private func sourceActiveState() -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(value: (relay.isSourceActive ? "1" : "0") as NSString, attributes: .readOnlyPropertyAttribute)
    }

    /// Clients cache property values until told otherwise; the app reads this one before renaming.
    private func announceSourceActive() {
        device.notifyPropertiesChanged([sourceActiveProperty: sourceActiveState()])
    }

    /// Ends the sink session of a device that has been removed from the provider.
    func invalidate() {
        try? sinkStream.stopStream()
    }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    private static let deviceNameKey = "deviceName"

    private(set) var provider: CMIOExtensionProvider!
    private let relay: FrameRelay
    private let log = Diagnostics.virtualCamera
    /// Serializes device changes; everything below is confined to it after `init`.
    private let queue = DispatchQueue(label: "cool.andre.Mirrorup.CameraExtension.provider")
    /// The published device; nil only while a replacement is in progress or after adding failed.
    private var deviceSource: DeviceSource?
    /// A device replacement is in progress; no device is published meanwhile.
    private var replacing = false
    /// The last name whose device could not be added. Not retried until another name is requested,
    /// or every sink reconnect would set it again and loop.
    private var failedName: String?
    /// Timed retries used after the device could not be published at all.
    private var publishRetries = 0

    /// Why a device is being added: the first one, a rename, or putting the old one back.
    private enum Purpose {
        case initial
        case rename(from: String)
        case restore
    }

    init(relay: FrameRelay) {
        self.relay = relay
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        // The extension runs as its own system user; this is its sandbox container's defaults.
        let name = UserDefaults.standard.string(forKey: Self.deviceNameKey) ?? VirtualCameraConfig.defaultDeviceName
        queue.sync { publish(name: name, purpose: .initial) }
    }

    private func makeDeviceSource(name: String) throws(DeviceSource.CreationError) -> DeviceSource {
        try DeviceSource(name: name, relay: relay) { [weak self] requested in
            self?.requestName(requested)
        }
    }

    /// Called from `setDeviceProperties` on a CoreMediaIO queue; the rename runs on `queue`. The app
    /// asks only after stopping its sink and when no other client streams (it retries otherwise);
    /// a request that arrives while a client streams anyway is ignored, never queued, so no app
    /// loses the camera mid-call and a later replacement can't strand the app's sink.
    private func requestName(_ requested: String) {
        let name = String(requested.trimmingCharacters(in: .whitespacesAndNewlines).prefix(VirtualCameraConfig.maxDeviceNameLength))
        guard !name.isEmpty else { return }
        queue.async { [self] in
            guard !replacing, name != deviceSource?.name, name != failedName else { return }
            if relay.isSourceActive {
                log.info("Rename to \(name, privacy: .public) ignored: a client is streaming")
                return
            }
            if deviceSource == nil {
                // The first device never went in; this is another chance to publish one.
                publish(name: name, purpose: .initial)
            } else {
                replaceDevice(name: name)
            }
        }
    }

    /// Removes the device and adds a new one with the same device ID under `name`. Clients see the
    /// camera disappear and come back and keep it selected by its device ID; the app reconnects its
    /// sink when the device list changes.
    private func replaceDevice(name: String) {
        guard let old = deviceSource else { return }
        do {
            try provider.removeDevice(old.device)
        } catch {
            log.error("Rename to \(name, privacy: .public) failed: removeDevice: \(error.localizedDescription, privacy: .public)")
            return
        }
        old.invalidate()
        deviceSource = nil
        publish(name: name, purpose: .rename(from: old.name))
    }

    /// Builds a device named `name` and adds it, retrying for about a second: CoreMediaIO finishes
    /// removing a device asynchronously, so a replacement added right away can fail. A rename that
    /// fails puts back a device under the old name.
    private func publish(name: String, purpose: Purpose) {
        replacing = true
        do {
            add(try makeDeviceSource(name: name), purpose: purpose, attempt: 1)
        } catch {
            failed(name: name, purpose: purpose, reason: error.description)
        }
    }

    private func add(_ candidate: DeviceSource, purpose: Purpose, attempt: Int) {
        do {
            try provider.addDevice(candidate.device)
        } catch where attempt < 10 {
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                add(candidate, purpose: purpose, attempt: attempt + 1)
            }
            return
        } catch {
            failed(name: candidate.name, purpose: purpose, reason: "addDevice: \(error.localizedDescription)")
            return
        }
        deviceSource = candidate
        replacing = false
        publishRetries = 0
        switch purpose {
        case .initial:
            log.info("Device published as \(candidate.name, privacy: .public) (attempt \(attempt))")
        case .rename(let previous):
            failedName = nil
            UserDefaults.standard.set(candidate.name, forKey: Self.deviceNameKey)
            log.info("Device renamed from \(previous, privacy: .public) to \(candidate.name, privacy: .public) (attempt \(attempt))")
        case .restore:
            log.info("Device restored as \(candidate.name, privacy: .public)")
        }
    }

    private func failed(name: String, purpose: Purpose, reason: String) {
        replacing = false
        switch purpose {
        case .rename(let previous):
            failedName = name
            log.fault("Rename to \(name, privacy: .public) failed: \(reason, privacy: .public); restoring \(previous, privacy: .public)")
            publish(name: previous, purpose: .restore)
        case .initial, .restore:
            // Without a device the app can't reach the extension to ask again, so retry on a timer
            // (12 times, a minute in all). Never crash: see `DeviceSource`.
            log.fault("Publishing the device as \(name, privacy: .public) failed: \(reason, privacy: .public)")
            guard publishRetries < 12 else { return }
            publishRetries += 1
            queue.asyncAfter(deadline: .now() + .seconds(5)) { [self] in
                guard deviceSource == nil, !replacing else { return }
                publish(name: name, purpose: purpose)
            }
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
        if properties.contains(.providerName) { result.name = VirtualCameraConfig.defaultDeviceName }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable provider properties.
    }
}
