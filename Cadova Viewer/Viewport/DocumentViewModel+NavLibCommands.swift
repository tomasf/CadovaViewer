import Foundation
import NavLib
import ViewerCore

/// Application commands exposed to the 3Dconnexion configuration UI, so users can map them to
/// SpaceMouse buttons. The navlib persists the command file where the pref pane reads it only when
/// the app isn't sandboxed.
///
/// Labels and grouping mirror the app's menus (see `ViewportController+Menus`), so a command reads
/// the same in the 3Dconnexion settings as in the menu bar.
extension DocumentViewModel {
    enum SpaceMouseCommand: CaseIterable {
        case viewPreset(ViewPreset)
        case projection(ViewportController.CameraProjection)
        case toggleProjection
        case straightenCamera
        case toggleSmoothShading
        case edgeVisibility(ViewOptions.EdgeVisibility)
        case cycleEdgeVisibility
        case focusNextPane
        case focusPreviousPane
        case slice

        /// A top-level entry in the configuration UI: a category of commands, or a single command.
        enum LayoutEntry {
            case category(id: String, label: String, commands: [SpaceMouseCommand])
            case command(SpaceMouseCommand)

            var commands: [SpaceMouseCommand] {
                switch self {
                case .category(_, _, let commands): commands
                case .command(let command): [command]
                }
            }

            var navLibCommand: NavLibCommand {
                switch self {
                case .category(let id, let label, let commands):
                    .category(id: id, label: label, children: commands.map(\.navLibCommand))
                case .command(let command):
                    command.navLibCommand
                }
            }
        }

        /// The commands as laid out in the configuration UI: submenus become categories, plain menu
        /// items sit at the top level. Category ids must stay stable too.
        static let layout: [LayoutEntry] = [
            .category(id: "views", label: "Standard Views", commands: ViewPreset.allCases.map { .viewPreset($0) }),
            .category(id: "camera-projection", label: "Camera Projection", commands: [
                .projection(.perspective), .projection(.orthographic), .toggleProjection,
            ]),
            .command(.straightenCamera),
            .command(.toggleSmoothShading),
            .category(id: "edges", label: "Show Edges", commands: [
                .edgeVisibility(.none), .edgeVisibility(.sharp), .edgeVisibility(.all), .cycleEdgeVisibility,
            ]),
            .category(id: "panes", label: "Panes", commands: [.focusNextPane, .focusPreviousPane]),
            .command(.slice),
        ]

        static let allCases: [SpaceMouseCommand] = layout.flatMap(\.commands)

        /// Stable identifier reported back by the navlib. Must never change between releases, or
        /// users' button assignments are lost.
        var id: String {
            switch self {
            case .viewPreset(let preset): "view.\(preset.commandName)"
            case .projection(.perspective): "camera.perspective"
            case .projection(.orthographic): "camera.orthographic"
            case .toggleProjection: "camera.toggle-projection"
            case .straightenCamera: "camera.straighten"
            case .toggleSmoothShading: "display.toggle-smooth-shading"
            case .edgeVisibility(let visibility): "display.edges.\(visibility.rawValue)"
            case .cycleEdgeVisibility: "display.cycle-edges"
            case .focusNextPane: "pane.focus-next"
            case .focusPreviousPane: "pane.focus-previous"
            case .slice: "file.slice"
            }
        }

        var label: String {
            switch self {
            case .viewPreset(let preset): preset.menuLabel
            case .projection(.perspective): "Perspective"
            case .projection(.orthographic): "Orthographic"
            case .toggleProjection: "Toggle Projection"
            case .straightenCamera: "Straighten Camera"
            case .toggleSmoothShading: "Smooth Shading"
            case .edgeVisibility(.none): "None"
            case .edgeVisibility(.sharp): "Sharp"
            case .edgeVisibility(.all): "All"
            case .cycleEdgeVisibility: "Cycle Edges"
            case .focusNextPane: "Focus Next Pane"
            case .focusPreviousPane: "Focus Previous Pane"
            case .slice: "Slice"
            }
        }

        var description: String {
            switch self {
            case .viewPreset(let preset): "Show the \(preset.menuLabel.lowercased()) view in the focused pane"
            case .projection(.perspective): "Use perspective projection in the focused pane"
            case .projection(.orthographic): "Use orthographic projection in the focused pane"
            case .toggleProjection: "Switch the focused pane between perspective and orthographic projection"
            case .straightenCamera: "Level the camera so the model's up direction points up"
            case .toggleSmoothShading: "Turn smooth shading on or off in the focused pane"
            case .edgeVisibility(.none): "Hide edges in the focused pane"
            case .edgeVisibility(.sharp): "Show only sharp edges in the focused pane"
            case .edgeVisibility(.all): "Show all edges in the focused pane"
            case .cycleEdgeVisibility: "Cycle the focused pane's edges between none, sharp and all"
            case .focusNextPane: "Move focus to the next pane"
            case .focusPreviousPane: "Move focus to the previous pane"
            case .slice: "Open the model in the slicer"
            }
        }

        var navLibCommand: NavLibCommand {
            .action(id: id, label: label, description: description)
        }

        static let navLibCommands: [NavLibCommand] = layout.map(\.navLibCommand)
    }

    /// Registers the command set with the document's session and routes button presses to it.
    /// Call after the session has started.
    func registerNavLibCommands() {
        navLibSession.commandHandler = { [weak self] id in
            guard let command = SpaceMouseCommand.allCases.first(where: { $0.id == id }) else { return }
            // Defer out of the navlib callback: acting on a command moves the camera, which the
            // navlib then reads back.
            DispatchQueue.main.async { self?.perform(command) }
        }

        do {
            try navLibSession.registerCommands(SpaceMouseCommand.navLibCommands, setID: "cadova-viewer")
        } catch {
            print("NavLib command registration failed: \(error)")
        }
    }

    private func perform(_ command: SpaceMouseCommand) {
        let viewport = focusedViewport
        switch command {
        case .viewPreset(let preset):
            guard viewport.canShowViewPreset(preset) else { return }
            viewport.showViewPreset(preset, animated: true)
        case .projection(let projection):
            viewport.projection = projection
        case .toggleProjection:
            viewport.projection = viewport.projection == .perspective ? .orthographic : .perspective
        case .straightenCamera:
            viewport.clearRoll()
        case .toggleSmoothShading:
            viewport.viewOptions.smoothShading.toggle()
        case .edgeVisibility(let visibility):
            viewport.viewOptions.edgeVisibility = visibility
        case .cycleEdgeVisibility:
            viewport.viewOptions.edgeVisibility = viewport.viewOptions.edgeVisibility.next
        case .focusNextPane:
            focusAdjacentViewport(forward: true)
        case .focusPreviousPane:
            focusAdjacentViewport(forward: false)
        case .slice:
            let parts = sceneController.parts
            guard !parts.isEmpty else { return }
            document?.sliceModel(parts: parts)
        }
    }
}

private extension ViewPreset {
    /// Non-localized, stable name used in NavLib command identifiers.
    var commandName: String {
        switch self {
        case .isometric: "isometric"
        case .front: "front"
        case .back: "back"
        case .left: "left"
        case .right: "right"
        case .top: "top"
        case .bottom: "bottom"
        }
    }

    /// The label used in the Standard Views menu (`title` abbreviates isometric to "Iso").
    var menuLabel: String {
        self == .isometric ? "Isometric" : title
    }
}

private extension ViewOptions.EdgeVisibility {
    /// The next setting in the none → sharp → all cycle.
    var next: Self {
        switch self {
        case .none: .sharp
        case .sharp: .all
        case .all: .none
        }
    }
}
