import Foundation
import SwiftUI
import SceneKit

struct PartListOverlay: View {
    @ObservedObject var viewportController: ViewportController
    @State private var showList = false

    var body: some View {
        if viewportController.parts.count > 1 {
            Button {
                showList.toggle()
            } label: {
                Text(title)
                    .frame(width: 60)
                    .foregroundStyle(.foreground)
            }
            .controlSize(.large)
            .buttonStyle(BlurButtonStyle())
            .popover(isPresented: $showList, arrowEdge: .top) {
                PartList(viewportController: viewportController)
            }
            .padding()
        }
    }

    private var title: String {
        let (visibleCount, hiddenCount) = viewportController.effectivePartCounts
        return switch (visibleCount, hiddenCount) {
        case (_, 0): "All Parts"
        case (0, _): "No Parts"
        case (1, _): "1 Part"
        default: "\(visibleCount) Parts"
        }
    }
}

struct PartList: View {
    @ObservedObject var viewportController: ViewportController
    @State private var useExclusiveSelection = false

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(viewportController.parts) { part in
                    Toggle(isOn: partVisibility(part.id)) {
                        Text(part.displayName)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onHover { hovered in
                        viewportController.highlightedPartID = hovered ? part.id : nil
                    }
                }
            }

            Button(viewportController.visibleParts.isEmpty ? "Show All" : "Hide All") {
                if viewportController.visibleParts.isEmpty {
                    viewportController.hiddenPartIDs = []
                } else {
                    viewportController.visibleParts = []
                }
            }
            .padding(.top)
        }
        .frame(minWidth: 70)
        .padding()
        .onModifierKeysChanged { _, keys in
            useExclusiveSelection = keys.contains(.option)
        }
    }

    private func partVisibility(_ id: ModelData.Part.ID) -> Binding<Bool> {
        Binding {
            viewportController.visibleParts.contains(id)
        } set: { visible in
            if useExclusiveSelection {
                if viewportController.onlyVisiblePartID == id {
                    viewportController.hiddenPartIDs = [id]
                } else {
                    viewportController.onlyVisiblePartID = id
                }
            } else if visible {
                viewportController.visibleParts.insert(id)
            } else {
                viewportController.visibleParts.remove(id)
            }
        }
    }
}

struct BlurButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .padding(5)
            .background(configuration.isPressed ? .thickMaterial : .ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerSize: CGSize(width: 8, height: 8)))
    }
}
