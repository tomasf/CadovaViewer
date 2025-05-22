import Foundation
import SwiftUI
import SceneKit

struct PartList: View {
    @ObservedObject var sceneController: SceneController
    @ObservedObject var viewportController: ViewportController
    @State var showList = false

    private var title: String {
        let (visibleCount, hiddenCount) = sceneController.parts.reduce(into: (0,0)) { result, part in
            if viewportController.hiddenPartIDs.contains(part.id) {
                result.1 += 1
            } else {
                result.0 += 1
            }
        }

        if hiddenCount == 0 {
            return "All Parts"
        } else if visibleCount == 0 {
            return "No Parts"
        } else if visibleCount == 1 {
            return "1 Part"
        } else {
            return "\(visibleCount) Parts"
        }
    }

    var body: some View {
        if sceneController.parts.count > 1 {
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
                VStack(alignment: .leading) {
                    ForEach(sceneController.parts) { part in
                        Toggle(isOn: Binding(get: {
                            !viewportController.hiddenPartIDs.contains(part.id)
                        }, set: { visible in
                            if visible {
                                viewportController.hiddenPartIDs.remove(part.id)
                            } else {
                                viewportController.hiddenPartIDs.insert(part.id)
                            }
                        })) {
                            Text(part.displayName)
                        }
                    }
                }
                .padding()
                //.interactiveDismissDisabled()
            }
            .padding()
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
