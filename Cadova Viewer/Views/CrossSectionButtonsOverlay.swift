import SwiftUI
import ViewerCore

/// Top-left cluster of scissor buttons: one per cross-section, each tinted its section colour (the
/// selected one is a filled chip and shows its gizmo + bottom editing bar; hovering previews its
/// plane), plus a button to add another. Wraps to further rows when the pane is too narrow to fit
/// them all in one.
struct CrossSectionButtonsOverlay: View {
    @ObservedObject var viewport: ViewportController

    var body: some View {
        FlowLayout(spacing: 6) {
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
            // Toggle: clicking the selected section again exits edit mode (closing the bottom bar).
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
                Text("Delete")
            }
            .modifierKeyAlternate(.option) {
                Button(role: .destructive) {
                    viewport.deleteAllCrossSections()
                } label: {
                    Text("Delete All")
                }
            }
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
}

/// Lays subviews left-to-right, wrapping to a new row once the next one would exceed the proposed
/// width. Rows are packed to their tallest subview's height.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: min(max(totalWidth, rowWidth), maxWidth), height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
