#if DEBUG
import Foundation

/// Measures the viewport's frame rate from render-loop frame times, for the Debug-only frame rate
/// counter. Fed every frame from `renderer(_:updateAtTime:)` and reports a `Sample` about twice a
/// second, so the overlay only updates at that rate.
///
/// The viewport renders on demand, so frames stop entirely when nothing changes. A gap longer than
/// `idleGap` is taken as rendering having stopped (not a slow frame) and starts a fresh measurement,
/// so the first frames after idling don't report a huge frame time.
struct FrameRateMeter {
    struct Sample: Equatable {
        /// Average frames per second over the measurement window.
        var framesPerSecond: Double
        /// The longest single frame interval in the window, in seconds. Shows hitches that the
        /// average hides.
        var longestFrameTime: TimeInterval
    }

    private static let window: TimeInterval = 0.5
    private static let idleGap: TimeInterval = 0.5

    private var windowStart: TimeInterval?
    private var lastFrameTime: TimeInterval?
    private var frameCount = 0
    private var longestFrameTime: TimeInterval = 0

    /// Records a frame rendered at `time` (render-loop time, in seconds). Returns a sample when a
    /// measurement window completes, otherwise nil.
    mutating func recordFrame(at time: TimeInterval) -> Sample? {
        defer { lastFrameTime = time }

        guard let windowStart, let lastFrameTime, time - lastFrameTime <= Self.idleGap else {
            startWindow(at: time)
            return nil
        }

        frameCount += 1
        longestFrameTime = max(longestFrameTime, time - lastFrameTime)

        let elapsed = time - windowStart
        guard elapsed >= Self.window else { return nil }

        let sample = Sample(framesPerSecond: Double(frameCount) / elapsed, longestFrameTime: longestFrameTime)
        startWindow(at: time)
        return sample
    }

    private mutating func startWindow(at time: TimeInterval) {
        windowStart = time
        frameCount = 0
        longestFrameTime = 0
    }
}
#endif
