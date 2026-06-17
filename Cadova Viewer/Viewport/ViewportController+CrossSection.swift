import SceneKit
import ViewerCore
import simd

/// Identifies one cap mesh: a (cross-section, part) pair. Caps are kept per pair so a drag only swaps
/// the affected geometry.
struct CrossSectionCapKey: Hashable {
    let section: UUID
    let part: ModelData.Part.ID
}

/// An in-progress gizmo drag: the grabbed handle, the section as it was when the drag began, the grab
/// reference value (axis parameter for translate, angle for rotate), and the pivot — the gizmo's
/// on-plane anchor at drag start, around which the drag operates (so it tracks where you were looking).
struct CrossSectionDragState {
    let handle: CrossSectionGizmo.Handle
    let startSection: CrossSection
    let grab: Double
    let pivot: SIMD3<Double>
}

extension ViewportController {
    /// Up to this many simultaneous cutting planes (the clip uniform packs planes into two `float4x4`).
    static let maxCrossSections = 8

    /// Surface shader modifier clipping fragments past **any** active plane. Planes are packed into two
    /// `float4x4` uniforms (columns 0–3 in A, 4–7 in B); `crossSectionSkip` lets a cap skip its own
    /// plane. Attached to every per-viewport model material.
    static let clipShaderModifier = """
    #pragma arguments
    float4x4 crossSectionPlanesA;
    float4x4 crossSectionPlanesB;
    float crossSectionCount;
    float crossSectionSkip;
    #pragma body
    int csCount = int(round(crossSectionCount));
    if (csCount > 0) {
        int csSkip = int(round(crossSectionSkip));
        float3 csWorld = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
        for (int i = 0; i < csCount; i++) {
            if (i == csSkip) continue;
            float4 csPlane = (i < 4) ? crossSectionPlanesA[i] : crossSectionPlanesB[i - 4];
            if (dot(csWorld, csPlane.xyz) > csPlane.w) { discard_fragment(); }
        }
    }
    """

    /// Cap surface modifier: the same N-plane clip (skipping its own plane, so a cap is trimmed by the
    /// *other* cuts) plus the part colour and a diagonal hatch marking it as a cut face.
    static let capShaderModifier = """
    #pragma arguments
    float4x4 crossSectionPlanesA;
    float4x4 crossSectionPlanesB;
    float crossSectionCount;
    float crossSectionSkip;
    float4 capColor;
    float4 capStripeColor;
    float3 hatchDirection;
    float hatchSpacing;
    #pragma body
    float3 csWorld = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    int csCount = int(round(crossSectionCount));
    int csSkip = int(round(crossSectionSkip));
    for (int i = 0; i < csCount; i++) {
        if (i == csSkip) continue;
        float4 csPlane = (i < 4) ? crossSectionPlanesA[i] : crossSectionPlanesB[i - 4];
        if (dot(csWorld, csPlane.xyz) > csPlane.w) { discard_fragment(); }
    }
    _surface.diffuse = capColor;
    float hatchCoordinate = dot(csWorld, hatchDirection) / hatchSpacing;
    if (fract(hatchCoordinate) < 0.5) {
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, capStripeColor.rgb, 0.45);
    }
    """

    /// Attaches the clip modifier to this viewport's model materials. Called once per loaded model.
    func installCrossSectionShader() {
        for material in modelInstance.clipMaterials {
            var modifiers = material.shaderModifiers ?? [:]
            modifiers[.surface] = Self.clipShaderModifier
            material.shaderModifiers = modifiers
        }
    }

    // MARK: - Apply

    /// Applies the current cross-sections. The locator plane + gizmo update live here; the clip planes
    /// and caps are applied together when the (background) cap slice finishes, so the cut surface and
    /// its fill stay in sync. Removing all cuts restores the geometry immediately.
    /// The cross-sections whose cut is currently applied (disabled ones still exist but don't clip).
    var activeCrossSections: [CrossSection] { crossSections.filter { $0.enabled } }

    func applyCrossSection() {
        // Overlays follow selection/hover regardless of enabled state, so a disabled section can still
        // be edited and previewed.
        updateCrossSectionOverlays()

        guard !activeCrossSections.isEmpty else {
            let packed = packedClipPlanes([])
            for material in modelInstance.clipMaterials {
                setClipUniforms(on: material, packed: packed, skip: -1)
                material.isDoubleSided = false
            }
            crossSectionCapNeedsRebuild = false
            clearCrossSectionCaps()
            sceneView.setNeedsRedraw()
            return
        }
        updateCrossSectionCap()
    }

    /// Pushes the current clip planes to the model materials immediately (no async cap wait). Used on
    /// model (re)load so the geometry is clipped in the first rendered frame — otherwise the whole
    /// model flashes uncut until the background cap slice finishes and applies the uniforms.
    func applyModelClipUniforms() {
        let packed = packedClipPlanes(activeCrossSections)
        for material in modelInstance.clipMaterials {
            setClipUniforms(on: material, packed: packed, skip: -1)
            material.isDoubleSided = packed.count > 0
        }
    }

    /// Shows the locator plane for the selected-or-hovered section and the gizmo for the selected one.
    func updateCrossSectionOverlays() {
        if let id = selectedCrossSectionID, let section = crossSections.first(where: { $0.id == id }) {
            // While dragging, hold the gizmo on the section's current point; otherwise anchor it at the
            // view centre (the per-frame `followView` keeps it there as the camera moves).
            let anchor = crossSectionDrag != nil ? section.origin : crossSectionGizmoAnchor(for: section)
            crossSectionGizmo.update(for: section, anchor: anchor)
        } else {
            crossSectionGizmo.hide()
        }

        if let id = selectedCrossSectionID ?? hoveredCrossSectionID,
           let section = crossSections.first(where: { $0.id == id }) {
            updateCrossSectionPlaneNode(for: section)
        } else {
            crossSectionPlaneNode.isHidden = true
        }
        sceneView.setNeedsRedraw()
    }

    /// Draws the translucent locator quad for `section` (a square covering the model, oriented to the
    /// plane), nudged onto the kept side to avoid z-fighting with the cap.
    func updateCrossSectionPlaneNode(for section: CrossSection) {
        let node = crossSectionPlaneNode
        let bounds = crossSectionModelBounds
        guard bounds.min != bounds.max else { node.isHidden = true; return }

        let diagonal = simd_length(bounds.max - bounds.min)
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
        plane.width = CGFloat(diagonal)
        plane.height = CGFloat(diagonal)

        let normal = SIMD3<Float>(section.normal)
        // Kept side is -normal; nudge slightly that way so the cap (exactly on the plane) wins.
        let center = SIMD3<Float>(section.origin) - normal * Float(diagonal) * 0.001
        node.simdPosition = center
        // Orient straight from the section's quaternion (a centered square doesn't care about ±normal),
        // which avoids the NaN `simd_quatf(from:to:)` produces for an exactly-antiparallel normal.
        let q = section.orientation
        node.simdOrientation = simd_quatf(vector: SIMD4<Float>(Float(q.vector.x), Float(q.vector.y), Float(q.vector.z), Float(q.vector.w)))
        node.isHidden = false
    }

    // MARK: - Caps

    /// Rebuilds caps for every section/part off the main thread, then applies clip planes + caps
    /// together on the main thread. One slice in flight at a time with a trailing rebuild (no backlog).
    func updateCrossSectionCap() {
        guard !activeCrossSections.isEmpty else {
            crossSectionCapNeedsRebuild = false
            clearCrossSectionCaps()
            return
        }
        guard !crossSectionCapInFlight else {
            crossSectionCapNeedsRebuild = true
            return
        }
        crossSectionCapInFlight = true
        crossSectionCapNeedsRebuild = false

        let sections = Array(activeCrossSections.prefix(Self.maxCrossSections))
        let packed = packedClipPlanes(sections)
        let bounds = crossSectionModelBounds
        let hatchSpacing = Float(max((bounds.max - bounds.min).max() / 90, 0.3))

        struct SectionJob { let id: UUID; let index: Int; let normal: SIMD3<Double>; let offset: Double; let hatch: SIMD3<Float>; let stripeColor: SIMD4<Float> }
        let jobs = sections.enumerated().map { index, section in
            SectionJob(id: section.id, index: index, normal: section.normal, offset: section.plane().w,
                       hatch: hatchDirection(for: SIMD3<Float>(section.normal)),
                       stripeColor: ColorPalette.linearComponents(forIndex: section.colorIndex))
        }
        let hidden = hiddenPartIDs
        let parts = sceneController.parts.filter { !hidden.contains($0.id) && $0.capSolid != nil }
        let partInputs = parts.map { (id: $0.id, solid: $0.capSolid!, color: $0.dominantColor) }

        crossSectionCapQueue.async { [weak self] in
            var results: [(key: CrossSectionCapKey, sectionIndex: Int, geometry: SCNGeometry, color: SIMD4<Float>, stripeColor: SIMD4<Float>, hatch: SIMD3<Float>)] = []
            for job in jobs {
                for part in partInputs {
                    let triangles = part.solid.capTriangles(planeNormal: job.normal, offset: job.offset)
                    guard !triangles.isEmpty else { continue }
                    let source = SCNGeometrySource(vertices: triangles.map { SCNVector3($0.x, $0.y, $0.z) })
                    let element = SCNGeometryElement(indices: Array(UInt32(0)..<UInt32(triangles.count)), primitiveType: .triangles)
                    results.append((CrossSectionCapKey(section: job.id, part: part.id), job.index,
                                    SCNGeometry(sources: [source], elements: [element]),
                                    part.color ?? SIMD4(0.7, 0.7, 0.7, 1), job.stripeColor, job.hatch))
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.crossSectionCapInFlight = false
                guard !self.activeCrossSections.isEmpty else { self.clearCrossSectionCaps(); return }

                for material in self.modelInstance.clipMaterials {
                    self.setClipUniforms(on: material, packed: packed, skip: -1)
                    material.isDoubleSided = packed.count > 0
                }
                self.applyCrossSectionCaps(results, packed: packed, hatchSpacing: hatchSpacing)
                self.sceneView.setNeedsRedraw()

                if self.crossSectionCapNeedsRebuild { self.updateCrossSectionCap() }
            }
        }
    }

    /// Installs computed caps onto persistent per-(section,part) nodes, reusing each node + material
    /// (only the geometry changes). Each cap material clips by the *other* planes (skip = its index).
    private func applyCrossSectionCaps(
        _ caps: [(key: CrossSectionCapKey, sectionIndex: Int, geometry: SCNGeometry, color: SIMD4<Float>, stripeColor: SIMD4<Float>, hatch: SIMD3<Float>)],
        packed: PackedClipPlanes, hatchSpacing: Float
    ) {
        var present: Set<CrossSectionCapKey> = []
        for cap in caps {
            present.insert(cap.key)

            let material: SCNMaterial
            if let existing = crossSectionCapMaterialsByKey[cap.key] {
                material = existing
            } else {
                material = SCNMaterial()
                material.lightingModel = .constant
                material.isDoubleSided = true
                material.shaderModifiers = [.surface: Self.capShaderModifier]
                material.setValue(NSValue(scnVector4: SCNVector4(cap.color.x, cap.color.y, cap.color.z, 1)), forKey: "capColor")
                material.setValue(NSValue(scnVector4: SCNVector4(cap.stripeColor.x, cap.stripeColor.y, cap.stripeColor.z, 1)), forKey: "capStripeColor")
                crossSectionCapMaterialsByKey[cap.key] = material
            }
            setClipUniforms(on: material, packed: packed, skip: cap.sectionIndex)
            material.setValue(NSValue(scnVector3: SCNVector3(cap.hatch.x, cap.hatch.y, cap.hatch.z)), forKey: "hatchDirection")
            material.setValue(NSNumber(value: hatchSpacing), forKey: "hatchSpacing")
            cap.geometry.materials = [material]

            if let node = crossSectionCapNodesByKey[cap.key] {
                node.geometry = cap.geometry
                node.isHidden = false
            } else {
                let node = SCNNode(geometry: cap.geometry)
                node.name = "Cross-section cap"
                crossSectionCapNodesByKey[cap.key] = node
                crossSectionCapNode.addChildNode(node)
            }
        }
        for (key, node) in crossSectionCapNodesByKey where !present.contains(key) {
            node.isHidden = true
        }
    }

    func clearCrossSectionCaps() {
        for (_, node) in crossSectionCapNodesByKey { node.isHidden = true }
    }

    // MARK: - Clip uniform packing

    /// Two `float4x4` columns of planes plus the active count, ready to push to a material uniform.
    struct PackedClipPlanes {
        let a: SCNMatrix4
        let b: SCNMatrix4
        let count: Int
    }

    func packedClipPlanes(_ sections: [CrossSection]) -> PackedClipPlanes {
        let planes = sections.prefix(Self.maxCrossSections).map { section -> SIMD4<Float> in
            let p = section.plane()
            return SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), Float(p.w))
        }
        func column(_ i: Int) -> SIMD4<Float> { i < planes.count ? planes[i] : .zero }
        let a = simd_float4x4(column(0), column(1), column(2), column(3))
        let b = simd_float4x4(column(4), column(5), column(6), column(7))
        return PackedClipPlanes(a: SCNMatrix4(a), b: SCNMatrix4(b), count: planes.count)
    }

    func setClipUniforms(on material: SCNMaterial, packed: PackedClipPlanes, skip: Int) {
        material.setValue(NSValue(scnMatrix4: packed.a), forKey: "crossSectionPlanesA")
        material.setValue(NSValue(scnMatrix4: packed.b), forKey: "crossSectionPlanesB")
        material.setValue(NSNumber(value: Float(packed.count)), forKey: "crossSectionCount")
        material.setValue(NSNumber(value: Float(skip)), forKey: "crossSectionSkip")
    }

    /// A diagonal direction lying in the plane with the given normal (for the cap hatch).
    private func hatchDirection(for normal: SIMD3<Float>) -> SIMD3<Float> {
        let reference = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let u = simd_normalize(simd_cross(reference, normal))
        let v = simd_cross(normal, u)
        return simd_normalize(u + v)
    }

    // MARK: - Mutators (called from the UI) — all undoable via the interaction undo manager

    /// Adds a new cross-section (flat along Z through the model centre), selects it, and shows it.
    func addCrossSection() {
        guard crossSections.count < Self.maxCrossSections else { return }
        let bounds = crossSectionModelBounds
        let center = (bounds.min + bounds.max) / 2
        let section = CrossSection.axisAligned(.z, origin: center, colorIndex: nextCrossSectionColorIndex)
        nextCrossSectionColorIndex += 1
        updateCrossSections(crossSections + [section], actionName: "Add Cross-Section")
        selectedCrossSectionID = section.id
    }

    func deleteCrossSection(_ id: UUID) {
        guard crossSections.contains(where: { $0.id == id }) else { return }
        for (key, node) in crossSectionCapNodesByKey where key.section == id {
            node.removeFromParentNode()
            crossSectionCapNodesByKey[key] = nil
            crossSectionCapMaterialsByKey[key] = nil
        }
        updateCrossSections(crossSections.filter { $0.id != id }, actionName: "Delete Cross-Section")
    }

    func flipSelectedCrossSection() {
        mutateSelectedCrossSection(actionName: "Flip Cross-Section") { $0.flip() }
    }

    func setCrossSectionEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = crossSections.firstIndex(where: { $0.id == id }), crossSections[index].enabled != enabled else { return }
        var sections = crossSections
        sections[index].enabled = enabled
        updateCrossSections(sections, actionName: enabled ? "Show Cross-Section" : "Hide Cross-Section")
    }

    /// Activates or deactivates every cross-section at once (single undo step).
    func setAllCrossSectionsEnabled(_ enabled: Bool) {
        guard crossSections.contains(where: { $0.enabled != enabled }) else { return }
        var sections = crossSections
        for index in sections.indices { sections[index].enabled = enabled }
        updateCrossSections(sections, actionName: enabled ? "Show All Cross-Sections" : "Hide All Cross-Sections")
    }

    func alignSelectedCrossSection(to axis: CrossSection.Axis) {
        mutateSelectedCrossSection(actionName: "Align Cross-Section to \(axis.displayName)") {
            $0.orientation = CrossSection.orientation(for: axis)
        }
    }

    private func mutateSelectedCrossSection(actionName: String, _ transform: (inout CrossSection) -> Void) {
        guard let id = selectedCrossSectionID, let index = crossSections.firstIndex(where: { $0.id == id }) else { return }
        var sections = crossSections
        transform(&sections[index])
        updateCrossSections(sections, actionName: actionName)
    }

    // MARK: - Undo

    /// Replaces the cross-sections and registers a self-inverting undo so the Edit-menu Undo/Redo
    /// (⌘Z/⌘⇧Z, on the shared interaction undo manager) step through cross-section changes.
    func updateCrossSections(_ new: [CrossSection], actionName: String) {
        guard crossSections != new else { return }
        registerCrossSectionUndo(restoring: crossSections, actionName: actionName)
        crossSections = new
    }

    /// Registers an undo restoring `old` without changing the current state — for when the live state
    /// has already been mutated (e.g. throughout a gizmo drag, so the whole drag is one undo step).
    func registerCrossSectionUndo(restoring old: [CrossSection], actionName: String) {
        let undoManager = document?.interactionUndoManager
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.updateCrossSections(old, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// The model's world-space axis-aligned bounding box (min, max) in millimetres.
    var crossSectionModelBounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        let root = modelInstance.root
        let (localMin, localMax) = root.boundingBox
        if localMin == localMax { return (.zero, .zero) }

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
