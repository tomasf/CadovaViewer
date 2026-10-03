import SceneKit
import simd

/// Post-release glide. Each render-loop frame integrates `velocity` into `delta` and re-applies the
/// gesture from its captured start. Stepping in the render loop (`renderer(_:updateAtTime:)`) keeps it in
/// lockstep with vsync, so every presented frame shows a pose computed for that frame — a free-running
/// timer instead beats against SceneKit's render loop and looks choppy.
extension CameraNavigator {
    /// Per-60fps-frame velocity retention for the glide. SceneKit uses 1/128 (≈0.992), a long gentle
    /// coast; this is a touch firmer so it settles sooner.
    private static let inertiaRetentionPerFrame: Float = 0.95
    /// Don't start a glide below this release speed (points or raw-delta units per second) — avoids a
    /// drift after a slow, deliberate drag.
    private static let inertiaMinStartSpeed: Float = 12
    /// End the glide once it decays below this speed.
    private static let inertiaStopSpeed: Float = 4

    /// Roll's glide speeds are in radians/sec (not points/sec), so it needs its own thresholds.
    private static let rollInertiaMinStartSpeed: Float = 0.25
    private static let rollInertiaStopSpeed: Float = 0.08

    /// Zoom's glide speed is in log-zoom units/sec (a rate of exponential dolly, so factor = e^logZoom),
    /// so it needs its own thresholds too.
    private static let zoomInertiaMinStartSpeed: Float = 0.5
    private static let zoomInertiaStopSpeed: Float = 0.05

    public enum Motion { case orbit, pan, roll, zoom }

    struct InertiaState {
        var dragState: DragState
        var delta: SIMD2<Float>
        var velocity: SIMD2<Float>
        /// Which gliding motion `delta`/`velocity` describe. For `.roll`, only `.x` is used (the angle
        /// and angular speed, in radians); for `.zoom`, only `.x` is used (the cumulative log-zoom and
        /// its rate, factor = e^delta.x).
        var motion: Motion
        /// 0 until the first render-loop step seeds it from that frame's time (so the first dt is 0).
        var lastTime: CFTimeInterval = 0
    }

    /// Starts a glide from a finished gesture. `delta` is the gesture's final total delta and `velocity`
    /// its release speed (same units/axes as the matching `orbit`/`pan`/`roll`/`zoom` deltas; points/sec
    /// for pan, raw-delta/sec for orbit, radians/sec for roll and log-zoom/sec for zoom in `.x`). A slow
    /// release (below the motion's min-start speed) doesn't glide.
    public func startInertia(dragState: DragState, delta: SIMD2<Float>, velocity: SIMD2<Float>, motion: Motion) {
        stopMotion()
        let minStart: Float
        switch motion {
        case .roll: minStart = Self.rollInertiaMinStartSpeed
        case .zoom: minStart = Self.zoomInertiaMinStartSpeed
        case .orbit, .pan: minStart = Self.inertiaMinStartSpeed
        }
        guard simd_length(velocity) >= minStart else { return }
        inertia.withLockUnchecked { $0 = InertiaState(dragState: dragState, delta: delta, velocity: velocity, motion: motion) }
        // Render vsync-paced for the whole glide, so the render loop ticks `stepInertia` every frame.
        // Otherwise SCNView only redraws on demand, presenting at irregular intervals — full FPS but
        // visibly choppy. An active drag ends up continuously rendered, which is why it looks smooth.
        sceneView?.rendersContinuously = true
    }

    /// Advances the glide one frame. Call from the render loop (`renderer(_:updateAtTime:)`) with that
    /// frame's `time`, so each presented frame shows a pose computed for it. No-op when no glide is active.
    public func stepInertia(atTime time: TimeInterval) {
        // Integrate under the lock; capture what to apply (and whether we just settled) for use outside.
        let step = inertia.withLockUnchecked { state -> (dragState: DragState, delta: SIMD2<Float>, motion: Motion, stopped: Bool)? in
            guard var s = state else { return nil }
            // Seed the clock on the first frame so its dt is 0, then integrate with real elapsed time.
            let dt = s.lastTime == 0 ? 0 : Float(min(max(time - s.lastTime, 0), 0.1))
            s.lastTime = time
            s.delta += s.velocity * dt
            s.velocity *= pow(Self.inertiaRetentionPerFrame, dt * 60)
            let stopSpeed: Float
            switch s.motion {
            case .roll: stopSpeed = Self.rollInertiaStopSpeed
            case .zoom: stopSpeed = Self.zoomInertiaStopSpeed
            case .orbit, .pan: stopSpeed = Self.inertiaStopSpeed
            }
            let stopped = simd_length(s.velocity) < stopSpeed
            state = stopped ? nil : s
            return (s.dragState, s.delta, s.motion, stopped)
        }
        guard let step else { return }

        switch step.motion {
        case .orbit: orbit(step.dragState, dx: step.delta.x, dy: step.delta.y)
        case .pan: pan(step.dragState, dx: step.delta.x, dy: step.delta.y)
        case .roll: roll(step.dragState, angle: step.delta.x)
        case .zoom: zoom(step.dragState, logZoom: step.delta.x)
        }

        if step.stopped {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                sceneView?.rendersContinuously = false
                delegate?.cameraNavigatorDidFinishMoving(self) // the resting position, once the glide settles
            }
        }
    }

    /// Stops any glide, and lets the delegate stop its own camera animations, so direct navigation takes
    /// over.
    public func stopMotion() {
        delegate?.cameraNavigatorWillTakeOver(self)
        inertia.withLockUnchecked { $0 = nil }
        sceneView?.rendersContinuously = false
    }
}
