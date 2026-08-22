import Testing
@testable import ViewerCore

struct GridScaleLegendTests {
    @Test func `exact single units show just the symbol`() {
        #expect(GridScaleLegend.label(forMillimeters: 1) == "mm")
        #expect(GridScaleLegend.label(forMillimeters: 10) == "cm")
        #expect(GridScaleLegend.label(forMillimeters: 100) == "dm")
        #expect(GridScaleLegend.label(forMillimeters: 1000) == "m")
        #expect(GridScaleLegend.label(forMillimeters: 1_000_000) == "km")
    }

    @Test func `sub-millimetre spacings stay in millimetres with a number`() {
        // Locale-independent: the number uses the current locale's separator, like the rest of the app.
        func expected(_ count: Double) -> String {
            "\(count.formatted(.number.precision(.fractionLength(0...3)))) mm"
        }
        #expect(GridScaleLegend.label(forMillimeters: 0.1) == expected(0.1))
        #expect(GridScaleLegend.label(forMillimeters: 0.01) == expected(0.01))
    }

    @Test func `multiples of the largest unit keep their count`() {
        #expect(GridScaleLegend.label(forMillimeters: 10_000) == "10 m")
        #expect(GridScaleLegend.label(forMillimeters: 100_000) == "100 m")
        #expect(GridScaleLegend.label(forMillimeters: 10_000_000) == "10 km")
    }

    @Test func `zero or negative spacing yields no label`() {
        #expect(GridScaleLegend.label(forMillimeters: 0) == "")
        #expect(GridScaleLegend.label(forMillimeters: -5) == "")
    }
}
