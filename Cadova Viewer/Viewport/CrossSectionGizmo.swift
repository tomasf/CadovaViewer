import SceneKit
import ViewerCore
import simd

/// The interactive transform handle for the selected cross-section. By default it's plane-relative —
/// two rings aim the cut's normal and one arrow slides the plane along it. Holding Shift switches to a
/// world-aligned set with all three translate arrows and rotate rings (R/G/B = X/Y/Z). Kept a constant
/// on-screen size and drawn on top of the model.
final class CrossSectionGizmo {
    static let minimumViewAlignment = 0.08

    enum Handle: Equatable {
        case translate(CrossSection.Axis)
        case rotate(CrossSection.Axis)
    }

    /// Whether the gizmo's axes follow the cut plane (the default — rings aim the normal, the arrow
    /// slides along it) or world space (all three arrows and rings, world-aligned; engaged with Shift).
    enum Space { case plane, world }
    private(set) var space: Space = .plane

    let root = SCNNode()
    private let planeContainer = SCNNode()
    private let worldContainer = SCNNode()
    /// Maps a hit node name back to the handle it represents.
    private var handleForName: [String: Handle] = [:]
    /// Each handle's top node, for dimming the others during a drag.
    private var handleTopNodes: [(handle: Handle, node: SCNNode)] = []
    /// Target on-screen radius of the gizmo, in view points.
    private let screenSize: Double = 140

    /// The selected section's plane, cached as plain values so the per-frame "follow the view" update
    /// (which runs on the render thread) doesn't read the main-thread cross-section state.
    private var followNormal = SIMD3<Double>(0, 0, 1)
    private var followDistance = 0.0
    private var following = false
    init() {
        root.name = "Cross-section gizmo"
        root.isHidden = true
        buildPlaneHandles(into: planeContainer)
        buildWorldHandles(into: worldContainer)
        root.addChildNode(planeContainer)
        root.addChildNode(worldContainer)
        worldContainer.isHidden = true
        // Draw on top of everything (incl. the opaque caps): the materials ignore the depth buffer, so
        // a high rendering order keeps the gizmo painted last.
        root.enumerateChildNodes { node, _ in node.renderingOrder = 100 }
    }

    /// The plane-relative handle set: rotate about local X and Y aim the normal, and the local−Z arrow
    /// moves the plane along that normal. Rotating about the normal (Z) and translating within the plane
    /// (X/Y) do nothing on an infinite, normal-symmetric cut, so those handles are omitted.
    private func buildPlaneHandles(into container: SCNNode) {
        container.addChildNode(makeRing(axis: .x, space: .plane))
        container.addChildNode(makeRing(axis: .y, space: .plane))
        // The translate arrow points along the kept (active) half — local −Z. Flipping the section
        // rotates the whole gizmo, so the arrow then points the other way automatically.
        let arrow = makeArrow(axis: .z, space: .plane)
        arrow.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)) // +Y → −Z
        container.addChildNode(arrow)
        container.addChildNode(makeCenterCube(handle: .translate(.z), space: .plane))
    }

    /// The world-relative handle set (engaged with Shift): all three translate arrows and rotate rings,
    /// world-aligned, so the plane can be moved and spun about world X/Y/Z directly.
    private func buildWorldHandles(into container: SCNNode) {
        for axis in CrossSection.Axis.allCases {
            container.addChildNode(makeRing(axis: axis, space: .world))
            container.addChildNode(makeArrow(axis: axis, space: .world))
        }
        container.addChildNode(makeCenterCube(handle: nil, space: .world))
    }

    /// Positions the gizmo at `anchor` (a point on the plane — see `followView`, which slides it to the
    /// view centre), orients it to the section, and shows it.
    func update(for section: CrossSection, anchor: SIMD3<Double>, space: Space) {
        self.space = space
        root.simdPosition = SIMD3<Float>(anchor)
        if space == .world {
            root.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)) // world-aligned
        } else {
            let q = section.orientation
            root.simdOrientation = simd_quatf(vector: SIMD4<Float>(Float(q.vector.x), Float(q.vector.y), Float(q.vector.z), Float(q.vector.w)))
        }
        planeContainer.isHidden = space != .plane
        worldContainer.isHidden = space != .world
        followNormal = section.normal
        followDistance = simd_dot(section.normal, section.origin)
        following = true
        root.isHidden = false
    }

    func hide() {
        following = false
        root.isHidden = true
    }

    /// Slides the gizmo along its (infinite) plane so it stays near the centre of the view — keeping it
    /// reachable when zoomed in. Skipped while dragging (the pivot stays put). Runs per frame on the
    /// render thread, reading only the cached plane, never the main-thread cross-section state.
    ///
    /// Pass the *presentation* camera node: during an orbit the default camera controller animates the
    /// presentation transform while the model transform (what `unprojectPoint` reads) lags, so using the
    /// presentation makes the gizmo track the camera live instead of only catching up on the next click.
    func followView(presentationCamera: SCNNode?, isDragging: Bool) {
        guard following, !isDragging, !root.isHidden, let camera = presentationCamera else { return }
        if let anchor = anchorOnPlane(camera: camera) {
            root.simdPosition = SIMD3<Float>(anchor)
        }
    }

    /// The point where the camera's optical axis (the ray through the view centre) meets the cached
    /// plane. Near edge-on, keep the current anchor on the plane instead of chasing a far-away,
    /// numerically unstable intersection.
    private func anchorOnPlane(camera: SCNNode) -> SIMD3<Double>? {
        let origin = SIMD3<Double>(camera.simdWorldPosition)
        let direction = SIMD3<Double>(simd_normalize(camera.simdWorldFront)) // camera's -Z, the view centre
        let denom = simd_dot(direction, followNormal)
        if abs(denom) > Self.minimumViewAlignment {
            let t = (followDistance - simd_dot(origin, followNormal)) / denom
            if t > 0 { return origin + direction * t }
        }
        let current = SIMD3<Double>(root.simdPosition)
        return current - followNormal * (simd_dot(current, followNormal) - followDistance)
    }

    /// Dims every handle except `active` (so a drag highlights what's being manipulated). Pass nil to
    /// restore all handles to full opacity.
    func setActiveHandle(_ active: Handle?) {
        for entry in handleTopNodes {
            entry.node.opacity = (active == nil || entry.handle == active) ? 1 : 0.10
        }
    }

    /// The handle for a hit node (walks up to the named handle node), or nil.
    func handle(for node: SCNNode) -> Handle? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name, let handle = handleForName[name] { return handle }
            current = n.parent
        }
        return nil
    }

    /// Rescales the gizmo so it stays a constant on-screen size regardless of zoom/distance.
    func updateScreenScale(renderer: SCNSceneRenderer) {
        guard !root.isHidden else { return }
        let world = worldRadius(forScreenRadius: screenSize, at: root.simdPosition, renderer: renderer)
        root.simdScale = SIMD3<Float>(repeating: Float(world))
    }

    // MARK: - Geometry

    /// A unique node name encoding the space and handle, so the two handle sets don't collide and a hit
    /// resolves back to the right handle.
    private func handleName(space: Space, handle: Handle) -> String {
        let s = space == .world ? "world" : "plane"
        switch handle {
        case .translate(let axis): return "cs.gizmo.\(s).translate.\(axis.displayName)"
        case .rotate(let axis): return "cs.gizmo.\(s).rotate.\(axis.displayName)"
        }
    }

    /// The centre cube. In plane space it's the translate-along-normal handle; in world space it's a
    /// purely visual anchor (the three arrows cover translation), so `handle` is nil.
    private func makeCenterCube(handle: Handle?, space: Space) -> SCNNode {
        let cube = SCNNode(geometry: SCNBox(width: 0.13, height: 0.13, length: 0.13, chamferRadius: 0.02))
        cube.geometry?.firstMaterial = material(color: NSColor(white: 0.85, alpha: 1))
        let name = "cs.gizmo.\(space == .world ? "world" : "plane").center"
        cube.name = name
        if let handle {
            handleForName[name] = handle
            handleTopNodes.append((handle, cube))
        }
        return cube
    }

    private func makeArrow(axis: CrossSection.Axis, space: Space) -> SCNNode {
        let node = SCNNode()
        node.simdOrientation = Self.localYToAxis(axis)
        let name = handleName(space: space, handle: .translate(axis))
        handleForName[name] = .translate(axis)

        let shaft = SCNNode(geometry: SCNCylinder(radius: 0.011, height: 0.72))
        shaft.simdPosition = SIMD3(0, 0.36, 0)
        let tip = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.18))
        tip.simdPosition = SIMD3(0, 0.81, 0)

        for child in [shaft, tip] {
            child.geometry?.firstMaterial = material(color: Self.color(axis))
            child.name = name
            node.addChildNode(child)
        }
        // A fat invisible cylinder gives the thin arrow a generous hit target.
        let proxy = SCNNode(geometry: SCNCylinder(radius: 0.08, height: 1.0))
        proxy.simdPosition = SIMD3(0, 0.45, 0)
        proxy.geometry?.firstMaterial = hitProxyMaterial()
        proxy.name = name
        node.addChildNode(proxy)

        node.name = name
        handleTopNodes.append((.translate(axis), node))
        return node
    }

    private func makeRing(axis: CrossSection.Axis, space: Space) -> SCNNode {
        let node = SCNNode(geometry: SCNTorus(ringRadius: 0.58, pipeRadius: 0.011))
        node.simdOrientation = Self.localYToAxis(axis)
        node.geometry?.firstMaterial = material(color: Self.color(axis))
        let name = handleName(space: space, handle: .rotate(axis))
        node.name = name
        // A fat invisible torus widens the thin ring's hit target.
        let proxy = SCNNode(geometry: SCNTorus(ringRadius: 0.58, pipeRadius: 0.06))
        proxy.geometry?.firstMaterial = hitProxyMaterial()
        proxy.name = name
        node.addChildNode(proxy)

        handleForName[name] = .rotate(axis)
        handleTopNodes.append((.rotate(axis), node))
        return node
    }

    /// A material that draws nothing (no colour, no depth) but is still hit-testable — for invisible
    /// hit proxies that widen the thin handles' click targets.
    private func hitProxyMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        return m
    }

    private func material(color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.isDoubleSided = true
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        return m
    }

    /// Rotation taking the primitives' local +Y onto the given world axis (cylinders/cones/tori are
    /// built along/around +Y).
    private static func localYToAxis(_ axis: CrossSection.Axis) -> simd_quatf {
        switch axis {
        case .x: simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1)) // +Y → +X
        case .y: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))        // +Y
        case .z: simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))  // +Y → +Z
        }
    }

    private static func color(_ axis: CrossSection.Axis) -> NSColor {
        switch axis {
        case .x: NSColor.systemRed
        case .y: NSColor.systemGreen
        case .z: NSColor.systemBlue
        }
    }

    /// World-space radius at `position` that projects to `screenRadius` view points (mirrors the
    /// technique in `MeasurementRenderer`).
    private func worldRadius(forScreenRadius screenRadius: Double, at position: SIMD3<Float>, renderer: SCNSceneRenderer) -> Double {
        let world = SCNVector3(position)
        let projected = renderer.projectPoint(world)
        let offset = renderer.unprojectPoint(SCNVector3(projected.x + CGFloat(screenRadius), projected.y, projected.z))
        let radius = offset.distance(from: world)
        return radius.isFinite ? max(radius, 0.0001) : 0.0001
    }
}
