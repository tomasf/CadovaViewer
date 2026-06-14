import SwiftUI
import AppKit
import ViewerCore

/// The window-global parts sidebar. It always acts on the document's *focused* viewport: the
/// visibility checkmarks reflect and control that viewport's part visibility, and they update live as
/// focus moves between split panes (`DocumentViewModel` forwards the focused viewport's changes, so
/// observing it here is enough).
///
/// Rows are multi-selectable; right-click offers slice / show-only / center-view on the selected
/// parts, and double-click (or Return) frames them. Each row carries an async-rendered thumbnail.
struct PartsSidebar: View {
    @ObservedObject var viewModel: DocumentViewModel
    @ObservedObject var thumbnails: PartThumbnailService
    @ObservedObject var measurements: MeasurementController
    @State private var selection: Set<ModelData.Part.ID> = []
    @State private var useExclusiveSelection = false
    @State private var splitSpaceID = UUID()
    /// The sidebar's own size, persisted app-wide. We override the system "Sidebar icon size" with
    /// this so thumbnails are never as small as the system's Small option allows.
    @AppStorage("partsSidebarSize") private var sidebarSize: PartsSidebarSize = .large
    @AppStorage("partsMeasurementsSidebarRatio") private var partsMeasurementsSplitRatio = 0.35

    private let splitDividerHeight: CGFloat = 5
    private let minimumPartsHeight: CGFloat = 120
    private let minimumMeasurementHeight: CGFloat = 150

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
        self.thumbnails = viewModel.sceneController.thumbnails
        self.measurements = viewModel.measurements
    }

    private var viewport: ViewportController { viewModel.focusedViewport }
    private var allParts: [ModelData.Part] { viewModel.sceneController.parts }
    private var hasMeasurements: Bool {
        !measurements.measurements.isEmpty || measurements.hoverPreview != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let measurementHeight = measurementHeight(for: geometry.size.height)
            VStack(spacing: 0) {
                partsPane
                    .frame(maxHeight: .infinity)

                if hasMeasurements {
                    splitDivider(totalHeight: geometry.size.height)
                    MeasurementSidebarSection(
                        controller: measurements,
                        height: measurementHeight
                    )
                }
            }
            .coordinateSpace(.named(splitSpaceID))
        }
        .navigationTitle("Parts")
    }

    private var partsPane: some View {
        VStack(spacing: 0) {
            partsList
                .frame(maxHeight: .infinity)
            sidebarBottomBar
        }
    }

    private var partsList: some View {
        List(allParts, selection: $selection) { part in
            PartRow(
                part: part,
                thumbnail: thumbnails.thumbnail(for: part.id),
                isVisible: !viewport.hiddenPartIDs.contains(part.id),
                toggleVisibility: { toggleVisibility(part.id) }
            )
            .onHover { hovered in
                viewport.highlightedPartID = hovered ? part.id : nil
            }
        }
        // Override the system "Sidebar icon size"; the rows (and their thumbnails, which read this)
        // follow this choice instead.
        .environment(\.sidebarRowSize, sidebarSize.rowSize)
        .contextMenu(forSelectionType: ModelData.Part.ID.self) { ids in
            if !ids.isEmpty {
                Button("Center View") { viewport.centerView(onPartIDs: ids) }
                Button("Show Only") { viewport.visibleParts = ids }
                Divider()
                Button(sliceTitle(for: ids)) {
                    viewModel.document?.sliceModel(parts: parts(for: ids))
                }
            }
        } primaryAction: { ids in
            viewport.centerView(onPartIDs: ids)
        }
        .onModifierKeysChanged { _, keys in
            useExclusiveSelection = keys.contains(.option)
        }
        .onExitCommand { selection.removeAll() }
    }

    private var sidebarBottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    if viewport.hiddenPartIDs.isEmpty {
                        viewport.visibleParts = []
                    } else {
                        viewport.hiddenPartIDs = []
                    }
                } label: {
                    Image(systemName: viewport.hiddenPartIDs.isEmpty ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(viewport.hiddenPartIDs.isEmpty ? "Hide All" : "Show All")
                Spacer()
                Menu {
                    Picker("Size", selection: $sidebarSize) {
                        ForEach(PartsSidebarSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("View Options")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }

    private func measurementHeight(for totalHeight: CGFloat) -> CGFloat {
        let available = max(totalHeight - splitDividerHeight, 1)
        return max(available * clampedSplitRatio(partsMeasurementsSplitRatio, available: available), 0)
    }

    private func clampedSplitRatio(_ ratio: Double, available: CGFloat) -> Double {
        let lower = min(0.75, Double(min(minimumMeasurementHeight, available) / available))
        let upper = max(lower, Double(max(available - minimumPartsHeight, 1) / available))
        return min(max(ratio, lower), upper)
    }

    private func splitDivider(totalHeight: CGFloat) -> some View {
        let available = max(totalHeight - splitDividerHeight, 1)
        return Rectangle()
            .fill(Color.clear)
            .frame(height: splitDividerHeight)
            .overlay {
                Rectangle().fill(Color.secondary.opacity(0.25))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named(splitSpaceID))
                    .onChanged { value in
                        let measurementHeight = max(totalHeight - value.location.y - splitDividerHeight, 0)
                        partsMeasurementsSplitRatio = clampedSplitRatio(Double(measurementHeight / available), available: available)
                    }
            )
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private func parts(for ids: Set<ModelData.Part.ID>) -> [ModelData.Part] {
        allParts.filter { ids.contains($0.id) }
    }

    private func sliceTitle(for ids: Set<ModelData.Part.ID>) -> String {
        if ids.count == 1, let part = allParts.first(where: { $0.id == ids.first }) {
            return "Slice \"\(part.name)\""
        }
        return "Slice \(ids.count) Parts"
    }

    /// Toggles a part's visibility in the focused viewport. Mirrors the old popover list: a plain
    /// click flips just that part, while holding Option isolates it (and a second Option-click on the
    /// isolated part inverts back to showing everything else).
    private func toggleVisibility(_ id: ModelData.Part.ID) {
        if useExclusiveSelection {
            if viewport.onlyVisiblePartID == id {
                viewport.hiddenPartIDs = [id]
            } else {
                viewport.onlyVisiblePartID = id
            }
        } else if viewport.hiddenPartIDs.contains(id) {
            viewport.visibleParts.insert(id)
        } else {
            viewport.visibleParts.remove(id)
        }
    }
}

/// The sidebar's user-chosen size, shown in the bottom-bar view-options menu. It maps onto SwiftUI's
/// `SidebarRowSize` so the whole row (text, height, thumbnail) scales, deliberately skipping the
/// system's smallest size.
enum PartsSidebarSize: String, CaseIterable, Identifiable {
    case small
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small Icons"
        case .large: "Large Icons"
        }
    }

    var rowSize: SidebarRowSize {
        switch self {
        case .small: .medium
        case .large: .large
        }
    }
}

private struct PartRow: View {
    // Match the thumbnail to the system "Sidebar icon size" setting, which SwiftUI surfaces here and
    // also uses to size the row's text/height — so the image scales in step with the rest of the row.
    @Environment(\.sidebarRowSize) private var sidebarRowSize

    let part: ModelData.Part
    let thumbnail: NSImage?
    let isVisible: Bool
    let toggleVisibility: () -> Void

    private var thumbnailSize: CGFloat {
        switch sidebarRowSize {
        case .small: 18
        case .medium: 24
        case .large: 32
        @unknown default: 24
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
            Text(part.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: toggleVisibility) {
                Image(systemName: isVisible ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isVisible ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isVisible ? "Hide Part" : "Show Part")
        }
        .opacity(isVisible ? 1 : 0.45)
    }

    @ViewBuilder private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "cube")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
    }
}
