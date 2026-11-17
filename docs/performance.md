# Performance

All numbers below were measured on the hardware listed, with the commands shown. Raw output is in
`benchmarks/`. Nothing here is a requested or nominal setting.

**Setup:** Canon EOS Rebel SL2 (firmware 1.0.1 unless noted) on USB 2.0 High Speed, Apple Silicon Mac, macOS 27.2,
debug build of the `mirrorup` CLI, ImageCaptureCore transport, decode on (VideoToolbox JPEG →
1280×720 `420v`). Camera in a stills mode, live-view frames 1024×576 JPEG.

## Live-view throughput and timing

`mirrorup liveview benchmark --duration 600 --json benchmarks/sl2-600s-imagecapture.json`

| Metric | 60 s run | 600 s soak |
|---|---|---|
| Frames | 1,791 | 17,980 |
| Measured camera FPS | 29.82 | 29.96 |
| First frame after live-view start | 409 ms | 494 ms |
| Viewfinder polls / not-ready (`0xA102`) | 5,905 / 4,114 (70%) | 55,259 / 37,279 (67%) |
| Invalid payloads | 0 | 0 |
| Mean JPEG size | 195 KiB | 208 KiB |
| CPU (whole process) | 6.5% of one core | 6.9% of one core |
| Peak physical footprint | 9.7 MB | 10.6 MB |

Timing distributions for the 600 s soak (ms, n = 17,980):

| Stage | min | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| Acquisition: GetViewfinderData request → payload received | 6.83 | 15.10 | 20.93 | 24.93 | 52.18 |
| Inter-frame interval | 10.74 | 33.38 | 39.81 | 44.23 | 139.10 |
| Decode + scale (VideoToolbox) | 2.50 | 4.28 | 8.80 | 15.07 | 129.55 |
| Capture → decoded pixel buffer | 2.52 | 4.35 | 9.01 | 15.33 | 129.64 |

The 60 s run's maxima (decode 382 ms, inter-frame 392 ms) are the one-time VideoToolbox session
creation on the first frame. Memory grew by under 1 MB between the 60 s and 600 s runs.

### Firmware 1.1.0

After updating the camera to Canon firmware 1.1.0 (`benchmarks/sl2-fw110-60s-imagecapture.json`):
the operations list is identical (170), all hardware tests pass, and timings are unchanged within run
to run variation. Measured: 29.93 fps; acquisition p50/p95/p99 14.65/20.01/23.25 ms; decode p50/p95
4.66/7.32 ms; 69% not-ready polls; 0 invalid payloads; 8.3% CPU; 9.4 MB. The live-view payload gained
one block (type `0x8`) before the terminator; the parser ignores it.

## Recovery (app, real hardware)

Measured from the app's `capture` log, two manual tests each:

| Event | Detection | Camera visible again → streaming |
|---|---|---|
| USB cable unplugged / replugged | immediate (ImageCaptureCore returns an empty response; mapped to *disconnected*) | 1.14 s |
| Camera switched off / on | 3.0 s frame timeout (the body keeps answering "not ready" while it shuts down) | 0.79 s |

While the camera is absent the engine waits 3 s for discovery, then backs off with jitter
(observed 0.2 → 0.5 → 0.9 s). It never spins.

## What these numbers mean

- **Acquisition latency:** the camera produces a new frame about every 33 ms. Mirrorup asks for it
  within ≤3 ms (not-ready retry interval) and receives it about 15 ms (p50) after asking. The
  transfer of ~200 KB over USB 2.0 plus ptpcamerad's XPC hop is most of that.
- **Processing latency:** a frame is a decoded 1280×720 pixel buffer 4.4 ms (p50) / 9.0 ms (p95)
  after its last byte arrives.
- **Not measured:** glass-to-glass latency (exposure, the camera's internal JPEG encode and buffering,
  the client app's render path). That needs an external method (e.g. filming a millisecond clock
  through the whole chain) and has not been done.
- **Not yet measured:** submission to CoreMediaIO and consumer receipt. The extension logs frame age
  at delivery (`frameAge[...]` every 10 s in the `virtualcamera` category) and the app records
  delivered FPS and frame age in Diagnostics. Both need the Camera Extension active, which was not
  possible on the managed development Mac (see `usb-feasibility.md` and the README).

## Optimisation decisions

| Decision | Evidence |
|---|---|
| Poll GetViewfinderData with a 3 ms retry instead of sleeping a frame interval | The camera delivers ~30 fps regardless; polling fast bounds frame age to ≤3 ms + transfer. The cost is ~92 polls/s at ~1 ms each and 6.9% of a core for the whole process. |
| Parse the EVF payload in place; JPEG stays a `Data` slice | No per-frame copy of the 200 KB payload. Footprint flat at ~10 MB over 10 min. |
| Wrap JPEG bytes in a `CMBlockBuffer` without copying; decode synchronously | Safe because decode completes inside the bytes' lifetime. Decode p50 4.3 ms. |
| Decode and scale in one VideoToolbox pass into pooled IOSurface buffers | No intermediate RGB image; the same buffer is handed to the extension with no copy. |
| Single-slot buffers (engine, preview, CMIO sink queue size 1, extension relay) | Latency can't grow under a slow consumer; covered by `slowConsumerGetsFreshFramesAndDrops` and related tests. |
| Extension forwards each sink frame immediately; the 30 Hz timer only fills gaps | A fixed-cadence re-stamp timer adds up to one frame interval (avg ~17 ms) of latency. |
| No disk I/O or logging per frame on the hot path | Per-frame events are signposts (Instruments) or bounded counters; logs are rate-limited summaries. |

## Profiling

```bash
xcrun xctrace record --template 'Time Profiler' --launch -- .build/release/mirrorup liveview benchmark --duration 30
```

Signposts: `PTPTransaction` (each PTP transaction) and `Decode` (each frame) in the Points of Interest
track. No hot spots justified further optimisation at 6.9% CPU.
