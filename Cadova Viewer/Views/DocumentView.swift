import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import AppKit

struct DocumentView: View {
    let url: URL
    let errorHandler: (Error) -> ()
    @ObservedObject var viewportController: ViewportController

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

    var body: some View {
        ViewerSceneView(sceneController: viewportController)
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
            .toolbar(id: "document") {
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

                let itemForStandardView = { (view: StandardView) in
                    ToolbarItem(id: "standard-view-\(view.name.lowercased())", placement: .primaryAction) {
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
                    itemForStandardView(standardViewIsometric)
                    itemForStandardView(standardViewFront)
                    itemForStandardView(standardViewBack)
                    itemForStandardView(standardViewLeft)
                    itemForStandardView(standardViewRight)
                    itemForStandardView(standardViewTop)
                    itemForStandardView(standardViewBottom)
                }

                Group {
                    ToolbarItem(id: "openIn", placement: .primaryAction, showsByDefault: true) {
                        Menu {
                            ForEach(openInApps, id: \.url) { app in
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
                        .disabled(openInApps.isEmpty)
                    }
                }

                // Non-default
                Group {
                    ToolbarItem(id: "clear-roll", placement: .primaryAction, showsByDefault: false) {
                        Button {
                            viewportController.clearRoll()
                        } label: {
                            Label {
                                Text("Level View")
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
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): viewportController.hoverPoint = point
                case .ended: viewportController.hoverPoint = nil
                }
            }
            .colorScheme(.dark)
    }


    var openInApps: [OpenInApp] {
        let fileManager = FileManager()
        return NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { appURL -> OpenInApp? in
            guard appURL != Bundle.main.bundleURL else { return nil }
            let path = appURL.path(percentEncoded: false)
            return OpenInApp(url: appURL, name: fileManager.displayName(atPath: path) , icon: NSWorkspace.shared.icon(forFile: path))
        }
    }

    struct OpenInApp {
        let url: URL
        let name: String
        let icon: NSImage

        func open(file fileURL: URL, errorHandler: @escaping (Error) -> ()) {
            Task {
                do {
                    try await NSWorkspace.shared.open([fileURL], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
                } catch {
                    errorHandler(error)
                }
            }
        }
    }
}
