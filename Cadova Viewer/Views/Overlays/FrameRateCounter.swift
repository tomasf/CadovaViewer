#if DEBUG
import SwiftUI
import Combine

/// Debug-only frame rate readout for a viewport, toggled from View ▸ Show Frame Rate. Receives
/// samples straight from the render loop's stream, so only this view updates (rather than publishing
/// through the viewport controller, which would re-evaluate the whole document UI).
///
/// The viewport renders on demand, so the numbers are only meaningful while something is moving; when
/// rendering stops, the last sample stays up dimmed.
struct FrameRateCounter: View {
    static let visibilityDefaultsKey = "showFrameRate"

    let stream: AnyPublisher<FrameRateMeter.Sample, Never>

    @State private var sample: FrameRateMeter.Sample?
    @State private var isStale = true
    /// Bumped on every sample so the staleness `task` restarts its countdown.
    @State private var generation = 0

    /// Samples arrive every ~0.5 s while rendering; after this long without one, rendering stopped.
    private static let staleDelay: Duration = .seconds(1)

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            .opacity(isStale ? 0.5 : 1)
            .allowsHitTesting(false)
            .onReceive(stream.receive(on: DispatchQueue.main)) { newSample in
                sample = newSample
                isStale = false
                generation += 1
            }
            .task(id: generation) {
                try? await Task.sleep(for: Self.staleDelay)
                guard !Task.isCancelled else { return }
                isStale = true
            }
    }

    private var label: String {
        guard let sample else { return "-- fps" }
        let fps = Int(sample.framesPerSecond.rounded())
        let longest = Int((sample.longestFrameTime * 1000).rounded())
        return "\(fps) fps · max \(longest) ms"
    }
}
#endif
