import SwiftUI
import AppKit
import ViewerCore

/// The window-global document sidebar. It always acts on the document's *focused* viewport: part
/// visibility checkmarks reflect and control that viewport's part visibility, and they update live as
/// focus moves between split panes (`DocumentViewModel` forwards the focused viewport's changes, so
/// observing it here is enough). Measurements are document-global.
///
/// Rows are multi-selectable; right-click offers slice / show-only / center-view on the selected
/// parts, and double-click (or Return) frames them. Each row carries an async-rendered thumbnail.
struct DocumentSidebar: View {
    @ObservedObject var viewModel: DocumentViewModel
    @ObservedObject var thumbnails: PartThumbnailService
    let measurements: MeasurementController
    @State private var selection: Set<ModelData.Part.ID> = []
    @State private var useExclusiveSelection = false
    @State private var measurementRows: [Measurement] = []
    @State private var lastMeasurementScrollSignature: MeasurementScrollSignature?
    @State private var measurementScrollToken = 0
    /// The sidebar's own size, persisted app-wide.
    @AppStorage("documentSidebarSize") private var sidebarSize: DocumentSidebarSize = .large

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
        self.thumbnails = viewModel.sceneController.thumbnails
        self.measurements = viewModel.measurements
    }

    private var viewport: ViewportController { viewModel.focusedViewport }
    private var allParts: [ModelData.Part] { viewModel.sceneController.parts }
    private var hasMeasurements: Bool {
        !measurementRows.isEmpty
    }
    private var currentMeasurementRows: [Measurement] {
        measurements.measurements + (measurements.hoverPreview.map { [$0] } ?? [])
    }

    var body: some View {
        sidebarList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarBottomBar
            }
            .navigationTitle("Contents")
    }

    private var sidebarList: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Section("Parts") {
                    ForEach(allParts) { part in
                        PartRow(
                            part: part,
                            thumbnails: thumbnails,
                            isVisible: !viewport.hiddenPartIDs.contains(part.id),
                            toggleVisibility: { toggleVisibility(part.id) }
                        )
                        .tag(part.id)
                        .onHover { hovered in
                            viewport.highlightedPartID = hovered ? part.id : nil
                        }
                    }
                }

                if hasMeasurements {
                    Section("Measurements") {
                        ForEach(measurementRows) { measurement in
                            SidebarMeasurementRow(measurement: measurement) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if NSEvent.modifierFlags.contains(.option) {
                                        measurements.deleteAll()
                                    } else {
                                        measurements.delete(measurement.id)
                                    }
                                }
                            }
                            .id(measurement.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .onHover { hovering in
                                if hovering {
                                    measurements.highlightedID = measurement.id
                                } else if measurements.highlightedID == measurement.id {
                                    measurements.highlightedID = nil
                                }
                            }
                        }
                    }
                }
            }
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
            .onKeyPress(.space) {
                toggleSelectedPartsVisibility()
                return .handled
            }
            .onHover { hovering in
                measurements.isPointerOverList = hovering && hasMeasurements
            }
            .onDisappear {
                measurements.isPointerOverList = false
            }
            .onAppear {
                refreshMeasurementRows()
            }
            .onReceive(measurements.didChange.throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)) { _ in
                refreshMeasurementRows()
            }
            .onChange(of: measurementScrollToken) { _, _ in
                scrollToLatestMeasurement(proxy)
            }
        }
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
                        ForEach(DocumentSidebarSize.allCases) { size in
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

    private func parts(for ids: Set<ModelData.Part.ID>) -> [ModelData.Part] {
        allParts.filter { ids.contains($0.id) }
    }

    private func sliceTitle(for ids: Set<ModelData.Part.ID>) -> String {
        ids.count == 1 ? "Slice" : "Slice \(ids.count) Parts"
    }

    private func refreshMeasurementRows() {
        let rows = currentMeasurementRows
        measurementRows = rows

        let signature = MeasurementScrollSignature(rows: rows)
        guard signature != lastMeasurementScrollSignature else { return }
        lastMeasurementScrollSignature = signature
        measurementScrollToken += 1
    }

    private func scrollToLatestMeasurement(_ proxy: ScrollViewProxy) {
        guard let id = measurementRows.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func toggleSelectedPartsVisibility() {
        guard !selection.isEmpty else { return }
        if selection.count == 1, let id = selection.first {
            toggleVisibility(id)
        } else if selection.allSatisfy({ viewport.hiddenPartIDs.contains($0) }) {
            viewport.visibleParts.formUnion(selection)
        } else {
            viewport.visibleParts.subtract(selection)
        }
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
enum DocumentSidebarSize: String, CaseIterable, Identifiable {
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

private struct MeasurementScrollSignature: Equatable {
    var count: Int
    var lastID: Measurement.ID?
    var lastHasEnd: Bool

    init(rows: [Measurement]) {
        count = rows.count
        lastID = rows.last?.id
        lastHasEnd = rows.last?.end != nil
    }
}

private struct PartRow: View {
    // Match the thumbnail to the system "Sidebar icon size" setting, which SwiftUI surfaces here and
    // also uses to size the row's text/height — so the image scales in step with the rest of the row.
    @Environment(\.sidebarRowSize) private var sidebarRowSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.appearsActive) private var appearsActive

    let part: ModelData.Part
    // Not observed: the parent `DocumentSidebar` observes the service and rebuilds these rows when a
    // render lands, at which point this row re-reads the now-cached thumbnail.
    let thumbnails: PartThumbnailService
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

    /// The thumbnail rendered to match this row's exact device-pixel footprint, so it's pixel-perfect
    /// at the current sidebar icon size and display scale.
    private var thumbnail: NSImage? {
        thumbnails.thumbnail(for: part.id, pixelSize: Int((thumbnailSize * displayScale).rounded()))
    }

    private var checkmarkStyle: AnyShapeStyle {
        if appearsActive, isVisible {
            AnyShapeStyle(Color.accentColor)
        } else if appearsActive {
            AnyShapeStyle(.secondary)
        } else {
            AnyShapeStyle(.tertiary)
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
                    .fontWeight(.bold)
                    .imageScale(.large)
                    .foregroundStyle(checkmarkStyle)
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
