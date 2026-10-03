import SceneKit
import simd
import os

/// What a `CameraNavigator` needs from the view it drives.
public protocol CameraNavigatorDelegate: AnyObject {
    /// The camera node to move. Called from the render thread during a glide, so it must be safe to call
    /// from any thread.
    func cameraNode(for navigator: CameraNavigator) -> SCNNode

    /// The model's world-space bounding sphere, used for zoom limits and the pivot fallback. Called from
    /// the render thread during a glide.
    func modelBoundingSphere(for navigator: CameraNavigator) -> (center: SCNVector3, radius: Float)

    /// The nearest visible model surface point under `viewPoint`, if any.
    func cameraNavigator(_ navigator: CameraNavigator, surfacePointAt viewPoint: CGPoint) -> SCNVector3?

    /// The camera transform (or orthographic scale) was just changed, inside the transaction that changed
    /// it. May be called from the render thread.
    func cameraNavigatorDidMoveCamera(_ navigator: CameraNavigator)

    /// Direct navigation is about to take over the camera, e.g. to stop an animated camera move. Main thread.
    func cameraNavigatorWillTakeOver(_ navigator: CameraNavigator)

    /// A discrete camera move (scroll, wheel zoom) or a glide has finished. Main thread.
    func cameraNavigatorDidFinishMoving(_ navigator: CameraNavigator)
}

public extension CameraNavigatorDelegate {
    func cameraNavigatorDidMoveCamera(_ navigator: CameraNavigator) {}
    func cameraNavigatorWillTakeOver(_ navigator: CameraNavigator) {}
    func cameraNavigatorDidFinishMoving(_ navigator: CameraNavigator) {}
}

/// Custom camera navigation, replacing SceneKit's built-in `defaultCameraController`: turntable orbit,
/// pan, roll and zoom-toward-a-point, each applied rigidly from the gesture's start pose, plus the
/// post-release glide. It drives the delegate's camera node directly (with implicit actions disabled).
/// `NavigableSceneView` feeds it raw mouse/trackpad input. World up is +Z.
public final class CameraNavigator {
    public weak var delegate: CameraNavigatorDelegate?
    public weak var sceneView: SCNView?

    /// How far past the model's bounding radius a grid pivot may sit before we fall back to the model
    /// centre (a near-grazing ray crosses z = 0 arbitrarily far away).
    private static let maxGridPivotRadiusFactor: Float = 50

    // Zoom limits, in multiples of the model's bounding radius — a distance-to-pivot for perspective,
    // a view half-height (orthographicScale) for orthographic. The zoom-in floor matters: a
    // multiplicative dolly can otherwise reach a near-zero distance, from which zooming back out
    // crawls imperceptibly.
    private static let zoomOutLimitFactor: Float = 40
    private static let zoomInLimitFactor: Float = 0.05

    /// Cached world pivot for zoom-toward-cursor, hit-tested once per cursor resting spot rather than
    /// every scroll/pinch event (which would re-scan the scene and drop the framerate). Dropped when the
    /// cursor moves (see `resetZoomPivot()`) or a zoom arrives at a different view point.
    private var zoomPivot: (viewPoint: CGPoint, world: SCNVector3)?

    /// The post-release glide. The render loop reads/clears this while the main thread starts and
    /// cancels it, so it's lock-guarded. See `CameraNavigator+Inertia`.
    let inertia = OSAllocatedUnfairLock<InertiaState?>(initialState: nil)

    public init(sceneView: SCNView) {
        self.sceneView = sceneView
    }

    public enum AxisLock {
        case horizontal // yaw only
        case vertical   // pitch only
    }

    /// State captured at the start of a click-drag or gesture, so each frame is applied from the
    /// gesture's origin (drift-free) rather than accumulated.
    public struct DragState {
        public let pivot: SIMD3<Float>
        let initialTransform: simd_float4x4
        /// The camera's right axis at drag start, used as the (yaw-rotated) pitch axis.
        let initialRight: SIMD3<Float>
        /// World units per screen point at the pivot's depth, for panning.
        let worldPerPoint: Float
        /// The longer viewport edge (points) at drag start, captured here so `orbit` can run on the
        /// render thread during the glide without touching `sceneView.bounds` (AppKit, main-thread only).
        let maxViewportDim: Float
        /// The viewport height (points) at drag start. Like `maxViewportDim`, captured so the zoom glide
        /// can compute an orthographic re-pan on the render thread without touching `sceneView.bounds`.
        let viewportHeight: Float
        /// The camera's `orthographicScale` (view half-height, world units) at drag start. Zoom re-applies
        /// cumulatively from this start value, so it's captured rather than read live. Unused (0) in
        /// perspective.
        let orthographicScale: Float
        /// Whether the camera was orthographic at drag start, choosing the zoom math. Won't change during
        /// a gesture, so it's safe to capture once.
        let usesOrthographic: Bool
    }

    private var cameraNode: SCNNode? { delegate?.cameraNode(for: self) }

    private var modelBoundingSphere: (center: SCNVector3, radius: Float) {
        delegate?.modelBoundingSphere(for: self) ?? (SCNVector3Zero, 0)
    }

    // MARK: - Pivot

    /// The world point to orbit/zoom around for a given view point: the surface under it, else the
    /// grid (z = 0) point if that's reasonably close, else the model centre.
    public func interactionPivot(atViewPoint point: CGPoint) -> SCNVector3 {
        if let hit = delegate?.cameraNavigator(self, surfacePointAt: point) {
            return hit
        }
        if let sceneView {
            let planePoint = sceneView.xyPlanePoint(forViewPoint: point)
            if isReasonablePivot(planePoint) {
                return planePoint
            }
        }
        return modelBoundingSphere.center
    }

    private func isReasonablePivot(_ p: SCNVector3) -> Bool {
        guard let pov = cameraNode else { return false }
        let pt = simd_float3(p)
        let pos = pov.simdWorldPosition
        // Must be in front of the camera.
        if simd_dot(pt - pos, simd_normalize(pov.simdWorldFront)) <= 0 { return false }
        // And not absurdly far from the model.
        let sphere = modelBoundingSphere
        let center = simd_float3(sphere.center)
        let radius = max(sphere.radius, 1)
        return simd_distance(pt, center) < radius * Self.maxGridPivotRadiusFactor
    }

    /// Forgets the cached zoom-toward-cursor pivot. Call when the cursor moves.
    public func resetZoomPivot() {
        zoomPivot = nil
    }

    // MARK: - Click-drag (orbit / pan / roll)

    public func beginDrag(atViewPoint point: CGPoint) -> DragState? {
        guard let sceneView, let cameraNode else { return nil }
        stopMotion() // a new grab cancels any ongoing glide
        let pivot = simd_float3(interactionPivot(atViewPoint: point))
        let m = cameraNode.simdTransform
        let position = m.columns.3.xyz
        let right = simd_normalize(m.columns.0.xyz)
        let forward = simd_normalize(-m.columns.2.xyz)
        let depth = abs(simd_dot(pivot - position, forward))
        return DragState(
            pivot: pivot,
            initialTransform: m,
            initialRight: right,
            worldPerPoint: worldPerPoint(atDepth: depth),
            maxViewportDim: Float(max(sceneView.bounds.width, sceneView.bounds.height, 1)),
            viewportHeight: Float(max(sceneView.bounds.height, 1)),
            orthographicScale: Float(cameraNode.camera?.orthographicScale ?? 0),
            usesOrthographic: cameraNode.camera?.usesOrthographicProjection ?? false
        )
    }

    /// Turntable orbit: yaw about world +Z and pitch about the (yaw-rotated) horizontal right axis,
    /// both through the pivot. Applied rigidly to the drag-start transform, so it doesn't drift and
    /// preserves any pre-existing roll. There's no pole clamp — dragging past vertical rolls the view
    /// over and upside down, matching SceneKit's turntable. `dx`/`dy` are the total drag delta from
    /// the start, in points, y-up.
    public func orbit(_ state: DragState, dx: Float, dy: Float) {
        // SceneKit's turntable: angle = pixels × sensitivity × (360 / maxViewportDim) × (π / 180),
        // i.e. with the default sensitivity of 1, 2π per drag across the longer viewport edge.
        // `maxViewportDim` is captured in the drag state (from `bounds`, on the main thread) so this
        // works on the render thread during the glide.
        let speed = 2 * .pi / state.maxViewportDim
        let yaw = -dx * speed
        // Drag down (dy < 0) → look down at the top.
        let pitch = dy * speed

        let yawQ = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 0, 1))
        let pitchQ = simd_quatf(angle: pitch, axis: yawQ.act(state.initialRight))
        let rot = pitchQ * yawQ

        let position = state.initialTransform.columns.3.xyz
        var m = simd_float4x4(rot) * state.initialTransform
        m.columns.3 = SIMD4<Float>(state.pivot + rot.act(position - state.pivot), 1)
        applyCameraTransform(m)
    }

    /// Pan: translate in the camera's right/up plane so the grabbed point tracks the cursor.
    public func pan(_ state: DragState, dx: Float, dy: Float) {
        let right = simd_normalize(state.initialTransform.columns.0.xyz)
        let up = simd_normalize(state.initialTransform.columns.1.xyz)
        let translation = (-dx * state.worldPerPoint) * right + (-dy * state.worldPerPoint) * up
        var m = state.initialTransform
        m.columns.3 = SIMD4<Float>(state.initialTransform.columns.3.xyz + translation, 1)
        applyCameraTransform(m)
    }

    /// Roll: rotate about the camera's view (forward) axis through the pivot, applied rigidly to the
    /// drag-start transform so it stays drift-free and keeps the pivot world point fixed on screen.
    /// Mirrors SceneKit's rotation-gesture roll (`rollBy:aroundScreenPoint:`). `angle` is the total
    /// rotation from the start, in radians.
    public func roll(_ state: DragState, angle: Float) {
        let forward = simd_normalize(-state.initialTransform.columns.2.xyz)
        let rot = simd_quatf(angle: angle, axis: forward)
        let position = state.initialTransform.columns.3.xyz
        var m = simd_float4x4(rot) * state.initialTransform
        m.columns.3 = SIMD4<Float>(state.pivot + rot.act(position - state.pivot), 1)
        applyCameraTransform(m)
    }

    // MARK: - Scroll / pinch

    /// Free pan driven by a precise scroll (trackpad / Magic Mouse). Uses the model centre's depth as
    /// a global scale reference rather than hit-testing every event.
    public func panByScroll(dx: Float, dy: Float) {
        guard let cameraNode else { return }
        stopMotion()
        let wpp = worldPerPoint(atDepth: modelCenterDepth())
        let m = cameraNode.simdTransform
        let right = simd_normalize(m.columns.0.xyz)
        let up = simd_normalize(m.columns.1.xyz)
        // Content follows the fingers: move the camera opposite the gesture.
        let translation = (-dx * wpp) * right + (dy * wpp) * up
        var nm = m
        nm.columns.3 = SIMD4<Float>(m.columns.3.xyz + translation, 1)
        applyCameraTransform(nm)
        delegate?.cameraNavigatorDidFinishMoving(self)
    }

    /// Zoom toward the world point under `point`. `factor > 1` zooms in. Perspective dollies along the
    /// line to the target (which keeps it fixed on screen); orthographic scales then re-pans so the
    /// target lands back under the cursor.
    public func zoom(factor: Double, towardViewPoint point: CGPoint) {
        guard factor > 0, let sceneView, let cameraNode, let camera = cameraNode.camera else { return }
        stopMotion()
        // Reuse the hit-tested pivot for the whole zoom burst (the cursor stays put, so the world point
        // under it is unchanged). This keeps zoom smooth — SceneKit's own dolly likewise avoids a
        // per-event scene hit-test.
        let target: SCNVector3
        if let zoomPivot, abs(zoomPivot.viewPoint.x - point.x) < 0.5, abs(zoomPivot.viewPoint.y - point.y) < 0.5 {
            target = zoomPivot.world
        } else {
            target = interactionPivot(atViewPoint: point)
            zoomPivot = (point, target)
        }

        // nil while no model is loaded → zoom stays unclamped.
        let limits = zoomLimits()

        if camera.usesOrthographicProjection {
            var newScale = camera.orthographicScale / factor
            if let limits {
                newScale = min(max(newScale, Double(limits.min)), Double(limits.max))
            } else {
                newScale = max(newScale, 0.001)
            }
            guard newScale != camera.orthographicScale else { return } // already at a limit

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            camera.orthographicScale = newScale
            // Re-pan so the target lands back under the cursor.
            let projected = sceneView.projectPoint(target)
            let screenDX = Float(point.x) - Float(projected.x)
            let screenDY = Float(point.y) - Float(projected.y)
            let wpp = Float(2 * newScale) / Float(max(sceneView.bounds.height, 1))
            let m = cameraNode.simdTransform
            let right = simd_normalize(m.columns.0.xyz)
            let up = simd_normalize(m.columns.1.xyz)
            let translation = (-screenDX * wpp) * right + (-screenDY * wpp) * up
            var nm = m
            nm.columns.3 = SIMD4<Float>(m.columns.3.xyz + translation, 1)
            cameraNode.simdTransform = nm
            delegate?.cameraNavigatorDidMoveCamera(self)
            SCNTransaction.commit()
        } else {
            // Perspective dolly along the camera→pivot ray (keeps the pivot fixed on screen). The
            // distance to the pivot scales by 1/factor; clamp it so it can't collapse to ~0 (which
            // would make zooming back out crawl) or run off to infinity.
            let m = cameraNode.simdTransform
            let pos = m.columns.3.xyz
            let offset = pos - simd_float3(target)
            let distance = simd_length(offset)
            guard distance > 1e-5 else { return }
            var newDistance = distance / Float(factor)
            if let limits {
                newDistance = min(max(newDistance, limits.min), limits.max)
            }
            guard abs(newDistance - distance) > 1e-6 else { return } // already at a limit

            var nm = m
            nm.columns.3 = SIMD4<Float>(simd_float3(target) + offset * (newDistance / distance), 1)
            applyCameraTransform(nm)
        }
        delegate?.cameraNavigatorDidFinishMoving(self)
    }

    /// Cumulative zoom-toward-the-pivot, applied rigidly to the drag-start transform (like `orbit`/`pan`/
    /// `roll`), so it's drift-free and keeps the pivot fixed on screen. `logZoom` is the total exponential
    /// dolly from the start (factor = e^logZoom; > 0 zooms in). Runs on the render thread during the zoom
    /// glide, so it touches only captured state — no `sceneView`.
    public func zoom(_ state: DragState, logZoom: Float) {
        let factor = expf(logZoom)
        guard factor > 0 else { return }
        let target = simd_float3(state.pivot)
        let limits = zoomLimits()
        let pos0 = state.initialTransform.columns.3.xyz

        if state.usesOrthographic {
            guard let cameraNode, let camera = cameraNode.camera, state.viewportHeight > 0 else { return }
            var newScale = state.orthographicScale / factor
            if let limits {
                newScale = min(max(newScale, limits.min), limits.max)
            } else {
                newScale = max(newScale, 0.001)
            }
            // Re-pan so the pivot stays under the (fixed) cursor: in orthographic, a world point's screen
            // offset from centre is dot(point − camPos, axis) / worldPerPoint. Holding that offset while
            // the scale (and thus worldPerPoint) changes means shifting the camera by the offset times
            // the change in worldPerPoint.
            let wpp0 = 2 * state.orthographicScale / state.viewportHeight
            let wppNew = 2 * newScale / state.viewportHeight
            let right = simd_normalize(state.initialTransform.columns.0.xyz)
            let up = simd_normalize(state.initialTransform.columns.1.xyz)
            let offsetX = simd_dot(target - pos0, right) / wpp0
            let offsetY = simd_dot(target - pos0, up) / wpp0
            let newPos = pos0 - right * (offsetX * (wppNew - wpp0)) - up * (offsetY * (wppNew - wpp0))

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            camera.orthographicScale = Double(newScale)
            var m = state.initialTransform
            m.columns.3 = SIMD4<Float>(newPos, 1)
            cameraNode.simdTransform = m
            delegate?.cameraNavigatorDidMoveCamera(self)
            SCNTransaction.commit()
        } else {
            // Perspective dolly along the camera→pivot ray (keeps the pivot fixed on screen). Distance to
            // the pivot scales by 1/factor, clamped so it can't collapse to ~0 or run to infinity.
            let offset = pos0 - target
            let distance = simd_length(offset)
            guard distance > 1e-5 else { return }
            var newDistance = distance / factor
            if let limits {
                newDistance = min(max(newDistance, limits.min), limits.max)
            }
            var m = state.initialTransform
            m.columns.3 = SIMD4<Float>(target + offset * (newDistance / distance), 1)
            applyCameraTransform(m)
        }
    }

    /// Min/max zoom extent from the model's bounding radius: a distance-to-pivot for perspective, a
    /// view half-height (orthographicScale) for orthographic. `nil` when no model is loaded.
    private func zoomLimits() -> (min: Float, max: Float)? {
        let radius = modelBoundingSphere.radius
        guard radius > 1e-4 else { return nil }
        return (radius * Self.zoomInLimitFactor, radius * Self.zoomOutLimitFactor)
    }

    // MARK: - Helpers

    func applyCameraTransform(_ transform: simd_float4x4) {
        guard let cameraNode else { return }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        cameraNode.simdTransform = transform
        delegate?.cameraNavigatorDidMoveCamera(self)
        SCNTransaction.commit()
    }

    /// World units spanned by one screen point at `depth` along the view axis.
    private func worldPerPoint(atDepth depth: Float) -> Float {
        guard let sceneView, let camera = cameraNode?.camera else { return 0 }
        let height = Float(max(sceneView.bounds.height, 1))
        if camera.usesOrthographicProjection {
            return Float(2 * camera.orthographicScale) / height
        }
        let tanHalfFov = Float(tan(camera.fieldOfView * .pi / 180 / 2))
        return 2 * depth * tanHalfFov / height
    }

    private func modelCenterDepth() -> Float {
        guard let cameraNode else { return 0 }
        let center = simd_float3(modelBoundingSphere.center)
        let pos = cameraNode.simdWorldPosition
        let forward = simd_normalize(cameraNode.simdWorldFront)
        return abs(simd_dot(center - pos, forward))
    }
}

fileprivate extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
