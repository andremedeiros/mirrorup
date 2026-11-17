# Development

## Prerequisites

- macOS 26 or later (developed on 27.2), Apple Silicon (Intel builds compile but are not validated).
- Xcode 26+ with its command-line tools selected (`xcode-select -p`). Developed with Xcode 27.2 / Swift 6.4.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `macOS/project.yml` is
  the only source of truth for the Xcode project, both Info.plists and both entitlements files; none
  of those are committed. `make project` (and therefore `make app`) generates them.
- An Apple Development certificate in your keychain and your Apple ID signed in under Xcode → Settings
  → Accounts. The Camera Extension is a system extension, so it must be signed with a provisioning
  profile that has the System Extension capability. Xcode creates that profile automatically and
  registers your Mac (`-allowProvisioningDeviceRegistration`).

## Identifiers and signing

Everything is derived from two settings in `macOS/project.yml`:

| Setting | Value | Used for |
|---|---|---|
| `APP_BUNDLE_ID` | `cool.andre.Mirrorup` | app bundle ID, extension app group (`$(TeamIdentifierPrefix)$(APP_BUNDLE_ID)`) |
| `EXTENSION_BUNDLE_ID` | `$(APP_BUNDLE_ID).CameraExtension` | extension bundle ID and product name, CMIO Mach service name, and the app's `MirrorupCameraExtensionBundleIdentifier` Info.plist key (read by `ExtensionManager`) |
| `DEVELOPMENT_TEAM` | `${DEVELOPMENT_TEAM}` from the environment | signing team |

The Makefile derives `DEVELOPMENT_TEAM` from the organizational unit of your first "Apple Development"
certificate. That is the team ID, which is **not** the ID in parentheses in the certificate's name.
Override it with `make app DEVELOPMENT_TEAM=XXXXXXXXXX`. To ship your own build, change
`APP_BUNDLE_ID` to a prefix you own.

## Build and test

```bash
make build          # swift build with -warnings-as-errors
make test           # all hardware-independent tests
make cli            # release CLI → .build/release/mirrorup
make project        # generate macOS/Mirrorup.xcodeproj + plists + entitlements
make app            # generate, then build Mirrorup.app (+ embedded Camera Extension)
make install-app    # copy the app to /Applications
```

Tests use Swift Testing. Suites:

| Target | Covers |
|---|---|
| `MirrorupPTPTests` | container encode/decode, truncation and length limits, fragmentation at every byte boundary, ZLP rules, transaction IDs, session open/close, typed errors, timeouts, concurrency/cancellation of the transaction gate, DeviceInfo parsing (real SL2 fixture + mutation fuzzing) |
| `MirrorupUSBTests` | configuration-descriptor parsing and IOReturn mapping |
| `MirrorupCanonTests` | GetEvent parsing (real SL2 dump), EVF payload parsing (real SL2 frame), fuzzing, and `CanonCamera` against `SimulatedSL2` (init sequence, not-ready retries, timeouts, unplug, stop during pending frame, re-arming live view) |
| `MirrorupCaptureTests` | state machine transitions, recovery/backoff, watchdog, latest-frame buffer, decoder, `SyntheticCamera` fault injection, start/stop cycles |
| `MirrorupIntegrationTests` | opt-in hardware tests (`make test-hardware`) |

### Hardware tests

Connect the camera over USB, switch it on, set the mode dial to a stills mode (P/Av/Tv/M or Auto),
close any menus, then:

```bash
make test-hardware
.build/debug/mirrorup liveview benchmark --duration 600 --json benchmarks/run.json
```

The camera's own screen goes dark while Mirrorup streams (live view is routed to the PC) and comes back
when streaming stops.

## Running the app

1. `make install-app`, then launch `/Applications/Mirrorup.app` (menu bar icon). On first launch (and
   whenever the embedded extension's build number changes) the app submits the Camera Extension
   activation request by itself.
2. Approve it in System Settings → General → Login Items & Extensions → Camera Extensions.
   On MDM-managed Macs a system-extension policy with `AllowUserOverrides = false` silently denies
   unlisted extensions. `sysextd` logs `applyPolicy … -> Deny: extension's teamID and identifier are
   not in the list of allowed extensions` and the app shows "Your Mac's security policy doesn't allow
   the Mirrorup camera extension." Your administrator must allowlist the team ID and
   `cool.andre.Mirrorup.CameraExtension`.
3. Pick the Mirrorup camera in FaceTime, QuickTime (File → New Movie Recording), Safari, Zoom, etc.
   It is named after the selected camera, e.g. "Canon EOS Rebel SL2 (Mirrorup)", or "Mirrorup Camera"
   before any camera has connected.
4. Validate Safari with `web/webcam-test.html`:
   `cd web && python3 -m http.server 8000`, then open `http://localhost:8000/webcam-test.html`.

Useful commands:

```bash
systemextensionsctl list                         # extension state
log stream --predicate 'subsystem == "cool.andre.Mirrorup"' --level debug
xcrun xctrace record --template 'Time Profiler' --attach Mirrorup   # profiling
```

## Fixtures

`Tests/*/Fixtures/*-sl2.bin` are raw data phases captured from the real SL2 via ImageCaptureCore
pass-through (`GetDeviceInfo`, the first `GetEvent` after SetEventMode(1), and one
`GetViewfinderData` payload). They contain the camera's serial number and nothing else personal.
