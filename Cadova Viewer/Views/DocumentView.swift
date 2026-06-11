import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import AppKit
import ViewerCore

struct DocumentView: View {
    let url: URL
    let errorHandler: (Error) -> ()
    @ObservedObject var viewModel: DocumentViewModel
    @State var isLoading = false
    @State var infoData: InformationView.Model?
    @State var modelData: ModelData?

    struct StandardView {
        let name: String
        let icon: Image
        let viewPreset: ViewPreset
    }

    let standardViewIsometric = StandardView(name: "Isometric", icon: Image(systemName: "cube"), viewPreset: .isometric)
    let standardViewFront = StandardView(name: "Front", icon: Image("front"), viewPreset: .front)
    let standardViewBack = StandardView(name: "Back", icon: Image("back"), viewPreset: .back)
    let standardViewLeft = StandardView(name: "Left", icon: Image("left"), viewPreset: .left)
    let standardViewRight = StandardView(name: "Right", icon: Image("right"), viewPreset: .right)
    let standardViewTop = StandardView(name: "Top", icon: Image("top"), viewPreset: .top)
    let standardViewBottom = StandardView(name: "Bottom", icon: Image("bottom"), viewPreset: .bottom)

    let spacer = ToolbarItem(id: NSToolbarItem.Identifier.space.rawValue, placement: .primaryAction, showsByDefault: true) { Color.clear }

    /// The viewport the toolbar and menus act on.
    private var focused: ViewportController { viewModel.focusedViewport }

    private var interactionMode: Binding<InteractionMode> {
        Binding(get: { viewModel.focusedViewport.measurementController.interactionMode },
                set: { viewModel.focusedViewport.measurementController.interactionMode = $0 })
    }

    private var projection: Binding<ViewportController.CameraProjection> {
        Binding(get: { viewModel.focusedViewport.projection },
                set: { viewModel.focusedViewport.projection = $0 })
    }

    var body: some View {
        ViewportSplitView(viewModel: viewModel)
            .frame(minWidth: 500, minHeight: 300)
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
            .onReceive(viewModel.document!.loadingStream) { status in
                withAnimation(.easeInOut) {
                    isLoading = status
                }
            }
            .onReceive(viewModel.document!.modelStream.receive(on: DispatchQueue.main)) { modelData in
                self.modelData = modelData
            }
            .onReceive(focused.showInfoSignal) { _ in
                if let modelData, let document = viewModel.document {
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
            ToolbarItem(id: "interaction-mode", placement: .primaryAction) {
                Picker("Mode", selection: interactionMode) {
                    Image(systemName: "rotate.3d")
                        .help("View")
                        .tag(InteractionMode.view)

                    Image(systemName: "ruler")
                        .help("Measure")
                        .tag(InteractionMode.measure)
                }
                .pickerStyle(.segmented)
            }

            spacer

            ToolbarItem(id: "projection", placement: .primaryAction) {
                Picker("Projection", selection: projection) {
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
                        focused.zoomOut()
                    } label: {
                        Label { Text("Zoom Out") } icon: { Image(systemName: "minus.magnifyingglass") }
                    }

                    Button {
                        focused.zoomIn()
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
                    focused.showViewPreset(view.viewPreset, animated: true)
                } label: {
                    Label { Text(view.name) } icon: { view.icon }
                }
                .help(view.name)
                .disabled(focused.canShowPresets[view.viewPreset] == false)
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
                    focused.clearRoll()
                } label: {
                    Label {
                        Text("Straighten Camera")
                    } icon: {
                        Image(systemName: "level")
                    }
                }
                .disabled(focused.canResetCameraRoll == false)
            }

            ToolbarItem(id: "share", placement: .primaryAction, showsByDefault: false) {
                ShareLink(item: url)
            }
        }
    }
}
