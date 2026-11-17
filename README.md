# Mirrorup

Mirrorup turns a Canon DSLR into a low-latency macOS webcam. It is a native Swift menu-bar app plus a
CoreMediaIO Camera Extension that publishes **Mirrorup Camera** to FaceTime, Safari/WebRTC, Zoom,
Teams, OBS, QuickTime and any other camera app.

It talks to the camera with its own Swift implementation of PTP (ISO 15740) and Canon's live-view
vendor extensions. It has no third-party dependencies, no libgphoto2, no Canon SDK and no private Apple API.

> Mirrorup is an independent project. It is not affiliated with, endorsed by or sponsored by Canon Inc.
> "Canon" and "EOS" are trademarks of Canon Inc. and are used here only to describe compatible cameras.

## Why

Canon's EOS Webcam Utility is unreliable and laggy. Mirrorup is built around four goals:

- **Bounded latency:** single-slot buffers everywhere, so a slow consumer drops frames instead of
  adding delay.
- **Recovery:** an explicit capture state machine with exponential backoff and jitter. Mirrorup
  reconnects after unplugging, camera power-off, stalls and protocol errors.
- **Observability:** OSLog categories, signposts, and live metrics (camera FPS, decode time, frame age,
  drops, reconnects) with diagnostics export.
- **One owner per camera:** the app holds the camera session, and any number of apps can use
  Mirrorup Camera at once.

## Status

| Component | Status |
|---|---|
| USB discovery, descriptor inspection | ✅ verified on hardware |
| PTP session and GetDeviceInfo (ImageCaptureCore transport) | ✅ verified on hardware |
| Direct IOUSBHost transport | ⚠️ implemented and unit-tested; blocked while macOS's `ptpcamerad` owns the interface (always, in a normal session). See [docs/usb-feasibility.md](docs/usb-feasibility.md) |
| Canon live view, snapshot, benchmark | ✅ verified: **29.96 fps for 10 minutes, 0 invalid frames, 6.9% CPU, 10.6 MB** |
| Capture engine, recovery from unplug and power-off | ✅ verified on hardware (stream back 0.8–1.1 s after the camera reappears) |
| Menu-bar app (capture, preview, diagnostics) | ✅ runs and streams on hardware |
| Camera Extension (Mirrorup Camera) | ⏳ builds and signs; **activation not yet validated**. The development Mac's MDM policy forbids unlisted system extensions |
| QuickTime / Safari / FaceTime validation | ⏳ pending (needs the extension active) |

### Cameras

| Camera | USB ID | Status |
|---|---|---|
| Canon EOS Rebel SL2 / 200D | `04A9:32CC` | ✅ validated on firmware 1.0.1 and 1.1.0 (live view 960×640 or 1024×576 depending on camera settings, ~30 fps) |
| Other Canon EOS DSLRs/mirrorless | `04A9:*` | Should work if the body lists GetViewfinderData (`0x9153`) in its DeviceInfo. Unvalidated |

## Requirements

- macOS 26 or later; Apple Silicon (Intel builds, unvalidated).
- Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build the app.
- An Apple Development certificate, with your Apple ID signed in to Xcode (the Camera Extension must be signed).
- A Canon camera on USB, in a stills shooting mode, menus closed.

## Build

```bash
make build        # Swift package + CLI (warnings are errors)
make test         # 136 hardware-independent tests
make install-app  # generate the Xcode project, build, copy to /Applications
```

See [docs/development.md](docs/development.md) for signing, identifiers and hardware tests.

## Run

**App:** launch `/Applications/Mirrorup.app`. On first launch it asks macOS to install the Camera
Extension. Approve it in System Settings → General → Login Items & Extensions → Camera Extensions,
then choose **Mirrorup Camera** in your video app. The menu-bar icon shows the camera status and has
start/stop, the preview and diagnostics.

**CLI:**

```bash
mirrorup devices                                   # attached Canon cameras
mirrorup inspect                                   # USB descriptors, endpoints, interface owner
mirrorup ptp info                                  # parsed GetDeviceInfo
mirrorup ptp operations                            # supported operations/events/properties
mirrorup liveview snapshot --output frame.jpg      # one real live-view frame
mirrorup liveview benchmark --duration 60          # measured FPS and timing distributions
```

**Safari check:** `cd web && python3 -m http.server 8000`, then open
`http://localhost:8000/webcam-test.html`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No camera found" | Turn the camera on. A camera that is off still shows up on USB but not to Image Capture. |
| "The camera can't start live view" | Set the mode dial to P/Av/Tv/M/Auto and close menus and playback on the camera. |
| "The camera is in use by another app" | Quit Photos, Image Capture, EOS Utility or EOS Webcam Utility. |
| Mirrorup Camera missing from apps | Check `systemextensionsctl list`. Approve the extension in System Settings. On managed Macs, ask IT to allowlist `cool.andre.Mirrorup.CameraExtension` (see docs/development.md). |
| Camera screen stays dark after quitting | Restart the camera. Mirrorup hands output back to the rear screen on stop, but a force-killed app can't. |
| Logs | `log stream --predicate 'subsystem == "cool.andre.Mirrorup"' --level debug`, or Diagnostics → Export. |

## Known limitations

- Output is fixed at 1280×720 `420v` @ 30 fps. Camera frames (960×640 or 1024×576) are scaled to
  fill it and centre-cropped. USB live view on the SL2 is ~30 fps; there is no 1080p over USB.
- Camera controls (ISO, shutter, aperture, WB, AF) are not exposed yet. The protocol notes in
  [docs/canon-eos-ptp.md](docs/canon-eos-ptp.md) cover the properties for a future version.
- Direct USB access only works when no other process owns the PTP interface. Mirrorup never kills
  system services to get it.
- Glass-to-glass latency has not been measured; see [docs/performance.md](docs/performance.md).

## Documentation

- [Architecture](docs/architecture.md): processes, modules, concurrency, frame flow
- [USB feasibility](docs/usb-feasibility.md): IOUSBHost vs ImageCaptureCore experiments on macOS 26+
- [Canon EOS PTP notes](docs/canon-eos-ptp.md): opcodes, payloads, sequences, verified vs hypothesis
- [Performance](docs/performance.md): benchmarks and optimisation decisions
- [Development](docs/development.md): build, sign, test

## License

MIT; see [LICENSE](LICENSE). libgphoto2 (LGPL-2.1) was used only as a protocol reference; no code was copied.
