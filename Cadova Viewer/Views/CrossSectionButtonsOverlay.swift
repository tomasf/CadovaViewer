import SwiftUI
import ViewerCore

/// Top-left cluster of scissor buttons: one per cross-section, each tinted its section colour (the
/// selected one is a filled chip and shows its gizmo + bottom editing bar), plus a button to add
/// another. Wraps to further rows when the pane is too narrow to fit them all in one.
struct CrossSectionButtonsOverlay: View {
    @ObservedObject var viewport: ViewportController
    @Environment(\.appearsActive) private var appearsActive

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
        let baseColor = ColorPalette.color(forIndex: section.colorIndex)
        // Dim the section tint while the window is inactive, matching the measurement rows.
        let color = appearsActive ? baseColor : baseColor.opacity(0.45)
        let foreground: Color = isSelected ? .black : color
        let background = isSelected ? AnyShapeStyle(color) : AnyShapeStyle(.ultraThinMaterial)
        // The two zones fill the chip with no gap: each button carries its own padding so its hit area
        // (the whole left/right half, full height) is far bigger than the glyph it shows.
        return HStack(spacing: 0) {
            // Left zone: a checkbox toggling the cut's enabled state.
            Button {
                viewport.setCrossSectionEnabled(section.id, !section.enabled)
            } label: {
                Image(systemName: section.enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 6)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(section.enabled ? "Enabled (click to disable)" : "Disabled (click to enable)")

            // Right zone: the scissors enters/exits edit mode (clicking the selected one exits).
            Button {
                viewport.selectedCrossSectionID = isSelected ? nil : section.id
            } label: {
                Image(systemName: "scissors")
                    .font(.system(size: 16))
                    .foregroundStyle(foreground)
                    .opacity(section.enabled ? 1 : 0.6)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 4)
                    .padding(.trailing, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cross-section (click to edit)")
        }
        .frame(height: 28) // match chipContainer's height (16 content + 6 padding top/bottom)
        .background(background)
        .clipShape(RoundedRectangle(cornerSize: CGSize(width: 8, height: 8)))
        .contextMenu {
            Toggle("Enabled", isOn: Binding(
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
            chipContainer(background: AnyShapeStyle(.ultraThinMaterial.opacity(0.4))) {
                HStack(spacing: -1) {
                    Image(systemName: "scissors")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                RoundedRectangle(cornerSize: CGSize(width: 8, height: 8))
                    .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 4) // a little breathing room from the section buttons
        .help("Add a cross-section")
    }

    /// Wraps chip content in the shared rounded background used across the viewport chrome.
    private func chipContainer<Content: View>(background: some ShapeStyle,
                                              @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(height: 16)
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
