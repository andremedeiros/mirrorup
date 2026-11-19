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

Tests use Swift Testing. `.github/workflows/ci.yml` runs `make build test` on every pull request and
every push to `main`, on the same `xcode-27` runner as releases. That runner is a loaded virtual
machine: tests wait for conditions with generous deadlines instead of sleeping fixed short windows,
and tests of the enhanced picture run only where the scaler really works (the VM claims it but
fails every frame). Suites:

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

Releases are made on GitHub, never from a laptop. Actions → **Release** → **Run workflow** (branch
`main`) → enter the version (`1.1.0`). Anyone with write access can start a run; it then waits for a
reviewer of the `release` environment (André or Dana; nobody approves their own run, admins can
bypass) before it receives any signing secret.

`.github/workflows/release.yml` runs on GitHub's `xcode-27` runner (Xcode 27.2). It refuses a
version that isn't `MAJOR.MINOR[.PATCH]`, already exists, or isn't above the highest `v*` tag; runs
`make build test`; archives the app signed with Developer ID; notarizes and staples it; signs the
zip for Sparkle and writes `appcast.xml`; writes release notes; and creates a **draft** release with
both files. The version input sets `MARKETING_VERSION`, the workflow run number the app's build
number (`CURRENT_PROJECT_VERSION`), the extension's own history its version (above; the checkout
fetches the full history for it). Installed apps replace the extension only when that number changes.

The reviewer reads the draft's notes, edits them if needed and clicks **Publish release**. Only then
does the `v<version>` tag exist (on the commit the run built) and do installed apps see the update.
A failed run leaves nothing behind; a draft nobody wants can simply be deleted.

**Release notes** come from GitHub Copilot: the workflow gives GitHub's generated notes (merged PRs
since the previous version) and the commit subjects to the Copilot CLI (pinned in the workflow, no
tools allowed) with a light model, `claude-haiku-5.5` unless the `RELEASE_NOTES_MODEL` variable says
otherwise (e.g. `gpt-6-luna`). It authenticates with the workflow's own `GITHUB_TOKEN`
(`copilot-requests: write`), so no token is stored; usage is billed to the repository owner's Copilot
plan. If Copilot fails (quota, unknown model), the draft gets GitHub's generated notes instead.

### Updates

Release builds update themselves with [Sparkle](https://sparkle-project.org) (`Updater.swift`, the
app's only third-party dependency). Sparkle checks daily and on "Check for Updates…" in the popover's
⋯ menu; installing always takes the user's click. The feed (`UPDATE_FEED_URL` in `project.yml`) is
`releases/latest/download/appcast.xml`, which GitHub serves from the newest release that is not a
pre-release: never mark a release as pre-release, or installed apps won't see it. The appcast lists
only its own release; Sparkle compares its `sparkle:version` (the run number) with the installed
app's `CFBundleVersion`, so the run number must keep increasing (don't rename or recreate the
workflow). Debug builds never start the updater.

Each update is signed with an EdDSA key on top of Apple's signature. The public key is
`UPDATE_PUBLIC_KEY` in `project.yml`; the private key is the `SPARKLE_ED_PRIVATE_KEY` secret (base64
of the 32-byte Ed25519 seed, the format of Sparkle's `generate_keys -x`). Keep a copy in a password
manager: without it no installed copy can be updated again, short of a manual reinstall.

One-time setup (Apple Developer Program account holder):

1. **Developer ID Application certificate.** Certificates, Identifiers & Profiles → Certificates → +
   → Developer ID Application (G2 Sub-CA), from a certificate signing request. Keep the private key:
   the `.p12` needs the certificate and its key (`openssl pkcs12 -export` builds one from both).
2. **Developer ID provisioning profile for the app** (the extension needs none). In Certificates,
   Identifiers & Profiles → Profiles → +, pick Developer ID (macOS), the app ID `APP_BUNDLE_ID`
   (registered with the System Extension capability by the first `make app`) and the certificate
   from step 1. Download it.
3. **Notarization key.** App Store Connect → Users and Access → Integrations → App Store Connect
   API → Team Keys → + (Developer access is enough). Download the `.p8` (only possible once) and
   note the key ID and the issuer ID shown above the keys.
4. **The `release` environment** (Settings → Environments): required reviewers, "Prevent self-review",
   and deployments limited to `main`. Its secrets and variable (the workflow names any that are missing):

   ```bash
   E="--env release"
   gh variable set DEVELOPMENT_TEAM $E --body XXXXXXXXXX   # team ID: the certificate's OU
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12 $E
   gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD $E
   base64 -i Mirrorup_Developer_ID.provisionprofile | gh secret set APP_PROVISIONING_PROFILE $E
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY $E
   gh secret set NOTARY_API_KEY_ID $E
   gh secret set NOTARY_API_ISSUER_ID $E
   gh secret set SPARKLE_ED_PRIVATE_KEY $E < sparkle-private-key.txt   # see "Updates" above
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

`mirrorup ptp dump --body <name> --output-dir <dir>` captures the same set from any attached body
(the `-7d` fixtures came from it). It overwrites the serial number with zeros of the same length
wherever it appears (`--keep-serial` to keep it). The EVF payload is a real picture of whatever the
camera sees, so point it at a blank wall first.
