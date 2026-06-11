import Cocoa
import SceneKit
import ViewerCore

extension ViewportController {
    /// Builds the right-click menu. `viewPoint` (in scene-view coordinates) is where the click
    /// happened; the parts list shows only the parts whose geometry the pick ray passes through
    /// there — every part along the ray, nearest first — rather than the whole model.
    func contextMenu(at viewPoint: CGPoint? = nil) -> NSMenu {
        let builder = MenuBuilder()
        let partsUnderCursor = viewPoint.map(partsUnderCursor(viewPoint:)) ?? []
        if sceneController.parts.count > 1 {
            if !partsUnderCursor.isEmpty {
                builder.addHeader("Part Visibility")
                buildPartsMenuItems(for: partsUnderCursor, with: builder)
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

    func buildPartsMenuItems(for parts: [ModelData.Part], with builder: MenuBuilder) {
        for part in parts {
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

    /// The parts whose geometry lies under the cursor at `viewPoint` (scene-view coordinates),
    /// ordered nearest-first — every part along the way, not just the closest. Small parts are hard
    /// to hit with a single ray, so this casts a bundle of rays over a small disk around the cursor
    /// (a screen-space "cylinder") and unions what they pass through; forgiveness measured in screen
    /// points stays constant regardless of the part's depth. Hidden parts are included (their
    /// geometry still lies under the cursor), which is why hidden nodes aren't ignored.
    func partsUnderCursor(viewPoint: CGPoint) -> [ModelData.Part] {
        guard let cameraPosition = sceneView.pointOfView?.presentation.worldPosition else { return [] }

        let samplePoints = hitTestSamplePoints(around: viewPoint)
        var hits: [(part: ModelData.Part, distance: Double)] = []
        for part in sceneController.parts {
            var best = Double.greatestFiniteMagnitude
            for samplePoint in samplePoints {
                guard let hit = sceneView.hitTest(samplePoint, options: [
                    .rootNode: part.nodes.model,
                    .searchMode: SCNHitTestSearchMode.closest.rawValue as NSNumber,
                    .ignoreHiddenNodes: false
                ]).first else { continue }
                best = min(best, hit.worldCoordinates.distance(from: cameraPosition))
            }
            if best < .greatestFiniteMagnitude {
                hits.append((part, best))
            }
        }
        return hits.sorted { $0.distance < $1.distance }.map(\.part)
    }

    /// The cursor point plus a ring of samples around it, giving the pick a small screen-space
    /// radius so small parts near (not exactly under) the cursor are still caught — but kept tight
    /// so it doesn't sweep in neighbouring parts, especially when zoomed out.
    private func hitTestSamplePoints(around point: CGPoint) -> [CGPoint] {
        let radius: CGFloat = 5 // forgiveness radius, in points
        var points = [point]
        for step in 0 ..< 8 {
            let angle = CGFloat(step) / 8 * 2 * .pi
            points.append(CGPoint(x: point.x + cos(angle) * radius, y: point.y + sin(angle) * radius))
        }
        return points
    }


    func buildViewMenu(with builder: MenuBuilder) {
        builder.addItem(label: "View", checked: measurementController.interactionMode == .view, keyEquivalent: "1", modifiers: [.command, .shift]) {
            self.measurementController.interactionMode = .view
        }
        builder.addItem(label: "Measure", checked: measurementController.interactionMode == .measure, keyEquivalent: "2", modifiers: [.command, .shift]) {
            self.measurementController.interactionMode = .measure
        }
        builder.addSeparator()

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

        buildViewportLayoutMenu(with: builder)
    }

    /// Split / close / focus-cycling commands for the focused viewport. Focus-cycling carries
    /// keyboard shortcuts so a SpaceMouse button can be bound to move focus between viewports.
    private func buildViewportLayoutMenu(with builder: MenuBuilder) {
        guard let viewModel = documentViewModel else { return }
        builder.addSeparator()

        let canSplitWide = sceneViewSize.width >= ViewportLayoutMetrics.minPaneWidth * 2 + ViewportLayoutMetrics.dividerThickness
        let canSplitTall = sceneViewSize.height >= ViewportLayoutMetrics.minPaneHeight * 2 + ViewportLayoutMetrics.dividerThickness

        builder.addItem(label: "Split Side by Side", enabled: canSplitWide) {
            viewModel.split(self.viewportID, axis: .horizontal)
        }
        builder.addItem(label: "Split Top and Bottom", enabled: canSplitTall) {
            viewModel.split(self.viewportID, axis: .vertical)
        }
        builder.addItem(label: "Close Viewport", enabled: viewModel.hasMultipleViewports) {
            viewModel.close(self.viewportID)
        }

        if viewModel.hasMultipleViewports {
            builder.addItem(label: "Focus Next Viewport", keyEquivalent: "]") {
                viewModel.focusAdjacentViewport(forward: true)
            }
            builder.addItem(label: "Focus Previous Viewport", keyEquivalent: "[") {
                viewModel.focusAdjacentViewport(forward: false)
            }
        }
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

        builder.addItem(label: "Smooth Shading", checked: sceneController.documentOptions.smoothShading) {
            self.sceneController.documentOptions.smoothShading.toggle()
        }
    }

    func buildEdgeVisibilityMenu(_ menuBuilder: MenuBuilder) {
        // Edge visibility is document-wide (it acts on the shared geometry), so it lives on the
        // SceneController rather than this viewport's options.
        let initialEdgeVisibility = sceneController.documentOptions.edgeVisibility

        func visibility(_ visibility: DocumentViewOptions.EdgeVisibility, label: String) {
            menuBuilder.addItem(label: label, checked: sceneController.documentOptions.edgeVisibility == visibility) {
                self.sceneController.documentOptions.edgeVisibility = visibility
            } onHighlight: { highlighted, isClosing in
                if !isClosing {
                    // Preview by setting the document-wide option (every viewport reflects it);
                    // restored to the initial value when the highlight leaves without a click.
                    self.sceneController.documentOptions.edgeVisibility = highlighted ? visibility : initialEdgeVisibility
                }
            }
        }

        visibility(.none, label: "None")
        visibility(.sharp, label: "Sharp")
        visibility(.all, label: "All")
    }
}
