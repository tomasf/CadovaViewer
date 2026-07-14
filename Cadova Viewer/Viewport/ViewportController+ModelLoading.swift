import Foundation
import SceneKit

extension ViewportController {
    /// (Re)builds this viewport's clone of the now-loaded model and runs the per-viewport setup
    /// that depends on it: swaps the clone into the scene, applies this viewport's geometry options
    /// and part visibility, fits the camera (first time only), sizes the grid, and gathers snap
    /// vertices. Called when the model loads and when a viewport is created by a split after the
    /// model is already loaded.
    func applyLoadedModel() {
        modelInstance.root.removeFromParentNode()
        modelInstance = ViewportModelInstance(modelData: sceneController.modelData)
        scene.rootNode.addChildNode(modelInstance.root)

        applyGeometryOptions()
        updatePartNodeVisibility(viewOptions.hiddenPartIDs)

        // Drop any cap nodes/materials from a previously-loaded model before rebuilding.
        crossSectionCapNode.childNodes.forEach { $0.removeFromParentNode() }
        crossSectionCapNodesByKey.removeAll()
        crossSectionCapMaterialsByKey.removeAll()
        // Drop the cut-away ghost too — it clones the old model's geometry; it's rebuilt on next drag.
        tearDownCrossSectionGhost()
        installCrossSectionShader()
        applyModelClipUniforms() // clip in the first frame so a reload doesn't flash the whole model
        applyCrossSection()

        if !hasSetInitialView {
            showViewPreset(.isometric, animated: false)
            hasSetInitialView = true
        }

        grid.updateBounds(geometry: modelInstance.root)
        // Shared across viewports and lazily cached on the scene controller — cheap on a split.
        snapVertices = sceneController.snapVertices
    }

    /// Applies this viewport's own geometry options (edge visibility, smooth shading) to its clone
    /// nodes. Smooth geometry is shared and built off the main thread by `SceneController`; until
    /// it's ready this falls back to flat and re-applies on the `smoothGeometryDidBuild` signal.
    func applyGeometryOptions() {
        if viewOptions.smoothShading {
            sceneController.ensureSmoothGeometryBuilt()
        }
        for container in modelInstance.sharpEdgeContainers {
            container.isHidden = viewOptions.edgeVisibility == .none
        }
        for container in modelInstance.smoothEdgeContainers {
            container.isHidden = viewOptions.edgeVisibility != .all
        }
        for variant in modelInstance.variantSwaps {
            variant.apply(smoothShading: viewOptions.smoothShading)
        }
    }
}
