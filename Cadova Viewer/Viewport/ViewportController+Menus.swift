import Cocoa
import SceneKit

extension ViewportController {
    func contextMenu() -> NSMenu {
        let builder = MenuBuilder()
        if sceneController.parts.count > 1 {
            if sceneController.parts.count >= 10 {
                builder.addItem(label: "Parts", submenu: { builder in
                    self.buildPartsMenuItems(with: builder)
                })
            } else {
                builder.addHeader("Parts")
                buildPartsMenuItems(with: builder)
                builder.addSeparator()
            }

            if hiddenPartIDs.isEmpty {
                builder.addItem(label: "Hide All") {
                    self.hiddenPartIDs = Set(self.sceneController.parts.map(\.id))
                }
            } else {
                builder.addItem(label: "Show All") {
                    self.hiddenPartIDs = []
                }
            }
            builder.addSeparator()
        }

        buildViewOptionToggles(with: builder)
        builder.addItem(label: "Show Edges", submenu: buildEdgeVisibilityMenu)
        return builder.makeMenu()
    }

    func buildPartsMenuItems(with builder: MenuBuilder) {
        for part in self.sceneController.parts {
            builder.addItem(label: part.name, checked: hiddenPartIDs.contains(part.id) == false) {
                self.hiddenPartIDs.formSymmetricDifference([part.id])
            } onHighlight: { h, _ in
                self.highlightedPartID = h ? part.id : nil
            }

            builder.addItem(label: "Show only \"\(part.name)\"", checked: onlyVisiblePartID == part.id, modifiers: .option) {
                self.onlyVisiblePartID = part.id
            } onHighlight: { h, _ in
                self.highlightedPartID = h ? part.id : nil
            }
        }
    }


    func buildViewMenu(with builder: MenuBuilder) {
        let currentView = currentCameraView

        func preset(_ preset: ViewPreset, label: String, shortcut: String) {
            builder.addItem(label: label, keyEquivalent: shortcut) {
                self.showViewPreset(preset, animated: true)
            } onHighlight: { highlighted, isClosing in
                if !isClosing {
                    self.setCameraView(highlighted ? self.cameraView(for: preset) : currentView, movement: .preview)
                }
            }
        }

        preset(.isometric, label: "Isometric", shortcut: "0")
        preset(.front, label: "Front", shortcut: "1")
        preset(.back, label: "Back", shortcut: "2")
        preset(.left, label: "Left", shortcut: "3")
        preset(.right, label: "Right", shortcut: "4")
        preset(.top, label: "Top", shortcut: "5")
        preset(.bottom, label: "Bottom", shortcut: "6")

        builder.addSeparator()
        builder.addItem(label: "Zoom In", keyEquivalent: "+") {
            self.zoomIn()
        }
        builder.addItem(label: "Zoom Out", keyEquivalent: "-") {
            self.zoomOut()
        }

        builder.addSeparator()
        builder.addItem(label: "Camera Projection", submenu: { builder in
            builder.addItem(label: "Perspective", checked: self.projection == .perspective) {
                self.projection = .perspective
            }
            builder.addItem(label: "Orthographic", checked: self.projection == .orthographic) {
                self.projection = .orthographic
            }
        })

        builder.addItem(label: "Straighten Camera", keyEquivalent: "l") {
            self.clearRoll()
        }

        builder.addSeparator()
        buildViewOptionToggles(with: builder)
        builder.addItem(label: "Show Edges", submenu: buildEdgeVisibilityMenu)
    }

    func buildFileMenu(with builder: MenuBuilder) {
        builder.addSeparator()
        builder.addItem(label: "Show Info", keyEquivalent: "i", modifiers: .command) {
            self.showInfoCallbackSignals.send()
        }
        builder.addItem(label: "Open in", submenu: { builder in
            guard let url = self.document?.fileURL else { return }
            for app in ExternalApplication.appsAbleToOpen(url: url) {
                builder.addItem(label: app.name, icon: app.icon) {
                    app.open(file: url, errorHandler: { _ in })
                }
            }
        })
    }

    func buildWindowMenu(with builder: MenuBuilder) {
        builder.addSeparator()
        builder.addItem(label: "SceneKit Debug Inspector", keyEquivalent: "R", modifiers: [.command, .control]) {
            self.showSceneKitRenderingOptions()
        }
    }

    func buildViewOptionToggles(with builder: MenuBuilder) {
        builder.addItem(label: "Show Grid", checked: viewOptions.showGrid) {
            self.viewOptions.showGrid = !self.viewOptions.showGrid
        }

        builder.addItem(label: "Show Origin", checked: viewOptions.showOrigin) {
            self.viewOptions.showOrigin = !self.viewOptions.showOrigin
        }

        builder.addItem(label: "Show Axis Directions", checked: viewOptions.showCoordinateSystemIndicator) {
            self.viewOptions.showCoordinateSystemIndicator = !self.viewOptions.showCoordinateSystemIndicator
        }
    }

    func buildEdgeVisibilityMenu(_ menuBuilder: MenuBuilder) {
        let initialEdgeVisibility = self.viewOptions.edgeVisibility

        func visibility(_ visibility: ViewOptions.EdgeVisibility, label: String) {
            menuBuilder.addItem(label: label, checked: self.viewOptions.edgeVisibility == visibility) {
                self.viewOptions.edgeVisibility = visibility
            } onHighlight: { highlighted, isClosing in
                if !isClosing {
                    self.setEdgeVisibilityInParts(highlighted ? visibility : initialEdgeVisibility)
                }
            }
        }

        visibility(.none, label: "None")
        visibility(.sharp, label: "Sharp")
        visibility(.all, label: "All")
    }
}
