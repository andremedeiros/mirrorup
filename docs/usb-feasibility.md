# USB access feasibility on macOS 26+

This document records how Mirrorup can (and cannot) talk to a Canon EOS camera over USB on current
macOS, the experiments behind each conclusion, and the access path the project ships with.

Test system: macOS 27.2 (build 26B123, Apple Silicon), Xcode 27.2 / Swift 6.4.2, Canon EOS Rebel SL2
(USB `04A9:32CC`, High Speed). The project's deployment target is macOS 26.0.

## Summary

| Path | Works? | Notes |
|---|---|---|
| IOUSBHost `IOUSBHostDevice` (device user client) | **Yes**, read-only use | Descriptors are readable while `ptpcamerad` owns the interface. |
| IOUSBHost `IOUSBHostInterface` (claim PTP interface) | **No** in a normal session | `ptpcamerad` holds it exclusively; open fails with `kIOReturnInternalError`. |
| IOUSBHost `.deviceSeize` | **No** | Same failure; `ptpcamerad` does not surrender on request. |
| IOUSBHost `.deviceCapture` | Not shippable | Needs the `com.apple.vm.device-access` entitlement (restricted, for virtualization) or root, and terminates every other client of the device. |
| ImageCaptureCore `requestSendPTPCommand` | **Yes** — shipped default | Full PTP pass-through, vendor opcodes included; 29.8 fps live view measured. Answers only after `ptpcamerad` has listed the card (34.1 s for 810 files on an SL2); the only session option is `ICEnumerationChronologicalOrder`, so the listing can't be skipped. |
| DriverKit (`USBDriverKit`) | Not pursued | The only route that might claim the PTP interface before `ptpcamerad` and skip the card listing (untested). Distribution needs Apple's USB transport entitlement, requested with "your company's hardware vendor ID" ([Apple](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)); Apple doesn't document whether it grants another maker's vendor ID (Canon `0x04A9`) or a Still Image class match. The self-service wildcard (`idVendor = "*"`) is development-signing only. Also a C++ driver (against the no-C-transport rule), a second system extension, and Photos/Image Capture lose the camera while it is matched. |

**Decision:** Mirrorup talks PTP through ImageCaptureCore by default (`CameraTransport.imageCapture`, used by `CameraRegistry.makeBackend()`).
The native Swift PTP stack (container framing, transaction IDs, session handling) is shared by both
transports; the direct IOUSBHost transport (`.usb`) is kept, tested with fakes, and usable whenever
the interface is unclaimed. It is never the default and Mirrorup never terminates system daemons to
free the interface.

## Experiments

### 1. Discovery

`IOServiceGetMatchingServices` with `{IOProviderClass: IOUSBHostDevice, IOPropertyMatch: {idVendor: 0x04A9}}`
finds the camera. Interfaces are children of the device in the IOService plane (`IOUSBHostInterface`),
each carrying `bInterfaceClass/SubClass/Protocol` and, when claimed, `UsbExclusiveOwner`.

Note: putting `idVendor` at the top level of the matching dictionary (instead of inside
`IOPropertyMatch`) matched nothing for `IOUSBHostInterface` — interface nodes don't carry `idVendor`
as a matchable key in that form.

Observed registry for the SL2:

```
Canon Digital Camera  (IOUSBHostDevice, idVendor 0x04A9, idProduct 0x32CC, 1 configuration)
└─ IOUSBHostInterface@0  class 6 / subclass 1 / protocol 1   UsbExclusiveOwner = "pid 53850, ptpcamerad"
   └─ AppleUSBHostInterfaceUserClient  IOUserClientCreator = "pid 53850, ptpcamerad"
```

`mirrorup inspect` reads the configuration descriptor through an `IOUSBHostDevice` user client
(opening the *device* succeeds even though the *interface* is owned):

```
configuration  1  attributes 0xc0 (self powered)  max power 2 mA
interface 0 alt 0: Still Image class 0x6 subclass 0x1 protocol 0x1  [PTP]
  EP 0x81 IN bulk maxPacket=512
  EP 0x2 OUT bulk maxPacket=512
  EP 0x83 IN interrupt maxPacket=8 interval=10
```

### 2. Claiming the interface

`IOUSBHostInterface(__ioService:options:queue:interestHandler:)` (the Swift-refined initializer) with
options `[]` and `[.deviceSeize]`:

```
open failed: IOUSBHostErrorDomain code 0xe00002c9 (kIOReturnInternalError) "Failed to create IOUSBHostInterface."
```

The header (`IOUSBHostObject.h`) documents that "if an IOUSBHostDevice or IOUSBHostInterface user client
is already created, nil will be returned" and that creation "establishes exclusive ownership". The
error code is `kIOReturnInternalError`, not `kIOReturnExclusiveAccess`, so Mirrorup reads
`UsbExclusiveOwner` from the registry to explain the failure to the user.

`.deviceSeize` sends `kUSBHostMessageDeviceIsRequestingClose` to the current owner. `ptpcamerad`
ignores it.

`killall ptpcamerad` (SIGTERM) changed nothing: the daemon kept the interface. With `kill -9`, the
interface became claimable and `IOUSBHostInterface` opened successfully — but `launchd` restarted
`ptpcamerad` within seconds (new PID), and the new instance holds the interface again (verified later via `UsbExclusiveOwner`).
This confirms the API works when the interface is free, and confirms that killing a system daemon is
neither reliable nor acceptable for a shipping app. Mirrorup does not do it.

### 3. ImageCaptureCore pass-through

`ICDeviceBrowser` (camera + local mask) reports the SL2 with capability
`ICCameraDeviceCanAcceptPTPCommands`. After `requestOpenSession`, `requestSendPTPCommand(_:outData:completion:)`
forwards a raw PTP command container and returns the data phase and the raw response container.

- `ptpcamerad` owns the PTP session: Mirrorup never sends OpenSession/CloseSession on this path
  (`PTPSessionOwnership.system`).
- `ptpcamerad` rewrites transaction IDs (responses carry its own sequence), so the transport does not
  validate them; the PTP layer's own serial gate still guarantees one transaction at a time.
- Vendor operations (0x91xx) and data-out phases (SetDevicePropValueEx) pass through unchanged.
- macOS has no ImageCaptureCore authorization API (`requestControlAuthorization…` is iOS-only); no
  TCC prompt appeared for an unsandboxed CLI or app. A sandboxed app may need
  `com.apple.security.device.usb` / camera entitlements; the Mirrorup app is not sandboxed.

### 4. Asynchronous transfers, cancellation, removal

Direct USB (`IOUSBHostBulkPipe`):
- `enqueueIORequest(with:completionTimeout:completionHandler:)` with a per-request timeout; completion
  arrives on the interface's serial queue.
- Task cancellation calls `abort(option: .asynchronous)`, so the completion fires with
  `kIOReturnAborted` and the awaiting task resumes immediately.
- Removal arrives as `kIOMessageServiceIsTerminated` on the interest handler; the pipe then fails all
  further I/O with `.disconnected`.
- After any timeout/cancellation/framing error the transport poisons itself (`notOpen`), since the
  device's transaction state is unknown.

ImageCaptureCore:
- No per-request timeout or cancellation API. Mirrorup races each request against its own deadline and
  the caller's cancellation; the first outcome wins, a late completion is ignored, and the transport is
  marked failed so the capture engine reconnects.
- Removal arrives as `deviceBrowser(_:didRemove:)`; Mirrorup fails the in-flight request immediately
  rather than waiting for its timeout.

## Distribution implications

- The ImageCaptureCore path needs no special entitlement and works with Developer ID signing.
- The Camera Extension is a system extension: the app needs `com.apple.developer.system-extension.install`,
  must be run from `/Applications`, and the user must approve the extension once in System Settings.
- DriverKit or `.deviceCapture` would each require an Apple-granted entitlement; neither is used.
- Only one process should own the camera: the Mirrorup app owns the PTP session; the Camera Extension
  never touches USB and receives frames through the CoreMediaIO sink stream.
