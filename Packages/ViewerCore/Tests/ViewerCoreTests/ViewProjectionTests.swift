import Testing
import SceneKit
import simd
@testable import ViewerCore

/// `ViewProjection` exists to stand in for `SCNSceneRenderer.projectPoint`, so every test here
/// checks it against the real thing rather than against hand-derived numbers.
@MainActor
struct ViewProjectionTests {
    private struct Fixture {
        let view: SCNView
        let cameraNode: SCNNode
        let camera: SCNCamera
        let size: CGSize

        var projection: ViewProjection {
            ViewProjection(
                cameraTransform: cameraNode.presentation.worldTransform,
                projectionTransform: camera.projectionTransform(withViewportSize: size),
                viewportSize: size
            )
        }
    }

    /// - Parameter automaticZRange: Mirrors the viewer's perspective camera, which lets SceneKit
    ///   pick the depth range. Then `zNear`/`zFar` keep reporting their defaults, so anything
    ///   derived from them is wrong — see `a camera with an automatic z-range still projects`.
    private func fixture(
        orthographic: Bool,
        size: CGSize,
        automaticZRange: Bool = false,
        distance: CGFloat = 30
    ) -> Fixture {
        let camera = SCNCamera()
        camera.fieldOfView = 47
        camera.usesOrthographicProjection = orthographic
        camera.orthographicScale = 10
        camera.automaticallyAdjustsZRange = automaticZRange
        if !automaticZRange {
            // The viewer's own orthographic settings: a range wide enough that nothing is clipped.
            camera.zNear = orthographic ? -100_000 : 1
            camera.zFar = orthographic ? 100_000 : 100
        }

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, distance)
        cameraNode.eulerAngles = SCNVector3(0.3, 0.4, 0.1) // an off-axis pose, so no term drops out

        let scene = SCNScene()
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 8, height: 8, length: 8, chamferRadius: 0)))

        let view = SCNView(frame: CGRect(origin: .zero, size: size))
        view.scene = scene
        view.pointOfView = cameraNode

        return Fixture(view: view, cameraNode: cameraNode, camera: camera, size: size)
    }

    private let visiblePoints = [
        SCNVector3(0, 0, 0),
        SCNVector3(3, -2, 5),
        SCNVector3(-8, 4, -12),
        SCNVector3(12, -9, 14),
    ]

    private func expectMatchesProjectPoint(_ f: Fixture, _ points: [SCNVector3]) throws {
        let projection = f.projection
        for point in points {
            let expected = f.view.projectPoint(point)
            let actual = try #require(projection.project(point), "\(point) was rejected")
            #expect(Double(actual.x) ≈ Double(expected.x))
            #expect(Double(actual.y) ≈ Double(expected.y))
        }
    }

    @Test(arguments: [
        CGSize(width: 800, height: 600),
        CGSize(width: 600, height: 800),
        CGSize(width: 733, height: 411), // a non-round aspect, to catch a viewport-size mix-up
    ])
    func `a perspective projection matches projectPoint`(size: CGSize) throws {
        try expectMatchesProjectPoint(fixture(orthographic: false, size: size), visiblePoints)
    }

    @Test(arguments: [CGSize(width: 800, height: 600), CGSize(width: 411, height: 733)])
    func `an orthographic projection matches projectPoint`(size: CGSize) throws {
        try expectMatchesProjectPoint(fixture(orthographic: true, size: size), visiblePoints)
    }

    /// The regression that broke snapping outright: with an automatic z-range the camera keeps
    /// reporting the default 1...100 no matter what it renders with, so a model a few hundred
    /// units out projects to a depth past the far plane. x and y are unaffected, so the fix is to
    /// project them and not filter on depth at all — every one of these points is on screen and
    /// must come back.
    @Test func `a camera with an automatic z-range still projects`() throws {
        let f = fixture(orthographic: false, size: CGSize(width: 800, height: 600), automaticZRange: true, distance: 400)
        f.view.snapshot() // render once, so any automatic range SceneKit picks has been applied

        #expect(f.camera.zFar == 100) // the trap: nowhere near the ~400 the camera actually renders
        try expectMatchesProjectPoint(f, [SCNVector3(0, 0, 0), SCNVector3(50, 50, 50), SCNVector3(-50, 20, -50)])
    }

    /// A point behind a perspective camera divides by a negative w, which would mirror it onto a
    /// perfectly plausible screen position — and a corner behind the camera must never become a
    /// snap target.
    @Test func `a point behind a perspective camera is rejected`() {
        let f = fixture(orthographic: false, size: CGSize(width: 800, height: 600))
        #expect(f.projection.project(SCNVector3(0, 0, 60)) == nil)
    }

    /// Orthographic has no projective divide, so a point behind the camera still lands where it
    /// belongs; the viewer's wide orthographic z-range means `projectPoint` reports it too.
    @Test func `a point behind an orthographic camera still projects`() throws {
        let f = fixture(orthographic: true, size: CGSize(width: 800, height: 600))
        try expectMatchesProjectPoint(f, [SCNVector3(0, 0, 60)])
    }

    /// `projectPoint` projects through the *presentation* transform, so a camera move that
    /// SceneKit is still animating projects from where the camera currently appears, not where it
    /// was told to go. Callers must feed `presentation.worldTransform` to match.
    @Test func `the projection follows the camera's presentation transform`() throws {
        let f = fixture(orthographic: false, size: CGSize(width: 800, height: 600))
        f.cameraNode.position = SCNVector3(5, 5, 25)
        try expectMatchesProjectPoint(f, [SCNVector3(0, 0, 0)])
    }
}
