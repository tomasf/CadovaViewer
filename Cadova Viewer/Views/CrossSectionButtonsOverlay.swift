import SwiftUI
import ViewerCore

/// Top-left row of scissor buttons: one per cross-section, each tinted its section colour (the
/// selected one is a filled chip and shows its popover + gizmo; hovering previews its plane), plus a
/// button to add another.
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
        .padding(8)
    }

    private func sectionButton(_ section: CrossSection) -> some View {
        let isSelected = viewport.selectedCrossSectionID == section.id
        let color = ColorPalette.color(forIndex: section.colorIndex)
        return Button {
            // Toggle: clicking the selected section again exits edit mode (the popover won't dismiss
            // on its own while editing — see `interactiveDismissDisabled`).
            viewport.selectedCrossSectionID = isSelected ? nil : section.id
        } label: {
            if isSelected {
                chip(Image(systemName: "scissors"), foreground: .black, background: color)
            } else {
                chip(Image(systemName: "scissors"), foreground: color, background: .ultraThinMaterial)
            }
        }
        .buttonStyle(.plain)
        .opacity(section.enabled ? 1 : 0.4) // dim a disabled cut's button
        .help("Cross-section (click to edit)")
        .onHover { hovering in
            if hovering {
                viewport.hoveredCrossSectionID = section.id
            } else if viewport.hoveredCrossSectionID == section.id {
                viewport.hoveredCrossSectionID = nil
            }
        }
        .contextMenu {
            Toggle("Active", isOn: Binding(
                get: { section.enabled },
                set: { viewport.setCrossSectionEnabled(section.id, $0) }
            ))
            Divider()
            Button(role: .destructive) {
                viewport.deleteCrossSection(section.id)
            } label: {
                Text("Remove")
            }
        }
        .popover(isPresented: selectionBinding(section), arrowEdge: .bottom) {
            CrossSectionControls(viewport: viewport)
                .interactiveDismissDisabled()
                // The viewport area forces `.colorScheme(.dark)`, which the popover would inherit
                // (white text in light mode). Restore the real system appearance.
                .colorScheme(.system)
        }
    }

    private var addButton: some View {
        Button {
            viewport.addCrossSection()
        } label: {
            chip(Image(systemName: "scissors"), foreground: .secondary, background: .ultraThinMaterial)
        }
        .buttonStyle(.plain)
        .help("Add a cross-section")
    }

    /// A button label styled like the viewport chrome buttons: an icon over a rounded background.
    private func chip(_ icon: Image, foreground: Color, background: some ShapeStyle) -> some View {
        icon
            .font(.system(size: 16))
            .frame(height: 16)
            .foregroundStyle(foreground)
            .padding(6)
            .background(background)
            .clipShape(RoundedRectangle(cornerSize: CGSize(width: 8, height: 8)))
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
