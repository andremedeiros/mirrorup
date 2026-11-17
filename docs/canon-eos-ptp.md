# Canon EOS PTP notes for Mirrorup (EOS Rebel SL2 / 200D)

This file collects what Mirrorup needs to know to run live view on Canon EOS DSLRs over PTP,
with the Rebel SL2 / 200D (USB `0x04A9:0x32CC`) as the target body. It is written from
protocol knowledge. No code was copied from anywhere (see [Licensing](#12-licensing)).

## Provenance tags

Every claim carries one of these tags:

| Tag | Meaning |
|---|---|
| **Verified** | Verified (SL2 hardware): observed on the real SL2 through ImageCaptureCore `requestSendPTPCommand` pass-through. |
| **Ref(`file`:`function`)** | Reference (libgphoto2 `camlibs/ptp2/<file>`:`<function>`, master as of 2026-11-16). For bare `#define` tables it reads **Ref(`ptp.h`)**. |
| **Ext(source)** | Public reverse-engineering write-up, listed in [Sources](#13-sources). Not libgphoto2, and not seen on the SL2. |
| **Hyp** | Hypothesis. Not confirmed. Test it on hardware before relying on it. |

Byte order is little-endian everywhere. "u32" means an unsigned 32-bit LE integer.

**Transport context (Verified).** `/usr/libexec/ptpcamerad` owns the USB interface. Claiming it
directly through IOUSBHost fails with `kIOReturnExclusiveAccess`. ptpcamerad also owns the PTP
session, so Mirrorup never sends OpenSession `0x1002`/CloseSession `0x1003`. Every operation below
goes through the pass-through.

### Corrections to the original brief

These codes were wrong in the brief. The correct values come from **Ref(`ptp.h`)**:

- EVFMode is `0xD1B1`. `0xD1B3` is EVFSharpness.
- `0xD1BF` is MirrorLockupState, not a power property. `0xD303` is a Nikon property
  (UseDeviceStageFlag) and does not exist on Canon. The Canon auto-power-off property is `0xD114`.
- Event `0xC181` is ObjectAddedEx. RequestGetObjectInfoEx is `0xC183`. `0xC1A7` is ObjectAddedEx64.
  `0xC18B` is CameraStatusChanged. The shutdown warning is `0xC18D` WillSoonShutdown.

---

## 1. Model entry for 0x04A9:0x32CC

- libgphoto2 lists this USB ID as **"Canon:EOS 200D"** with exactly two device flags:
  `PTP_CAP` (= `DEVICE_FLAG_CAPTURE`) and `PTP_CAP_PREVIEW` (= `DEVICE_FLAG_CAPTURE_PREVIEW`).
  There are no quirk or bug flags. **Ref(`library.c`:`models[]`, `ptp-bugs.h`)**
- The gphoto support list shows the EOS 200D as supporting "Image Capture, Trigger Capture,
  Liveview, Configuration". **Ext(gphoto support.php)**
- On USB the device reports itself as "Canon EOS Rebel SL2". **Verified**
- libgphoto2 sends some bodies down a separate "EOS M" path. It decides by checking whether the
  model string starts with "Canon EOS M" (plus some PowerShot SX/G/IXUS cases). "Canon EOS Rebel SL2"
  does not match, so the SL2 gets the regular-EOS DSLR behaviour throughout: remote mode 1, and
  no forced EVFOutputDevice=8 or SetEventMode 2. **Ref(`ptp-private.h`:`is_canon_eos_m`)**
- The 200D's OLC info version (property `0xD199`) is 0x0F. libgphoto2's table marks that entry
  "CONFIRMED: 200D". **Ref(`ptp-pack.c`:`olcsizes` / `ptp_unpack_EOS_events`)**
- The DeviceInfo VendorExtensionID for Canon is `0x0000000B`. **Ref(`ptp.h`)**

## 2. EOS initialization sequence (libgphoto2)

libgphoto2 sets up a regular EOS DSLR in two places:

1. At connect time (`camera_init`): after OpenSession and GetDeviceInfo, if `0x9114` is supported,
   it sends **SetRemoteMode `0x9114`(1)**. EOS M bodies get 0x15 or 0x11 instead, then a fresh
   GetDeviceInfo. **Ref(`library.c`:`camera_init`)**
2. Before the first capture or preview (`camera_prepare_canon_eos_capture`). `camera_capture_preview`
   calls it lazily, on the first frame, if capture is not yet enabled.
   **Ref(`config.c`:`camera_prepare_canon_eos_capture`, `library.c`:`camera_capture_preview`)**

| # | Operation | Params / data | Notes | Provenance |
|---|---|---|---|---|
| 1 | SetRemoteMode `0x9114` | `1` | Regular EOS. EOS M uses `0x15`, some PowerShots `0x11`. | **Ref(`config.c`:`camera_prepare_canon_eos_capture`)**. SL2 returned `0x2001`: **Verified** |
| 2 | SetEventMode `0x9115` | `1` | Turns on event reporting through GetEvent. | **Ref(same)**. SL2 returned `0x2001`: **Verified** |
| 3 | SetRequestOLCInfoGroup `0x913D` | `0x00001FFF` | Only sent if listed in OperationsSupported. Asks the body to emit OLCInfoChanged `0xC1A5` blobs. | **Ref(same)** |
| 4 | GetEvent `0x9116` drain | none | "Initial bulk set". Called repeatedly until a call parses zero records. | **Ref(same, `ptp.c`:`ptp_check_eos_events`)**. SL2 first call returned 7928 bytes: **Verified** |
| 5 | RequestDevicePropValue `0x9127` | prop code | Sent for Owner `0xD115`, Artist `0xD1D0`, Copyright `0xD1D1` and SerialNumber `0xD1AF`. Errors are logged and ignored, because the body answers GeneralError `0x2002` for props it lacks. The body then pushes the value as a `0xC189` record in a later GetEvent. | **Ref(same)** |
| 6 | GetDeviceInfoEx `0x9108` | none | Only if supported. The data is a u32 header followed by three u32-count-prefixed u32 arrays: events, device props, unknown. libgphoto2 also merges the prop list into DevicePropertiesSupported. | **Ref(same, `ptp-pack.c`:`ptp_unpack_EOS_DI`, `library.c`:`fixup_cached_deviceinfo`)** |
| 7 | GetEvent drain, then wait for `0xD1B0` | none | If EVFOutputDevice has not appeared in the event cache, it retries up to 10 times, 50 ms apart. | **Ref(same)** |
| 8 | Capture-target setup | SetDevicePropValueEx on CaptureDestination `0xD11C`; PCHDDCapacity `0x911A`(`0x0FFFFFFF`,`0x1000`,`1`) when the target is PC RAM (value 4) | Only matters for still capture. Live view does not need it. | **Ref(`config.c`:`camera_canon_eos_update_capture_target`)** |
| 9 | GetDeviceInfo `0x1001`, GetStorageIDs `0x9101`, GetStorageInfo `0x9102` | none | libgphoto2's own comment says the storage calls seem to have no effect. | **Ref(`config.c`:`camera_prepare_canon_eos_capture`)** |
| 10 | GetEvent drain | none | "Second bulk set". Then the KeepDeviceOn timer starts. | **Ref(same)** |

- KeepDeviceOn `0x911D` is not sent during init. It is sent later on a 10-second timer (see §7).
  **Ref(`config.c`:`camera_keep_device_on`)**
- libgphoto2 never writes a dedicated "PC connection" property for regular EOS. SetRemoteMode is
  the PC-connection switch. **Ref(`config.c`:`camera_prepare_canon_eos_capture`)**. In the
  property list, `0xD058` ConnectTrigger exists but goes unused here. **Ref(`ptp.h`)**
- GetRemoteMode is `0x9113`. **Ref(`ptp.h`)**

## 3. Live view start and stop

### 3.1 EVFOutputDevice `0xD1B0` (u32 bitmask)

| Bit | Value | Meaning | Provenance |
|---|---|---|---|
| — | `0` | Off. On the 5D Mk III this means LCD off, mirror down, optical viewfinder. | **Ref(`config.c`:`canon_eos_cameraoutput`)** |
| 0 | `0x1` | TFT (rear LCD) | **Ref(same)**; **Ext(Schroden: "camera")** |
| 1 | `0x2` | PC (host) | **Ref(same)**; **Ext(Schroden: "host")** |
| 2 | `0x4` | MOBILE | **Ref(same)** |
| 3 | `0x8` | MOBILE2 (EOS M bodies need it for tethering) | **Ref(same, `config.c`:`camera_prepare_canon_eos_capture`)** |

- libgphoto2 offers a second view of the same property, a "Live View Size" widget. It reads
  bits 1–3 as frame size: `0x2` Large, `0x4` Medium, `0x8` Small. Writing it replaces bits 1–3 and
  keeps the TFT bit. **Ref(`config.c`:`_get_Canon_LiveViewSize` / `_put_Canon_LiveViewSize`)**.
  Whether `0x4` or `0x8` gives a smaller JPEG on the SL2: **Hyp**.
- With value `2` (PC only) the SL2 produced 960×640 JPEG frames. **Verified**

### 3.2 How libgphoto2 starts preview

The preview path (`camera_capture_preview`, EOS branch) takes this branch when GetViewFinderData
`0x9153` appears in OperationsSupported. It does the following:

1. If capture is not prepared yet, it runs the §2 sequence.
2. EVFMode `0xD1B1` (u16, 0 = off, 1 = on): if the cached value is not 1, it writes 1. A
   DeviceBusy `0x2019` reply is accepted, because the body answers busy in movie mode but works.
3. EVFOutputDevice `0xD1B0`: it writes `2` only when the cached value has no bit set other than
   TFT, i.e. `(value & ~1) == 0`. Writing a value that already includes the PC bit is skipped,
   because every write causes delays.
4. KeepDeviceOn check (rate-limited, §7).
5. Per frame: drain GetEvent, then call GetViewFinderData (§4).

**Ref(`library.c`:`camera_capture_preview`)**

- **libgphoto2 never sends InitiateViewfinder `0x9151` on the preview path.** It sends `0x9151` only
  from the explicit "viewfinder" config toggle, and only when `0x9151` is listed in
  OperationsSupported. If it is not listed, that toggle writes `0xD1B0` = 2 instead (and 0 to turn
  it off). **Ref(`config.c`:`_put_Canon_EOS_ViewFinder`)**
- The SL2 answers `0x9151` and `0x9152` with `0x2005` OperationNotSupported. **Verified**
- Reconciliation: on the SL2, live view is driven only by properties (0xD1B0, plus 0xD1B1 if
  needed). The Initiate/TerminateViewfinder pair belongs to bodies that list it, and libgphoto2
  gates it on OperationsSupported. The SL2's 591-byte DeviceInfo most likely does not list
  `0x9151`/`0x9152`. **Hyp**: confirm by parsing OperationsSupported.
- Setting `0xD1B0`=2 was enough for the SL2 to start serving frames, and a `0xC189` record echoed
  `0xD1B0`=2. **Verified**. The verified sequence did not list an EVFMode `0xD1B1` write, so the
  SL2 apparently does not need one. **Hyp**

### 3.3 How libgphoto2 stops live view and disconnects

`camera_exit` → `camera_unprepare_canon_eos_capture`, for regular (non-M) EOS:

1. Drain GetEvent if events are being tracked.
2. TerminateViewfinder `0x9152`, only if live view is active **and** `0x9152` is listed in
   OperationsSupported. **Ref(`library.c`:`camera_exit`)**
3. AfCancel `0x9160`, if supported, in case AF was running.
4. Reset CaptureDestination `0xD11C` to card. ResetUILock `0x911C` if the UI had been locked.
5. Drain GetEvent.
6. SetRemoteMode `0x9114`(0), then SetRemoteMode(1) (the source comment says this enables the
   camera display), then SetEventMode `0x9115`(0).
7. Back in `camera_exit`: SetRemoteMode(1) once more, again "to switch the display back on".

**Ref(`config.c`:`camera_unprepare_canon_eos_capture`, `library.c`:`camera_exit`)**

- For regular EOS, **libgphoto2 does not reset `0xD1B0` on exit**. Only EOS M bodies get
  `0xD1B0`=0 there. The viewfinder-off toggle writes `0xD1B0`=0. **Ref(same,
  `config.c`:`_put_Canon_EOS_ViewFinder`)**
- On the SL2, SetEventMode(0) and SetRemoteMode(0) return `0x2001`. **Verified**

### 3.4 SetDevicePropValueEx `0x9110` payload

- No operation parameters. The data phase is `[u32 total size][u32 prop code][value]`. For any
  integer of 32 bits or fewer, total size is always 12 and the value sits LE in a zero-padded
  4-byte slot (u8/u16 values included). Strings are NUL-terminated (size = 8 + strlen + 1).
  AINT32 values are raw u32 words. ImageFormat and CustomFuncEx have special packers.
  **Ref(`ptp.c`:`ptp_canon_eos_setdevicepropvalue`)**
- `[12][0xD1B0][2]` returned `0x2001` on the SL2. **Verified**
- libgphoto2 refuses to write a property it has not yet seen in GetEvent, returning a local
  "Undefined" error without sending anything. It updates its cache only after an OK reply.
  **Ref(same)**

## 4. GetViewFinderData `0x9153`

- **Parameters:** 3 × u32, sent as `0x00200000, 0, 0`. libgphoto2's comment says the values came
  from a trace (EOS 1000D), that `0x00100000` has also been used, and that the meanings are
  unknown. **Ref(`ptp.c`:`ptp_canon_eos_get_viewfinder_image`)**. EOS Utility sends the same
  triple over PTP/IP. **Ext(Schroden)**. The `ptp.h` comment also notes that the EOS M2 over WLAN
  uses 2 params, `0x00200000, 0x01000000`. **Ref(`ptp.h`)**. The first parameter is likely a
  maximum transfer or buffer size (0x200000 = 2 MiB). **Hyp**
- **Data phase:** GETDATA, with no response parameters. **Ref(`ptp.c`)**
- With `0x00200000, 0, 0` the SL2 returns `0x2001` and about 217 KB when ready, and `0xA102`
  otherwise. Polled at full speed it delivers about 30 frames/s, with roughly half the calls
  returning `0xA102`. **Verified**. A 6D shows the same "about half the polls are ObjectNotReady"
  pattern. **Ext(FC.SDK)**

### 4.1 Response handling

| Code | Name | libgphoto2 action | Provenance |
|---|---|---|---|
| `0x2001` | OK | Parse the blocks | **Ref(`library.c`:`camera_capture_preview`)** |
| `0xA102` | Canon EOS ObjectNotReady / "Camera Not Ready" | Sleep `try × 5 ms`, retry, give up after 3 s total | **Ref(same)**. Seen on the SL2: **Verified** |
| `0x2019` | DeviceBusy | Same as `0xA102` | **Ref(same)** |
| other | — | Fail the preview | **Ref(same)** |

The 3-second budget covers the mirror-up delay before the first frame. A source comment says the
EOS 100D needs about 1.2 s. **Ref(same)**

### 4.2 Payload layout

The payload is a sequence of blocks `[u32 length including this 8-byte header][u32 type][payload]`.
libgphoto2 walks the blocks and clamps or aborts when a length exceeds the remaining bytes.
**Ref(`library.c`:`camera_capture_preview`)**. The SL2 uses this same format. **Verified**

| Type | Content | Provenance |
|---|---|---|
| `0x00000001` | Live view JPEG | **Ref(same)**. SL2: baseline 960×640 JPEG starting `FF D8`: **Verified** |
| `0x00000009` | Image in movie mode. libgphoto2 tags it as raw data, not JPEG. | **Ref(same)** |
| `0x0000000B` | JPEG (variant) | **Ref(same)** |
| `0x00000011` | Histogram, 4096 bytes: 4 planes (Y, R, G, B) × 256 bins × u32. FC.SDK found it linear in light. | **Ref(same: "planar YRGB histogram")**; **Ext(FC.SDK)**. SL2 block length `0x1008` = 8 + 4096: **Verified** |
| `0xFFFFFFFF` | Frame header, 32–56 bytes | **Ext(FC.SDK)**. SL2: first block, length `0x3C`: **Verified** |
| `0x00000004` | Magnification (1 / 5 / 10) | **Ext(FC.SDK, 6D/R6)** |
| `0x00000005` | Magnifier origin x, y | **Ext(FC.SDK)** |
| `0x00000007` | AF busy (2 while driving AF) | **Ext(FC.SDK)** |
| `0x00000008` | AF frame / touch-AF rect | **Ext(FC.SDK, Schroden)** |
| `0x0000000A` | Unix timestamp + counter | **Ext(FC.SDK)** |
| `0x0000000C` | Unidentified | **Ext(FC.SDK)** |
| `0x0000000D` | Magnifier rect x, y, w, h | **Ext(FC.SDK)** |
| `0x0000000E` | Full sensor size w, h | **Ext(FC.SDK, Schroden)** |
| `0x00000012` | Zoom rect: image origin plus shown size | **Ext(FC.SDK)** |
| `0x0000000F`, `0x10`, `0x13`, `0x14`, `0x15` | Unknown. The SL2 sends them; none of the sources decode them. | **Verified** (presence only) |
| `0x00000000`, length 8 | Terminator | SL2: **Verified**. libgphoto2 just stops at the end of the buffer. |

Decoded on the SL2 (both fixtures; layouts checked against the bytes):

| Type | SL2 layout and values | Provenance |
|---|---|---|
| `0x8` | `[u32 count]` then count × `[u32 state, u32 (always 1), u32 x, u32 y, u32 w, u32 h]`, sensor pixels. Firmware 1.1.0 sends 49 entries in a 7×7 grid, each 649×399, all state 0. The payload is exactly 4 + 24·count bytes. States 0x10 resting, 0x11 focused (FC.SDK), 0x20 face, 0x30 tracking (Schroden); state 0 is undocumented. | Layout **Verified**; state meanings **Ext** |
| `0xA` | `[u32 Unix seconds][u32 counter]`, e.g. 2026-11-16 21:10:30 UTC, counter 770 | **Verified** (local vs UTC: **Hyp**) |
| `0xE` | `[u32 w][u32 h]`: 6000×3988 (fw 1.0.1 capture), 5976×3952 (fw 1.1.0 capture) | **Verified** |
| `0x12` | `[x][y][w][h]` visible area, e.g. `0,298,5976,3356` (16:9 crop of the sensor) | **Verified** |
| `0x11` | 4 planes × 256 bins × u32. Plane totals are equal, and the first plane matches 0.299R + 0.587G + 0.114B of the others, which confirms the Y, R, G, B order | **Verified** |
| `0x4` / `0x5` / `0xD` / `0x7` | magnification 1; origin and rect zero; AF activity 1 = idle (2 = focusing per FC.SDK) | **Verified** values; meanings **Ext** |
| `0xFFFFFFFF` | 52-byte header; some bytes repeat values from blocks 0xF and 0x14; no fields documented | **Verified** (presence only) |
| `0xC`, `0xF`, `0x10`, `0x13`, `0x14`, `0x15` | undocumented; kept raw and reported as undocumented | **Verified** (presence only) |

The SL2 sends its blocks in this order: `FFFFFFFF, 1, F, 10, 14, 4, 5, 12, C, D, E, A, 13, 15, 7,
11, 0` on firmware 1.0.1, and the same plus a type `0x8` block before the terminator on firmware
1.1.0. **Verified** (one capture each; whether `0x8` depends on the firmware or on the AF mode is
**Hyp**). Block meanings above are taken from 6D/R6 numbering. That the SL2 uses the
same meanings: **Hyp**.

**JPEG extraction (libgphoto2):** take the first block of type 1, 9 or 11, copy bytes
`[offset+8, offset+length)`, then keep walking to cache the histogram. libgphoto2 decodes no other
metadata. **Ref(`library.c`:`camera_capture_preview`)**. For Mirrorup: find type 1 (or 11), check
the `FF D8` prefix, and hand the slice to the decoder without copying.

## 5. GetEvent `0x9116`

- No parameters. GETDATA. The data is a list of records `[u32 size][u32 event code][size-8 bytes]`,
  ended by a record of size 8 with code 0. **Ref(`ptp-pack.c`:`ptp_unpack_EOS_events`)**. On the
  SL2, the idle response after a change is 24 bytes: one record (`0x10`, `0xC189`, `0xD1B0`, `2`)
  followed by the terminator (`8`, `0`). **Verified**
- Parsing rules (**Ref(same)**): stop on size < 8, on size > remaining bytes, or on the
  `(8, 0)` terminator. libgphoto2 also stops when a record would reach exactly the end of the
  buffer, so it expects a terminator to be present.
- A drain (`ptp_check_eos_events`) repeats GetEvent until a reply contains zero records. It is
  done at every init step and before every preview frame. **Ref(`ptp.c`:`ptp_check_eos_events`,
  `library.c`:`camera_capture_preview`)**

### 5.1 Record types

Offsets are from the start of the record.

| Code | Name | Payload | Provenance |
|---|---|---|---|
| `0xC189` | PropValueChanged | `+8` u32 prop code, `+12` value, `size-12` bytes. The value's width comes from a per-property type table, not from the record size. u32 props in that table include `0xD1B0`, `0xD116`, `0xD11B`, `0xD11C`, `0xD1A8`. u16 props include `0xD101`, `0xD102`, `0xD103`, `0xD111`, `0xD1B1`, `0xD1B8`. u8 props include `0xD104`, `0xD107`, `0xD109`, `0xD110`. `0xD114` is i32. Strings are plain ASCII, NUL-terminated. | **Ref(`ptp-pack.c`:`ptp_unpack_EOS_events`)**. SL2: 16-byte records for `0xD116` and `0xD1B0` (4-byte values): **Verified** |
| `0xC18A` | AvailListChanged (allowed values) | `+8` prop, `+12` u32 form type, `+16` u32 count, `+20` count × 4-byte slots (even u16/u8 values take 4 bytes each). libgphoto2 decodes only form type 3 (enumeration). | **Ref(same)** |
| `0xC181` | ObjectAddedEx | `+8` handle, `+0xC` storage ID, `+0x10` object format, `+0x1C` size, `+0x20` parent, `+0x28` filename | **Ref(same)** |
| `0xC1A7` | ObjectAddedEx64 | Like `0xC181`, with parent at `+0x24` and name at `+0x2C` | **Ref(same)** |
| `0xC186` / `0xC1A9` | RequestObjectTransfer(64) | `+8` handle, `+0xC` format, `+0x14` size, `+0x1C` name | **Ref(same)** |
| `0xC182` | ObjectRemoved | `+8` handle | **Ref(same)** |
| `0xC18B` | CameraStatusChanged | `+8` u32. 1 = busy (libgphoto2 refuses to capture), 0 = idle / capture complete. | **Ref(same, `library.c`:`camera_trigger_canon_eos_capture`, `camera_wait_for_event`)** |
| `0xC1A5` | OLCInfoChanged | Blob: `+8` length, `+12` u16 mask, then entries whose sizes depend on the OLC version (`0xD199`; 0x0F on the 200D) | **Ref(same)** |
| `0xC18D` | WillSoonShutdown | Logged only, not handled | **Ref(same)** |
| `0xC18E` | ShutdownTimerUpdated | Logged only | **Ref(same)** |
| `0xC183` | RequestGetObjectInfoEx | Logged only | **Ref(same)** |
| `0xC101` | RequestGetEvent | Logged only | **Ref(same)** |
| `0xC184` / `0xC185` / `0xC192` / `0xC193` | StorageStatusChanged / StorageInfoChanged / StoreAdded / StoreRemoved | `+8` u32 | **Ref(same)** |
| `0xC1A3` | AfResult | Logged only | **Ref(same)** |

Events that need action in Mirrorup (**Hyp**, derived from the meanings above):

- `0xC189` for `0xD1B0` with bit 1 cleared: the body has left PC live view (mode dial, menu,
  playback). Rewrite `0xD1B0`.
- `0xC18D` or `0xC18E`: auto power-off is imminent. Send KeepDeviceOn now.
- `0xC18B` = 1: the body is busy. Expect `0xA102`/`0x2019` replies and back off.
- `0xC181`/`0xC1A7`/`0xC186`/`0xC1A9`: a file was created. Ignored, except while
  `capturePhoto()` waits for its own shot (§11.6); `CanonEventParser` keeps handle, storage, format,
  size and name.

## 6. Response codes

| Code | Name | Provenance |
|---|---|---|
| `0x2001` | OK | **Ref(`ptp.h`)**; **Verified** |
| `0x2002` | GeneralError (e.g. RequestDevicePropValue on an absent prop) | **Ref(`ptp.h`, `config.c`:`camera_prepare_canon_eos_capture`)** |
| `0x2003` | SessionNotOpen | **Ref(`ptp.h`)** |
| `0x2005` | OperationNotSupported | **Ref(`ptp.h`)**; SL2 `0x9151`/`0x9152`: **Verified** |
| `0x2019` | DeviceBusy | **Ref(`ptp.h`)** |
| `0x201C` | InvalidDevicePropValue | **Ref(`ptp.h`)** |
| `0xA001` | Canon UnknownCommand | **Ref(`ptp.h`, `ptp.c`:`ptp_strerror` table)** |
| `0xA005` | Canon OperationRefused | **Ref(same)** |
| `0xA006` | Canon LensCoverClosed / "Lens Cover Present" | **Ref(same)** |
| `0xA009` | Canon (unnamed in libgphoto2) | **Ref(`ptp.h`)** |
| `0xA101` | Canon LowBattery | **Ref(same)** |
| `0xA102` | Canon EOS ObjectNotReady / "Camera Not Ready" (no live view frame yet) | **Ref(same)**; **Verified** |
| `0xA104` | Canon EOS CannotMakeObject | **Ref(same)** |
| `0xA106` | Canon EOS MemoryStatusNotReady | **Ref(same)** |
| `0xA1E8` | Seen once and flagged in a `ptp.h` comment as maybe an error code. Meaning unknown. | **Ref(`ptp.h`)** |

## 7. Keep-alive, sleep and disconnection

- **KeepDeviceOn `0x911D`** takes no parameters and no data. libgphoto2 sends it at most every
  10 s, only if it is listed in OperationsSupported, from the preview loop (once per frame
  request), from capture waits and from config reads. **Ref(`config.c`:`camera_keep_device_on`,
  `library.c`:`camera_capture_preview`)**. A source comment says an EOS R8 with a 15 s
  auto-power-off still did not sleep for minutes while connected over USB.
- **AutoPowerOff `0xD114`** (i32) is exposed read/write as "autopoweroff". Units are presumably
  seconds, with 0 = never. **Ref(`config.c` menu table, `ptp-pack.c`)**; units: **Hyp**.
  Mirrorup should not change the user's setting. KeepDeviceOn is enough.
- The older PowerShot opcode KeepDeviceOn `0x9003` is a different code from the EOS `0x911D`, and
  libgphoto2's only call to it is compiled out (`#if 0`). Only `0x911D` applies to the SL2.
  **Ref(`ptp.h`, `library.c`)**
- Continuous `0x9153` polling probably keeps the SL2 awake on its own. **Hyp**. Send `0x911D`
  anyway, as libgphoto2 does.
- **Disconnection / power-off:** libgphoto2 has no Canon-specific detection. A switched-off or
  unplugged body shows up as transport I/O errors. **Ref(`library.c`, generic transport path)**.
  On the ImageCaptureCore path it should show up as the device being removed or its session
  closing, plus `requestSendPTPCommand` completing with an error. **Hyp**. The `0xC18D`/`0xC18E`
  events may arrive first. **Hyp**
- On the SL2, `0xA101` LowBattery or `0xC18B` may show up near battery exhaustion. **Hyp**

### 7.1 Identity properties seen on the SL2

| Code | Content | Provenance |
|---|---|---|
| `0xD1D8` | Lens name, ASCII (`EF-S18-55mm f/4-5.6 IS STM`) | **Verified** |
| `0xD125` | Body ID string (`EOSSL2`) | **Verified** (meaning beyond the value: **Hyp**) |
| `0xD1A8` | LensStatus, 1 with a lens attached | **Verified** |

Firmware versions tested: 1.0.1 and 1.1.0 (DeviceInfo `DeviceVersion` `3-1.0.1` / `3-1.1.0`); both
expose the same 170 operations. **Verified**

## 8. Exposure and focus controls (reference)

What Mirrorup's controls actually send, and what the SL2 answered, is in §11.

All writes go through `0x9110` (§3.4). Allowed values arrive as `0xC18A` lists. Use those lists
rather than hard-coded tables.

| Code | Name | Type | Notes | Provenance |
|---|---|---|---|---|
| `0xD101` | Aperture (Av) | u16 | Canon code table | **Ref(`ptp.h`, `config.c`:`canon_aperture`)** |
| `0xD102` | ShutterSpeed (Tv) | u16 | `0x0C`/`0x04` = bulb | **Ref(`ptp.h`, `config.c`:`canon_shutterspeed`)** |
| `0xD103` | ISOSpeed | u16 | `0x00` Auto, `0x48`=100, `0x50`=200, `0x58`=400, `0x60`=800, `0x68`=1600 | **Ref(`config.c`:`canon_isospeed`)** |
| `0xD104` | ExpCompensation | u8 | Enumerated | **Ref(`ptp.h`, `ptp-pack.c`)** |
| `0xD105` | AutoExposureMode | u16 | 0 P, 1 Tv, 2 Av, … (no enum list is sent) | **Ref(`config.c`:`canon_eos_autoexposuremode`)** |
| `0xD138` | AEModeDial | u16 | Mode dial position | **Ref(`ptp.h`, `ptp-pack.c`)** |
| `0xD106` | DriveMode | u16 | — | **Ref(`ptp.h`)** |
| `0xD107` | MeteringMode | u8 | — | **Ref(`ptp.h`)** |
| `0xD108` | FocusMode | u32 | Follows the lens AF/MF switch | **Ref(`ptp.h`)**; **Ext(FC.SDK)** |
| `0xD109` | WhiteBalance | u8 | 0 Auto, 1 Daylight, 2 Cloudy, 3 Tungsten, 4 Fluorescent, 5 Flash, 6 Manual, 8 Shadow, 9 Color temperature | **Ref(`config.c`:`canon_eos_whitebalance`)** |
| `0xD10A` | ColorTemperature | u32 | Kelvin | **Ref(`config.c` menu table)** |
| `0xD110` | PictureStyle | u8 | — | **Ref(`ptp-pack.c`)** |
| `0xD111` | BatteryPower | u16 | Read-only | **Ref(`ptp-pack.c`)** |
| `0xD1A8` | LensStatus | u32 | 0 = no lens | **Ref(`ptp.h`)**; **Ext(FC.SDK)** |
| `0xD1BA` | LvAfSystem | u32 | Face-tracking mode can block zoom | **Ref(`ptp.h`)**; **Ext(FC.SDK)** |
| `0xD1B4` | EVFWBMode | u32 | Live view WB | **Ref(`ptp.h`)** |
| `0xD1B6` | EVFColorTemp | u32 | — | **Ref(`ptp.h`)** |
| `0xD1B7` | ExposureSimMode | u32 | Exposure simulation in live view | **Ref(`ptp.h`)** |

| Opcode | Name | Params | Provenance |
|---|---|---|---|
| `0x9154` | DoAf | none. Returns on acceptance, not on focus. | **Ref(`ptp.h`, `config.c`:`_put_Canon_EOS_AFDrive`)**; **Ext(FC.SDK)** |
| `0x9160` | AfCancel | none | **Ref(same)** |
| `0x9155` | DriveLens | 1: step 1/2/3 = near (small/medium/large), `0x8000` + 1/2/3 = far | **Ref(`config.c`:`_put_Canon_EOS_MFDrive`)** |
| `0x9158` | Zoom | 1: factor (1 / 5 / 10) | **Ref(`ptp.h`)**; **Ext(FC.SDK)** |
| `0x9159` | ZoomPosition | 2: x, y (sensor pixels) | **Ref(`ptp.h`)**; **Ext(FC.SDK)** |
| `0x915B` | TouchAfPosition | 3: type, x, y | **Ref(`ptp.h`)** |
| `0x9128` / `0x9129` | RemoteReleaseOn / Off | 1 = half press, 2 = full press (plus a second param 0 on On) | **Ref(`ptp.h`)** |

libgphoto2 drains GetEvent after DoAf and DriveLens. **Ref(`config.c`)**

## 9. Recommended sequence for Mirrorup on the SL2

The steps use the ImageCaptureCore pass-through; the ptpcamerad session is already open.

### 9.1 Init

1. **GetDeviceInfo `0x1001`** (**Verified**: 591 bytes). Parse OperationsSupported,
   EventsSupported and DevicePropertiesSupported. Record whether `0x9151`, `0x9152`, `0x911D`,
   `0x913D`, `0x9127`, `0x9108`, `0x9154`, `0x9155` and `0x9158` are listed. Check that
   VendorExtensionID is `0x0B` and that the model starts "Canon EOS".
2. **SetRemoteMode `0x9114`(1)**. Fatal unless the reply is `0x2001`. (**Verified**)
3. **SetEventMode `0x9115`(1)**. Fatal unless the reply is `0x2001`. (**Verified**)
4. **Drain GetEvent `0x9116`**: loop until a reply has no records (≤ 8 bytes, or only the
   terminator), at most about 50 iterations. Build a property cache keyed by prop code from
   `0xC189` (value) and `0xC18A` (allowed values). (**Verified**: the first reply is 7928 bytes.)
5. If `0xD1B0` is not in the cache, repeat the drain up to 10 times, 50 ms apart. If it is still
   missing, report "camera not ready for remote control". (**Ref**: §2 step 7)
6. Skip 0x913D, 0x9127, 0x9108 and the storage calls. Live video does not need them. (**Ref**: §2
   shows libgphoto2 uses them only for metadata, OLC and capture.)

### 9.2 Live view start

1. Save `savedOutput = cache[0xD1B0]`. If `(savedOutput & ~0x1) == 0`, send **`0x9110`
   `[12][0xD1B0][2]`** (PC only, rear LCD off). Fatal unless `0x2001`. (**Verified** value 2;
   libgphoto2 uses the same rule: **Ref**)
2. If `cache[0xD1B1]` exists and is not 1, send `0x9110` `[12][0xD1B1][1]` and treat `0x2019` as
   success. Remember to restore it. (**Ref**; the SL2 likely does not need it: **Hyp**)
3. Do **not** send InitiateViewfinder `0x9151` unless step 9.1.1 found it in OperationsSupported.
   If it is sent and answers `0x2005`, log it and continue. The SL2 starts live view from the
   property write alone. (**Verified** `0x2005`, and frames arrive without it.)
4. Drain GetEvent and expect `0xC189`/`0xD1B0` = 2. (**Verified**)
5. First frame: poll `0x9153` as in §9.3, with a 3 s budget for the mirror flip. On timeout, stop
   and report. (**Ref**: 3 s budget)

### 9.3 Steady-state poll (one serial loop; PTP is half-duplex)

```
loop:
  rc, data = 0x9153(0x00200000, 0, 0)
  if rc == 0x2001:
      walk blocks; jpeg = first block with type 1 (or 11) and an FF D8 prefix; emit frame
      notReadyStreak = 0
  elif rc in (0xA102, 0x2019):
      notReadyStreak += 1; sleep min(notReadyStreak * 2 ms, 20 ms)
      if notReadyStreak exceeds about 3 s worth of tries: treat live view as lost and re-arm (9.2)
  else: fail (see errors)
  every ~250 ms: drain GetEvent; apply 0xC189 to cache; act per section 5.1
      (0xD1B0 lost bit 1 -> rewrite 2; 0xC18D/0xC18E -> 0x911D now)
  every 10 s, if 0x911D is listed: KeepDeviceOn 0x911D (ignore 0x2005)
```

- Expect about 30 fps, with about half the polls `0xA102`. (**Verified**). libgphoto2's fixed
  `try × 5 ms` backoff is tuned for single grabs; for streaming, reset the backoff after each
  frame. (**Hyp**)
- Draining GetEvent before every frame, as libgphoto2 does, is not needed at 30 fps. A slower
  cadence is enough. (**Hyp**)
- Errors: `0xA101` → warn about the battery; `0x2003`, a transport error or device removal →
  stop and report the camera as disconnected. Any other code → stop live view, try one re-arm
  (9.2), then give up. (**Hyp**)

### 9.4 Stop

1. Write `0xD1B0` back to `savedOutput` (usually 0 or 1). If that write fails, write 0, which is
   what libgphoto2's viewfinder-off toggle does. (**Ref**: `_put_Canon_EOS_ViewFinder`; restoring
   the saved value instead: **Hyp**)
2. If `0xD1B1` was changed, restore it.
3. Send TerminateViewfinder `0x9152` only if it is listed. The SL2 answers `0x2005`, which is
   harmless. (**Verified**)
4. Drain GetEvent once.
5. **SetEventMode `0x9115`(0)**, then **SetRemoteMode `0x9114`(0)**. (**Verified**: both
   `0x2001`.) libgphoto2 then sends SetRemoteMode(1) to bring the rear display back (**Ref**). If
   the SL2's LCD stays dark after mode 0, add SetRemoteMode(1) as the final step. (**Hyp**)

## 10. Opcode summary (live view subset)

| Opcode | Name | Provenance |
|---|---|---|
| `0x1001` | GetDeviceInfo | **Verified** |
| `0x9101` / `0x9102` | GetStorageIDs / GetStorageInfo | **Ref(`ptp.h`)** |
| `0x9108` | GetDeviceInfoEx | **Ref(`ptp.h`)** |
| `0x9110` | SetDevicePropValueEx | **Verified** |
| `0x9113` | GetRemoteMode | **Ref(`ptp.h`)** |
| `0x9114` | SetRemoteMode | **Verified** |
| `0x9115` | SetEventMode | **Verified** |
| `0x9116` | GetEvent | **Verified** |
| `0x911A` | PCHDDCapacity | **Ref(`ptp.h`)** |
| `0x911B` / `0x911C` | SetUILock / ResetUILock | **Ref(`ptp.h`)** |
| `0x911D` | KeepDeviceOn | **Ref(`ptp.h`)** |
| `0x9127` | RequestDevicePropValue | **Ref(`ptp.h`)** |
| `0x913D` | SetRequestOLCInfoGroup | **Ref(`ptp.h`)** |
| `0x9151` | InitiateViewfinder | **Verified** (`0x2005` on the SL2) |
| `0x9152` | TerminateViewfinder | **Verified** (`0x2005` on the SL2) |
| `0x9153` | GetViewFinderData | **Verified** |

## 11. User camera controls (`CanonCamera: CameraControlling`)

Implementation: `Sources/MirrorupCanon/CanonControls.swift`. Every command goes through the same
`PTPSession` gate as frame polling, and nothing is polled for the controls: the state is computed
only when `controlState()` is called. Hardware session 2026-11-16 on the SL2, firmware 1.1.0,
EF-S 18-55mm f/4-5.6 IS STM, a memory card (StorageID `0x00020001`), over the ImageCaptureCore
pass-through. The mode dial was first on Scene Intelligent Auto (`0xD138` = `0x16`) and then on
P (`0x00`). Every setting that was changed was put back. Each session ended with `0xD1B0` restored,
zoom at 1×, SetEventMode(0) and SetRemoteMode(0).

### 11.1 Control state

`controlState()` drains GetEvent once, then builds everything from the property cache and the
latest parsed live-view frame.

| Control | Source | Notes | Provenance |
|---|---|---|---|
| Aperture / shutter / ISO / exposure compensation / white balance / picture style / AF method | `0xD101` / `0xD102` / `0xD103` / `0xD104` / `0xD109` / `0xD110` / `0xD1BA`: value from `0xC189`, options from `0xC18A` in the camera's order | Titles come from `CanonCatalog.optionTitle` (the same tables as the metadata). Undocumented values are not offered as options. | Lists **Verified** |
| Color temperature | `0xD10A` | Offered only when white balance is Color Temperature (`9`). The SL2 sends a 76-value list, 2500–10000 K in 100 K steps, in both modes even when white balance is Auto. Its P-mode white-balance list (`0, 0x17, 1, 8, 2, 3, 4, 5, 6`) has no `9`, so color temperature is never adjustable on the SL2. | **Verified** |
| Battery | `0xD111` | `2` = "100%" on the SL2. "Low" is `0`, the lowest level libgphoto2 names; `batteryIsLow` is true for it. | Value **Verified**; low code **Ref(`config.c`:`_get_Canon_EOS_BatteryLevel`)** |
| Shots remaining | `0xD11B` | 5221 with the card in. The test fixture was captured with 0. | **Verified** |
| canAutofocus | live view, `0x9154` listed, `0xD1A8` ≠ 0 (lens), `0xD108` ≠ 3 (lens switch not at MF) | | Ops listed: **Verified**; MF rule **Ext(FC.SDK)** |
| canFocusAtPoint | canAutofocus, `0x9159` listed, AF method = 1-point (`1`), frame geometry known | | **Verified** (§11.4) |
| zoom | magnification from block `0x4`, nil when not in live view, `0x9158` not listed, or AF method = Face + Tracking | | **Verified** (§11.5) |
| canCapturePhoto / photoUnavailableReason | `0x9128`/`0x9129` listed, `0xD1C2` ≠ 1 (not movie mode) and `0xD11B` > 0; otherwise a reason sentence | Capture works in stills mode (§11.6, §11.7) | **Verified** |

Allowed lists by mode (**Verified**):

| Property | Scene Intelligent Auto | P |
|---|---|---|
| `0xD101` Av, `0xD102` Tv, `0xD103` ISO | empty | empty |
| `0xD104` exposure compensation | empty | 19 values, −3…+3 EV in 1/3 steps |
| `0xD109` white balance | empty | `0, 0x17, 1, 8, 2, 3, 4, 5, 6` |
| `0xD110` picture style | empty | `0x87, 0x81, 0x82, 0x83, 0x88, 0x84, 0x85, 0x86, 0x21, 0x22, 0x23` |
| `0xD1BA` AF method | `2, 4, 1` | `2, 4, 1` |

- `0xD101`/`0xD102` read 0 (Auto) and change to the metered value during AF/AE (`0x28` f/4,
  `0x60` 1/30 s), then go back to 0. **Verified**
- `0xD1BA` titles come from EDSDK Evf_AFMode: 2 Face + Tracking, 4 Zone AF, 1 1-point AF. The SL2's
  own menu calls them "Face+Tracking", "Smooth zone AF" and "Live 1-point AF". Matching 4 to "Smooth
  zone AF" is **Hyp**: the EDSDK name differs.

### 11.2 Changing a setting

`set(_:to:)` refuses values that are not in the current options without sending anything. Then it
sends SetDevicePropValueEx `0x9110` `[12][prop][value]`, a 4-byte slot for every width (§3.4), and
drains GetEvent until the property comes back with the new value (at most 1 s).

| Write | Mode | Response | Echo | Provenance |
|---|---|---|---|---|
| `0xD110` = `0x81`, `0xD109` = `1` | Scene Intelligent Auto | `0x2019` DeviceBusy, value unchanged | none | **Verified** |
| `0xD1BA` 2 → 1 → 2 | both | `0x2001` in 15–30 ms | `0xD1BA` in the next GetEvent (~8 ms), together with `0xD1C9`, `0xD13C`, `0xD108` | **Verified** |
| `0xD110` `0x82` → `0x81` → `0x82` | P | `0x2001` | `0xD110` | **Verified** |
| `0xD109` `0x17` → `1` → `0x17` | P | `0x2001` | `0xD109`, plus `0xD1B4` (EVF white balance) following it | **Verified** |
| `0xD104` 0 → `0x08` (+1 EV) → 0 | P | `0x2001` | `0xD104`, `0xD1C3` | **Verified** |
| `0xD1BA` while AF is held (DoAf without AfCancel) | P | `0x2019` | none | **Verified** |

With the full implementation, each `set` round trip took 47–84 ms. **Verified**. `0x2019` is
reported as "The camera is busy or doesn't allow this change in its current mode.", and `0xA005` as
a refusal with the "shooting mode, no menu" hint. Raw codes go into `detail`.

### 11.3 Autofocus

`autofocus()` sends DoAf `0x9154` (no parameters), waits for the AF result in the live-view frames,
then sends AfCancel `0x9160` and drains GetEvent.

- DoAf returns `0x2001` in about 8 ms, on acceptance. Metering events follow within ~100 ms.
  **Verified**
- **The body holds AF until AfCancel.** While held, SetDevicePropValueEx, Zoom and the
  RemoteReleaseOn full press all answer `0x2019`. AfCancel answers `0x2001`. **Verified**. This is
  why `autofocus()` always ends with AfCancel.
- Result in 1-point AF: block `0x8` holds one frame. Its state goes `0x10` (rest) → `0x11` (in
  focus) 0.3–0.6 s after DoAf, or → `0x12`, which no source names; it showed up when focusing on a
  plain wall. The wait ends on either. Block `0x7` (AF activity) stayed `1` throughout, so the SL2
  does not report AF through it. **Verified**
- Face + Tracking: block `0x8` is a 7×7 grid of 49 entries (each 649×399), all state 0. After AF,
  some entries change to `0x1` (three after one AF) and the rest to `0x10`. The wait ends when an
  entry leaves 0/`0x10`, or after 2 s. States: **Verified**. That `0x1` marks the points that
  focused: **Hyp**.
- Timings with the full implementation: 0.28–0.61 s in 1-point AF and 0.61–2.07 s in Face + Tracking.
  That AF really moved the focus was checked from saved frames in §11.4. **Verified**
- Whether an AfCancel sent 9 ms after DoAf cuts the drive short could not be told from the frames:
  not determined.

### 11.4 Focus at a point

The SL2 moves its live-view AF point with **ZoomPosition `0x9159`(x, y)** in 1-point AF. The
parameters are the top-left corner of the magnifier, in sensor pixels. In 1-point AF the AF frame
follows the magnifier, which matches FC.SDK's 6D finding. `focus(at:)` moves it, waits until a frame
shows the magnifier moved, then runs §11.3.

| Step | Observed on the SL2 | Provenance |
|---|---|---|
| Before | block `0xD` magnifier 1200×800 at (2388,1576); block `0x8` AF frame 1200×1200 at (2388,1376) | **Verified** |
| ZoomPosition(1000,1000) at 1× | `0x2001`; magnifier → (980,1000); AF frame → (980,800); the zoom rect `0x12` stays 0,298 5976×3356 | **Verified** |
| ZoomPosition(0,0) / (4776,3152) at 5× | lands at (332,186) / (4444,2966). The body clamps to an inset box, as on the 6D | **Verified** |
| `focus(at: 0.15,0.2)` → sends (296,569) | lands at (588,576), AF frame state `0x11`, background wall in focus | **Verified** (frames saved and compared) |
| `focus(at: 0.6,0.45)` → sends (2986,1408) | lands at (2964,1384), subject in focus | **Verified** |
| TouchAfPosition `0x915B`(type 0/1/2, 1500, 1500) | `0x2001` each time, but blocks `0x5`/`0x8`/`0xD` did not change. Sent while AF was held, so a second try with AF released would settle it | **Verified** (no visible effect); not used |
| ZoomPosition sent ~4 ms after AfCancel | ignored once (the magnifier did not move) | **Verified**. `focus(at:)` sends it once more if no frame shows the move within 1 s |

#### Mapping (pure functions in `CanonControls.swift`, tested against the fw 1.1.0 fixture)

1. The live-view JPEG shows exactly the area in block `0x12`: 1024×576 ↔ 5976×3356 at (0,298) at 1×,
   1200×800 ↔ the 1200×800 crop at 5× (**Verified**). At 10× the camera still sends the 5× image
   (JPEG 1200×800, same field as 5×) while `0x12` reports a 600×400 area. The visible area is
   therefore taken as `0x12` scaled by magnification/5 (**Verified**, frames compared; EDSDK
   documents the same for Evf_Zoom).
2. sensor point = area origin + normalized point × area size.
3. magnifier size = block `0xD` when it is non-zero (1200×800 in 1-point AF), otherwise sensor/5
   (EDSDK Evf_ZoomPosition note). In Face + Tracking block `0xD` is all zero. **Verified**
4. origin = sensor point − size/2, clamped to `[0, sensor − size]`. The body discards positions
   beyond that range instead of clamping them (**Ext(FC.SDK)**), so they are never sent. The body
   applies its own inset and step on top (**Verified**).

Only 1-point AF supports focusing at a point. In Face + Tracking and Zone AF `canFocusAtPoint` is
false, and `focus(at:)` reports that it needs the 1-point AF focus mode.

### 11.5 Zoom

`setZoom(_:center:)`: if a center is given and the zoom is not 1×, ZoomPosition centres the magnifier
there (as in §11.4). Then Zoom `0x9158`(1/5/10), then a wait for block `0x4` to report the new
magnification.

| Command | Observed | Provenance |
|---|---|---|
| Zoom(5) in Face + Tracking | `0x2019`, nothing changes (the camera's own UI disables magnify in that mode too) | **Verified**. `setZoom` refuses up front |
| Zoom(5) in 1-point AF | `0x2001`. About 0.5 s later the frames are **1200×800** (from 1024×576); block 4 = 5; `0x12` = `0xD` = 1200×800 at the magnifier (2388,1576 when centred) | **Verified** |
| Zoom(10) | `0x2001`; JPEG **still 1200×800**, showing the same field as 5×; block 4 = 10; `0x12` = 600×400 at the 5× origin; `0xD` = 600×400 centred inside it | **Verified** |
| ZoomPosition at 5× | pans the crop (table in §11.4) | **Verified** |
| Zoom(1) | `0x2001`; frames back to 1024×576; the magnifier keeps its last position | **Verified** |

Timings with the full implementation, frame confirmation included: 0.42–1.44 s per `setZoom`.
**Verified**

### 11.6 Photo capture

Implemented sequence, after libgphoto2's regular-EOS path (**Ref(`library.c`:`camera_trigger_canon_eos_capture`, `camera_canon_eos_capture`)**):

1. Refuse up front, without pressing anything, when the body is in movie mode (`0xD1C2` = 1, §11.7)
   or reports 0 shots left (`0xD11B`). Then GetStorageIDs `0x9101`; an empty list gives "Insert a
   memory card to take photos." Capture destination `0xD11C` is left as the user set it (2 = card).
2. Drain GetEvent, start collecting ObjectAdded/RequestObjectTransfer records, and suspend frame
   polling and the frame timeout (`shutterCycleActive`).
3. RemoteReleaseOn `0x9128`(1, 0) half press, then GetEvent for 600 ms while AF/AE settle.
4. RemoteReleaseOn(2, 0) full press. A non-zero first response parameter means the release failed
   (decoded below). Then RemoteReleaseOff `0x9129`(2) and RemoteReleaseOff(1), also after a
   failure, so the body is never left half-pressed.
5. Wait up to 15 s for `0xC181`/`0xC1A7` (card) or `0xC186`/`0xC1A9` (RAM). Then GetObject
   `0x1009`(handle) with a 60 s timeout. TransferComplete `0x9117` is sent only for RAM objects
   (storage 0), as libgphoto2 does. The file name comes from the record, or from GetObjectInfo when
   the record has none.

#### Release result codes

The first response parameter of RemoteReleaseOn and of EOS Capture `0x910F` is the low byte of
Canon EDSDK's TakePicture errors (`EDS_ERR_TAKE_PICTURE_*` = `0x00008D00` + n). libgphoto2's EOS
capture results 1, 3, 7 and 8 have the same meanings. **Ref(`library.c`:`camera_trigger_canon_eos_capture`)**;
values 1–8 **Ext(Canon.Eos.Framework `EDSDK.cs`)**; values 9–0xF follow the order of the EDSDK reference's TakePicture
error list (**Ext(EDSDK API reference 3.2.13)**, numeric values not seen in a header: **Hyp**).

| Result | EDSDK name | `capturePhoto()` message |
|---|---|---|
| 1 | AF_NG | The camera could not focus, so it did not take the photo. |
| 2 | RESERVED | (unexplained; code in `detail`) |
| 3 | MIRROR_UP_NG | The camera's mirror is locked up… |
| 4 | SENSOR_CLEANING_NG | The camera is cleaning its sensor… |
| 5 | SILENCE_NG | The camera is busy with another operation… |
| 6 | NO_CARD_NG | Insert a memory card to take photos. |
| 7 | CARD_NG | The camera could not write to its memory card… |
| 8 | CARD_PROTECT_NG | The memory card is locked… |
| 9 | MOVIE_CROP_NG | The camera can't take photos while movie crop is on. |
| 0xA | STROBO_CHARGE_NG | The flash is still charging… |
| 0xB | NO_LENS_NG | Attach a lens to take photos. |
| 0xC | SPECIAL_MOVIE_MODE_NG | Power-switch advice only while `0xD1C2` = 1; otherwise unexplained (see below) |
| 0xD | LV_REL_PROHIBIT_MODE_NG | The camera can't take photos from live view in this shooting mode. |
| 0xE | MOVIE_MODE_NG | as 0xC |
| 0xF | RETRACTED_LENS_NG | The lens is retracted… |

The result wins over the response code: with live view off the SL2 answered the half press with
`0x2019` **and** result 1 after 5.0 s (AF through the viewfinder failed in a dim room). **Verified**

#### What the SL2 did (2026-11-16 and 2026-11-17)

**Working (2026-11-17, power switch ON after a physical ON → movie → ON cycle, dial on P, PC live
view, 1-point AF, 1×), `capturePhoto()` end to end:** half press, full press (result 0), release,
ObjectAdded, GetObject `0x1009` through the ImageCaptureCore pass-through → `IMG_0003.JPG`,
6 580 522 bytes, `FF D8 … FF D9`, EXIF Canon EOS Rebel SL2, 6000×4000, in 1.89 s. `0xD11B` went
5156 → 5155. Live view resumed with no frame timeout. The file name came out of the object
handling (`CanonEventParser` record or the GetObjectInfo fallback; which one was not logged; the
`new object …` info log now records it). **Verified**

In the same session a capture at 5× on a low-contrast target answered the half press with result 1;
`capturePhoto()` reported "The camera could not focus, so it did not take the photo." **Verified**

**Before the switch cycle no release ever produced a file.** Every attempt with live view on
answered result `0xC`:

| Power switch / `0xD1C2` | Live view | Variant | Result | Provenance |
|---|---|---|---|---|
| movie position / 1 | PC (`0xD1B0` = 2→3) | RemoteReleaseOn (1,0) then (2,0); (3,0); (3,1); EOS Capture `0x910F`; after SetUILock `0x911B`; after SetRequestOLCInfoGroup `0x913D`(`0x1FFF`); with `0xD1B1` write (refused `0x2019`); with `0xD11C` = 4 + PCHDDCapacity `0x911A`(`0x0FFFFFFF`, `0x1000`, 1); after SetRemoteMode `0x15` | `0xC` | **Verified** |
| movie position / 1 | rear LCD only (`0xD1B0` = 1) | (1,0), (2,0) | `0xC` | **Verified** |
| movie position → MovieSelectSWOff `0x9134` / 0 | PC, rear LCD | (1,0), (2,0); `0x910F` | `0xC` | **Verified** |
| moved to ON after `0x9133`/`0x9134` were sent, then `0x9134` / 0 | PC (`0xD1B0` = 2), rear LCD (`0xD1B0` = 1) | (1,0), (2,0); `0x910F`; `0xD11C` = 4 + PCHDDCapacity | `0xC` | **Verified** |
| any / any | off (`0xD1B0` = 0) | (1,0) or (1,1)/(2,1) | `0x2019` after 5 s, result 1 (focus failed) | **Verified** |
| ON / 0 | off, SetRemoteMode(0) | (1,0) | `0x2019` after 5 s, result 1 | **Verified** |
| ON after ON → movie → ON cycle / 0 | PC | (1,0), (2,0) | result 0, photo saved and downloaded | **Verified** |

- In the stuck state the body's own shutter button took no photo either: not while the host held
  remote mode, and not with no host attached (viewfinder). After the user cycled the power switch
  ON → movie → ON with no host attached, viewfinder shots worked, and so did `capturePhoto()` once
  reconnected. **Verified** (user report + capture above)
- **MovieSelectSWOn `0x9133` / MovieSelectSWOff `0x9134` can leave the SL2 refusing every release
  (result `0xC`, `0xD1C2` already reading 0) until the power switch is cycled.** Our probes sent both
  on 2026-11-16/17. Mirrorup never sends them; nobody should. **Verified**
- Throughout: card present (StorageID `0x00020001`, `0xD11C` = 2, allowed `2, 6, 4`), battery 100%,
  lens attached, mirror lockup off, drive mode `0xD106` = 0 (single), AF mode `0xD108` = 0
  (One-Shot) in P.
- OLCInfoChanged (`0xC1A5`) after every failed full press carried Button = 3 (the 0x0001 entry).
  libgphoto2 reads 3 as a full-press failure on the EOS M2. **Ref(`library.c`:`camera_trigger_canon_eos_capture`)**
- `capturePhoto()` messages for `0xC`/`0xE`: "The camera's power switch is on movie mode. Move it to
  ON to take photos." while `0xD1C2` = 1; otherwise "The camera refused the photo as if it were in
  movie mode. If its power switch is already on ON, turn it to the movie position and back to ON."
- Not verified on hardware: RequestObjectTransfer (capture to PC RAM) and TransferComplete, RAW or
  RAW+JPEG files, and capture while zoomed in.

### 11.7 Movie mode vs stills mode

`0xD1C2` (ptp.h EOS_FixedMovie, EDSDK kEdsPropID_FixedMovie) is 1 while the body is in movie mode:
the power switch is on the movie position, or an application sent MovieSelectSWOn `0x9133`.
MovieSelectSWOff `0x9134` returns the body to stills; EDSDK requires the hardware to be in stills
for that. **Ref(`ptp.h`)**, **Ext(EDSDK 5.2.88, 6.9)**

| | Movie mode (`0xD1C2` = 1) | Stills mode (`0xD1C2` = 0) | Provenance |
|---|---|---|---|
| Live-view JPEG at 1× | 1024×576 (16:9) | **960×640 (3:2)** | **Verified** |
| Sensor size, block `0xE` | 5976×3952 | 6000×3988 | **Verified** |
| Zoom rect, block `0x12` at 1× | 0,298 5976×3356 | 0,0 6000×3988 | **Verified** |
| ISO `0xD103` list (P) | empty | `0, 0x48 … 0x80` (Auto, 100–6400) | **Verified** |
| Aspect ratio `0xD194` list | none | `0, 2, 7, 1` | **Verified** |
| Drive mode `0xD106` list | none | `0, 1, 0x10, 0x11, 7` | **Verified** |
| EVF record status `0xD1B8` with live view on | 3 | 3 (0 with live view off) | **Verified** |

- Both GetEvent fixtures report `0xD1C2` = 1. The fw 1.0.1 EVF fixture's geometry (960×640,
  6000×3988) matches stills mode and the fw 1.1.0 one (1024×576, 5976×3952) matches movie mode.
  **Verified** (geometry); when each was captured relative to the switch position is not recorded.
- `0x9134` → `0xD1C2` = 0 and drops PC live view (`0xD1B0` reads 0); writing `0xD1B0` again restarts
  it in stills. `0x9133` → back to 1. After `0x9133` and the user moving the power switch from the
  movie position to ON, the next session still started with `0xD1C2` = 1, and `0x9134` cleared it,
  but releases stayed refused until the switch was cycled (§11.6). **Verified**
- `controlState()` sets `canCapturePhoto = false` and `photoUnavailableReason` = "The camera's power
  switch is on movie mode. Move it to ON to take photos." while `0xD1C2` = 1 (or when `0xD11B` = 0:
  "The camera has no room for photos. Check its memory card."). `capturePhoto()` refuses the same
  way before pressing anything. Mirrorup never sends `0x9133`/`0x9134`.

#### Geometry in stills mode (2026-11-17, **Verified**)

| | 1× | 5× |
|---|---|---|
| JPEG | 960×640 | 1200×800 |
| Block `0x12` (frame area) | 0,0 6000×3988 (whole sensor) | the 1200×800 crop |
| Magnifier, block `0xD` | 1200×800 | 1200×800 (= the crop) |
| 1-point AF frame, block `0x8` | **684×420** (movie mode: 1200×1200) | 396×400 |

The §11.4 mapping needs no change: it reads block `0x12` and `0xD` per frame. Checked at 1×:
`focus(at:)` (0.15, 0.2) → sent (300, 398), landed (344, 378), AF frame centred at (944, 778) for a
target of (900, 798); (0.6, 0.45) → AF frame centred at (3576, 1802) for (3600, 1795); (1, 1) →
clamped by the body to (4456, 2984). Results `focused` / `notFocused` (blank wall) as expected. 5×
zoom centred lands at (2400, 1594) = the sensor centre.

- Zoom(1) sent ~0.3 s after an AF cycle was answered OK and ignored once (frames stayed at 5×);
  `setZoom` now sends Zoom and ZoomPosition once more when streaming frames contradict the OK, and
  reports "The camera did not change the zoom. Try again in a moment." if the second is ignored too.
  The retried Zoom(1) worked (1.4 s). **Verified**

### 11.8 What the UI must know

- In Scene Intelligent Auto, only the AF method is adjustable. Exposure, white balance and picture
  style have no options, and writes would be refused.
- In P, exposure compensation, white balance and picture style are adjustable. Aperture, shutter and
  ISO are not (empty lists). Color temperature never is on the SL2.
- Focusing at a point and zooming need the 1-point AF method. Face + Tracking (the SL2's default)
  allows only whole-frame `autofocus()`. The UI can offer to switch the AF method first.
- Zoom changes the stream's frame size: 1× is 960×640 in stills mode and 1024×576 in movie mode;
  5× is 1200×800 in both. Points for `focus(at:)` and `setZoom(center:)` are normalized to the
  frame the camera actually sends, at every zoom level.
- `autofocus()` / `focus(at:)` return after the AF result, in 0.3–0.6 s in 1-point AF and up to 2 s
  in Face + Tracking. Run them off the main actor; frames keep flowing meanwhile.
- `capturePhoto()` takes about 2 s and returns the card file (6.6 MB Large Fine JPEG on the SL2).
  When `canCapturePhoto` is false, show `photoUnavailableReason`; on failure show the error's
  `message`.

## 12. Licensing

libgphoto2 is licensed under LGPL-2.1-or-later. Mirrorup links nothing from it and copies none of
its code. It served only as protocol documentation: the opcode, property, event and response
values above are interoperability facts, and every behaviour is described in our own words. The
FC.SDK and julianschroden.com write-ups were also used as descriptive references only. The Swift
implementation must be written from this document and the hardware observations, not from those
sources.

## 13. Sources

- libgphoto2 `camlibs/ptp2/`: `ptp.h`, `ptp.c`, `ptp-pack.c`, `library.c`, `config.c`,
  `ptp-private.h`, `ptp-bugs.h` (master, fetched 2026-11-16):
  https://github.com/gphoto/libgphoto2/tree/master/camlibs/ptp2
- gphoto support list: https://gphoto.sourceforge.io/proj/libgphoto2/support.php
- FC.SDK, "Live-view magnification" (EOS 6D / R6 measurements, EVF record decoding):
  https://github.com/SharpAstro/FC.SDK/blob/main/docs/canon-live-view-zoom.md
- J. Schroden, "Remote Live View using PTP/IP on Canon EOS Cameras" (2023):
  https://julianschroden.com/post/2023-08-19-remote-live-view-using-ptp-ip-on-canon-eos-cameras
- Canon EDSDK API Programming Reference (13.20.11): TakePicture errors 3.2.13, kEdsPropID_FixedMovie
  5.2.88, still/movie switching 6.9.
- Canon.Eos.Framework `EDSDK.cs` (EDSDK error constants, `EDS_ERR_TAKE_PICTURE_*` 0x8D01–0x8D08):
  https://github.com/esskar/Canon.Eos.Framework/blob/master/Canon.Eos.Framework/Internal/SDK/EDSDK.cs
