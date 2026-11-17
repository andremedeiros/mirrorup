<img src="docs/images/mirrorup-icon.png" alt="Mirrorup icon: a seven-blade aperture glowing amber" width="128">

# Mirrorup

Mirrorup turns a camera on USB into a low-latency macOS webcam. Canon EOS cameras are supported today;
other makers plug in as drivers ([docs/adding-a-camera.md](docs/adding-a-camera.md)). It is a native Swift menu-bar app plus a
CoreMediaIO Camera Extension that publishes your camera, named after it (e.g. **Canon EOS Rebel SL2 (Mirrorup)**), to FaceTime, Safari/WebRTC, Zoom,
Teams, OBS, QuickTime and any other camera app.

It talks to the camera with its own Swift implementation of PTP (ISO 15740) and each maker's live-view
vendor extensions. It has no third-party dependencies, no libgphoto2, no vendor SDK and no private Apple API.

> Mirrorup is an independent project. It is not affiliated with, endorsed by or sponsored by any camera
> maker. "Canon" and "EOS" are trademarks of Canon Inc. and are used here only to describe compatible
> cameras.

## Why

Canon's EOS Webcam Utility is unreliable and laggy. Mirrorup is built around these goals:

- **Bounded latency:** single-slot buffers everywhere, so a slow consumer drops frames instead of
  adding delay.
- **Recovery:** an explicit capture state machine with exponential backoff and jitter. Mirrorup
  reconnects after unplugging, camera power-off, stalls and protocol errors, and says when the USB
  connection itself keeps dropping.
- **Observability:** OSLog categories, signposts, and live metrics (camera FPS, decode time, frame age,
  drops, reconnects) with diagnostics export.
- **One owner per camera:** the app holds the camera session, and any number of apps can use
  the Mirrorup camera at once.
- **Nothing hidden:** every value the camera reports is decoded to human terms (lens, aperture,
  shutter, ISO, white balance, image quality, battery, focus points, sensor size, formats...) in the
  app's Camera window and `mirrorup camera info`. Codes no public source documents are kept, raw,
  in the JSON export and diagnostics.

## Status

| Component | Status |
|---|---|
| USB discovery, descriptor inspection | ✅ verified on hardware |
| PTP session and GetDeviceInfo (ImageCaptureCore transport) | ✅ verified on hardware |
| Direct IOUSBHost transport | ⚠️ implemented and unit-tested; blocked while macOS's `ptpcamerad` owns the interface (always, in a normal session). See [docs/usb-feasibility.md](docs/usb-feasibility.md) |
| Canon live view, snapshot, benchmark | ✅ verified: **29.96 fps for 10 minutes, 0 invalid frames, 6.9% CPU, 10.6 MB** |
| Capture engine, recovery from unplug and power-off | ✅ verified on hardware (stream back 0.8–1.1 s after the camera reappears) |
| Menu-bar app (capture, preview, diagnostics) | ✅ runs and streams on hardware |
| Camera Extension | ✅ activates and streams on macOS 27.2 (unmanaged Mac). MDM policies that forbid unlisted system extensions block it |
| Video app validation | ✅ Photo Booth, FaceTime; ⏳ QuickTime / Safari not tested yet |

### Cameras

| Camera | USB ID | Status |
|---|---|---|
| Canon EOS Rebel SL2 / 200D | `04A9:32CC` | ✅ validated on firmware 1.0.1 and 1.1.0 (live view 960×640 or 1024×576 depending on camera settings, ~30 fps) |
| Other Canon EOS DSLRs/mirrorless | `04A9:*` | Should work if the body lists GetViewfinderData (`0x9153`) in its DeviceInfo. Unvalidated |
| Other makers | — | No driver yet. `mirrorup devices` lists them as "not supported yet"; the app says so by name. |

## Requirements

- macOS 26 or later; Apple Silicon (Intel builds, unvalidated).
- Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build the app.
- An Apple Development certificate, with your Apple ID signed in to Xcode (the Camera Extension must be signed).
- A supported camera on USB (see above), in a stills shooting mode, menus closed. Plugging it
  straight into the Mac is more reliable than through an adapter or hub. Turning the camera's
  **Auto power off** to Disable keeps it ready: Mirrorup keeps it awake only while it is connected.

## Build

```bash
make build        # Swift package + CLI (warnings are errors)
make test         # all hardware-independent tests
make install-app  # generate the Xcode project, build, copy to /Applications
```

See [docs/development.md](docs/development.md) for signing, identifiers and hardware tests.

## Run

**App:** launch `/Applications/Mirrorup.app`. On first launch it asks macOS to install the Camera
Extension. Approve it in System Settings → General → Login Items & Extensions → Camera Extensions,
then choose the camera named after yours (e.g. **Canon EOS Rebel SL2 (Mirrorup)**; **Mirrorup Camera**
before any camera has connected) in your video app. Click the menu-bar icon for the live preview, the
streaming switch, the camera's current lens and exposure, and camera controls:

- **Focus:** the Focus button autofocuses; in the 1-point AF focus mode, clicking the preview focuses
  there, with a square that turns green on a lock or yellow when the camera can't lock.
- **Brightness** (exposure compensation), white balance, Picture Style, ISO, focus mode,
  aperture/shutter when the mode allows them, live-view zoom (1×/5×, click to move the zoomed area),
  Mirror / Upside Down, and **Enhance** (Apple silicon): sharpens the picture with Apple's
  machine-learning upscaler at the cost of about 12 ms more latency per frame.
- **Battery** level and **Take Photo**: a full-resolution photo, saved to Pictures › Mirrorup (it
  also stays on the camera's card).

Controls show only what the camera allows in its current mode and follow the mode dial live. The
green Scene Intelligent Auto mode allows only the focus mode; P adds brightness, white balance,
Picture Style and ISO. In P and Av the camera keeps the picture equally bright whatever the ISO, so
ISO changes only the grain; use Brightness to change brightness. With the power switch on the movie
(camcorder) position the camera streams 16:9, offers fewer settings and refuses photos; Mirrorup says
so in the popover.

The ⋯ menu holds Camera Info (every setting the camera reports, searchable), Diagnostics and
Settings (camera source, start streaming at launch, open at login, camera extension).

**CLI:**

```bash
mirrorup devices                                   # attached cameras and their drivers
mirrorup inspect                                   # USB descriptors, endpoints, interface owner
mirrorup camera info [--json all.json]             # everything the camera reports, decoded
mirrorup ptp info                                  # parsed GetDeviceInfo
mirrorup ptp operations                            # operations/events/properties/formats by name
mirrorup liveview snapshot --output frame.jpg      # one real frame + frame.jpg.json metadata
mirrorup liveview benchmark --duration 60          # measured FPS and timing distributions
```

**Safari check:** `cd web && python3 -m http.server 8000`, then open
`http://localhost:8000/webcam-test.html`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No camera found" | Turn the camera on and check the cable. `mirrorup devices` shows what Mirrorup sees and which driver claims it. |
| "… is connected but not responding" | The camera is on USB but macOS's Image Capture doesn't list it, usually after a USB dropout left it stuck. Turn it off and on again. |
| "The camera's USB connection dropped … times" | The cable, adapter or port is dropping the connection (macOS logs `hardware connection lost`). Try another cable, or plug the camera straight into the Mac. |
| "Mirrorup doesn't support … yet" | The camera was found but no driver supports it. See [docs/adding-a-camera.md](docs/adding-a-camera.md). |
| "The camera can't start live view" | Set the mode dial to P/Av/Tv/M/Auto and close menus and playback on the camera. |
| "Another app is using the camera" | Quit Photos, Image Capture, or the maker's utility (e.g. EOS Utility, EOS Webcam Utility). |
| Mirrorup camera missing from apps | Check `systemextensionsctl list`. Approve the extension in System Settings. On managed Macs, ask IT to allowlist `cool.andre.Mirrorup.CameraExtension` (see docs/development.md). Right after an update, reopen the video app; if Mirrorup asks you to restart your Mac, do so (macOS 27.2 sometimes fails to start an updated camera extension). |
| "The camera did not take the photo… turn it to the movie position and back to ON" | The camera is stuck refusing the shutter (it ignores its own shutter button too). Turn the power switch to the camcorder icon and back to ON. |
| Camera screen stays dark after quitting | Restart the camera. Mirrorup hands output back to the rear screen on stop, but a force-killed app can't. |
| Logs | `log stream --predicate 'subsystem == "cool.andre.Mirrorup"' --level debug`, or Diagnostics → Export. |

## Known limitations

- Output is fixed at 1280×720 `420v` @ 30 fps. Camera frames (960×640 or 1024×576) are scaled to
  fill it and centre-cropped. USB live view on the SL2 is ~30 fps; there is no 1080p over USB.
- The SL2's 10× live-view zoom sends the same image as 5× over USB, so only 1× and 5× are offered.
- Photo capture is verified for JPEG to the card; RAW and RAW+JPEG downloads are untested.
- Direct USB access only works when no other process owns the PTP interface. Mirrorup never kills
  system services to get it.
- Glass-to-glass latency has not been measured; see [docs/performance.md](docs/performance.md).
- On macOS 27.2, replacing a running camera extension can leave it stopped until the Mac restarts
  (OBS has the same problem). The extension has its own version, so only updates that change it
  replace it, and Mirrorup asks for a restart when it happens.

## Documentation

- [Architecture](docs/architecture.md): processes, modules, concurrency, frame flow
- [USB feasibility](docs/usb-feasibility.md): IOUSBHost vs ImageCaptureCore experiments on macOS 26+
- [Adding a camera maker](docs/adding-a-camera.md): the driver contract and checklist
- [Canon EOS PTP notes](docs/canon-eos-ptp.md): opcodes, payloads, sequences, verified vs hypothesis
- [Performance](docs/performance.md): benchmarks and optimisation decisions
- [Development](docs/development.md): build, sign, test

## License

MIT; see [LICENSE](LICENSE). libgphoto2 (LGPL-2.1) was used only as a protocol reference; no code was copied.
