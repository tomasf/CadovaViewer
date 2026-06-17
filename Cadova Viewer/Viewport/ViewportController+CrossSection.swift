import SceneKit
import ViewerCore
import simd

extension ViewportController {
    /// Surface shader modifier that clips fragments past the cross-section plane. The plane is in
    /// world space `(normal.xyz, distance)`; a fragment is discarded when `dot(world, normal) > distance`.
    /// Attached to every per-viewport material so the clip applies to faces and edges alike; gated by
    /// `crossSectionEnabled` so it's inert when the feature is off.
    static let clipShaderModifier = """
    #pragma arguments
    float4 crossSectionPlane;
    float crossSectionEnabled;
    #pragma body
    if (crossSectionEnabled > 0.5) {
        float4 worldPosition = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
        if (dot(worldPosition.xyz, crossSectionPlane.xyz) > crossSectionPlane.w) {
            discard_fragment();
        }
    }
    """

    /// Attaches the clip shader modifier to this viewport's materials. Called once per loaded model
    /// (the materials are rebuilt with the model instance).
    func installCrossSectionShader() {
        for material in modelInstance.clipMaterials {
            var modifiers = material.shaderModifiers ?? [:]
            modifiers[.surface] = Self.clipShaderModifier
            material.shaderModifiers = modifiers
        }
    }

    /// Applies the current `crossSection` to this viewport's scene. Main-thread only.
    ///
    /// To keep the clip and the cap in lockstep, the clip plane isn't moved here — the kept geometry
    /// would otherwise jump ahead of the cap, which lags by one (background) slice. Instead the clip
    /// plane, locator and caps are all applied together when the slice for a given offset finishes
    /// (see `updateCrossSectionCap`). Turning the cut *off* is applied immediately, since there's no
    /// cap to wait for.
    func applyCrossSection() {
        let enabled = crossSection.enabled
        for material in modelInstance.clipMaterials {
            // Show interior back faces while a cut is active.
            material.isDoubleSided = enabled
            if !enabled {
                material.setValue(NSNumber(value: Float(0)), forKey: "crossSectionEnabled")
            }
        }

        guard enabled else {
            crossSectionCapNeedsRebuild = false
            clearCrossSectionCaps()
            updateCrossSectionPlaneNode() // hides it
            sceneView.setNeedsRedraw()
            return
        }

        // Move the locator plane live for instant feedback on where the cut will be, ahead of the
        // (slower) clip + cap which catch up when the background slice finishes.
        updateCrossSectionPlaneNode()
        sceneView.setNeedsRedraw()
        updateCrossSectionCap()
    }

    /// Rebuilds the translucent locator quad at the cut plane, sized to the model and oriented to the
    /// cut axis. Hidden when the cut is off or the user turned the plane off.
    ///
    /// Driven live from `applyCrossSection` (every slider change) for instant feedback on where the
    /// plane is — it leads the actual cut, which trails by one background slice.
    func updateCrossSectionPlaneNode() {
        let section = crossSection
        let node = crossSectionPlaneNode
        let planeOffset = section.offset

        let bounds = crossSectionModelBounds
        guard section.enabled, section.showPlane, bounds.min != bounds.max else {
            node.isHidden = true
            return
        }

        let size = bounds.max - bounds.min
        let inPlaneAxes = [0, 1, 2].filter { $0 != section.axis.index }
        let width = size[inPlaneAxes[0]] * 1.05
        let height = size[inPlaneAxes[1]] * 1.05

        // Reuse the existing plane geometry/material (only resize/move) to avoid per-tick churn.
        let plane: SCNPlane
        if let existing = node.geometry as? SCNPlane {
            plane = existing
        } else {
            plane = SCNPlane()
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(white: 0.9, alpha: 0.12)
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            material.blendMode = .alpha
            plane.firstMaterial = material
            node.geometry = plane
        }
        plane.width = CGFloat(width)
        plane.height = CGFloat(height)

        var center = (bounds.min + bounds.max) / 2
        center[section.axis.index] = planeOffset
        // The cap sits exactly on the cut plane, so nudge the locator a hair onto the kept side to
        // avoid z-fighting — it then tucks behind the cap over the model but still shows beyond its edges.
        let keptSide: Double = section.flipped ? 1 : -1
        center[section.axis.index] += keptSide * size.max() * 0.002
        node.simdPosition = SIMD3<Float>(center)

        // Orient the plane with an explicit rotation (not `simd_quatf(from:to:)`, which adds an
        // arbitrary roll about the axis and twists the plane). Map the plane's local X→`width` axis,
        // local Y→`height` axis, local Z (its normal)→cut axis. `v = n × u` keeps it right-handed.
        let n = SIMD3<Float>(section.axis.unit)
        var u = SIMD3<Float>(repeating: 0)
        u[inPlaneAxes[0]] = 1
        let v = simd_cross(n, u)
        node.simdOrientation = simd_quatf(simd_float3x3(u, v, n))
        node.isHidden = false
    }

    /// Surface shader modifier for the cap: paints the part's colour and overlays a diagonal
    /// semi-transparent black hatch (in world space) so a cut face reads as a cut, not real geometry.
    static let capHatchShaderModifier = """
    #pragma arguments
    float4 capColor;
    float3 hatchDirection;
    float hatchSpacing;
    #pragma body
    _surface.diffuse = capColor;
    float4 capWorldPosition = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float hatchCoordinate = dot(capWorldPosition.xyz, hatchDirection) / hatchSpacing;
    if (fract(hatchCoordinate) < 0.12) {
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, float3(0.0), 0.22);
    }
    """

    /// Rebuilds the per-part filled cap at the cut plane. The cut-section polygon is computed off the
    /// main thread (it scans every triangle), then the geometry is swapped in on the main thread. A
    /// generation counter drops results that a newer change has superseded.
    func updateCrossSectionCap() {
        guard crossSection.enabled else {
            crossSectionCapNeedsRebuild = false
            clearCrossSectionCaps()
            return
        }
        // Only one scan at a time; while one runs, remember that another is wanted so the drag
        // collapses to a single rebuild at the *latest* offset instead of queueing a backlog of stale
        // scans (which would lag behind the slider).
        guard !crossSectionCapInFlight else {
            crossSectionCapNeedsRebuild = true
            return
        }
        crossSectionCapInFlight = true
        crossSectionCapNeedsRebuild = false

        // The cap depends only on the axis and offset (which side is kept doesn't change the section).
        let axisNormal = SIMD3<Double>(crossSection.axis.unit)
        let offset = crossSection.offset
        // The clip plane for this same offset, applied together with the cap so they stay in sync.
        let plane = crossSection.plane()
        let clipPlaneValue = NSValue(scnVector4: SCNVector4(plane.x, plane.y, plane.z, plane.w))

        // Snapshot the inputs needed off-main: each visible part's solid and colour.
        let hidden = hiddenPartIDs
        let parts = sceneController.parts.filter { !hidden.contains($0.id) && $0.capSolid != nil }
        let inputs = parts.map { (id: $0.id, solid: $0.capSolid!, color: $0.dominantColor) }

        let bounds = crossSectionModelBounds
        let extent = bounds.max - bounds.min
        let hatchSpacing = Float(max(extent.max() / 150, 0.3))
        // A diagonal direction lying in the cut plane.
        let normal = SIMD3<Float>(crossSection.axis.unit)
        let basisReference = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let u = simd_normalize(simd_cross(basisReference, normal))
        let v = simd_cross(normal, u)
        let hatchDirection = simd_normalize(u + v)

        crossSectionCapQueue.async { [weak self] in
            let caps: [(id: ModelData.Part.ID, geometry: SCNGeometry, color: SIMD4<Float>)] = inputs.compactMap { input in
                let triangles = input.solid.capTriangles(planeNormal: axisNormal, offset: offset)
                guard !triangles.isEmpty else { return nil }
                let source = SCNGeometrySource(vertices: triangles.map { SCNVector3($0.x, $0.y, $0.z) })
                let element = SCNGeometryElement(indices: Array(UInt32(0)..<UInt32(triangles.count)), primitiveType: .triangles)
                return (input.id, SCNGeometry(sources: [source], elements: [element]), input.color ?? SIMD4(0.7, 0.7, 0.7, 1))
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.crossSectionCapInFlight = false

                // The cut may have been switched off mid-slice; `applyCrossSection` already restored
                // the geometry, so just drop this result.
                guard self.crossSection.enabled else { return }

                // Apply this result even if the slider has already moved on, so the cut updates *during*
                // the drag (one slice behind) rather than only when it stops. The clip plane and caps
                // move together so the cut surface and its fill are always for the same offset. The
                // locator plane is driven live from `applyCrossSection`, so it isn't touched here.
                for material in self.modelInstance.clipMaterials {
                    material.setValue(clipPlaneValue, forKey: "crossSectionPlane")
                    material.setValue(NSNumber(value: Float(1)), forKey: "crossSectionEnabled")
                }
                self.applyCrossSectionCaps(caps, hatchDirection: hatchDirection, hatchSpacing: hatchSpacing)
                self.sceneView.setNeedsRedraw()

                // If the slider moved while we were computing, compute once more for the latest offset.
                // Only ever one slice is in flight, so this can't pile up a backlog.
                if self.crossSectionCapNeedsRebuild {
                    self.updateCrossSectionCap()
                }
            }
        }
    }

    /// Installs freshly-computed caps onto persistent per-part nodes, reusing each part's node and
    /// material (only the geometry changes) so dragging the slider doesn't churn shaders. Parts with
    /// no cap this frame are hidden.
    private func applyCrossSectionCaps(_ caps: [(id: ModelData.Part.ID, geometry: SCNGeometry, color: SIMD4<Float>)], hatchDirection: SIMD3<Float>, hatchSpacing: Float) {
        var present: Set<ModelData.Part.ID> = []
        for cap in caps {
            present.insert(cap.id)

            let material: SCNMaterial
            if let existing = crossSectionCapMaterialsByPart[cap.id] {
                material = existing
            } else {
                material = SCNMaterial()
                material.lightingModel = .constant
                material.isDoubleSided = true
                material.shaderModifiers = [.surface: Self.capHatchShaderModifier]
                material.setValue(NSValue(scnVector4: SCNVector4(cap.color.x, cap.color.y, cap.color.z, 1)), forKey: "capColor")
                crossSectionCapMaterialsByPart[cap.id] = material
            }
            material.setValue(NSValue(scnVector3: SCNVector3(hatchDirection.x, hatchDirection.y, hatchDirection.z)), forKey: "hatchDirection")
            material.setValue(NSNumber(value: hatchSpacing), forKey: "hatchSpacing")

            cap.geometry.materials = [material]

            if let node = crossSectionCapNodesByPart[cap.id] {
                node.geometry = cap.geometry
                node.isHidden = false
            } else {
                let node = SCNNode(geometry: cap.geometry)
                node.name = "Cross-section cap"
                crossSectionCapNodesByPart[cap.id] = node
                crossSectionCapNode.addChildNode(node)
            }
        }
        // Hide caps for parts that produced none this frame (hidden, or plane outside them).
        for (id, node) in crossSectionCapNodesByPart where !present.contains(id) {
            node.isHidden = true
        }
    }

    private func clearCrossSectionCaps() {
        for (_, node) in crossSectionCapNodesByPart { node.isHidden = true }
    }

    /// The model's world-space axis-aligned bounding box (min, max) in millimetres, used for the
    /// offset slider range and to size the locator plane. Empty model → zero box.
    var crossSectionModelBounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        let root = modelInstance.root
        let (localMin, localMax) = root.boundingBox
        if localMin == localMax { return (.zero, .zero) }

        // Transform the eight local corners into world space and take their extent.
        var worldMin = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var worldMax = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for xi in [localMin.x, localMax.x] {
            for yi in [localMin.y, localMax.y] {
                for zi in [localMin.z, localMax.z] {
                    let world = root.convertPosition(SCNVector3(xi, yi, zi), to: nil)
                    let p = SIMD3<Double>(Double(world.x), Double(world.y), Double(world.z))
                    worldMin = simd_min(worldMin, p)
                    worldMax = simd_max(worldMax, p)
                }
            }
        }
        return (worldMin, worldMax)
    }
}
