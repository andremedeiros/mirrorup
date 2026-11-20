# AGENTS.md — instructions for coding agents

Mirrorup turns a USB camera into a macOS webcam through per-maker drivers (shipped: Canon EOS,
validated on the EOS Rebel SL2 / 200D). Read `docs/architecture.md` first; the driver contract is in
`docs/adding-a-camera.md`, Canon protocol facts in `docs/canon-eos-ptp.md`, platform constraints in
`docs/usb-feasibility.md`.

## Layout

| Path | What | Depends on |
|---|---|---|
| `Sources/MirrorupDiagnostics` | OSLog loggers, signposts, `HostTime`, bounded metrics | — |
| `Sources/MirrorupPTP` | ISO 15740 containers, codec, `PTPSession`, USB framing (`PTPUSBTransport`) | Diagnostics |
| `Sources/MirrorupUSB` | IOUSBHost discovery/descriptors and bulk pipe | PTP |
| `Sources/MirrorupImageCapture` | ImageCaptureCore browser + PTP pass-through transport | PTP |
| `Sources/MirrorupCapture` | `CameraBackend` contract, capture engine/state machine, decoder, latest-frame buffer, `SyntheticCamera` | Diagnostics |
| `Sources/MirrorupDevices` | Vendor-neutral discovery (`CameraDiscovery`), `CameraDriver`, `CameraRegistry`, PTP→`CameraError` mapping | PTP, USB, ImageCapture, Capture |
| `Sources/MirrorupCanon` | `CanonDriver` + Canon EOS backend (`CanonCamera`), events, EVF parsing, controls | PTP, Capture, Devices |
| `Sources/MirrorupCameras` | `CameraRegistry.builtIn`: the shipped driver list (only module that knows every driver) | Devices, drivers |
| `Tools/MirrorupCLI` | `mirrorup` CLI | all |
| `macOS/` | SwiftUI menu-bar app + CoreMediaIO Camera Extension. `project.yml` (XcodeGen) is the only project definition; the `.xcodeproj`, Info.plists and entitlements are generated and untracked. `Shared/AppIcon.icon` (Icon Composer: SVG layers + `icon.json`, edit in Xcode's Icon Composer) is the icon of both targets; `docs/images/mirrorup-icon.png` is its 256 px render | package products |
| `web/webcam-test.html` | Safari/WebRTC validation page | — |
| `.github/workflows/release.yml` | Actions → Release → Run workflow → requires CI passed on the commit → approved via the `release` environment → Developer ID archive, notarize, Sparkle-signed appcast, Copilot-written notes, draft GitHub release (setup: `docs/development.md`) | — |
| `.github/workflows/ci.yml` | every PR, push to `main` and manual run → `make build test` on the release runner; releases require it on their commit | — |

## Hard constraints

- Swift 6 language mode, strict concurrency, no warnings (`make build` uses `-warnings-as-errors`).
- No third-party dependencies, no libgphoto2/Rust/C transport code, no private Apple API. One
  exception: the app target links Sparkle (pinned in `macOS/project.yml`) for updates; the Swift
  package, the CLI and the Camera Extension stay dependency-free.
- Release signing keys live only in the `release` environment. In `release.yml`, nothing from outside
  this repository (Homebrew, npm, package resolution) runs after "Install signing certificate and
  profile"; actions and Sparkle are pinned to commit hashes (Dependabot moves the action pins).
- Vendor opcodes, wording and quirks stay in the driver module (`MirrorupCanon`, …); `MirrorupPTP`,
  `MirrorupCapture`, `MirrorupDevices`, the app and the CLI contain no vendor logic and no vendor
  wording shown to users (doc comments may cite makers as examples). Backends phrase
  user-facing hints and errors in the camera's own terms (`CameraControlState.hint`,
  `CameraSettingState.title`, `CameraError.message`); the app shows them as is.
- Drivers never depend on each other; `MirrorupCameras` is the only place listing them.
- Only one process owns the camera: the app. The Camera Extension never opens USB/ImageCaptureCore.
- Never terminate `ptpcamerad` or other system services. Default transport is ImageCaptureCore.
- No unbounded frame queues anywhere. Drop stale frames instead of adding latency.
- Do not change camera settings beyond what live view requires; restore what you changed on stop
  (Canon: `0xD1B0`). Never send Canon MovieSelectSWOn/Off (0x9133/0x9134): it can leave the SL2
  refusing every shutter release until its power switch is cycled.
- User-facing text comes from `CameraError.message`; raw PTP/IOReturn codes go in `detail` only.
- Never drop camera metadata and never show magic values: decode every property, event, format and
  live-view block into `CameraMetadata` with human values (Canon: `CanonCatalog`, `CanonViewfinderMetadata`).
  Undocumented codes are kept with `isDocumented == false` (hidden in UI, kept in JSON/diagnostics);
  never guess a meaning. Identify things with enums (`ItemKind`, `SectionKind`, `WindowID`), not strings.
- Don't publish measurements you didn't take; benchmarks live in `benchmarks/` with their raw output.
- Never hand-edit or commit generated Xcode artifacts. Change `macOS/project.yml` and run `make project`.
  Identifiers come from `APP_BUNDLE_ID`/`EXTENSION_BUNDLE_ID` there; never repeat them in code or plists.
- The Camera Extension's build number comes from `macOS/extension-version.sh` (commits touching its
  sources); never bump it by hand, and never tie it to the app's version: replacing a running
  extension can need a restart on macOS 27.2. Nothing in the extension may crash (no `fatalError`,
  force unwraps or `try!`): a relaunched extension is invisible to video apps already connected.
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
.build/debug/mirrorup ptp dump --body 7d --output-dir fixtures   # raw fixtures, serial zeroed
.build/debug/mirrorup liveview snapshot --output frame.jpg
.build/debug/mirrorup liveview benchmark --duration 60 --json out.json
log stream --predicate 'subsystem == "cool.andre.Mirrorup"' --level debug
# Debug builds: render the popover (live model, real camera state) to a PNG ~8 s after launch.
# Use this to check UI layout; the agent terminal has no Screen Recording permission. The video
# layer itself renders black in the snapshot.
open /Applications/Mirrorup.app --args -MirrorupSnapshotPopover /tmp/popover.png
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
- A camera can be on USB but not in ImageCaptureCore: the SL2 stayed that way for minutes after a
  USB dropout (until power-cycled). Switching the SL2 off with its power switch removes it from USB
  entirely (2026-11-17).
- ptpcamerad answers PTP pass-through only after cataloguing the card. A 7D with 479 files took
  10–24 s after `requestOpenSession`, and not only on a cold attach: every new process pays it
  again (23.8 s, 23.9 s on an attached, powered 7D), while later sessions in the same process are
  ready at once. `contentCatalogPercentCompleted` sits at 0 for ~9.5 s, then counts 1→100 in ~150 ms
  steps (KVO works). Commands sent earlier time out. The transport
  waits for `deviceDidBecomeReady(withCompleteContentCatalog:)` (bounded at 60 s, cancellable) and
  reports it as `PTPPreparation.indexingStorage`; the engine shows `.preparing(.readingStorage)`
  and swaps the 10 s connect deadline for `preparationTimeout` (90 s) meanwhile, so a cold start
  connects in one session instead of timing out and reconnecting. Every surface that shows this
  wait (popover, CLI, docs) also shows `CameraPreparation.explanation`: users read "memory card"
  as the app reading their photos, and Mirrorup copies none (only a Take Photo shot).
- A cancelled pass-through request must not fail the session: a capture stop lands during a
  frame poll often (3 of 5 stops on a 7D), and teardown still has to restore `0xD1B0` and leave remote mode.
- System extensions activate only from `/Applications`, and the user must approve them in
  System Settings → General → Login Items & Extensions. MDM policies with `AllowUserOverrides = false`
  deny unlisted extensions outright (seen on a Kandji-managed Mac; error `forbiddenBySystemPolicy`).
- The signing team ID is the certificate's OU, not the ID shown in the certificate name.
- On a killed host process the camera keeps `0xD1B0` with the PC bit set; stop always clears it.
- Actor methods are re-entrant: serialize PTP transactions with `PTPSession`'s gate, not the actor.
- A sink `CMSampleBuffer` with the `DisplayImmediately` sample attachment fails to deserialize in the
  Camera Extension (`FigSampleBufferSerialization` -19646, `CMIOExtensionSample alloc failed`) and
  the extension shows the fallback frame. Only the preview's own buffer carries that attachment.
- Replacing a CMIO extension while its process runs loses the launchd job on macOS 27.2
  (`Submit job failed … error = 37: Operation already in progress`, then `removing service`): sysextd
  reports `activated enabled` but nothing runs and no camera exists (also reported by OBS users).
  Seen on 6 of 6 upgrades over a running extension; upgrading over a lost job works. Re-activating
  the same version is a no-op (sysextd `alreadyActive`), and quitting the extension first doesn't help
  (launchd respawns it within ~20 ms). Only a restart or the next version recovers it.
- When the extension process respawns (same launchd job), connected CoreMediaIO clients never
  reconnect (none within 45 s; AVFoundation clients included); fresh processes see it. After an
  upgrade, Photo Booth picked up the new process but the app's own sink did not, so the app
  relaunches itself after replacing the extension.
- Renaming the device = removing it and adding a new `CMIOExtensionDevice` (`localizedName` is
  read-only). Reused stream IDs fail with `streamID already included` (removal is asynchronous), and a
  client streaming into the sink never sees the replacement, so the sink stops before renaming.
- Extension custom properties (`4cc_<sel>_glob_0000`, string values) are cached client-side until
  the extension calls `notifyPropertiesChanged`.

## Testing conventions

Swift Testing (`import Testing`). Deterministic fixtures captured from real bodies are in
`Tests/*/Fixtures` (`deviceinfo-sl2.bin`, `getevent-initial-sl2.bin`, `evf-sl2.bin`, and the `-7d`
set from an EOS 7D). Capture new ones with `mirrorup ptp dump --body <name> --output-dir <dir>`
(serial zeroed unless `--keep-serial`; aim the camera at a blank surface, the EVF frame is an image). Hardware tests
are in `Tests/MirrorupIntegrationTests/HardwareTests.swift`, gated by `MIRRORUP_HARDWARE_TESTS=1`.
`SimulatedSL2` (Canon tests) and `SyntheticCamera` cover protocol and engine behaviour without hardware.
