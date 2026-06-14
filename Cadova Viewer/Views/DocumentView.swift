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
    @State var isSlicing = false
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

    /// Drives the measurement toolbar toggle: on enters measure mode, off returns to view. (The mode
    /// also turns itself off automatically once a measurement is completed.)
    private var measureActive: Binding<Bool> {
        Binding(get: { viewModel.measurements.interactionMode == .measure },
                set: { viewModel.measurements.interactionMode = $0 ? .measure : .view })
    }

    private var projection: Binding<ViewportController.CameraProjection> {
        Binding(get: { viewModel.focusedViewport.projection },
                set: { viewModel.focusedViewport.projection = $0 })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $viewModel.sidebarVisibility) {
            DocumentSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            viewportArea
                .colorScheme(.dark)
        }
        .toolbar(id: "document") { toolbar }
        .onReceive(viewModel.document!.loadingStream) { status in
            withAnimation(.easeInOut) {
                isLoading = status
            }
        }
        .onReceive(viewModel.document!.slicingStream) { status in
            withAnimation(.easeInOut) {
                isSlicing = status
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

    /// The 3D viewport (possibly split) and its document-global overlays.
    private var viewportArea: some View {
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
            .overlay(alignment: .bottom) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing…")
                        .font(.title2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .colorScheme(.light)
                .background {
                    Capsule()
                        .fill(Color.yellow.opacity(0.8))
                        .shadow(color: .black, radius: 2, x: 0, y: 0)
                }
                .opacity(isSlicing ? 1 : 0)
                .padding()
                .allowsHitTesting(false)
            }
    }

    @ToolbarContentBuilder
    var toolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "sidebar", placement: .navigation) {
            Button {
                viewModel.toggleSidebar()
            } label: {
                Label("Parts", systemImage: "sidebar.left")
            }
            .help("Show or hide the parts sidebar")
        }

        Group {
            ToolbarItem(id: "interaction-mode", placement: .primaryAction) {
                Toggle(isOn: measureActive) {
                    Label("Measure", systemImage: "ruler")
                }
                .toggleStyle(.button)
                .help("Measure a distance (turns off after one measurement)")
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

        Group {
            ToolbarItem(id: "slice", placement: .primaryAction, showsByDefault: true) {
                Button {
                    let parts = modelData?.parts ?? []
                    // Holding Option slices only the parts visible in the focused viewport.
                    let included = NSEvent.modifierFlags.contains(.option) ? parts.filter { !focused.hiddenPartIDs.contains($0.id) } : parts
                    viewModel.document?.sliceModel(parts: included)
                } label: {
                    Label {
                        Text("Slice")
                    } icon: {
                        Image(systemName: "printer.fill")
                    }
                }
                .help("Slice in the preferred slicer (hold Option to slice only visible parts)")
                .disabled(modelData == nil)
            }
        }

        let apps = ExternalApplication.appsAbleToOpen(url: url)
        Group {
            ToolbarItem(id: "openIn", placement: .primaryAction, showsByDefault: false) {
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
