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
    @State private var selection: Set<ModelData.Part.ID> = []
    @State private var useExclusiveSelection = false

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
        self.thumbnails = viewModel.sceneController.thumbnails
    }

    private var viewport: ViewportController { viewModel.focusedViewport }
    private var allParts: [ModelData.Part] { viewModel.sceneController.parts }

    var body: some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button(viewport.hiddenPartIDs.isEmpty ? "Hide All" : "Show All") {
                        if viewport.hiddenPartIDs.isEmpty {
                            viewport.visibleParts = []
                        } else {
                            viewport.hiddenPartIDs = []
                        }
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
        .navigationTitle("Parts")
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
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.06))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(1)
            } else {
                Image(systemName: "cube")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
    }
}
