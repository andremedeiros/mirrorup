public import OSLog
import Darwin

/// Shared logging and signpost handles. All Mirrorup processes log under one subsystem so a single
/// `log stream --predicate 'subsystem == "cool.andre.Mirrorup"'` captures app, CLI and extension.
public enum Diagnostics {
    public static let subsystem = "cool.andre.Mirrorup"

    public static let usb = Logger(subsystem: subsystem, category: "usb")
    public static let ptp = Logger(subsystem: subsystem, category: "ptp")
    public static let imageCapture = Logger(subsystem: subsystem, category: "imagecapture")
    public static let canon = Logger(subsystem: subsystem, category: "canon")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let virtualCamera = Logger(subsystem: subsystem, category: "virtualcamera")
    public static let app = Logger(subsystem: subsystem, category: "app")

    /// Points-of-interest signposter; intervals show up in Instruments' os_signpost track.
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}

/// Host-time clock shared by every process on the machine.
///
/// `mach_absolute_time` is the clock behind `CMClockGetHostTimeClock()`, so values taken in the
/// capture process are directly comparable with sample-buffer timestamps inside the Camera Extension.
/// It does not advance while the machine sleeps, which is the desired behavior for frame ages.
public enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> UInt64 { mach_absolute_time() }

    public static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    public static func ticks(nanoseconds: UInt64) -> UInt64 {
        nanoseconds &* UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    /// Milliseconds elapsed between two host times; negative if `end` precedes `start`.
    public static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        if end >= start { return Double(nanoseconds(end - start)) / 1_000_000 }
        return -Double(nanoseconds(start - end)) / 1_000_000
    }

    public static func seconds(_ ticks: UInt64) -> Double { Double(nanoseconds(ticks)) / 1_000_000_000 }
}

extension Duration {
    public var milliseconds: Double {
        let (s, atto) = components
        return Double(s) * 1_000 + Double(atto) / 1_000_000_000_000_000
    }
}
