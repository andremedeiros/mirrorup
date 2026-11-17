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
| `EXTENSION_VERSION` | `${EXTENSION_VERSION}` from the environment (`macOS/extension-version.sh`) | the Camera Extension's `CFBundleVersion` |

The Makefile derives `DEVELOPMENT_TEAM` from the organizational unit of your first "Apple Development"
certificate. That is the team ID, which is **not** the ID in parentheses in the certificate's name.
Override it with `make app DEVELOPMENT_TEAM=XXXXXXXXXX`. To ship your own build, change
`APP_BUNDLE_ID` to a prefix you own.

The Camera Extension has its own build number, so app-only changes never replace an installed
extension (macOS 27.2 can lose a replaced extension until the Mac restarts). `extension-version.sh`
prints the number of commits touching what the extension is built from (`macOS/MirrorupCameraExtension`,
`macOS/Shared`, `macOS/project.yml`, `Sources/MirrorupDiagnostics`, the script itself). With uncommitted
changes there it appends a hash of them, so a development build with edited extension sources
installs, and rebuilding the same edit doesn't. The Makefile passes it to XcodeGen. Its short
version is fixed at 1.0: the system compares both.

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
   whenever the embedded extension's version changes) the app submits the Camera Extension
   activation request by itself, then relaunches itself to connect to the new extension.
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

## Releases

Pushing a tag `vMAJOR.MINOR[.PATCH]` runs `.github/workflows/release.yml` on GitHub's `xcode-27`
runner (Xcode 27.2). It runs `make build test`, archives the app signed with Developer ID, notarizes
and staples it, and attaches `Mirrorup-<version>.zip` to a GitHub release with generated notes. The
version comes from the tag (`MARKETING_VERSION`), the app's build number from the workflow run number
(`CURRENT_PROJECT_VERSION`), the extension's from its own history (above; the checkout fetches the
full history for it). Installed apps replace the extension only when that number changes.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

One-time setup (Apple Developer Program account holder or admin):

1. **Developer ID Application certificate.** Xcode → Settings → Accounts → Manage Certificates → + →
   Developer ID Application. Export it with its private key from Keychain Access as a `.p12` with a
   password.
2. **Developer ID provisioning profile for the app** (the extension needs none). In Certificates,
   Identifiers & Profiles → Profiles → +, pick Developer ID (macOS), the app ID `APP_BUNDLE_ID`
   (registered with the System Extension capability by the first `make app`) and the certificate
   from step 1. Download it.
3. **Notarization key.** App Store Connect → Users and Access → Integrations → Team Keys → +
   (Developer access is enough). Download the `.p8` (only possible once) and note the key ID and
   issuer ID.
4. **Repository secrets and variable** (the workflow names any that are missing):

   ```bash
   gh variable set DEVELOPMENT_TEAM --body XXXXXXXXXX   # team ID: the certificate's OU
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12
   gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD
   base64 -i Mirrorup_Developer_ID.provisionprofile | gh secret set APP_PROVISIONING_PROFILE
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY
   gh secret set NOTARY_API_KEY_ID
   gh secret set NOTARY_API_ISSUER_ID
   ```

The workflow signs manually: it passes the profile's name as `MIRRORUP_APP_PROFILE`, which the app
target's `PROVISIONING_PROFILE_SPECIFIER` reads (empty locally, so local builds keep automatic
signing). Bundle IDs are read from the profile, never repeated in the workflow.

Upgrading an installed copy replaces the running extension, which macOS 27.2 can fail to relaunch
(see `AGENTS.md`). The app relaunches itself and, if the camera still doesn't appear, asks for a
restart; video apps that were open may need reopening.

## Fixtures

`Tests/*/Fixtures/*-sl2.bin` are raw data phases captured from the real SL2 via ImageCaptureCore
pass-through (`GetDeviceInfo`, the first `GetEvent` after SetEventMode(1), and one
`GetViewfinderData` payload). They contain the camera's serial number and nothing else personal.
