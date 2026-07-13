import SceneKit
import ViewerCore
import AppKit
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
    /// The gizmo space the drag began in (plane- or world-relative), fixed for the whole drag.
    let space: CrossSectionGizmo.Space
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

    /// The inverse of `clipShaderModifier`, for the translucent cut-away ghost. Two modes:
    /// - **union** (`ghostMode` 0, used while dragging): keep a fragment removed by **any** active
    ///   plane — the whole cut-away half.
    /// - **difference** (`ghostMode` 1, used when a single cut is enabled/added): keep only the material
    ///   that cut *newly* removes — past `ghostNewPlane` yet still on the kept side of every **other**
    ///   active plane (so it was visible before). `crossSectionPlanesA/B` hold those other planes.
    /// The faint look comes from the ghost material, not this shader.
    static let ghostClipShaderModifier = """
    #pragma arguments
    float4x4 crossSectionPlanesA;
    float4x4 crossSectionPlanesB;
    float crossSectionCount;
    float ghostMode;
    float4 ghostNewPlane;
    #pragma body
    int csCount = int(round(crossSectionCount));
    float3 csWorld = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    if (ghostMode < 0.5) {
        if (csCount == 0) { discard_fragment(); }
        bool removedByAny = false;
        for (int i = 0; i < csCount; i++) {
            float4 csPlane = (i < 4) ? crossSectionPlanesA[i] : crossSectionPlanesB[i - 4];
            if (dot(csWorld, csPlane.xyz) > csPlane.w) { removedByAny = true; }
        }
        if (!removedByAny) { discard_fragment(); }
    } else {
        if (dot(csWorld, ghostNewPlane.xyz) <= ghostNewPlane.w) { discard_fragment(); } // not removed by the new cut
        for (int i = 0; i < csCount; i++) {
            float4 csPlane = (i < 4) ? crossSectionPlanesA[i] : crossSectionPlanesB[i - 4];
            if (dot(csWorld, csPlane.xyz) > csPlane.w) { discard_fragment(); } // already removed before → not new
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
    float hatchStrength;
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
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, capStripeColor.rgb, hatchStrength);
    }
    """

    /// Surface modifier for the translucent locator plane: draws a world-anchored diagonal hatch so the
    /// plane's orientation reads clearly (a flat gray fill gives no parallax cue, especially zoomed in)
    /// and so it echoes the cut-cap hatch — the same direction and solid alternating bands. `hatchAxis`
    /// is the in-plane direction the stripe spacing runs along (world space); bands repeat every
    /// `hatchSpacing` mm, with a ~1px softened edge (via `fwidth`) so they don't shimmer at any zoom.
    static let planeGridShaderModifier = """
    #pragma arguments
    float3 hatchAxis;
    float hatchSpacing;
    float4 hatchColor;
    #pragma body
    float3 phWorld = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float c = dot(phWorld, hatchAxis) / hatchSpacing;
    float f = fract(c);
    float d = fwidth(c);
    float band = 1.0 - smoothstep(0.5 - d, 0.5 + d, f); // solid stripe over the first half of each period
    _surface.diffuse = mix(_surface.diffuse, hatchColor, band * hatchColor.a);
    """

    /// Opacities for the translucent ghosts (the cut-away ghost shown while editing and the per-part
    /// hover ghost) — the faint fill and the slightly bolder edge lines. Shared so both stay in sync.
    static let ghostFillOpacity: CGFloat = 0.10
    static let ghostEdgeOpacity: CGFloat = 0.4

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

    /// The sections actually *drawn* as cuts: the enabled ones plus a hover-previewed disabled section
    /// (`crossSectionPreviewID`). Only the rendering paths (clip uniforms + caps) use this — picking and
    /// measurement stay on the real `activeCrossSections`, so a transient preview doesn't affect them.
    var renderedCrossSections: [CrossSection] {
        guard let previewID = crossSectionPreviewID,
              let preview = crossSections.first(where: { $0.id == previewID }), !preview.enabled
        else { return activeCrossSections }
        return activeCrossSections + [preview]
    }

    func applyCrossSection() {
        // Overlays follow selection/hover regardless of enabled state, so a disabled section can still
        // be edited and previewed.
        updateCrossSectionOverlays()

        guard !renderedCrossSections.isEmpty else {
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
        let packed = packedClipPlanes(renderedCrossSections)
        for material in modelInstance.clipMaterials {
            setClipUniforms(on: material, packed: packed, skip: -1)
            material.isDoubleSided = packed.count > 0
        }
    }

    /// Shows the locator plane for the selected-or-hovered section and the gizmo for the selected one —
    /// but only while that section is enabled (a disabled cut can't be manipulated, so its gizmo is
    /// hidden even in edit mode; the locator plane still shows where the plane sits).
    func updateCrossSectionOverlays() {
        if let id = selectedCrossSectionID, let section = crossSections.first(where: { $0.id == id }), section.enabled {
            // While dragging, keep the gizmo fixed at the grab pivot and in the drag's space; otherwise
            // anchor it at the view centre (the per-frame `followView` keeps it there as the camera
            // moves) and let Shift pick world vs. plane space live.
            let anchor = crossSectionDrag?.pivot ?? crossSectionGizmoAnchor(for: section)
            let space = crossSectionDrag?.space ?? crossSectionGizmoSpaceForModifiers
            crossSectionGizmo.update(for: section, anchor: anchor, space: space)
            crossSectionGizmo.setInteractive(true)
        } else {
            crossSectionGizmo.hide()
        }

        if let id = selectedCrossSectionID,
           let section = crossSections.first(where: { $0.id == id }) {
            updateCrossSectionPlaneNode(for: section)
        } else {
            crossSectionPlaneNode.isHidden = true
        }
        // Hide the floor grid whenever the plane locator is on screen — the two grids overlapping
        // looks messy. Independent of the user's Show Grid setting, which is restored on hide.
        grid.suppressedForCrossSection = !crossSectionPlaneNode.isHidden
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
            material.diffuse.contents = NSColor(white: 0.9, alpha: 0.05)
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            material.blendMode = .alpha
            material.shaderModifiers = [.surface: Self.planeGridShaderModifier]
            material.setValue(NSValue(scnVector4: SCNVector4(1, 1, 1, 0.32)), forKey: "hatchColor")
            plane.firstMaterial = material
            node.geometry = plane
        }
        plane.width = CGFloat(diagonal)
        plane.height = CGFloat(diagonal)

        // Diagonal hatch in the plane, matching the cut-cap hatch direction and density. Spacing uses
        // the same basis as the cap (`updateCrossSectionCap`): the model's max extent / 90, not the
        // diagonal (which is longer and would make the locator bands wider than the cap's).
        let hatchAxis = hatchDirection(for: SIMD3<Float>(section.normal))
        let hatchSpacing = max(Double((bounds.max - bounds.min).max()) / 90, 0.3)
        plane.firstMaterial?.setValue(NSValue(scnVector3: SCNVector3(hatchAxis.x, hatchAxis.y, hatchAxis.z)), forKey: "hatchAxis")
        plane.firstMaterial?.setValue(NSNumber(value: hatchSpacing), forKey: "hatchSpacing")

        let normal = section.normal
        let normalFloat = SIMD3<Float>(normal)

        let modelCenter = (bounds.min + bounds.max) / 2
        let planeDistance = simd_dot(normal, section.origin)
        var anchorPoint = modelCenter + normal * (planeDistance - simd_dot(modelCenter, normal))

        // While translating, slide the locator by the drag's *in-plane* displacement so it visibly
        // follows the gizmo arrow — including world-axis drags whose in-plane component leaves the cut
        // unchanged. The perpendicular part is already in `planeDistance`; the in-plane part is zero at
        // drag start (no jump) and snaps back when the drag ends.
        if let drag = crossSectionDrag, case .translate = drag.handle {
            // Measure from `drag.pivot` (the on-plane grab anchor), since the drag sets
            // `origin = pivot + axis·Δ` — so this is zero at the start. `pivot` lies on the plane, so
            // its perpendicular offset already matches `planeDistance`; only the in-plane part remains.
            let displacement = section.origin - drag.pivot
            anchorPoint += displacement - normal * simd_dot(normal, displacement)
        }
        // Kept side is -normal; nudge slightly that way so the cap (exactly on the plane) wins.
        let center = SIMD3<Float>(anchorPoint) - normalFloat * Float(diagonal) * 0.001
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
        guard !renderedCrossSections.isEmpty else {
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

        let sections = Array(renderedCrossSections.prefix(Self.maxCrossSections))
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
                guard !self.renderedCrossSections.isEmpty else { self.clearCrossSectionCaps(); return }

                for material in self.modelInstance.clipMaterials {
                    self.setClipUniforms(on: material, packed: packed, skip: -1)
                    material.isDoubleSided = packed.count > 0
                }
                // Only a drag needs the ghost re-synced to moving planes (union mode); a static flash
                // (enable/add difference mode) must keep the uniforms it was shown with.
                if self.crossSectionGhostVisible, self.crossSectionDrag != nil {
                    self.setGhostClipUniforms(packed: packed)
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
            material.setValue(NSNumber(value: hatchStrength(forSection: cap.key.section)), forKey: "hatchStrength")
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

    // MARK: - Cut-away ghost (shown while dragging a gizmo handle)

    /// Hovering a *disabled* section's button previews enabling it: the model is clipped + capped as if
    /// that section were active, and the material it would *newly* remove (vs the enabled cuts) is shown
    /// as a persistent ghost. Hovering anything else (or an enabled section) tears the preview down.
    /// Skipped during a gizmo drag (the drag owns the ghost and the cut state).
    func updateCrossSectionHoverPreview() {
        guard crossSectionDrag == nil else { return }
        let hovered = hoveredCrossSectionID.flatMap { id in crossSections.first { $0.id == id } }
        let preview = (hovered?.enabled == false) ? hovered : nil

        if preview?.id != crossSectionPreviewID {
            crossSectionPreviewID = preview?.id
            applyModelClipUniforms() // clip immediately so the previewed region pops cleanly to a cut
            applyCrossSection()      // rebuild caps + overlays for the new rendered set
        }
        if let preview {
            showCrossSectionGhost(difference: preview)
        } else {
            // Snap off (no fade): the model reverts to its real cut at once, so a lingering ghost would
            // sit over already-solid material.
            crossSectionGhostFadeTimer?.invalidate()
            crossSectionGhostFadeTimer = nil
            crossSectionGhostNode?.isHidden = true
            sceneView.setNeedsRedraw()
        }
    }

    /// Reveals the cut-away as a faint ghost (fully opaque, immediately). Builds the ghost on first use
    /// and excludes hidden parts. Cancels any in-flight fade so re-showing snaps back to full opacity.
    ///
    /// With `difference` nil it shows the **whole** cut-away (union of every active cut — used while
    /// dragging). With `difference` set to a section it shows only what *that* cut newly removes (the
    /// material still kept by every other active cut) — used when a single cut is enabled or added.
    func showCrossSectionGhost(difference: CrossSection? = nil) {
        if crossSectionGhostNode == nil { buildCrossSectionGhost() }
        crossSectionGhostFadeTimer?.invalidate()
        crossSectionGhostFadeTimer = nil
        if let difference {
            let others = activeCrossSections.filter { $0.id != difference.id }
            let p = difference.plane()
            setGhostUniforms(planes: packedClipPlanes(others),
                             newPlane: SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), Float(p.w)))
        } else {
            setGhostUniforms(planes: packedClipPlanes(activeCrossSections), newPlane: nil)
        }
        for (id, node) in crossSectionGhostFillNodes {
            node.isHidden = hiddenPartIDs.contains(id)
        }
        crossSectionGhostNode?.opacity = 1
        crossSectionGhostNode?.isHidden = false
        sceneView.setNeedsRedraw()
    }

    /// Fades the ghost out (used on drag end) rather than snapping it off.
    func hideCrossSectionGhost() {
        fadeOutCrossSectionGhost(afterHold: 0, fadeDuration: 0.25)
    }

    /// Briefly flashes the ghost then fades it — for one-shot changes that aren't a drag, so the user
    /// gets a momentary preview. `difference` scopes it to one cut's newly-removed material (enable /
    /// add); nil shows the whole cut-away (flip / align).
    func flashCrossSectionGhost(difference: CrossSection? = nil) {
        guard !activeCrossSections.isEmpty else { return } // nothing to reveal
        showCrossSectionGhost(difference: difference)
        fadeOutCrossSectionGhost(afterHold: 0.1, fadeDuration: 0.25)
    }

    /// Animates the ghost's opacity to zero after an optional hold, then hides it. Self-stepping on a
    /// timer (the scene renders on demand) so it doesn't disturb the shared `rendersContinuously` used
    /// by the camera glide / SpaceMouse.
    private func fadeOutCrossSectionGhost(afterHold hold: TimeInterval, fadeDuration: TimeInterval) {
        guard let node = crossSectionGhostNode, !node.isHidden else { return }
        crossSectionGhostFadeTimer?.invalidate()
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, let node = crossSectionGhostNode else { timer.invalidate(); return }
            let t = Date().timeIntervalSince(start) - hold
            if t <= 0 {
                node.opacity = 1
            } else if t >= fadeDuration {
                node.isHidden = true
                node.opacity = 1
                timer.invalidate()
                crossSectionGhostFadeTimer = nil
            } else {
                node.opacity = CGFloat(1 - t / fadeDuration)
            }
            sceneView.setNeedsRedraw()
        }
        RunLoop.main.add(timer, forMode: .common) // keep fading across tracking run-loop modes
        crossSectionGhostFadeTimer = timer
    }

    /// Pushes the active clip planes to the ghost materials so the revealed cut-away tracks the plane
    /// live as it's dragged (union mode). Used by the drag's live-update hooks.
    func setGhostClipUniforms(packed: PackedClipPlanes) {
        setGhostUniforms(planes: packed, newPlane: nil)
    }

    /// Sets the ghost's clip uniforms on all the gizmo-drag ghost materials. `newPlane` nil selects
    /// union mode (whole cut-away); a value selects difference mode, where `planes` are the *other*
    /// active cuts and `newPlane` is the cut whose newly-removed material is shown.
    private func setGhostUniforms(planes: PackedClipPlanes, newPlane: SIMD4<Float>?) {
        for material in crossSectionGhostMaterials {
            setGhostUniforms(on: material, planes: planes, newPlane: newPlane)
        }
    }

    /// Sets the inverted-clip ghost uniforms on a single material — shared by the gizmo-drag ghost and
    /// the per-part hover ghost (`makeHighlightGhost`). `newPlane` nil = union mode.
    func setGhostUniforms(on material: SCNMaterial, planes: PackedClipPlanes, newPlane: SIMD4<Float>?) {
        let plane = newPlane ?? SIMD4<Float>(0, 0, 0, 0)
        material.setValue(NSValue(scnMatrix4: planes.a), forKey: "crossSectionPlanesA")
        material.setValue(NSValue(scnMatrix4: planes.b), forKey: "crossSectionPlanesB")
        material.setValue(NSNumber(value: Float(planes.count)), forKey: "crossSectionCount")
        material.setValue(NSNumber(value: newPlane == nil ? Float(0) : Float(1)), forKey: "ghostMode")
        material.setValue(NSValue(scnVector4: SCNVector4(plane.x, plane.y, plane.z, plane.w)), forKey: "ghostNewPlane")
    }

    /// Drops the ghost so a reloaded model rebuilds a fresh one (it clones model geometry).
    func tearDownCrossSectionGhost() {
        crossSectionGhostFadeTimer?.invalidate()
        crossSectionGhostFadeTimer = nil
        crossSectionGhostNode?.removeFromParentNode()
        crossSectionGhostNode = nil
        crossSectionGhostFillNodes.removeAll()
        crossSectionGhostMaterials.removeAll()
    }

    /// Builds the per-part translucent ghost (hidden, under `privateRoot`). Mirrors the hidden-part
    /// hover ghost (`makeHighlightGhost`): a non-occluding faint fill plus light edges, with geometry
    /// rebuilt via `SCNGeometry(sources:elements:)` so it shares the model's vertex buffers but carries
    /// its own materials. Those materials carry the inverted-clip shader, so only the cut-away side draws.
    private func buildCrossSectionGhost() {
        tearDownCrossSectionGhost()

        let root = SCNNode()
        root.name = "Cross-section cut-away ghost"
        root.renderingOrder = 100
        root.isHidden = true

        let fillMaterial = SCNMaterial()
        fillMaterial.lightingModel = .constant
        fillMaterial.diffuse.contents = NSColor.white.withAlphaComponent(Self.ghostFillOpacity)
        fillMaterial.transparencyMode = .singleLayer
        fillMaterial.writesToDepthBuffer = false
        fillMaterial.isDoubleSided = true
        fillMaterial.shaderModifiers = [.surface: Self.ghostClipShaderModifier]

        var materials = [fillMaterial]

        let edgeVisibility = viewOptions.edgeVisibility
        let edgeMaterial: SCNMaterial? = edgeVisibility == .none ? nil : {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.white.withAlphaComponent(Self.ghostEdgeOpacity)
            material.writesToDepthBuffer = false
            material.shaderModifiers = [.surface: Self.ghostClipShaderModifier]
            materials.append(material)
            return material
        }()

        for part in sceneController.parts {
            let container = SCNNode()

            let fill = part.nodes.model.clone()
            for child in fill.childNodes {
                guard let oldGeometry = child.geometry else { continue }
                let newGeometry = SCNGeometry(sources: oldGeometry.sources(for: .vertex), elements: oldGeometry.elements)
                newGeometry.materials = [fillMaterial]
                child.geometry = newGeometry
            }
            container.addChildNode(fill)

            let edgeSource = edgeVisibility == .all ? part.nodes.smoothEdges : part.nodes.sharpEdges
            if let edgeMaterial, let edgeSource {
                let edgeClone = edgeSource.clone()
                edgeClone.isHidden = false
                for node in edgeClone.childNodes(passingTest: { node, _ in node.geometry != nil }) {
                    guard let oldGeometry = node.geometry else { continue }
                    let newGeometry = SCNGeometry(sources: oldGeometry.sources(for: .vertex), elements: oldGeometry.elements)
                    newGeometry.materials = [edgeMaterial]
                    node.geometry = newGeometry
                }
                container.addChildNode(edgeClone)
            }

            root.addChildNode(container)
            crossSectionGhostFillNodes[part.id] = container
        }

        privateRoot.addChildNode(root)
        crossSectionGhostNode = root
        crossSectionGhostMaterials = materials
    }

    /// How strongly the diagonal hatch is blended into a section's cap. The section being edited — or
    /// the one whose button is hovered (an edit-mode preview) — gets a much bolder hatch so its cut
    /// face stands out from the others.
    private func hatchStrength(forSection id: UUID) -> Float {
        (id == selectedCrossSectionID || id == hoveredCrossSectionID) ? 0.75 : 0.2
    }

    /// Re-pushes the hatch strength to the existing cap materials (no geometry rebuild) so the selected
    /// section's bolder hatch appears/disappears the instant edit mode is entered or left.
    func updateCrossSectionCapHatchStrength() {
        for (key, material) in crossSectionCapMaterialsByKey {
            material.setValue(NSNumber(value: hatchStrength(forSection: key.section)), forKey: "hatchStrength")
        }
        sceneView.setNeedsRedraw()
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
        flashCrossSectionGhost(difference: section) // reveal just what this new cut removes
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

    func deleteAllCrossSections() {
        guard !crossSections.isEmpty else { return }
        clearCrossSectionCaps()
        updateCrossSections([], actionName: "Delete All Cross-Sections")
        selectedCrossSectionID = nil
    }

    func flipSelectedCrossSection() {
        mutateSelectedCrossSection(actionName: "Flip Cross-Section") { $0.flip() }
    }

    func setCrossSectionEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = crossSections.firstIndex(where: { $0.id == id }), crossSections[index].enabled != enabled else { return }
        var sections = crossSections
        sections[index].enabled = enabled
        updateCrossSections(sections, actionName: enabled ? "Show Cross-Section" : "Hide Cross-Section")
        // Preview just what this cut newly removes (kept by the other active cuts), not the whole cut-away.
        if enabled { flashCrossSectionGhost(difference: sections[index]) }
    }

    /// Activates or deactivates every cross-section at once (single undo step).
    func setAllCrossSectionsEnabled(_ enabled: Bool) {
        guard crossSections.contains(where: { $0.enabled != enabled }) else { return }
        var sections = crossSections
        for index in sections.indices { sections[index].enabled = enabled }
        updateCrossSections(sections, actionName: enabled ? "Show All Cross-Sections" : "Hide All Cross-Sections")
        if enabled { flashCrossSectionGhost() }
    }

    func alignSelectedCrossSection(to axis: CrossSection.Axis) {
        mutateSelectedCrossSection(actionName: "Align Cross-Section to \(axis.displayName)") {
            $0.orientation = CrossSection.orientation(for: axis)
        }
    }

    func snapSelectedCrossSectionToNearestAxis() {
        mutateSelectedCrossSection(actionName: "Snap Cross-Section to Axis") { $0.snapToNearestAxis() }
    }

    private func mutateSelectedCrossSection(actionName: String, _ transform: (inout CrossSection) -> Void) {
        guard let id = selectedCrossSectionID, let index = crossSections.firstIndex(where: { $0.id == id }) else { return }
        var sections = crossSections
        transform(&sections[index])
        updateCrossSections(sections, actionName: actionName)
        // Flip / align / snap aren't drags, so briefly flash the cut-away ghost to preview the change.
        flashCrossSectionGhost()
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
