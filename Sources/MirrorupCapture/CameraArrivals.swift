/// Tells the capture engine when a camera may have appeared, so it waits for one while none is
/// attached instead of polling (`CaptureState.waitingForCamera`). Counts every camera that appears,
/// usable or not: discovery decides which one to use.
public protocol CameraArrivals: Sendable {
    /// Grows by one each time a camera appears.
    var arrivalCount: UInt64 { get async }
    /// Returns once `arrivalCount` is greater than `count` (at once if it already is), or when the
    /// calling task is cancelled.
    func waitForArrival(after count: UInt64) async
}
