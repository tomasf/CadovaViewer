import SwiftUI
import ViewerCore

/// The viewport's bottom chrome: the coordinate indicator (bottom-right) and, while a cross-section is
/// selected, its editing bar (centred). Both are siblings in a `ZStack` so the bar can slide in/out
/// cleanly while the indicator stays put. The bar reserves space for the indicator and, when the pane
/// is too narrow even for the minimal bar beside it, signals (via a preference) to drop the indicator.
///
/// `ViewThatFits` degrades the bar in order: centred → shifted left (clearing the indicator) → drop
/// the "Cross-section" label → drop the Align group → drop the indicator and centre the minimal bar.
struct ViewportBottomOverlay: View {
    @ObservedObject var viewport: ViewportController

    /// Footprint of the coordinate indicator (110pt + its padding): reserved on the bar's right and
    /// mirrored on its left to keep it centred.
    private static let indicatorReserved: CGFloat = 142
    private static let edgeMargin: CGFloat = 16

    /// The bar's fit ladder while the indicator is visible, widest first: shift left to clear the
    /// indicator, then shed the label and the Align group, and finally drop the indicator to take the
    /// full pane width. `ViewThatFits` renders the first rung that fits.
    private static let indicatorStages: [Layout] = [
        Layout(alignment: .centered,    components: [.text, .align, .flip, .indicator]),
        Layout(alignment: .shiftedLeft, components: [.text, .align, .flip, .indicator]),
        Layout(alignment: .shiftedLeft, components: [.align, .flip, .indicator]),
        Layout(alignment: .centered,    components: [.align, .flip]),
        Layout(alignment: .centered,    components: [.flip]),
        Layout(alignment: .centered,    components: []),
    ]

    /// The ladder when the indicator is already off: just shed features, always centred.
    private static let plainStages: [Layout] = [
        Layout(alignment: .centered, components: [.text, .align, .flip, .indicator]),
        Layout(alignment: .centered, components: [.align, .flip, .indicator]),
        Layout(alignment: .centered, components: [.flip, .indicator]),
        Layout(alignment: .centered, components: [.indicator]),
    ]

    /// One rung of the fit ladder: how to place the bar and which parts it carries.
    private struct Layout {
        enum Alignment { case centered, shiftedLeft }
        enum Component { case text, align, flip, indicator }
        var alignment: Alignment
        var components: Set<Component>
    }

    /// Set by the bar's tightest layout, which drops the indicator to make room.
    @State private var hideIndicator = false

    private var selected: CrossSection? {
        viewport.crossSections.first { $0.id == viewport.selectedCrossSectionID }
    }
    private var showIndicator: Bool { viewport.viewOptions.showCoordinateSystemIndicator }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let section = selected {
                barLayouts(section)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showIndicator && !hideIndicator {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    indicatorView
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewport.selectedCrossSectionID)
        .onPreferenceChange(CoordinateIndicatorHiddenKey.self) { hidden in
            // Preference values are resolved during layout. Mutating `@State` synchronously here
            // can therefore publish while SwiftUI is still updating this view hierarchy.
            DispatchQueue.main.async {
                if hideIndicator != hidden {
                    hideIndicator = hidden
                }
            }
        }
    }

    /// Picks the widest bar rung that fits the current indicator state.
    private func barLayouts(_ section: CrossSection) -> some View {
        let stages = showIndicator ? Self.indicatorStages : Self.plainStages
        return ViewThatFits(in: .horizontal) {
            ForEach(stages.indices, id: \.self) { index in
                stageView(stages[index], section)
            }
        }
    }

    @ViewBuilder
    private func stageView(_ stage: Layout, _ section: CrossSection) -> some View {
        let keepsIndicator = stage.components.contains(.indicator)
        let reserve = showIndicator && keepsIndicator ? Self.indicatorReserved : Self.edgeMargin
        let content = bar(
            section,
            showText: stage.components.contains(.text),
            showAlign: stage.components.contains(.align),
            showFlip: stage.components.contains(.flip)
        )
        Group {
            switch stage.alignment {
            case .centered:    centered(reserve) { content }
            case .shiftedLeft: shiftedLeft(reserve) { content }
            }
        }
        .coordinateIndicatorHidden(!keepsIndicator)
    }

    // MARK: - Layout rows

    /// Content centred in the pane: `reserve` on both sides (the right one matching the indicator's
    /// footprint) keeps it centred without overlapping the indicator.
    private func centered<Content: View>(_ reserve: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: reserve)
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
            Spacer().frame(width: reserve)
        }
    }

    /// Content pushed against the right-hand reserved (indicator) zone, slack on the left, so it shifts
    /// left of centre while clearing the indicator.
    private func shiftedLeft<Content: View>(_ trailingReserve: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer().frame(width: trailingReserve)
        }
    }

    private var indicatorView: some View {
        CoordinateSystemIndicator(stream: viewport.coordinateIndicatorValues)
            .padding()
    }

    // MARK: - Editing bar

    private func bar(_ section: CrossSection, showText: Bool, showAlign: Bool, showFlip: Bool) -> some View {
        VStack(spacing: 12) {
            Text("Cross-Section")

            HStack(spacing: 14) {
                VStack(spacing: 3) {
                    Toggle("", isOn: enabledBinding(section))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                    Text("Enabled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if showFlip {
                    Divider().frame(height: 26)
                    Button("Flip") { viewport.flipSelectedCrossSection() }
                        .disabled(!section.enabled) // an inactive cut can't be reshaped
                }

                if showAlign {
                    Divider().frame(height: 26)

                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            ForEach(CrossSection.Axis.allCases, id: \.self) { axis in
                                Button(axis.displayName) { viewport.alignSelectedCrossSection(to: axis) }
                                    .disabled(section.isAligned(to: axis))
                            }
                            Button("Nearest") { viewport.snapSelectedCrossSectionToNearestAxis() }
                                .disabled(section.isAxisAligned)
                        }

                        Text("Align")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!section.enabled) // an inactive cut can't be reshaped
                }

                Divider().frame(height: 26)

                Button(role: .destructive) {
                    viewport.deleteCrossSection(section.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this cross-section")

                Button("Done") { viewport.selectedCrossSectionID = nil }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 16)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Drives the active switch: reads the section's `enabled` flag, writes it back through the
    /// undoable controller mutator.
    private func enabledBinding(_ section: CrossSection) -> Binding<Bool> {
        Binding(
            get: { section.enabled },
            set: { viewport.setCrossSectionEnabled(section.id, $0) }
        )
    }
}

/// Set true by the cross-section bar's tightest layout, telling the bottom overlay to hide the
/// coordinate indicator so the minimal bar has room.
private struct CoordinateIndicatorHiddenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private extension View {
    func coordinateIndicatorHidden(_ hidden: Bool) -> some View {
        preference(key: CoordinateIndicatorHiddenKey.self, value: hidden)
    }
}
