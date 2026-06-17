import SwiftUI
import ViewerCore

/// Top-left row of scissor buttons: one per cross-section (the selected one is highlighted and shows
/// its popover + gizmo; hovering previews its plane), plus a trailing button to add another.
struct CrossSectionButtonsOverlay: View {
    @ObservedObject var viewport: ViewportController

    var body: some View {
        HStack(spacing: 6) {
            ForEach(viewport.crossSections) { section in
                sectionButton(section)
            }
            if viewport.crossSections.count < ViewportController.maxCrossSections {
                addButton
            }
        }
        .controlSize(.large)
        .buttonStyle(BlurButtonStyle())
        .padding(8)
    }

    private func sectionButton(_ section: CrossSection) -> some View {
        let isSelected = viewport.selectedCrossSectionID == section.id
        return Button {
            // Toggle: clicking the selected section again exits edit mode (the popover won't dismiss
            // on its own while editing — see `interactiveDismissDisabled`).
            viewport.selectedCrossSectionID = isSelected ? nil : section.id
        } label: {
            Image(systemName: "scissors")
                .frame(height: 16)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .help("Cross-section (click to edit)")
        .onHover { hovering in
            if hovering {
                viewport.hoveredCrossSectionID = section.id
            } else if viewport.hoveredCrossSectionID == section.id {
                viewport.hoveredCrossSectionID = nil
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                viewport.deleteCrossSection(section.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .popover(isPresented: selectionBinding(section), arrowEdge: .bottom) {
            CrossSectionControls(viewport: viewport)
                .interactiveDismissDisabled()
        }
    }

    private var addButton: some View {
        Button {
            viewport.addCrossSection()
        } label: {
            Image(systemName: "scissors")
                .frame(height: 16)
                .opacity(0.55)
        }
        .help("Add a cross-section")
    }

    /// True while this section is the selected one; clearing it (popover dismissed) deselects.
    private func selectionBinding(_ section: CrossSection) -> Binding<Bool> {
        Binding(
            get: { viewport.selectedCrossSectionID == section.id },
            set: { presented in
                if presented {
                    viewport.selectedCrossSectionID = section.id
                } else if viewport.selectedCrossSectionID == section.id {
                    viewport.selectedCrossSectionID = nil
                }
            }
        )
    }
}
