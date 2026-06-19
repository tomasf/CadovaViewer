import AppKit
import Combine
import SceneKit

extension ViewportController {
    func configureScene(measurementParent: SCNNode) {
        // Assemble this viewport's own scene: shared image-based lighting, its chrome (grid +
        // measurements) under one hideable node, and an ambient fill. The model and the camera
        // headlight are added later (on load / below).
        scene.lightingEnvironment.contents = sceneController.skyboxImages
        privateRoot.name = "Viewport chrome"
        scene.rootNode.addChildNode(privateRoot)
        privateRoot.addChildNode(grid.node)
        privateRoot.addChildNode(measurementParent)
        crossSectionPlaneNode.name = "Cross-section plane"
        crossSectionPlaneNode.isHidden = true
        privateRoot.addChildNode(crossSectionPlaneNode)
        crossSectionCapNode.name = "Cross-section caps"
        privateRoot.addChildNode(crossSectionCapNode)
        privateRoot.addChildNode(crossSectionGizmo.root)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.name = "Ambient light"
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)
    }

    func configureSceneViewCallbacks() {
        sceneView.onClick = { [weak self] point in
            guard let self else { return }
            // A click off the gizmo (gizmo presses are intercepted earlier) exits cross-section edit
            // mode rather than placing a measurement.
            if selectedCrossSectionID != nil {
                selectedCrossSectionID = nil
                return
            }
            handleMeasurementClick(at: point)
        }
        sceneView.onHover = { [weak self] point in
            self?.hoverPoint = point
        }
        sceneView.onCancel = { [weak self] in
            self?.measurementController.cancelInProgress()
        }
        sceneView.beginGizmoDrag = { [weak self] point in
            self?.beginCrossSectionGizmoDrag(at: point) ?? false
        }
        sceneView.updateGizmoDrag = { [weak self] point in
            self?.updateCrossSectionGizmoDrag(at: point)
        }
        sceneView.endGizmoDrag = { [weak self] in
            self?.endCrossSectionGizmoDrag()
        }
        // Shift swaps the cross-section gizmo between plane- and world-relative. Watch modifier changes
        // app-wide (a local monitor, not the scene view's `flagsChanged`) so it works even when the
        // canvas isn't the first responder.
        modifierFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateCrossSectionOverlays()
            return event
        }
        measurementRenderer.onVisualChange = { [weak self] in
            // The redraw drives updateAtTime -> updateScreenSizes, which does the sizing.
            self?.sceneView.setNeedsRedraw()
        }
    }

    func configureOverlayScene() {
        overlayScene = OverlayScene(viewportController: self, renderer: sceneView)
        sceneView.overlaySKScene = overlayScene
        sceneView.viewportController = self
    }

    func configureSceneView() {
        sceneView.scene = scene
        sceneView.showsStatistics = false
        sceneView.backgroundColor = NSColor(white: 0.05, alpha: 1)
        // Camera navigation is fully custom (see ViewportController+CameraInteraction and
        // CustomSceneView); SceneKit's built-in controller stays off.
        sceneView.allowsCameraControl = false
        sceneView.delegate = self
    }

    func configureInitialCamera() {
        let initialCamera = SCNCamera()
        let initialCameraNode = SCNNode()
        initialCameraNode.name = "Initial camera node"
        initialCameraNode.camera = initialCamera
        scene.rootNode.addChildNode(initialCameraNode)
        sceneView.pointOfView = initialCameraNode
        self.cameraNode = initialCameraNode
    }

    func configureHeadlight() {
        // A real directional headlight on its own node (oriented to the camera in willRenderScene).
        // This viewport renders its own scene, so the light affects only this viewport.
        sceneView.autoenablesDefaultLighting = false
        cameraLight.type = .directional
        cameraLight.intensity = 800
        headlightNode.name = "Headlight"
        headlightNode.light = cameraLight
        scene.rootNode.addChildNode(headlightNode)
    }

    func bindSceneViewSignals() {
        sceneView.mouseInteractionActive.sink { [weak self] active in
            guard let self else { return }
            setNavLibSuspended(active)

            if !active {
                viewDidChange()
            }
        }.store(in: &observers)

        sceneView.mouseRotationPivot.sink { [weak self] pivot in
            guard let self else { return }
            if let pivot {
                self.overlayScene.pivotPointLocation = pivot
            }
            self.overlayScene.pivotPointVisibility = pivot != nil
        }.store(in: &observers)

        sceneView.showContextMenu.receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self else { return }
            let viewPoint = sceneView.convert(event.locationInWindow, from: nil)
            NSMenu.popUpContextMenu(contextMenu(at: viewPoint), with: event, for: sceneView)
        }.store(in: &observers)
    }

    func bindModelSignals() {
        sceneController.modelWasLoaded.sink { [weak self] in
            self?.applyLoadedModel()
        }.store(in: &observers)

        sceneController.documentGeometryChanged.sink { [weak self] in
            self?.applyDocumentOptions()
        }.store(in: &observers)
    }

    func bindViewOptions() {
        $viewOptions.sink { [weak self] viewOptions in
            guard let self else { return }
            grid.showGrid = viewOptions.showGrid
            grid.showOrigin = viewOptions.showOrigin
            updatePartNodeVisibility(viewOptions.hiddenPartIDs)
            // Persist as the default for newly opened documents. Menu toggles only mutate
            // viewOptions (+ restorable state), which isn't reapplied on a manual reopen; this
            // keeps display options like smooth shading remembered. (setViewOptions does the
            // same on the restore path.)
            Preferences().viewOptions = viewOptions
        }.store(in: &observers)
    }
}
