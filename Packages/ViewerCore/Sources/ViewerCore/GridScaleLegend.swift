import Foundation
import SwiftUI
import Combine

/// A small heads-up legend showing what the grid's lines currently represent, as a vertical
/// "odometer" of metric units. Each unit fades in from the top, reaches full opacity as it scrolls
/// through the centre, then continues down and fades out — so zooming in/out slides the ladder
/// (0.1 mm → mm → cm → dm → m → 10 m) smoothly past the centre line. It appears while the scale
/// changes and fades out after a short idle; it hides entirely when the grid is hidden.
public struct GridScaleLegend: View {
    let stream: AnyPublisher<ViewportGrid.ScaleInfo, Never>

    /// Continuous position on the unit ladder (coarse spacing = 10^this mm); its fractional part is
    /// the scroll offset between units.
    @State private var exponent = 0.0
    @State private var shown = false
    /// Bumped on every update so the auto-hide `task` restarts its idle countdown.
    @State private var generation = 0

    public init(stream: AnyPublisher<ViewportGrid.ScaleInfo, Never>) {
        self.stream = stream
    }

    /// How long the legend stays up after the last change before fading out.
    private static let idleDuration: Duration = .seconds(2.5)
    /// Opacity of a unit centred on the line; rows fade from here to zero at `fadeRange`.
    private static let baseOpacity = 0.95
    /// Vertical distance between adjacent units.
    private static let rowHeight = 18.0
    /// How many rows from the centre a unit travels before it has fully faded out.
    private static let fadeRange = 1.25
    /// Exponents whose spacing the grid actually draws, bounded by ViewportGrid's scale clamp:
    /// coarse spans 1 mm…1 m (exponents 0…3) and fine reaches 0.1 mm (-1). Units outside this never
    /// appear as real lines, so the legend doesn't label them — e.g. no faint "10 m" at the zoom-out
    /// limit.
    private static let drawableExponents = -1...3

    public var body: some View {
        let center = exponent
        let lowest = max(Int((center - Self.fadeRange).rounded(.down)), Self.drawableExponents.lowerBound)
        let highest = min(Int((center + Self.fadeRange).rounded(.up)), Self.drawableExponents.upperBound)

        ZStack {
            if lowest <= highest {
                ForEach(lowest...highest, id: \.self) { unitExponent in
                    let distance = Double(unitExponent) - center
                    Text(Self.label(forExponent: unitExponent))
                        .offset(y: distance * Self.rowHeight)
                        .opacity(Self.rowOpacity(rowsFromCenter: abs(distance)))
                }
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 2)
        .frame(height: Self.rowHeight * Self.fadeRange * 2)
        .opacity(shown ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: shown)
        .allowsHitTesting(false)
        .onReceive(stream.receive(on: DispatchQueue.main)) { update($0) }
        .task(id: generation) {
            guard shown else { return }
            // A newer update bumps `generation`, which cancels this task; bail out rather than
            // falling through to hide (that would make the legend flicker away on every update).
            do {
                try await Task.sleep(for: Self.idleDuration)
            } catch {
                return
            }
            shown = false
        }
    }

    private func update(_ info: ViewportGrid.ScaleInfo) {
        if info.isVisible {
            exponent = info.coarseExponent
            shown = true
        } else {
            shown = false
        }
        generation &+= 1
    }

    /// Opacity for a unit `rowsFromCenter` rows away: full on the centre line, smoothly to zero at
    /// `fadeRange`.
    static func rowOpacity(rowsFromCenter distance: Double) -> Double {
        guard distance < fadeRange else { return 0 }
        return baseOpacity * (0.5 + 0.5 * cos(.pi * distance / fadeRange))
    }

    static func label(forExponent exponent: Int) -> String {
        label(forMillimeters: pow(10, Double(exponent)))
    }

    /// Formats a spacing in millimetres using the most natural metric unit, e.g. `0.1 mm`, `mm`,
    /// `cm`, `dm`, `m`, `10 m`. A spacing that is exactly one unit shows just the unit symbol.
    static func label(forMillimeters millimeters: Double) -> String {
        guard millimeters > 0 else { return "" }
        let units: [(symbol: String, millimeters: Double)] = [
            ("m", 1000), ("dm", 100), ("cm", 10), ("mm", 1)
        ]
        let unit = units.first { millimeters + 1e-9 >= $0.millimeters } ?? ("mm", 1)
        let count = millimeters / unit.millimeters
        if abs(count - 1) < 1e-6 { return unit.symbol }
        let number = count.formatted(.number.precision(.fractionLength(0...3)))
        return "\(number) \(unit.symbol)"
    }
}
