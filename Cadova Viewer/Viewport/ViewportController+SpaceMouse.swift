import Foundation
import AppKit
import Combine
import SceneKit
import NavLib
import Synchronization
import simd

extension ViewportController {
    // The document owns one NavLib session whose state provider is this viewport while it's focused
    // (see DocumentViewModel). These push this viewport's state to that shared session — guarded on
    // being the focused viewport, so a background viewport never drives it.

    func updateNavLibPointerPosition() {
        guard isFocusedViewport, let position = mousePosition else { return }
        documentViewModel?.navLibSession.mousePosition = position
    }

    func updateNavLibProjection() {
        guard isFocusedViewport, let cameraProjection else { return }
        documentViewModel?.navLibSession.cameraProjection = cameraProjection
    }

    func setNavLibSuspended(_ suspend: Bool) {
        navLibIsSuspended = suspend
        if suspend {
            // Drop any unapplied SpaceMouse transform so it can't fight a mouse drag or fly-to.
            pendingNavLibTransform.withLock { $0 = nil }
            // Callbacks are ignored while suspended, so the motion's end would never arrive.
            endSpaceMouseMotion(interrupted: true)
        }
        // Only the focused viewport drives the shared session; don't cancel its motion from here.
        if isFocusedViewport {
            documentViewModel?.navLibSession.cancelMotion()
        }
    }

    /// Stops an in-progress SpaceMouse motion in this viewport, e.g. when it loses focus.
    func interruptSpaceMouseMotion() {
        guard isSpaceMouseMotionActive else { return }
        endSpaceMouseMotion(interrupted: true)
        documentViewModel?.navLibSession.cancelMotion()
    }

    /// Restores mouse navigation and on-demand rendering after a SpaceMouse motion. An interrupted
    /// motion also hides the pivot, since the navlib's own hide won't reach this viewport.
    private func endSpaceMouseMotion(interrupted: Bool) {
        guard isSpaceMouseMotionActive else { return }
        isSpaceMouseMotionActive = false
        sceneView.cameraControlEnabled = true
        sceneView.rendersContinuously = false
        if interrupted {
            overlayScene.pivotPointVisibility = false
        } else {
            viewDidChange()
        }
    }
}

extension ViewportController: NavLibStateProvider {
    var modelBoundingBox: SCNVector3.BoundingBox {
        sceneController.modelBoundingBox
    }

    var cameraTransform: NavLib.Transform {
        get {
            // Prefer the last commanded transform that the render loop hasn't applied yet, so NavLib
            // reads back a consistent state. Otherwise the node's model transform — never the
            // presentation tree, whose read takes the scene lock and stalls the main thread.
            if let pending = pendingNavLibTransform.withLock({ $0 }) {
                return pending.navLibTransform
            }
            return (sceneView.pointOfView?.transform ?? SCNMatrix4Identity).navLibTransform
        }
        set {
            guard !navLibIsSuspended else { return }
            // Hand the transform to the render loop instead of committing it here: an SCNTransaction
            // commit on the main thread takes the scene lock every motion frame, contending with the
            // render thread, stalling the run loop, and backing NavLib's frames up (the model kept
            // moving for a while after release). `updateAtTime` applies it on the render thread.
            pendingNavLibTransform.withLock { $0 = newValue.scnMatrix }
            sceneView.setNeedsRedraw()
        }
    }

    var unitsInMeters: Double? { 0.001 }
    var hasEmptySelection: Bool? { true }

    var cameraProjection: NavLib.CameraProjection<SCNVector3>? {
        get {
            guard let camera = sceneView.pointOfView?.camera else { return nil }

            if camera.usesOrthographicProjection {
                let aspectRatio = sceneView.bounds.width / sceneView.bounds.height
                return .orthographic (viewExtents: camera.orthographicViewExtents(viewAspectRatio: aspectRatio))
            } else {
                return .perspective (fov: camera.fieldOfView)
            }
        }
        set {
            guard !navLibIsSuspended, let camera = sceneView.pointOfView?.camera, case .orthographic(let extents) = newValue else { return }
            camera.orthographicScale = 0.5 * (Double(extents.max.y) - Double(extents.min.y))
        }
    }

    var frontView: Transform? {
        cameraView(for: .front).transform.navLibTransform
    }

    func pivotChanged(position: SCNVector3, visible: Bool) {
        guard !navLibIsSuspended else { return }
        overlayScene.pivotPointVisibility = visible
        overlayScene.pivotPointLocation = position.scnVector
    }

    func hitTest(parameters: HitTest<SCNVector3>) -> SCNVector3? {
        let origin = parameters.origin.scnVector
        let direction = parameters.direction.scnVector
        guard let end = modelHitTestEnd(from: origin, direction: direction) else { return nil }

        // When cuts are active, pivot only on visible geometry (kept side or a cap), never clipped-away
        // surfaces. Uses all-intersections + filtering, so it's reserved for when a cut is present.
        if !activeCrossSections.isEmpty {
            return nearestVisibleHit(segmentFrom: origin, to: end, in: modelInstance.root)?.worldCoordinates
        }

        // Hit test each visible part's model node with the closest-hit search mode rather
        // than running the default all-intersections search over the whole container. NavLib
        // calls this on the main thread (single-threaded session) every navigation frame, so
        // the costlier search stalls rendering whenever the ray crosses dense geometry.
        // Rooting at each part's model node also excludes the edge lines (which are siblings),
        // mirroring `surfaceWorldPoint`.
        let hidden = hiddenPartIDs
        var best: SCNVector3?
        var bestDistance = Double.greatestFiniteMagnitude
        for part in sceneController.parts where !hidden.contains(part.id) {
            guard let modelNode = modelInstance.partModelNodes[part.id] else { continue }
            guard let hit = modelNode.hitTestWithWorldSegment(from: origin, to: end, options: [
                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue as NSNumber
            ]).first else { continue }
            let distance = hit.worldCoordinates.distance(from: origin)
            if distance < bestDistance {
                bestDistance = distance
                best = hit.worldCoordinates
            }
        }
        return best
    }

    private func modelHitTestEnd(from origin: SCNVector3, direction: SCNVector3) -> SCNVector3? {
        let originVector = SIMD3<Double>(Double(origin.x), Double(origin.y), Double(origin.z))
        let directionVector = SIMD3<Double>(Double(direction.x), Double(direction.y), Double(direction.z))
        let directionLength = simd_length(directionVector)
        guard directionLength > 1e-9, directionLength.isFinite else { return nil }

        let center = sceneController.modelBoundingSphere.center
        let centerVector = SIMD3<Double>(Double(center.x), Double(center.y), Double(center.z))
        let radius = max(Double(sceneController.modelBoundingSphere.radius), 1)
        let reach = max(100_000, radius * 4 + simd_distance(originVector, centerVector) * 2)
        let end = originVector + directionVector / directionLength * reach
        return SCNVector3(end.x, end.y, end.z)
    }

    var mousePosition: SCNVector3? {
        guard let hoverPoint else { return nil }
        return sceneView.unprojectPoint(SCNVector3(hoverPoint.x, hoverPoint.y, 0))
    }

    func motionActiveChanged(_ active: Bool) {
        guard active else {
            endSpaceMouseMotion(interrupted: false)
            return
        }
        guard !navLibIsSuspended, !isSpaceMouseMotionActive else { return }
        isSpaceMouseMotionActive = true
        // A new gesture started: drop any pending "navigation settled" refresh so the toolbar
        // state isn't updated mid-motion.
        cancelNavigationSettledUpdate()
        cameraNavigator.stopMotion() // grabbing the SpaceMouse cancels a mouse glide
        // Hide the cursor while navigating, the same way the system hides it
        // while typing: it reappears automatically as soon as the mouse moves.
        NSCursor.setHiddenUntilMouseMoves(true)
        // Suspend mouse/trackpad camera navigation while a SpaceMouse motion is active so the two
        // don't fight (replaces toggling SceneKit's now-disabled allowsCameraControl).
        sceneView.cameraControlEnabled = false
        // NavLib writes the camera transform with actions disabled, which doesn't spin up SceneKit's
        // render loop — so without this the view only repaints on demand and motion lags behind the
        // data. Render vsync-paced for the duration of the motion (SceneKit's own camera control used
        // to keep this alive via allowsCameraControl).
        sceneView.rendersContinuously = true
    }
}

fileprivate extension SCNCamera {
    func orthographicViewExtents(viewAspectRatio: Double) -> SCNVector3.BoundingBox {
        let height = orthographicScale * 2
        let width = height * viewAspectRatio
        return (
            min: SCNVector3(-width / 2, -height / 2, zNear),
            max: SCNVector3(width / 2, height / 2, zFar)
        )
    }
}

extension SCNVector3: NavLib.Vector {
    public init(x: Double, y: Double, z: Double) {
        self.init(x, y, z)
    }
}

extension Transform {
    var scnMatrix: SCNMatrix4 {
        SCNMatrix4(
            m11: values[0],  m12: values[1],  m13: values[2],  m14: values[3],
            m21: values[4],  m22: values[5],  m23: values[6],  m24: values[7],
            m31: values[8],  m32: values[9],  m33: values[10], m34: values[11],
            m41: values[12], m42: values[13], m43: values[14], m44: values[15]
        )
    }
}

extension Vector {
    var scnVector: SCNVector3 {
        .init(Double(x), Double(y), Double(z))
    }
}

extension SCNMatrix4 {
    public var navLibTransform: NavLib.Transform {
        .init([m11, m12, m13, m14,  m21, m22, m23, m24,  m31, m32, m33, m34,  m41, m42, m43, m44])
    }
}
