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

            builder.addItem(label: "Show only \"\(part.name)\"", checked: onlyVisiblePartID == part.id, modifiers: .option, isAlternate: true) {
                self.onlyVisiblePartID = part.id
            } onHighlight: { h, _ in
                self.highlightedPartID = h ? part.id : nil
            }

            builder.addItem(label: "Slice \"\(part.name)\"", modifiers: .shift, isAlternate: true) {
                self.document?.slicePart(part)
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

        // Search all intersections only when cuts are active (so a part hit solely on its clipped-away
        // side isn't listed); otherwise the cheaper closest hit. `crossSectionHides` is false with no
        // active cuts, so the first visible hit is just the nearest.
        let searchMode: SCNHitTestSearchMode = activeCrossSections.isEmpty ? .closest : .all
        let samplePoints = hitTestSamplePoints(around: viewPoint)
        var hits: [(part: ModelData.Part, distance: Double)] = []
        for part in sceneController.parts {
            var best = Double.greatestFiniteMagnitude
            for samplePoint in samplePoints {
                let results = sceneView.hitTest(samplePoint, options: [
                    .rootNode: part.nodes.model,
                    .searchMode: searchMode.rawValue as NSNumber,
                    .ignoreHiddenNodes: false
                ])
                guard let hit = results.first(where: { !crossSectionHides($0.worldCoordinates) }) else { continue }
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
        builder.addItem(label: "Zoom In", keyEquivalent: "+") {
            self.zoomIn()
        }
        builder.addItem(label: "Zoom Out", keyEquivalent: "-") {
            self.zoomOut()
        }

        builder.addSeparator()
        builder.addItem(label: "Standard Views", submenu: buildStandardViewsMenu)
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
        builder.addItem(label: "Smooth Shading", checked: sceneController.documentOptions.smoothShading) {
            self.sceneController.documentOptions.smoothShading.toggle()
        }
        builder.addItem(label: "Show Edges", submenu: buildEdgeVisibilityMenu)

        builder.addSeparator()
        builder.addItem(label: "Cross-Sections", submenu: { submenu in
            submenu.addItem(label: "New Cross-Section", enabled: self.crossSections.count < Self.maxCrossSections,
                            keyEquivalent: "n", modifiers: [.command, .control]) {
                self.addCrossSection()
            }
            submenu.addSeparator()
            // Single toggle so one keystroke flips them all. Shows "Disable All" while any section
            // is enabled, otherwise "Enable All".
            let anyEnabled = self.crossSections.contains { $0.enabled }
            submenu.addItem(label: anyEnabled ? "Disable All" : "Enable All", enabled: !self.crossSections.isEmpty,
                            keyEquivalent: "a", modifiers: [.command, .control]) {
                self.setAllCrossSectionsEnabled(!anyEnabled)
            }
        })

        buildViewportLayoutMenu(with: builder)

        // Sits just above the system "Show/Hide Toolbar" item (the end marker is the separator right
        // before it).
        if let viewModel = documentViewModel {
            builder.addSeparator()
            let sidebarShown = viewModel.sidebarVisibility != .detailOnly
            builder.addItem(label: sidebarShown ? "Hide Sidebar" : "Show Sidebar",
                            keyEquivalent: "s", modifiers: [.command, .control]) {
                viewModel.toggleSidebar()
            }
        }
    }

    /// The "Standard Views" submenu: snap the camera to a preset orientation (with a live preview
    /// while a row is highlighted).
    private func buildStandardViewsMenu(_ builder: MenuBuilder) {
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
    }

    /// The "Viewports" submenu: split / close / focus-cycling commands for the focused viewport.
    /// Focus-cycling carries keyboard shortcuts so a SpaceMouse button can be bound to move focus
    /// between viewports.
    private func buildViewportLayoutMenu(with builder: MenuBuilder) {
        guard let viewModel = documentViewModel else { return }
        builder.addSeparator()

        let canSplitWide = sceneViewSize.width >= ViewportLayoutMetrics.minPaneWidth * 2 + ViewportLayoutMetrics.dividerThickness
        let canSplitTall = sceneViewSize.height >= ViewportLayoutMetrics.minPaneHeight * 2 + ViewportLayoutMetrics.dividerThickness

        builder.addItem(label: "Viewports", submenu: { submenu in
            submenu.addItem(label: "Split Horizontally", enabled: canSplitWide,
                            keyEquivalent: "h", modifiers: [.command, .control]) {
                viewModel.split(self.viewportID, axis: .horizontal)
            }
            submenu.addItem(label: "Split Vertically", enabled: canSplitTall,
                            keyEquivalent: "v", modifiers: [.command, .control]) {
                viewModel.split(self.viewportID, axis: .vertical)
            }
            // Always present, disabled when there's a single viewport (per the HIG).
            submenu.addItem(label: "Close Viewport", enabled: viewModel.hasMultipleViewports,
                            keyEquivalent: "w", modifiers: [.command, .control, .shift]) {
                viewModel.close(self.viewportID)
            }

            submenu.addSeparator()

            // Focus next/previous. The key equivalent is the US backtick key, whose key position is
            // the < / > (`<>|`) key on ISO layouts — so it reads as ⌘< / ⌘> there (and ⌘` on US ANSI).
            submenu.addItem(label: "Focus Next Viewport", enabled: viewModel.hasMultipleViewports,
                            keyEquivalent: "`", modifiers: [.command]) {
                viewModel.focusAdjacentViewport(forward: true)
            }
            submenu.addItem(label: "Focus Previous Viewport", enabled: viewModel.hasMultipleViewports,
                            keyEquivalent: "`", modifiers: [.command, .shift]) {
                viewModel.focusAdjacentViewport(forward: false)
            }
        })
    }

    func buildFileMenu(with builder: MenuBuilder) {
        builder.addSeparator()
        builder.addItem(label: "Show Info", keyEquivalent: "i", modifiers: .command) {
            self.showInfoCallbackSignals.send()
        }

        builder.addSeparator()
        let allParts = sceneController.parts
        let visibleParts = allParts.filter { !hiddenPartIDs.contains($0.id) }
        builder.addItem(label: "Slice", enabled: !allParts.isEmpty, keyEquivalent: "p", modifiers: .command) {
            self.document?.sliceModel(parts: allParts)
        }
        builder.addItem(label: "Slice Visible Parts", enabled: !visibleParts.isEmpty, keyEquivalent: "p", modifiers: [.command, .option], isAlternate: true) {
            self.document?.sliceModel(parts: visibleParts)
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
