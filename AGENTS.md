# AGENTS.md — instructions for coding agents

Mirrorup turns a Canon EOS camera (validated: EOS Rebel SL2 / 200D) into a macOS webcam. Read
`docs/architecture.md` first; protocol facts live in `docs/canon-eos-ptp.md`, platform constraints in
`docs/usb-feasibility.md`.

## Layout

| Path | What | Depends on |
|---|---|---|
| `Sources/MirrorupDiagnostics` | OSLog loggers, signposts, `HostTime`, bounded metrics | — |
| `Sources/MirrorupPTP` | ISO 15740 containers, codec, `PTPSession`, USB framing (`PTPUSBTransport`) | Diagnostics |
| `Sources/MirrorupUSB` | IOUSBHost discovery/descriptors and bulk pipe | PTP |
| `Sources/MirrorupImageCapture` | ImageCaptureCore browser + PTP pass-through transport | PTP |
| `Sources/MirrorupCapture` | `CameraBackend` contract, capture engine/state machine, decoder, latest-frame buffer, `SyntheticCamera` | Diagnostics |
| `Sources/MirrorupCanon` | Canon EOS backend (`CanonCamera`), events, EVF parsing, factory | all of the above |
| `Tools/MirrorupCLI` | `mirrorup` CLI | all |
| `macOS/` | SwiftUI menu-bar app + CoreMediaIO Camera Extension. `project.yml` (XcodeGen) is the only project definition; the `.xcodeproj`, Info.plists and entitlements are generated and untracked | package products |
| `web/webcam-test.html` | Safari/WebRTC validation page | — |

## Hard constraints

- Swift 6 language mode, strict concurrency, no warnings (`make build` uses `-warnings-as-errors`).
- No third-party dependencies, no libgphoto2/Rust/C transport code, no private Apple API.
- Canon opcodes stay in `MirrorupCanon`; `MirrorupPTP` stays vendor-neutral.
- Only one process owns the camera: the app. The Camera Extension never opens USB/ImageCaptureCore.
- Never terminate `ptpcamerad` or other system services. Default transport is ImageCaptureCore.
- No unbounded frame queues anywhere. Drop stale frames instead of adding latency.
- Do not change camera settings beyond what live view requires; restore `0xD1B0` on stop.
- User-facing text comes from `CameraError.message`; raw PTP/IOReturn codes go in `detail` only.
- Don't publish measurements you didn't take; benchmarks live in `benchmarks/` with their raw output.
- Never hand-edit or commit generated Xcode artifacts. Change `macOS/project.yml` and run `make project`.
  Identifiers come from `APP_BUNDLE_ID`/`EXTENSION_BUNDLE_ID` there; never repeat them in code or plists.
- The project name is Mirrorup. Never use "EOS" or "Canon" in product names (trademarks); naming the
  supported cameras in docs is fine.

## Commands

```bash
make build            # package + CLI, warnings are errors
make test             # all hardware-independent tests (no camera needed)
make test-hardware    # opt-in tests; camera connected, powered on, in a shooting mode
make cli              # release CLI at .build/release/mirrorup
make app              # generate the Xcode project from project.yml, build app + extension
make install-app      # copy to /Applications (required for system extension activation)
.build/debug/mirrorup devices | inspect | ptp info | ptp operations
.build/debug/mirrorup liveview snapshot --output frame.jpg
.build/debug/mirrorup liveview benchmark --duration 60 --json out.json
log stream --predicate 'subsystem == "cool.andre.Mirrorup"' --level debug
```

## Platform pitfalls (verified)

- `IOUSBHostInterface` open fails with `kIOReturnInternalError` (not ExclusiveAccess) while
  `ptpcamerad` owns the PTP interface; read `UsbExclusiveOwner` from the registry to explain it.
- ImageCaptureCore owns the PTP session and rewrites transaction IDs; never send OpenSession on that path.
- ImageCaptureCore has no request timeout/cancel API; the transport races its own deadline.
- The SL2 answers InitiateViewfinder (0x9151) with OperationNotSupported and does not list it.
  Live view is started by SetDevicePropValueEx `0xD1B0 = 2` alone; without it GetViewfinderData
  returns `0xA102` forever.
- About 70% of GetViewfinderData polls return `0xA102` (not ready) at 30 fps; this is normal.
- The live-view frame size depends on camera settings (960×640 and 1024×576 both observed). Always use
  the decoded size; never assume it.
- A camera that is switched off still enumerates on USB but not in ImageCaptureCore.
- System extensions activate only from `/Applications`, and the user must approve them in
  System Settings → General → Login Items & Extensions. MDM policies with `AllowUserOverrides = false`
  deny unlisted extensions outright (seen on a Kandji-managed Mac; error `forbiddenBySystemPolicy`).
- The signing team ID is the certificate's OU, not the ID shown in the certificate name.
- On a killed host process the camera keeps `0xD1B0` with the PC bit set; stop always clears it.
- Actor methods are re-entrant: serialize PTP transactions with `PTPSession`'s gate, not the actor.

## Testing conventions

Swift Testing (`import Testing`). Deterministic fixtures captured from the real SL2 are in
`Tests/*/Fixtures` (`deviceinfo-sl2.bin`, `getevent-initial-sl2.bin`, `evf-sl2.bin`). Hardware tests
are in `Tests/MirrorupIntegrationTests/HardwareTests.swift`, gated by `MIRRORUP_HARDWARE_TESTS=1`.
`SimulatedSL2` (Canon tests) and `SyntheticCamera` cover protocol and engine behaviour without hardware.
