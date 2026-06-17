import SwiftUI
import ViewerCore

/// Popover controls for the focused viewport's cutting plane: enable, axis, offset, flip and the
/// locator plane. Writes straight to `ViewportController.crossSection`, whose `didSet` re-applies
/// the cut to that viewport's scene.
struct CrossSectionControls: View {
    @ObservedObject var viewport: ViewportController

    var body: some View {
        let bounds = viewport.crossSectionModelBounds
        let range = sliderRange(for: bounds)
        let enabled = viewport.crossSection.enabled

        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $viewport.crossSection.enabled) {
                Text("Cross-Section").font(.headline)
            }

            VStack(alignment: .leading, spacing: 12) {
                Picker("Axis", selection: axisBinding) {
                    ForEach(CrossSection.Axis.allCases, id: \.self) { axis in
                        Text(axis.displayName).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Offset")
                    Slider(value: $viewport.crossSection.offset, in: range)
                }

                Toggle("Flip side", isOn: $viewport.crossSection.flipped)
                Toggle("Show plane", isOn: $viewport.crossSection.showPlane)
            }
            .disabled(!enabled)
        }
        .frame(width: 240)
        .padding()
    }

    /// The offset slider's range, widened slightly so the plane can sit just outside the model and a
    /// degenerate (single-point) box still yields a valid range.
    private func sliderRange(for bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) -> ClosedRange<Double> {
        let range = viewport.crossSection.offsetRange(boxMin: bounds.min, boxMax: bounds.max)
        guard range.lowerBound < range.upperBound else { return (range.lowerBound - 1)...(range.upperBound + 1) }
        return range
    }

    /// Changing axis re-centers the offset, since the slider range changes with it.
    private var axisBinding: Binding<CrossSection.Axis> {
        Binding {
            viewport.crossSection.axis
        } set: { newAxis in
            var section = viewport.crossSection
            section.axis = newAxis
            let bounds = viewport.crossSectionModelBounds
            let range = section.offsetRange(boxMin: bounds.min, boxMax: bounds.max)
            section.offset = (range.lowerBound + range.upperBound) / 2
            viewport.crossSection = section
        }
    }
}
