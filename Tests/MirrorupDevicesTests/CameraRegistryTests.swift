import MirrorupCameras
import MirrorupCanon
import MirrorupCapture
@testable import MirrorupDevices
import Testing

/// A driver that claims one USB vendor and records what it was asked to build.
private struct FakeDriver: CameraDriver {
    let id: String
    let name: String
    let vendor: UInt16

    func supports(_ camera: DiscoveredCamera) -> Bool { camera.usbVendorID == vendor && camera.acceptsPTP }
    func makeBackend(for camera: DiscoveredCamera) async throws(CameraError) -> any CameraBackend {
        SyntheticCamera()
    }
}

@Suite struct CameraRegistryTests {
    let sl2 = DiscoveredCamera.placeholder(name: "Canon EOS Rebel SL2", usbVendorID: 0x04A9, usbProductID: 0x32CC)
    let nikon = DiscoveredCamera.placeholder(name: "Nikon Z 6", usbVendorID: 0x04B0)

    @Test func firstRegisteredDriverThatSupportsTheCameraWins() {
        let registry = CameraRegistry(drivers: [
            FakeDriver(id: "nikon", name: "Nikon", vendor: 0x04B0),
            FakeDriver(id: "canon-a", name: "Canon A", vendor: 0x04A9),
            FakeDriver(id: "canon-b", name: "Canon B", vendor: 0x04A9),
        ])
        #expect(registry.driver(for: sl2)?.id == "canon-a")
        #expect(registry.driver(for: nikon)?.id == "nikon")
        #expect(registry.driver(for: .placeholder(name: "Webcam", usbVendorID: 0x046D)) == nil)
    }

    @Test func builtInRegistryDrivesCanonPTPCamerasOnly() {
        let registry = CameraRegistry.builtIn
        #expect(registry.driver(for: sl2)?.id == "canon-eos")
        #expect(registry.driver(for: nikon) == nil)
        // A Canon body in a non-PTP USB mode (e.g. mass storage) can't be driven.
        #expect(registry.driver(for: .placeholder(name: "Canon PowerShot", usbVendorID: 0x04A9, acceptsPTP: false)) == nil)
    }

    @Test func notFoundNamesAnAttachedButUnsupportedCamera() {
        let drivers: [any CameraDriver] = [CanonDriver()]
        let none = CameraRegistry.notFound(unsupported: [], drivers: drivers)
        #expect(none.kind == .notFound)
        #expect(none.message == "No camera found. Connect your camera with a USB cable and turn it on.")

        let unsupported = CameraRegistry.notFound(unsupported: [nikon], drivers: drivers)
        #expect(unsupported.kind == .notFound)
        #expect(unsupported.message == "Mirrorup doesn't support Nikon Z 6 yet. It works with: Canon EOS.")
        #expect(unsupported.detail?.contains("04B0:0000") == true)

        // Image Capture also lists phones; an unknown maker's device is never named as "the camera".
        let phone = DiscoveredCamera.placeholder(name: "André's iPhone", usbVendorID: 0x05AC, acceptsPTP: false)
        #expect(CameraRegistry.notFound(unsupported: [phone], drivers: drivers).message == none.message)
        #expect(CameraRegistry.notFound(unsupported: [phone, nikon], drivers: drivers).message.contains("Nikon Z 6"))

        let noPTP = CameraRegistry.notFound(
            unsupported: [.placeholder(name: "Sony ILCE-7M3", usbVendorID: 0x054C, acceptsPTP: false)], drivers: drivers)
        #expect(noPTP.message.hasPrefix("Sony ILCE-7M3 doesn't offer a PTP connection."))
    }

    @Test func knownVendorsAreNamedFromTheUSBVendorID() {
        #expect(sl2.vendorName == "Canon")
        #expect(nikon.vendorName == "Nikon")
        #expect(DiscoveredCamera.placeholder(name: "x", usbVendorID: 0x054C).vendorName == "Sony")
        #expect(DiscoveredCamera.placeholder(name: "x", usbVendorID: 0x046D).vendorName == nil)
    }

    @Test func opensFailClearlyWithoutADevice() async {
        await #expect(throws: CameraError.self) { _ = try await sl2.openPTPSession() }
        let noPTP = DiscoveredCamera.placeholder(name: "Cam", usbVendorID: 0x04A9, acceptsPTP: false)
        do {
            _ = try await noPTP.openPTPSession()
            Issue.record("expected an error")
        } catch {
            #expect(error.kind == .protocolViolation)
        }
    }

    @Test func identityCarriesTheTransportName() {
        #expect(sl2.identity == CameraIdentity(name: "Canon EOS Rebel SL2", transport: "ImageCaptureCore"))
        let usb = DiscoveredCamera.placeholder(name: "Canon Digital Camera", usbVendorID: 0x04A9, transport: .usb)
        #expect(usb.identity.transport == "USB")
    }
}
