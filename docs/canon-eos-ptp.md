# Canon EOS PTP notes for Mirrorup (EOS Rebel SL2 / 200D)

This file collects what Mirrorup needs to know to run live view on Canon EOS DSLRs over PTP,
with the Rebel SL2 / 200D (USB `0x04A9:0x32CC`) as the target body. It is written from
protocol knowledge. No code was copied from anywhere (see [Licensing](#11-licensing)).

## Provenance tags

Every claim carries one of these tags:

| Tag | Meaning |
|---|---|
| **Verified** | Verified (SL2 hardware): observed on the real SL2 through ImageCaptureCore `requestSendPTPCommand` pass-through. |
| **Ref(`file`:`function`)** | Reference (libgphoto2 `camlibs/ptp2/<file>`:`<function>`, master as of 2026-11-16). For bare `#define` tables it reads **Ref(`ptp.h`)**. |
| **Ext(source)** | Public reverse-engineering write-up, listed in [Sources](#12-sources). Not libgphoto2, and not seen on the SL2. |
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

The SL2 sends its blocks in this order: `FFFFFFFF, 1, F, 10, 14, 4, 5, 12, C, D, E, A, 13, 15, 7,
11, 0`. **Verified**. Block meanings above are taken from 6D/R6 numbering. That the SL2 uses the
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
- `0xC181`/`0xC186`: an image was shot on the body. Ignore it; Mirrorup does not download.

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

## 8. Exposure and focus controls (for later)

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

## 11. Licensing

libgphoto2 is licensed under LGPL-2.1-or-later. Mirrorup links nothing from it and copies none of
its code. It served only as protocol documentation: the opcode, property, event and response
values above are interoperability facts, and every behaviour is described in our own words. The
FC.SDK and julianschroden.com write-ups were also used as descriptive references only. The Swift
implementation must be written from this document and the hardware observations, not from those
sources.

## 12. Sources

- libgphoto2 `camlibs/ptp2/`: `ptp.h`, `ptp.c`, `ptp-pack.c`, `library.c`, `config.c`,
  `ptp-private.h`, `ptp-bugs.h` (master, fetched 2026-11-16):
  https://github.com/gphoto/libgphoto2/tree/master/camlibs/ptp2
- gphoto support list: https://gphoto.sourceforge.io/proj/libgphoto2/support.php
- FC.SDK, "Live-view magnification" (EOS 6D / R6 measurements, EVF record decoding):
  https://github.com/SharpAstro/FC.SDK/blob/main/docs/canon-live-view-zoom.md
- J. Schroden, "Remote Live View using PTP/IP on Canon EOS Cameras" (2023):
  https://julianschroden.com/post/2023-08-19-remote-live-view-using-ptp-ip-on-canon-eos-cameras
