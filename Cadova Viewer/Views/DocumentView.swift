import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import AppKit

struct DocumentView: View {
    let url: URL
    let errorHandler: (Error) -> ()
    @ObservedObject var viewportController: ViewportController
    @State var isLoading = false
    @State var infoData: InformationView.Model?
    @State var modelData: ModelData?

    struct StandardView {
        let name: String
        let icon: Image
        let viewPreset: ViewportController.ViewPreset
    }

    let standardViewIsometric = StandardView(name: "Isometric", icon: Image(systemName: "cube"), viewPreset: .isometric)
    let standardViewFront = StandardView(name: "Front", icon: Image("front"), viewPreset: .front)
    let standardViewBack = StandardView(name: "Back", icon: Image("back"), viewPreset: .back)
    let standardViewLeft = StandardView(name: "Left", icon: Image("left"), viewPreset: .left)
    let standardViewRight = StandardView(name: "Right", icon: Image("right"), viewPreset: .right)
    let standardViewTop = StandardView(name: "Top", icon: Image("top"), viewPreset: .top)
    let standardViewBottom = StandardView(name: "Bottom", icon: Image("bottom"), viewPreset: .bottom)

    let spacer = ToolbarItem(id: NSToolbarItem.Identifier.space.rawValue, placement: .primaryAction, showsByDefault: true) { Color.clear }

    init(url: URL, errorHandler: @escaping (Error) -> Void, viewportController: ViewportController) {
        self.url = url
        self.errorHandler = errorHandler
        self.viewportController = viewportController
    }

    var body: some View {
        ViewerSceneView(viewportController: viewportController)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                viewportController.sceneViewSize = $0
                viewportController.sceneView.overlaySKScene?.size = $0
            }
            .frame(minWidth: 500, minHeight: 300)
            .overlay(alignment: .bottomLeading) {
                PartListOverlay(viewportController: viewportController)
            }
            .overlay(alignment: .bottomTrailing) {
                if viewportController.viewOptions.showCoordinateSystemIndicator {
                    CoordinateSystemIndicator(stream: viewportController.coordinateIndicatorValues)
                        .padding()
                }
            }
            .overlay(alignment: .bottom) {
                Text("Loading")
                    .font(.title2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(.black)
                    .background {
                        Capsule()
                            .fill(Color.yellow.opacity(0.8))
                            .shadow(color: .black, radius: 2, x: 0, y: 0)
                    }
                    .opacity(isLoading ? 1 : 0)
                    .padding()
                    .allowsHitTesting(false)
            }
            .colorScheme(.dark)
            .toolbar(id: "document") { toolbar }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): viewportController.hoverPoint = point
                case .ended: viewportController.hoverPoint = nil
                }
            }
            .onReceive(viewportController.document!.loadingStream) { status in
                withAnimation(.easeInOut) {
                    isLoading = status
                }
            }
            .onReceive(viewportController.document!.modelStream.receive(on: DispatchQueue.main)) { modelData in
                self.modelData = modelData
            }
            .onReceive(viewportController.showInfoSignal) { _ in
                if let modelData, let document = viewportController.document {
                    self.infoData = .init(document: document, modelData: modelData)
                }
            }
            .sheet(item: $infoData) { infoModel in
                InformationView(model: infoModel)
            }
    }

    @ToolbarContentBuilder
    var toolbar: some CustomizableToolbarContent {
        Group {
            ToolbarItem(id: "projection", placement: .primaryAction) {
                Picker("Projection", selection: $viewportController.projection) {
                    Image(systemName: "perspective")
                        .help("Perspective")
                        .tag(ViewportController.CameraProjection.perspective)

                    Image(systemName: "grid")
                        .help("Orthographic")
                        .tag(ViewportController.CameraProjection.orthographic)
                }
                .pickerStyle(.segmented)
            }

            spacer

            ToolbarItem(id: "zoom", placement: .primaryAction) {
                ControlGroup {
                    Button {
                        viewportController.zoomOut()
                    } label: {
                        Label { Text("Zoom Out") } icon: { Image(systemName: "minus.magnifyingglass") }
                    }

                    Button {
                        viewportController.zoomIn()
                    } label: {
                        Label { Text("Zoom In") } icon: { Image(systemName: "plus.magnifyingglass") }
                    }
                }
            }

            spacer
        }

        let itemForStandardView = { (view: StandardView, isDefault: Bool) in
            ToolbarItem(id: "standard-view-\(view.name.lowercased())", placement: .primaryAction, showsByDefault: isDefault) {
                Button {
                    viewportController.showViewPreset(view.viewPreset, animated: true)
                } label: {
                    Label { Text(view.name) } icon: { view.icon }
                }
                .help(view.name)
                .disabled(viewportController.canShowPresets[view.viewPreset] == false)
            }
        }

        Group {
            itemForStandardView(standardViewIsometric, true)
            itemForStandardView(standardViewFront, true)
            itemForStandardView(standardViewBack, false)
            itemForStandardView(standardViewLeft, false)
            itemForStandardView(standardViewRight, false)
            itemForStandardView(standardViewTop, true)
            itemForStandardView(standardViewBottom, false)
        }
        spacer

        let apps = ExternalApplication.appsAbleToOpen(url: url)
        Group {
            ToolbarItem(id: "openIn", placement: .primaryAction, showsByDefault: true) {
                Menu {
                    ForEach(apps, id: \.url) { app in
                        Button {
                            app.open(file: url, errorHandler: errorHandler)
                        } label: {
                            HStack {
                                Image(nsImage: app.icon)
                                Text(app.name)
                            }
                        }
                    }
                } label: {
                    Label {
                        Text("Open in…")
                    } icon: {
                        Image(systemName: "arrowshape.turn.up.forward.fill")
                    }
                }
                .disabled(apps.isEmpty)
            }
        }

        // Non-default
        Group {
            ToolbarItem(id: "clear-roll", placement: .primaryAction, showsByDefault: false) {
                Button {
                    viewportController.clearRoll()
                } label: {
                    Label {
                        Text("Straighten Camera")
                    } icon: {
                        Image(systemName: "level")
                    }
                }
                .disabled(viewportController.canResetCameraRoll == false)
            }

            ToolbarItem(id: "share", placement: .primaryAction, showsByDefault: false) {
                ShareLink(item: url)
            }
        }
    }
}
