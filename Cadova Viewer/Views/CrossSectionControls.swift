import SwiftUI
import ViewerCore

/// Popover for the selected cross-section: snap it flat to an axis, flip which half is kept, or delete
/// it. Position/orientation are set with the in-scene gizmo, so there are no sliders here.
struct CrossSectionControls: View {
    @ObservedObject var viewport: ViewportController

    private var selected: CrossSection? {
        guard let id = viewport.selectedCrossSectionID else { return nil }
        return viewport.crossSections.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cross-Section").font(.headline)

            HStack(spacing: 6) {
                Text("Align to").foregroundStyle(.secondary)
                ForEach(CrossSection.Axis.allCases, id: \.self) { axis in
                    Button(axis.displayName) { viewport.alignSelectedCrossSection(to: axis) }
                }
            }

            Toggle("Flip side", isOn: flipBinding)

            Divider()

            Button(role: .destructive) {
                if let id = viewport.selectedCrossSectionID { viewport.deleteCrossSection(id) }
            } label: {
                Label("Delete Cross-Section", systemImage: "trash")
            }
        }
        .frame(width: 220)
        .padding()
    }

    private var flipBinding: Binding<Bool> {
        Binding(get: { selected?.flipped ?? false }, set: { _ in viewport.flipSelectedCrossSection() })
    }
}
