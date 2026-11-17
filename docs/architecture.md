# Architecture

## Process boundaries

```mermaid
flowchart LR
    subgraph Camera["Canon EOS (USB)"]
    end
    subgraph System["macOS"]
        PTPD["ptpcamerad<br/>(owns USB PTP interface + session)"]
    end
    subgraph App["Mirrorup.app (menu bar, unsandboxed)"]
        ICT["ImageCapturePTPTransport"] --> SES["PTPSession<br/>(serial gate, TIDs)"]
        SES --> CAN["CanonCamera actor"]
        CAN --> ENG["CaptureEngine<br/>state machine + recovery"]
        ENG --> DEC["FrameDecoder<br/>VideoToolbox JPEG → 1280×720 420v"]
        DEC --> BUF["LatestFrameBuffer<br/>(1 slot)"]
        BUF --> SINK["VirtualCameraSink<br/>CMIO sink queue"]
        BUF --> PREV["Preview"]
    end
    subgraph Ext["Mirrorup Camera Extension (system extension, sandboxed)"]
        SNK["sink stream"] --> REL["FrameRelay<br/>newest frame only"]
        REL --> SRC["source stream<br/>'Mirrorup Camera'"]
    end
    Clients["FaceTime · Safari · Zoom · Teams · OBS · QuickTime"]
    Camera <-->|USB bulk| PTPD
    PTPD <-->|requestSendPTPCommand| ICT
    SINK -->|IOSurface-backed CMSampleBuffer| SNK
    SRC --> Clients
```

- **Exactly one process owns the camera:** the app. The Camera Extension never touches USB or
  ImageCaptureCore; it can't start capture by itself and shows a "camera not connected" frame
  until the app feeds it.
- **Transport:** `ptpcamerad` owns the USB interface, so the app sends PTP through
  ImageCaptureCore's pass-through (see `usb-feasibility.md`). A direct IOUSBHost transport exists
  for when the interface is free and is exercised by the same PTP stack.
- **App → extension IPC:** CoreMediaIO's own sink/source design. The app enqueues `CMSampleBuffer`s
  on the extension's sink stream (`CMIOStreamCopyBufferQueue`). The pixel buffers are
  IOSurface-backed, so they cross the process boundary without copying pixels. There is no custom
  XPC or shared-memory code. CoreMediaIO fans the source stream out to any number of client apps.

## Modules (Swift package)

| Module | Responsibility | Concurrency |
|---|---|---|
| `MirrorupPTP` | Value-type containers and codec. `PTPSession` actor serialises transactions through `AsyncSerialGate` (actors are re-entrant across `await`), assigns transaction IDs and maps response codes to `PTPError`. `PTPUSBTransport<Pipe>` adds USB framing: multi-packet reassembly, ZLPs, length limits checked before allocation, TID/opcode checks. | actor + Mutex |
| `MirrorupUSB` | IORegistry discovery, descriptor parsing, `IOUSBHostBulkPipe` (async enqueue, abort on cancel, interest handler for removal). | `@unchecked Sendable`, documented |
| `MirrorupImageCapture` | `ImageCaptureBrowser` (main actor; ImageCaptureCore calls back on main) and `ImageCapturePTPTransport`: each request races its own deadline and task cancellation, and device removal fails the in-flight request immediately. | MainActor + Mutex |
| `MirrorupCanon` | `CanonCamera` actor: init sequence, live-view arming through `0xD1B0`, the GetViewfinderData poll loop with not-ready retries, periodic GetEvent drain, KeepDeviceOn, and re-arming when the user leaves PC live view. EVF payload and GetEvent parsers. | actor |
| `MirrorupCapture` | `CameraBackend` contract, the pure `CaptureStateMachine`, `CaptureEngine`/`CaptureLoop` (recovery with exponential backoff and jitter, stall watchdog, deadlines), `FrameDecoder`, `LatestFrameBuffer`, `FrameMetrics`, `SyntheticCamera`. | actor + `@concurrent` loop |
| `MirrorupDiagnostics` | OSLog categories, signposts, `HostTime`, bounded `SampleWindow`. | — |

Errors are layered. `PTPTransportError` (I/O) is wrapped by `PTPError` (protocol), and `CanonCamera`
maps both to `CameraError`. `CameraError` carries a plain-language `message`, a diagnostic `detail`
and a `disposition` (skip frame / reconnect / wait for device / fatal / stop) that drives recovery.

## Camera metadata

Every value the camera reports is decoded once, in the vendor layer, into the vendor-neutral
`CameraMetadata` model (`MirrorupCapture/CameraMetadata.swift`): sections (`SectionKind`) of items
keyed by `ItemKind` (an enum; neutral kinds such as `.aperture`, `.lensName`, `.focusPoints`, plus
`.vendorProperty(code)` / `.vendorFrameBlock(type)` for vendor codes without a neutral meaning). Each
item carries the human value, the raw protocol value, the allowed values, and whether any public
source documents it.

- **Camera-wide:** `CameraBackend.metadata()`. `CanonCamera` combines DeviceInfo (identity,
  capabilities named through `PTPCatalog`/`CanonCatalog`) with every GetEvent property and
  allowed-value list (decoded by `CanonCatalog`). The capture loop refreshes it after connect, after
  live view starts, and once a second while streaming.
- **Per frame:** `CanonViewfinderParser` parses every block of each live-view payload into
  `CanonViewfinderMetadata` (cheap, no formatting). `CanonCamera` formats it into items at most
  4 times a second and attaches them to `CameraFrame.metadata`.
- **Consumers:** `CaptureStatus.cameraMetadata` / `.frameMetadata`. The app's Camera window and the
  CLI's text output show `documentedOnly`. `mirrorup camera info --json`, the snapshot sidecar and the
  diagnostics export keep everything, including undocumented codes.

## Camera controls

`CameraControlling` (`MirrorupCapture/CameraControls.swift`) is an optional backend capability:
settings (`CameraSetting`: aperture, shutter, ISO, brightness/exposure compensation, white balance,
colour temperature, Picture Style, AF method) with the options the camera currently allows,
autofocus, focus at a point, live-view zoom, and photo capture. `CaptureEngine.controls()` returns the
active backend when it conforms. `CanonCamera` implements it with Canon PTP commands (see
`canon-eos-ptp.md`, Controls); the commands go through the same `PTPSession` gate as frame polling,
so they interleave safely with streaming.

- Control state is read on demand only: when the popover opens and after each change.
- Points are normalized to the camera's live-view frame. The app maps a click on the 16:9 preview
  back to that frame by undoing mirroring/rotation (`FrameOrientation.cameraPoint`) and the centre
  crop.
- Mirror and upside down are app-side (`CaptureEngine.setOrientation`), applied after decoding with
  `VTPixelRotationSession`, and skipped entirely when off.

## Capture state machine

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> discovering: start()
    discovering --> connecting: backend created
    connecting --> initializing: connected
    initializing --> ready: live view armed
    ready --> streaming: first frame published
    discovering --> recovering: failure
    connecting --> recovering: failure
    initializing --> recovering: failure
    ready --> recovering: failure
    streaming --> recovering: disconnect / timeout / stall / protocol error
    recovering --> discovering: backoff elapsed (retry)
    recovering --> failed: fatal (e.g. access denied) or attempts exhausted
    streaming --> streaming: invalid frame (skipped, counted)
    failed --> discovering: start()
    idle --> idle: stop()
    streaming --> idle: stop()
    recovering --> idle: stop()
```

Every transition goes through `CaptureStateMachine.handle(_:)`, a pure value-type reducer with a
test per transition. There are no ad-hoc flags. Each engine run has a generation number, so late
events from a cancelled loop are ignored.

## Frame flow and timing

1. `CanonCamera.nextFrame()` polls `GetViewfinderData`. The first byte request is stamped
   `acquisitionStart` (host time). Not-ready replies (`0xA102`) are retried every 3 ms.
2. The payload is parsed in place. The JPEG is a `Data` slice of the transfer buffer and is never
   copied. `acquisitionEnd` is stamped when the transfer completes; this is the frame's capture time.
3. `FrameDecoder` wraps the JPEG bytes in a `CMBlockBuffer` without copying. VideoToolbox decodes it
   (hardware where available) and scales/crops it in one pass into a pooled IOSurface-backed 1280×720
   `420v` buffer.
4. `LatestFrameBuffer.publish` replaces any unconsumed frame (counted as a drop) and wakes waiters.
5. The app forwards the frame to the CMIO sink queue. If the queue is full it drops the frame; it
   never blocks. The frame also goes to the preview, which keeps only the newest frame.
6. The extension forwards each new sink frame to the source stream as soon as it arrives. A 30 Hz
   timer only fills gaps (repeats the last frame, or shows the fallback when the app is silent for
   more than 500 ms), so clients get a steady stream without the extension adding a frame interval
   of latency.

All timestamps are `mach_absolute_time` host time, the clock behind `CMClockGetHostTimeClock()`, so
values compare directly across the app/extension boundary. Frame age at delivery =
`delivery − acquisitionEnd`. That measures processing latency, not glass-to-glass latency: the camera's
exposure, its encoding and its internal buffering happen before `acquisitionEnd`, and the clients'
render path after delivery is not measured.

## Why these choices

- **ImageCaptureCore instead of IOUSBHost/DriverKit:** it is the only supported path while `ptpcamerad`
  runs, and it measured 29.8 fps with ~15 ms acquisition. DriverKit would need Apple-granted
  entitlements and would replace the system driver.
- **Polling, not events, for frames:** the camera exposes no frame-ready event. Fast polling with a
  short retry keeps frames fresh. About 70% of polls return not-ready at the camera's ~30 fps cadence.
  Polls cost ~1 ms each and CPU stays around 6.5% of one core (see `performance.md`).
- **Single-slot buffers everywhere:** latency is bounded by construction. A slow consumer loses frames
  instead of accumulating delay.
- **One fixed output format (1280×720 '420v' @ 30):** the extension advertises only what it can
  always produce. The camera's 960×640 or 1024×576 frames are aspect-filled and centre-cropped into it.
