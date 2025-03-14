import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import AppKit

struct DocumentView: View {
    let url: URL
    let errorHandler: (Error) -> ()
    @ObservedObject var sceneController: SceneController

    struct StandardView {
        let name: String
        let axis: String?
        let icon: Image
        let keyEquivalent: KeyEquivalent
        let viewPreset: SceneController.ViewPreset

        var title: AttributedString {
            let base = AttributedString(name)
            if let axis {
                var axisText = AttributedString("\n" + axis)
                axisText.foregroundColor = .secondary
                axisText.font = Font.caption
                return base + axisText
            } else {
                return base
            }
        }
    }

    var standardViews: [StandardView] = [
        .init(name: "Isometric", axis: "I", icon: Image(systemName: "cube"), keyEquivalent: "0", viewPreset: .isometric),
        .init(name: "Front", axis: "+Y", icon: Image("front"), keyEquivalent: "1", viewPreset: .front),
        .init(name: "Back", axis: "-Y", icon: Image("back"), keyEquivalent: "2", viewPreset: .back),
        .init(name: "Left", axis: "+X", icon: Image("left"), keyEquivalent: "3", viewPreset: .left),
        .init(name: "Right", axis: "-X", icon: Image("right"), keyEquivalent: "4", viewPreset: .right),
        .init(name: "Top", axis: "-Z", icon: Image("top"), keyEquivalent: "5", viewPreset: .top),
        .init(name: "Bottom", axis: "+Z", icon: Image("bottom"), keyEquivalent: "6", viewPreset: .bottom)
    ]

    var body: some View {
        ViewerSceneView(sceneController: sceneController)
            .coordinateSpace(name: "sceneView")
            .frame(minWidth: 500, minHeight: 300)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading) {
                    ForEach(sceneController.parts) { part in
                        Toggle(isOn: part.visibility) {
                            Text(part.displayName)
                        }
                    }
                }
                .padding()
            }
            .toolbar {
                Button {
                    sceneController.clearRoll()
                } label: {
                    Label {
                        Text("Level View")
                    } icon: {
                        Image(systemName: "level")
                    }
                }

                Toggle("Use normals", systemImage: "rays", isOn: $sceneController.useNormals)

                Toggle("Wireframe", systemImage: "square.split.diagonal.2x2", isOn: $sceneController.showAsWireframe)

                Picker("Projection", selection: $sceneController.projection) {
                    Image(systemName: "perspective")
                        .help("Perspective")
                        .tag(SceneController.CameraProjection.perspective)

                    Image(systemName: "grid")
                        .help("Orthographic")
                        .tag(SceneController.CameraProjection.orthographic)
                }
                .pickerStyle(.segmented)

                ForEach(standardViews, id: \.viewPreset) { view in
                    Button {
                        sceneController.showViewPreset(view.viewPreset, animated: true)
                    } label: {
                        Label {
                            Text(view.name)
                        } icon: {
                            view.icon
                        }
                    }
                    .help(view.name)
                }

                ShareLink(item: url)

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
                    Image(systemName: "arrowshape.turn.up.forward.fill")
                }
                .disabled(openInApps.isEmpty)

                //Button("Haj") {
                //    sceneController.test()
                //}
            }
            .onContinuousHover(coordinateSpace: .named("sceneView")) { phase in
                switch phase {
                case .active(let point): sceneController.hoverPoint = point
                case .ended: sceneController.hoverPoint = nil
                }
            }
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

struct ActionSegments<Value: Hashable, Content: View>: View {
    let titleKey: LocalizedStringKey
    let content: () -> Content
    let action: (Value) -> ()

    @State var value: Value? = nil

    init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content, action: @escaping (Value) -> Void) {
        self.titleKey = titleKey
        self.content = content
        self.action = action
    }

    var body: some View {
        Picker<Text, Value?, Content>(titleKey, selection: $value, content: content)
            .pickerStyle(.segmented)
            .onChange(of: value) { _, _ in
                if let value {
                    action(value)
                    self.value = nil
                }
            }
    }
}

class DocumentHostingController: NSHostingController<DocumentView>, NSMenuItemValidation {
    let sceneController: SceneController

    init(sceneController: SceneController, documentView: DocumentView) {
        self.sceneController = sceneController
        super.init(rootView: documentView)
    }
    
    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @IBAction func performSceneControllerMenuCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue, let command = SceneController.MenuCommand(rawValue: identifier) else {
            preconditionFailure("Invalid command")
        }
        sceneController.performMenuCommand(command, tag: sender.tag)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performSceneControllerMenuCommand(_:)),
           let identifier = menuItem.identifier?.rawValue,
           let command = SceneController.MenuCommand(rawValue: identifier)
        {
            return sceneController.canPerformMenuCommand(command, tag: menuItem.tag)
        } else {
            return true
        }
    }
}

extension ModelData.Part {
    var visibility: Binding<Bool> {
        .init {
            !node.isHidden
        } set: { value in
            node.isHidden = !value
        }
    }
}
