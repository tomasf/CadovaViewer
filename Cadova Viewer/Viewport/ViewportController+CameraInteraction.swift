import SceneKit
import simd
import ViewerCore

/// Custom camera navigation, replacing SceneKit's built-in `defaultCameraController`. The math here
/// drives `cameraNode` directly (with implicit actions disabled): turntable orbit, pan, and
/// zoom-toward-a-point. `CustomSceneView` feeds it raw mouse/trackpad input. `worldUp` is +Z.
extension ViewportController {
    /// How far past the model's bounding radius a grid pivot may sit before we fall back to the model
    /// centre (a near-grazing ray crosses z = 0 arbitrarily far away).
    private static let maxGridPivotRadiusFactor: Float = 50

    /// Per-60fps-frame velocity retention for the post-release glide. SceneKit uses 1/128 (≈0.992),
    /// a long gentle coast; this is a touch firmer so it settles sooner.
    private static let inertiaRetentionPerFrame: Float = 0.95
    /// Don't start a glide below this release speed (points or raw-delta units per second) — avoids a
    /// drift after a slow, deliberate drag.
    private static let inertiaMinStartSpeed: Float = 12
    /// End the glide once it decays below this speed.
    private static let inertiaStopSpeed: Float = 4

    // Zoom limits, in multiples of the model's bounding radius — a distance-to-pivot for perspective,
    // a view half-height (orthographicScale) for orthographic. The zoom-in floor matters: a
    // multiplicative dolly can otherwise reach a near-zero distance, from which zooming back out
    // crawls imperceptibly.
    private static let zoomOutLimitFactor: Float = 40
    private static let zoomInLimitFactor: Float = 0.05

    enum CameraAxisLock {
        case horizontal // yaw only
        case vertical   // pitch only
    }

    /// State captured at the start of a click-drag, so each frame is applied from the drag's origin
    /// (drift-free) rather than accumulated.
    struct CameraDragState {
        let pivot: SIMD3<Float>
        let initialTransform: simd_float4x4
        /// The camera's right axis at drag start, used as the (yaw-rotated) pitch axis.
        let initialRight: SIMD3<Float>
        /// World units per screen point at the pivot's depth, for panning.
        let worldPerPoint: Float
    }

    // MARK: - Pivot

    /// The world point to orbit/zoom around for a given view point: the surface under it, else the
    /// grid (z = 0) point if that's reasonably close, else the model centre.
    func interactionPivot(atViewPoint point: CGPoint) -> SCNVector3 {
        if let hit = nearestVisibleHit(at: point, in: modelInstance.root) {
            return hit.worldCoordinates
        }
        let planePoint = sceneView.xyPlanePoint(forViewPoint: point)
        if isReasonablePivot(planePoint) {
            return planePoint
        }
        return sceneController.modelBoundingSphere.center
    }

    private func isReasonablePivot(_ p: SCNVector3) -> Bool {
        guard let pov = sceneView.pointOfView else { return false }
        let pt = simd_float3(p)
        let pos = pov.simdWorldPosition
        // Must be in front of the camera.
        if simd_dot(pt - pos, simd_normalize(pov.simdWorldFront)) <= 0 { return false }
        // And not absurdly far from the model.
        let center = simd_float3(sceneController.modelBoundingSphere.center)
        let radius = max(sceneController.modelBoundingSphere.radius, 1)
        return simd_distance(pt, center) < radius * Self.maxGridPivotRadiusFactor
    }

    // MARK: - Click-drag (orbit / pan)

    func beginCameraDrag(atViewPoint point: CGPoint) -> CameraDragState {
        stopCameraInertia() // a new grab cancels any ongoing glide
        let pivot = simd_float3(interactionPivot(atViewPoint: point))
        let m = cameraNode.simdTransform
        let position = m.columns.3.xyz
        let right = simd_normalize(m.columns.0.xyz)
        let forward = simd_normalize(-m.columns.2.xyz)
        let depth = abs(simd_dot(pivot - position, forward))
        return CameraDragState(
            pivot: pivot,
            initialTransform: m,
            initialRight: right,
            worldPerPoint: worldPerPoint(atDepth: depth)
        )
    }

    /// Turntable orbit: yaw about world +Z and pitch about the (yaw-rotated) horizontal right axis,
    /// both through the pivot. Applied rigidly to the drag-start transform, so it doesn't drift and
    /// preserves any pre-existing roll. There's no pole clamp — dragging past vertical rolls the view
    /// over and upside down, matching SceneKit's turntable. `dx`/`dy` are the total drag delta from
    /// the start, in points, y-up.
    func orbitCamera(_ state: CameraDragState, dx: Float, dy: Float) {
        // SceneKit's turntable: angle = pixels × sensitivity × (360 / maxViewportDim) × (π / 180),
        // i.e. with the default sensitivity of 1, 2π per drag across the longer viewport edge.
        let maxDim = Float(max(sceneView.bounds.width, sceneView.bounds.height, 1))
        let speed = 2 * .pi / maxDim
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
    func panCamera(_ state: CameraDragState, dx: Float, dy: Float) {
        let right = simd_normalize(state.initialTransform.columns.0.xyz)
        let up = simd_normalize(state.initialTransform.columns.1.xyz)
        let translation = (-dx * state.worldPerPoint) * right + (-dy * state.worldPerPoint) * up
        var m = state.initialTransform
        m.columns.3 = SIMD4<Float>(state.initialTransform.columns.3.xyz + translation, 1)
        applyCameraTransform(m)
    }

    // MARK: - Scroll / pinch

    /// Free pan driven by a precise scroll (trackpad / Magic Mouse). Uses the model centre's depth as
    /// a global scale reference rather than hit-testing every event.
    func panByScroll(dx: Float, dy: Float) {
        stopCameraInertia()
        let wpp = worldPerPoint(atDepth: modelCenterDepth())
        let m = cameraNode.simdTransform
        let right = simd_normalize(m.columns.0.xyz)
        let up = simd_normalize(m.columns.1.xyz)
        // Content follows the fingers: move the camera opposite the gesture.
        let translation = (-dx * wpp) * right + (dy * wpp) * up
        var nm = m
        nm.columns.3 = SIMD4<Float>(m.columns.3.xyz + translation, 1)
        applyCameraTransform(nm)
        viewDidChange()
    }

    /// Zoom toward the world point under `point`. `factor > 1` zooms in. Perspective dollies along the
    /// line to the target (which keeps it fixed on screen); orthographic scales then re-pans so the
    /// target lands back under the cursor.
    func zoomCamera(factor: Double, towardViewPoint point: CGPoint) {
        guard factor > 0, let camera = cameraNode.camera else { return }
        stopCameraInertia()
        // Reuse the hit-tested pivot for the whole zoom burst (the cursor stays put, so the world
        // point under it is unchanged); `hoverPoint` clears it when the cursor moves. This keeps zoom
        // smooth — SceneKit's own dolly likewise avoids a per-event scene hit-test.
        let target: SCNVector3
        if let zoomPivot {
            target = zoomPivot
        } else {
            target = interactionPivot(atViewPoint: point)
            zoomPivot = target
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

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            var nm = m
            nm.columns.3 = SIMD4<Float>(simd_float3(target) + offset * (newDistance / distance), 1)
            cameraNode.simdTransform = nm
            SCNTransaction.commit()
        }
        viewDidChange()
    }

    /// Min/max zoom extent from the model's bounding radius: a distance-to-pivot for perspective, a
    /// view half-height (orthographicScale) for orthographic. `nil` when no model is loaded.
    private func zoomLimits() -> (min: Float, max: Float)? {
        let radius = Float(sceneController.modelBoundingSphere.radius)
        guard radius > 1e-4 else { return nil }
        return (radius * Self.zoomInLimitFactor, radius * Self.zoomOutLimitFactor)
    }

    // MARK: - Helpers

    private func applyCameraTransform(_ transform: simd_float4x4) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        cameraNode.simdTransform = transform
        SCNTransaction.commit()
    }

    /// World units spanned by one screen point at `depth` along the view axis.
    private func worldPerPoint(atDepth depth: Float) -> Float {
        let height = Float(max(sceneView.bounds.height, 1))
        guard let camera = cameraNode.camera else { return 0 }
        if camera.usesOrthographicProjection {
            return Float(2 * camera.orthographicScale) / height
        }
        let tanHalfFov = Float(tan(camera.fieldOfView * .pi / 180 / 2))
        return 2 * depth * tanHalfFov / height
    }

    private func modelCenterDepth() -> Float {
        let center = simd_float3(sceneController.modelBoundingSphere.center)
        let pos = cameraNode.simdWorldPosition
        let forward = simd_normalize(cameraNode.simdWorldFront)
        return abs(simd_dot(center - pos, forward))
    }

    // MARK: - Inertia (post-release glide)

    /// Starts a glide from a finished drag. `delta` is the drag's final total delta and `velocity`
    /// its release speed (same units/axes as `orbitCamera`/`panCamera` deltas; points/sec for pan,
    /// raw-delta/sec for orbit). A slow release (below `inertiaMinStartSpeed`) doesn't glide.
    func startCameraInertia(dragState: CameraDragState, delta: SIMD2<Float>, velocity: SIMD2<Float>, isOrbit: Bool) {
        stopCameraInertia()
        guard simd_length(velocity) >= Self.inertiaMinStartSpeed else { return }
        inertiaDragState = dragState
        inertiaDelta = delta
        inertiaVelocity = velocity
        inertiaIsOrbit = isOrbit
        inertiaLastTime = CACurrentMediaTime()
        // Render vsync-paced for the whole glide. Otherwise SCNView only redraws on demand (via
        // setNeedsRedraw), presenting at irregular intervals — full FPS but visibly choppy. An active
        // drag ends up continuously rendered, which is why it looks smooth.
        sceneView.rendersContinuously = true
        // Tick well above the display refresh so each rendered frame samples a current pose.
        let timer = Timer(timeInterval: 1.0 / 240.0, repeats: true) { [weak self] _ in self?.stepCameraInertia() }
        RunLoop.main.add(timer, forMode: .common)
        inertiaTimer = timer
    }

    private func stepCameraInertia() {
        guard let dragState = inertiaDragState else { stopCameraInertia(); return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - inertiaLastTime, 0), 0.1)) // guard against stalls / first frame
        inertiaLastTime = now

        // Integrate with real elapsed time, so the pose at any render is correct regardless of when
        // ticks land — the motion stays smooth even if the timer jitters.
        inertiaDelta += inertiaVelocity * dt
        if inertiaIsOrbit {
            orbitCamera(dragState, dx: inertiaDelta.x, dy: inertiaDelta.y)
        } else {
            panCamera(dragState, dx: inertiaDelta.x, dy: inertiaDelta.y)
        }
        sceneView.setNeedsRedraw()

        inertiaVelocity *= pow(Self.inertiaRetentionPerFrame, dt * 60)
        if simd_length(inertiaVelocity) < Self.inertiaStopSpeed {
            stopCameraInertia()
            viewDidChange() // persist the resting position once the glide settles
        }
    }

    func stopCameraInertia() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
        inertiaDragState = nil
        inertiaVelocity = .zero
        sceneView.rendersContinuously = false
    }
}
