import SwiftUI
import ViewerCore

/// Popover for the selected cross-section: snap it flat to an axis, flip which half is kept, or delete
/// it. Position/orientation are set with the in-scene gizmo, so there are no sliders here.
struct CrossSectionControls: View {
    @ObservedObject var viewport: ViewportController

    private var selected: CrossSection? {
        viewport.crossSections.first { $0.id == viewport.selectedCrossSectionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button("Flip") { viewport.flipSelectedCrossSection() }
                ForEach(CrossSection.Axis.allCases, id: \.self) { axis in
                    Button(axis.displayName) { viewport.alignSelectedCrossSection(to: axis) }
                }
            }

            Button("Snap to Nearest Axis") { viewport.snapSelectedCrossSectionToNearestAxis() }

            Divider()

            HStack {
                Toggle("Active", isOn: Binding(
                    get: { selected?.enabled ?? true },
                    set: { active in
                        if let id = viewport.selectedCrossSectionID { viewport.setCrossSectionEnabled(id, active) }
                    }
                ))

                Spacer()

                Button(role: .destructive) {
                    if let id = viewport.selectedCrossSectionID { viewport.deleteCrossSection(id) }
                } label: {
                    Text("Remove")
                }
            }
        }
        .frame(width: 220)
        .padding()
    }
}
